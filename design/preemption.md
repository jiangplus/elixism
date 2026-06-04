<!-- SPDX-License-Identifier: Apache-2.0 -->
# Pre-emption counter: design and tuning

Elixism gives each process a **reduction budget** and pre-empts it cooperatively,
BEAM-style: every function call ticks a counter, and when it hits zero the
running process yields to the scheduler so others get a turn. The hook is
`reduce!` in [`module/elixir/process.scm`](../module/elixir/process.scm), called
from `ex-call-local`/`ex-call-remote` in
[`dispatch.scm`](../module/elixir/dispatch.scm) on every Elixir-level call.

Because it runs on *every* call, `reduce!` is squarely on the hot path. This note
records what it actually costs, the candidates considered for cutting that cost,
and the one that shipped.

## What it costs

Measured on the JSON parser ([`bench-json/`](../bench-json)) — a pure
single-process workload that makes millions of calls — by swapping `reduce!`
implementations and taking the min of 3 runs (µs per parse):

| `reduce!` body | blockchain | github | giphy | vs baseline |
|----------------|-----------:|-------:|------:|:-----------:|
| baseline (decrement + abort) | 25,688 | 76,491 | 185,888 | — |
| **no-op (`#t`) — the ceiling** | 23,989 | 70,604 | 174,814 | **−7 to −10 %** |

So the *entire* pre-emption machinery is **~7–10 %** of parse time. That is the
whole budget available to this optimization; the other ~190× gap to Jason is
dispatch, the value model, and interpreted-vs-native execution, none of which the
counter touches.

Two further measurements located the cost precisely:

- Replacing the body with *just* the decrement (no fluid deref, no abort) was
  still within noise of baseline — so the `(current-process)` parameter lookup
  and the `abort-to-prompt` round-trip were **not** the cost.
- The cost is the **per-call volume itself**: touching shared scheduler state
  (a decrement, or even a single run-queue read) on every one of millions of
  calls. Anything `reduce!` does on the hot path costs ~7 %; only doing *nothing*
  reaches the ceiling.

## Candidates

| # | Candidate | Effect | Verdict |
|---|-----------|--------|---------|
| **C1** | **Lone-process elision** — gate all counting on "is another process ready?", checked by an inlined run-queue read. A single process has no one to yield to, so it does ~nothing. | **−3 to −4 %**, recovers ~½ the ceiling | **Shipped** |
| C2 | Cheaper hot path — decrement a plain global, move the `current-process`/abort checks to the threshold | ~0 % (the body wasn't the cost) | Subsumed by C1 |
| C3 | Count on local calls only (drop `reduce!` from `ex-call-remote`) | ~0 % here; coarsens reductions | Rejected — no gain, weakens fairness accounting |
| C4 | Raise `reduction-limit` (fewer aborts) | negligible (aborts aren't the cost) | Rejected |
| C5 | Compiler-emitted reduction points — tick only at loop back-edges / self-recursion instead of every call | could approach the ceiling on hot loops | Future work (needs compiler support; risk: a tight non-local-recursive loop never yields) |
| C6 | Inline `reduce!` into the dispatch functions to drop one call layer | low (the *call* is cheap; the state access is the cost) | Not pursued |

## What shipped: lone-process elision (C1)

Pre-emption only matters when there is **another** ready process to be fair to.
The overwhelmingly common case — one process, e.g. any pure computation in the
root fiber — has no one to yield to, so the counter is pure overhead there. C1
skips the *entire* machinery (no counting, no abort/resume) behind one inlined
run-queue check:

```scheme
;; an (ice-9 q) is a pair whose car is the list of queued items; a non-empty
;; car means another process is already waiting to run.
(define-syntax-rule (others-ready?) (pair? (car *runq*)))

(define (reduce!)
  (when (others-ready?)
    (set! *reductions* (- *reductions* 1))
    (when (<= *reductions* 0)
      (set! *reductions* (reduction-limit))
      (abort-to-prompt sched-tag 'yield))))
```

Why this is **correctness-preserving**, not a fairness regression:

- While a process runs, the scheduler has already dequeued it, so `*runq*` holds
  exactly the *other* ready processes. `others-ready?` is therefore true precisely
  when there is someone to yield to.
- When two or more processes are runnable, every running process sees the others
  in the queue, counts down, and yields after `reduction-limit` calls — identical
  round-robin to before. The test *"reduction pre-emption interleaves CPU-bound
  work"* (a CPU-heavy process must yield so a quick one's message arrives first)
  still passes.
- A lone process not yielding has no observable effect: the scheduler's logical
  clock only advances when the run queue is idle, so blocked timers fire at the
  same logical point whether or not the lone process bounced through the
  scheduler in between.

Result: ~3–4 % faster on the pure-parse benchmark (more on call-heavy inputs —
`canada.json` improved ~12 %), aggregate Elixism slowdown vs Jason 222× → 193×,
with all 241 tests green and identical parse output.

## The ceiling, and where the rest of the time goes

The hard limit here is ~10 %. Pushing past it means *not making the call at all*
on the hot path — candidate **C5**, where the compiler emits a reduction tick
only at loop back-edges (self/mutual recursion) rather than on every call. That
would let straight-line and leaf calls run tick-free while still bounding any
loop, approaching the no-op ceiling on exactly the workloads that matter. It is
left as future work because it requires the compiler to identify back-edges and
carries a real correctness obligation (every unbounded loop must retain at least
one tick), unlike C1 which is a pure, local, runtime-only change.
