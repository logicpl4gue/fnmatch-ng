# Methodology

How `fnmatch-ng` was built and how every number in the README is earned.
This is the public distillation of the project's working plan: the
phase names (`M0`–`M9`) and section references (`§N`) you'll find in
code comments and test names resolve here.

## The experiment

Replace POSIX `fnmatch()` with a compact modern implementation, then
determine scientifically whether it matches libc behavior — with
compatibility testing, differential fuzzing, adversarial inputs, and
reproducible benchmarks. No vibes in the final claims; measurements decide.

## Phases

| phase | scope |
|---|---|
| M0 | Reference harness around the system `fnmatch()`, machine-readable corpus format, baseline benchmarks |
| M1 | Minimal matcher: literals, `?`, `*` |
| M2 | `FNM_PATHNAME` — `*`/`?`/classes must not cross `/` |
| M3 | Escapes + `FNM_NOESCAPE` |
| M4 | Bracket expressions: classes, ranges, `[!`/`[^` negation |
| M5 | `FNM_PERIOD` — leading `.` needs an explicit match |
| M6 | `FNM_CASEFOLD`, C/POSIX locale, ASCII only |
| M7–M8 | Differential campaign, adversarial study, benchmarks, C ABI |
| M9 | Optimization of measured bottlenecks only (never before compatibility is stable) |

Locale scope throughout: **C/POSIX locale**. No Unicode/collation claims.

## The oracle

Compatibility is established against a reference implementation, not
assumed. The build box (Windows + w64devkit) ships no system `fnmatch`,
so **musl libc 1.2.5 is vendored** in `compat/` and compiled into the
test harness; on POSIX hosts the same harness binds the system libc.
`compat/README.md` documents the vendoring and the two local shims.

## Corpus and gates

- **Format:** JSONL, one object per line:
  `{"pattern": "...", "string": "...", "flags": ["FNM_PATHNAME", ...], "result": "MATCH"|"NOMATCH"}`.
- **Hand vectors** (`tests/unit/m*.jsonl`): written per phase, every
  expectation validated against the oracle before it counts — musl wins
  disputes.
- **Generated corpus** (`tests/corpus/big20k.jsonl`): seeded (seed 42),
  grammar-aware generator (`scripts/gen_corpus.py`) that varies pattern
  length, wildcard/class/escape density, and flag combinations. Labels
  come from the oracle (`big20k_expected.jsonl`).
- **Gate** (`scripts/zig_gate.py`): generates a Zig test from vector
  files and runs the matcher against every one. 20,794/20,794 file-verified
  vectors agree; the live-musl differential (ref_harness) adds m0's 117 →
  20,911/20,911 (m0_baseline:55's D001 expectation is stale by design —
  musl and the matcher both MATCH there).
- **Randomized soak:** 3,000 further differential cases vs the oracle plus
  200,000 prototype-vs-production self-checks, 0 mismatches (plus 599
  committed as permanent gate vectors).
- **Divergences** (`docs/divergences.md`): every disagreement gets an
  ID, reproducer, classification (`BUG_*`, `LIBC_DIFFERENCE`,
  `SPEC_AMBIGUITY`, …) and status. Six entries, none silent.

## Benchmarks

Release builds, same machine, both sides, warmup, repeated passes,
median reported (mean/stddev/p95 recorded in `results/baseline/`).
Workload categories: literal-heavy, single/prefix/suffix/multi-star,
question-marks, brackets, pathname, fail-early, fail-late — realistic
synthetic strings (repo paths, packages, logs, deep paths).
Adversarial families (`*a*a*…*b`, `?`-chains, class variants) are kept
separate from normal workloads. Absolute numbers drift across machines;
same-session ratios are the honest comparison.

## Reproduce it

```console
$ zig build -Doptimize=ReleaseFast   # static lib (needs Zig 0.14.1)
$ zig build test                     # 39 unit tests

# conformance gate vs the oracle (build the harness first on Windows):
$ gcc -O2 -std=c11 -Wall -Wextra -o scripts/ref_harness.exe scripts/ref_harness.c compat/musl_fnmatch.c
$ python3 scripts/zig_gate.py tests/unit/*.jsonl tests/corpus/big20k_expected.jsonl

# reference-side differential on the hand corpus:
$ python3 scripts/differential.py tests/corpus/m0_baseline.jsonl --harness "scripts/ref_harness.exe --json"

# benchmarks (see bench/*_run.py --help in-file usage):
$ python3 bench/adversarial_run.py
$ python3 bench/workload_run.py
```

Pinned environment for the published numbers: i5-12400F, Windows +
w64devkit (gcc 16.2), zig 0.14.1 — see `results/baseline/env.json`.
Raw evidence for every claim lives in `results/baseline/`.
