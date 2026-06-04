#!/usr/bin/env python3
"""Merge JSON-parse benchmark TSVs from up to three runtimes into one table.

Usage: report.py jason.tsv guile.tsv [wasm.tsv]
Each line: runtime<TAB>file<TAB>bytes<TAB>iters<TAB>us_per_parse<TAB>nodes
Joins by file basename (in the order they appear in jason.tsv), shows per-parse
times and slowdown factors, and checks that all runtimes agree on the node count.
"""
import sys


def load(path):
    rows, order = {}, []
    for line in open(path):
        p = line.rstrip("\n").split("\t")
        if len(p) != 6:
            continue
        _rt, f, byts, _iters, us, nodes = p
        base = f.split("/")[-1]
        rows[base] = (int(byts), int(us), int(nodes))
        order.append(base)
    return rows, order


jason, order = load(sys.argv[1])
guile, _ = load(sys.argv[2])
wasm, _ = load(sys.argv[3]) if len(sys.argv) > 3 else ({}, [])

def fmt(n): return f"{n:,}" if isinstance(n, int) else n
def dash(): return "—"

print()
print("  JSON parsing across runtimes — µs per parse (lower is better)")
print("  Jason = real Jason on the BEAM;  Elixism = the recursive-descent parser")
print("  compiled by Elixism, run on Guile (native bytecode) and on Hoot/WASM.")
print("  " + "-" * 92)
print("  %-22s %9s %10s %11s %12s   %8s %8s   %s"
      % ("file", "size", "Jason", "Elixism", "Elixism", "Guile", "WASM", "nodes"))
print("  %-22s %9s %10s %11s %12s   %8s %8s   %s"
      % ("", "(bytes)", "BEAM", "Guile", "Hoot/WASM", "/Jason", "/Jason", "(match)"))
print("  " + "-" * 92)

agg_j = agg_g = 0                 # over all files (Jason vs Guile)
wj = wg = ww = 0                  # over only the files WASM ran (for WASM ratios)
for base in order:
    jb, jus, jn = jason[base]
    gb, gus, gn = guile.get(base, (0, 0, -1))
    has_w = base in wasm
    wb, wus, wn = wasm.get(base, (0, 0, -2))

    counts = [jn] + ([gn] if base in guile else []) + ([wn] if has_w else [])
    ok = len(set(counts)) == 1
    mark = ("✓ %d" % jn) if ok else ("✗ " + "/".join(map(str, counts)))

    g_ratio = f"{gus/jus:.0f}x" if (base in guile and jus) else dash()
    w_ratio = f"{wus/jus:.0f}x" if (has_w and jus) else dash()
    agg_j += jus
    agg_g += gus if base in guile else 0
    if has_w:
        wj += jus; wg += gus if base in guile else 0; ww += wus

    print("  %-22s %9s %10s %11s %12s   %8s %8s   %s"
          % (base, fmt(jb), fmt(jus),
             fmt(gus) if base in guile else dash(),
             fmt(wus) if has_w else dash(),
             g_ratio, w_ratio, mark))

print("  " + "-" * 92)
gx = f"{agg_g/agg_j:.0f}x" if agg_j else dash()
wx = f"{ww/wj:.0f}x" if (ww and wj) else dash()
print("  %-22s %9s %10s %11s %12s   %8s %8s"
      % ("(sum / relative)", "", fmt(agg_j), fmt(agg_g), fmt(ww) if ww else dash(), gx, wx))
if ww and wg:
    print()
    print("  Over the files WASM ran: Jason 1x, Elixism/Guile ~%.0fx, Elixism/WASM ~%.0fx;"
          % (wg / wj, ww / wj))
    print("  i.e. Hoot/WASM is ~%.0fx slower than native Guile bytecode. Hoot compiles" % (ww / wg))
    print("  Scheme to WebAssembly (Wasm-GC) and crosses the JS↔Wasm reflect boundary")
    print("  per call; Guile runs native VM bytecode. Equal node counts confirm agreement.")
print()
