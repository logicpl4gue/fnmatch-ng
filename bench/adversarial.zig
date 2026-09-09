// bench/adversarial.zig — fnmatch-ng adversarial complexity study (plan §21).
//
// Measures the REWRITE (src/matcher.zig, flags=0) on the classic
// pathological wildcard families, in the same shape as the reference
// measurement made by bench/adversarial_run.py against vendored musl:
//
//   (A) "*a*a*...*a*b"  (k a-tokens, k=2..10)  vs  "a"*n   (n=8..64, step 8)
//       -> failing match: no 'b' anywhere.      [k x 8 cases]
//   (B) same pattern                            vs  "a"*n+"b" (n >= k)
//       -> matching tail: the '*' before 'b' absorbs n-k a's.  [k x 8]
//   (C) "?"*n                                   vs  "a"*n+"b"
//       -> ?-only pattern, mismatch on the trailing 'b'.       [8 cases]
//   (D) "*[a]*[a]*...*[a]*b" (k class-tokens)   vs  "a"*n      -> failing
//   (E) same class pattern                      vs  "a"*n+"b"  -> matching
//
// Timing method (mirrors the task contract): warmup pass, then 5 timed
// runs of >=1000 iterations each (adaptive ~1 ms budget per run); report
// the MINIMUM ns/match. Calls are kept live via a running checksum that is
// printed to stderr at the end (never optimized away). 0 heap allocations
// per match; pattern/string buffers are stack arrays.
//
// Run (from the repo root, zig 0.14.1):
//   zig run -O ReleaseFast bench/adversarial.zig -- [out.jsonl]
// Default out: results/baseline/adversarial_cases.jsonl
// Each output line: {"family","k","n","pattern","string","flags":[],
//                    "result","pattern_len","string_len","ours_ns"}
// (extra keys are ignored by the reference parse_case in ref_harness.c)

const std = @import("std");
const matcher = @import("matcher"); // wired via -Mmatcher=src/matcher.zig (see adversarial_run.py)

const k_lo: usize = 2;
const k_hi: usize = 10;
const ns_vals = [_]usize{ 8, 16, 24, 32, 40, 48, 56, 64 };

var g_checksum: u64 = 0; // keeps timed matches live; printed at the end

/// One adaptive timed run: batches of 1024 matches until >=1000 iters and
/// ~1 ms elapsed (or a hard iteration cap). Returns ns/match (f64).
fn passOnce(pat: []const u8, str: []const u8) f64 {
    var timer = std.time.Timer.start() catch unreachable;
    var iters: u64 = 0;
    var acc: u64 = 0;
    while (true) {
        var i: u64 = 0;
        while (i < 1024) : (i += 1)
            acc +%= @intFromBool(matcher.matchesFlags(pat, str, 0));
        iters += 1024;
        if (timer.read() >= 1_000_000 or iters >= (1 << 22)) break;
    }
    g_checksum +%= acc; // data dependency: the matches above cannot be elided
    return @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iters));
}

/// Warmup + 5 timed runs, minimum ns/match, rounded to u64.
fn benchCase(pat: []const u8, str: []const u8) u64 {
    _ = passOnce(pat, str); // warmup
    var best: f64 = std.math.inf(f64);
    var run: usize = 0;
    while (run < 5) : (run += 1) {
        const v = passOnce(pat, str);
        if (v < best) best = v;
    }
    return @intFromFloat(@round(best));
}

/// Fill buf with a repeated token ("*a" or "*[a]") k times, then "*b".
fn starPat(k: usize, buf: []u8, tok: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < k) : (i += 1) {
        @memcpy(buf[n..][0..tok.len], tok);
        n += tok.len;
    }
    @memcpy(buf[n..][0..2], "*b");
    return buf[0 .. n + 2];
}

/// Fill buf with n 'a's (plus a trailing 'b' when with_b).
fn aString(n: usize, with_b: bool, buf: []u8) []const u8 {
    @memset(buf[0..n], 'a');
    var len = n;
    if (with_b) {
        buf[n] = 'b';
        len += 1;
    }
    return buf[0..len];
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    const out_path = if (args.len > 1) args[1] else "results/baseline/adversarial_cases.jsonl";

    var buf = std.ArrayList(u8).init(alloc);
    var np: [128]u8 = undefined; // pattern scratch
    var ns: [128]u8 = undefined; // string scratch
    var count: usize = 0;

    // (A) literal a-tokens, failing ("a"*n has no 'b')
    for (k_lo..(k_hi + 1)) |k| {
        const pat = starPat(k, &np, "*a");
        for (ns_vals) |n| {
            const str = aString(n, false, &ns);
            const ours = matcher.matchesFlags(pat, str, 0);
            const res = if (ours) "MATCH" else "NOMATCH";
            const nsm = benchCase(pat, str);
            const line = try std.fmt.allocPrint(alloc, "{{\"family\":\"A\",\"k\":{d},\"n\":{d},\"pattern\":\"{s}\",\"string\":\"{s}\",\"flags\":[],\"result\":\"{s}\",\"pattern_len\":{d},\"string_len\":{d},\"ours_ns\":{d}}}\n", .{ k, n, pat, str, res, pat.len, str.len, nsm });
            try buf.appendSlice(line);
            count += 1;
        }
    }
    // (B) literal a-tokens, matching tail ("a"*n+"b", n >= k)
    for (k_lo..(k_hi + 1)) |k| {
        const pat = starPat(k, &np, "*a");
        for (ns_vals) |n| {
            if (n < k) continue;
            const str = aString(n, true, &ns);
            const ours = matcher.matchesFlags(pat, str, 0);
            const res = if (ours) "MATCH" else "NOMATCH";
            const nsm = benchCase(pat, str);
            const line = try std.fmt.allocPrint(alloc, "{{\"family\":\"B\",\"k\":{d},\"n\":{d},\"pattern\":\"{s}\",\"string\":\"{s}\",\"flags\":[],\"result\":\"{s}\",\"pattern_len\":{d},\"string_len\":{d},\"ours_ns\":{d}}}\n", .{ k, n, pat, str, res, pat.len, str.len, nsm });
            try buf.appendSlice(line);
            count += 1;
        }
    }
    // (C) '?'-only pattern, mismatch on the trailing 'b'
    for (ns_vals) |n| {
        @memset(np[0..n], '?');
        const pat = np[0..n];
        const str = aString(n, true, &ns);
        const ours = matcher.matchesFlags(pat, str, 0);
        const res = if (ours) "MATCH" else "NOMATCH";
        const nsm = benchCase(pat, str);
        const line = try std.fmt.allocPrint(alloc, "{{\"family\":\"C\",\"k\":0,\"n\":{d},\"pattern\":\"{s}\",\"string\":\"{s}\",\"flags\":[],\"result\":\"{s}\",\"pattern_len\":{d},\"string_len\":{d},\"ours_ns\":{d}}}\n", .{ n, pat, str, res, pat.len, str.len, nsm });
        try buf.appendSlice(line);
        count += 1;
    }
    // (D) bracket class-tokens, failing
    for (k_lo..(k_hi + 1)) |k| {
        const pat = starPat(k, &np, "*[a]");
        for (ns_vals) |n| {
            const str = aString(n, false, &ns);
            const ours = matcher.matchesFlags(pat, str, 0);
            const res = if (ours) "MATCH" else "NOMATCH";
            const nsm = benchCase(pat, str);
            const line = try std.fmt.allocPrint(alloc, "{{\"family\":\"D\",\"k\":{d},\"n\":{d},\"pattern\":\"{s}\",\"string\":\"{s}\",\"flags\":[],\"result\":\"{s}\",\"pattern_len\":{d},\"string_len\":{d},\"ours_ns\":{d}}}\n", .{ k, n, pat, str, res, pat.len, str.len, nsm });
            try buf.appendSlice(line);
            count += 1;
        }
    }
    // (E) bracket class-tokens, matching tail (n >= k)
    for (k_lo..(k_hi + 1)) |k| {
        const pat = starPat(k, &np, "*[a]");
        for (ns_vals) |n| {
            if (n < k) continue;
            const str = aString(n, true, &ns);
            const ours = matcher.matchesFlags(pat, str, 0);
            const res = if (ours) "MATCH" else "NOMATCH";
            const nsm = benchCase(pat, str);
            const line = try std.fmt.allocPrint(alloc, "{{\"family\":\"E\",\"k\":{d},\"n\":{d},\"pattern\":\"{s}\",\"string\":\"{s}\",\"flags\":[],\"result\":\"{s}\",\"pattern_len\":{d},\"string_len\":{d},\"ours_ns\":{d}}}\n", .{ k, n, pat, str, res, pat.len, str.len, nsm });
            try buf.appendSlice(line);
            count += 1;
        }
    }

    const out = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(buf.items);

    std.debug.print("adversarial.zig: {d} cases written to {s}\n", .{ count, out_path });
    std.debug.print("adversarial.zig: checksum {d} (match calls kept live)\n", .{g_checksum});
}
