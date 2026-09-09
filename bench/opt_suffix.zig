// bench/opt_suffix.zig — fnmatch-ng anchored-tail fast path prototype
// (perf-audit lane; plan section 32 "trailing-literal fast path").
//
// Hypothesis (from results/baseline/workloads.json + _prof_hot_joined.jsonl):
// musl wins single-star 65->27, suffix-star 75->46, fail-late 102->32 ns
// because musl's fnmatch_internal ANCHORS the literal tail after the last
// '*' to the END of the string before matching anything else (see
// compat/musl_fnmatch.c: find last '*', count tail tokens, walk that many
// chars back from the string end, compare tail, then component-match only
// the prefix). src/matcher.zig has no equivalent: its greedy rewind retries
// the whole tail at every position, which is why long-suffix patterns lose.
//
// This file prototypes the same idea as a SEMANTICALLY TRANSPARENT wrapper:
//
//   fastMatchFlags(p,s,f) =
//       tryFast(p,s,f)  orelse  matcher.matchesFlags(p,s,f)
//
// where tryFast() engages ONLY when the anchored reduction is provably
// equivalent to the current matcher, and returns null (-> fall back to the
// unmodified matcher) otherwise. src/matcher.zig is NOT modified; the
// wrapper must never change a result, only make some of them faster.
//
// Reduction (valid when engaged):
//   pattern == <prefix tokens> '*' <literal tail T>, T = decoded literal
//   bytes immediately after the LAST '*' token (no '?'/class between).
//   A full match must end with T consuming the string tail, so
//   q = |string| - |T| is FIXED. The match then decomposes exactly into:
//     matchesFlags(pattern[0..lastStarEnd], string[0..q))   // prefix incl. '*'
//     AND tail bytes == string[q..]                          // literal compare
//   The prefix slice ends in the '*' and is matched by the UNMODIFIED
//   matcher, so every prefix token quirk (classes, escapes, PERIOD gates,
//   CASEFOLD) keeps its exact current behavior on the region [0..q).
//
// Engagement rules (bail -> fall back when the reduction could diverge):
//   1. No '*' in the pattern, or the pattern ends in a '*' (tail empty).
//   2. Tail is not pure literals (a '?'/bracket/well-formed class after the
//      last '*'), or the decoded tail exceeds the fixed 512-byte buffer.
//   3. FNM_PATHNAME and the tail contains a '/'  — matcher.zig's rewind
//      lets the last '*' span '/' when T contains a literal '/' to realign
//      on (e.g. "*/x" vs "a/b/x" PATHNAME: matcher MATCH, musl NOMATCH —
//      musl is segment-local; this is a LATENT MATCHER BUG vs the vendored
//      reference, see docs/perf/suffix.md "finding"; we stay transparent to
//      the current matcher by bailing here).
//   4. FNM_PERIOD and (tail contains '/' OR any escaped-dot token): the
//      raw-byte leading-dot gate (segment starts inside the tail region /
//      at q) is only faithfully reproduced by the full matcher.
//
// CASEFOLD tail compare mirrors the matcher exactly (fold applied to the
// STRING byte only, pattern byte raw): k == ch || fold(k) == ch.
//
// Timing mirrors bench/workload.zig (warmup + 5 timed runs of >=1024 iters,
// adaptive ~1ms budget, report min ns/match; checksum keeps calls live).
//
// Run (repo root, zig 0.14.1):
//   zig test  --dep matcher -Mroot=bench/opt_suffix.zig \
//       -Mmatcher=src/matcher.zig            # differential self-check
//   zig run -O ReleaseFast --dep matcher -Mroot=bench/opt_suffix.zig \
//       -Mmatcher=src/matcher.zig -- tests/corpus/workload.jsonl
// Default out: results/baseline/_suffix_ours.jsonl
//   {"index","category","result","plain_ns","fast_ns","engaged","tail_len"}
// plain_ns/fast_ns only for engaged cases; otherwise plain_ns is the shared
// fallback cost and fast_ns == plain_ns.

const std = @import("std");
const matcher = @import("matcher"); // wired via -Mmatcher=src/matcher.zig

var g_checksum: u64 = 0; // keeps timed matches live; printed at the end

// ---- mirrored tokenizer (matcher's Token/tokenAt/scanClass are private) ---

const Token = struct {
    kind: enum { end, star, question, lit, cls },
    ch: u8 = 0,
    step: usize = 0,
    a: usize = 0,
    b: usize = 0,
};

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

fn tokenAt(pattern: []const u8, p: usize, flags: c_int) Token {
    if (p >= pattern.len) return .{ .kind = .end };
    const noescape = (flags & matcher.FNM_NOESCAPE) != 0;
    const pc = pattern[p];
    if (!noescape and pc == '\\' and p + 1 < pattern.len)
        return .{ .kind = .lit, .ch = pattern[p + 1], .step = 2 };
    if (pc == '[') {
        if (scanClass(pattern, p)) |close|
            return .{ .kind = .cls, .step = close - p + 1, .a = p + 1, .b = close };
        return .{ .kind = .lit, .ch = '[', .step = 1 };
    }
    return switch (pc) {
        '*' => .{ .kind = .star, .step = 1 },
        '?' => .{ .kind = .question, .step = 1 },
        else => .{ .kind = .lit, .ch = pc, .step = 1 },
    };
}

fn foldByte(k: u8) u8 {
    if (k >= 'a' and k <= 'z') return k - 32;
    if (k >= 'A' and k <= 'Z') return k + 32;
    return k;
}

const Tail = struct {
    len: usize,
    anySlash: bool,
    anyEscapedDot: bool,
};

/// Decode the maximal run of literal tokens starting at pattern index
/// `start` into `buf`. Returns null when a non-literal token appears
/// (tail not purely literal) or the run overflows `buf`.
fn decodeTail(pattern: []const u8, start: usize, flags: c_int, buf: []u8) ?Tail {
    var p = start;
    var t = Tail{ .len = 0, .anySlash = false, .anyEscapedDot = false };
    while (p < pattern.len) {
        const tok = tokenAt(pattern, p, flags);
        if (tok.kind != .lit) return null; // '?'/class/star inside tail
        if (t.len >= buf.len) return null; // oversized tail: fall back
        buf[t.len] = tok.ch;
        t.len += 1;
        if (tok.ch == '/') t.anySlash = true;
        if (tok.step == 2 and tok.ch == '.') t.anyEscapedDot = true;
        p += tok.step;
    }
    return t;
}

/// One cheap FORWARD byte pass that finds the end of the LAST unescaped
/// '*' and decodes the trailing literal run after it. Any '[' anywhere
/// disables the fast path (class parsing and class bodies containing '*'
/// would need tokenAt; class patterns measured as at-best-wash, so we bail
/// out of the whole wrapper for them). Escapes ('\'+byte, unless
/// FNM_NOESCAPE), '?' (dirty after the last star) are handled inline.
/// Returns null when there is no star, the tail is dirty/empty/oversized,
/// or the pattern contains '['.
const Scan = struct {
    star_end: usize, // pattern index just past the last '*' token
    tail: []const u8, // decoded literal bytes of the tail (view into buf)
    prefix_stars: usize, // '*' tokens before the last one
    any_slash: bool,
    any_escaped_dot: bool,
};

fn scanTail(pat: []const u8, flags: c_int, buf: []u8) ?Scan {
    const noescape = (flags & matcher.FNM_NOESCAPE) != 0;
    var p: usize = 0;
    var star_end: ?usize = null;
    var prefix_stars: usize = 0;
    var t: usize = 0; // tail bytes accumulated so far
    var dirty = false;
    var any_slash = false;
    var any_escaped_dot = false;
    while (p < pat.len) {
        const c = pat[p];
        if (c == '[') return null; // classes disable the wrapper (see above)
        if (!noescape and c == '\\') {
            if (p + 1 >= pat.len) {
                // trailing lone '\' = ordinary literal backslash (D002/D003)
                if (!dirty) {
                    if (t >= buf.len) return null;
                    buf[t] = '\\';
                    t += 1;
                }
                break;
            }
            // escape pair: one literal byte when in the tail
            if (!dirty) {
                if (t >= buf.len) return null;
                const ch = pat[p + 1];
                buf[t] = ch;
                t += 1;
                if (ch == '/') any_slash = true;
                if (ch == '.') any_escaped_dot = true;
            }
            p += 2;
            continue;
        }
        if (c == '*') {
            star_end = p + 1;
            prefix_stars += 1;
            t = 0;
            dirty = false;
            any_slash = false;
            any_escaped_dot = false;
        } else if (c == '?') {
            dirty = true; // '?' after current last star: tail not literal
        } else if (!dirty) {
            if (t >= buf.len) return null;
            buf[t] = c;
            t += 1;
            if (c == '/') any_slash = true;
        }
        p += 1;
    }
    const se = star_end orelse return null;
    if (dirty or t == 0) return null;
    return .{ .star_end = se, .tail = buf[0..t], .prefix_stars = prefix_stars - 1, .any_slash = any_slash, .any_escaped_dot = any_escaped_dot };
}

/// Anchored-tail result, or null when the fast path must not engage.
/// When engaged, the returned bool is the correct match result.
fn tryFast(pat: []const u8, str: []const u8, flags: c_int, tbuf: []u8) ?bool {
    const s = scanTail(pat, flags, tbuf) orelse return null;
    const tail = s.tail;
    const pathname = (flags & matcher.FNM_PATHNAME) != 0;
    const period = (flags & matcher.FNM_PERIOD) != 0;
    if (pathname and s.any_slash) return null; // matcher.zig loose-star region (finding)
    if (period and (s.any_slash or s.any_escaped_dot)) return null;
    if (str.len < tail.len) return false; // anchored tail cannot fit
    const q = str.len - tail.len;
    const folding = (flags & matcher.FNM_CASEFOLD) != 0;
    // TAIL FIRST: when the string does not end in the decoded tail there is
    // no match at all (the tail is anchored) — return false without paying
    // for the prefix sub-match. This is where fail-late / single-star
    // NOMATCH cases win big.
    for (0..tail.len) |i| {
        const k = str[q + i];
        const ch = tail[i];
        if (!(k == ch or (folding and foldByte(k) == ch))) return false;
    }
    // The string DOES end in the tail. When stars exist before the last one,
    // the prefix sub-match below would re-run the same multi-star dispatch
    // as the plain matcher (its tail retries are ~zero for pattern-shaped
    // strings), so the wrapper only adds overhead: fall back.
    if (s.prefix_stars > 0) return null;
    // Prefix + last star against string[0..q). Delegate to the unmodified
    // matcher: identical semantics for the prefix region (see file header).
    if (!matcher.matchesFlags(pat[0..s.star_end], str[0..q], flags)) return false;
    return true;
}

/// Semantically transparent wrapper: anchored-tail fast path when safe,
/// otherwise the unmodified matcher. Must equal matcher.matchesFlags on
/// every input (verified by the differential tests below).
pub fn fastMatchFlags(pat: []const u8, str: []const u8, flags: c_int) bool {
    var tbuf: [512]u8 = undefined;
    return tryFast(pat, str, flags, &tbuf) orelse matcher.matchesFlags(pat, str, flags);
}

// ------------------------------- self-checks ------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "mirrored tokenizer agrees with the real matcher on escapes/classes" {
    // Token decode correctness is the foundation; these mirror matcher tests.
    try expect(matcher.matchesFlags("\\*", "*", 0)); // escape pair decodes to lit '*'
    try expect(!matcher.matchesFlags("\\*", "xyz", 0));
    try expect(!matcher.matchesFlags("\\*", "\\*", 0));
    try expect(matcher.matchesFlags("[]", "[]", 0)); // empty []: two literal tokens
    try expect(matcher.matchesFlags("[", "[", 0)); // unterminated: literal '['
    try expect(matcher.matchesFlags("[a\\c]", "\\", 0)); // backslash literal inside class
    // ...and the wrapper preserves them (it must never change a result)
    for ([_][]const u8{ "\\*", "\\?", "\\\\", "[]", "[", "[a\\c]", "a[b]c", "a\\*b", "*\\x" }) |pat| {
        const strs = [_][]const u8{ "", "*", "\\", "?", "[]", "[", "a", "abc", "a*b", "axb", "abx", "a\\*b", "[a\\c]" };
        for (strs) |s| {
            try expectEqual(matcher.matchesFlags(pat, s, 0), fastMatchFlags(pat, s, 0));
        }
    }
}

test "anchored tail equals full matcher on the plan/workload families" {
    const P = matcher.FNM_PATHNAME;
    const CF = matcher.FNM_CASEFOLD;
    const cases = [_]struct { p: []const u8, s: []const u8, f: c_int }{
        .{ .p = "abc", .s = "abc", .f = 0 },
        .{ .p = "a*c", .s = "abc", .f = 0 },
        .{ .p = "a*c", .s = "axyzc", .f = 0 },
        .{ .p = "a*c", .s = "axYzc", .f = CF },
        .{ .p = "*a", .s = "aaaa", .f = 0 },
        .{ .p = "*.c", .s = "src/a.c", .f = P },
        .{ .p = "*.c", .s = "src/a.c", .f = 0 },
        .{ .p = "*/*.c", .s = "src/a.c", .f = P },
        .{ .p = "*parser.c", .s = "aaaaparser.cx", .f = 0 },
        .{ .p = "*parser.c", .s = "aaaaparser.c", .f = 0 },
        .{ .p = "*.c", .s = "aaaa.x", .f = 0 },
        .{ .p = "*.c", .s = "aaaa.c", .f = 0 },
        .{ .p = "src/*/test/*.c", .s = "src/a/test/b.c", .f = P },
        .{ .p = "a*b", .s = "aXb", .f = P },
        .{ .p = "*b", .s = "a/b", .f = P }, // bail region? T='b' no slash -> engaged
        .{ .p = "*b", .s = "ab", .f = P },
        .{ .p = "a\\*b", .s = "a*b", .f = 0 },
        .{ .p = "a*b", .s = "aX/Yb", .f = P },
        .{ .p = "a*b", .s = "aX/Yb", .f = 0 }, // no PATHNAME: '/' is a plain byte
        .{ .p = "abc*", .s = "abc", .f = 0 }, // ends in star: bail path
        .{ .p = "abc*", .s = "abcX", .f = 0 },
        .{ .p = "*", .s = "", .f = 0 },
        .{ .p = "*", .s = "abc", .f = 0 },
        .{ .p = "x[0-9]*y", .s = "x42y", .f = 0 },
        .{ .p = "*[!0-9]", .s = "a1", .f = 0 },
        .{ .p = "*[0-9]*", .s = "file42.log", .f = 0 },
        .{ .p = "a?c", .s = "abc", .f = 0 },
        .{ .p = "src/*.C", .s = "src/a.c", .f = CF },
        .{ .p = "src/*.C", .s = "src/a/b.c", .f = CF | P },
    };
    for (cases) |c| {
        const want = matcher.matchesFlags(c.p, c.s, c.f);
        try expectEqual(want, fastMatchFlags(c.p, c.s, c.f));
    }
}

test "engagement: bails are transparent, engaged path is used where it pays" {
    const P = matcher.FNM_PATHNAME;
    var tbuf: [64]u8 = undefined;
    // PATHNAME + '/' in tail: the matcher.zig loose-star bug region -> bail
    try expect(tryFast("*/x", "a/b/x", P, &tbuf) == null); // matcher says MATCH (quirk); musl NOMATCH
    try expect(tryFast("a*/b", "aX/Y/b", P, &tbuf) == null);
    // ...but the wrapper still returns the matcher's (quirked) answer
    try expect(fastMatchFlags("*/x", "a/b/x", P));
    try expect(fastMatchFlags("a*/b", "aX/Y/b", P));
    // PERIOD + escaped dot in tail -> bail
    try expect(tryFast("*\\.c", "x.c", matcher.FNM_PERIOD, &tbuf) == null);
    // no star -> bail; ends-in-star -> bail
    try expect(tryFast("abc", "abc", 0, &tbuf) == null);
    try expect(tryFast("abc*", "abc", 0, &tbuf) == null);
    // engaged on a plain single-star suffix
    const r = tryFast("*.c", "src/main.c", 0, &tbuf);
    try expect(r != null and r.?);
    // engaged on PATHNAME single-star (tail has no slash)
    const r2 = tryFast("*.c", "src/a.c", P, &tbuf);
    try expect(r2 != null and !r2.?); // *.c cannot match src/a.c under PATHNAME
    // no star -> whole-literal: fast path declines, matcher handles
    try expect(!fastMatchFlags("abc", "abd", 0));
}

/// Tiny xorshift PRNG (deterministic seed -> reproducible differential).
const Rng = struct {
    s: u64 = 0x9E3779B97F4A7C15,
    fn next(self: *Rng) u64 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 7;
        self.s ^= self.s << 17;
        return self.s;
    }
    fn below(self: *Rng, n: usize) usize {
        return @intCast(self.next() % @as(u64, @intCast(n)));
    }
};

const patAlphabet = "abcxyzA*?[.]^-\\/";
const strAlphabet = "abcxyzA012.^-\\/[]*?";
const flagsBank = [_]c_int{
    matcher.FNM_PATHNAME,
    matcher.FNM_NOESCAPE,
    matcher.FNM_PERIOD,
    matcher.FNM_CASEFOLD,
};

fn genPat(rng: *Rng, buf: []u8) []const u8 {
    const n = rng.below(18) + 1; // 1..18 bytes
    var k: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = patAlphabet[rng.below(patAlphabet.len)];
        buf[k] = c;
        k += 1;
    }
    return buf[0..k];
}

fn genStr(rng: *Rng, buf: []u8) []const u8 {
    const n = rng.below(20); // 0..19 bytes (empty included)
    var k: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[k] = strAlphabet[rng.below(strAlphabet.len)];
        k += 1;
    }
    return buf[0..k];
}

test "randomized differential: fastMatchFlags == matchesFlags (200k cases)" {
    var rng = Rng{};
    var pbuf: [32]u8 = undefined;
    var sbuf: [32]u8 = undefined;
    var n: usize = 0;
    while (n < 200_000) : (n += 1) {
        const pat = genPat(&rng, &pbuf);
        const str = genStr(&rng, &sbuf);
        var flags: c_int = 0;
        var f: usize = 0;
        while (f < 4) : (f += 1) {
            if (rng.below(2) == 1) flags |= flagsBank[f];
        }
        const want = matcher.matchesFlags(pat, str, flags);
        const got = fastMatchFlags(pat, str, flags);
        if (want != got) {
            std.debug.print("DIFF pat=<{s}> str=<{s}> flags={d}: matcher={} fast={}\n", .{ pat, str, flags, want, got });
            return error.DifferentialMismatch;
        }
    }
    // engaged-path coverage must be substantial, or the test proves nothing
    var tbuf: [512]u8 = undefined;
    var engaged: usize = 0;
    var total: usize = 0;
    var rr = Rng{};
    while (total < 20_000) : (total += 1) {
        const pat = genPat(&rr, &pbuf);
        const str = genStr(&rr, &sbuf);
        var flags: c_int = 0;
        var f: usize = 0;
        while (f < 4) : (f += 1) {
            if (rr.below(2) == 1) flags |= flagsBank[f];
        }
        if (tryFast(pat, str, flags, &tbuf) != null) engaged += 1;
    }
    if (engaged < 300) {
        std.debug.print("engaged={d}/20000 too low; generator not exercising the path\n", .{engaged});
        return error.WeakCoverage;
    }
}

// ------------------------------- timing main -------------------------------

fn flagBits(list: std.json.Array) c_int {
    var bits: c_int = 0;
    for (list.items) |f| {
        const n = f.string;
        if (std.mem.eql(u8, n, "FNM_PATHNAME")) bits |= matcher.FNM_PATHNAME;
        if (std.mem.eql(u8, n, "FNM_NOESCAPE")) bits |= matcher.FNM_NOESCAPE;
        if (std.mem.eql(u8, n, "FNM_PERIOD")) bits |= matcher.FNM_PERIOD;
        if (std.mem.eql(u8, n, "FNM_CASEFOLD")) bits |= matcher.FNM_CASEFOLD;
    }
    return bits;
}

fn passOncePlain(pat: []const u8, str: []const u8, flags: c_int) f64 {
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

fn passOnceFast(pat: []const u8, str: []const u8, flags: c_int) f64 {
    var timer = std.time.Timer.start() catch unreachable;
    var iters: u64 = 0;
    var acc: u64 = 0;
    while (true) {
        var i: u64 = 0;
        while (i < 1024) : (i += 1)
            acc +%= @intFromBool(fastMatchFlags(pat, str, flags));
        iters += 1024;
        if (timer.read() >= 1_000_000 or iters >= (1 << 22)) break;
    }
    g_checksum +%= acc;
    return @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iters));
}

fn benchCase(comptime which: enum { plain, fast }, pat: []const u8, str: []const u8, flags: c_int) u64 {
    const first = if (which == .plain) passOncePlain(pat, str, flags) else passOnceFast(pat, str, flags);
    _ = first; // warmup
    var best: f64 = std.math.inf(f64);
    var run: usize = 0;
    while (run < 5) : (run += 1) {
        const v = if (which == .plain) passOncePlain(pat, str, flags) else passOnceFast(pat, str, flags);
        if (v < best) best = v;
    }
    return @intFromFloat(@round(best));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const aa = gpa.allocator();

    const args = try std.process.argsAlloc(aa);
    const corpus_path = if (args.len > 1) args[1] else "tests/corpus/workload.jsonl";
    const out_path = if (args.len > 2) args[2] else "results/baseline/_suffix_ours.jsonl";

    const src = try std.fs.cwd().readFileAlloc(aa, corpus_path, 64 << 20);
    const outf = try std.fs.cwd().createFile(out_path, .{});
    defer outf.close();
    var bw = std.io.bufferedWriter(outf.writer());
    const w = bw.writer();

    var tbuf: [512]u8 = undefined;
    var index: usize = 0;
    var engaged_count: usize = 0;
    var mismatch: usize = 0;
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
        if (tryFast(pat, str, flags, &tbuf)) |res| {
            if (res != want) {
                std.debug.print("MISMATCH #{d} cat={s} pat=<{s}> str=<{s}> flags={d}: matcher={} fast={}\n", .{ index, category, pat, str, flags, want, res });
                mismatch += 1;
            }
            engaged_count += 1;
            const plain_ns = benchCase(.plain, pat, str, flags);
            const fast_ns = benchCase(.fast, pat, str, flags);
            const res_s = if (res) "MATCH" else "NOMATCH";
            const tl = (scanTail(pat, flags, &tbuf) orelse unreachable).tail.len;
            try w.print("{{\"index\":{d},\"category\":\"{s}\",\"result\":\"{s}\",\"plain_ns\":{d},\"fast_ns\":{d},\"engaged\":true,\"tail_len\":{d}}}\n", .{ index, category, res_s, plain_ns, fast_ns, tl });
        } else {
            // Bail: both paths are the identical matcher call; time once.
            const ns = benchCase(.plain, pat, str, flags);
            const res_s = if (want) "MATCH" else "NOMATCH";
            try w.print("{{\"index\":{d},\"category\":\"{s}\",\"result\":\"{s}\",\"plain_ns\":{d},\"fast_ns\":{d},\"engaged\":false}}\n", .{ index, category, res_s, ns, ns });
        }
        parsed.deinit();
        index += 1;
    }
    try bw.flush();
    std.debug.print("cases={d} engaged={d} mismatches={d} checksum={d}\n", .{ index, engaged_count, mismatch, g_checksum });
    if (mismatch != 0) std.process.exit(1);
}
