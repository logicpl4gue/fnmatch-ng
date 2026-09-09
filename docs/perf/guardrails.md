# Optimization guardrails (read-only audit 2026-09-09)

Every optimization ported into `src/matcher.zig` must preserve these.
Each line: invariant + test pin.

1. PERIOD raw-byte gate: a segment-leading `.` may only be consumed by a `lit ch='.' step==1` token — star, `?`, class, `\.` all reject (M5 "plan section 14 cases", test 27).
2. Escaped dot at a leading position is NOMATCH (`\.` first pattern byte is `\`, step 2) (M5 "escaped dot", D005).
3. Leading-dot gate is terminal and position-scoped: rejection never star-rewinds past the dot; gate re-runs at every `(s,p)`; "leading" = `s==0` or after `/` only when PATHNAME set (M5 rewind/position tests).
4. PATHNAME: `*`, `?`, classes never consume `/`; star rewind bails with NOMATCH at `/` — and the cover-add guard: a star may never COVER `/` even if a later literal realigns (BUG 2026-09-09: `*/x` vs `a/b/x` must be NOMATCH; regression vectors in `tests/unit/m2_pathname.jsonl`).
5. Trailing lone `\` is an ordinary literal backslash, step 1 (M3 trailing-backslash, D002/D003).
6. Escapes are single lit tokens consuming 2 pattern bytes; rewind retries the token, not the `\` byte (M3 escape tests).
7. Reversed ranges contribute only endpoint bytes as literal members (M4 reversed-range, D001).
8. CASEFOLD is ASCII-only: bytes ≥0x80 never fold (M6 ASCII-only test).
9. Fold applies to the string byte only (pattern bytes raw); classes, ranges, negation, escaped literals fold the same way (M6 class/literal tests).
10. NOESCAPE governs backslash only outside classes; inside a class `\` is an ordinary member (M4 NOESCAPE-in-class tests).
11. NOESCAPE flips only escape pairing outside classes (M3 NOESCAPE test).
12. A class token exists only when scanClass finds a closer; `[]`, unterminated `[`, unterminated POSIX spans degrade to literals (M4 degrade test).
13. End-state: string exhausted → only unescaped trailing `*` may remain, full pattern consumed; `\*` never skips (M1 rewind `x*` vs `""`, M3 escaped tests).
14. Greedy rewind semantics: retries re-enter at last star +1 with strictly advancing `s`; `**` ≡ `*`; suffix fast paths must not shortcut star search alignment (M1 rewind + M4 classes-in-rewind tests).
15. Fast paths from tokenized lits, not raw bytes: literal runs use token byte counts (step-2 escapes); no raw memcmp under CASEFOLD unless both sides folded identically (equality is `S==P or fold(S)==P`); end-anchored suffix mismatch conclusive only for all-literal tails.
