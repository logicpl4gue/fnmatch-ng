#!/usr/bin/env python3
"""Grammar-aware fnmatch corpus generator (plan sec 17), stdlib-only + seeded.

Deterministic output; emits {"pattern","string","flags"} JSONL with no result
field (a reference harness labels results). Grammar: literal | ? | * |
class [..]/[!..] | escaped literal. Excluded: POSIX [:classes:] and bytes
>=0x80 (C-locale scope). Usage:
    python3 scripts/gen_corpus.py --count 20000 --seed 42
        --out tests/corpus/big20k.jsonl --meta results/baseline/big20k_meta.json
"""
import argparse, json, random, time
GEN_VERSION = "gen_corpus.py v2"
S = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ/.!^\\[]*?-"
LIT = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./"
CLASS_CH = "abcdefghijklmnopqrstuvwxyz0123456789."
META = "*?[\\]."
FLAGS = [([], "[]"), (["FNM_PATHNAME"], "PATHNAME"), (["FNM_NOESCAPE"], "NOESCAPE"),
         (["FNM_PERIOD"], "PERIOD"), (["FNM_CASEFOLD"], "CASEFOLD"),
         (["FNM_PATHNAME", "FNM_PERIOD"], "PATHNAME+PERIOD"),
         (["FNM_PATHNAME", "FNM_CASEFOLD"], "PATHNAME+CASEFOLD")]
W = [34] + [11] * 6

def tokens(rng, want):
    """Pattern of exactly `want` chars (1..12) + token types (for stats).

    A multi-char token that would overshoot the remaining budget is redrawn
    among single-char tokens so lengths stay exact and the token list always
    matches the pattern text.
    """
    pat, toks, rem = [], [], want
    while rem > 0:
        while True:
            r = rng.random()
            if r < 0.35:
                if rng.random() < 0.6: cand, tok = "*", "star"
                else: cand, tok = "?", "q"
            elif r < 0.53:
                if rem < 3: cand, tok = rng.choice(LIT), "lit"
                else:
                    neg = rng.random() < 0.25
                    fit = rem - (4 if neg else 3)
                    if fit < 1: neg, fit = False, rem - 3
                    n = 1 if fit <= 1 else rng.randint(1, min(4, fit))
                    cls = "[" + ("!" if neg else "") + "".join(
                        rng.choice(CLASS_CH) for _ in range(n))
                    if rng.random() < 0.20 and rem - len(cls) >= 2:
                        cls += "-" + rng.choice("az09")
                    cand, tok = cls + "]", "negclass" if neg else "class"
            elif r < 0.68:
                if rem < 2: cand, tok = rng.choice(LIT), "lit"
                else: cand, tok = "\\" + rng.choice(META), "esc"
            else:
                cand, tok = rng.choice(LIT), "lit"
            if len(cand) <= rem: break
        pat.append(cand); toks.append(tok); rem -= len(cand)
    return "".join(pat), toks

def matched(rng, flags, pat):
    """Best-effort string the pattern matches; the harness labels truth.

    Guards avoid guaranteed mismatches: no '/' for * ? classes under
    FNM_PATHNAME; no '.' at segment start under FNM_PERIOD unless raw literal
    '.' (musl raw-byte gate, D005).
    """
    pathname, period, noesc = ("FNM_PATHNAME" in flags, "FNM_PERIOD" in flags,
                               "FNM_NOESCAPE" in flags)
    out, p, n = [], 0, len(pat)
    seg = lambda: not out or out[-1] == "/"
    while p < n:
        c = pat[p]
        banned = (("/" if pathname else "") + ("." if period and seg() else ""))
        if c == "*":
            while p < n and pat[p] == "*": p += 1
            out.extend(rng.choice([x for x in S if x not in banned])
                       for _ in range(rng.randint(0, 4)))
        elif c == "?":
            out.append(rng.choice([x for x in S if x not in banned])); p += 1
        elif c == "\\" and not noesc and p + 1 < n:
            ch = pat[p + 1]
            out.append("a" if period and seg() and ch == "." else ch); p += 2
        elif c == "[":
            q = pat.find("]", p + 1)
            if q < 0: out.append("["); p += 1; continue  # unterminated (musl)
            inner = pat[p + 1:q]
            neg = inner[:1] == "!"; body = inner[1:] if neg else inner
            members, i = [], 0
            while i < len(body):
                if i + 2 < len(body) and body[i + 1] == "-":
                    lo, hi = body[i], body[i + 2]
                    members += [chr(x) for x in range(ord(lo), ord(hi) + 1)] \
                        if lo <= hi else [lo, hi]
                    i += 3
                else: members.append(body[i]); i += 1
            members = list(dict.fromkeys(members)) or ["a"]
            pool = [x for x in S if x not in members and x not in banned] if neg else \
                   [m for m in members if m not in banned]
            out.append(rng.choice(pool) if pool else "a"); p = q + 1
        else:
            out.append(c); p += 1          # literal (incl. '\' under NOESCAPE)
    return "".join(out)

def case(rng):
    flags, fname = FLAGS[rng.choices(range(len(FLAGS)), W)[0]]
    pat, toks = tokens(rng, rng.randint(1, 12))
    if rng.random() < 0.5:
        s = matched(rng, flags, pat)[:16]
    else:
        s = "".join(rng.choice(S) for _ in range(rng.randint(0, 16)))
    return {"pattern": pat, "string": s, "flags": list(flags)}, fname, toks

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="tests/corpus/big20k.jsonl")
    ap.add_argument("--meta", default="results/baseline/big20k_meta.json")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    fmix, tc, pl, sl, t0 = {}, {}, [], [], time.time()
    with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
        for _ in range(a.count):
            c, fname, toks = case(rng)
            fh.write(json.dumps(c, ensure_ascii=False) + "\n")
            fmix[fname] = fmix.get(fname, 0) + 1
            for t in toks: tc[t] = tc.get(t, 0) + 1
            pl.append(len(c["pattern"])); sl.append(len(c["string"]))
    meta = {"generator": GEN_VERSION, "count": a.count, "seed": a.seed,
            "flag_mix": dict(sorted(fmix.items())),
            "token_counts": dict(sorted(tc.items())),
            "pattern_len_chars": {"min": min(pl), "max": max(pl)},
            "string_len_chars": {"min": min(sl), "max": max(sl)},
            "alphabet": S,
            "excluded": ["POSIX [:classes:]", "bytes>=0x80 (C-locale scope)"],
            "gen_seconds": round(time.time() - t0, 3)}
    with open(a.meta, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2); fh.write("\n")
    print("wrote %d cases -> %s (%.2fs)" % (a.count, a.out, time.time() - t0))
    print("meta -> %s" % a.meta)

if __name__ == "__main__":
    main()
