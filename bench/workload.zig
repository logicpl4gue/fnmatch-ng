// bench/workload.zig — fnmatch-ng normal-workload benchmark (plan sections
// 22-25). Mirrors the timing method of bench/adversarial.zig:
//
//   warmup pass, then 5 timed runs of >=1024 iterations each (adaptive
//   ~1 ms budget per run), report the MINIMUM ns/match per case. Calls are
//   kept live via a running checksum printed to stderr at the end (never
//   optimized away). 0 heap allocations per match; corpus parsing happens
//   once up front, outside the timed region.
//
// Reads tests/corpus/workload.jsonl ({pattern,string,flags,category},
// musl-validated by scripts/gen_workload.py), times src/matcher.zig on
// each case with the case's own flags, and emits one JSON object per
// input line:
//
//   {"index":<i>,"category":"...","result":"MATCH"|"NOMATCH","ours_ns":<n>}
//
// Run (from the repo root, zig 0.14.1):
//   zig run -O ReleaseFast --dep matcher -Mroot=bench/workload.zig \
//       -Mmatcher=src/matcher.zig -- tests/corpus/workload.jsonl
// Default out: results/baseline/_workload_ours.jsonl (overwritten).

const std = @import("std");
const matcher = @import("matcher"); // wired via -Mmatcher=src/matcher.zig

var g_checksum: u64 = 0; // keeps timed matches live; printed at the end

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
    g_checksum +%= acc; // data dependency: the matches above cannot be elided
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
    const cases_path = if (args.len > 1) args[1]
    else "tests/corpus/workload.jsonl";
    const out_path = if (args.len > 2) args[2]
    else "results/baseline/_workload_ours.jsonl";

    const src = try std.fs.cwd().readFileAlloc(a, cases_path, 64 << 20);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var lines = std.mem.splitScalar(u8, src, '\n');
    var buf = std.ArrayList(u8).init(a);
    var count: usize = 0;
    var index: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, aa, line, .{});
        const obj = parsed.value.object;
        const pat = obj.get("pattern").?.string;
        const str = obj.get("string").?.string;
        const flags = flagBits(obj.get("flags").?.array);
        const category = obj.get("category").?.string;

        const ours = matcher.matchesFlags(pat, str, flags);
        const res = if (ours) "MATCH" else "NOMATCH";
        const nsm = benchCase(pat, str, flags);
        const line_out = try std.fmt.allocPrint(a,
            "{{\"index\":{d},\"category\":\"{s}\",\"result\":\"{s}\",\"ours_ns\":{d}}}\n",
            .{ index, category, res, nsm });
        try buf.appendSlice(line_out);
        count += 1;
        index += 1;
    }

    const out = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(buf.items);

    std.debug.print("workload.zig: {d} cases timed from {s} -> {s}\n",
        .{ count, cases_path, out_path });
    std.debug.print("workload.zig: checksum {d} (match calls kept live)\n",
        .{g_checksum});
}
