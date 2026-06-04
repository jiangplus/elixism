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

These are the natural simplifications for a single-threaded Wasm guest. The
cooperative model is a good fit: WebAssembly is single-threaded by default,
and `receive` is a natural yield point.
