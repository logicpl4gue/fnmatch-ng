// fuzz/memfuzz.zig — trap fuzzer for src/matcher.zig (memory-safety leg).
//
// What it proves: the matcher never trips a safe-Zig trap (panic, OOB
// slice, integer overflow, unreachable) on arbitrary byte soup under
// ReleaseSafe. What it does NOT prove: verdict correctness (that is the
// differential leg, scripts/differential.py vs vendored musl) or C-ABI UB
// invisible to safe Zig (parked: no Linux host for libFuzzer/AFL, see
// docs/language-choice.md). A crash is reported by the Zig runtime itself:
// nonzero exit + stack trace.
//
// Per-iteration input distribution (seeded, fully reproducible):
//   * token-soup patterns: metachar bytes ('*','?','[',']','-','^','!',
//     '\\','.','/') mixed with alnum and raw bytes >= 0x80; '[' is
//     sometimes completed into a well-formed class so scanClass sees
//     closed, open, and malformed brackets;
//   * 12.5% "flood" patterns: '*'+literal pairs until >128 compile tokens,
//     forcing the MAXT=128 overflow and exercising matchBytewise, the
//     fallback path the compiled core otherwise hides;
//   * strings: 50% independent soup, 50% literal chunks cut out of the
//     pattern and re-pasted with junk between them — every star rewind
//     gets many false candidate alignments to walk (deep-rewind exercise);
//   * flags: all 16 combinations of PATHNAME/NOESCAPE/PERIOD/CASEFOLD
//     cycled (combo = iteration index & 0xF), plus junk high bits OR'd in
//     on 25% of calls (undefined bits must be ignored, not acted on).
//
// Usage (from the repo root, zig 0.14.1):
//   zig run -O ReleaseSafe --dep matcher -Mroot=fuzz/memfuzz.zig \
//       -Mmatcher=src/matcher.zig -- <seed> <iters>
//   e.g. zig run -O ReleaseSafe --dep matcher -Mroot=fuzz/memfuzz.zig \
//       -Mmatcher=src/matcher.zig -- 0x5eed 200000
// Exit 0 = <iters> iterations, zero traps. Heartbeat to stderr every 1M
// iterations; final checksum (kept live so ReleaseSafe cannot fold the
// match calls away) printed to stderr.
//
// (The matcher is wired as a named module, `-Mmatcher=src/matcher.zig`,
// the repo convention in bench/workload.zig: zig 0.14 rejects relative
// imports that escape a `zig run` root module's directory.)

const std = @import("std");
const m = @import("matcher");

const hi_pool = [_]u8{ 0x80, 0xC3, 0xE2, 0xFF };
const soup = "abcXYZ019._/-";

fn randByte(r: std.Random, hi_pct: u32) u8 {
    if (r.uintLessThan(u32, 100) < hi_pct) return hi_pool[r.uintLessThan(usize, hi_pool.len)];
    return soup[r.uintLessThan(usize, soup.len)];
}

/// Pattern from token soup. `flood` emits '*'+literal pairs to the whole
/// buffer: >128 tokens overflow the compiled core's MAXT stack buffer, so
/// every such call that reaches compilation falls back to matchBytewise
/// (not literally every flood call: the raw pre-compile end-byte reject can
/// return false before compileToks when the tail literal mismatches).
fn genPattern(r: std.Random, buf: []u8, flood: bool) []const u8 {
    if (flood) {
        var n: usize = 0;
        while (n + 2 <= buf.len) : (n += 2) {
            buf[n] = '*';
            buf[n + 1] = if (r.boolean()) 'a' else 'x';
        }
        return buf[0..n];
    }
    const limit = r.uintLessThan(usize, buf.len + 1);
    const closed = "a-z0-9x._/[]\\-^!";
    var n: usize = 0;
    while (n < limit) {
        switch (r.uintLessThan(u32, 16)) {
            0 => {
                buf[n] = '*';
                n += 1;
            },
            1 => {
                buf[n] = '?';
                n += 1;
            },
            2 => { // backslash + optional escaped byte (in-bounds guarded)
                buf[n] = '\\';
                n += 1;
                if (n < limit and r.boolean()) {
                    buf[n] = randByte(r, 8);
                    n += 1;
                }
            },
            3 => {
                buf[n] = '[';
                n += 1;
            },
            4 => {
                buf[n] = ']';
                n += 1;
            },
            5 => {
                buf[n] = '^';
                n += 1;
            },
            6 => {
                buf[n] = '!';
                n += 1;
            },
            7 => {
                buf[n] = '-';
                n += 1;
            },
            8 => {
                buf[n] = '.';
                n += 1;
            },
            9 => {
                buf[n] = '/';
                n += 1;
            },
            10, 11, 12 => {
                buf[n] = randByte(r, 10);
                n += 1;
            },
            13 => { // well-formed class, occasionally closed
                const body_len = 1 + r.uintLessThan(usize, 5);
                buf[n] = '[';
                n += 1;
                var k: usize = 0;
                while (k < body_len and n < limit) : (k += 1) {
                    buf[n] = closed[r.uintLessThan(usize, closed.len)];
                    n += 1;
                }
                if (n < limit and r.boolean()) {
                    buf[n] = ']';
                    n += 1;
                }
            },
            else => {
                buf[n] = soup[r.uintLessThan(usize, soup.len)];
                n += 1;
            },
        }
    }
    return buf[0..n];
}

/// Plain (non-meta) skeleton of the pattern: bytes a literal-only matcher
/// would consume. Star rewinds scan for these across the junk we paste
/// between them.
fn skeletonOf(pat: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < pat.len and n < out.len) : (i += 1) {
        const c = pat[i];
        if (c == '\\') {
            if (i + 1 < pat.len) i += 1; // escaped byte is literal
            continue;
        }
        switch (c) {
            '*', '?', '[', ']', '^', '!', '-' => continue,
            else => {
                out[n] = c;
                n += 1;
            },
        }
    }
    return out[0..n];
}

/// String: 50% independent soup, 50% re-pasted pattern chunks (deep-rewind
/// fodder: a star must try every chunk alignment before the true one).
fn genString(r: std.Random, pat: []const u8, buf: []u8) []const u8 {
    if (!r.boolean()) {
        const limit = r.uintLessThan(usize, buf.len + 1);
        var n: usize = 0;
        while (n < limit) : (n += 1) buf[n] = randByte(r, 8);
        return buf[0..n];
    }
    var skel_buf: [512]u8 = undefined;
    const skel = skeletonOf(pat, &skel_buf);
    if (skel.len == 0) return genString(r, "abc", buf); // retry soup path
    const junk = "xZ09./_";
    var n: usize = 0;
    const reps = 1 + r.uintLessThan(usize, 4);
    var rep: usize = 0;
    while (rep < reps and n < buf.len) : (rep += 1) {
        const start = r.uintLessThan(usize, skel.len);
        const len = 1 + r.uintLessThan(usize, skel.len - start);
        const chunk = skel[start .. start + len];
        if (n + chunk.len > buf.len) break;
        @memcpy(buf[n .. n + chunk.len], chunk);
        n += chunk.len;
        if (n < buf.len and r.boolean()) { // junk gap between chunks
            const gap = 1 + r.uintLessThan(usize, 2);
            var k: usize = 0;
            while (k < gap and n < buf.len) : (k += 1) {
                buf[n] = junk[r.uintLessThan(usize, junk.len)];
                n += 1;
            }
        }
    }
    if (n < buf.len and skel.len <= buf.len - n and r.boolean()) { // exact tail
        @memcpy(buf[n .. n + skel.len], skel);
        n += skel.len;
    }
    return buf[0..n];
}

/// Combo is the low 4 bits of the iteration index, so all 16 flag
/// combinations recur. 25% of calls also get junk high bits.
fn genFlags(r: std.Random, combo: usize) c_int {
    var fl: c_int = 0;
    if (combo & 1 != 0) fl |= m.FNM_PATHNAME;
    if (combo & 2 != 0) fl |= m.FNM_NOESCAPE;
    if (combo & 4 != 0) fl |= m.FNM_PERIOD;
    if (combo & 8 != 0) fl |= m.FNM_CASEFOLD;
    if (r.uintLessThan(u32, 100) < 25) fl |= @as(c_int, @bitCast(r.int(u32) & 0xFFFFFFE0));
    return fl;
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 3) {
        std.debug.print("usage: zig run -O ReleaseSafe --dep matcher -Mroot=fuzz/memfuzz.zig -Mmatcher=src/matcher.zig -- <seed> <iters>\n", .{});
        std.process.exit(2);
    }
    const seed = try std.fmt.parseInt(u64, args[1], 0);
    const iters = try std.fmt.parseInt(u64, args[2], 0);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var checksum: u64 = 0;
    var pat_buf: [512]u8 = undefined;
    var str_buf: [1024]u8 = undefined;
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        const pat = genPattern(r, &pat_buf, r.uintLessThan(u32, 8) == 0); // 12.5% flood
        const str = genString(r, pat, &str_buf);
        const fl = genFlags(r, @intCast(i & 0xF));
        checksum = checksum *% 0x9E3779B97F4A7C15 +% @intFromBool(m.matchesFlags(pat, str, fl));
        if (i % 1_000_000 == 0) std.debug.print("memfuzz: {d}/{d} iters, no traps\n", .{ i, iters });
    }
    std.debug.print("memfuzz: done {d} iters, checksum 0x{x}\n", .{ iters, checksum });
}
