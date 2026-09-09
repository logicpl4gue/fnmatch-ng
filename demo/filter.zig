// demo/filter.zig — real-consumer demo (plan "real-consumer demo"): a
// find-style file filter built directly on fnmatch-ng's Zig API.
//
// Selectors mirror POSIX find, mapped onto fnmatch-ng flag bits:
//   -name GLOB  match the entry's basename  -> FNM_PERIOD          (find -name)
//   -path GLOB  match the '/' -normalized relative path
//               -> FNM_PATHNAME | FNM_PERIOD                        (find -path)
// Multiple selectors OR together; with no selectors every path is printed
// (the find default). Hidden entries are shown only when a selector
// matches them (the FNM_PERIOD gate).
//
// --verify      every selector verdict is re-checked against the vendored
//               musl 1.2.5 reference, which is linked in-process from
//               compat/musl_fnmatch.c (this Windows box has no system
//               fnmatch). Disagreements go to stderr; exit code 1 if any.
// --paths-from FILE
//               take candidate paths from a JSONL corpus's "string" field
//               (e.g. tests/corpus/workload.jsonl) instead of walking the
//               filesystem. The corpus "pattern" fields are ignored — the
//               -name/-path selectors are the filter.
// --selftest    run the built-in 5-case check (fnmatch-ng README examples
//               in find semantics, plus a musl cross-check) and exit.
//
// Usage (from the repo root, zig 0.14.1). -lc supplies libc headers for
// the vendored musl C file; the matcher module wire is the repo convention
// from bench/workload.zig:
//   zig run -O ReleaseFast -lc --dep matcher -Mroot=demo/filter.zig \
//       -Mmatcher=src/matcher.zig compat/musl_fnmatch.c -- <root> <selectors>
// Examples:
//   zig run -O ReleaseFast -lc --dep matcher -Mroot=demo/filter.zig \
//     -Mmatcher=src/matcher.zig compat/musl_fnmatch.c -- . -name '*.zig'
//   ... -- tests/corpus/workload.jsonl -name '*.html' -path 'share/*' --verify

const std = @import("std");
const m = @import("matcher");

extern fn fnmatch(pattern: [*:0]const u8, string: [*:0]const u8, flags: c_int) c_int;

const FLAG_NAME: c_int = m.FNM_PERIOD; // -name
const FLAG_PATH: c_int = m.FNM_PATHNAME | m.FNM_PERIOD; // -path

const Selector = struct { kind: enum { name, path }, glob: []const u8 };

/// '/' -normalized relative path (walkDir separates with '\' on Windows).
fn normPath(alloc: std.mem.Allocator, p: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, p);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Basename on either separator (std.fs.path.basename is platform-bound).
fn baseOf(rel: []const u8) []const u8 {
    var i = rel.len;
    while (i > 0) : (i -= 1) {
        if (rel[i - 1] == '/' or rel[i - 1] == '\\') return rel[i..];
    }
    return rel;
}

fn ours(sel: Selector, rel: []const u8) bool {
    return switch (sel.kind) {
        .name => m.matchesFlags(sel.glob, baseOf(rel), FLAG_NAME),
        .path => m.matchesFlags(sel.glob, rel, FLAG_PATH),
    };
}

fn muslVerdict(alloc: std.mem.Allocator, sel: Selector, rel: []const u8) !bool {
    const cflags: c_int = switch (sel.kind) {
        .name => FLAG_NAME,
        .path => FLAG_PATH,
    };
    // ours() feeds -name the BASENAME (baseOf(rel)), so musl must judge the
    // same target: a full rel would let '*' cross '/' and dodge the
    // FNM_PERIOD leading-dot gate, mis-verifying nested paths.
    const target: []const u8 = switch (sel.kind) {
        .name => baseOf(rel),
        .path => rel,
    };
    const pz = try alloc.dupeZ(u8, sel.glob);
    const rz = try alloc.dupeZ(u8, target);
    return fnmatch(pz, rz, cflags) == 0; // 0 == match, 1 == FNM_NOMATCH
}

const Ctx = struct {
    alloc: std.mem.Allocator,
    sels: []const Selector,
    verify: bool,
    out: std.fs.File.Writer,
    checked: *u64,
    mismatches: *u64,
};

fn handlePath(ctx: *Ctx, p: []const u8) !void {
    const rel = try normPath(ctx.alloc, p);
    var hit = ctx.sels.len == 0;
    for (ctx.sels) |sel| {
        const got = ours(sel, rel);
        hit = hit or got;
        if (ctx.verify) {
            const want = try muslVerdict(ctx.alloc, sel, rel);
            ctx.checked.* += 1;
            if (got != want) {
                ctx.mismatches.* += 1;
                std.debug.print("filter MISMATCH: {s} {s} vs <{s}> ours={any} musl={any}\n", .{
                    @tagName(sel.kind), sel.glob, rel, got, want,
                });
            }
        }
    }
    if (hit) try ctx.out.print("{s}\n", .{rel});
}

fn selftest() !void {
    const E = error.SelfTestFailed;
    if (m.matchesFlags("*.zig", "main.zig", FLAG_NAME) != true) return E; // -name: plain file
    if (m.matchesFlags("*.zig", ".main.zig", FLAG_NAME) != false) return E; // -name: leading dot hidden
    if (m.matchesFlags("src/*.zig", "src/main.zig", FLAG_PATH) != true) return E;
    if (m.matchesFlags("src/*.zig", "src/a/b.zig", FLAG_PATH) != false) return E; // * cannot cross '/'
    if (m.matchesFlags("a\\*b", "a*b", 0) != true) return E; // escaped star is a literal
    const pz: [:0]const u8 = "*.zig";
    const sz: [:0]const u8 = "main.zig";
    if (fnmatch(pz, sz, FLAG_NAME) != 0) return E; // musl agrees with -name gate
    std.debug.print("filter selftest: 5/5 ok, musl cross-check ok\n", .{});
}

fn usage() noreturn {
    std.debug.print("usage: filter.zig [root] [-name GLOB | -path GLOB]... [--paths-from FILE] [--verify] [--selftest]\n", .{});
    std.process.exit(2);
}

/// Minimal JSON string decoder for a corpus line's "string" field.
fn extractString(alloc: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const key = "\"string\"";
    const k = std.mem.indexOf(u8, line, key) orelse return null;
    var p = k + key.len;
    while (p < line.len and line[p] != ':') p += 1;
    p += 1;
    while (p < line.len and (line[p] == ' ' or line[p] == '\t')) p += 1;
    if (p >= line.len or line[p] != '"') return null;
    p += 1;
    var out = std.ArrayList(u8).init(alloc);
    while (p < line.len) : (p += 1) {
        const c = line[p];
        if (c == '"') break;
        if (c == '\\' and p + 1 < line.len) {
            p += 1;
            switch (line[p]) {
                '"' => try out.append('"'),
                '\\' => try out.append('\\'),
                '/' => try out.append('/'),
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                'b' => try out.append(0x08),
                'f' => try out.append(0x0C),
                'u' => { // 4 hex digits -> UTF-8 (no surrogate pairs in corpora)
                    if (p + 4 >= line.len) return null;
                    const cp = try std.fmt.parseInt(u21, line[p + 1 .. p + 5], 16);
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &tmp) catch return null;
                    try out.appendSlice(tmp[0..n]);
                    p += 4;
                },
                else => try out.append(line[p]),
            }
        } else try out.append(c);
    }
    return out.items;
}

fn runWalk(ctx: *Ctx, root: []const u8) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    var walker = try dir.walk(ctx.alloc);
    while (true) {
        const e = walker.next() catch continue; // skip unreadable subtrees
        if (e) |en| {
            try handlePath(ctx, en.path);
        } else break;
    }
}

fn runCorpus(ctx: *Ctx, file: []const u8) !void {
    const f = try std.fs.cwd().openFile(file, .{});
    defer f.close();
    var buf: [1 << 20]u8 = undefined;
    var br = std.io.bufferedReader(f.reader());
    const r = br.reader();
    while (try r.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        if (try extractString(ctx.alloc, line)) |s| try handlePath(ctx, s);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = try std.process.argsAlloc(alloc);

    var root: []const u8 = ".";
    var paths_from: ?[]const u8 = null;
    var verify = false;
    var sel_list = std.ArrayList(Selector).init(alloc);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--selftest")) {
            try selftest();
            return;
        } else if (std.mem.eql(u8, a, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, a, "--paths-from")) {
            i += 1;
            if (i >= args.len) usage();
            paths_from = args[i];
        } else if (std.mem.eql(u8, a, "-name") or std.mem.eql(u8, a, "-path")) {
            i += 1;
            if (i >= args.len) usage();
            try sel_list.append(.{ .kind = if (a[1] == 'n') .name else .path, .glob = args[i] });
        } else if (a.len > 0 and a[0] == '-') {
            usage();
        } else {
            root = a;
        }
    }

    var checked: u64 = 0;
    var mismatches: u64 = 0;
    var ctx = Ctx{
        .alloc = alloc,
        .sels = sel_list.items,
        .verify = verify,
        .out = std.io.getStdOut().writer(),
        .checked = &checked,
        .mismatches = &mismatches,
    };
    if (paths_from) |f| {
        try runCorpus(&ctx, f);
    } else {
        try runWalk(&ctx, root);
    }
    if (verify) {
        std.debug.print("filter: verified {d} selector/path verdicts vs musl, {d} mismatches\n", .{ checked, mismatches });
        if (mismatches > 0) std.process.exit(1);
    }
}
