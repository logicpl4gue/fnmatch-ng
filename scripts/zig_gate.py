#!/usr/bin/env python3
"""Gate: check src/matcher.zig against JSONL vectors via generated `zig test`.

Usage: python3 scripts/zig_gate.py tests/unit/m1_minimal.jsonl [more.jsonl ...]
Parses {pattern,string,flags,result}, emits a temp Zig test that calls
matchesFlags with the supported flag bits, runs `zig test` on it.
Exit 0 = all agree, 1 = mismatch or runner failure.
"""
import json, os, subprocess, sys, tempfile

FLAG_BITS = {"FNM_PATHNAME": "m.FNM_PATHNAME", "FNM_NOESCAPE": "m.FNM_NOESCAPE", "FNM_PERIOD": "m.FNM_PERIOD", "FNM_CASEFOLD": "m.FNM_CASEFOLD"}  # names the matcher supports
ZIG = os.environ.get("ZIG", "zig")

def zesc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def main(files):
    cases = []
    for f in files:
        with open(f, encoding="utf-8") as fh:
            for ln, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                c = json.loads(line)
                flags = c.get("flags", [])
                unknown = [fl for fl in flags if fl not in FLAG_BITS]
                if unknown:
                    print(f"SKIP {f}:{ln} unsupported flags {unknown}")
                    continue
                bits = " | ".join([f"m.{n}" for n in flags]) if flags else "0"
                want = "true" if c["result"] == "MATCH" else "false"
                cases.append((f, ln, c["pattern"], c["string"], bits, want))
    lines = [
        'const m = @import("matcher");',
        'const expect = @import("std").testing.expect;',
        'test "zig_gate vectors" {',
    ]
    for f, ln, pat, s, bits, want in cases:
        lines.append(
            f'    try expect(m.matchesFlags("{zesc(pat)}", "{zesc(s)}", {bits}) == {want}); // {f}:{ln}'
        )
    lines.append("}")
    with tempfile.TemporaryDirectory() as td:
        gen = os.path.join(td, "gate_test.zig")
        with open(gen, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        # run alongside src/ so @import("matcher") resolves via --pkg? use test file that includes matcher relatively:
        src = os.path.join("fnmatch-ng" if os.path.exists("fnmatch-ng/src/matcher.zig") else ".", "src", "matcher.zig")
        root = os.path.join("fnmatch-ng" if os.path.exists("fnmatch-ng/src/matcher.zig") else ".")
        # simplest: put generated test in src dir temporarily
        import shutil
        placed = os.path.join(root, "src", "gate_test_tmp.zig")
        shutil.copy(gen, placed)
        try:
            with open(placed, "r+", encoding="utf-8") as fh:
                body = fh.read().replace('@import("matcher")', '@import("matcher.zig")')
                fh.seek(0)
                fh.write(body)
                fh.truncate()
            r = subprocess.run([ZIG, "test", placed], capture_output=True, text=True)
            print(r.stdout[-2000:] if r.stdout else "")
            print(r.stderr[-2000:] if r.stderr else "", file=sys.stderr)
        finally:
            os.remove(placed)
    # report: zig build test runs ALL tests incl. gate; green means vectors agree
    print(f"vectors checked: {len(cases)}")
    return r.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["tests/unit/m1_minimal.jsonl"]))
