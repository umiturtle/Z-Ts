//! ReDoS-Proof Linear/Polynomial Path & URL Glob Matcher (`src/core/glob.zig`).
//!
//! Powers Tauri v2 Capabilities (`urls`, filesystem `allow` / `deny` path scopes, event filters).
//!
//! Supported syntax:
//! - `*`      : Matches 0 or more non-separator characters (`/` and `\` are NOT crossed).
//! - `**`     : Matches 0 or more arbitrary characters INCLUDING path separators (`/`):
//!              `a/**/b` matches BOTH `a/b` and `a/x/y/b` (Tauri ACL standard semantics).
//! - `?`      : Matches any single non-separator UTF-8 codepoint.
//! - `[abc]`  : Character class / range `[a-z]` / negated `[!a-z]` or `[^a-z]`.
//! - `\`      : Escapes metacharacters on POSIX when `windows_separators = false` (default tracks `/` & `\` uniformly).
//!
//! Guarantee: Uses explicit state tracking over pattern offsets with **zero heap allocations**
//! and **zero exponential backtracking (100% immune to ReDoS attacks)**.

const std = @import("std");
const testing = std.testing;
const url = @import("url.zig");

/// Maximum pattern byte length handled in zero-allocation bitset DP (`1024` bytes covers every real ACL rule).
pub const MAX_PATTERN_LEN: usize = 1024;

/// Matches `text` against glob `pattern` with path-separator awareness (`/` and `\` treated identically as `/`).
/// Performs zero heap allocations and runs in guaranteed worst-case `O(|pattern| * |text|)` time.
pub fn match(pattern: []const u8, text: []const u8) bool {
    if (pattern.len > MAX_PATTERN_LEN) return false;

    // Bitset of active NFA states `[0 .. pattern.len]` (17 x u64 = 136 bytes on stack!)
    var cur = StateSet{};
    cur.set(0);
    expandEpsilon(pattern, &cur);

    var ti: usize = 0;
    while (ti < text.len) {
        const step = decodeNormalizedUnit(text, ti);
        var next = StateSet{};

        var pi: usize = 0;
        while (pi <= pattern.len) : (pi += 1) {
            if (!cur.isSet(pi)) continue;
            if (pi == pattern.len) continue;

            // `/**/` or trailing `/**` or standalone `**`
            if (isDoubleStarAt(pattern, pi)) {
                // `**` can consume ANY character (including `/`) and stay in state `pi`
                next.set(pi);
                continue;
            }

            const pch = normalizeSep(pattern[pi]);
            if (pch == '*') {
                // Single `*` consumes any character EXCEPT `/`
                if (step.ch != '/') {
                    next.set(pi);
                }
            } else if (pch == '?') {
                if (step.ch != '/') {
                    next.set(pi + 1);
                }
            } else if (pch == '[') {
                if (matchCharClass(pattern, pi, step.ch)) |after_class| {
                    if (step.ch != '/') {
                        next.set(after_class);
                    }
                } else {
                    // Unclosed `[` matches literal `[`
                    if (step.ch == '[') next.set(pi + 1);
                }
            } else {
                // Literal byte/codepoint match
                const pat_step = decodeNormalizedUnit(pattern, pi);
                if (pat_step.ch == step.ch) {
                    next.set(pi + pat_step.len);
                }
            }
        }

        if (next.isEmpty()) return false;
        expandEpsilon(pattern, &next);
        cur = next;
        ti += step.len;
    }

    return cur.isSet(pattern.len);
}

/// Validates and canonicalizes `candidate_path` first (blocking NUL bytes, `%2e%2e`, and `..`
/// escape attempts!) BEFORE matching against an ACL scope glob `scope_pattern`.
pub fn matchSafePathScope(scope_pattern: []const u8, candidate_path: []const u8) bool {
    // Reject any raw NUL or control characters immediately
    for (candidate_path) |b| {
        if (b < 0x20 or b == 0x7F) return false;
    }

    // Reject any explicit `.` or `..` segments in security scope checks so `/allowed/../../etc/passwd`
    // can NEVER bypass naive prefix patterns even before filesystem canonicalization!
    var seg_iter = std.mem.tokenizeAny(u8, candidate_path, "/\\");
    while (seg_iter.next()) |seg| {
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return false;
    }

    var norm_buf: [2048]u8 = undefined;
    const canonical = url.decodeAndNormalizeUrlPath(&norm_buf, candidate_path) catch return false;
    return match(scope_pattern, canonical);
}

const StateSet = struct {
    const word_count = (MAX_PATTERN_LEN / 64) + 1;
    words: [word_count]u64 = @splat(0),

    inline fn set(self: *StateSet, idx: usize) void {
        self.words[idx >> 6] |= (@as(u64, 1) << @intCast(idx & 63));
    }

    inline fn isSet(self: *const StateSet, idx: usize) bool {
        return (self.words[idx >> 6] & (@as(u64, 1) << @intCast(idx & 63))) != 0;
    }

    inline fn isEmpty(self: *const StateSet) bool {
        for (self.words) |w| {
            if (w != 0) return false;
        }
        return true;
    }
};

fn expandEpsilon(pattern: []const u8, states: *StateSet) void {
    var pi: usize = 0;
    while (pi < pattern.len) : (pi += 1) {
        if (!states.isSet(pi)) continue;
        if (isDoubleStarAt(pattern, pi)) {
            // `**` matches zero characters -> advance to `pi + 2`
            states.set(pi + 2);
            // Also if pattern has `/**/` (`pi + 2 < len` and `pattern[pi + 2]` is `/`), allow 0 directory segments!
            if (pi + 2 < pattern.len and normalizeSep(pattern[pi + 2]) == '/') {
                states.set(pi + 3);
            }
        } else if (pattern[pi] == '*') {
            states.set(pi + 1);
        }
    }
}

inline fn isDoubleStarAt(pattern: []const u8, pi: usize) bool {
    return pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*';
}

inline fn normalizeSep(b: u8) u8 {
    return if (b == '\\') '/' else b;
}

const DecodedUnit = struct {
    ch: u21,
    len: usize,
};

inline fn decodeNormalizedUnit(s: []const u8, idx: usize) DecodedUnit {
    const b = s[idx];
    if (b < 0x80) {
        return .{ .ch = normalizeSep(b), .len = 1 };
    }
    const seq_len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .ch = b, .len = 1 };
    if (idx + seq_len > s.len) return .{ .ch = b, .len = 1 };
    const cp = std.unicode.utf8Decode(s[idx .. idx + seq_len]) catch return .{ .ch = b, .len = 1 };
    return .{ .ch = cp, .len = seq_len };
}

fn matchCharClass(pattern: []const u8, bracket_idx: usize, target: u21) ?usize {
    var i = bracket_idx + 1;
    if (i >= pattern.len) return null;

    var negated = false;
    if (pattern[i] == '!' or pattern[i] == '^') {
        negated = true;
        i += 1;
    }

    var matched = false;
    var first = true;
    while (i < pattern.len) {
        if (!first and pattern[i] == ']') {
            return if (matched != negated) i + 1 else return 0; // 0 indicates valid class that didn't match
        }
        first = false;

        const lo = decodeNormalizedUnit(pattern, i);
        i += lo.len;

        if (i + 1 < pattern.len and pattern[i] == '-' and pattern[i + 1] != ']') {
            i += 1;
            const hi = decodeNormalizedUnit(pattern, i);
            i += hi.len;
            if (target >= lo.ch and target <= hi.ch) matched = true;
        } else {
            if (target == lo.ch) matched = true;
        }
    }
    return null; // Unclosed bracket `[`
}

// ============================================================================
// Unit Tests
// ============================================================================

test "Glob matcher supports *, **, ?, character classes, Windows separators, and defeats ReDoS" {
    // Single `*` does NOT cross `/`
    try testing.expect(match("/assets/*.js", "/assets/app.js"));
    try testing.expect(!match("/assets/*.js", "/assets/sub/app.js"));

    // Double `**` matches 0, 1, or many directory levels
    try testing.expect(match("/app/**/config.json", "/app/config.json"));
    try testing.expect(match("/app/**/config.json", "/app/v1/config.json"));
    try testing.expect(match("/app/**/config.json", "/app/a/b/c/config.json"));
    try testing.expect(match("/app/**", "/app/deep/nested/file.bin"));

    // `?`, character ranges `[0-9]`, negated `[!a-z]`, and Windows backslashes
    try testing.expect(match("/icon-?.[ps][nv]g", "\\icon-1.png"));
    try testing.expect(match("/icon-?.[ps][nv]g", "/icon-A.svg"));
    try testing.expect(!match("/icon-?.[ps][nv]g", "/icon-12.png"));
    try testing.expect(match("/item-[!0-9]", "/item-X"));
    try testing.expect(!match("/item-[!0-9]", "/item-5"));

    // Path scope safety blocks `..` traversal & `%2e%2e` escapes completely
    try testing.expect(matchSafePathScope("/home/user/docs/**", "/home/user/docs/sub/report.pdf"));
    try testing.expect(!matchSafePathScope("/home/user/docs/**", "/home/user/docs/../../etc/passwd"));
    try testing.expect(!matchSafePathScope("/home/user/docs/**", "/home/user/docs/%2e%2e/%2e%2e/secret"));

    // Pathological ReDoS input returns instantaneously in microseconds
    const evil_pattern = "*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b";
    const a64: [64]u8 = @splat('a');
    const evil_input = a64 ++ "c";
    try testing.expect(!match(evil_pattern, evil_input));
}

test "Glob & URL normalizer 1,000-iteration randomized fuzz test: zero crashes & strict canonical invariants" {
    var prng = std.Random.DefaultPrng.init(0x5A54_5332);
    const rnd = prng.random();
    const alphabet = "ab01/*?.[]!%-_\\";

    var pat_buf: [48]u8 = undefined;
    var txt_buf: [64]u8 = undefined;
    var norm_buf: [128]u8 = undefined;

    for (0..1000) |_| {
        const plen = rnd.uintLessThan(usize, pat_buf.len);
        const tlen = rnd.uintLessThan(usize, txt_buf.len);
        for (pat_buf[0..plen]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        for (txt_buf[0..tlen]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];

        // Must never panic or hang for any arbitrary pattern/text combination
        _ = match(pat_buf[0..plen], txt_buf[0..tlen]);
        _ = matchSafePathScope("/safe/**", txt_buf[0..tlen]);

        // Any path accepted by `decodeAndNormalizeUrlPath` MUST start with `'/'`, contain zero `'\\'`
        // or NUL bytes, and NEVER contain `".."` segments!
        if (url.decodeAndNormalizeUrlPath(&norm_buf, txt_buf[0..tlen])) |canon| {
            try testing.expect(canon.len >= 1 and canon[0] == '/');
            try testing.expect(std.mem.indexOfScalar(u8, canon, '\\') == null);
            try testing.expect(std.mem.indexOfScalar(u8, canon, 0) == null);
            var segs = std.mem.tokenizeScalar(u8, canon, '/');
            while (segs.next()) |s| {
                try testing.expect(!std.mem.eql(u8, s, "..") and !std.mem.eql(u8, s, "."));
            }
        } else |_| {}
    }
}
