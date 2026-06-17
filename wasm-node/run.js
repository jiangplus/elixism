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
const { readFileSync } = require("node:fs");
const path = require("node:path");

// Instantiate the native Zig regex engine as a sibling wasm module and expose
// re.compile/search/cap to the Elixir program (the edge counterpart of the
// host's libelixism_re FFI).  Strings are marshalled into its linear memory.
function loadRegex() {
  const bytes = readFileSync(path.join(__dirname, "elixism_re.wasm"));
  const re = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
  const enc = new TextEncoder();
  const put = (str) => {
    re.re_reset();
    const b = enc.encode(str);
    const off = re.re_alloc(b.length);
    new Uint8Array(re.memory.buffer).set(b, off);
    return [off, b.length];
  };
  // One string-in/string-out entry point: compile (cached) + search, returning
  // "s0,l0,s1,l1,…" (or "" for no match).  flags/start arrive as BigInt.
  const handles = new Map();
  return {
    exec: (pat, flagsStr, subj, startStr) => {
      const flags = Number(flagsStr), start = Number(startStr);
      const key = pat + "\0" + flags;
      let h = handles.get(key);
      if (h === undefined) { const [o, l] = put(pat); h = re.re_compile(o, l, flags); handles.set(key, h); }
      if (h < 0) return "";
      const [o, l] = put(subj);
      const n = re.re_search(h, o, l, start);
      if (n <= 0) return "";
      const dv = new DataView(re.memory.buffer), base = re.re_caps_ptr(), out = [];
      for (let i = 0; i < n; i++) out.push(Number(dv.getBigInt64(base + i * 8, true)));
      return out.join(",");
    },
  };
}

async function main() {
  let summary = null;
  const re = loadRegex();
  await Scheme.load_main("program.wasm", {
    reflect_wasm_dir: __dirname,
    user_imports: { host: { print: (s) => { summary = s; }, sql: () => "[]" }, re },
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
