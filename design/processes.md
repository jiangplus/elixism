<!-- SPDX-License-Identifier: Apache-2.0 -->
# Processes on fibers

Elixir/BEAM processes are isolated, share-nothing actors with a mailbox,
scheduled pre-emptively by the VM. This project models them as **cooperative
fibers** on a single run queue. A fiber suspends itself by aborting to a
delimited-continuation prompt — the exact technique used by
[Guile Fibers](https://github.com/wingo/fibers) and by Hoot's own
`(hoot scheduler)`. That is the whole reason the design maps cleanly onto the
browser: in the Wasm build the same `abort-to-prompt`/`call-with-prompt`
machinery is provided by Hoot, backed by Wasm tail calls.

## The primitives

```
spawn(fn)   create a fiber, enqueue it, return its pid
send(pid, m) append m to pid's mailbox; if it is blocked, wake it
receive ..  take the first matching message; else suspend
self()      the running fiber's (canonical) pid
Process.sleep(ms)  suspend until the logical clock advances
```

## The scheduler (`module/elixir/process.scm`)

```
   run queue ──deq──► run fiber under call-with-prompt(sched-tag)
       ▲                       │
       │                fiber aborts (receive/sleep)
       │                       ▼
   wake! ◄── send / timeout ── park: stash continuation k, add to *blocked*
       │
       └── (run queue empty?) ──► fire-due-timeouts!: advance the logical
                                  clock to the nearest deadline, wake those
                                  whose `after` elapsed; none due ⇒ stop
                                  (permanent deadlock).
```

A parked fiber stores its suspended continuation `k`. Waking it sets its
resume thunk to `(k reason)` where `reason` is `'message` or `'timeout`, so
`receive` knows whether to re-scan the mailbox or run its `after` body.

### `receive` selects, then removes, then runs

The subtle correctness point. A `receive` clause body may itself block in a
nested `receive` (e.g. a recursive server loop). If the body ran *inside* the
mailbox scan, an abort would unwind before the matched message was removed,
stranding it. So the compiled handler returns a **thunk** of the body; the
scheduler removes the message first, then calls the thunk — matching BEAM's
"select message, dequeue, execute" order. This is what makes recursive
stateful processes (a `Counter.loop/1` that recurses inside `receive`) work.

### Logical time

There is no wall clock. `after N` and `Process.sleep(N)` register a deadline
in a monotonically advancing logical-time counter. When the run queue empties
but fibers are parked, the scheduler jumps the clock to the nearest deadline
and fires it. This makes timeouts deterministic and testable, and doubles as
deadlock detection: parked fibers with no pending timeout and nothing to wake
them simply end the run (the BEAM would leave them blocked forever).

## Differences from BEAM (deliberate, for the slice)

| BEAM | here |
|------|------|
| pre-emptive, reduction-counted scheduling | cooperative; fibers yield only at `receive`/`sleep` |
| per-process isolated heaps | one shared heap (see [gc.md](gc.md)) |
| real timers | logical clock |
| `trap_exit`, named processes, registries | not yet implemented |
| multicore run queues | single run queue |

## Crash handling, links, and monitors

Each fiber runs its body under an exception handler: an uncaught `raise`
terminates **only that fiber** with reason `{:error, payload}` (a normal return
is reason `:normal`), and the scheduler keeps going. On termination a process:

* sends every monitor a `{:DOWN, ref, :process, pid, reason}` message
  (`Process.monitor/1` returns the `ref`; a dead target fires `:DOWN` with
  `:noproc` immediately), and
* propagates an **abnormal** exit to every linked process (`spawn_link`,
  `Process.link/1`), terminating them with the same reason — which cascades
  through the link set.

The root process created by `elixir-run` is special: if it dies abnormally,
its reason is re-raised into the host so the CLI and test suite see the error
rather than silently getting `nil`.

## GenServer

`GenServer` is built entirely on these primitives (in `kernel.scm`), not baked
into the runtime. `GenServer.start_link/2` spawn-links a fiber that calls the
module's `init/1` then enters a receive loop; `call/2` sends a `{:"$call",
{self, ref}, request}` tuple and blocks on the matching `{ref, reply}`; `cast/2`
sends `{:"$cast", request}` and returns immediately. The loop dispatches to the
module's `handle_call/3` / `handle_cast/2` / `handle_info/2` and tail-recurses
with the returned state — relying on the same "recursion inside `receive`"
correctness the scheduler guarantees. `use GenServer` is accepted and ignored;
the user supplies the callbacks directly.

## trap_exit and Supervisor

`Process.flag(:trap_exit, true)` flips a per-process flag. When a linked
process dies, a trapping process receives an `{:EXIT, pid, reason}` *message*
instead of being killed — the mechanism OTP supervisors rely on to survive
child crashes.

`Supervisor.start_link(children, opts)` spawn-links a fiber that traps exits,
starts each `{Module, arg}` child via `Module.start_link(arg)`, and on an
`{:EXIT, pid, reason}` restarts that child (`:one_for_one`: only the dead one).
Because children are started *from within* the supervisor fiber, their
`spawn_link` links them to the supervisor automatically.

## Reduction-counted pre-emption

Pure cooperative scheduling lets a CPU-bound process (one that never calls
`receive`) starve everyone else. To prevent that, every function call
(`ex-call-local`/`ex-call-remote`) decrements a per-slice **reduction budget**
(default 2000, like BEAM). When it hits zero the process *yields* — it
`abort-to-prompt`s the scheduler, which re-queues it immediately (ready, not
parked) and resumes it on its next turn. So a 50k-call loop runs in ~25 slices,
interleaving with other ready processes.

This is why the slice's exception handler sits *outside* the yield prompt: a
yield's captured continuation must be resumable, and a continuation cannot be
re-entered across an unwinding exception handler — so the prompt is nested
inside the handler, never the reverse.

## Named processes

`Process.register(pid, name)` / `whereis/1` / `unregister/1` maintain a global
name→pid table. `send`, and `GenServer.call`/`cast`, resolve an atom
destination through it, and `GenServer.start_link(mod, arg, name: N)` registers
the server. Module resolution for local calls is **lexical** (the compiler
emits the defining module as a literal), so a closure like
`spawn(fn -> helper() end)` still finds `helper/0` in its own module after it
migrates to another process.

These simplifications suit a single-threaded Wasm guest. The cooperative model
is a good fit: WebAssembly is single-threaded by default, and `receive` is a
natural yield point.
