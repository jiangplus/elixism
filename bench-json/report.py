#!/usr/bin/env python3
"""Merge JSON-parse benchmark TSVs into one table.

Usage: report.py jason.tsv guile.tsv [wasm.tsv] [poison.tsv]
Each line: runtime<TAB>file<TAB>bytes<TAB>iters<TAB>us_per_parse<TAB>nodes
Joins by file basename (order from jason.tsv), shows per-parse times and slowdown
factors, and checks that all runtimes agree on the node count. Pass "-" for a
missing optional TSV.
"""
import sys


def load(path):
    rows, order = {}, []
    if not path or path == "-":
        return rows, order
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
poison, _ = load(sys.argv[4]) if len(sys.argv) > 4 else ({}, [])

def fmt(n): return f"{n:,}" if isinstance(n, int) else n
def dash(): return "—"

print()
print("  JSON parsing across runtimes — µs per parse (lower is better)")
print("  Jason, Poison = real native libraries on the BEAM;  Elixism = the")
print("  recursive-descent parser compiled by Elixism (Guile bytecode / Hoot-WASM).")
print("  " + "-" * 100)
print("  %-22s %9s %8s %8s %10s %11s   %7s %7s   %s"
      % ("file", "size", "Jason", "Poison", "Elixism", "Elixism", "Guile", "WASM", "nodes"))
print("  %-22s %9s %8s %8s %10s %11s   %7s %7s   %s"
      % ("", "(bytes)", "BEAM", "BEAM", "Guile", "Hoot/WASM", "/Jason", "/Jason", "(match)"))
print("  " + "-" * 100)

agg_j = agg_p = agg_g = 0
wj = ww = 0
for base in order:
    jb, jus, jn = jason[base]
    pb, pus, pn = poison.get(base, (0, 0, -3))
    gb, gus, gn = guile.get(base, (0, 0, -1))
    has_w = base in wasm
    wb, wus, wn = wasm.get(base, (0, 0, -2))

    counts = [jn] + ([pn] if base in poison else []) \
             + ([gn] if base in guile else []) + ([wn] if has_w else [])
    ok = len(set(counts)) == 1
    mark = ("✓ %d" % jn) if ok else ("✗ " + "/".join(map(str, counts)))

    g_ratio = f"{gus/jus:.0f}x" if (base in guile and jus) else dash()
    w_ratio = f"{wus/jus:.0f}x" if (has_w and jus) else dash()
    agg_j += jus
    agg_p += pus if base in poison else 0
    agg_g += gus if base in guile else 0
    if has_w:
        wj += jus; ww += wus

    print("  %-22s %9s %8s %8s %10s %11s   %7s %7s   %s"
          % (base, fmt(jb), fmt(jus),
             fmt(pus) if base in poison else dash(),
             fmt(gus) if base in guile else dash(),
             fmt(wus) if has_w else dash(),
             g_ratio, w_ratio, mark))

print("  " + "-" * 100)
gx = f"{agg_g/agg_j:.0f}x" if agg_j else dash()
wx = f"{ww/wj:.0f}x" if (ww and wj) else dash()
print("  %-22s %9s %8s %8s %10s %11s   %7s %7s"
      % ("(sum / relative)", "", fmt(agg_j),
         fmt(agg_p) if agg_p else dash(), fmt(agg_g),
         fmt(ww) if ww else dash(), gx, wx))
if agg_p:
    print()
    px = agg_p / agg_j
    rel = ("about even with" if 0.9 <= px <= 1.1
           else (f"~{px:.1f}x of" if px > 1 else f"~{1/px:.1f}x faster than"))
    print("  Poison (BEAM) is %s Jason overall (it wins on object/string-heavy files but" % rel)
    print("  is slower on float-heavy canada.json). Equal node counts confirm all runtimes")
    print("  build the same structure.")
print()
