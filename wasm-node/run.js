// Run the elixism stdlib test program (compiled to WebAssembly) in Node.
// SPDX-License-Identifier: Apache-2.0
//
//   node run.js
//
// Hoot 0.9+ emits the Wasm exception-handling (exnref) opcodes, which V8 needs
// a flag for; we re-exec ourselves with it so plain `node run.js` works.
const EXNREF = "--experimental-wasm-exnref";
if (!process.execArgv.includes(EXNREF)) {
  const { spawnSync } = require("child_process");
  const r = spawnSync(process.execPath, [EXNREF, __filename], { stdio: "inherit" });
  process.exit(r.status ?? 1);
}

// Load program.wasm via Hoot's reflect.js, provide the `host.print` import the
// Elixir program calls with its summary, and exit non-zero on any failure.
const { Scheme } = require("./reflect.js");

async function main() {
  let summary = null;
  await Scheme.load_main("program.wasm", {
    reflect_wasm_dir: __dirname,
    user_imports: { host: { print: (s) => { summary = s; }, sql: () => "[]" } },
  });

  console.log("Elixism standard library, running in WebAssembly:\n");
  console.log("  " + summary + "\n");

  const m = summary && summary.match(/^(\d+)\/(\d+) passed/);
  if (m && m[1] === m[2]) {
    console.log(`✓ all ${m[2]} checks passed in Wasm`);
    process.exit(0);
  }
  console.error("✗ some checks failed");
  process.exit(1);
}

main().catch((e) => { console.error("error:", e); process.exit(1); });
