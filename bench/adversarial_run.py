#!/usr/bin/env python3
"""bench/adversarial_run.py — orchestrates the adversarial complexity study
(plan section 21) and writes results/baseline/adversarial.json.

Pipeline:
  1. For each of 3 measurement passes:
       a. `zig run -O ReleaseFast ... bench/adversarial.zig -- <cases.jsonl>`
          times the REWRITE (src/matcher.zig) on every case and emits JSONL.
       b. Spawn bench/adversarial_musl.exe once per case with a hard 5 s
          wall-clock cap (subprocess timeout). A cap hit is data: recorded
          as "TIMEOUT" instead of hanging the run.
  2. Per-case MEDIAN over the 3 passes (per-case min-of-5 within a pass
     still swings ~30% on rewind-heavy cases, so medians are reported).
  3. Write results/baseline/adversarial.json and print the scaling table.

Usage:
  export PATH="/c/zig-0.14.1/zig-x86_64-windows-0.14.1:$PATH"
  python3 bench/adversarial_run.py [musl_exe] [out_json]

  musl_exe default: bench/adversarial_musl.exe
  out_json  default: results/baseline/adversarial.json
"""
import datetime, json, os, statistics, subprocess, sys

ZIG = os.environ.get("ZIG", "zig")
TIMEOUT_S = 5.0
PASSES = 3
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "results", "baseline", "adversarial_cases.jsonl")


def run_ours():
    r = subprocess.run(
        [ZIG, "run", "-O", "ReleaseFast", "--dep", "matcher",
         "-Mroot=bench/adversarial.zig", "-Mmatcher=src/matcher.zig",
         "--", CASES],
        cwd=ROOT, capture_output=True, text=True, timeout=300,
    )
    if r.returncode != 0:
        sys.exit(f"zig run failed (rc={r.returncode}):\n{r.stdout}\n{r.stderr}")
    return r


def load_cases():
    with open(CASES, encoding="ascii") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def measure_musl(c):
    """Run the musl driver once for case c; returns (ns_or_TIMEOUT, result)."""
    try:
        sub = subprocess.run(
            # ref_harness's parser only skips STRING-valued unknown keys
            # (see skip_value), so send just the keys it understands.
            [musl_exe_path], input=json.dumps({k: c[k] for k in ("pattern", "string", "flags")}) + "\n",
            capture_output=True, text=True, encoding="ascii", timeout=TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "TIMEOUT"
    if sub.returncode != 0:
        sys.exit(f"musl driver rc={sub.returncode} on case {c!r}: {sub.stderr}")
    try:
        out = json.loads(sub.stdout.strip().splitlines()[-1])
        return out["ns"], out["result"]
    except (ValueError, KeyError):
        sys.exit(f"musl driver bad output on case {c!r}: {sub.stdout!r}")


def main():
    global musl_exe_path
    musl_exe_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "bench", "adversarial_musl.exe")
    out_json = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "results", "baseline", "adversarial.json")
    if not os.path.exists(musl_exe_path):
        sys.exit(f"musl driver not found: {musl_exe_path}")

    # pass 1: establish the case list + ours numbers
    r = run_ours()
    if r.stderr.strip():
        print(r.stderr.strip())
    cases = load_cases()
    ours_all = {i: [c["ours_ns"]] for i, c in enumerate(cases)}
    musl_all = {i: [] for i in range(len(cases))}
    mismatches = []
    timeouts = 0

    for i, c in enumerate(cases):
        mns, mres = measure_musl(c)
        musl_all[i].append(mns)
        if mns == "TIMEOUT":
            timeouts += 1
        elif mres != c["result"]:
            mismatches.append({"family": c["family"], "k": c["k"], "n": c["n"],
                               "ours": c["result"], "musl": mres})

    for _ in range(1, PASSES):
        r = run_ours()
        if r.stderr.strip():
            print(r.stderr.strip())
        fresh = load_cases()
        for i, c in enumerate(fresh):
            ours_all[i].append(c["ours_ns"])
            mns, mres = measure_musl(c)
            musl_all[i].append(mns)
            if mns == "TIMEOUT":
                timeouts += 1
            elif mres != c["result"]:
                mismatches.append({"family": c["family"], "k": c["k"], "n": c["n"],
                                   "ours": c["result"], "musl": mres})

    for i, c in enumerate(cases):
        c["ours_ns"] = int(round(statistics.median(ours_all[i])))
        c["musl_ns"] = statistics.median([m for m in musl_all[i] if m != "TIMEOUT"]) \
            if any(m == "TIMEOUT" for m in musl_all[i]) else int(round(statistics.median(musl_all[i])))
        c["musl_result"] = None

    doc = {
        "date": datetime.date.today().isoformat(),
        "study": "adversarial complexity (plan section 21)",
        "reference": "vendored musl 1.2.5 (compat/musl_fnmatch.c)",
        "ours": "src/matcher.zig, zig 0.14.1, ReleaseFast",
        "flags": 0,
        "method": {
            "ours": "warmup + 5 timed runs, >=1000 iters each, ~1ms budget/run, min ns/match; reported value = median over 3 passes",
            "musl": "fresh process per case, single-call probe, batches to ~2ms, hard 5s external cap; reported value = median over 3 passes",
        },
        "passes": PASSES,
        "timeout_cap_s": TIMEOUT_S,
        "families": {
            "A": '"*a"*k+"*b" vs "a"*n (failing)',
            "B": '"*a"*k+"*b" vs "a"*n+"b" (matching, n>=k)',
            "C": '"?"*n vs "a"*n+"b" (failing)',
            "D": '"*[a]"*k+"*b" vs "a"*n (failing)',
            "E": '"*[a]"*k+"*b" vs "a"*n+"b" (matching, n>=k)',
        },
        "k_range": "2..10",
        "n_values": [8, 16, 24, 32, 40, 48, 56, 64],
        "case_count": len(cases),
        "timeouts": timeouts,
        "semantic_mismatches": mismatches,
        "cases": cases,
    }
    with open(out_json, "w", encoding="ascii") as fh:
        json.dump(doc, fh, indent=1, sort_keys=False)
    print(f"wrote {out_json}")

    # ---- scaling table (median over passes; largest n per (family,k)) ----
    print(f"\n{'fam':>3} {'k':>3} {'n':>4} {'plen':>5} {'slen':>5} "
          f"{'ours':>9} {'musl':>9}")
    for fam in "ABCDE":
        rows = [c for c in cases if c["family"] == fam]
        by_k = {}
        for c in rows:
            by_k.setdefault(c["k"], []).append(c)
        for k in sorted(by_k):
            row = max(by_k[k], key=lambda c: c["n"])
            m = row["musl_ns"] if row.get("musl_ns") is not None else "TIMEOUT"
            print(f"{fam:>3} {k:>3} {row['n']:>4} {row['pattern_len']:>5} "
                  f"{row['string_len']:>5} {row['ours_ns']:>9} {str(m):>9}")
    # scaling ratio: ns at max n vs min n for k=10 (per family with rows)
    print("\nscaling at k=10, smallest n -> largest n (input grew 8x):")
    for fam in "ABCDE":
        rows = [c for c in cases if c["family"] == fam and c["k"] == 10]
        if not rows:
            continue
        lo = min(rows, key=lambda c: c["n"])
        hi = max(rows, key=lambda c: c["n"])
        if isinstance(lo["musl_ns"], (int, float)) and isinstance(hi["musl_ns"], (int, float)):
            mnote = f"{hi['musl_ns'] / max(lo['musl_ns'], 1e-9):.2f}x"
        else:
            mnote = "TIMEOUT involved"
        print(f"  {fam}: ours {lo['ours_ns']} -> {hi['ours_ns']} "
              f"({hi['ours_ns'] / max(lo['ours_ns'], 1e-9):.2f}x), "
              f"musl {lo['musl_ns']} -> {hi['musl_ns']} ({mnote})")
    if mismatches:
        print(f"\nWARNING {len(mismatches)} semantic mismatches: {mismatches[:5]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
