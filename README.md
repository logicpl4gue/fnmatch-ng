# fnmatch-ng

**The modern `fnmatch()`. One Zig file. No heap. Drop-in.**

POSIX's decades-old glob matcher, rebuilt from scratch in a single Zig file —
a plain C ABI, a clock that reads a fraction of the nanoseconds, and every
in-scope behavior pinned against musl libc, not guessed.

[![language](https://img.shields.io/badge/language-Zig-f7a41d)](https://ziglang.org)
[![deps](https://img.shields.io/badge/dependencies-0-green)](.)
[![heap](https://img.shields.io/badge/heap%20allocs%20per%20match-0-green)](.)
[![size](https://img.shields.io/badge/static%20lib-43.5%20KiB-blue)](.)
[![parity](https://img.shields.io/badge/musl%201.2.5%20agreement-20%2C911%20%2F%2020%2C911-green)](.)
[![speed](https://img.shields.io/badge/faster%20than%20musl-10%20of%2010%20workloads-green)](.)

[Why](#why) · [Scoreboard](#scoreboard) · [Speed](#speed) · [Adversarial](#adversarial) ·
[The experiment](#the-experiment) · [Scope](#scope) · [Quick start](#quick-start) · [Status](#status)

---

## Why

Every glob you've ever run against a filesystem, a config file, or a build
system went through `fnmatch(3)` — one of the oldest, most quietly universal
functions in C. And every existing implementation forces you to take a side:

- **The libc one** — a black box whose corners can differ between libcs, with
  quirks you inherit silently and can never pin down.
- **A vendored copy** — more code to audit, more glue to maintain, same 1988
  semantics underneath.

fnmatch-ng ends the trade. It is a replacement for POSIX `fnmatch()`: one Zig
file (~1,300 lines), zero dependencies, **zero heap allocations per match**,
exported through a plain C ABI (two symbols to rename), and verified
verdict-for-verdict against a reference implementation instead of assumed
correct.

Watch it work (real calls, `0` == match, `1` == no match):

```c
fnmatch_ng_flags("src/*.zig", "src/main.zig", FNM_PATHNAME);            /* 0 — trivially */
fnmatch_ng_flags("*.zig", "src/main.zig", FNM_PATHNAME);                /* 1 — * must not cross '/' */
fnmatch_ng_flags("*.zig", ".main.zig", FNM_PATHNAME | FNM_PERIOD);      /* 1 — leading '.' needs an explicit match */
fnmatch_ng_flags("*.zig", "main.zig", 0);                               /* 0 */
```

That's the whole job. Here is the whole proof.

---

## Scoreboard

Every claim below comes from running both implementations on the **same
machine** against the **same inputs** — a 20,911-vector corpus (20,000
generated, 794 pinned unit vectors, 117 m0 baseline) plus randomized
differential cases.

```
fnmatch-ng vs musl libc 1.2.5        (vendored — the build box has no system fnmatch)

  in-scope test vectors   ████████████████████  20,911 / 20,911  agree  ✅
  divergences             D001–D006             every one audited, none silent
  glibc cross-check       ░░░░░░░░░░░░░░░░░░░░  pending (see Status)
```

**20,911 / 20,911.** Not "passes its own test suite" — every in-scope vector
produces the identical match/no-match answer as musl libc 1.2.5, the
implementation famous for doing fnmatch correctly. (Composition: 20,000
generated + 794 unit/pinned + 117 m0 baseline.)

One m0 corpus expectation is stale, and it is D001's case: `m0_baseline.jsonl`
line 55 (`[z-a]` vs `z`) still says NOMATCH, but musl and this matcher both
MATCH — the corpus file predates the D001 mirror decision and is the only
vector whose *file* expectation disagrees with the live musl result.

**Six documented divergences, D001–D006.** Differential testing *will* find
disagreements, and hiding them is how matchers rot. Each of the six is filed
with its reproducer and its reasoning, linked from the D-ledger in this repo.
One of them was not a subtle libc corner at all — it was a genuine bug in our
own matcher (see [The bug we found on purpose](#the-bug-we-found-on-purpose)).

---

## Speed

Median ns per match, same machine, both sides re-measured in the same session
(post-memchr-port run, commit 38ab8ed). Lower is better.

| workload | fnmatch-ng | musl 1.2.5 | win |
|---|---:|---:|---|
| literal-heavy (`main.zig` vs `main.zig`) | **16 ns** | 58.5 ns | **3.7×** |
| fail-late (mismatch at the last byte) | **4 ns** | 32 ns | **8.0×** |
| fail-early (mismatch at the first byte) | **3 ns** | 5 ns | **1.7×** |
| suffix-star (`main.*`) | **21 ns** | 47 ns | **2.2×** |
| pathname (`*/` patterns) | **19 ns** | 41 ns | **2.2×** |
| multi-star (`*a*b*…`) | **64 ns** | 121 ns | **1.9×** |
| prefix-star (`*rc/…` star-head) | **17 ns** | 27.5 ns | **1.6×** |
| single-star (`*.zig` one star) | **19 ns** | 27 ns | **1.4×** |
| brackets | **32 ns** | 42 ns | **1.3×** |
| question-marks | **32 ns** | 35 ns | **1.1×** |

**All 10 workload categories go to fnmatch-ng** — between **1.1× and 8.0×
faster** (0.13×–0.91× of musl's ns). Full ten-category table, harness, and
methodology ship with the repo so you can re-run the numbers yourself.

### The old loss that became a win

Pre-port, `fail-early` cost us an honest **11 ns vs 5 ns** — a fixed compile
tax paid even when a call died on byte one, and the one category musl won.
The memchr star-skip port added a byte-0 guard that erases it: fail-early now
reads **3 ns vs 5 ns**, ours. 10/10, with nothing swept under the table.

### The two regressions we're not hiding

The port's two star categories run hotter than the pre-port prototype's best
same-session numbers: **single-star 19 ns and suffix-star 21 ns vs 16/19 ns**
at the merge bar. Both stay 1.4–2.2× faster than musl, both sit inside this
box's ±20% run-to-run variance (the prototype's own 16/19 readings repeated
at 18/21 in a later session), and chasing them further would be tuning noise.
Re-measure before publishing any absolute number.

---

## Adversarial

Benchmarks on friendly inputs prove nothing. Matchers die on **pathological
patterns**, so that's where the corpus points its worst intentions:

- **Star-count attack** — raise the number of `*` in the pattern from 1 to
  24. fnmatch-ng stays in a flat **~47–71 ns band**. No cliff, no runaway.
- **The textbook killer** — naive matchers go exponential on
  `*a*a*…*b` against a long run of `a`s. It kills neither fnmatch-ng nor
  musl; both return instantly.

---

## The experiment

This project was built like an experiment, because it was one: can a decades-old
spec function be rebuilt, from scratch, with **no heap**, and still be *provably*
a drop-in — not approximately, not "should be", but vector-by-vector?

### The oracle

Compatibility claims need a referee. The build box has no system `fnmatch`, so
**musl libc 1.2.5 was vendored in as the reference** — small, strict, and
self-contained enough to compile anywhere.

### The corpus

A **seeded, grammar-aware generator** produced the 20k-vector corpus — grammar-
aware so it hunts the parts of the grammar where matchers actually break:
bracket edge cases, escapes, `*` next to `/` next to `.`, star storms. Seeded,
so the same corpus reproduces forever.

### The differential run

On top of the corpus: **3,000 randomized differential cases against musl**
plus 200,000 prototype-vs-production self-checks (suffix-prototype A/B) —
every musl-facing one compared verdict-for-verdict. When they disagree, the
case gets a ticket — not a shrug.

### The build

A **supervisor-mediated agent swarm** built and cross-examined the
implementation: code, tests, and this document's numbers all came out of that
process. Which matters less than what the numbers are — every figure here comes
from a harness a human can re-run, not from a chat log.

### The bug we found on purpose

Differential testing is supposed to embarrass you, and it did — exactly once.
One randomized case caught a real bug in our matcher: a **PATHNAME star-cover**
case where our `*` swallowed a `/` separator musl never lets it cross. musl was
right; we were wrong. The fix was small, the regression vectors were pinned into
the corpus, and it's why the divergence list says **six**, not zero: six is what's
left after you stop sweeping disagreements under the test suite.

---

## Scope

What fnmatch-ng implements, and what it doesn't — yet.

| feature | status |
|---|---|
| literals, `?`, `*` | ✅ |
| escapes / `FNM_NOESCAPE` | ✅ |
| bracket expressions | ✅ |
| `FNM_PATHNAME` (`*` and `?` don't cross `/`) | ✅ |
| `FNM_PERIOD` (leading `.` needs an explicit match) | ✅ |
| `FNM_CASEFOLD` — C locale, ASCII bytes | ✅ |
| POSIX `[:classes:]` | 🔜 deferred |
| `FNM_LEADING_DIR` | 🔜 deferred |
| Unicode | 🔜 deferred |
| real-consumer demo | 🔜 deferred |

The in-scope surface — everything POSIX `fnmatch` ships except character
classes — is complete and frozen, which is exactly what makes the 20,911/20,911
scoreboard meaningful.

---

## Quick start

C, C++, Rust, Zig — anything that can call a C ABI. No header ships yet: two
`extern` declarations are the whole API (`0` == match, `1` == no match, musl
flag values):

```c
int fnmatch_ng(const char *pattern, const char *string);
int fnmatch_ng_flags(const char *pattern, const char *string, int flags);
/* flags: FNM_PATHNAME 0x1, FNM_NOESCAPE 0x2, FNM_PERIOD 0x4, FNM_CASEFOLD 0x10 */

if (fnmatch_ng_flags("src/*.zig", "src/main.zig", 0x1) == 0) {
    /* matched — without a single heap allocation */
}
```

```console
$ zig build -Doptimize=ReleaseFast   # → zig-out/lib/fnmatch_ng.lib (~43.5 KiB)
$ zig build test                     # 39 unit tests, all green
$ python3 scripts/zig_gate.py tests/unit/*.jsonl tests/corpus/big20k_expected.jsonl
                                     # 20,794 file-verified vectors, green; live-musl
                                     # differential adds m0's 117 → 20,911/20,911
                                     # (m0:55's D001 expectation is stale by design)
                                     # — re-run every number above
```

Zig consumers can also import `src/matcher.zig` directly (`matchesFlags`).
There is nothing else to install — one file of implementation, zero
dependencies, by design.

---

## Status

- **Compatibility** — frozen against musl 1.2.5 at 20,911/20,911; D001–D006 in
  the ledger (`docs/divergences.md`).
- **glibc cross-check** — pending. The next number this README prints will be
  the glibc one, same harness, same machine.
- **Next** — real-consumer demo, then the deferred scope above.

No hype beyond these numbers. The 8× fail-late and the two accepted star
regressions (single-star 19, suffix-star 21) are all in the table — run the
harness and check them.

---

*fnmatch, but not from 1988. — [why it exists](#why)*
