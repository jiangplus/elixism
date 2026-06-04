// Run the elixism stdlib test program (compiled to WebAssembly) in Node.
// SPDX-License-Identifier: Apache-2.0
//
//   node run.js
//
// Loads program.wasm via Hoot's reflect.js, provides the `host.print` import
// the Elixir program calls with its summary, and exits non-zero on any failure.
const { Scheme } = require("./reflect.js");

async function main() {
  let summary = null;
  await Scheme.load_main("program.wasm", {
    reflect_wasm_dir: __dirname,
    user_imports: { host: { print: (s) => { summary = s; } } },
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
