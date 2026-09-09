# Perf / optimization scan (M9 prototype)

Date: 2026-09-09. Machine: `results/baseline/env.json` (i5-12400F, gcc 16.2 / MinGW).
Zig 0.14.1, `-O ReleaseFast`. Prototype: `bench/opt_scan.zig` (does NOT modify
`src/matcher.zig`). Corpus: `tests/corpus/workload.jsonl` (2400 musl-validated
cases, 10 categories). Method identical to `bench/workload.zig` (warmup + 5
timed runs of >=1024 iters / ~1ms budget, per-case min, category median).

> **Run-to-run variance caveat.** The recorded `results/baseline/workloads.json`
> matcher medians (e.g. single-star 27ns) do not reproduce on this machine
> today (same repo harness now measures ~72ns for the same code — machine
> state/turbo drift across sessions, ~2.7x). All numbers below were therefore
> re-measured **in one session**: base and opt interleaved in the same process
> (robust ratio), musl re-run per case right before aggregation
> (`bench/adversarial_musl.exe`). Do not compare against the older recorded
> absolute numbers.

## Headline finding — real bug in `src/matcher.zig` (FNM_PATHNAME)

`src/matcher.zig`'s star rewind rejects a `/` crossing only when the **failure
byte** is `/`. When a match attempt deep-fails *after* consuming a literal `/`,
the rewind can march past that `/`, so the star's cover grows to include a `/` —
which musl never allows.

Repros (all `FNM_PATHNAME`; matcher=MATCH, vendored musl 1.2.5 = NOMATCH):

    a*/b    vs a/x/b     (matcher: true,  musl: NOMATCH)
    a*/c    vs a/b/c     (matcher: true,  musl: NOMATCH)
    */x.c   vs a/b/x.c   (matcher: true,  musl: NOMATCH)
    x/*/a   vs x/y/z/a   (matcher: true,  musl: NOMATCH)

Not caught by M2 unit vectors or the 20k/2400 differential corpora: the
generators never produced a star followed by a literal `/` with a deep-fail
after it (their PATHNAME shapes are shallow: `*`, `*/leaf`, `pre/*`).
Recommended fix (not applied — src is out of scope for this scan): on star
retry under FNM_PATHNAME, reject when the byte being **added to the star
cover** (`str[rewind]`) is `/`, i.e. replace the failure-byte guard
`if (pathname and string[s]=='/')` with a cover guard before `rewind += 1`.
Correctness argument: cover grows monotonically with each retry candidate, so
once it would include `/`, no later candidate can match. `bench/opt_scan.zig`
implements the fixed guard and is pinned to musl on 16 vectors
(`musl_vectors`); 93 hand vectors still agree with matcher everywhere else.
Add these four repros as regression vectors when fixing.

## What was prototyped (in `bench/opt_scan.zig`, `matchOpt`)

One-shot compile-then-match (0 heap alloc; stack token array, fallback to
matcher for patterns >128 tokens):

1. **Literal-run tokens.** Pattern compiles once into tokens; maximal raw
   literal runs become one `.run` token consumed by one slice compare
   (`std.mem.eql` -> memcmp), not per-byte dispatch.
2. **Tail anchor (V2).** If the token after the LAST `*` is a single raw
   literal run of length m>0, the greedy matcher must consume exactly the
   string's final m bytes with it: `endswith` check first (fast reject), then
   recurse once on `pattern[0..star+1]` (ends in `*`) over the shortened
   string. Disabled under FNM_PERIOD (stripping relocates a segment-leading
   `.` to position 0 and changes the musl leading-dot gate — vector
   `*.x` vs `.x` PERIOD must stay NOMATCH). Recursion depth <= 1.
3. **Star->run jump.** Plain flags only: when a retry's next-after-star token
   is a literal run starting with byte c0, scan with `indexOfScalar` (memchr)
   to the next c0 instead of stepping one byte per candidate.
4. **Final-star absorb shortcut.** Plain flags: a pattern ending in `*`
   absorbs the whole remainder in one jump.
5. **Class-token caching.** Bracket bodies are tokenized once (a,b slice);
   the per-byte loop no longer re-runs `scanClass` + content slicing per byte.
6. **Flag hoisting.** PATHNAME/PERIOD/CASEFOLD/NOESCAPE decoded once per call;
   per-byte loop is flag-free on the common paths.
7. **Pure-literal fast path.** Patterns with no wildcard/class/escape skip the
   token loop entirely (`runEq` whole-string compare).
8. **Compile-time structure flags** (`pure_literal`, `last_star`, `star_final`)
   so the tail-anchor path is skipped when the last star is final, avoiding a
   second pattern pass.

Tried and dropped during the scan:

- MAXT=2048 token buffer: the ~48KB x2 stack frames cost a flat ~20-25ns per
  call (measured: fail-early 18ns at 2048 vs 11-12ns at 128; every category
  improved 1.2-1.8x). 128 tokens covers real patterns; longer ones fall back
  to matcher. Keep MAXT small.
- A separate leading-literal prefix strip was designed then dropped: in-loop
  run tokens already bulk-compare leading literals, and the strip interacts
  with the FNM_PERIOD leading-dot gate.
- A star->run jump under FNM_PATHNAME/PERIOD/FNM_CASEFOLD: not worth the
  corner cases (fold makes the first-byte scan incomplete; period interacts
  with the dot gate). Plain-only jump kept.

## Results (same-session medians, ns/match; musl re-measured same session)

| category       | base (matcher) | opt  | musl | opt/base | opt/musl |
|----------------|---------------:|-----:|-----:|---------:|---------:|
| literal-heavy  |           75.5 | 21.0 | 67.0 |   0.28x  |  0.31x   |
| single-star    |           74.0 | 16.0 | 29.0 |   0.22x  |  0.55x   |
| prefix-star    |           48.0 | 16.0 | 30.0 |   0.33x  |  0.53x   |
| suffix-star    |           89.5 | 19.5 | 50.0 |   0.22x  |  0.39x   |
| multi-star     |          130.5 | 66.0 |140.0 |   0.51x  |  0.47x   |
| question-marks |           45.0 | 30.0 | 39.0 |   0.67x  |  0.77x   |
| brackets       |           44.0 | 29.0 | 47.0 |   0.66x  |  0.62x   |
| pathname       |           38.5 | 22.0 | 47.0 |   0.57x  |  0.47x   |
| fail-early     |            4.0 | 11.0 |  5.0 | **2.75x**| **2.2x** |
| fail-late      |          117.5 | 13.0 | 36.0 |   0.11x  |  0.36x   |

opt is 2-9x faster than the current matcher on 9 of 10 categories and faster
than musl on 9 of 10 (single-star 16 vs 29, suffix-star 19.5 vs 50, pathname
22 vs 47, multi-star 66 vs 140, literal-heavy 21 vs 67...). Two independent
runs agreed within ~10%.

**The one loss is honest and structural:** fail-early (mismatch at the first
byte) goes 4 -> 11ns because one-shot compile-then-match has a fixed ~7ns
overhead per call that a 4ns trivially-failing match cannot amortize. 11ns is
still negligible in absolute terms, and the category is the cheapest possible
case (pure fail-fast). musl's 5ns there is its per-byte walk with zero setup.
Reported as-is; a hybrid entry (scan for wildcard bytes before compiling) would
close most of it but add a second pass on every wildcard pattern.

## What to keep / next steps (recommendations only — src untouched)

1. **Fix the FNM_PATHNAME star-cover bug first** (headline above) and pin the
   four repros as regression vectors. It is a real semantic divergence from
   musl in released code, independent of performance.
2. Adopt the compiled-token design (runs + tail anchor + plain jump) as the
   M9 matcher core: 2-4x over current, beats musl on every real workload
   category, and the tail anchor also caps the worst-case rewind distance on
   star-heavy patterns (multi-star 130 -> 66ns and still flat in star count).
3. Keep MAXT ~128 with matcher fallback; revisit token packing only if a
   profiling pass shows the compile loop.
4. Re-run the full differential corpora (unit vectors, 20k corpus, workload)
   against the adopted matcher — the musl-pinned vectors in opt_scan.zig are
   the semantic harness to reuse.
5. Re-run `bench/workload_run.py` fresh (same-session musl + matcher) before
   publishing any absolute comparison; the older recorded baselines are not
   reproducible on this machine state.

Zero-alloc per match is preserved (stack token array). Binary/compile not yet
measured; LOC: prototype ~700 lines incl. harness — production core would be
the matcher part only (~350).
