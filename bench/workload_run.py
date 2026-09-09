#!/usr/bin/env python3
"""bench/workload_run.py — normal-workload benchmark (plan sections 22-25).

Pipeline:
  1. Load tests/corpus/workload.jsonl (2400 musl-validated cases with
     categories: literal-heavy, single-star, prefix-star, suffix-star,
     multi-star, question-marks, brackets, pathname, fail-early,
     fail-late).
  2. For each of 3 measurement passes:
       a. `zig run -O ReleaseFast bench/workload.zig` times the REWRITE
          (src/matcher.zig) on every case -> per-case min-of-5 ns/match.
       b. bench/adversarial_musl.exe (vendored musl 1.2.5 driver) times
          the REFERENCE per case (fresh process, ~2 ms budget, hard 5 s
          cap). A cap hit is recorded as TIMEOUT.
  3. Per-case MEDIAN over the passes, per side. Any matcher-vs-musl
     semantic disagreement is recorded (expected: none — the corpus is
     musl-validated and matcher agrees on the whole core POSIX scope).
  4. Per-category aggregates: median / mean / stddev / p95 / min / max of
     the per-case medians, both sides.
  5. Write results/baseline/workloads.json and print the category table.

Usage (from the repo root):
  export PATH="/c/zig-0.14.1/zig-x86_64-windows-0.14.1:$PATH"
  python3 bench/workload_run.py [musl_exe] [out_json]

  musl_exe default: bench/adversarial_musl.exe
  out_json  default: results/baseline/workloads.json
"""
import datetime, json, os, statistics, subprocess, sys

ZIG = os.environ.get("ZIG", "zig")
PASSES = 3
TIMEOUT_S = 5.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "tests", "corpus", "workload.jsonl")
OURS_TMP = os.path.join(ROOT, "results", "baseline", "_workload_ours.jsonl")


def run_ours():
    r = subprocess.run(
        [ZIG, "run", "-O", "ReleaseFast", "--dep", "matcher",
         "-Mroot=bench/workload.zig", "-Mmatcher=src/matcher.zig",
         "--", CORPUS, OURS_TMP],
        cwd=ROOT, capture_output=True, text=True, timeout=300,
    )
    if r.returncode != 0:
        sys.exit(f"zig run failed (rc={r.returncode}):\n{r.stdout}\n{r.stderr}")
    if r.stderr.strip():
        print(r.stderr.strip())
    with open(OURS_TMP, encoding="ascii") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def measure_musl(c):
    try:
        sub = subprocess.run(
            [musl_exe_path],
            input=json.dumps({k: c[k] for k in ("pattern", "string", "flags")})
                  + "\n",
            capture_output=True, text=True, encoding="ascii",
            timeout=TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "TIMEOUT"
    if sub.returncode != 0:
        sys.exit(f"musl driver rc={sub.returncode} on {c['category']} "
                 f"case {c['pattern']!r}/{c['string']!r}: {sub.stderr}")
    try:
        out = json.loads(sub.stdout.strip().splitlines()[-1])
        return out["ns"], out["result"]
    except (ValueError, KeyError, IndexError):
        sys.exit(f"musl driver bad output on case {c!r}: {sub.stdout!r}")


def main():
    global musl_exe_path
    musl_exe_path = sys.argv[1] if len(sys.argv) > 1 \
        else os.path.join(ROOT, "bench", "adversarial_musl.exe")
    out_json = sys.argv[2] if len(sys.argv) > 2 \
        else os.path.join(ROOT, "results", "baseline", "workloads.json")
    if not os.path.exists(musl_exe_path):
        sys.exit(f"musl driver not found: {musl_exe_path}")

    with open(CORPUS, encoding="ascii") as fh:
        cases = [json.loads(line) for line in fh if line.strip()]
    print(f"corpus: {CORPUS} ({len(cases)} cases)")

    ours_all = {i: [] for i in range(len(cases))}
    musl_all = {i: [] for i in range(len(cases))}
    mismatches = []
    timeouts = 0

    for p in range(PASSES):
        rows = run_ours()
        if len(rows) != len(cases):
            sys.exit(f"ours pass {p}: expected {len(cases)} rows, got "
                     f"{len(rows)}")
        for i, row in enumerate(rows):
            ours_all[i].append(row["ours_ns"])
            mns, mres = measure_musl(cases[i])
            musl_all[i].append(mns)
            if mns == "TIMEOUT":
                timeouts += 1
            elif mres != row["result"]:
                mismatches.append({"index": i,
                                   "category": cases[i]["category"],
                                   "pattern": cases[i]["pattern"],
                                   "string": cases[i]["string"],
                                   "ours": row["result"], "musl": mres})
        print(f"pass {p + 1}/{PASSES} done "
              f"(ours median {statistics.median(row['ours_ns'] for row in rows):.0f} ns)")

    for i, c in enumerate(cases):
        omed = statistics.median(ours_all[i])
        mvals = [m for m in musl_all[i] if m != "TIMEOUT"]
        mmed = statistics.median(mvals) if mvals else None
        c["ours_ns"] = int(round(omed))
        c["musl_ns"] = mmed
        c["musl_ns_int"] = int(round(mmed)) if mmed is not None else None

    # per-category aggregates over per-case medians
    cats = {}
    for c in cases:
        cats.setdefault(c["category"], []).append(c)
    order = ["literal-heavy", "single-star", "prefix-star", "suffix-star",
             "multi-star", "question-marks", "brackets", "pathname",
             "fail-early", "fail-late"]
    table = {}
    for cat in order:
        rows = cats.get(cat, [])
        agg = {}
        for side, key in (("ours", "ours_ns"), ("musl", "musl_ns")):
            vals = [r[key] for r in rows if r[key] is not None]
            s = sorted(vals)
            n = len(s)
            agg[side] = {
                "n": n,
                "median_ns": round(statistics.median(s), 1) if s else None,
                "mean_ns": round(statistics.mean(s), 1) if s else None,
                "stddev_ns": round(statistics.stdev(s), 1) if n > 1 else 0.0,
                "p95_ns": (s[int(0.95 * (n - 1))] if n else None),
                "min_ns": s[0] if s else None,
                "max_ns": s[-1] if s else None,
            }
        table[cat] = agg

    doc = {
        "date": datetime.date.today().isoformat(),
        "study": "normal-workload benchmark (plan sections 22-25)",
        "reference": "vendored musl 1.2.5 (compat/musl_fnmatch.c) via "
                     "bench/adversarial_musl.exe",
        "ours": "src/matcher.zig, zig 0.14.1, ReleaseFast",
        "method": {
            "ours": "warmup + 5 timed runs, >=1024 iters, ~1ms budget, "
                    "min ns/match; reported = median over 3 passes",
            "musl": "fresh process per case, probe then batches to ~2ms, "
                    "hard 5s cap; reported = median over 3 passes",
        },
        "passes": PASSES,
        "timeout_cap_s": TIMEOUT_S,
        "corpus": os.path.relpath(CORPUS, ROOT).replace("\\", "/"),
        "corpus_gen": "scripts/gen_workload.py seed 7 "
                      "(results/baseline/workload_meta.json)",
        "case_count": len(cases),
        "timeouts": timeouts,
        "semantic_mismatches": mismatches,
        "categories": table,
    }
    with open(out_json, "w", encoding="ascii") as fh:
        json.dump(doc, fh, indent=1, sort_keys=False)
    print(f"wrote {os.path.relpath(out_json, ROOT)}")

    print(f"\n{'category':<16}{'n':>5} {'ours-med':>9} {'ours-mean':>10} "
          f"{'ours-p95':>9} {'musl-med':>9} {'musl-mean':>10} {'musl-p95':>9} "
          f"{'ours/musl':>9}")
    print("-" * 90)
    for cat in order:
        o, m = table[cat]["ours"], table[cat]["musl"]
        if o["median_ns"] and m["median_ns"]:
            ratio = o["median_ns"] / m["median_ns"]
            r = f"{ratio:.2f}x"
        else:
            r = "-"
        print(f"{cat:<16}{o['n']:>5} {o['median_ns']:>9.1f} "
              f"{o['mean_ns']:>10.1f} {o['p95_ns']:>9} "
              f"{m['median_ns']:>9.1f} {m['mean_ns']:>10.1f} "
              f"{m['p95_ns']:>9} {r:>9}")
    if timeouts:
        print(f"\nWARNING {timeouts} musl timeouts recorded")
    if mismatches:
        print(f"\nWARNING {len(mismatches)} matcher-vs-musl semantic "
              f"mismatches (first 3): {mismatches[:3]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
