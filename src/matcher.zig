// src/matcher.zig: fnmatch-ng core matcher (Zig).
//
// Scope: POSIX fnmatch(3) semantics for the C/POSIX locale, mirroring the
// vendored musl 1.2.5 reference (compat/):
//   M1  literal bytes, '?', '*'
//   M2  FNM_PATHNAME ('*'/'?'/classes never match '/')
//   M3  backslash escaping outside classes ('\' escapes the next byte; a
//       trailing lone '\' is an ordinary literal backslash, musl D002/D003;
//       FNM_NOESCAPE (0x2) restores plain-byte backslash). Inside a class,
//       backslash is an ORDINARY member byte (musl / POSIX: FNM_NOESCAPE
//       is never consulted inside a class). POSIX spans [: :] / [. .] /
//       [= =] are recognized by the scanner so class boundaries match musl
//       but never match a byte: documented deferred divergence.
//   M4  bracket expressions [abc], [a-z] ranges, [!...] / [^...] negation,
//       literal ']' in first position, literal '-' in first/last position,
//       unterminated '[' degrading to a literal byte.
//   M5  FNM_PERIOD (0x4): a segment-leading '.' must be consumed by a RAW
//       unescaped literal '.' (musl's per-segment first-byte check); an
//       escaped '\.' at a leading position is NOMATCH (pinned vector, D005).
//   M6  FNM_CASEFOLD (0x10), C/POSIX locale, ASCII-only fold applied to the
//       STRING byte only (pattern bytes raw), bytes >= 0x80 never fold.
//
// M9 (perf audit port, docs/perf/scan.md): compile-once-then-match core.
// The pattern is compiled per call into a stack token array (0 heap allocs;
// MAXT=128 tokens; longer patterns fall back to the bytewise matcher):
//   * maximal raw literal runs become one .run token consumed by a single
//     slice compare (raw memcmp when NOT FNM_CASEFOLD; guardrail 15);
//   * the tail after the LAST '*' (when it is one raw literal run) is
//     anchored to the string end (endswith reject first, then one bounded
//     recursion over the shortened prefix), disabled under FNM_PERIOD;
//   * plain-flags only (no PATHNAME/PERIOD/CASEFOLD): a star whose next
//     token is a literal run jumps to the next candidate byte with memchr,
//     and a pattern ending in '*' absorbs the whole remainder at once;
//   * bracket bodies are tokenized once (no scanClass re-scan per retry);
//   * flags are hoisted to booleans before the loop.
//
// D006 (found by the M9 audit): the bytewise star rewind previously guarded
// the FAILURE byte against '/' instead of the byte ADDED to the star cover.
// A deep failure after a literal '/' was consumed let the star cover grow
// across '/', diverging from musl (e.g. "*/x.c" vs "a/b/x.c" PATHNAME was
// MATCH here, NOMATCH in musl). Both matcher paths now use the cover-add
// guard: on star retry under FNM_PATHNAME, reject when str[rewind] == '/'
// (the byte about to join the star cover). Regression vectors appended to
// tests/unit/m2_pathname.jsonl.
//
// Returns true when `string` matches `pattern`.

const std = @import("std");

/// Flag bits. Values match compat/musl_fnmatch.h (the differential
/// reference): musl/glibc/POSIX all define FNM_PATHNAME 0x1,
/// FNM_NOESCAPE 0x2, FNM_PERIOD 0x4, FNM_CASEFOLD 0x10 (FNM_LEADING_DIR
/// 0x8 exists there but is not implemented here).
pub const FNM_PATHNAME: c_int = 0x1;
pub const FNM_NOESCAPE: c_int = 0x2;
pub const FNM_PERIOD: c_int = 0x4;
pub const FNM_CASEFOLD: c_int = 0x10;

pub fn matches(pattern: []const u8, string: []const u8) bool {
    return matchesFlags(pattern, string, 0);
}

// ---------------------------------------------------------------------------
// Shared byte-level helpers (used by both the compiled token loop and the
// bytewise fallback).
// ---------------------------------------------------------------------------

/// Pattern token parsed at byte index `p` (bytewise matcher).
const Token = struct {
    kind: enum { end, star, question, lit, cls },
    ch: u8 = 0, // literal byte when kind == .lit
    step: usize = 0, // pattern bytes consumed (1, 2, or a full class)
    a: usize = 0, // class content start index (kind == .cls)
    b: usize = 0, // class closer index, content exclusive end (kind == .cls)
};

/// Mirror musl pat_next's '[' scan: optional '^'/'!' negation, a literal
/// ']' in the first member position, POSIX [: :]/[. .]/[= =] spans skipped
/// as units (an unterminated span makes the whole bracket unterminated),
/// then the closing ']'. Returns the closer index, or null when the bracket
/// is unterminated; the caller then treats '[' as an ordinary literal byte.
/// FNM_NOESCAPE does not affect this scan (backslash is not special inside
/// a class).
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
            if (k == pattern.len) return null; // unterminated span -> literal '['
        }
    }
    if (k == pattern.len) return null;
    return k;
}

fn tokenAt(pattern: []const u8, p: usize, flags: c_int) Token {
    if (p >= pattern.len) return .{ .kind = .end };
    const noescape = (flags & FNM_NOESCAPE) != 0;
    const pc = pattern[p];
    if (!noescape and pc == '\\' and p + 1 < pattern.len)
        return .{ .kind = .lit, .ch = pattern[p + 1], .step = 2 };
    if (pc == '[') {
        if (scanClass(pattern, p)) |close|
            return .{ .kind = .cls, .step = close - p + 1, .a = p + 1, .b = close };
        return .{ .kind = .lit, .ch = '[', .step = 1 }; // unterminated: literal
    }
    return switch (pc) {
        '*' => .{ .kind = .star, .step = 1 },
        '?' => .{ .kind = .question, .step = 1 },
        else => .{ .kind = .lit, .ch = pc, .step = 1 },
    };
}

/// musl's casefold(k) applied to one byte: towupper(k), falling back to
/// towlower(k) when the byte has no uppercase form: for an ASCII letter
/// that is exactly its opposite case. C-locale ASCII-only scope (M6);
/// bytes >= 0x80 pass through unchanged.
fn foldByte(k: u8) u8 {
    if (k >= 'a' and k <= 'z') return k - 32;
    if (k >= 'A' and k <= 'Z') return k + 32;
    return k;
}

/// musl match_bracket, byte-wise C locale (see M4 notes in the header).
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
            i += 1; // consume '-'; musl still checks the endpoint as a member
            continue;
        }
        if (content[i] == '[' and i + 1 < content.len and
            (content[i + 1] == ':' or content[i + 1] == '.' or content[i + 1] == '='))
        {
            const z = content[i + 1];
            i += 3;
            while (i < content.len and !(content[i - 1] == z and content[i] == ']')) i += 1;
            i += 1; // consume the z] pair
            continue;
        }
        wc = content[i];
        if (wc == c or wc == c2) return !inv;
        i += 1;
    }
    return inv;
}

// ---------------------------------------------------------------------------
// Compiled-token matcher (M9 core; star-skip / memchr-lane port).
// ---------------------------------------------------------------------------

const MAXT = 128; // compiled-token capacity; longer patterns fall back to
// matchBytewise (correctness preserved). Small stack frame matters:
// measuring showed MAXT=2048 cost a flat ~20-25 ns/call (see docs/perf/scan.md).

const CToken = union(enum) {
    star: usize, // pattern byte index of the LAST '*' of a collapsed run
    q,
    run: struct { start: usize, len: usize }, // multi-byte raw literal run (len >= 2)
    esc: struct { b: u8, i: usize }, // single literal byte: 1-byte run, escape
    // pair, lone trailing '\', degraded '[', or singleton class [x].
    // i = pattern index of the token's first pattern byte (the raw-byte
    // PERIOD gate needs it: a raw unescaped '.' has pat[i]=='.', an escaped
    // '\.' has pat[i]=='\\', a class [.] has pat[i]=='[').
    cls: struct { a: usize, b: usize }, // class content = pattern[a..b]
};

/// Compile metadata: token count plus structure flags that let the caller
/// skip work. pure_literal: the whole pattern is one raw literal (no
/// star/?/[/escape); last_star: token index of the LAST star (if any);
/// star_final: the last star is also the final token (tail is empty).
const Compiled = struct {
    n: usize,
    pure_literal: bool,
    last_star: ?usize,
    star_final: bool,
};

/// A positive class whose body is exactly one plain byte (no negation, no
/// range, no span) is a bare byte equality, so encode it as .esc. EXCEPT a
/// '/' member: under FNM_PATHNAME a class can never match '/', while an
/// .esc literal '/' (raw or escaped) CAN, so '[/]' must stay a class.
fn singletonByte(content: []const u8) ?u8 {
    if (content.len != 1) return null;
    const b = content[0];
    if (b == '^' or b == '!') return null; // negated-empty = matches any byte
    if (b == '/') return null; // class may not match '/' under FNM_PATHNAME
    return b;
}

/// Enumerate the member bytes of a simple positive class (no ranges, no
/// spans, no negation, no embedded ']') into `out`. Returns member count,
/// or null when the body is too complex to enumerate cheaply (caller then
/// byte-steps instead of skipping).
fn classMembers(content: []const u8, out: *[8]u8) ?usize {
    if (content.len == 0) return 0;
    if (content[0] == '^' or content[0] == '!') return null; // negated
    var m: usize = 0;
    var i: usize = 0;
    if (content[i] == ']') { // leading ']' literal member (musl)
        out[m] = ']';
        m += 1;
        i += 1;
    } else if (content[i] == '-') { // leading '-' literal member
        out[m] = '-';
        m += 1;
        i += 1;
    }
    while (i < content.len) : (i += 1) {
        const b = content[i];
        if (b == '-' or b == '[') return null; // range / span: bail
        if (m >= 8) return null;
        out[m] = b;
        m += 1;
    }
    return m;
}

fn addCand(set: []u8, n: *usize, b: u8) void {
    for (set[0..n.*]) |x| if (x == b) return;
    if (n.* >= set.len) return;
    set[n.*] = b;
    n.* += 1;
}

/// Pattern -> tokens. Restructuring vs a plain bytewise walk (all
/// semantics-identical, musl-verified on the corpus):
///   a. consecutive '*' collapse into one .star (keeping the LAST star's
///      pattern index so the tail anchor still lines up);
///   b. 1-byte raw literal runs become .esc (one byte compare instead of a
///      runEq call);
///   c. singleton positive classes ([a], [.], [-], []] ...) become .esc of
///      that byte (classMember for a single non-negated member is exactly a
///      byte equality, incl. the fold semantics); '/' members stay .cls;
///   d. multi-byte literal runs stay .run (tail-anchor candidates).
/// Returns null on buffer overflow (caller falls back to matchBytewise).
fn compileToks(p: []const u8, noescape: bool, buf: []CToken) ?Compiled {
    var n: usize = 0;
    var i: usize = 0;
    var last_star: ?usize = null;
    while (i < p.len) {
        if (n + 1 > buf.len) return null;
        const c = p[i];
        if (!noescape and c == '\\') {
            if (i + 1 < p.len) {
                buf[n] = .{ .esc = .{ .b = p[i + 1], .i = i } };
                n += 1;
                i += 2;
            } else { // trailing lone backslash = literal '\' (musl D002/D003)
                buf[n] = .{ .esc = .{ .b = '\\', .i = i } };
                n += 1;
                i += 1;
            }
        } else if (c == '*') {
            if (n > 0 and buf[n - 1] == .star) {
                buf[n - 1] = .{ .star = i }; // collapse; keep the LAST '*'
                i += 1;
            } else {
                buf[n] = .{ .star = i };
                last_star = n;
                n += 1;
                i += 1;
            }
        } else if (c == '?') {
            buf[n] = .q;
            n += 1;
            i += 1;
        } else if (c == '[') {
            if (scanClass(p, i)) |cl| {
                const content = p[i + 1 .. cl];
                if (singletonByte(content)) |b| {
                    buf[n] = .{ .esc = .{ .b = b, .i = i } };
                } else {
                    buf[n] = .{ .cls = .{ .a = i + 1, .b = cl } };
                }
                n += 1;
                i = cl + 1;
            } else { // unterminated: '[' is an ordinary literal byte (musl)
                buf[n] = .{ .esc = .{ .b = '[', .i = i } };
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
            const len = i - start;
            if (len == 1) {
                buf[n] = .{ .esc = .{ .b = p[start], .i = start } };
            } else {
                buf[n] = .{ .run = .{ .start = start, .len = len } };
            }
            n += 1;
        }
    }
    return .{
        .n = n,
        .pure_literal = n == 1 and ((buf[0] == .run and buf[0].run.len == p.len) or
            (buf[0] == .esc and p.len == 1)),
        .last_star = last_star,
        .star_final = (last_star != null and last_star.? == n - 1),
    };
}

/// Literal-run equality: pattern run (raw bytes) vs string run. Under
/// FNM_CASEFOLD the STRING byte is folded toward the raw pattern byte
/// (matcher/musl semantics); plain mode is a straight bulk compare
/// (guardrail 15: no raw memcmp under CASEFOLD).
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

/// Compiled-token matcher over one bounded recursion (tail anchor).
///
/// Star-retry acceleration (memchr lane, docs/perf/scan.md): when a star's
/// continuation token fails, the matcher does not byte-step. It jumps to the
/// next string position where that token could possibly match, using a
/// necessary-condition candidate set built from the token's first byte:
///   * .esc continuation -> {b, fold(b)};
///   * .run continuation -> {first byte, fold(first)};
///   * simple positive .cls -> its enumerated members (+ folds).
/// The jump is bounded so it can never violate the PATHNAME cover guard or
/// the PERIOD segment gate (guardrails 4 and 1-3):
///   * under FNM_PATHNAME the bytes a star ABSORBS must all be != '/'; the
///     search stops at (and includes) the next '/', so nothing is skipped
///     across a separator (the D006 cover-add guard stays the final word),
///     and landing ON a '/' is allowed because a literal continuation may
///     consume it;
///   * every jump lands back at the loop top where the PERIOD gate re-runs
///     before the token is consumed (guardrail 3).
fn go(pat: []const u8, str: []const u8, flags: c_int, buf: []CToken) bool {
    const pathname = (flags & FNM_PATHNAME) != 0;
    const period = (flags & FNM_PERIOD) != 0;
    const folding = (flags & FNM_CASEFOLD) != 0;
    const noescape = (flags & FNM_NOESCAPE) != 0;

    // Leading-run guard (M9/early): a pattern opening with plain literals
    // must match them against string[0..k] (fold-aware). Reject before paying
    // for compileToks. The run stops at '*', '?', '[' or (unless NOESCAPE)
    // '\': escapes and classes need token semantics (D005 raw-byte PERIOD
    // gate, D002/D003). A leading raw run must consume str[0..k], so any
    // fold-mismatch inside it is conclusive.
    {
        var k: usize = 0;
        while (k < pat.len and pat[k] != '*' and pat[k] != '?' and pat[k] != '[' and
            (noescape or pat[k] != '\\')) : (k += 1) {}
        if (k > 0) {
            if (str.len < k) return false;
            var i: usize = 0;
            while (i < k) : (i += 1) {
                if (!(str[i] == pat[i] or (folding and foldByte(str[i]) == pat[i])))
                    return false;
            }
        }
        // (k == 0: empty pattern or a meta opening — nothing to pre-check.)
    }

    // Raw pre-compile end-byte reject: any full match consumes the final
    // string byte with the final pattern byte, so when the pattern ends in a
    // plain literal (raw, escaped, or a trailing lone '\') the string's last
    // byte must fold-equal it. Runs on the RAW pattern so failing star-flood
    // patterns (tail literal 'b' vs an all-'a' string) reject WITHOUT paying
    // the token compile at all. Meta/class-closing tails are skipped
    // conservatively ('*','?','[',']' may not be a plain literal: ']' may
    // close a class whose body ends in a backslash member, e.g. "[\]"; the
    // exact token-level endcheck below covers those after compile). Any
    // OTHER final byte is a raw literal outside a class (unterminated
    // classes degrade to literals), so the string's last byte must
    // fold-equal it.
    // Raw-end cover flag: a chk tail forces the final token to .esc/.run on
    // the identical byte, so the token-level endcheck below can skip those
    // arms (a ']'/'?'/'*' tail makes chk false and still runs them).
    const raw_end_ok = str.len > 0 and pat.len > 0 and
        (pat[pat.len - 1] != '*' and pat[pat.len - 1] != '?' and
        pat[pat.len - 1] != '[' and pat[pat.len - 1] != ']');
    if (raw_end_ok) {
        const p_last = pat[pat.len - 1];
        const last = str[str.len - 1];
        if (!(last == p_last or (folding and foldByte(last) == p_last)))
            return false;
    }

    const compiled = compileToks(pat, noescape, buf) orelse
        return matchBytewise(pat, str, flags); // overflow fallback
    const n = compiled.n;

    // Pure-literal pattern: the whole string must equal it (runEq checks
    // lengths first). Skipping the token loop removes per-call dispatch
    // overhead on the literal-heavy workload.
    if (compiled.pure_literal) return runEq(pat, str, folding);

    // --- tail anchor: MULTI-BYTE literal tails only ------------------------
    // If the only token after the LAST star is one raw literal run covering
    // pat[star+1..], any full match must end with that run consuming the
    // string's final bytes: endswith reject first, then one bounded
    // recursion over the shortened prefix (which now ends in '*'). Single-
    // byte tails are .esc tokens (not .run) and do NOT anchor: their anchor
    // recursion is what made the star-flood matching families (B/E) walk
    // O(n); those resolve faster via the walk+skip path. Skipped when the
    // star is final (tail empty). Disabled under FNM_PERIOD: stripping
    // relocates a segment-leading '.' to string position 0 where the star
    // token would be misjudged (vector *.x vs .x, PERIOD -> NOMATCH must
    // hold). The recursion runs through this same go(), so the D006 cover
    // guard keeps the star from ever covering '/' under PATHNAME.
    if ((flags & FNM_PERIOD) == 0 and !compiled.star_final) {
        if (compiled.last_star) |ls| {
            const ps = buf[ls].star;
            if (ls + 2 == n) { // exactly one token after the star
                if (buf[ls + 1] == .run and buf[ls + 1].run.start == ps + 1) {
                    const m = buf[ls + 1].run.len;
                    if (m > 0) {
                        if (str.len < m) return false;
                        if (!runEq(pat[ps + 1 ..], str[str.len - m ..], folding))
                            return false;
                        // Reuse buf: this frame never touches it again (the
                        // result returns directly), and the recursion's own
                        // anchor is skipped (prefix ends in '*', star_final),
                        // so no live data is clobbered. Kills the second
                        // ~3 KiB frame and the recompile writes into it.
                        return go(pat[0 .. ps + 1], str[0 .. str.len - m], flags, buf);
                    }
                }
            }
        }
    }

    // --- necessary-condition reject on the string's final byte -------------
    // Any full match consumes the LAST token exactly at the string end, so
    // that final byte must be consumable by the last token. This is a pure
    // reject (never strips, never recurses): it gives the failing star-flood
    // families (A/D: string ends 'a', tail needs 'b') their instant NOMATCH
    // back WITHOUT the tail-anchor recursion that made the matching families
    // (B/E) walk the whole string. Matching tails then resolve by walk+skip.
    if (str.len > 0 and n > 0) {
        const last = str[str.len - 1];
        const last_ok = switch (buf[n - 1]) {
            .esc => |e| raw_end_ok or last == e.b or (folding and foldByte(last) == e.b),
            .run => |r| raw_end_ok or blk: {
                const pc = pat[r.start + r.len - 1];
                break :blk last == pc or (folding and foldByte(last) == pc);
            },
            .cls => |cl| classMember(pat[cl.a..cl.b], last, if (folding) foldByte(last) else last),
            else => true, // .q / .star consume any byte (or nothing)
        };
        if (!last_ok) return false;
    }

    // --- main token loop ---------------------------------------------------
    var t: usize = 0; // token cursor
    var s: usize = 0; // string cursor
    var star_tok: ?usize = null;
    var rewind: usize = 0;

    while (s < str.len) {
        const ch = str[s];

        // FNM_PERIOD leading-dot gate (musl): a segment-leading '.' in the
        // string must be met by a RAW unescaped '.' as the current token
        // (guardrails 1-3). Leading = s==0, or after '/' with PATHNAME.
        // .esc carries its pattern origin in .i: a raw '.' has pat[i]=='.',
        // an escaped '\.' has pat[i]=='\\' (D005), a class [.] has
        // pat[i]=='[': all three land on their musl side of the gate.
        if (period and ch == '.' and (s == 0 or (pathname and str[s - 1] == '/'))) {
            const dot_ok = blk: {
                if (t >= n) break :blk false;
                switch (buf[t]) {
                    .esc => |e| break :blk e.b == '.' and pat[e.i] == '.',
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
                    if (ch == e.b or (folding and foldByte(ch) == e.b)) {
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

        // Failure: give the last '*' more cover (greedy rewind, accelerated).
        if (star_tok) |st| {
            const after = st + 1;

            if (after >= n) {
                // Final star absorbs the rest of the current segment. Under
                // FNM_PATHNAME it cannot absorb '/' at all: if a '/' remains
                // ahead, no continuation exists -> no match.
                if (pathname) {
                    if (rewind < str.len and
                        std.mem.indexOfScalar(u8, str[rewind..], '/') != null)
                        return false;
                }
                s = str.len;
                continue;
            }

            // Build the necessary first-byte candidate set for buf[after]
            // (what the continuation token must see at its start).
            var cand: [16]u8 = undefined;
            var nc: usize = 0;
            var skippable = false;
            switch (buf[after]) {
                .esc => |e| {
                    addCand(&cand, &nc, e.b);
                    if (folding) addCand(&cand, &nc, foldByte(e.b));
                    skippable = true;
                },
                .run => |r| {
                    const c0 = pat[r.start];
                    addCand(&cand, &nc, c0);
                    if (folding) addCand(&cand, &nc, foldByte(c0));
                    skippable = true;
                },
                .cls => |cl| {
                    var members: [8]u8 = undefined;
                    if (classMembers(pat[cl.a..cl.b], &members)) |cm| {
                        var mi: usize = 0;
                        while (mi < cm) : (mi += 1) {
                            addCand(&cand, &nc, members[mi]);
                            if (folding) addCand(&cand, &nc, foldByte(members[mi]));
                        }
                        skippable = true;
                    } // else: too complex / negated -> byte-step
                },
                else => {}, // .q matches any byte: no skip
            }

            if (skippable and nc > 0) {
                if (rewind + 1 > str.len) return false;
                // Under PATHNAME the star cover may not absorb '/': the byte
                // at str[rewind] (the first to be absorbed) must not be '/',
                // and the search must stop at (and include) the next '/' so
                // nothing is skipped across a separator (D006 stays intact;
                // landing ON the '/' is legal: a literal continuation may
                // consume it).
                var hay_end = str.len;
                if (pathname) {
                    if (str[rewind] == '/') return false; // D006 cover guard
                    if (std.mem.indexOfScalar(u8, str[rewind..], '/')) |f| {
                        hay_end = rewind + f + 1;
                    }
                }
                const hay = str[rewind + 1 .. hay_end];
                if (hay.len > 0) {
                    // memchr-style skip: a 1-2 byte needle uses two
                    // indexOfScalar calls (vectorized in the std); larger
                    // candidate sets fall back to indexOfAny (a scalar loop
                    // in Zig 0.14, ~1 ns/byte).
                    const off: ?usize = if (nc == 1)
                        std.mem.indexOfScalar(u8, hay, cand[0])
                    else if (nc == 2) blk: {
                        // Search cand[0] first; if found at i1, cand[1] can
                        // only win inside hay[0..i1]. Same minimum, half the
                        // scan on early first-byte hits.
                        const o1 = std.mem.indexOfScalar(u8, hay, cand[0]);
                        if (o1) |idx1| {
                            const o2 = std.mem.indexOfScalar(u8, hay[0..idx1], cand[1]);
                            break :blk o2 orelse o1;
                        }
                        break :blk std.mem.indexOfScalar(u8, hay, cand[1]);
                    } else std.mem.indexOfAny(u8, hay, cand[0..nc]);
                    if (off) |j| {
                        rewind = rewind + 1 + j;
                        s = rewind;
                        t = after;
                        continue; // loop top re-checks the PERIOD gate
                    }
                }
                return false; // no candidate before the segment end == no match
            }

            // byte-step fallback (identical to the classic greedy rewind,
            // incl. the D006 cover guard).
            if (pathname and rewind < str.len and str[rewind] == '/') return false;
            rewind += 1;
            s = rewind;
            t = after;
        } else return false;
    }

    // Only unescaped trailing '*' tokens may match empty (guardrail 13); an
    // escaped '\*' (parsed .esc) correctly stays unmatched.
    while (t < n and buf[t] == .star) t += 1;
    return t == n;
}

/// Bytewise fallback used when a pattern compiles to more than MAXT tokens.
/// Same semantics as go() (including the D006 cover guard), without
/// compilation: a plain two-pointer star-rewind machine.
fn matchBytewise(pattern: []const u8, string: []const u8, flags: c_int) bool {
    const pathname = (flags & FNM_PATHNAME) != 0;
    const period = (flags & FNM_PERIOD) != 0;
    const folding = (flags & FNM_CASEFOLD) != 0;
    var p: usize = 0; // cursor into pattern
    var s: usize = 0; // cursor into string
    var star: ?usize = null; // pattern index of last '*' seen
    var rewind: usize = 0; // string index to retry after that '*'

    while (s < string.len) {
        if (period and string[s] == '.' and (s == 0 or (pathname and string[s - 1] == '/'))) {
            const lead = tokenAt(pattern, p, flags);
            if (!(lead.kind == .lit and lead.ch == '.' and lead.step == 1)) return false;
        }
        var consumed = false;
        if (p < pattern.len) {
            const tok = tokenAt(pattern, p, flags);
            switch (tok.kind) {
                .star => {
                    star = p;
                    p += tok.step;
                    rewind = s;
                    consumed = true;
                },
                .question => {
                    if (!(pathname and string[s] == '/')) {
                        p += tok.step;
                        s += 1;
                        consumed = true;
                    }
                },
                .cls => {
                    const c = string[s];
                    if (!(pathname and c == '/') and
                        classMember(pattern[tok.a..tok.b], c, if (folding) foldByte(c) else c))
                    {
                        p += tok.step;
                        s += 1;
                        consumed = true;
                    }
                },
                .lit => {
                    const k = string[s];
                    if (k == tok.ch or (folding and foldByte(k) == tok.ch)) {
                        p += tok.step;
                        s += 1;
                        consumed = true;
                    }
                },
                .end => {},
            }
        }
        if (consumed) continue;
        if (star) |st| {
            // D006 cover guard (see go()): reject when the byte about to be
            // added to the star cover is '/'.
            if (pathname and rewind < string.len and string[rewind] == '/') return false;
            p = st + 1;
            rewind += 1;
            s = rewind;
        } else return false;
    }
    while (p < pattern.len and tokenAt(pattern, p, flags).kind == .star) p += 1;
    return p == pattern.len;
}

/// matches() + POSIX fnmatch(3) flag bits (FNM_PATHNAME, FNM_NOESCAPE,
/// FNM_PERIOD, FNM_CASEFOLD).
pub fn matchesFlags(pattern: []const u8, string: []const u8, flags: c_int) bool {
    var buf: [MAXT]CToken = undefined;
    return go(pattern, string, flags, buf[0..]);
}

/// POSIX fnmatch(3) convention: 0 == match, FNM_NOMATCH (1) == no match.
pub const FNM_NOMATCH: c_int = 1;

/// C ABI entry point. Both pointers must be NUL-terminated; NULL on either
/// side returns FNM_NOMATCH instead of faulting (libc convention ignores
/// NULL, we fail closed).
/// M1-compatible 2-arg form: plain wildcards, no flags.
export fn fnmatch_ng(pattern: ?[*:0]const u8, string: ?[*:0]const u8) c_int {
    const p = pattern orelse return FNM_NOMATCH;
    const s = string orelse return FNM_NOMATCH;
    return if (matches(std.mem.span(p), std.mem.span(s))) 0 else FNM_NOMATCH;
}

/// C ABI entry point with POSIX fnmatch(3) flag bits (FNM_PATHNAME,
/// FNM_NOESCAPE, FNM_PERIOD, FNM_CASEFOLD). NULL contract as above.
export fn fnmatch_ng_flags(pattern: ?[*:0]const u8, string: ?[*:0]const u8, flags: c_int) c_int {
    const p = pattern orelse return FNM_NOMATCH;
    const s = string orelse return FNM_NOMATCH;
    return if (matchesFlags(std.mem.span(p), std.mem.span(s), flags)) 0 else FNM_NOMATCH;
}

const expect = std.testing.expect;

test "M1 plan section 10 table" {
    const cases = [_]struct { pat: []const u8, str: []const u8, want: bool }{
        .{ .pat = "abc", .str = "abc", .want = true },
        .{ .pat = "abc", .str = "abd", .want = false },
        .{ .pat = "?", .str = "a", .want = true },
        .{ .pat = "?", .str = "", .want = false },
        .{ .pat = "*", .str = "", .want = true },
        .{ .pat = "*", .str = "abc", .want = true },
        .{ .pat = "a*c", .str = "abc", .want = true },
        .{ .pat = "a*c", .str = "axyzc", .want = true },
        .{ .pat = "*a", .str = "aaaa", .want = true },
        .{ .pat = "a*", .str = "a", .want = true },
        .{ .pat = "ab", .str = "abc", .want = false },
        .{ .pat = "abc", .str = "ab", .want = false },
    };
    for (cases) |c| {
        const got = matches(c.pat, c.str);
        try expect(got == c.want);
    }
}

test "M1 greedy star rewind" {
    try expect(matches("a*b", "aXb"));
    try expect(!matches("a*b", "abX"));
    try expect(matches("a**b", "aXXb"));
    try expect(!matches("a*b*c", "aXbY"));
    try expect(matches("a*b*c", "aXbYc"));
    try expect(!matches("x*", ""));
    try expect(matches("", ""));
    try expect(!matches("", "a"));
    try expect(matches("?", "Z"));
    try expect(matches("**", ""));
}

test "M1 backslash is an ordinary literal byte in this phase" {
    // M3 supersedes this phase: '\\' now escapes. These lines document the
    // M1->M3 behavior flip (escaped '*' matches the literal '*').
    try expect(matches("\\*", "\\*") == false);
    try expect(matches("\\*", "*"));
    try expect(matches("\\*", "XYZ") == false);
}

test "M1 export fnmatch_ng C ABI returns 0/1" {
    try expect(fnmatch_ng("a*c", "abc") == 0);
    try expect(fnmatch_ng("a*c", "abd") == FNM_NOMATCH);
}

test "M2 FNM_PATHNAME plan section 11 quartet" {
    const P = FNM_PATHNAME;
    // The four canonical plan cases.
    try expect(!matchesFlags("*.c", "src/a.c", P));
    try expect(matchesFlags("*/*.c", "src/a.c", P));
    try expect(!matchesFlags("src/*", "src/a/b", P));
    try expect(matchesFlags("src/*", "src/a", P));
    // Plain mode must still treat '/' like any byte.
    try expect(matches("*.c", "src/a.c"));
    try expect(matches("src/*", "src/a/b"));
}

test "M2 FNM_PATHNAME '*' and '?' never match '/'" {
    const P = FNM_PATHNAME;
    try expect(!matchesFlags("*", "a/b", P));
    try expect(matchesFlags("*", "abc", P));
    try expect(matchesFlags("*", "", P));
    try expect(matchesFlags("*/*", "a/b", P));
    try expect(!matchesFlags("*/*", "a/b/c", P));
    try expect(matchesFlags("*/*", "a/", P));
    try expect(matchesFlags("?", "a", P));
    try expect(!matchesFlags("?", "/", P));
    try expect(!matchesFlags("a?b", "a/b", P));
    try expect(matchesFlags("a?b", "axb", P));
    try expect(!matchesFlags("a*b", "a/b", P));
    try expect(matchesFlags("a*b", "aXb", P));
    try expect(!matchesFlags("*b", "a/b", P));
    try expect(matchesFlags("a*/b", "a/b", P));
    try expect(!matchesFlags("a*/b", "aXb", P));
    try expect(!matchesFlags("*x", "/x", P));
    // flags==0 is exactly matches(): '/' is a plain byte for '*'
    try expect(matchesFlags("*", "a/b", 0));
    try expect(matchesFlags("?", "/", 0));
    // unknown flag bits are ignored, matching libc convention
    try expect(matchesFlags("a?b", "axb", 0x40));
    try expect(matchesFlags("a?b", "a/b", 0x40));
}

test "M2 fnmatch_ng_flags C ABI returns 0/1" {
    const P = FNM_PATHNAME;
    try expect(fnmatch_ng_flags("*/*.c", "src/a.c", P) == 0);
    try expect(fnmatch_ng_flags("*.c", "src/a.c", P) == FNM_NOMATCH);
    try expect(fnmatch_ng_flags("*.c", "src/a.c", 0) == 0);
}

// M3 escape expectations below are musl-verified: every (want) in these
// tests was probed against compat/musl_fnmatch.c via scripts/ref_harness.

test "M3 escaped wildcards are literals" {
    // '\*' matches literal '*', never acts as a wildcard.
    try expect(matches("\\*", "*"));
    try expect(!matches("\\*", "xyz"));
    try expect(!matches("\\*", "\\*"));
    // '\?' matches literal '?'.
    try expect(matches("\\?", "?"));
    try expect(!matches("\\?", "a"));
    // '\\' matches one literal backslash.
    try expect(matches("\\\\", "\\"));
    // '\[' is a literal '[' (brackets arrive in M4; escaping is already literal).
    try expect(matches("\\[", "["));
    try expect(!matches("\\[", "a"));
}

test "M3 trailing lone backslash is a literal backslash (musl D002/D003)" {
    try expect(matches("\\", "\\"));
    try expect(!matches("\\", ""));
    try expect(matches("a\\", "a\\"));
    try expect(!matches("a\\", "a"));
}

test "M3 escapes inside a star match" {
    try expect(matches("a\\*b", "a*b"));
    try expect(!matches("a\\*b", "axb"));
    try expect(matches("\\a\\*b", "a*b"));
    try expect(!matches("\\a\\*b", "x*b"));
    // star rewind retries the escaped token, not the '\' byte alone
    try expect(matches("*\\x", "abx"));
    try expect(!matches("*\\x", "aby"));
}

test "M3 FNM_NOESCAPE makes backslash an ordinary byte" {
    const NE = FNM_NOESCAPE;
    try expect(matchesFlags("\\*", "\\*", NE));
    try expect(!matchesFlags("\\*", "*", NE));
    try expect(!matchesFlags("\\*", "x", NE));
}

test "M3 escaped wildcards under FNM_PATHNAME stay literals" {
    const P = FNM_PATHNAME;
    try expect(matchesFlags("\\*", "*", P));
    try expect(!matchesFlags("\\*", "/", P));
    try expect(!matchesFlags("\\*", "a/b", P));
    // '\/' is a literal '/' and does match: no wildcard powers, no crossing.
    try expect(matchesFlags("\\/", "/", P));
    try expect(matchesFlags("\\/", "/", 0));
    try expect(matchesFlags("a\\/b", "a/b", P));
}

test "M3 fnmatch_ng_flags escape C ABI" {
    const P = FNM_PATHNAME;
    try expect(fnmatch_ng_flags("\\*", "*", 0) == 0);
    try expect(fnmatch_ng_flags("\\*", "xyz", 0) == FNM_NOMATCH);
    try expect(fnmatch_ng_flags("a\\*b", "axb", P) == FNM_NOMATCH);
}

// M4 bracket expectations below are musl-verified: every (want) was probed
// against compat/musl_fnmatch.c via scripts/ref_harness.exe (see probe
// corpora in the M4 gate run).

test "M4 bracket basics match exactly one byte" {
    try expect(matches("[abc]", "b"));
    try expect(!matches("[abc]", "d"));
    try expect(matches("[a-c]", "b"));
    try expect(!matches("[a-c]", "d"));
    try expect(matches("x[abc]y", "xby"));
    try expect(!matches("[abc]", "ab"));
    try expect(!matches("[abc]", ""));
    try expect(matches("a[b]c", "abc"));
    try expect(!matches("a[b]c", "axc"));
}

test "M4 negation with ! and ^" {
    try expect(matches("[!a]", "b"));
    try expect(!matches("[!a]", "a"));
    try expect(matches("[^a]", "b"));
    try expect(!matches("[^a]", "a"));
    // [!]] = any byte except ']' (leading ']' consumed as the negated member)
    try expect(matches("[!]]", "a"));
    try expect(!matches("[!]]", "]"));
    try expect(matches("x[!]]", "xa"));
}

test "M4 reversed range [z-a]: only its members are literals (D001, musl)" {
    try expect(matches("[z-a]", "z")); // leading literal member
    try expect(matches("[z-a]", "a")); // endpoint still checked as literal
    try expect(!matches("[z-a]", "y"));
    try expect(!matches("[z-a]", "b"));
    try expect(!matches("[z-a]", "["));
}

test "M4 empty [] and unterminated [ degrade to literal bytes (musl)" {
    // [] is not a class: literal '[' followed by literal ']' (matches only "[]")
    try expect(matches("[]", "[]"));
    try expect(!matches("[]", "["));
    try expect(!matches("[]", "x"));
    // unterminated '[' is a literal '['; the rest of the pattern continues literally
    try expect(matches("[", "["));
    try expect(!matches("[", "a"));
    try expect(matches("[a", "[a"));
    try expect(!matches("[a", "a"));
    try expect(!matches("[!", "b"));
    try expect(!matches("[!]", "[")); // literal '[' + '!' + ']'
    try expect(matches("[!]", "[!]"));
    try expect(matches("a[bc", "a[bc"));
    // a class inside a star run can still fail to an unterminated sibling
    try expect(matches("*[", "x["));
}

test "M4 literal ] and - in first/last positions" {
    try expect(matches("[]]", "]")); // leading ']' is a literal member
    try expect(!matches("[]]", "["));
    try expect(!matches("[]]", "a"));
    try expect(matches("[a-]", "-")); // trailing '-' is a literal member
    try expect(matches("[a-]", "a"));
    try expect(matches("[-a]", "-")); // leading '-' is a literal member
    try expect(matches("[-a]", "a"));
    try expect(matches("[-]", "-"));
    try expect(!matches("[-]", "x"));
    try expect(matches("[a-b-c]", "c")); // chained ranges
    try expect(!matches("[a-b-c]", "d"));
}

test "M4 backslash inside a class is an ordinary member byte (musl/POSIX)" {
    // [\] is a class containing one backslash: no escape semantics
    try expect(matches("[\\]", "\\"));
    try expect(!matches("[\\]", "a"));
    // [a\c] = {a, \, c}: '\' does not escape 'c'
    try expect(matches("[a\\c]", "a"));
    try expect(matches("[a\\c]", "\\"));
    try expect(matches("[a\\c]", "c"));
    try expect(!matches("[a\\c]", "b"));
    // [ab\] has a literal trailing backslash member before the closer
    try expect(matches("[ab\\]", "\\"));
    try expect(matches("[ab\\]", "b"));
    try expect(!matches("[ab\\]", "x"));
    // [\\a-c] = {'\\'} ∪ [a-c]
    try expect(matches("[\\a-c]", "\\"));
    try expect(matches("[\\a-c]", "b"));
    // [\\]] = class {'\\'} followed by a literal ']' (closer is the first ']')
    try expect(matches("[\\]]", "\\]"));
    try expect(!matches("[\\]]", "\\"));
    try expect(!matches("[\\]]", "]"));
}

test "M4 FNM_NOESCAPE never affects backslash inside a class" {
    const NE = FNM_NOESCAPE;
    try expect(matchesFlags("[a\\c]", "\\", NE));
    try expect(matchesFlags("[a\\c]", "a", NE));
    try expect(matchesFlags("[\\]", "\\", NE));
    // but NOESCAPE still governs backslash OUTSIDE the class
    try expect(matchesFlags("\\[", "\\[", NE));
    try expect(!matchesFlags("\\[", "[", NE));
}

test "M4 a class never matches '/' under FNM_PATHNAME" {
    const P = FNM_PATHNAME;
    try expect(!matchesFlags("[/]", "/", P));
    try expect(matchesFlags("[/]", "/", 0));
    try expect(!matchesFlags("a[/]b", "a/b", P));
    try expect(matchesFlags("a[/]b", "a/b", 0));
    try expect(!matchesFlags("[a/]", "/", P)); // member '/' present but excluded
    try expect(matchesFlags("[a/]", "/", 0));
    try expect(!matchesFlags("*[/]*", "a/b", P));
    try expect(matchesFlags("*[/]*", "a/b", 0));
    try expect(matchesFlags("*[a]*", "xay", P));
    try expect(matchesFlags("[abc]*", "ab", P));
    try expect(!matchesFlags("[abc]*", "ab/c", P));
}

test "M4 classes in star-rewind runs" {
    // musl-verified: class + trailing content must align to the string end
    try expect(matches("*[a]", "xa"));
    try expect(matches("*[a]", "a"));
    try expect(!matches("*[a]", "x"));
    try expect(!matches("*[a]", "xay"));
    try expect(matches("a*[b]c", "aXXbc"));
    try expect(!matches("a*[b]c", "aXXbYc"));
    try expect(matches("*[0-9]*", "file42.log"));
    try expect(!matches("*[0-9]*", "file.log"));
    try expect(matches("*[!0-9]", "abc"));
    try expect(matches("*[!0-9]", "a"));
    try expect(!matches("*[!0-9]", "a1"));
    try expect(matches("[0-9]*", "42abc"));
    try expect(!matches("[0-9]*", "abc42"));
}

test "M4 fnmatch_ng_flags bracket C ABI" {
    try expect(fnmatch_ng_flags("[a-c]", "b", 0) == 0);
    try expect(fnmatch_ng_flags("[a-c]", "d", 0) == FNM_NOMATCH);
    try expect(fnmatch_ng_flags("[/]", "/", 0) == 0);
    try expect(fnmatch_ng_flags("[/]", "/", FNM_PATHNAME) == FNM_NOMATCH);
}

// M5 FNM_PERIOD expectations below are musl-verified: every (want) was
// probed against compat/musl_fnmatch.c via scripts/ref_harness.exe (see the
// M5 probe battery in the phase gate).

test "M5 FNM_PERIOD plan section 14 cases" {
    const PD = FNM_PERIOD;
    // leading dot: wildcards never match it
    try expect(!matchesFlags("*", ".hidden", PD));
    try expect(!matchesFlags("?", ".", PD));
    try expect(!matchesFlags("[.]", ".", PD));
    // a literal dot does
    try expect(matchesFlags(".*", ".hidden", PD));
    try expect(matchesFlags(".", ".", PD));
    try expect(matchesFlags("..", "..", PD));
    try expect(matchesFlags(".a", ".a", PD));
    // leading dot vs literal prefix mismatch stays a mismatch
    try expect(!matchesFlags("a", ".a", PD));
    // no leading dot: unaffected
    try expect(matchesFlags("*", "normal", PD));
    try expect(matchesFlags("*", "a.b", PD));
    try expect(matchesFlags("a*", "a.b", PD));
}

test "M5 FNM_PERIOD only position 0 counts without FNM_PATHNAME" {
    const PD = FNM_PERIOD;
    // mid-string dot (even right after '/') is not leading without PATHNAME
    try expect(matchesFlags("a/*", "a/.b", PD));
    try expect(matchesFlags("*/*", "a/.b", PD));
    try expect(matchesFlags("*", "/.x", PD));
    try expect(matchesFlags("*", "x/.y", PD));
}

test "M5 escaped dot at a leading position is NOMATCH (musl pin)" {
    const PD = FNM_PERIOD;
    // musl's check compares the pattern's first BYTE: '\' != '.' -> reject
    try expect(!matchesFlags("\\.", ".", PD));
    try expect(!matchesFlags("\\.x", ".x", PD));
    try expect(!matchesFlags("\\.\\x", ".x", PD));
    try expect(!matchesFlags("\\*", ".x", PD)); // corpus m0_baseline #95
    try expect(!matchesFlags("\\*x", ".x", PD));
    // escaped dot is a plain literal dot when no leading dot is involved
    try expect(matchesFlags("\\*", "*", PD));
    try expect(matchesFlags("\\*x", "*x", PD));
    try expect(matchesFlags("a\\.b", "a.b", PD));
    try expect(matchesFlags("\\*", "*", 0)); // escape works without PERIOD
}

test "M5 FNM_PERIOD with FNM_PATHNAME checks each segment" {
    const PP = FNM_PERIOD | FNM_PATHNAME;
    // a segment starting with '.' needs a raw '.' at that segment's pattern start
    try expect(!matchesFlags("*", "a/.b", PP));
    try expect(!matchesFlags("*", ".a/b", PP));
    try expect(!matchesFlags("*/*", "a/.b", PP));
    try expect(matchesFlags("*/.*", "a/.b", PP));
    try expect(!matchesFlags("a/*", "a/.b", PP));
    try expect(matchesFlags("a/*", "a/b", PP));
    try expect(matchesFlags(".*", ".a", PP));
    try expect(matchesFlags("src/.*", "src/.config", PP));
    try expect(!matchesFlags("a/*/c", "a/.b/c", PP));
    try expect(matchesFlags("a/.*/c", "a/.b/c", PP));
    try expect(!matchesFlags("*", ".x/.y", PP));
    try expect(!matchesFlags("x*", "x/.y", PP));
    // PATHNAME alone still lets wildcards eat a leading dot
    try expect(matchesFlags("*", ".x", FNM_PATHNAME));
    try expect(matchesFlags("a/*", "a/.b", FNM_PATHNAME));
}

test "M5 leading dot reject does not star-rewind past the dot" {
    const PD = FNM_PERIOD;
    // musl rejects at segment entry: the star must not absorb the dot and
    // then let 'a' match "xa"
    try expect(!matchesFlags("*a", ".xa", PD));
    try expect(matchesFlags("*a", "xaa", PD));
    try expect(matchesFlags("*a", "a", PD));
    const PP = FNM_PERIOD | FNM_PATHNAME;
    // same inside a later segment
    try expect(!matchesFlags("x/*a", "x/.xa", PP));
    try expect(matchesFlags("x/*a", "x/xaa", PP));
}

test "M5 fnmatch_ng_flags period C ABI" {
    const PD = FNM_PERIOD;
    try expect(fnmatch_ng_flags("*", ".x", PD) == FNM_NOMATCH);
    try expect(fnmatch_ng_flags(".*", ".x", PD) == 0);
    try expect(fnmatch_ng_flags("*", ".x", FNM_PATHNAME) == 0);
}

// M6 FNM_CASEFOLD expectations below are musl-verified: every (want) was
// probed against compat/musl_fnmatch.c via scripts/ref_harness.exe --json
// in the M6 probe battery (single-byte mode, ASCII-only folding, C locale).

const CF = FNM_CASEFOLD;

test "M6 CASEFOLD folds literal bytes both directions" {
    try expect(matchesFlags("abc", "ABC", CF));
    try expect(matchesFlags("ABC", "abc", CF));
    try expect(matchesFlags("AbC", "aBc", CF));
    try expect(!matchesFlags("abc", "abd", CF));
    try expect(!matchesFlags("abc", "ABC", 0)); // control: no fold without the flag
    try expect(matchesFlags("a", "A", CF));
    try expect(matchesFlags("a*b", "AXB", CF));
    try expect(matchesFlags("A?B", "aXb", CF));
    try expect(matchesFlags("*a", "xA", CF));
    // escaped literals fold too (musl folds k regardless of token origin)
    try expect(matchesFlags("\\A", "a", CF));
}

test "M6 CASEFOLD does not make wildcards or '?' match anything new" {
    try expect(!matchesFlags("?", "", CF));
    try expect(matchesFlags("*", "", CF));
    // '?' still matches exactly one byte; a two-byte UTF-8 char needs two
    try expect(!matchesFlags("?", "\u{00E9}", CF));
}

test "M6 CASEFOLD folds inside bracket classes (probe-verified)" {
    // single members fold
    try expect(matchesFlags("[A]", "a", CF));
    try expect(matchesFlags("[a]", "A", CF));
    try expect(!matchesFlags("[A]", "b", CF));
    // ranges accept the folded string byte (kfold enters the range)
    try expect(matchesFlags("[A-Z]", "q", CF));
    try expect(matchesFlags("[A-Z]", "Q", CF));
    try expect(matchesFlags("[A-Z]", "a", CF));
    try expect(matchesFlags("[A-Z]", "z", CF));
    try expect(matchesFlags("[a-z]", "Q", CF));
    try expect(matchesFlags("[a-z]", "A", CF));
    try expect(matchesFlags("[A-C]", "b", CF));
    try expect(matchesFlags("[a-c]", "B", CF));
    // case-free ranges still behave
    try expect(matchesFlags("[0-9]", "5", CF));
    // negation folds too: the excluded set is case-insensitive
    try expect(!matchesFlags("[!a]", "A", CF));
    try expect(matchesFlags("[!a]", "b", CF));
    try expect(!matchesFlags("[!A-Z]", "q", CF));
    try expect(matchesFlags("[!A-Z]", "1", CF));
    // reversed ranges: only endpoint literals, now foldable (D001 + M6);
    // without CASEFOLD the raw endpoint is case-sensitive (M4 semantics)
    try expect(matchesFlags("[Z-A]", "z", CF));
    try expect(matchesFlags("[z-a]", "Z", CF));
    try expect(matchesFlags("[z-a]", "z", CF));
    try expect(!matchesFlags("[Z-A]", "z", 0)); // raw 'Z' member, no fold
    try expect(!matchesFlags("[z-a]", "y", CF));
    // class inside a star-rewind run folds per retry
    try expect(matchesFlags("*[A]", "xa", CF));
    try expect(!matchesFlags("*[a]", "xY", CF));
}

test "M6 ASCII-only fold: high bytes and multibyte do not fold (C locale)" {
    // single high bytes pass through byte-wise, never folding (probe: 0xC9
    // vs 0xE9 under CASEFOLD = NOMATCH) and never unmatching identity
    try expect(!matchesFlags("\xC9", "\xE9", CF));
    try expect(!matchesFlags("\xE9", "\xC9", CF));
    try expect(!matchesFlags("\xC0", "\xE0", CF));
    try expect(matchesFlags("\xE9", "\xE9", CF));
    try expect(matchesFlags("\xE9", "\xE9", 0));
    // ASCII fold still applies next to high bytes
    try expect(matchesFlags("a\xE9", "A\xE9", CF));
    // UTF-8 two-byte sequences are two single-byte chars here: '\xC3' then
    // 0x89/0xA9: the fold never joins them, so U+00C9 vs U+00E9 is NOMATCH
    try expect(!matchesFlags("\u{00C9}", "\u{00E9}", CF));
    try expect(!matchesFlags("\u{00E9}", "\u{00C9}", CF));
    try expect(matchesFlags("\u{00E9}", "\u{00E9}", 0)); // byte-identical
    // high-byte classes/ranges work byte-wise and fold nothing
    try expect(matchesFlags("[\xE9]", "\xE9", CF));
    try expect(matchesFlags("[\xC0-\xFF]", "\xD0", 0));
    try expect(matchesFlags("[\xC0-\xFF]", "\xD0", CF));
    try expect(!matchesFlags("[\xE9]", "\xC9", CF));
    // '?' matches a high byte in single-byte mode
    try expect(matchesFlags("?", "\xE9", 0));
}

test "M6 CASEFOLD combined with other flags" {
    const CP = CF | FNM_PATHNAME;
    try expect(matchesFlags("src/*.C", "src/a.c", CP));
    try expect(matchesFlags("*.C", "file.c", CF));
    try expect(!matchesFlags("src/*.C", "src/a/b.c", CP));
    // FNM_PERIOD is a raw-byte rule; folding never lets a wildcard in
    try expect(!matchesFlags("*", ".x", CF | FNM_PERIOD));
    try expect(matchesFlags(".*", ".X", CF | FNM_PERIOD));
    try expect(!matchesFlags("[.]", ".", CF | FNM_PERIOD));
    // NOESCAPE + CASEFOLD: backslash stays literal, fold still applies
    try expect(matchesFlags("\\a", "\\A", CF | FNM_NOESCAPE));
}

test "M6 fnmatch_ng_flags casefold C ABI" {
    try expect(fnmatch_ng_flags("abc", "ABC", CF) == 0);
    try expect(fnmatch_ng_flags("abc", "abd", CF) == FNM_NOMATCH);
    try expect(fnmatch_ng_flags("[A-Z]", "q", CF) == 0);
    try expect(fnmatch_ng_flags("a?b", "AXB", CF) == 0);
}

// ---------------------------------------------------------------------------
// M9: post-audit tests. Star-cover guard regression (D006), tail-anchor and
// pure-literal behavior (compiled core), and the bytewise-overflow fallback.
// ---------------------------------------------------------------------------

test "M9 FNM_PATHNAME star-cover guard (D006 regression)" {
    const P = FNM_PATHNAME;
    // The four audit repros: musl = NOMATCH (all probed via ref_harness).
    try expect(!matchesFlags("a*/b", "a/x/b", P));
    try expect(!matchesFlags("a*/c", "a/b/c", P));
    try expect(!matchesFlags("*/x.c", "a/b/x.c", P));
    try expect(!matchesFlags("x/*/a", "x/y/z/a", P));
    // Related loose-star shapes from the audit's musl pins.
    try expect(!matchesFlags("*b", "a/xb", P));
    try expect(!matchesFlags("*a*", "x/a/y", P));
    try expect(!matchesFlags("x*a", "x/y/a", P));
    try expect(!matchesFlags("a*/b", "aX/Yb", P));
    try expect(!matchesFlags("*", "x/b", P));
    try expect(!matchesFlags("a*b", "aX/Yb", P));
    // Accept controls from the same shapes (cover never crosses '/').
    try expect(matchesFlags("a*/b", "a/b", P));
    try expect(matchesFlags("a*/b", "aX/b", P));
    try expect(matchesFlags("*/", "x/", P));
    try expect(matchesFlags("*/*", "x/y", P));
    try expect(matchesFlags("x/*/a", "x/y/a", P));
    try expect(matchesFlags("*b", "xb", P));
    try expect(matchesFlags("*b", "aXb", P));
    try expect(matchesFlags("*a*", "xa", P));
    try expect(!matchesFlags("*a*", "x/a", P));
}

test "M9 tail anchor: star-with-literal-tail patterns" {
    // fail-late shape: string must END in the tail (anchored reject)
    try expect(!matches("*parser.c", "aaaaparser.cx"));
    try expect(matches("*parser.c", "aaaaparser.c"));
    try expect(matches("*parser.c", "parser.c"));
    try expect(!matches("*parser.c", "pa"));
    try expect(!matches("*.c", "aaaa.x"));
    try expect(matches("*.c", "aaaa.c"));
    // PATHNAME: tail anchoring must not resurrect the loose star
    const P = FNM_PATHNAME;
    try expect(!matchesFlags("*.c", "src/a.c", P));
    try expect(matchesFlags("*/*.c", "src/a.c", P));
    try expect(!matchesFlags("*b", "a/xb", P));
    try expect(matchesFlags("*b", "xb", P));
    // CASEFOLD tail compare folds the string byte only
    try expect(matchesFlags("*parser.C", "aaaaparser.c", CF));
    try expect(!matchesFlags("*parser.C", "aaaaparserXc", CF));
    // multi-star prefix still aligns to the anchored tail
    try expect(matches("a*b*c", "aXbYc"));
    try expect(!matches("a*b*c", "aXbYcZ"));
    try expect(matches("src/*/test/*.c", "src/a/b/test/x.c"));
    try expect(!matches("src/*/test/*.c", "src/a/b/test/x.cx"));
    try expect(matches("*a*a*a*b", "aaaab"));
    try expect(!matches("*a*a*a*b", "aaaa"));
}

test "M9 pure-literal and literal-run paths agree with bytewise semantics" {
    try expect(matchesFlags("src/components/parser.c", "src/components/parser.c", 0));
    try expect(!matchesFlags("src/components/parser.c", "src/components/parser.cx", 0));
    // pure-literal equality holds under any flags (no wildcard/leading-dot semantics)
    try expect(matchesFlags("src/components/parser.c", "src/components/parser.c", FNM_PATHNAME | FNM_PERIOD));
    try expect(matchesFlags("ABC", "abc", CF));
    try expect(matchesFlags("a\\*b", "a*b", 0)); // escaped star literal + run
    try expect(!matchesFlags("a\\*b", "aXb", 0));
    try expect(matchesFlags("", "", 0));
    try expect(!matchesFlags("", "x", 0));
    // a run followed by '?' then a run (mixed loop path)
    try expect(matchesFlags("ab?cd", "abXcd", 0));
    try expect(!matchesFlags("ab?cd", "abXcY", 0));
}

test "M9 compile-overflow falls back to the bytewise matcher" {
    // >MAXT tokens forces matchBytewise (the compiled core holds <=128).
    var pbuf: [512]u8 = undefined;
    var pbs = std.io.fixedBufferStream(&pbuf);
    var i: usize = 0;
    while (i < 130) : (i += 1) pbs.writer().writeAll("*a") catch unreachable;
    const pat = pbs.getWritten(); // 260 tokens > 128
    var sbuf: [512]u8 = undefined;
    var sbs = std.io.fixedBufferStream(&sbuf);
    i = 0;
    while (i < 130) : (i += 1) sbs.writer().writeByte('a') catch unreachable;
    const str = sbs.getWritten();
    try expect(matchesFlags(pat, str, 0));
    try expect(!matchesFlags(pat, str[0..129], 0)); // 129 a's < 130 required
    // the fallback honors FNM_PATHNAME: star never covers '/' even there
    const P = FNM_PATHNAME;
    try expect(matchesFlags(pat, str, P));
    try expect(!matchesFlags("*b", "a/xb", P)); // short pattern sanity (go() path)
    // overflow under combined flags: PERIOD|PATHNAME (no dots/slashes: match)
    try expect(matchesFlags(pat, str, P | FNM_PERIOD));
    try expect(!matchesFlags(pat, str[0..129], P | FNM_PERIOD));
    // overflow under CASEFOLD: uppercase string still matches lowercase runs
    var ubuf: [512]u8 = undefined;
    var ubs = std.io.fixedBufferStream(&ubuf);
    i = 0;
    while (i < 130) : (i += 1) ubs.writer().writeByte('A') catch unreachable;
    const ustr = ubs.getWritten();
    try expect(matchesFlags(pat, ustr, FNM_CASEFOLD));
    try expect(!matchesFlags(pat, ustr[0..129], FNM_CASEFOLD));
    // overflow NOMATCH: wrong tail byte fails in the fallback too
    ubuf[129] = 'B';
    try expect(!matchesFlags(pat, ustr, FNM_CASEFOLD));
}
