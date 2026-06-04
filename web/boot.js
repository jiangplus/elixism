// SPDX-License-Identifier: Apache-2.0
// Boot an Elixir-on-Hoot .wasm in the browser and route IO.puts to the page.
//
// `make wasm` produces build/<name>.wasm and copies reflect.js + the Hoot
// reflection runtime (reflect.wasm, wtf8.wasm) next to this file.  The
// compiled program calls the host import `io.puts`, which we provide here.

const out = document.getElementById("out");
out.textContent = "";

function print(line) {
  out.textContent += line + "\n";
}

window.addEventListener("load", async () => {
  try {
    await Scheme.load_main("build/program.wasm", {
      reflect_wasm_dir: ".",
      user_imports: {
        // Elixir's IO.puts is compiled to call this host function.
        io: { puts: (s) => print(s) },
      },
    });
  } catch (e) {
    print("error: " + e + "\n" + (e.stack || ""));
  }
});
