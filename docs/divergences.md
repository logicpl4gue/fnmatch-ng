# Divergences

Reference: vendored musl 1.2.5 (`compat/`) — this Windows box has no system `fnmatch`.
Corpus: `tests/corpus/m0_baseline.jsonl` (117 cases). Baseline: 114 agree / 3 diverge (97.44%).
Harness: `scripts/ref_harness.exe --json` + `scripts/differential.py`.

| ID | pattern | string | flags | corpus expected | musl actual | classification | status |
|----|---------|--------|-------|-----------------|-------------|----------------|--------|
| D001 | `[z-a]` | `z` | — | NOMATCH | MATCH | LIBC_DIFFERENCE (reversed range: boundary chars are literal members in musl; glibc-pending) | mirrored in matcher (M4 test 17), glibc check pending |
| D002 | `a\` | `a\` | — | NOMATCH | MATCH | SPEC_AMBIGUITY (trailing backslash: literal vs error) | open — needs glibc check |
| D003 | `\` | `\` | — | NOMATCH | MATCH | SPEC_AMBIGUITY (same as D002) | open — needs glibc check |
| D004 | `\*` | `.x` | FNM_PERIOD | MATCH | NOMATCH | BUG_CORPUS (escaped `*` is literal `*`, never equals `.x`; musl NOMATCH is correct) | RESOLVED_CORPUS_BUG — expectation fixed to NOMATCH; regressions added: `\*` vs `*`, `\*x` vs `*x`, `\*x` vs `.x`, all FNM_PERIOD |
| D005 | `\.` | `.` | FNM_PERIOD | MATCH | NOMATCH | LIBC_DIFFERENCE? (FNM_PERIOD leading-dot rule is a raw first-BYTE check in musl: only an unescaped literal `.` satisfies it; an escaped `\.` parses to a literal `.` but its first byte is `\`, so NOMATCH. glibc check pending.) | M5 supervisor decision 2026-09-09: mirror musl — escaped dot at a leading position = NOMATCH; pinned as matcher test "M5 escaped dot at a leading position"; glibc check pending |
| D006 | `a*/b` vs `a/x/b`; `a*/c` vs `a/b/c`; `*/x.c` vs `a/b/x.c`; `x/*/a` vs `x/y/z/a` | FNM_PATHNAME | matcher MATCH | musl NOMATCH | BUG_MATCHER (star rewind cover could grow across `/` when a deep failure happened after a literal `/` was consumed; fixed by a cover-add guard: on star retry under FNM_PATHNAME reject when the byte added to the star cover `str[rewind]` is `/`. Found by the M9 perf audit, `docs/perf/scan.md`.) | FIXED 2026-09-09 — regression vectors appended to `tests/unit/m2_pathname.jsonl`; unit tests M9 star-cover guard |

`FNM_CASEFOLD` in corpus is musl-only until glibc cross-check (plan M4).

Known deferred divergence: POSIX `[:alpha:]`/`[= =]`/`[. .]` spans are recognized structurally for class boundaries but never match bytes (M4 supervisor decision; later phase).
