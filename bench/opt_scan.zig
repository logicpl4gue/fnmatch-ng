// bench/opt_scan.zig — fnmatch-ng optimization prototypes (M9 perf audit).
//
// Prototypes measured here (all against src/matcher.zig as the correctness
// reference and speed baseline):
//
//   (a) LITERAL-RUN tokens: the pattern is compiled ONCE per match into a
//       token array (stack, 0 heap allocs). Runs of consecutive raw literal
//       bytes become ONE .run token consumed with a single bulk slice
//       compare (std.mem.eql -> memcmp) instead of per-byte dispatch.
//   (b) TAIL-ANCHOR: when the pattern's LAST '*' is followed only by a raw
//       literal run of length m>0 (no more stars/?/classes/escapes), the
//       greedy matcher must consume exactly the string's final m bytes with
//       that run. So: endswith check first (fast reject), then recurse on
//       pattern[0..star+1] (which now ENDS in '*') against the shortened
//       string. Recursion depth <= 1 (stripping one tail exposes a final
//       star, which has no tail).
//   (c) STAR->RUN JUMP (flags plain: no PATHNAME/PERIOD/CASEFOLD): when a
//       match attempt fails and the token right after the last '*' is a raw
//       literal run starting with byte c0, the next viable candidate must
//       START with c0, so scan forward with indexOfScalar (memchr) instead
//       of advancing one byte at a time.
//   (d) STAR-LAST absorb shortcut (plain): if the final token is '*', it
//       absorbs the whole remaining string in one jump instead of one-byte
//       rewind steps.
//   (e) CLASS-TOKEN caching: a bracket expression is tokenized once during
//       compile; the per-byte match loop no longer re-runs scanClass() and
//       re-derives the class content slice on every byte tested.
//   (f) FLAG hoisting: pathname/period/folding/noescape are read once into
//       booleans before the loop; no per-byte flag decoding.
//
// Correctness gate in main(): matchOpt is compared against
// src/matcher.matchesFlags on ~60 hand vectors (M1-M6 edges incl. the
// period/leading-dot pins) AND on every case of the 2400-case workload
// corpus. Any disagreement is counted and printed (stderr); the timing
// pass still runs so a semantic regression cannot masquerade as a speedup.
//
// Run (from the repo root, zig 0.14.1):
//   zig run -O ReleaseFast --dep matcher -Mroot=bench/opt_scan.zig \
//       -Mmatcher=src/matcher.zig -- tests/corpus/workload.jsonl
// Emits one JSON line per corpus case to stdout:
//   {"index":i,"category":"...","result":"MATCH"|"NOMATCH",
//    "opt_ns":n,"base_ns":n}
// plus a hand-vector summary to stderr.
//
// NOTE: this file does NOT modify src/matcher.zig. Findings land in
// docs/perf/scan.md.

const std = @import("std");
const matcher = @import("matcher"); // correctness reference + base timing

const FNM_PATHNAME: c_int = 0x1;
const FNM_NOESCAPE: c_int = 0x2;
const FNM_PERIOD: c_int = 0x4;
const FNM_CASEFOLD: c_int = 0x10;

const MAXT = 128; // compiled-token capacity; larger patterns fall back to
// matcher.matchesFlags (correctness preserved). 128 covers real-world
// patterns; measured 2-4x slower on tiny cases at 2048 due to the stack
// frame (see docs/perf/scan.md).

const CToken = union(enum) {
    star: usize, // pattern byte index of the '*'
    q,
    run: struct { start: usize, len: usize }, // raw literal run (pattern slice)
    esc: u8, // single literal byte (escaped pair, lone '\', or degraded '[')
    cls: struct { a: usize, b: usize }, // class content = pattern[a..b]
};

/// musl pat_next '[' scan (mirrors src/matcher.zig scanClass).
fn scanClass(pattern: []const u8, start: usize) ?usize {
    var k: usize = start + 1;
    if (k < pattern.len and (pattern[k] == '^' or pattern[k] == '!')) k += 1;
    if (k < pattern.len and pattern[k] == ']') k += 1;
    while (k < pattern.len and pattern[k] != ']') : (k += 1) {
        if (k + 1 < pattern.len and pattern[k] == '[' and
            (pattern[k + 1] == ':' or pattern[k + 1] == '.' or pattern[k + 1] == '='))
        {
            const z = pattern[k + 1];
            k += 2;
            if (k < pattern.len) k += 1;
            while (k < pattern.len and !(pattern[k - 1] == z and pattern[k] == ']')) k += 1;
            if (k == pattern.len) return null;
        }
    }
    if (k == pattern.len) return null;
    return k;
}

/// Compile pattern -> tokens. Returns null on buffer overflow (caller falls
/// back to the reference matcher), else compile metadata: token count plus
/// structure flags that let the caller skip work:
///   pure_literal — one raw literal run == whole pattern (no star/?/[/escape)
///   last_star    — token index of the LAST star (if any)
///   star_final   — the last star is also the final token (tail is empty)
const Compiled = struct {
    n: usize,
    pure_literal: bool,
    last_star: ?usize,
    star_final: bool,
};

fn compileToks(p: []const u8, noescape: bool, buf: []CToken) ?Compiled {
    var n: usize = 0;
    var i: usize = 0;
    var last_star: ?usize = null;
    while (i < p.len) {
        if (n + 1 > buf.len) return null;
        const c = p[i];
        if (!noescape and c == '\\') {
            if (i + 1 < p.len) {
                buf[n] = .{ .esc = p[i + 1] };
                n += 1;
                i += 2;
            } else { // trailing lone backslash = literal '\' (musl D002/D003)
                buf[n] = .{ .esc = '\\' };
                n += 1;
                i += 1;
            }
        } else if (c == '*') {
            buf[n] = .{ .star = i };
            last_star = n;
            n += 1;
            i += 1;
        } else if (c == '?') {
            buf[n] = .q;
            n += 1;
            i += 1;
        } else if (c == '[') {
            if (scanClass(p, i)) |cl| {
                buf[n] = .{ .cls = .{ .a = i + 1, .b = cl } };
                n += 1;
                i = cl + 1;
            } else { // unterminated: '[' is an ordinary literal byte (musl)
                buf[n] = .{ .esc = '[' };
                n += 1;
                i += 1;
            }
        } else { // maximal raw literal run
            const start = i;
            while (i < p.len) : (i += 1) {
                const b = p[i];
                if (b == '*' or b == '?' or b == '[') break;
                if (!noescape and b == '\\') break;
            }
            buf[n] = .{ .run = .{ .start = start, .len = i - start } };
            n += 1;
        }
    }
    return .{
        .n = n,
        .pure_literal = n == 1 and buf[0] == .run and buf[0].run.len == p.len,
        .last_star = last_star,
        .star_final = (last_star != null and last_star.? == n - 1),
    };
}

/// C-locale ASCII fold (mirrors src/matcher.zig).
fn foldByte(k: u8) u8 {
    if (k >= 'a' and k <= 'z') return k - 32;
    if (k >= 'A' and k <= 'Z') return k + 32;
    return k;
}

/// classMember mirrors src/matcher.zig (musl match_bracket byte-wise).
fn classMember(content: []const u8, c: u8, c2: u8) bool {
    var i: usize = 0;
    var inv = false;
    if (content.len > 0 and (content[0] == '^' or content[0] == '!')) {
        inv = true;
        i = 1;
    }
    if (i < content.len and content[i] == ']') {
        if (c == ']') return !inv;
        i += 1;
    } else if (i < content.len and content[i] == '-') {
        if (c == '-') return !inv;
        i += 1;
    }
    var wc: u8 = if (i == 0) '[' else content[i - 1];
    while (i < content.len) {
        if (content[i] == '-' and i + 1 < content.len) {
            const wc2 = content[i + 1];
            if (wc <= wc2 and ((c >= wc and c <= wc2) or (c2 >= wc and c2 <= wc2)))
                return !inv;
            i += 1;
            continue;
        }
        if (content[i] == '[' and i + 1 < content.len and
            (content[i + 1] == ':' or content[i + 1] == '.' or content[i + 1] == '='))
        {
            const z = content[i + 1];
            i += 3;
            while (i < content.len and !(content[i - 1] == z and content[i] == ']')) i += 1;
            i += 1;
            continue;
        }
        wc = content[i];
        if (wc == c or wc == c2) return !inv;
        i += 1;
    }
    return inv;
}

/// Literal-run equality: pattern run (raw bytes) vs string run. Under
/// FNM_CASEFOLD the STRING byte is folded toward the raw pattern byte
/// (matcher/musl semantics); plain mode is a straight bulk compare.
fn runEq(pat: []const u8, str: []const u8, folding: bool) bool {
    if (folding) {
        if (pat.len != str.len) return false;
        for (pat, str) |pc, sc| {
            if (!(sc == pc or foldByte(sc) == pc)) return false;
        }
        return true;
    }
    return std.mem.eql(u8, pat, str);
}

/// Endswith helper for the V2 tail anchor (pattern tail vs string suffix).
fn endsEq(tail: []const u8, suffix: []const u8, folding: bool) bool {
    return runEq(tail, suffix, folding);
}

/// The optimized matcher. Public entry: compiles once and runs the token
/// loop, with the V2 tail anchor wrapping it.
pub fn matchOpt(pat: []const u8, str: []const u8, flags: c_int) bool {
    var buf: [MAXT]CToken = undefined;
    return go(pat, str, flags, buf[0..]);
}

fn go(pat: []const u8, str: []const u8, flags: c_int, buf: []CToken) bool {
    const pathname = (flags & FNM_PATHNAME) != 0;
    const period = (flags & FNM_PERIOD) != 0;
    const folding = (flags & FNM_CASEFOLD) != 0;
    const noescape = (flags & FNM_NOESCAPE) != 0;
    const plain = (flags & (FNM_PATHNAME | FNM_PERIOD | FNM_CASEFOLD)) == 0;

    const compiled = compileToks(pat, noescape, buf) orelse
        return matcher.matchesFlags(pat, str, flags); // overflow fallback
    const n = compiled.n;

    // Pure-literal pattern (no wildcards/classes/escapes): the whole string
    // must equal it. Skipping the token loop removes per-call dispatch
    // overhead on the literal-heavy workload (runEq checks lengths).
    if (compiled.pure_literal) return runEq(pat, str, folding);

    // --- (b) V2 tail anchor (disabled under FNM_PERIOD) -------------------
    // If the only token after the LAST star is one raw literal run covering
    // pat[star+1..], strip it via endswith + recurse. Skipped when the star
    // is final (tail empty) — that is tracked during compile.
    // Disabled under FNM_PERIOD: stripping moves a segment-leading '.' to
    // string position 0 where the star token (not a raw '.' literal) would
    // be misjudged (vector *.x vs .x, PERIOD -> NOMATCH must hold).
    if ((flags & FNM_PERIOD) == 0 and !compiled.star_final) {
        if (compiled.last_star) |s| {
            const ps = buf[s].star;
            if (s + 2 == n) { // exactly one token after the star
                if (buf[s + 1] == .run and buf[s + 1].run.start == ps + 1) {
                    const m = buf[s + 1].run.len;
                    if (m > 0) {
                        if (str.len < m) return false;
                        if (!endsEq(pat[ps + 1 ..], str[str.len - m ..], folding))
                            return false;
                        var buf2: [MAXT]CToken = undefined;
                        return go(pat[0 .. ps + 1], str[0 .. str.len - m], flags, buf2[0..]);
                    }
                }
            }
        }
    }

    // --- main token loop ------------------------------------------------
    var t: usize = 0; // token cursor
    var s: usize = 0; // string cursor
    var star_tok: ?usize = null;
    var rewind: usize = 0;

    while (s < str.len) {
        const ch = str[s];

        // FNM_PERIOD leading-dot gate (musl): a segment-leading '.' in the
        // string must be met by a RAW unescaped '.' as the current token.
        if (period and ch == '.' and (s == 0 or (pathname and str[s - 1] == '/'))) {
            const dot_ok = blk: {
                if (t >= n) break :blk false;
                switch (buf[t]) {
                    .run => |r| break :blk pat[r.start] == '.',
                    else => break :blk false, // star/?/class/escaped '.': reject
                }
            };
            if (!dot_ok) return false;
        }

        var advanced = false;
        if (t < n) {
            switch (buf[t]) {
                .star => |ps| {
                    star_tok = t;
                    rewind = s;
                    _ = ps;
                    t += 1;
                    advanced = true;
                },
                .q => {
                    if (!(pathname and ch == '/')) {
                        t += 1;
                        s += 1;
                        advanced = true;
                    }
                },
                .cls => |cl| {
                    if (!(pathname and ch == '/') and
                        classMember(pat[cl.a..cl.b], ch, if (folding) foldByte(ch) else ch))
                    {
                        t += 1;
                        s += 1;
                        advanced = true;
                    }
                },
                .esc => |e| {
                    if (ch == e or (folding and foldByte(ch) == e)) {
                        t += 1;
                        s += 1;
                        advanced = true;
                    }
                },
                .run => |r| {
                    if (str.len - s >= r.len and
                        runEq(pat[r.start .. r.start + r.len], str[s .. s + r.len], folding))
                    {
                        t += 1;
                        s += r.len;
                        advanced = true;
                    }
                },
            }
        }
        if (advanced) continue;

        // Failure: give the last '*' one more byte (greedy rewind).
        if (star_tok) |st| {
            const after = st + 1;
            if (plain) {
                // (d) final star absorbs the whole remainder
                if (after >= n) {
                    s = str.len;
                    continue;
                }
                // (c) jump to the next run-start candidate byte
                if (buf[after] == .run and buf[after].run.len > 0) {
                    const c0 = pat[buf[after].run.start];
                    if (rewind + 1 < str.len) {
                        const off = std.mem.indexOfScalar(u8, str[rewind + 1 ..], c0) orelse
                            return false;
                        rewind = rewind + 1 + off;
                        s = rewind;
                        t = after;
                        continue;
                    }
                    return false;
                }
            } else {
                // FNM_PATHNAME: '*' never matches '/'. The star's cover is
                // [rewind_at_star_consume .. rewind). Advancing rewind adds
                // byte str[rewind] to the cover; if that byte is '/', no
                // later candidate can work (cover only grows) -> reject.
                // (src/matcher.zig guards the FAILURE byte instead, which
                // misses deep failures after a literal '/' was consumed -
                // e.g. "*/x.c" vs "a/b/x.c" PATHNAME: matcher=MATCH,
                // musl=NOMATCH. This is a matcher.zig bug; see
                // docs/perf/scan.md.)
                if (pathname and rewind < str.len and str[rewind] == '/') return false;
            }
            rewind += 1;
            s = rewind;
            t = after;
        } else return false;
    }

    // Trailing stars may match empty.
    while (t < n and buf[t] == .star) t += 1;
    return t == n;
}

// ---------------------------------------------------------------------------
// Driver: semantic gate (matchOpt vs matcher) + per-case timing, mirroring
// bench/workload.zig's method (warmup, 5 runs >=1024 iters ~1ms budget, min).
// ---------------------------------------------------------------------------

var g_checksum: u64 = 0;

fn flagBits(list: std.json.Array) c_int {
    var bits: c_int = 0;
    for (list.items) |f| {
        const nm = f.string;
        if (std.mem.eql(u8, nm, "FNM_PATHNAME")) bits |= FNM_PATHNAME;
        if (std.mem.eql(u8, nm, "FNM_NOESCAPE")) bits |= FNM_NOESCAPE;
        if (std.mem.eql(u8, nm, "FNM_PERIOD")) bits |= FNM_PERIOD;
        if (std.mem.eql(u8, nm, "FNM_CASEFOLD")) bits |= FNM_CASEFOLD;
    }
    return bits;
}

fn passBase(pat: []const u8, str: []const u8, flags: c_int) f64 {
    var timer = std.time.Timer.start() catch unreachable;
    var iters: u64 = 0;
    var acc: u64 = 0;
    while (true) {
        var i: u64 = 0;
        while (i < 1024) : (i += 1)
            acc +%= @intFromBool(matcher.matchesFlags(pat, str, flags));
        iters += 1024;
        if (timer.read() >= 1_000_000 or iters >= (1 << 22)) break;
    }
    g_checksum +%= acc;
    return @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iters));
}

fn passOpt(pat: []const u8, str: []const u8, flags: c_int) f64 {
    var timer = std.time.Timer.start() catch unreachable;
    var iters: u64 = 0;
    var acc: u64 = 0;
    while (true) {
        var i: u64 = 0;
        while (i < 1024) : (i += 1)
            acc +%= @intFromBool(matchOpt(pat, str, flags));
        iters += 1024;
        if (timer.read() >= 1_000_000 or iters >= (1 << 22)) break;
    }
    g_checksum +%= acc;
    return @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iters));
}

fn benchOne(comptime pass: fn ([]const u8, []const u8, c_int) f64, pat: []const u8, str: []const u8, flags: c_int) u64 {
    _ = pass(pat, str, flags); // warmup
    var best: f64 = std.math.inf(f64);
    var run: usize = 0;
    while (run < 5) : (run += 1) {
        const v = pass(pat, str, flags);
        if (v < best) best = v;
    }
    return @intFromFloat(@round(best));
}

const Vec = struct { pat: []const u8, str: []const u8, flags: c_int };
const MVec = struct { pat: []const u8, str: []const u8, flags: c_int, want: bool };

/// FNM_PATHNAME star-cover bug vectors: src/matcher.zig accepts some of
/// these (its star rewind can cover '/' when a deep failure happens after a
/// literal '/' was consumed); vendored musl 1.2.5 rejects all of them.
/// matchOpt is pinned to MUSL here (the differential reference), not to the
/// buggy matcher. Every expectation below was probed against
/// scripts/ref_harness.exe.
const musl_vectors = [_]MVec{
    .{ .pat = "a*/b", .str = "a/x/b", .flags = FNM_PATHNAME, .want = false },
    .{ .pat = "a*/c", .str = "a/b/c", .flags = FNM_PATHNAME, .want = false },
    .{ .pat = "*/x.c", .str = "a/b/x.c", .flags = FNM_PATHNAME, .want = false },
    .{ .pat = "*b", .str = "a/xb", .flags = FNM_PATHNAME, .want = false },
    .{ .pat = "*a*", .str = "x/a/y", .flags = FNM_PATHNAME, .want = false },
    .{ .pat = "x*a", .str = "x/y/a", .flags = FNM_PATHNAME, .want = false },
    .{ .pat = "x/*/a", .str = "x/y/z/a", .flags = FNM_PATHNAME, .want = false },
    .{ .pat = "a*/b", .str = "aX/Yb", .flags = FNM_PATHNAME, .want = false },
    .{ .pat = "*", .str = "x/b", .flags = FNM_PATHNAME, .want = false },
    // control acceptances from the same shapes (star cover never crosses '/')
    .{ .pat = "a*/b", .str = "a/b", .flags = FNM_PATHNAME, .want = true },
    .{ .pat = "a*/b", .str = "aX/b", .flags = FNM_PATHNAME, .want = true },
    .{ .pat = "*/", .str = "x/", .flags = FNM_PATHNAME, .want = true },
    .{ .pat = "*/*", .str = "x/y", .flags = FNM_PATHNAME, .want = true },
    .{ .pat = "x/*/a", .str = "x/y/a", .flags = FNM_PATHNAME, .want = true },
    .{ .pat = "*b", .str = "xb", .flags = FNM_PATHNAME, .want = true },
    .{ .pat = "src/*", .str = "src/a/b", .flags = FNM_PATHNAME, .want = false },
};

/// ~60 hand vectors across M1-M6 edges; every case must agree between
/// matchOpt and matcher.matchesFlags.
const hand_vectors = [_]Vec{
    // M1 literals / ? / *
    .{ .pat = "abc", .str = "abc", .flags = 0 },
    .{ .pat = "abc", .str = "abd", .flags = 0 },
    .{ .pat = "?", .str = "a", .flags = 0 },
    .{ .pat = "?", .str = "", .flags = 0 },
    .{ .pat = "*", .str = "", .flags = 0 },
    .{ .pat = "*", .str = "abc", .flags = 0 },
    .{ .pat = "a*c", .str = "abc", .flags = 0 },
    .{ .pat = "a*c", .str = "axyzc", .flags = 0 },
    .{ .pat = "*a", .str = "aaaa", .flags = 0 },
    .{ .pat = "a*", .str = "a", .flags = 0 },
    .{ .pat = "", .str = "", .flags = 0 },
    .{ .pat = "", .str = "a", .flags = 0 },
    .{ .pat = "ab", .str = "abc", .flags = 0 },
    .{ .pat = "abc", .str = "ab", .flags = 0 },
    // M2 pathname
    .{ .pat = "*.c", .str = "src/a.c", .flags = FNM_PATHNAME },
    .{ .pat = "*/*.c", .str = "src/a.c", .flags = FNM_PATHNAME },
    .{ .pat = "src/*", .str = "src/a/b", .flags = FNM_PATHNAME },
    .{ .pat = "src/*", .str = "src/a", .flags = FNM_PATHNAME },
    .{ .pat = "src/*", .str = "src/a/b", .flags = 0 },
    .{ .pat = "a*/b", .str = "a/b", .flags = FNM_PATHNAME },
    .{ .pat = "a*/b", .str = "ax/b", .flags = FNM_PATHNAME },
    .{ .pat = "a?b", .str = "a/b", .flags = FNM_PATHNAME },
    .{ .pat = "a?b", .str = "a.b", .flags = FNM_PATHNAME },
    // M3 escapes / NOESCAPE
    .{ .pat = "\\*", .str = "*", .flags = 0 },
    .{ .pat = "\\*", .str = "xyz", .flags = 0 },
    .{ .pat = "a\\", .str = "a\\", .flags = 0 },
    .{ .pat = "\\", .str = "\\", .flags = 0 },
    .{ .pat = "\\\\", .str = "\\", .flags = 0 },
    .{ .pat = "*\\*", .str = "x*y", .flags = 0 },
    .{ .pat = "*\\*", .str = "xy", .flags = 0 },
    .{ .pat = "\\*", .str = "x", .flags = FNM_NOESCAPE },
    .{ .pat = "a\\*b", .str = "a*b", .flags = FNM_NOESCAPE },
    .{ .pat = "a*\\*b", .str = "axx*b", .flags = FNM_NOESCAPE },
    .{ .pat = "a\\", .str = "a\\", .flags = FNM_NOESCAPE },
    // M4 brackets
    .{ .pat = "[abc]", .str = "b", .flags = 0 },
    .{ .pat = "[abc]", .str = "d", .flags = 0 },
    .{ .pat = "[a-z]", .str = "q", .flags = 0 },
    .{ .pat = "[a-z]", .str = "Q", .flags = 0 },
    .{ .pat = "[!abc]", .str = "d", .flags = 0 },
    .{ .pat = "[!abc]", .str = "a", .flags = 0 },
    .{ .pat = "[^abc]", .str = "d", .flags = 0 },
    .{ .pat = "[z-a]", .str = "z", .flags = 0 }, // D001: reversed range = members literal
    .{ .pat = "[z-a]", .str = "a", .flags = 0 },
    .{ .pat = "[]", .str = "[]", .flags = 0 }, // degrades to two literal bytes
    .{ .pat = "[]", .str = "[", .flags = 0 },
    .{ .pat = "[a-]", .str = "-", .flags = 0 },
    .{ .pat = "[]a]", .str = "]", .flags = 0 },
    .{ .pat = "[]a]", .str = "a", .flags = 0 },
    .{ .pat = "[a\\c]", .str = "\\", .flags = 0 }, // backslash is an ordinary member
    .{ .pat = "a[", .str = "a[", .flags = 0 }, // unterminated '[' literal
    .{ .pat = "[ab", .str = "a", .flags = FNM_NOESCAPE },
    .{ .pat = "*[0-9].log", .str = "x7.log", .flags = 0 },
    .{ .pat = "*[0-9].log", .str = "x7.logx", .flags = 0 },
    .{ .pat = "x[ab]/y", .str = "xa/y", .flags = FNM_PATHNAME },
    .{ .pat = "[ab]/y", .str = "a/y", .flags = FNM_PATHNAME },
    .{ .pat = "a/[!x]", .str = "a/y", .flags = FNM_PATHNAME },
    // M5 period
    .{ .pat = "*", .str = ".x", .flags = FNM_PERIOD },
    .{ .pat = ".x", .str = ".x", .flags = FNM_PERIOD },
    .{ .pat = "[.]x", .str = ".x", .flags = FNM_PERIOD },
    .{ .pat = "?.x", .str = "a.x", .flags = FNM_PERIOD },
    .{ .pat = "a*", .str = "a.x", .flags = FNM_PERIOD },
    .{ .pat = "a*", .str = "a.x", .flags = FNM_PERIOD | FNM_PATHNAME },
    .{ .pat = "a/*", .str = "a/.x", .flags = FNM_PERIOD | FNM_PATHNAME },
    .{ .pat = "a/.*", .str = "a/.x", .flags = FNM_PERIOD | FNM_PATHNAME },
    .{ .pat = "a/*", .str = "a/b.x", .flags = FNM_PERIOD | FNM_PATHNAME },
    .{ .pat = "*", .str = "a/.x", .flags = FNM_PERIOD | FNM_PATHNAME },
    .{ .pat = "\\*", .str = "*.x", .flags = FNM_PERIOD },
    .{ .pat = "*.x", .str = ".x", .flags = FNM_PERIOD }, // star cannot take the dot
    // M6 casefold (C locale, ASCII)
    .{ .pat = "ABC", .str = "abc", .flags = FNM_CASEFOLD },
    .{ .pat = "abc", .str = "ABC", .flags = FNM_CASEFOLD },
    .{ .pat = "[A-Z]", .str = "q", .flags = FNM_CASEFOLD },
    .{ .pat = "[a-z]", .str = "Q", .flags = FNM_CASEFOLD },
    .{ .pat = "A?C", .str = "aZc", .flags = FNM_CASEFOLD },
    .{ .pat = "A*Z", .str = "aMIddleZ", .flags = FNM_CASEFOLD },
    .{ .pat = "*AB*", .str = "xxabxx", .flags = FNM_CASEFOLD },
    .{ .pat = "*AB*", .str = "xxcdxx", .flags = FNM_CASEFOLD },
    // adversarial-ish
    .{ .pat = "*a*a*a*b", .str = "aaaaaaaaaaaaaaaa", .flags = 0 },
    .{ .pat = "*a*a*a*b", .str = "aaaaaaaaaaaaaab", .flags = 0 },
    .{ .pat = "src/*/test/*.c", .str = "src/a/test/x.c", .flags = 0 },
    .{ .pat = "src/*/test/*.c", .str = "src/a/b/test/x.c", .flags = 0 },
    .{ .pat = "*a*c", .str = "abracadabrac", .flags = 0 },
    // tail-anchor-specific edges
    .{ .pat = "*abc", .str = "abc", .flags = 0 },
    .{ .pat = "*abc", .str = "xxabc", .flags = 0 },
    .{ .pat = "*abc", .str = "abcxx", .flags = 0 },
    .{ .pat = "*abc", .str = "ab", .flags = 0 },
    .{ .pat = "a*abc", .str = "aabc", .flags = 0 },
    .{ .pat = "a*abc", .str = "aXabc", .flags = 0 },
    .{ .pat = "a*b*c", .str = "aXbYc", .flags = 0 },
    .{ .pat = "*.c", .str = "src/a.c", .flags = 0 },
    .{ .pat = "*/.x", .str = "a/.x", .flags = FNM_PERIOD | FNM_PATHNAME },
    .{ .pat = "*/.x", .str = "a/b.x", .flags = FNM_PERIOD | FNM_PATHNAME },
    .{ .pat = "*ab", .str = "xab", .flags = FNM_CASEFOLD },
    .{ .pat = "*AB", .str = "xab", .flags = FNM_CASEFOLD },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    // --- hand-vector semantic gate (matchOpt vs matcher) ---
    var mismatches: usize = 0;
    for (hand_vectors, 0..) |v, vi| {
        const want = matcher.matchesFlags(v.pat, v.str, v.flags);
        const got = matchOpt(v.pat, v.str, v.flags);
        if (want != got) {
            mismatches += 1;
            std.debug.print("VECTOR MISMATCH #{d}: pat='{s}' str='{s}' flags={d} matcher={} opt={}\n",
                .{ vi, v.pat, v.str, v.flags, want, got });
        }
    }
    std.debug.print("hand vectors: {d} checked, {d} mismatches\n", .{ hand_vectors.len, mismatches });

    // --- musl-pinned vectors: opt must equal the VENDORED MUSL result ---
    // (separate from matcher because src/matcher.zig has a known FNM_PATHNAME
    // star-cover bug on some of these; see docs/perf/scan.md.)
    var musl_mismatches: usize = 0;
    for (musl_vectors, 0..) |v, vi| {
        const got = matchOpt(v.pat, v.str, v.flags);
        if (got != v.want) {
            musl_mismatches += 1;
            std.debug.print("MUSL-VECTOR MISMATCH #{d}: pat='{s}' str='{s}' flags={d} opt={} expected={}\n",
                .{ vi, v.pat, v.str, v.flags, got, v.want });
        }
    }
    std.debug.print("musl-pinned vectors: {d} checked, {d} mismatches\n", .{ musl_vectors.len, musl_mismatches });

    const args = try std.process.argsAlloc(a);
    const cases_path = if (args.len > 1) args[1] else "tests/corpus/workload.jsonl";
    const src = try std.fs.cwd().readFileAlloc(a, cases_path, 64 << 20);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var out = std.ArrayList(u8).init(a);
    var corr_mismatch: usize = 0;
    var count: usize = 0;
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, aa, line, .{});
        const obj = parsed.value.object;
        const pat = obj.get("pattern").?.string;
        const str = obj.get("string").?.string;
        const flags = flagBits(obj.get("flags").?.array);
        const category = obj.get("category").?.string;

        const want = matcher.matchesFlags(pat, str, flags);
        const got = matchOpt(pat, str, flags);
        if (want != got) corr_mismatch += 1;
        const res = if (got) "MATCH" else "NOMATCH";
        const opt_ns = benchOne(passOpt, pat, str, flags);
        const base_ns = benchOne(passBase, pat, str, flags);
        const line_out = try std.fmt.allocPrint(a,
            "{{\"index\":{d},\"category\":\"{s}\",\"result\":\"{s}\",\"opt_ns\":{d},\"base_ns\":{d}}}\n",
            .{ index, category, res, opt_ns, base_ns });
        try out.appendSlice(line_out);
        count += 1;
        index += 1;
    }

    std.debug.print("corpus: {d} cases, semantic mismatches vs matcher: {d}\n",
        .{ count, corr_mismatch });
    std.debug.print("opt_scan checksum {d} (match calls kept live)\n", .{g_checksum});

    const stdout = std.io.getStdOut();
    try stdout.writeAll(out.items);
}
