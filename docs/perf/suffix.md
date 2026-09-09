# Anchored-tail fast path (`bench/opt_suffix.zig`)

> Perf-audit lane deliverable. Measured 2026-09-09, fnmatch-ng repo root.
> Machine: `results/baseline/env.json` — i5-12400F, MinGW, Zig 0.14.1.
> Ours = `src/matcher.zig` @ ReleaseFast. Method: `bench/workload.zig`
> style — warmup + 5 timed runs, >=1024 iters, ~1 ms budget/run, min
> ns/match, per-case; medians over the corpus below. Raw per-case rows
> (plain + fast, engaged flag, tail length): `results/baseline/_suffix_ours.jsonl`.

## Problem (why musl wins the star-with-tail categories)

`results/baseline/workloads.json` + `docs/perf/profile.md` isolate the
three losses to patterns of the form `X*Y` with a non-empty literal tail
`Y`: single-star 65 vs 27 ns, suffix-star 75 vs 46 ns, fail-late 102 vs
32 ns. Per profile.md the per-string-byte slopes are ours ~2.7–13 ns vs
musl 0.30 ns on `*parser.c`/`*.c` shapes (worst: A6 `*[a-z]x`, 28.9x at
length 258). Cause: `src/matcher.zig` retries the whole tail token-by-token
at every string position (classic greedy rewind, ~2.7 ns/string-byte),
while musl's `fnmatch_internal` (compat/musl_fnmatch.c) ANCHORS the tail:
find the last `*`, count the tail tokens, walk that many chars back from
the string END, compare the tail, and only then component-match the prefix
(per-segment, after splitting on `/` under FNM_PATHNAME).

## Prototype

`bench/opt_suffix.zig` wraps `src/matcher.zig` with a **semantically
transparent** anchored-tail fast path (`fastMatchFlags`; `src/matcher.zig`
is NOT modified):

    fastMatchFlags(p, s, f) = tryFast(p, s, f)  orelse  matchesFlags(p, s, f)

Reduction (valid when engaged): when the pattern's last `*` is followed
only by literal bytes `T` (escape pairs allowed), any full match must end
with `T` consuming the string tail, so `q = |s| - |T|` is FIXED and the
match decomposes exactly into:

    matchesFlags(pattern[0..lastStarEnd], s[0..q))   // prefix incl. '*'
    AND decoded T == s[q..]                           // anchored literal compare

The prefix slice is matched by the UNMODIFIED matcher, so every prefix
token quirk (classes, `?`, PERIOD gates, CASEFOLD) keeps its exact current
behavior on `[0..q)`. Order matters: the tail compare runs FIRST — when the
string does not end in `T`, the answer is `false` with no sub-match at all
(that is where the fail-late / single-star NOMATCH wins come from).

Engagement rules (bail -> identical fallback, never a behavior change):

1. No `*`, or pattern ends in `*` (empty tail), or tail not pure literals
   (`?`/class after the last `*`), or tail > 512 bytes.
2. Any `[` anywhere disables the wrapper: class bodies can contain `*`
   (needs real tokenization) and class patterns measured as at-best-wash.
   This keeps `scanTail` a cheap single forward byte pass (~1 ns/byte).
3. FNM_PATHNAME and the tail contains `/` — matcher.zig's star rewind can
   span `/` when the tail holds a literal `/` to realign on, so the anchor
   is not equivalent there (see the finding below); stay transparent.
4. FNM_PERIOD and (tail contains `/` or an escaped dot): the raw-byte
   leading-dot gate at segment starts inside/at the tail region is only
   faithfully reproduced by the full matcher.
5. After the tail compare passes, if more `*`s exist before the last one
   (multi-star prefix), bail: the prefix sub-match would re-run the same
   multi-star dispatch as plain for pattern-shaped strings, buying nothing
   while paying the scan. Multi-star patterns still win via rule-order when
   the tail compare FAILS (instant false).

CASEFOLD tail compare mirrors the matcher exactly: fold the STRING byte
only (`k == ch || fold(k) == ch`); pattern bytes stay raw.

## Correctness

- `zig test` self-check: 200,000 randomized differential cases
  (`fastMatchFlags` vs `matchesFlags`, deterministic xorshift, grammar
  covering `*`, `?`, escapes, `.`/`/`-heavy strings, all four flags) — 0
  mismatches; plus edge batteries for every engagement/bail rule.
- Full workload corpus run: 2400 cases, 0 mismatches (also asserted
  per-case inside the timing binary).

## Measured results (workload corpus, engaged medians)

| category | plain | fast | ratio | engaged |
|---|---|---|---|---|
| fail-late | 130 ns | 14 ns | **9.3x** | 240/240 |
| single-star | 76 ns | 26 ns | **2.9x** | 240/240 |
| suffix-star | 97 ns | 34 ns | **2.9x** | 240/240 |
| multi-star | 94 ns | 65 ns | 1.45x | 79/240 (tail-mismatch) |
| brackets | — | — | 1.00x | 0/240 (rule 2 bails) |
| literal-heavy / prefix-star / pathname / question-marks / fail-early | — | — | 1.00x | 0 (no star+tail) |

Micro rows (paired, isolated driver): `*.rs` vs `local/tests/u451fx.rs`
81 -> 41 ns; `*parser.c` vs `aaaaparser.cx` 82 -> 14 ns; adversarial
family A (`*a*a*a*a*a*a*b` vs `a`×48, failing) 191 -> 21 ns (9.1x),
family B (matching) ~184 -> 239 ns (bail tax on multi-star prefix,
see below).

## Findings

1. **Tail anchoring is the whole musl advantage in these categories** — and
   a wrapper around the current matcher recovers it: fail-late 9.3x,
   single/suffix-star ~2.9x. After this, workloads.json's three losses
   become wins or ties (brackets/pathname already tied/won and are
   untouched).
2. **Latent PATHNAME bug in `src/matcher.zig` vs the vendored reference
   (musl 1.2.5), caught by the engagement analysis.** When FNM_PATHNAME is
   set, pattern `*/x` vs string `a/b/x`: musl = NOMATCH (it splits pattern
   and string on `/` into segments first — a star never spans `/`),
   matcher.zig = MATCH: the star rewind can absorb across a `/` when the
   tail contains a literal `/` that later realigns (e.g. `a*/b` vs
   `aX/Y/b` likewise MATCH-vs-NOMATCH). musl is segment-local
   (`fnmatch()` outer loop, fnmatch_internal per segment); the matcher has
   no segment structure. The 20k differential + hand corpus never shaped
   this. The wrapper bails on `PATHNAME + '/' in tail` to stay transparent
   to the CURRENT matcher. **Recommend a matcher-fix lane**: adopt musl's
   per-segment structure (split on `/`, match each segment) — which also
   lets the tail anchor live INSIDE the matcher per segment (see next).
3. **A wrapper has a hard ceiling.** Matching multi-star prefixes (adversarial
   family B, `src/*/mod/*/x` patterns) cannot be sped up from outside: the
   prefix sub-match duplicates the plain matcher's dispatch and the bail
   path pays a small scan tax (+15-30% on family B). musl's real advantage
   there is one parse + component matching. The fix is structural, not a
   wrapper: port musl's algorithm shape (find last `*`, anchored tail, then
   per-component prefix loop with the "advance one char on component
   failure" rewind) into `src/matcher.zig`, keeping the byte-wise C-locale
   semantics. `bench/opt_suffix.zig` is the correctness oracle + engagement
   model for that port; sibling lane `bench/opt_scan.zig` prototypes the
   same direction from the matcher side (literal-run tokens, star->run
   memchr jump, tail-anchor recursion) — merge, don't duplicate.
4. Bail-tax measurement noise note: per-run medians drift ~15% (thermal);
   ratios above are within-binary paired measurements.

## Files

- `bench/opt_suffix.zig` — prototype (tryFast + fastMatchFlags + tests).
- `results/baseline/_suffix_ours.jsonl` — raw per-case evidence.
- Run: `zig test --dep matcher -Mroot=bench/opt_suffix.zig
  -Mmatcher=src/matcher.zig`, then `zig run -O ReleaseFast --dep matcher
  -Mroot=bench/opt_suffix.zig -Mmatcher=src/matcher.zig --
  tests/corpus/workload.jsonl`.
