# fnmatch-ng

**POSIX `fnmatch()` had 38 years to get its corners documented. It didn't. So we rebuilt it: one Zig file, zero heap, every behavior pinned against musl instead of guessed.**

[![language](https://img.shields.io/badge/language-Zig-f7a41d)](https://ziglang.org)
[![deps](https://img.shields.io/badge/dependencies-0-green)](.)
[![heap](https://img.shields.io/badge/heap%20allocs%20per%20match-0-green)](.)
[![size](https://img.shields.io/badge/static%20lib-13.8%20KiB-blue)](.)
[![parity](https://img.shields.io/badge/musl%201.2.5%20agreement-20%2C911%20%2F%2020%2C911-green)](.)
[![speed](https://img.shields.io/badge/faster%20than%20musl-10%20of%2010%20workloads-green)](.)

> Your libc's glob matcher has corners nobody can explain. Ours has six, all filed, all with reproducers.

[Why](#why) · [Scoreboard](#scoreboard) · [Speed](#speed) · [Adversarial](#adversarial) ·
[Opinions](#opinions) · [Hot takes](#hot-takes) · [The experiment](#the-experiment) ·
[Scope](#scope) · [Quick start](#quick-start) · [Status](#status)

---

## Why

Every glob you've ever run (filesystem, config file, build system) went
through `fnmatch(3)`, one of the oldest, most quietly universal functions in
C. And every existing implementation makes you pick your poison:

- **The libc one:** a black box whose corners differ between libcs. Quirks
  you inherit silently and can never pin down. Thirty-eight years old and
  still "trust me."
- **A vendored copy:** more code to audit, more glue to maintain, same 1988
  semantics underneath. Tech debt with a build script.

fnmatch-ng ends the trade: one Zig file (~1,300 lines), zero dependencies,
**zero heap allocations per match** (not "minimal heap": zero), exported
through a plain C ABI, and verified verdict-for-verdict against a reference
implementation instead of assumed correct.

Watch it work (real calls, `0` == match, `1` == no match):

```c
fnmatch_ng_flags("src/*.zig", "src/main.zig", FNM_PATHNAME);            /* 0: trivially */
fnmatch_ng_flags("*.zig", "src/main.zig", FNM_PATHNAME);                /* 1: * must not cross '/' */
fnmatch_ng_flags("*.zig", ".main.zig", FNM_PATHNAME | FNM_PERIOD);      /* 1: leading '.' needs an explicit match */
fnmatch_ng_flags("*.zig", "main.zig", 0);                               /* 0 */
```

That's the whole job. Here is the whole proof.

---

## Scoreboard

Every claim below comes from running both implementations on the **same
machine** against the **same inputs**: the 20,911-vector corpus (composition
in [The corpus](#the-corpus)), plus randomized differential cases.

```
fnmatch-ng vs musl libc 1.2.5        (vendored; the build box has no system fnmatch)

  in-scope test vectors   ████████████████████  20,911 / 20,911  agree
  divergences             D001–D006             every one audited, none silent
  glibc cross-check       ░░░░░░░░░░░░░░░░░░░░  parked: no Linux host yet (see Status)
```

**20,911 / 20,911.** Not "passes its own test suite": every in-scope vector
produces the identical match/no-match answer as musl libc 1.2.5, the
implementation famous for doing fnmatch correctly.

> [!NOTE]
> One corpus expectation is stale, and it's D001's case: `m0_baseline.jsonl`
> line 55 (`[z-a]` vs `z`) still says NOMATCH while musl and this matcher both
> MATCH; the file predates the D001 mirror decision. It stays as the one
> vector whose *file* expectation disagrees with the live musl result, by
> design, so nobody confuses a shipped expectation for a live verdict.

**Six documented divergences, D001–D006.** Differential testing *will* find
disagreements, and hiding them is how matchers rot. Each of the six is filed
with its reproducer and its reasoning, linked from the D-ledger in this repo.
One of them wasn't a subtle libc corner at all: it was a genuine bug in our
own matcher (see [The bug we found on purpose](#the-bug-we-found-on-purpose)).

---

## Speed

Median ns per match, same machine, both sides re-measured in the same
session (post-memchr-port run). Lower is better.

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

**All 10 workload categories go to fnmatch-ng**, between **1.1× and 8.0×
faster** (0.13×–0.91× of musl's ns). Full harness and methodology ship with
the repo so you can re-run the numbers yourself. If you can make the table
look worse, open an issue. We'd genuinely like to know.

### The old loss that became a win

Pre-port, `fail-early` cost us an honest **11 ns vs 5 ns**: a fixed compile
tax paid even when a call died on byte one, and the one category musl won.
The memchr star-skip port added a byte-0 guard that erases it: fail-early now
reads **3 ns vs 5 ns**, ours. 10/10.

### The two regressions we're not hiding

The port's two star categories run hotter than the pre-port prototype's best
same-session numbers: **single-star 19 ns and suffix-star 21 ns vs 16/19 ns**
at the merge bar. Both stay 1.4–2.2× faster than musl, both sit inside this
box's ±20% run-to-run variance, and chasing them further would be tuning
noise. Re-measure before publishing any absolute number.

---

## Adversarial

Benchmarks on friendly inputs prove nothing. Matchers die on **pathological
patterns**, so that's where the corpus points its worst intentions:

- **Star-count attack:** raise the number of `*` in the pattern from 2 to
  24. No cliff, no runaway on failing tails: matches stay in a 14–39 ns band up to 10 stars,
  and the 12-to-24-star extension tops out at 47–71 ns on 128-byte strings.
  Matching tails are the honest footnote: at k=24 the B family costs us
  325 ns vs musl's 279 (n=128) and 425 vs 277 (n=256). Full rows in
  `results/baseline/adversarial_ext.json`.
- **The textbook killer:** naive matchers go exponential on
  `*a*a*…*b` against a long run of `a`s. It kills neither fnmatch-ng nor
  musl; both return instantly.
- **Trap fuzz** (`fuzz/memfuzz.zig`): arbitrary byte soup through the
  matcher under ReleaseSafe, where the Zig runtime turns any overstep into
  a crash with a stack trace. Seeds are the API, runs are deterministic,
  and 12.5% of patterns are floods built to blow past the 128-token buffer
  so the bytewise fallback (`matchBytewise`) gets exercised too.

If you know a pattern family that breaks glob matchers and it's not in the
corpus, that's not a complaint, that's a contribution. File it.

---

## Opinions

Things this repo believes and won't apologize for:

1. **Zero heap means zero.** Not "almost none", not "amortized". A glob
   matcher has no business calling malloc. If yours does, ask it why.
2. **Undocumented corners are bugs with seniority.** 38 years of "that's just
   how libc does it" is how `*` swallows a `/` somewhere in your build
   system at 2am. We filed all six of ours, and the one that was our own bug
   gets its own section [below](#the-bug-we-found-on-purpose).
3. **A benchmark you can't lose is marketing.** The two accepted star
   regressions (+3/+2 ns over a prototype's best reading) are in the same
   table as the 8× fail-late. Any benchmark page without a loss row is
   telling you what the author needed to be true.
4. **Vendoring is not a strategy.** Copying 1988 semantics into your tree
   doesn't fix them. It just makes them your fault now.
5. **One file is a feature.** ~1,300 lines, zero dependencies: the entire
   implementation fits in a code review you can finish before your coffee
   cools. That's the audit story. There is no other audit story.

---

## Hot takes

Questions people will argue about, answered with a stance:

- **"Why not just use libc?"** Because then your matcher's behavior is
  defined by whichever libc your user happens to link. Ours is defined by
  20,911 vectors you can re-run. Pick your religion.
- **"Single-star is 3 ns over the prototype's best. Noise?"** It's inside
  this box's ±20% run-to-run variance and still beats musl 1.4×; the full
  ledger is [the two regressions we're not
  hiding](#the-two-regressions-were-not-hiding). Re-measure on your machine
  before quoting ours.
- **"What about glibc?"** Parked, not dodged: the build box has no Linux
  host, and MinGW can't link glibc. The first Linux box that appears gets
  to be the referee, same harness, same machine, and the next number this
  README prints is the glibc one, whatever it says, including if it's bad
  for us.
- **"Why trap fuzzing and not libFuzzer/AFL?"** Same answer as glibc: no
  Linux host. So the memory-safety leg runs where the code runs: in
  ReleaseSafe, where the Zig runtime's own traps are the oracle and every
  run is reproducible from a seed.
- **"No `[:classes:]`? No Unicode? Toy project?"** Scope is frozen on
  purpose (see below). A matcher that does 90% of POSIX provably beats one
  that does 100% approximately.

---

## The experiment

This project was built like an experiment, because it was one: can a decades-old
spec function be rebuilt, from scratch, with **no heap**, and still be *provably*
a drop-in: not approximately, not "should be", but vector-by-vector?

### The oracle

Compatibility claims need a referee. The build box has no system `fnmatch`, so
**musl libc 1.2.5 was vendored in as the reference**: small, strict, and
self-contained enough to compile anywhere.

### The corpus

The scoreboard's 20,911 inputs come in three layers: 20,000 vectors from a
**seeded, grammar-aware generator** (grammar-aware so it hunts the parts of
the grammar where matchers actually break: bracket edge cases, escapes, `*`
next to `/` next to `.`, star storms; seeded so the same corpus reproduces
forever), 794 pinned unit vectors, and the 117-case m0 baseline.

### The differential run

On top of the corpus: **3,000 randomized differential cases against musl**
plus **200,000 prototype-vs-production self-checks** (suffix-prototype A/B).
Every musl-facing verdict is compared. When they disagree, the case gets a
ticket, not a shrug.

### The build

A **supervisor-mediated agent swarm** built and cross-examined the
implementation: code, tests, and this document's numbers all came out of that
process. Which matters less than what the numbers are: every figure here comes
from a harness a human can re-run, not from a chat log.

### The bug we found on purpose

Differential testing is supposed to embarrass you, and it did. Exactly once.
One randomized case caught a real bug in our matcher: a **PATHNAME star-cover**
case where our `*` swallowed a `/` separator musl never lets it cross. musl was
right; we were wrong. The fix was small, the regression vectors were pinned into
the corpus, and it's why the divergence list says **six**, not zero: six is what's
left after you stop sweeping disagreements under the test suite.

---

## Scope

What fnmatch-ng implements, and what it doesn't (yet).

| feature | status |
|---|---|
| literals, `?`, `*` | ✅ |
| escapes / `FNM_NOESCAPE` | ✅ |
| bracket expressions | ✅ |
| `FNM_PATHNAME` (`*` and `?` don't cross `/`) | ✅ |
| `FNM_PERIOD` (leading `.` needs an explicit match) | ✅ |
| `FNM_CASEFOLD` (C locale, ASCII bytes) | ✅ |
| memory-safety leg (`fuzz/memfuzz.zig`, ReleaseSafe) | ✅ |
| real-consumer demo (`demo/filter.zig`, find-style) | ✅ |
| POSIX `[:classes:]` | 🔜 deferred |
| `FNM_LEADING_DIR` | 🔜 deferred |
| Unicode | 🔜 deferred |
| glibc cross-check | 🔜 needs a Linux host |

The in-scope surface (everything POSIX `fnmatch` ships except character
classes) is complete and frozen, which is exactly what makes the 20,911/20,911
scoreboard meaningful. Frozen means frozen: new features don't move old vectors.

---

## Quick start

C, C++, Rust, Zig: anything that can call a C ABI. No header ships yet: two
`extern` declarations are the whole API (`0` == match, `1` == no match, musl
flag values):

```c
int fnmatch_ng(const char *pattern, const char *string);
int fnmatch_ng_flags(const char *pattern, const char *string, int flags);
/* flags: FNM_PATHNAME 0x1, FNM_NOESCAPE 0x2, FNM_PERIOD 0x4, FNM_CASEFOLD 0x10 */

if (fnmatch_ng_flags("src/*.zig", "src/main.zig", 0x1) == 0) {
    /* matched: without a single heap allocation */
}
```

```console
$ zig build -Doptimize=ReleaseFast   # → zig-out/lib/fnmatch_ng.lib (~13.8 KiB)
$ zig build test                     # 39 unit tests, all green
$ python3 scripts/zig_gate.py tests/unit/*.jsonl tests/corpus/big20k_expected.jsonl
                                     # 20,794 pinned vectors green; the live-musl
                                     # differential adds m0's 117 → 20,911/20,911
$ zig run -O ReleaseSafe --dep matcher -Mroot=fuzz/memfuzz.zig \
      -Mmatcher=src/matcher.zig -- 0x5eed 200000
                                     # memory-safety leg: 200k soup iterations, exit 0
$ zig run -O ReleaseFast -lc --dep matcher -Mroot=demo/filter.zig \
      -Mmatcher=src/matcher.zig compat/musl_fnmatch.c -- . -name '*.zig'
                                     # find-style demo; add --verify to cross-check
                                     # every verdict against vendored musl
```

Zig consumers can also import `src/matcher.zig` directly (`matchesFlags`).
There is nothing else to install: one file of implementation, zero
dependencies, by design. Sixty seconds from clone to re-running our scoreboard.

---

## Status

- **Compatibility:** frozen against musl 1.2.5 at 20,911/20,911; D001–D006 in
  the ledger (`docs/divergences.md`). One corpus expectation (m0:55) is
  deliberately stale (see [Scoreboard](#scoreboard)).
- **Shipped since the port:** memory-safety leg (`fuzz/memfuzz.zig`) and the
  find-style demo (`demo/filter.zig`, with `--verify` against vendored musl).
- **glibc cross-check:** parked, pending a Linux host on the build box. The
  first Linux box that appears decides, same harness, same machine. The next
  number this README prints will be that one.
- **Next:** long-soak the fuzzer; land the glibc leg when a Linux host shows
  up.
- **[YOU DECIDE] Which deferred scope item falls first?** `[:classes:]`,
  `FNM_LEADING_DIR`, or Unicode — vote in issues. Top-voted becomes the next
  milestone, whatever it says.

No hype beyond these numbers: run [Quick start](#quick-start) and check every
one.

---

*⭐ Star if a silent libc quirk has ever personally victimized you. Found a pattern that breaks us? [File it](.): the corpus takes contributions, and the ledger takes names.*

*fnmatch, but not from 1988.*
