# Hot-path profile: `src/matcher.zig`

> Perf-audit lane deliverable. Measured 2026-09-09, fnmatch-ng repo root.
> Machine: `results/baseline/env.json` — i5-12400F (12th gen), gcc 16.2.0
> MinGW, Zig 0.14.1. Ours = `src/matcher.zig` @ ReleaseFast via
> `bench/prof_hot.zig` (warmup + 5 timed runs, >=1024 iters, ~1 ms budget,
> min ns/match). Reference = vendored musl 1.2.5 via
> `bench/adversarial_musl.exe` (probe + adaptive batch to ~2 ms, one
> process per case). Raw per-case rows: `results/baseline/_prof_hot_ours.jsonl`
> and `_prof_hot_joined.jsonl` (ours + musl joined). This file contains no
> unmeasured claims; every number below is a row or slope from those files.

## Why profile these shapes

The workload benchmark (`results/baseline/workloads.json`) loses in exactly
three categories: single-star 65 vs 27 ns (2.4x), suffix-star 75 vs 46 ns
(1.6x), fail-late 102 vs 32 ns (3.2x) — all patterns of the form `X*Y` with
a **non-empty tail after a star**. Literal-heavy, brackets, pathname,
question-marks, fail-early all tie or win. `bench/prof_hot.zig` isolates
the cost drivers: A = star-with-tail shapes over a string-length sweep,
B = pure literal passes (per-byte dispatch), C = `?` chains, D = bare `*`,
E = per-position flag checks, G = raw `std.mem.eql` floor.

## Measured slopes (ns per string byte)

| group | shape | ours | musl |
|---|---|---|---|
| A1 | `*parser.c` vs `aⁿ`+`parser.cx` (NOMATCH) | **2.66** | 0.30 |
| A2 | `*parser.c` vs `aⁿ`+`parser.c` (MATCH) | **2.64** | 0.28 |
| A3 | `*.c` vs `aⁿ`+`.x` (NOMATCH) | **2.84** | 0.30 |
| A4 | `*.c` vs `aⁿ`+`.c` (MATCH) | **2.95** | 0.31 |
| A6 | `*[a-z]x` vs `aⁿ`+`bx` (MATCH) | **12.99** | 0.28 |
| D | `*` vs `aⁿ` (MATCH) | 0.75 | 0.27 |
| B1 | `abcdefghij`×r vs itself (MATCH) | 2.52 | 2.36 |
| B2 | same, last byte flipped (NOMATCH) | 2.62 | 2.02 |
| C | `?`×32 vs `a`×32 | 82 ns flat | 84 ns flat |

Worst absolute rows: A1 at string length 265: ours 743 ns vs musl 105 ns
(7.1x). A6 at length 258: ours 3,349 ns vs musl 116 ns (**28.9x**).

## Ranked hot spots

### 1. Star-with-tail matches are O(n) byte-stepping rewinds — musl anchors the post-last-star tail (dominant loss)

Every pattern with `*` followed by a non-empty tail (`*.c`, `*parser.c`,
`*[a-z]x`, and the trailing tail of multi-star patterns) makes
`matchesFlags` retry the tail at **every string offset**: each failed
offset runs the full tokenAt + compare + star-rewind branch, then advances
one byte. That is the 2.6–3.0 ns/B cost of rows A1–A4 and the 13 ns/B of
A6 (class tails re-scan the class per retry, see #2).

musl (`compat/musl_fnmatch.c`, "Sea of Stars") instead: tokenizes the
pattern to find the **last `*`**, counts the required tail length, and
compares that tail **anchored at the string end** in one forward pass —
O(tail) with no rewind. Its residual 0.28–0.31 ns/B slope is just libc
`strnlen` walking the string (word-at-a-time). It rejects a mismatched
tail in O(tail) + O(strnlen), instantly for short strings
(`if (n < tailcnt) return FNM_NOMATCH`).

This single mechanism explains all three workload losses: single-star,
suffix-star and fail-late are exactly `*Y` shapes. A6 shows class tails
are 4–5x worse than literal tails for us (13 vs 2.7 ns/B) and would also
be fixed by anchoring.

### 2. Class tokenization re-runs on every rewind retry (secondary, compounds #1)

On a failed tail attempt `tokenAt` re-parses `[a-z]x` from scratch —
`scanClass` plus a fresh `Token` — and `classMember` walks the class body
again for the next offset. Row A6's 13 ns/B is mostly this repeated
re-parse, not the match logic itself. musl tokenizes each component
once per component search, and its tail phase parses the tail exactly once.

### 3. Per-byte forward dispatch: parity with musl, not a loss (2.4–2.6 ns/B)

Rows B1/B2/C: on star-free shapes ours walks a byte at a time at
2.4–2.6 ns/B and musl does the same (2.0–2.4). The per-byte tokenAt +
kind-switch + fold guards are *not* why we lose. Do not spend the first
optimization budget here. The only absolute win available in this region
is skipping the byte loop entirely for literal runs (below).

### 4. Flag checks per position are cheap for us — and CASEFOLD is a big win (no action)

60-byte literal workload (rows E1–E6, absolute ns):

| flags | ours | musl |
|---|---|---|
| 0 | 159 | 136 |
| +FNM_PERIOD | 158 | 141 |
| +FNM_PATHNAME | 185 | 287 |
| +FNM_CASEFOLD (string folded, fold fires/byte) | 169 | 1,164 |
| +FNM_CASEFOLD (fold short-circuits/byte) | 153 | 633 |

PERIOD's per-byte leading-dot probe costs nothing. PATHNAME costs us
+26 ns/60 B; musl pays +151 (its segment wrapper re-enters
`fnmatch_internal` per segment). CASEFOLD costs us +10–16 ns only when a
fold is actually needed, because `foldByte` is two range checks and the
literal compare short-circuits before it; musl calls CRT `towupper` +
`towlower` per byte (1.0–1.2 µs/60 B here). Nothing to fix.

### 5. Bare `*` is O(n) in us, O(strnlen) in musl (minor, easy)

Row D: ours 0.75 ns/B (star-rewind machine steps every byte even though
there is no tail to chase) vs musl 0.27 ns/B (pure strnlen then an empty
tail pass). 2.4x at 256 B but irrelevant at real filename sizes; fix
falls out of hot spot #1's pre-pass (star-only → match without scanning).

## The floor that makes literal-run batching attractive (optional, later)

Raw `std.mem.eql` on equal strings: 40 B in 1 ns, 640 B in 11 ns
(~0.02 ns/B) — Zig emits a wide compare. Our per-byte literal walk is
~2.4 ns/B, ~100x above that floor. A literal-run fast path (match both
runs of plain bytes with one `mem.eql`, or `?`-aware chunk compares)
would cut literal-heavy, tail-compare, and head/tail anchoring costs to
single-digit ns. This is plan section 32's "literal-run scanning",
currently untouched (M9).

## Fix recipes for the implementation lane (measured ceiling)

1. **Anchored post-last-star tail** (fixes single-star/suffix-star/fail-
   late entirely): pre-pass over the pattern — tokenize once, remember the
   last star index and the tail's byte requirement. If a tail exists:
   compare the pattern tail against `string[len-tail..]` in one forward
   pass ('?' matches any byte, classes check one byte, literals compare —
   all already implemented as the `.lit`/`.question`/`.cls` arms); any
   mismatch → return NOMATCH without rewinding. Then run the existing
   star-rewind machine on the prefix pattern (up to the last star) against
   `string[0..len-tail]` only. For the workload-losing shapes the prefix
   is empty or tiny, so total cost becomes O(tail) + O(prefix window) and
   should land at musl's 0.3 ns/B + fixed overhead — i.e. ours L=256 A1
   743 ns → ~100 ns (~7x), A6 3,349 ns → ~120 ns (~28x), and the
   workload category medians should drop toward musl's 27–46 ns.
   Correctness scope: FNM_PERIOD's leading-dot rule still applies per
   segment — the anchored tail may not cross a '/' under FNM_PATHNAME and
   the existing segment/PERIOD checks must stay in the anchored pass.
2. **Short-string reject** (part of #1): if `string.len < tail length`
   return NOMATCH before any scan. (Small absolute win at filename sizes;
   A5 already shows ours is competitive there — musl's own precompute
   costs it 22–25 ns.)
3. **Tokenize-once**: parse the pattern to a compact token array before
   the match loop (removes #2's re-scan entirely and lets the machine
   index tokens instead of re-deriving them). Not required for #1's win
   but removes the 13 ns/B class-tail penalty on prefix components too.
4. Later, if the benchmark still shows a gap on literal-heavy: literal-run
   memcmp per recipe above.

Order by measured impact: (1) >> (2)+(3) > (4). (1) alone is expected to
close all three losing workload categories.

## Caveats

- One machine, one day, ReleaseFast vs `gcc -O2` musl; small-`n` rows
  (L<=16) swing ±20% between process spawns — conclusions rest on the
  length slopes and the L>=64 rows, which are stable.
- A6's musl row at L=258 measured 116 ns (earlier partial pass: 202 ns);
  the slope (~0.28 ns/B) is the reliable number, not the single row.
- No change to `src/matcher.zig` was made by this lane. The workload
  benchmark must be re-run after any implementation to confirm the
  category medians move (expected: single-star/suffix-star/fail-late
  ratios -> ~1).
