// Benchmark the Zig HAMT map (in WASM) against Guile's alist-backed emap on the
// exact workload that made Elixism's real-program benchmarks O(n^2): build an
// N-entry integer-keyed map by repeated put, then look every key up.
// SPDX-License-Identifier: Apache-2.0
const fs = require("fs");

async function main() {
  const bytes = fs.readFileSync(__dirname + "/elixism_rt.wasm");
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const e = instance.exports;
  e.rt_init();

  for (const N of [1000, 4000, 16000, 64000]) {
    e.rt_reset();
    const t0 = process.hrtime.bigint();
    let m = e.map_new();
    for (let i = 0; i < N; i++) m = e.map_put(m, e.mk_fixnum(i), e.mk_fixnum(i * 2));
    const t1 = process.hrtime.bigint();
    let sum = 0;
    for (let i = 0; i < N; i++) sum += e.fixnum_val(e.map_get(m, e.mk_fixnum(i)));
    const t2 = process.hrtime.bigint();

    const expect = (N - 1) * N; // sum of i*2 for i in 0..N-1
    if (sum !== expect) throw new Error(`wrong sum ${sum} != ${expect} (N=${N})`);

    const buildMs = Number(t1 - t0) / 1e6;
    const lookupMs = Number(t2 - t1) / 1e6;
    console.log(
      `Zig HAMT  N=${String(N).padStart(6)}  build ${buildMs.toFixed(2)}ms ` +
        `(${((buildMs * 1e3) / N).toFixed(3)} us/op)  lookup ${lookupMs.toFixed(2)}ms ` +
        `(${((lookupMs * 1e3) / N).toFixed(3)} us/op)  heap ${(e.rt_heap_used() / 1e6).toFixed(1)}MB`,
    );
  }
}
main().catch((err) => { console.error(err); process.exit(1); });
