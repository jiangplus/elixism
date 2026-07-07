// Benchmark the Elixism JSON parser compiled to WebAssembly, under Node.
// SPDX-License-Identifier: Apache-2.0
//
//   node bench.js blockchain.json:20 github.json:10 ...
//
// For each "file:iters", reads jason/bench/data/<file>, calls the Wasm handler
// Bench.run(data, false) `iters` times (parse only, timed), and once with
// `true` for the node count. Prints a TSV row matching the host benchmark:
//   WASM<TAB>file<TAB>bytes<TAB>iters<TAB>microseconds-per-parse<TAB>nodes

const EXNREF = "--experimental-wasm-exnref";
if (!process.execArgv.includes(EXNREF)) {
  const { spawnSync } = require("child_process");
  const r = spawnSync(process.execPath, [EXNREF, __filename, ...process.argv.slice(2)],
                      { stdio: "inherit" });
  process.exit(r.status ?? 1);
}

const fs = require("fs");
const path = require("path");
const { Scheme } = require("./reflect.js");

const DATA = path.join(__dirname, "..", "..", "jason", "bench", "data");

async function loadHandler() {
  const results = await Scheme.load_main(path.join(__dirname, "program.wasm"), {
    reflect_wasm_dir: __dirname,
    user_imports: {
      host: { print: () => {}, sql: () => "[]" },
      // The bundle declares the Zig regex foreign unconditionally; JSON
      // parsing never calls it, so a "no match" stub satisfies the import.
      re: { exec: () => "" },
    },
  });
  const vals = Array.isArray(results) ? results : [results];
  const h = vals.find((v) => v && typeof v.call === "function");
  if (!h) throw new Error("program.wasm did not return a handler procedure");
  return h;
}

function timeCalls(handler, data, mode, iters) {
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < iters; i++) handler.call(data, mode);
  const t1 = process.hrtime.bigint();
  return Number(t1 - t0) / iters / 1000; // µs per call
}

async function main() {
  // Boot + Wasm instantiation happen here, ONCE, and are explicitly EXCLUDED
  // from the per-parse timing below. We report them so it's transparent.
  const bootStart = process.hrtime.bigint();
  const handler = await loadHandler();
  const bootMs = Number(process.hrtime.bigint() - bootStart) / 1e6;
  console.error(`(one-time boot + Wasm load: ${bootMs.toFixed(0)} ms — excluded from timings)`);

  const specs = process.argv.slice(2);

  for (const spec of specs) {
    const [file, itersStr] = spec.split(":");
    const iters = parseInt(itersStr || "5", 10);
    const data = fs.readFileSync(path.join(DATA, file), "utf8");
    const bytes = Buffer.byteLength(data, "utf8");

    // node count (correctness) — mode 1; call returns [BigInt].
    // Flags are BigInt so they marshal to exact Elixir integers (0/1/2).
    const nodes = Number(handler.call(data, 1n)[0]);

    // warm both code paths, then time them
    handler.call(data, 0n);
    handler.call(data, 2n);
    const parseUs = timeCalls(handler, data, 0n, iters);  // marshal + parse
    const overheadUs = timeCalls(handler, data, 2n, iters); // marshal + call only
    // Pure in-Wasm parse time = parse-call minus the JS<->Wasm boundary overhead.
    const pureUs = Math.max(0, parseUs - overheadUs);

    console.log(`WASM\t${file}\t${bytes}\t${iters}\t${Math.round(pureUs)}\t${nodes}`);
    console.error(`    ${file}: parse-call ${Math.round(parseUs)}µs - boundary ${Math.round(overheadUs)}µs = ${Math.round(pureUs)}µs pure parse`);
  }
}

main().catch((e) => { console.error("error:", e); process.exit(1); });
