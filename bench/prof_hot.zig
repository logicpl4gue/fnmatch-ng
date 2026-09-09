// bench/prof_hot.zig — fnmatch-ng hot-path micro-profile (perf audit lane).
//
// Task: isolate WHERE src/matcher.zig spends time in the workload
// categories where it loses to musl (results/baseline/workloads.json):
// single-star 65 vs 27 ns, suffix-star 75 vs 46 ns, fail-late 102 vs
// 32 ns). This file does NOT optimize anything — it pins costs with
// micro-cases grouped by driver:
//
//   A  trailing-literal tail shape, string length swept  (root-cause
//      candidate: no anchored tail compare — musl's Sea-of-Stars tail)
//      A1 *parser.c  vs  "a"*L+"parser.cx"   NOMATCH, tail fails on 'x'
//      A2 *parser.c  vs  "a"*L+"parser.c"    MATCH, tail found at end
//      A3 *.c        vs  "a"*L+".x"          NOMATCH, one-byte tail
//      A4 *.c        vs  "a"*L+".c"          MATCH, one-byte tail
//   B  pure literal forward pass, length swept (per-byte dispatch cost,
//      no star involved at all)
//      B1 "abcdefghij"*r == string           MATCH
//      B2 same, last byte flipped            NOMATCH (fail-late literal)
//   C  "?"-chain vs equal-length string      (per-byte '?' arm cost)
//   D  "*" alone vs "a"*L                    (star-absorption/rewind cost
//      with no tail to chase)
//   E  flag-check overhead per position, fixed literal workload:
//      E1 flags=0           E2 +CASEFOLD(upper str)  E3 +PERIOD
//      E4 +PATHNAME         E5 CASEFOLD(lower str, short-circuit)
//      E6 CASEFOLD+PERIOD
//
// Timing method mirrors bench/workload.zig (warmup, 5 timed runs,
// >=1024 iters, ~1 ms budget/run, report min ns/match; checksum keeps
// calls live). 0 heap allocations inside the timed region; case strings
// are built once up front.
//
// Run (from the repo root, zig 0.14.1):
//   zig run -O ReleaseFast --dep matcher -Mroot=bench/prof_hot.zig \
//       -Mmatcher=src/matcher.zig [out.jsonl]
// Default out: results/baseline/_prof_hot_ours.jsonl (overwritten).
// Each output line:
//   {"case":"A2","pat":"...","str":"...","flags":["FNM_PERIOD",...],
//    "flags_int":4,"ours_ns":<n>,"patlen":L,"strlen":L}

const std = @import("std");
const matcher = @import("matcher"); // wired via -Mmatcher=src/matcher.zig

var g_checksum: u64 = 0; // keeps timed matches live; printed at the end

const Case = struct {
    name: []const u8,
    pat: []const u8,
    str: []const u8,
    flags: c_int,
};

const FlagNames = struct {
    bits: c_int,
    names: []const []const u8,
};

fn fl(bits: c_int, names: []const []const u8) FlagNames {
    return .{ .bits = bits, .names = names };
}

/// One adaptive timed run: batches of 1024 matches until ~1 ms elapsed
/// (or a hard iteration cap). Returns ns/match (f64).
fn passOnce(pat: []const u8, str: []const u8, flags: c_int) f64 {
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

/// Warmup + 5 timed runs, minimum ns/match, rounded to u64.
fn benchCase(pat: []const u8, str: []const u8, flags: c_int) u64 {
    _ = passOnce(pat, str, flags); // warmup
    var best: f64 = std.math.inf(f64);
    var run: usize = 0;
    while (run < 5) : (run += 1) {
        const v = passOnce(pat, str, flags);
        if (v < best) best = v;
    }
    return @intFromFloat(@round(best));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const args = try std.process.argsAlloc(a);
    const out_path = if (args.len > 1) args[1]
    else "results/baseline/_prof_hot_ours.jsonl";

    var cases = std.ArrayList(Case).init(a);

    // ---- string builders (allocated once, outside the timed region) ----
    const a_rep = "a";
    var buf = std.ArrayList(u8).init(a);

    // A: trailing-literal tails, length sweep L = {4, 16, 64, 256}
    const Ls = [_]usize{ 4, 16, 64, 256 };
    const A_fail_tail = "parser.cx"; // NOMATCH: tail differs in its last region
    const A_match_tail = "parser.c";
    for (Ls) |L| {
        buf.clearRetainingCapacity();
        try buf.appendNTimes(a_rep[0], L);
        try buf.appendSlice(A_fail_tail);
        const s1 = try buf.toOwnedSlice();
        try cases.append(.{ .name = "A1", .pat = "*parser.c", .str = s1, .flags = 0 });

        buf.clearRetainingCapacity();
        try buf.appendNTimes(a_rep[0], L);
        try buf.appendSlice(A_match_tail);
        const s2 = try buf.toOwnedSlice();
        try cases.append(.{ .name = "A2", .pat = "*parser.c", .str = s2, .flags = 0 });

        buf.clearRetainingCapacity();
        try buf.appendNTimes(a_rep[0], L);
        try buf.appendSlice(".x");
        const s3 = try buf.toOwnedSlice();
        try cases.append(.{ .name = "A3", .pat = "*.c", .str = s3, .flags = 0 });

        buf.clearRetainingCapacity();
        try buf.appendNTimes(a_rep[0], L);
        try buf.appendSlice(".c");
        const s4 = try buf.toOwnedSlice();
        try cases.append(.{ .name = "A4", .pat = "*.c", .str = s4, .flags = 0 });
    }

    // A5: string shorter than the required tail (musl: n < tailcnt instant
    // reject; ours scans the whole short string first)
    try cases.append(.{ .name = "A5", .pat = "*parser.c", .str = "abcd", .flags = 0 });
    try cases.append(.{ .name = "A5b", .pat = "*parser.c", .str = "ab", .flags = 0 });

    // A6: class tail after a star (anchored tail must generalize to classes)
    for ([_]usize{ 16, 256 }) |L| {
        buf.clearRetainingCapacity();
        try buf.appendNTimes(a_rep[0], L);
        try buf.appendSlice("bx");
        const s6 = try buf.toOwnedSlice();
        try cases.append(.{ .name = "A6", .pat = "*[a-z]x", .str = s6, .flags = 0 });
    }

    // B: pure literal forward pass, length sweep (per-byte dispatch, no star)
    const Lit = "abcdefghij";
    for ([_]usize{ 4, 16, 64 }) |r| {
        buf.clearRetainingCapacity();
        var ri: usize = 0;
        while (ri < r) : (ri += 1) buf.appendSlice(Lit) catch unreachable;
        const s = try buf.toOwnedSlice();
        try cases.append(.{ .name = "B1", .pat = s, .str = s, .flags = 0 });
        // B2: same pattern, string's final byte flipped ('j' -> 'k')
        var s2 = try a.dupe(u8, s);
        s2[s2.len - 1] = 'k';
        try cases.append(.{ .name = "B2", .pat = s, .str = s2, .flags = 0 });
    }

    // C: '?' chain vs equal-length string
    {
        buf.clearRetainingCapacity();
        const qpat = try a.alloc(u8, 32);
        const qstr = try a.alloc(u8, 32);
        @memset(qpat, '?');
        @memset(qstr, 'a');
        try cases.append(.{ .name = "C", .pat = qpat, .str = qstr, .flags = 0 });
        _ = &buf;
    }

    // D: bare "*" vs long strings (star absorption; musl is O(1) here)
    for (Ls) |L| {
        const s = try a.alloc(u8, L);
        @memset(s, 'a');
        try cases.append(.{ .name = "D", .pat = "*", .str = s, .flags = 0 });
    }

    // E: flag-check overhead per position on a fixed literal workload
    {
        const pat = try a.alloc(u8, 60); // lowercase 'a'*60
        const s_low = try a.alloc(u8, 60); // lowercase 'a'*60 (== pat)
        const s_up = try a.alloc(u8, 60); // uppercase 'A'*60
        @memset(pat, 'a');
        @memset(s_low, 'a');
        @memset(s_up, 'A');
        try cases.append(.{ .name = "E1", .pat = pat, .str = s_low, .flags = 0 });
        try cases.append(.{ .name = "E2", .pat = pat, .str = s_up, .flags = matcher.FNM_CASEFOLD });
        try cases.append(.{ .name = "E3", .pat = pat, .str = s_low, .flags = matcher.FNM_PERIOD });
        try cases.append(.{ .name = "E4", .pat = pat, .str = s_low, .flags = matcher.FNM_PATHNAME });
        try cases.append(.{ .name = "E5", .pat = pat, .str = s_low, .flags = matcher.FNM_CASEFOLD });
        try cases.append(.{ .name = "E6", .pat = pat, .str = s_up, .flags = matcher.FNM_CASEFOLD | matcher.FNM_PERIOD });
    }

    // ---- time + emit ----
    var out = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out.close();
    var w = out.writer();
    var ncase: usize = 0;

    // G: floor measurement — raw std.mem.eql on equal 40B/640B strings
    // (what a literal-run memcmp fast path could approach; no matcher).
    // Printed directly as G rows via the same writer.
    for ([_]usize{ 40, 640 }) |L| {
        const g1 = try a.alloc(u8, L);
        const g2 = try a.alloc(u8, L);
        @memset(g1, 'a');
        @memset(g2, 'a');
        var best: f64 = std.math.inf(f64);
        var run: usize = 0;
        while (run < 5) : (run += 1) {
            var timer = std.time.Timer.start() catch unreachable;
            var iters: u64 = 0;
            var acc: u64 = 0;
            while (true) {
                var i: u64 = 0;
                while (i < 1024) : (i += 1)
                    acc +%= @intFromBool(std.mem.eql(u8, g1, g2));
                iters += 1024;
                if (timer.read() >= 1_000_000 or iters >= (1 << 22)) break;
            }
            g_checksum +%= acc;
            const v = @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iters));
            if (v < best) best = v;
        }
        const gns: u64 = @intFromFloat(@round(best));
        try w.print("{{\"case\":\"G\",\"pat\":\"\",\"str\":\"\",\"flags\":[],\"flags_int\":0,\"ours_ns\":{d},\"patlen\":{d},\"strlen\":{d}}}" ++ "\n", .{ gns, L, L });
        ncase += 1;
    }

    for (cases.items) |c| {
        const nsm = benchCase(c.pat, c.str, c.flags);
        const names = std.fmt.allocPrint(a, "{s}", .{""}) catch unreachable;
        _ = names;
        // map flags_int -> flag name list (readable, matches corpus schema)
        var fnames = std.ArrayList([]const u8).init(a);
        if ((c.flags & matcher.FNM_PATHNAME) != 0) try fnames.append("FNM_PATHNAME");
        if ((c.flags & matcher.FNM_NOESCAPE) != 0) try fnames.append("FNM_NOESCAPE");
        if ((c.flags & matcher.FNM_PERIOD) != 0) try fnames.append("FNM_PERIOD");
        if ((c.flags & matcher.FNM_CASEFOLD) != 0) try fnames.append("FNM_CASEFOLD");
        var jl = std.ArrayList(u8).init(a);
        const wj = jl.writer();
        try wj.print("{{\"case\":\"{s}\",\"pat\":", .{c.name});
        try std.json.stringify(c.pat, .{}, wj);
        try wj.writeAll(",\"str\":");
        try std.json.stringify(c.str, .{}, wj);
        try wj.print(",\"flags\":", .{});
        try std.json.stringify(fnames.items, .{}, wj);
        try wj.print(",\"flags_int\":{d},\"ours_ns\":{d},\"patlen\":{d},\"strlen\":{d}}}\n",
            .{ c.flags, nsm, c.pat.len, c.str.len });
        try w.writeAll(jl.items);
        ncase += 1;
    }

    std.debug.print("prof_hot.zig: {d} micro-cases timed -> {s}\n", .{ ncase, out_path });
    std.debug.print("prof_hot.zig: checksum {d} (match calls kept live)\n", .{g_checksum});
}
