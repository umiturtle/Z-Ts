//! Compile-time and runtime identifier naming conventions for the Web ⇔ Zig RPC boundary.
//!
//! Responsibilities:
//! - `snake_case` → `camelCase` conversion at `comptime` (and runtime) for JSON/TS keys.
//! - Preservation of hyphenated HTML/CSS identifiers (`@"aria-label"`, `@"data-id"`, `@"--bg"`).
//! - `camelCase` → `snake_case` reverse conversion.
//! - JavaScript / TypeScript reserved-word and property-quoting diagnostics for `tsgen`.

const std = @import("std");
const testing = std.testing;

/// Returns `true` if `name` contains at least one ASCII hyphen (`'-'`).
///
/// Per `docs/architecture/web-zig-boundary.md` #4, hyphenated identifiers such as
/// `@"aria-label"`, `@"data-id"`, and `@"--bg"` must never be converted to `camelCase`.
pub fn hasHyphen(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '-') != null;
}

/// Computes the byte length of `snakeToCamel(snake)` at compile time or runtime.
pub fn snakeToCamelLen(snake: []const u8) usize {
    if (hasHyphen(snake)) return snake.len;

    var len: usize = 0;
    var seen_non_underscore = false;
    var pending_underscore = false;

    for (snake) |c| {
        if (c == '_') {
            if (!seen_non_underscore) {
                len += 1;
            } else {
                pending_underscore = true;
            }
        } else {
            seen_non_underscore = true;
            pending_underscore = false;
            len += 1;
        }
    }
    return len;
}

/// Writes the `camelCase` form of `snake` into `out` and returns the written slice.
/// `out.len` must be at least `snakeToCamelLen(snake)` (which is always `<= snake.len`).
pub fn snakeToCamelBuf(snake: []const u8, out: []u8) []const u8 {
    if (hasHyphen(snake)) {
        @memcpy(out[0..snake.len], snake);
        return out[0..snake.len];
    }

    var idx: usize = 0;
    var seen_non_underscore = false;
    var capitalize_next = false;

    for (snake) |c| {
        if (c == '_') {
            if (!seen_non_underscore) {
                out[idx] = '_';
                idx += 1;
            } else {
                capitalize_next = true;
            }
        } else {
            seen_non_underscore = true;
            if (capitalize_next) {
                out[idx] = std.ascii.toUpper(c);
                capitalize_next = false;
            } else {
                out[idx] = c;
            }
            idx += 1;
        }
    }
    return out[0..idx];
}

/// Converts a `snake_case` identifier to `camelCase` at `comptime`.
///
/// Rules:
/// 1. Identifiers containing `'-'` (`@"aria-label"`, `@"data-id"`, `@"--bg"`) are returned unchanged.
/// 2. Leading underscores (`"_id"`, `"__typename"`) are preserved so identifiers never collapse
///    to empty strings or inadvertently become `PascalCase`.
/// 3. Internal underscores followed by `[a-z]` are removed and the letter is uppercased.
/// 4. Internal underscores followed by `[0-9A-Z]` or trailing underscores after words are removed.
pub fn snakeToCamel(comptime snake: []const u8) *const [snakeToCamelLen(snake):0]u8 {
    const out_len = comptime snakeToCamelLen(snake);
    const result = comptime blk: {
        var buf: [out_len:0]u8 = undefined;
        _ = snakeToCamelBuf(snake, &buf);
        buf[out_len] = 0;
        break :blk buf;
    };
    return &result;
}

/// Allocates and returns the `camelCase` conversion of `snake` at runtime.
pub fn snakeToCamelAlloc(allocator: std.mem.Allocator, snake: []const u8) std.mem.Allocator.Error![]u8 {
    const out_len = snakeToCamelLen(snake);
    const buf = try allocator.alloc(u8, out_len);
    _ = snakeToCamelBuf(snake, buf);
    return buf;
}

/// Computes the byte length of `camelToSnake(camel)`.
pub fn camelToSnakeLen(camel: []const u8) usize {
    if (hasHyphen(camel)) return camel.len;

    var len: usize = 0;
    for (camel, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0 and camel[i - 1] != '_') {
                const prev_is_lower_or_digit = std.ascii.isLower(camel[i - 1]) or std.ascii.isDigit(camel[i - 1]);
                const next_is_lower = (i + 1 < camel.len) and std.ascii.isLower(camel[i + 1]);
                if (prev_is_lower_or_digit or next_is_lower) {
                    len += 1;
                }
            }
        }
        len += 1;
    }
    return len;
}

/// Writes the `snake_case` form of `camel` into `out` and returns the written slice.
pub fn camelToSnakeBuf(camel: []const u8, out: []u8) []const u8 {
    if (hasHyphen(camel)) {
        @memcpy(out[0..camel.len], camel);
        return out[0..camel.len];
    }

    var idx: usize = 0;
    for (camel, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0 and camel[i - 1] != '_') {
                const prev_is_lower_or_digit = std.ascii.isLower(camel[i - 1]) or std.ascii.isDigit(camel[i - 1]);
                const next_is_lower = (i + 1 < camel.len) and std.ascii.isLower(camel[i + 1]);
                if (prev_is_lower_or_digit or next_is_lower) {
                    out[idx] = '_';
                    idx += 1;
                }
            }
            out[idx] = std.ascii.toLower(c);
            idx += 1;
        } else {
            out[idx] = c;
            idx += 1;
        }
    }
    return out[0..idx];
}

/// Converts a `camelCase` (or `PascalCase`) identifier to `snake_case` at `comptime`.
/// Identifiers containing `'-'` are returned unchanged.
pub fn camelToSnake(comptime camel: []const u8) *const [camelToSnakeLen(camel):0]u8 {
    const out_len = comptime camelToSnakeLen(camel);
    const result = comptime blk: {
        var buf: [out_len:0]u8 = undefined;
        _ = camelToSnakeBuf(camel, &buf);
        buf[out_len] = 0;
        break :blk buf;
    };
    return &result;
}

/// Checks whether a JSON object key matches a Zig struct field name.
/// By default, matches against `comptime snakeToCamel(zig_field_name)`.
/// If `allow_snake_case` is `true`, also accepts the exact `zig_field_name`.
pub fn matchesFieldName(
    comptime zig_field_name: []const u8,
    json_key: []const u8,
    allow_snake_case: bool,
) bool {
    const camel_name = comptime snakeToCamel(zig_field_name);
    if (std.mem.eql(u8, json_key, camel_name)) return true;
    if (allow_snake_case and !std.mem.eql(u8, zig_field_name, camel_name)) {
        return std.mem.eql(u8, json_key, zig_field_name);
    }
    return false;
}

/// Complete list of ECMAScript / TypeScript reserved words and strict-mode restricted identifiers.
pub const js_reserved_words = std.StaticStringMap(void).initComptime(.{
    // ECMAScript keywords
    .{ "await", {} },
    .{ "break", {} },
    .{ "case", {} },
    .{ "catch", {} },
    .{ "class", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "debugger", {} },
    .{ "default", {} },
    .{ "delete", {} },
    .{ "do", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "export", {} },
    .{ "extends", {} },
    .{ "false", {} },
    .{ "finally", {} },
    .{ "for", {} },
    .{ "function", {} },
    .{ "if", {} },
    .{ "import", {} },
    .{ "in", {} },
    .{ "instanceof", {} },
    .{ "new", {} },
    .{ "null", {} },
    .{ "return", {} },
    .{ "super", {} },
    .{ "switch", {} },
    .{ "this", {} },
    .{ "throw", {} },
    .{ "true", {} },
    .{ "try", {} },
    .{ "typeof", {} },
    .{ "var", {} },
    .{ "void", {} },
    .{ "while", {} },
    .{ "with", {} },
    .{ "yield", {} },
    // Strict mode future reserved words & restricted bindings
    .{ "implements", {} },
    .{ "interface", {} },
    .{ "let", {} },
    .{ "package", {} },
    .{ "private", {} },
    .{ "protected", {} },
    .{ "public", {} },
    .{ "static", {} },
    .{ "arguments", {} },
    .{ "eval", {} },
    // TypeScript type-level / contextual keywords that break binding declarations
    .{ "any", {} },
    .{ "bigint", {} },
    .{ "boolean", {} },
    .{ "never", {} },
    .{ "number", {} },
    .{ "object", {} },
    .{ "string", {} },
    .{ "symbol", {} },
    .{ "undefined", {} },
    .{ "unknown", {} },
});

/// Returns `true` if `ident` is a JavaScript or TypeScript reserved word.
pub fn isJsReservedWord(ident: []const u8) bool {
    return js_reserved_words.has(ident);
}

/// Returns `true` if `ident` is a valid lexical ASCII JS identifier (`[A-Za-z_$][A-Za-z0-9_$]*`),
/// ignoring whether it is a reserved keyword.
pub fn isLexicalJsIdentifier(ident: []const u8) bool {
    if (ident.len == 0) return false;
    const first = ident[0];
    if (!std.ascii.isAlphabetic(first) and first != '_' and first != '$') return false;
    for (ident[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    }
    return true;
}

/// Returns `true` if `ident` can be used as a standalone JS/TS variable, parameter, or function name.
pub fn isValidJsBindingIdentifier(ident: []const u8) bool {
    return isLexicalJsIdentifier(ident) and !isJsReservedWord(ident);
}

/// Returns `true` if `ident` requires string quotes when emitted as a property name in a
/// TypeScript interface or JS object literal (e.g. `"aria-label"`, `"--bg"`, `"123"`).
pub fn needsPropertyQuotes(ident: []const u8) bool {
    return !isLexicalJsIdentifier(ident);
}

/// Escapes a `comptime` identifier for use as a JS/TS binding (parameter or function name)
/// by appending `"_"` if it collides with a JS/TS reserved word.
pub fn escapeJsBindingIdentifier(comptime ident: []const u8) []const u8 {
    const camel = comptime snakeToCamel(ident);
    if (comptime isJsReservedWord(camel)) {
        return camel ++ "_";
    }
    return camel;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "snakeToCamel converts standard snake_case identifiers at comptime" {
    try testing.expectEqualStrings("userId", comptime snakeToCamel("user_id"));
    try testing.expectEqualStrings("getWindowTitle", comptime snakeToCamel("get_window_title"));
    try testing.expectEqualStrings("maxHttpRetries", comptime snakeToCamel("max_http_retries"));
    try testing.expectEqualStrings("isFullscreen", comptime snakeToCamel("is_fullscreen"));
    try testing.expectEqualStrings("utf8Bytes", comptime snakeToCamel("utf8_bytes"));
    try testing.expectEqualStrings("utf8String", comptime snakeToCamel("utf_8_string"));
    try testing.expectEqualStrings("simple", comptime snakeToCamel("simple"));
    try testing.expectEqualStrings("alreadyCamelCase", comptime snakeToCamel("alreadyCamelCase"));
    try testing.expectEqualStrings("", comptime snakeToCamel(""));
}

test "snakeToCamel preserves hyphenated HTML/CSS identifiers unchanged" {
    try testing.expectEqualStrings("aria-label", comptime snakeToCamel("aria-label"));
    try testing.expectEqualStrings("aria-hidden", comptime snakeToCamel("aria-hidden"));
    try testing.expectEqualStrings("data-id", comptime snakeToCamel("data-id"));
    try testing.expectEqualStrings("data-test-id", comptime snakeToCamel("data-test-id"));
    try testing.expectEqualStrings("--bg", comptime snakeToCamel("--bg"));
    try testing.expectEqualStrings("--theme-primary-color", comptime snakeToCamel("--theme-primary-color"));
    // Even if a hyphenated key also contains an underscore, presence of '-' preserves it verbatim
    try testing.expectEqualStrings("data-user_id", comptime snakeToCamel("data-user_id"));
}

test "snakeToCamel handles leading, trailing, and consecutive underscores safely" {
    try testing.expectEqualStrings("_", comptime snakeToCamel("_"));
    try testing.expectEqualStrings("__", comptime snakeToCamel("__"));
    try testing.expectEqualStrings("_id", comptime snakeToCamel("_id"));
    try testing.expectEqualStrings("_userId", comptime snakeToCamel("_user_id"));
    try testing.expectEqualStrings("__tauriInternals", comptime snakeToCamel("__tauri_internals"));
    try testing.expectEqualStrings("fooBar", comptime snakeToCamel("foo__bar"));
    try testing.expectEqualStrings("fooBar", comptime snakeToCamel("foo_bar_"));
}

test "snakeToCamelAlloc matches comptime snakeToCamel and frees cleanly" {
    const cases = [_]struct { in: []const u8, expected: []const u8 }{
        .{ .in = "user_id", .expected = "userId" },
        .{ .in = "aria-label", .expected = "aria-label" },
        .{ .in = "--bg", .expected = "--bg" },
        .{ .in = "_private_field", .expected = "_privateField" },
    };
    for (cases) |tc| {
        const actual = try snakeToCamelAlloc(testing.allocator, tc.in);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(tc.expected, actual);
    }
}

test "camelToSnake converts camelCase and acronyms while preserving hyphens" {
    try testing.expectEqualStrings("user_id", comptime camelToSnake("userId"));
    try testing.expectEqualStrings("get_window_title", comptime camelToSnake("getWindowTitle"));
    try testing.expectEqualStrings("parse_html_doc", comptime camelToSnake("parseHTMLDoc"));
    try testing.expectEqualStrings("simple", comptime camelToSnake("simple"));
    try testing.expectEqualStrings("aria-label", comptime camelToSnake("aria-label"));
    try testing.expectEqualStrings("data-id", comptime camelToSnake("data-id"));
    try testing.expectEqualStrings("--bg", comptime camelToSnake("--bg"));
    try testing.expectEqualStrings("_user_id", comptime camelToSnake("_userId"));
}

test "matchesFieldName supports strict camelCase and optional snake_case fallback" {
    try testing.expect(matchesFieldName("user_id", "userId", false));
    try testing.expect(!matchesFieldName("user_id", "user_id", false));
    try testing.expect(matchesFieldName("user_id", "user_id", true));
    try testing.expect(matchesFieldName("aria-label", "aria-label", false));
    try testing.expect(!matchesFieldName("aria-label", "ariaLabel", false));
}

test "JS/TS reserved words and property quote detection" {
    // JS/TS reserved words
    try testing.expect(isJsReservedWord("delete"));
    try testing.expect(isJsReservedWord("class"));
    try testing.expect(isJsReservedWord("default"));
    try testing.expect(isJsReservedWord("in"));
    try testing.expect(isJsReservedWord("new"));
    try testing.expect(isJsReservedWord("function"));
    try testing.expect(isJsReservedWord("bigint"));
    try testing.expect(!isJsReservedWord("userId"));
    try testing.expect(!isJsReservedWord("windowTitle"));

    // Binding identifier escaping
    try testing.expectEqualStrings("delete_", comptime escapeJsBindingIdentifier("delete"));
    try testing.expectEqualStrings("class_", comptime escapeJsBindingIdentifier("class"));
    try testing.expectEqualStrings("userId", comptime escapeJsBindingIdentifier("user_id"));

    // Property quoting
    try testing.expect(needsPropertyQuotes("aria-label"));
    try testing.expect(needsPropertyQuotes("data-id"));
    try testing.expect(needsPropertyQuotes("--bg"));
    try testing.expect(needsPropertyQuotes("123abc"));
    try testing.expect(needsPropertyQuotes(""));
    try testing.expect(!needsPropertyQuotes("userId"));
    try testing.expect(!needsPropertyQuotes("$element"));
    try testing.expect(!needsPropertyQuotes("_internal"));
    // Reserved words are valid lexical identifiers (valid as unquoted TS property keys)
    // but NOT valid binding identifiers:
    try testing.expect(!needsPropertyQuotes("delete"));
    try testing.expect(!isValidJsBindingIdentifier("delete"));
    try testing.expect(isValidJsBindingIdentifier("userId"));
}
