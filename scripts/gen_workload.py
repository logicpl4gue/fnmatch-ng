#!/usr/bin/env python3
"""scripts/gen_workload.py — realistic normal-workload benchmark corpus
(plan sections 22-23), stdlib-only, deterministic (seed 7).

Emits tests/corpus/workload.jsonl:
    {"pattern": ..., "string": ..., "flags": [...], "category": ...}
with ~2400 cases across the plan section-22 categories (240 each):
    literal-heavy single-star prefix-star suffix-star multi-star
    question-marks brackets pathname fail-early fail-late
Strings come from realistic synthetic styles (section 23): linux-style
paths, repo paths, package filenames, log filenames, short names, deep
paths.

Every case expectation is validated against vendored musl
(scripts/ref_harness.exe --json) BEFORE the corpus is used for timing.
Fix rule: musl wins — a case whose constructed expectation disagrees with
musl is regenerated from fresh draws of the seeded stream until it agrees
(per-case attempt cap), so the emitted corpus is 100% musl-consistent.

"flags" is [] except the pathname category, which uses ["FNM_PATHNAME"].

Usage:
    python3 scripts/gen_workload.py [--cases 2400] [--seed 7]
Writes:
    tests/corpus/workload.jsonl
    results/baseline/workload_meta.json
"""
import argparse, json, os, random, subprocess, sys

GEN_VERSION = "gen_workload.py v1"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "tests", "corpus", "workload.jsonl")
META = os.path.join(ROOT, "results", "baseline", "workload_meta.json")
HARNESS = os.path.join(ROOT, "scripts", "ref_harness.exe")
MAX_FIX_ATTEMPTS = 60

# ---- realistic string material (section 23) ---------------------------------
LC = "abcdefghijklmnopqrstuvwxyz"
DIG = "0123456789"
SRC_NAMES = ["main", "app", "parser", "lexer", "compiler", "runtime", "config",
             "util", "utils", "server", "client", "index", "handler", "model",
             "view", "worker", "daemon", "manager", "store", "loader",
             "scanner", "tokenizer", "test_main", "test_util", "make",
             "install", "setup", "build", "README", "LICENSE", "CHANGELOG"]
SRC_EXTS = ["c", "h", "py", "sh", "zig", "rs", "go", "cpp", "hpp", "js", "ts",
            "json", "md", "txt", "toml", "yaml", "css", "html"]
PKGS = ["libssl1.1", "python3", "gcc", "glibc", "curl", "openssl", "zlib",
        "ffmpeg", "nginx", "postgresql", "nodejs", "rustc", "vim", "bash",
        "coreutils", "util-linux", "systemd", "gdb", "git", "perl"]
VERS = ["1.1.1", "3.11.2", "2.38.1", "8.1.2", "0.4.1", "20.0.0", "12.2", "7.0.9",
        "1.2.11", "5.6.3", "6.1.1", "2.4.7"]
PKG_FLAV = ["", "", "", "1.fc38", "1.el9", "1ubuntu1", "1_amd64", "1_x86_64"]
PKG_EXT = ["deb", "rpm", "tar.gz", "tgz", "zip", "tar.xz"]
LOG_PRE = ["app", "error", "access", "debug", "syslog", "journal", "audit",
           "cron", "dmesg", "auth", "kernel"]
LOG_POST = ["log", "log.1", "log.gz", "txt"]
DIRS = ["src", "lib", "include", "tests", "bin", "build", "obj", "docs", "app",
        "core", "utils", "net", "db", "ui", "vendor", "node_modules", "pkg",
        "dist", "var", "log", "home", "opt", "etc", "usr", "local", "share",
        "tmp", "cache", "run", "systemd", "proc", "dev", "mnt"]
ROOTS = ["/usr/local", "/usr/lib", "/var/log", "/etc", "/opt", "/home/user",
         "/srv/www", "/bin"]
SUFFIXES = ["parser.c", "main.c", "_test.py", "core", "main.rs", ".tar.gz",
            "-debug.log", "index.html", "config.json", "setup.sh"]
PREFIXES = ["src", "lib", "tests", "docs", "build", "app", "/usr/lib",
            "/opt/app", "var/log", "home/user/proj"]
STYLES = ["linux", "repo", "package", "log", "short", "deep"]
STYLE_W = [5, 4, 2, 2, 2, 2]
ALLOWED = LC + DIG  # bytes allowed where a wildcard must align with a class


def pick(rng, seq):
    return rng.choice(seq)


def pick_style(rng):
    return rng.choices(STYLES, weights=STYLE_W, k=1)[0]


def rng_str(rng, chars, lo, hi):
    return "".join(rng.choice(chars) for _ in range(rng.randint(lo, hi)))


def short_name(rng):
    """Slash-free realistic file name."""
    n = pick(rng, SRC_NAMES)
    return n + "." + pick(rng, SRC_EXTS) if rng.random() < 0.85 else n


def dir_path(rng, depth, rooted=False):
    parts = "/".join(pick(rng, DIRS) for _ in range(depth))
    base = (parts + "/") if parts else ""
    return (pick(rng, ROOTS) + "/" if rooted else "") + base + short_name(rng)


def make_string(rng, style):
    if style == "linux":
        return dir_path(rng, rng.randint(0, 2), rooted=True)
    if style == "repo":
        return dir_path(rng, rng.randint(1, 3), rooted=False)
    if style == "package":
        return pick(rng, PKGS) + "-" + pick(rng, VERS) + pick(rng, PKG_FLAV) \
            + "." + pick(rng, PKG_EXT)
    if style == "log":
        return "%s-%04d-%02d-%02d.%s" % (pick(rng, LOG_PRE),
                                         rng.randint(2000, 2026),
                                         rng.randint(1, 12), rng.randint(1, 28),
                                         pick(rng, LOG_POST))
    if style == "short":
        return short_name(rng)
    if style == "deep":
        return dir_path(rng, rng.randint(4, 9), rooted=rng.random() < 0.5)
    raise ValueError(style)


def split_dir(s):
    d, _, _ = s.rpartition("/")
    return d + "/" if d else ""


# ---- per-category constructors: return (pattern, string, flags, want) -------
def gen_literal(rng):
    s = make_string(rng, pick_style(rng))
    if len(s) < 4:
        s = short_name(rng)
    return s, s, [], "MATCH"


def gen_single_star(rng):
    ext = pick(rng, ["c", "h", "py", "log", "so", "a", "o", "deb", "txt", "md",
                     "rs", "go"])
    stem = rng_str(rng, LC + DIG + "._-", 2, 12)
    s = split_dir(make_string(rng, pick(rng, ["repo", "linux", "short"]))) \
        + stem + "." + ext
    return "*." + ext, s, [], "MATCH"


def gen_prefix_star(rng):
    pre = pick(rng, PREFIXES)
    s = pre + "/" + make_string(rng, pick(rng, ["repo", "linux", "short", "log"]))
    return pre + "/*", s, [], "MATCH"


def gen_suffix_star(rng):
    suf = pick(rng, SUFFIXES)
    stem = rng_str(rng, LC + DIG + "._-", 2, 12)
    s = split_dir(make_string(rng, pick(rng, ["repo", "linux", "short"]))) \
        + stem + suf
    return "*" + suf, s, [], "MATCH"


def gen_multi_star(rng):
    # pattern  l0 /* seg1 [/ mid1] /* seg2 ... / tail    (all segments slash-free)
    l0 = pick(rng, ["src", "lib", "tests", "vendor", "/usr/local/lib", "docs"])
    stars = rng.randint(1, 3)
    tail = pick(rng, SRC_NAMES) + "." + pick(rng, ["c", "py", "rs", "go", "h"])
    mids = [pick(rng, ["src", "test", "lib", "obj", "gen", "core", "mod"])
            for _ in range(stars)]
    pat = l0
    s = l0
    for i in range(stars):
        seg = pick(rng, DIRS)
        pat += "/*"
        s += "/" + seg
        if i < stars - 1 or rng.random() < 0.5:
            pat += "/" + mids[i]
            s += "/" + mids[i]
    pat += "/" + tail
    s += "/" + tail
    return pat, s, [], "MATCH"


def gen_question_marks(rng):
    pre = pick(rng, ["file-", "log-", "backup-", "img-", "srv-", "db-", "vm-"])
    post = pick(rng, [".log", ".txt", ".bin", ".dat", "", ".gz"])
    k = rng.randint(2, 6)
    s = pre + rng_str(rng, ALLOWED, k, k) + post
    return pre + "?" * k + post, s, [], "MATCH"


BRACKET_BODIES = [("[0-9]", DIG), ("[a-z]", LC), ("[p-z]", "pqrstuvwxyz"),
                  ("[a-z0-9]", LC + DIG), ("[0-9a-f]", "0123456789abcdef")]


def gen_brackets(rng):
    kind = rng.random()
    if kind < 0.4:
        # file-[0-9][0-9].log
        cls, chset = pick(rng, BRACKET_BODIES)
        k = rng.randint(1, 3)
        pre = pick(rng, ["file-", "img-", "snap-", ""])
        post = pick(rng, [".log", ".dat", ".img", ""])
        s = pre + rng_str(rng, chset, k, k) + post
        return pre + cls * k + post, s, [], "MATCH"
    if kind < 0.6:
        # lib[0-9]*.so
        cls, chset = pick(rng, BRACKET_BODIES[0:3])
        pre = pick(rng, ["lib", "v", "x", "coreutils-"])
        tail = pick(rng, [".so", ".a", ".dll", ""])
        s = pre + rng.choice(chset) + rng_str(rng, LC + DIG, 0, 6) + tail
        return pre + cls + "*" + tail, s, [], "MATCH"
    if kind < 0.8:
        # *.[ch] — class over the extension's first char
        ext = pick(rng, ["c", "h", "o"])
        stem = rng_str(rng, LC, 2, 8)
        s = split_dir(make_string(rng, pick(rng, ["repo", "short"]))) \
            + stem + "." + ext
        return "*.[" + ext + "]", s, [], "MATCH"
    # [!x]* — negated head class, string never starts with the banned char
    banned = pick(rng, ["q", "x", "0", "z", "j"])
    first = rng.choice([ch for ch in ALLOWED if ch != banned])
    s = first + rng_str(rng, LC + DIG + "._-", 1, 10)
    return "[!" + banned + "]*", s, [], "MATCH"


def gen_pathname(rng):
    kind = rng.random()
    if kind < 0.25:
        s = make_string(rng, pick(rng, ["linux", "deep"]))
        if "/" not in s:
            s = make_string(rng, "deep")
        return s, s, ["FNM_PATHNAME"], "MATCH"
    if kind < 0.5:
        # */last-segment matches exactly one level above
        last = short_name(rng)
        s = pick(rng, DIRS) + "/" + last
        return "*/" + last, s, ["FNM_PATHNAME"], "MATCH"
    if kind < 0.75:
        pre = pick(rng, ["src", "lib", "tests", "docs"])
        leaf = short_name(rng)
        if rng.random() < 0.5:
            return pre + "/*", pre + "/" + leaf, ["FNM_PATHNAME"], "MATCH"
        return pre + "/*", pre + "/" + pick(rng, DIRS) + "/" + leaf, \
            ["FNM_PATHNAME"], "NOMATCH"
    if rng.random() < 0.5:
        # "*" cannot cross a slash under FNM_PATHNAME
        return "*", pick(rng, DIRS) + "/" + short_name(rng), \
            ["FNM_PATHNAME"], "NOMATCH"
    return "*", rng_str(rng, LC + DIG + "._-", 1, 12), ["FNM_PATHNAME"], "MATCH"


def gen_fail_early(rng):
    pre = pick(rng, ["build/", "cache/", "/tmp/", "zz", "qq", "dist/"])
    bad0 = pre.lstrip("/")[0]
    for _ in range(50):
        s = make_string(rng, pick(rng, ["repo", "linux", "short"]))
        if not s.startswith(bad0):
            break
    else:
        s = "a" + rng_str(rng, LC + DIG + "._-", 3, 12)
    tail = "*" if rng.random() < 0.6 else short_name(rng)
    return pre + tail, s, [], "NOMATCH"


def gen_fail_late(rng):
    # a suffix-star match broken by one wrong trailing byte: the '*' scans the
    # whole string, the literal tail fails on its final character.
    suf = pick(rng, SUFFIXES)
    stem = rng_str(rng, LC + DIG + "._-", 2, 12)
    s = split_dir(make_string(rng, pick(rng, ["repo", "linux", "short"]))) \
        + stem + suf + "x"
    return "*" + suf, s, [], "NOMATCH"


GENS = {
    "literal-heavy": gen_literal,
    "single-star": gen_single_star,
    "prefix-star": gen_prefix_star,
    "suffix-star": gen_suffix_star,
    "multi-star": gen_multi_star,
    "question-marks": gen_question_marks,
    "brackets": gen_brackets,
    "pathname": gen_pathname,
    "fail-early": gen_fail_early,
    "fail-late": gen_fail_late,
}
CATS = list(GENS)


def run_musl(cases):
    """Validate all cases in one batch via scripts/ref_harness.exe --json."""
    tmp_in = os.path.join(ROOT, "results", "baseline", "_wload_val_in.jsonl")
    tmp_out = os.path.join(ROOT, "results", "baseline", "_wload_val_out.jsonl")
    with open(tmp_in, "w", encoding="ascii") as fh:
        for c in cases:
            fh.write(json.dumps(c, ensure_ascii=True) + "\n")
    with open(tmp_in, "rb") as fin, open(tmp_out, "wb") as fout:
        subprocess.run([HARNESS, "--json"], stdin=fin, stdout=fout, check=True)
    with open(tmp_out, encoding="ascii") as fh:
        out = [json.loads(line)["result"] for line in fh if line.strip()]
    os.remove(tmp_in)
    os.remove(tmp_out)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=2400)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    per = args.cases // len(CATS)

    cases = []
    for cat in CATS:
        for _ in range(per):
            p, s, fl, want = GENS[cat](rng)
            cases.append({"pattern": p, "string": s, "flags": fl,
                          "category": cat, "want": want})

    results = run_musl(cases)
    mismatch = [i for i, (c, got) in enumerate(zip(cases, results))
                if got != c["want"]]
    print(f"initial: {len(cases)} cases, {len(mismatch)} expectation "
          f"mismatches vs musl")

    repaired = 0
    for i in list(mismatch):
        cat = cases[i]["category"]
        for _attempt in range(MAX_FIX_ATTEMPTS):
            p, s, fl, want = GENS[cat](rng)
            got = run_musl([{"pattern": p, "string": s, "flags": fl}])[0]
            if got == want:
                cases[i] = {"pattern": p, "string": s, "flags": fl,
                            "category": cat, "want": want}
                repaired += 1
                break
        else:
            print(f"WARN: unfixable {cat} case after {MAX_FIX_ATTEMPTS} "
                  f"attempts; dropping to keep corpus 100% musl-consistent")
            cases[i] = None
    cases = [c for c in cases if c]

    # final full re-validation must be 100% clean
    results = run_musl(cases)
    bad = [(c["category"], c["pattern"], c["string"], c["want"], got)
           for c, got in zip(cases, results) if got != c["want"]]
    if bad:
        sys.exit("INTERNAL ERROR: %d cases disagree after repair, first: %r"
                 % (len(bad), bad[0]))

    cat_counts = {}
    with open(CORPUS, "w", encoding="ascii") as fh:
        for c in cases:
            cat_counts[c["category"]] = cat_counts.get(c["category"], 0) + 1
            fh.write(json.dumps({"pattern": c["pattern"], "string": c["string"],
                                 "flags": c["flags"],
                                 "category": c["category"]},
                                ensure_ascii=True) + "\n")

    meta = {
        "date": "2026-09-09",
        "generator": GEN_VERSION,
        "seed": args.seed,
        "case_count": len(cases),
        "categories_per_target": per,
        "category_counts": cat_counts,
        "musl_validation": {
            "reference": "vendored musl 1.2.5 via scripts/ref_harness.exe --json",
            "initial_mismatches": len(mismatch),
            "repaired": repaired,
            "final": "100% agree (verified before timing use)",
        },
        "string_styles": {"styles": STYLES, "weights": STYLE_W},
        "corpus_file": os.path.relpath(CORPUS, ROOT).replace("\\", "/"),
    }
    with open(META, "w", encoding="ascii") as fh:
        json.dump(meta, fh, indent=1, sort_keys=False)
    print(f"wrote {os.path.relpath(CORPUS, ROOT)} ({len(cases)} cases)")
    print(f"wrote {os.path.relpath(META, ROOT)}")
    print("category_counts:", json.dumps(cat_counts, sort_keys=True))


if __name__ == "__main__":
    main()
