// Elixism web server for Node.js — serves a handler-mode program.wasm (the
// Playground Elixir app) over Node's native http server.
// SPDX-License-Identifier: Apache-2.0
//
//   node server.js [program.wasm] [port]      (defaults: program.wasm 8080)
//
// Architecture (thin host, fat runtime), mirroring the Cloudflare worker:
//   node:http (native C++ sockets)
//     → Endpoint.handle(method, path, body) -> "STATUS\n<json>"   (Hoot wasm)
//     ← native response framing (status line, headers, CORS)
//
// What lives where:
//   * sockets / HTTP parsing  -> Node (native, off Elixir)
//   * regex (~r/…/)           -> Zig elixism_re.wasm kernel, the `re` import
//   * JSON encode / query parse / routing / business logic -> the wasm (Elixir
//     + the native-Scheme Jason). The JS layer does ZERO JSON work: it splits
//     the status line and streams the already-encoded body through.
//
// Hoot 0.9+ emits exnref opcodes; we re-exec with the V8 flag so plain
// `node server.js` works.
const EXNREF = "--experimental-wasm-exnref";
if (!process.execArgv.includes(EXNREF)) {
  const { spawnSync } = require("child_process");
  const r = spawnSync(process.execPath, [EXNREF, __filename, ...process.argv.slice(2)], {
    stdio: "inherit",
  });
  process.exit(r.status ?? 1);
}

const http = require("node:http");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const { Scheme } = require("./reflect.js");

const PROGRAM = process.argv[2] || path.join(__dirname, "program.wasm");
const PORT = Number(process.argv[3] || process.env.PORT || 8080);

// The Zig regex engine, instantiated as a sibling wasm module and exposed as
// the `re.exec` host import (one string-in/string-out call). Same bridge as
// run.js and the Cloudflare worker's makeRegexImport.
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

function toJsString(v) {
  if (typeof v === "string") return v;
  if (v?.reflector && typeof v.reflector.string_value === "function")
    return v.reflector.string_value(v);
  return String(v);
}

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, PUT, DELETE, OPTIONS",
  "access-control-allow-headers": "content-type",
};

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", () => resolve(""));
  });
}

async function main() {
  const re = loadRegex();
  const results = await Scheme.load_main(PROGRAM, {
    reflect_wasm_dir: __dirname,
    user_imports: { host: { print: () => {}, sql: () => "[]" }, re },
  });
  const vals = Array.isArray(results) ? results : [results];
  const handler = vals.find((v) => v && typeof v.call === "function");
  if (!handler) throw new Error("program.wasm did not return a handler procedure");

  const server = http.createServer(async (req, res) => {
    const method = req.method;
    // Native edge routes bypass the wasm (the work taken off Elixir).
    if (method === "OPTIONS") { res.writeHead(204, CORS); return res.end(); }
    if (req.url === "/healthz") {
      res.writeHead(200, { "content-type": "application/json; charset=utf-8", ...CORS });
      return res.end(JSON.stringify({ ok: true, served_by: "elixism-node" }));
    }

    // Query parsing stays in Elixir (Phoenix-style): hand it path + search.
    const pathWithQuery = req.url;
    const body = method === "GET" || method === "HEAD" ? "" : await readBody(req);

    let status = 200, jsonBody = "";
    try {
      const out = toJsString(handler.call(method, pathWithQuery, body)[0]);
      const nl = out.indexOf("\n");
      status = nl < 0 ? 200 : parseInt(out.slice(0, nl), 10) || 200;
      jsonBody = nl < 0 ? out : out.slice(nl + 1);
    } catch (e) {
      status = 500;
      jsonBody = JSON.stringify({ error: String(e) });
    }
    res.writeHead(status, { "content-type": "application/json; charset=utf-8", ...CORS });
    res.end(method === "HEAD" ? undefined : jsonBody);
  });

  server.listen(PORT, () => {
    console.log(`Elixism on Node listening at http://127.0.0.1:${PORT}`);
    console.log(`  program: ${path.basename(PROGRAM)}   regex: Zig elixism_re.wasm`);
  });
}

main().catch((e) => { console.error("server error:", e); process.exit(1); });
