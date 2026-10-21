//! Capability-scope glob matching (`*`, `**`, `?`) with path-traversal hardening.
//!
//! Tauri's `capabilities/*.json` scopes match filesystem paths and remote URLs
//! against glob patterns. A naive matcher is a security hole: `**` must not be
//! able to escape the scope root through `..` segments, and a hostile pattern or
//! path must never cause unbounded recursion/allocation. This module therefore
//! works purely on borrowed slices, caps segment counts, and fails closed.
//!
//! Semantics:
//! - `*` matches any run of characters inside a single path segment (never `/`).
//! - `?` matches exactly one character inside a single path segment.
//! - `**` as a whole segment matches zero or more entire segments.
//! - Consecutive `*` inside a normal segment (e.g. `a**b`) behave like `*`.
//! - `\` is treated as a separator (Windows) unless disabled via `Options`.
//! - Leading `/`, duplicate `/`, and `.` segments are normalized away.
//! - Any `..` segment (including percent-encoded `%2e%2e`) makes the whole match
//!   fail, so a pattern can never be traversed out of its scope.

const std = @import("std");

/// Longer patterns/paths are rejected instead of risking quadratic blowups.
pub const max_pattern_bytes: usize = 4096;
pub const max_path_bytes: usize = 8192;
/// Caps the greedy backtracking work and denies pathological paths.
pub const max_segments: usize = 256;

pub const Options = struct {
    /// Match ASCII case-insensitively (Windows / default macOS filesystems).
    case_insensitive: bool = false,
    /// Treat `\` as a path separator (Windows-style scopes).
    backslash_is_separator: bool = true,
};

const Segment = struct { text: []const u8 };

/// Returns true when `path` is fully matched by `pattern`.
pub fn match(pattern: []const u8, path: []const u8) bool {
    return matchWith(pattern, path, .{});
}

/// Returns true when `path` is fully matched by `pattern` under `options`.
pub fn matchWith(pattern: []const u8, path: []const u8, options: Options) bool {
    if (pattern.len > max_pattern_bytes or path.len > max_path_bytes) return false;
    if (std.mem.findScalar(u8, pattern, 0) != null) return false;
    if (std.mem.findScalar(u8, path, 0) != null) return false;
    // Reject invalid UTF-8 outright: scope paths are protocol strings, and
    // permissive byte matching invites overlong-encoding bypasses.
    if (!std.unicode.utf8ValidateSlice(pattern)) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;

    var pattern_segments: [max_segments]Segment = undefined;
    var path_segments: [max_segments]Segment = undefined;

    const pattern_count = splitSegments(pattern, &pattern_segments, options) orelse return false;
    const path_count = splitSegments(path, &path_segments, options) orelse return false;

    return matchSegments(pattern_segments[0..pattern_count], path_segments[0..path_count], options);
}

/// Returns true when any of `patterns` matches `path`.
pub fn matchAny(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pattern| {
        if (match(pattern, path)) return true;
    }
    return false;
}

/// True when the string contains any glob metacharacter.
pub fn hasWildcard(pattern: []const u8) bool {
    return std.mem.findAny(u8, pattern, "*?") != null;
}

/// Security check used before touching the filesystem: no NUL bytes, no control
/// characters, and no `.`/`..` segments in either literal or percent-encoded form.
pub fn isSafePath(path: []const u8) bool {
    if (path.len > max_path_bytes) return false;
    if (std.mem.findScalar(u8, path, 0) != null) return false;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |segment| {
        if (isUnsafeSegment(segment)) return false;
    }
    return true;
}

fn splitSegments(
    input: []const u8,
    out: *[max_segments]Segment,
    options: Options,
) ?usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < input.len) {
        while (index < input.len and isSeparator(input[index], options)) : (index += 1) {}
        if (index >= input.len) break;

        const start = index;
        while (index < input.len and !isSeparator(input[index], options)) : (index += 1) {}
        const segment = input[start..index];

        if (std.mem.eql(u8, segment, ".")) continue;
        // `..` anywhere makes the whole target unsafe: fail closed rather than
        // silently normalizing it away.
        if (isUnsafeSegment(segment)) return null;
        if (count == max_segments) return null;
        out[count] = .{ .text = segment };
        count += 1;
    }
    return count;
}

fn isSeparator(c: u8, options: Options) bool {
    return c == '/' or (options.backslash_is_separator and c == '\\');
}

fn matchSegments(
    patterns: []const Segment,
    paths: []const Segment,
    options: Options,
) bool {
    var pattern_index: usize = 0;
    var path_index: usize = 0;
    // Greedy match with a single backtrack point for the most recent `**`.
    // Standard glob semantics: remembering the latest star is sufficient.
    var backtrack_pattern: ?usize = null;
    var backtrack_path: usize = 0;

    while (path_index < paths.len) {
        if (pattern_index < patterns.len and isRecursive(patterns[pattern_index].text)) {
            backtrack_pattern = pattern_index;
            backtrack_path = path_index;
            pattern_index += 1;
            continue;
        }
        if (pattern_index < patterns.len and
            matchSegment(patterns[pattern_index].text, paths[path_index].text, options))
        {
            pattern_index += 1;
            path_index += 1;
            continue;
        }
        if (backtrack_pattern) |star| {
            backtrack_path += 1;
            if (backtrack_path > paths.len) return false;
            path_index = backtrack_path;
            pattern_index = star + 1;
            continue;
        }
        return false;
    }

    while (pattern_index < patterns.len and isRecursive(patterns[pattern_index].text)) {
        pattern_index += 1;
    }
    return pattern_index == patterns.len;
}

fn isRecursive(segment: []const u8) bool {
    if (segment.len < 2) return false;
    for (segment) |c| {
        if (c != '*') return false;
    }
    return true;
}

fn matchSegment(pattern: []const u8, text: []const u8, options: Options) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_pattern: ?usize = null;
    var star_text: usize = 0;

    while (text_index < text.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or
                charsEqual(pattern[pattern_index], text[text_index], options)))
        {
            pattern_index += 1;
            text_index += 1;
            continue;
        }
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern = pattern_index;
            star_text = text_index;
            pattern_index += 1;
            continue;
        }
        if (star_pattern) |star| {
            star_text += 1;
            text_index = star_text;
            pattern_index = star + 1;
            continue;
        }
        return false;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

fn charsEqual(a: u8, b: u8, options: Options) bool {
    if (a == b) return true;
    if (!options.case_insensitive) return false;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// Detects `..` (including percent-encoded `%2e%2e`) and encoded separators
/// (`%2f`, `%5c`) inside a segment. Both would let a decoded path escape its
/// scope, so they fail closed. A literal `%` that does not form a valid escape
/// is treated as harmless text.
fn isUnsafeSegment(segment: []const u8) bool {
    var decoded_len: usize = 0;
    var all_dots = true;
    var index: usize = 0;
    while (index < segment.len) {
        var c = segment[index];
        if (c == '%') {
            if (index + 2 >= segment.len) return false;
            const high = hexValue(segment[index + 1]) orelse return false;
            const low = hexValue(segment[index + 2]) orelse return false;
            c = (high << 4) | low;
            index += 3;
        } else {
            index += 1;
        }
        if (c == '/' or c == '\\' or c == 0) return true;
        if (c != '.') all_dots = false;
        decoded_len += 1;
    }
    return all_dots and decoded_len >= 2;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

const testing = std.testing;

test "glob: literal exact match" {
    try testing.expect(match("index.html", "index.html"));
    try testing.expect(match("/assets/index.html", "/assets/index.html"));
    try testing.expect(!match("index.html", "index.htm"));
    try testing.expect(!match("index.html", "index.html.bak"));
}

test "glob: single star stays inside one segment" {
    try testing.expect(match("src/*.js", "src/main.js"));
    try testing.expect(match("src/*.js", "/src/./main.js"));
    try testing.expect(!match("src/*.js", "src/nested/main.js"));
    try testing.expect(!match("src/*.js", "src/main.css"));
    try testing.expect(match("*", "main.js"));
    try testing.expect(!match("*", "a/b"));
}

test "glob: double star crosses segment boundaries" {
    try testing.expect(match("src/**", "src/a/b/c.js"));
    try testing.expect(match("src/**", "src"));
    try testing.expect(match("**", "any/deep/path.txt"));
    try testing.expect(match("src/**/*.js", "src/main.js"));
    try testing.expect(match("src/**/*.js", "src/nested/deep/main.js"));
    try testing.expect(!match("src/**/*.js", "src/nested/deep/main.css"));
    try testing.expect(match("a/**/b", "a/b"));
    try testing.expect(match("a/**/b", "a/x/y/b"));
    try testing.expect(!match("a/**/b", "a/x/y/c"));
}

test "glob: question mark matches exactly one character" {
    try testing.expect(match("a?.js", "ab.js"));
    try testing.expect(!match("a?.js", "a.js"));
    try testing.expect(!match("a?.js", "abc.js"));
    try testing.expect(!match("a?b", "a/b"));
}

test "glob: case sensitivity is configurable" {
    try testing.expect(!match("Assets/*.PNG", "assets/logo.png"));
    try testing.expect(matchWith("Assets/*.PNG", "assets/logo.png", .{ .case_insensitive = true }));
}

test "glob: backslash separators are normalized" {
    try testing.expect(match("assets/**", "assets\\img\\logo.png"));
    try testing.expect(!matchWith("assets/**", "assets\\img\\logo.png", .{ .backslash_is_separator = false }));
}

test "glob: traversal attempts never match" {
    try testing.expect(!match("**", "../secret.txt"));
    try testing.expect(!match("assets/**", "assets/../../etc/passwd"));
    try testing.expect(!match("**", "a/../b"));
    try testing.expect(!match("**", "%2e%2e/secret"));
    try testing.expect(!match("**", "%2E%2E%2Fsecret"));
    try testing.expect(!match("../**", "a/b"));
    try testing.expect(!isSafePath("a/../b"));
    try testing.expect(!isSafePath("%2e%2e/etc/passwd"));
    try testing.expect(isSafePath("assets/img/logo.png"));
    try testing.expect(!isSafePath("assets/\x00evil"));
}

test "glob: NUL bytes and invalid UTF-8 fail closed" {
    try testing.expect(!match("a\x00b", "a\x00b"));
    try testing.expect(!match("*", "\xff\xfe"));
    try testing.expect(!match("\xff", "x"));
}

test "glob: oversized inputs and segment explosion fail closed" {
    var long_path = std.Io.Writer.Allocating.init(testing.allocator);
    defer long_path.deinit();
    for (0..max_segments + 10) |_| try long_path.writer.writeAll("a/");
    try long_path.writer.writeAll("b");
    try testing.expect(!match("**", long_path.written()));

    var huge: [max_pattern_bytes + 1]u8 = undefined;
    @memset(&huge, 'a');
    try testing.expect(!match(&huge, "a"));
}

test "glob: matchAny and hasWildcard helpers" {
    const patterns = [_][]const u8{ "src/*.js", "assets/**" };
    try testing.expect(matchAny(&patterns, "src/main.js"));
    try testing.expect(matchAny(&patterns, "assets/icons/x.svg"));
    try testing.expect(!matchAny(&patterns, "docs/readme.md"));
    try testing.expect(hasWildcard("a*"));
    try testing.expect(hasWildcard("a?"));
    try testing.expect(!hasWildcard("a/b"));
}

test "glob: repeated star inside a segment behaves like star" {
    try testing.expect(match("a**b", "ab"));
    try testing.expect(match("a**b", "axxxb"));
    try testing.expect(!match("a**b", "a/b"));
}

test "glob: empty pattern matches only empty path" {
    try testing.expect(match("", ""));
    try testing.expect(match("", "/"));
    try testing.expect(!match("", "a"));
}
