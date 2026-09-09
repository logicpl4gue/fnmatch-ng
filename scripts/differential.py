#!/usr/bin/env python3
"""differential.py -- compare a reference fnmatch harness against corpus results.

Harness protocol (corpus format is the contract):
  corpus : JSONL, one object per line:
           {"pattern": "...", "string": "...",
            "flags": ["FNM_PATHNAME", ...], "result": "MATCH"|"NOMATCH"}
  harness: executable that reads one JSON object per line on stdin
           {"pattern": "...", "string": "...", "flags": [...]}
           and writes one JSON object per line on stdout
           {"result": "MATCH"|"NOMATCH"}          (order preserved).
           The M0 reference harness wraps the system fnmatch(); see
           tests/corpus/README or the plan for how flags map to bits.

Usage:
  python3 scripts/differential.py [corpus.jsonl ...] [--harness PATH]

  corpus  default: <repo>/tests/corpus/m0_baseline.jsonl
  harness resolution: --harness CMD, else $REF_HARNESS, else "ref_harness"
          found on PATH. CMD may be a command line ("python3 tools/h.py").
          When no harness exists yet (M0), run this script with a stub that
          answers every case to see the machinery end-to-end.

Exit status:
  0  harness results match every expected result
  1  at least one divergence (listed with the table)
  2  usage / corpus / harness error

Stdlib only.
"""

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
from collections import Counter

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CORPUS = os.path.join(REPO_ROOT, "tests", "corpus", "m0_baseline.jsonl")
VALID_RESULTS = ("MATCH", "NOMATCH")


def load_cases(path):
    """Parse corpus JSONL into list of dicts. Raises ValueError on schema breaks."""
    cases = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                raise ValueError("%s:%d: bad JSON: %s" % (path, lineno, e))
            if set(obj) != {"pattern", "string", "flags", "result"}:
                raise ValueError("%s:%d: keys must be exactly "
                                 "{pattern,string,flags,result}: %r" % (path, lineno, obj))
            if not isinstance(obj["flags"], list) or \
               not all(isinstance(x, str) for x in obj["flags"]):
                raise ValueError("%s:%d: flags must be a list of strings" % (path, lineno))
            if obj["result"] not in VALID_RESULTS:
                raise ValueError("%s:%d: result must be MATCH|NOMATCH, got %r"
                                 % (path, lineno, obj["result"]))
            cases.append(obj)
    return cases


def find_harness(explicit):
    if explicit:
        return explicit
    env = os.environ.get("REF_HARNESS")
    if env:
        return env
    return shutil.which("ref_harness")


def run_harness(harness, cases):
    """Feed cases to the harness, return list of {"result": ...} in order."""
    payload = "".join(
        json.dumps({"pattern": c["pattern"], "string": c["string"],
                    "flags": c["flags"]}, ensure_ascii=False) + "\n"
        for c in cases
    )
    cmd = shlex.split(harness)
    proc = subprocess.run(cmd, input=payload, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("harness %r exited %d:\n%s"
                           % (harness, proc.returncode, proc.stderr.strip()))
    results = []
    for lineno, line in enumerate(proc.stdout.splitlines(), 1):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as e:
            raise RuntimeError("harness stdout line %d is not JSON: %s\n%r"
                               % (lineno, e, line))
        if obj.get("result") not in VALID_RESULTS:
            raise RuntimeError("harness stdout line %d: bad result %r"
                               % (lineno, obj.get("result")))
        results.append(obj)
    if len(results) != len(cases):
        raise RuntimeError("harness answered %d cases, expected %d"
                           % (len(results), len(cases)))
    return results


def fmt_flags(flags):
    return "[%s]" % ",".join(flags) if flags else "[]"


def main(argv):
    ap = argparse.ArgumentParser(
        description="Compare reference fnmatch harness output vs corpus expectations.")
    ap.add_argument("corpus", nargs="*", default=[DEFAULT_CORPUS],
                    help="corpus JSONL file(s) (default: tests/corpus/m0_baseline.jsonl)")
    ap.add_argument("--harness", default=None,
                    help="reference harness executable (default: $REF_HARNESS or ref_harness on PATH)")
    args = ap.parse_args(argv)

    harness = find_harness(args.harness)
    if not harness:
        print("error: no reference harness found.\n"
              "  Pass one with --harness PATH, set $REF_HARNESS, or build the M0\n"
              "  harness as 'ref_harness' (system fnmatch wrapper) and put it on PATH.\n"
              "  Harness protocol: read JSONL {pattern,string,flags} on stdin, write\n"
              "  JSONL {result: MATCH|NOMATCH} on stdout.", file=sys.stderr)
        return 2

    all_cases = []
    for path in args.corpus:
        try:
            all_cases.extend(load_cases(path))
        except ValueError as e:
            print("error: %s" % e, file=sys.stderr)
            return 2
    if not all_cases:
        print("error: corpus is empty", file=sys.stderr)
        return 2

    try:
        actual = run_harness(harness, all_cases)
    except (OSError, RuntimeError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 2

    divergences = []
    by_flags = Counter()
    agree_by_flags = Counter()
    for idx, (case, act) in enumerate(zip(all_cases, actual), 1):
        key = tuple(case["flags"])
        by_flags[key] += 1
        if act["result"] == case["result"]:
            agree_by_flags[key] += 1
        else:
            divergences.append((idx, case, act["result"]))

    total = len(all_cases)
    n_div = len(divergences)
    n_agree = total - n_div
    rate = (100.0 * n_agree / total) if total else 0.0

    print("CORPUS: %s" % ", ".join(args.corpus))
    print("HARNESS: %s" % harness)
    print("total=%d  agreements=%d  divergences=%d  agreement_rate=%.4f%%\n"
          % (total, n_agree, n_div, rate))

    print("%-40s %7s %8s %9s" % ("flags", "cases", "agree", "diverge"))
    print("-" * 68)
    for key in sorted(by_flags, key=lambda k: (len(k), k)):
        n = by_flags[key]
        a = agree_by_flags[key]
        print("%-40s %7d %8d %9d" % (fmt_flags(list(key)), n, a, n - a))
    print()

    if divergences:
        print("DIVERGENCES (%d):" % n_div)
        for idx, case, actual in divergences:
            print("  #%d pattern=%r string=%r flags=%s expected=%s actual=%s"
                  % (idx, case["pattern"], case["string"],
                     fmt_flags(case["flags"]), case["result"], actual))
        return 1
    print("OK: no divergences.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
