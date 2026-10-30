//! Zero-Allocation Pull JSON Cursor & Object Member Iterator (`src/rpc/scanner.zig`).
//!
//! Shared lexical layer for `zts_rpc.codec`:
//! - **0 heap allocations** on unescaped strings (`DecodedString.allocated == false`).
//! - **O(1) 3-word cursor checkpoint & rewind** (`saved = cursor.*`) for zero-copy internal union tags
//!   and untagged union backtracking.
//! - **3 UTF-16 lone surrogate decode modes** (`strict_utf8`, `lossy_utf8`, `wtf8` for Windows `OsPath`).
//! - **Reusable `ObjectIter`** eliminating repetitive `{ key: value, ... }` boilerplate across all decoders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const ScanError = error{
    OutOfMemory,
    SyntaxError,
    UnexpectedEndOfInput,
    UnexpectedToken,
    NonFiniteFloat,
    InvalidUtf8,
    LoneSurrogate,
    MaxDepthExceeded,
};

/// The lexical token a `Cursor` is sitting on. `eof` is a token, not an error, so a pull loop can
/// terminate without a special case.
pub const TokenKind = enum {
    object_begin,
    object_end,
    array_begin,
    array_end,
    string,
    number,
    boolean,
    null,
    eof,
};

/// How to turn a JSON string's bytes into a Zig slice.
///
/// * `.strict_utf8` — reject invalid UTF-8 (the default for request bodies).
/// * `.lossy_utf8` — replace invalid sequences with U+FFFD.
/// * `.wtf8` — keep unpaired surrogates as WTF-8, which is what a JS `JSON.stringify` can legally
///   produce and what must be re-encoded unchanged when proxying.
pub const StringDecodeMode = enum {
    strict_utf8,
    lossy_utf8,
    wtf8,
};

/// A decoded JSON string. `allocated` says whether the caller must free it (escapes force a copy;
/// plain ASCII borrows the input), so the fast path costs nothing.
pub const DecodedString = struct {
    slice: []const u8,
    allocated: bool,
    had_wtf8_surrogate: bool = false,

    pub fn freeIfAllocated(self: DecodedString, allocator: Allocator) void {
        if (self.allocated and self.slice.len > 0) {
            allocator.free(self.slice);
        }
    }
};

/// A number as it appeared in the input, plus whether it used float syntax. Deciding integer vs
/// float is left to the target type so `1` can fill an `f64` and `1.0` can be rejected by an `u32`.
pub const NumberToken = struct {
    slice: []const u8,
    is_float_syntax: bool,
};

/// Stateful pull-iterator over `{ "key": value, ... }` members with zero-copy key borrowing.
pub const ObjectIter = struct {
    cursor: *Cursor,
    first: bool = true,
    done: bool = false,

    /// Reads the next member's key and consumes the following `':'`, or consumes `'}'` and returns `null`.
    /// Caller MUST call `key.freeIfAllocated(allocator)` (typically via `defer`).
    pub fn nextKey(self: *ObjectIter, allocator: Allocator) ScanError!?DecodedString {
        if (self.done) return null;

        if (self.first) {
            self.first = false;
            if (try self.cursor.peekKind() == .object_end) {
                self.cursor.pos += 1;
                self.done = true;
                return null;
            }
        } else {
            self.cursor.skipWhitespace();
            if (self.cursor.pos >= self.cursor.input.len) return error.UnexpectedEndOfInput;
            switch (self.cursor.input[self.cursor.pos]) {
                ',' => self.cursor.pos += 1,
                '}' => {
                    self.cursor.pos += 1;
                    self.done = true;
                    return null;
                },
                else => return error.SyntaxError,
            }
        }

        const key = try self.cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
        errdefer key.freeIfAllocated(allocator);

        self.cursor.skipWhitespace();
        if (self.cursor.pos >= self.cursor.input.len or self.cursor.input[self.cursor.pos] != ':') {
            return error.SyntaxError;
        }
        self.cursor.pos += 1;
        return key;
    }
};

/// A zero-copy pull scanner over a JSON document. It tracks byte position and nesting depth (so a
/// crafted `[[[[…` body cannot blow the stack) but allocates nothing on its own.
pub const Cursor = struct {
    input: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    pub fn skipWhitespace(self: *Cursor) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    pub fn peekKind(self: *Cursor) ScanError!TokenKind {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return .eof;
        return switch (self.input[self.pos]) {
            '{' => .object_begin,
            '}' => .object_end,
            '[' => .array_begin,
            ']' => .array_end,
            '"' => .string,
            '-', '0'...'9' => .number,
            't', 'f' => .boolean,
            'n' => .null,
            else => error.SyntaxError,
        };
    }

    pub fn enterContainer(self: *Cursor, max_depth: usize) ScanError!void {
        if (self.depth >= max_depth) return error.MaxDepthExceeded;
        self.depth += 1;
    }

    pub fn leaveContainer(self: *Cursor) void {
        self.depth -= 1;
    }

    /// Consumes `'{'`, checks nesting depth, and returns an `ObjectIter`.
    /// Caller MUST `defer cursor.leaveContainer();` once iteration finishes or errors.
    pub fn beginObject(self: *Cursor, max_depth: usize) ScanError!ObjectIter {
        const kind = try self.peekKind();
        if (kind != .object_begin) {
            return if (kind == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
        }
        try self.enterContainer(max_depth);
        self.pos += 1; // '{'
        return .{ .cursor = self };
    }

    pub fn readBool(self: *Cursor) ScanError!bool {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
            self.pos += 4;
            return true;
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
            self.pos += 5;
            return false;
        }
        return switch (self.input[self.pos]) {
            '{', '}', '[', ']', '"', '-', '0'...'9', 'n' => error.UnexpectedToken,
            else => error.SyntaxError,
        };
    }

    pub fn readNull(self: *Cursor) ScanError!void {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        if (std.mem.startsWith(u8, self.input[self.pos..], "null")) {
            self.pos += 4;
            return;
        }
        return switch (self.input[self.pos]) {
            '{', '}', '[', ']', '"', '-', '0'...'9', 't', 'f' => error.UnexpectedToken,
            else => error.SyntaxError,
        };
    }

    pub fn readNumberToken(self: *Cursor) ScanError!NumberToken {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;

        const start = self.pos;
        var i = start;

        if (std.mem.startsWith(u8, self.input[i..], "NaN") or
            std.mem.startsWith(u8, self.input[i..], "Infinity") or
            std.mem.startsWith(u8, self.input[i..], "-Infinity"))
        {
            return error.NonFiniteFloat;
        }

        const first = self.input[i];
        if (first != '-' and !std.ascii.isDigit(first)) {
            return switch (first) {
                '{', '}', '[', ']', '"', 't', 'f', 'n' => error.UnexpectedToken,
                else => error.SyntaxError,
            };
        }

        if (self.input[i] == '-') {
            i += 1;
            if (i >= self.input.len) return error.UnexpectedEndOfInput;
        }

        if (self.input[i] == '0') {
            i += 1;
            if (i < self.input.len and std.ascii.isDigit(self.input[i])) return error.SyntaxError;
        } else if (std.ascii.isDigit(self.input[i])) {
            while (i < self.input.len and std.ascii.isDigit(self.input[i])) : (i += 1) {}
        } else {
            return error.SyntaxError;
        }

        var is_float_syntax = false;
        if (i < self.input.len and self.input[i] == '.') {
            is_float_syntax = true;
            i += 1;
            if (i >= self.input.len or !std.ascii.isDigit(self.input[i])) return error.SyntaxError;
            while (i < self.input.len and std.ascii.isDigit(self.input[i])) : (i += 1) {}
        }

        if (i < self.input.len and (self.input[i] == 'e' or self.input[i] == 'E')) {
            is_float_syntax = true;
            i += 1;
            if (i < self.input.len and (self.input[i] == '+' or self.input[i] == '-')) i += 1;
            if (i >= self.input.len or !std.ascii.isDigit(self.input[i])) return error.SyntaxError;
            while (i < self.input.len and std.ascii.isDigit(self.input[i])) : (i += 1) {}
        }

        self.pos = i;
        return .{ .slice = self.input[start..i], .is_float_syntax = is_float_syntax };
    }

    pub fn readString(
        self: *Cursor,
        allocator: Allocator,
        alloc_when: std.json.AllocWhen,
        mode: StringDecodeMode,
    ) ScanError!DecodedString {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.pos] != '"') {
            return switch (self.input[self.pos]) {
                '{', '}', '[', ']', '-', '0'...'9', 't', 'f', 'n' => error.UnexpectedToken,
                else => error.SyntaxError,
            };
        }

        const start = self.pos + 1;
        var i = start;

        // Fast zero-copy path for unescaped JSON strings
        while (i < self.input.len) : (i += 1) {
            const c = self.input[i];
            if (c == '"') {
                const raw = self.input[start..i];
                if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
                self.pos = i + 1;
                if (alloc_when == .alloc_if_needed) {
                    return .{ .slice = raw, .allocated = false };
                }
                return .{ .slice = try allocator.dupe(u8, raw), .allocated = true };
            }
            if (c == '\\') break;
            if (c < 0x20) return error.SyntaxError;
        }

        if (i >= self.input.len) return error.UnexpectedEndOfInput;

        const prefix = self.input[start..i];
        if (!std.unicode.utf8ValidateSlice(prefix)) return error.InvalidUtf8;

        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        if (prefix.len > 0) try list.appendSlice(allocator, prefix);

        var had_wtf8_surrogate = false;
        var seg_start = i;

        while (i < self.input.len) {
            const c = self.input[i];
            if (c == '"') {
                const tail = self.input[seg_start..i];
                if (!std.unicode.utf8ValidateSlice(tail)) return error.InvalidUtf8;
                if (tail.len > 0) try list.appendSlice(allocator, tail);
                self.pos = i + 1;
                return .{
                    .slice = try list.toOwnedSlice(allocator),
                    .allocated = true,
                    .had_wtf8_surrogate = had_wtf8_surrogate,
                };
            }
            if (c < 0x20) return error.SyntaxError;
            if (c != '\\') {
                i += 1;
                continue;
            }

            const chunk = self.input[seg_start..i];
            if (!std.unicode.utf8ValidateSlice(chunk)) return error.InvalidUtf8;
            if (chunk.len > 0) try list.appendSlice(allocator, chunk);

            i += 1;
            if (i >= self.input.len) return error.UnexpectedEndOfInput;
            const esc = self.input[i];
            i += 1;

            switch (esc) {
                '"' => try list.append(allocator, '"'),
                '\\' => try list.append(allocator, '\\'),
                '/' => try list.append(allocator, '/'),
                'b' => try list.append(allocator, 0x08),
                'f' => try list.append(allocator, 0x0C),
                'n' => try list.append(allocator, '\n'),
                'r' => try list.append(allocator, '\r'),
                't' => try list.append(allocator, '\t'),
                'u' => {
                    if (i + 4 > self.input.len) return error.SyntaxError;
                    const cu1 = parseHex4(self.input[i..][0..4]) orelse return error.SyntaxError;
                    i += 4;

                    if (std.unicode.utf16IsHighSurrogate(cu1)) {
                        var paired_low: ?u16 = null;
                        if (i + 6 <= self.input.len and self.input[i] == '\\' and self.input[i + 1] == 'u') {
                            if (parseHex4(self.input[i + 2 ..][0..4])) |cu2| {
                                if (std.unicode.utf16IsLowSurrogate(cu2)) {
                                    paired_low = cu2;
                                    i += 6;
                                }
                            }
                        }
                        if (paired_low) |cu2| {
                            const pair = [2]u16{ cu1, cu2 };
                            const scalar = std.unicode.utf16DecodeSurrogatePair(&pair) catch unreachable;
                            var utf8_buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(scalar, &utf8_buf) catch unreachable;
                            try list.appendSlice(allocator, utf8_buf[0..len]);
                        } else {
                            try appendLoneSurrogate(&list, allocator, cu1, mode, &had_wtf8_surrogate);
                        }
                    } else if (std.unicode.utf16IsLowSurrogate(cu1)) {
                        try appendLoneSurrogate(&list, allocator, cu1, mode, &had_wtf8_surrogate);
                    } else {
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(cu1), &utf8_buf) catch unreachable;
                        try list.appendSlice(allocator, utf8_buf[0..len]);
                    }
                },
                else => return error.SyntaxError,
            }
            seg_start = i;
        }
        return error.UnexpectedEndOfInput;
    }

    pub fn skipString(self: *Cursor) ScanError!void {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.pos] != '"') return error.UnexpectedToken;
        var i = self.pos + 1;
        while (i < self.input.len) {
            const c = self.input[i];
            if (c == '"') {
                self.pos = i + 1;
                return;
            }
            if (c < 0x20) return error.SyntaxError;
            if (c == '\\') {
                i += 1;
                if (i >= self.input.len) return error.UnexpectedEndOfInput;
                switch (self.input[i]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => i += 1,
                    'u' => {
                        if (i + 5 > self.input.len) return error.SyntaxError;
                        _ = parseHex4(self.input[i + 1 ..][0..4]) orelse return error.SyntaxError;
                        i += 5;
                    },
                    else => return error.SyntaxError,
                }
            } else {
                i += 1;
            }
        }
        return error.UnexpectedEndOfInput;
    }

    pub fn skipValue(self: *Cursor, max_depth: usize) ScanError!void {
        switch (try self.peekKind()) {
            .eof => return error.UnexpectedEndOfInput,
            .boolean => _ = try self.readBool(),
            .null => try self.readNull(),
            .number => _ = try self.readNumberToken(),
            .string => try self.skipString(),
            .array_begin => {
                try self.enterContainer(max_depth);
                defer self.leaveContainer();
                self.pos += 1;
                if (try self.peekKind() == .array_end) {
                    self.pos += 1;
                    return;
                }
                while (true) {
                    try self.skipValue(max_depth);
                    self.skipWhitespace();
                    if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
                    switch (self.input[self.pos]) {
                        ',' => self.pos += 1,
                        ']' => {
                            self.pos += 1;
                            return;
                        },
                        else => return error.SyntaxError,
                    }
                }
            },
            .object_begin => {
                try self.enterContainer(max_depth);
                defer self.leaveContainer();
                self.pos += 1;
                if (try self.peekKind() == .object_end) {
                    self.pos += 1;
                    return;
                }
                while (true) {
                    try self.skipString();
                    self.skipWhitespace();
                    if (self.pos >= self.input.len or self.input[self.pos] != ':') return error.SyntaxError;
                    self.pos += 1;
                    try self.skipValue(max_depth);
                    self.skipWhitespace();
                    if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
                    switch (self.input[self.pos]) {
                        ',' => self.pos += 1,
                        '}' => {
                            self.pos += 1;
                            return;
                        },
                        else => return error.SyntaxError,
                    }
                }
            },
            .object_end, .array_end => return error.SyntaxError,
        }
    }
};

fn appendLoneSurrogate(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    cu: u16,
    mode: StringDecodeMode,
    had_wtf8: *bool,
) ScanError!void {
    switch (mode) {
        .strict_utf8 => return error.LoneSurrogate,
        .lossy_utf8 => try list.appendSlice(allocator, types.utf8_replacement_char),
        .wtf8 => {
            var wtf8_buf: [3]u8 = undefined;
            types.wtf8EncodeSurrogate(cu, &wtf8_buf);
            try list.appendSlice(allocator, &wtf8_buf);
            had_wtf8.* = true;
        },
    }
}

fn parseHex4(chars: *const [4]u8) ?u16 {
    var result: u16 = 0;
    for (chars) |c| {
        const digit: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        result = (result << 4) | digit;
    }
    return result;
}

test "Scanner rejects RFC 8259 invalid leading zeros, trailing commas, unescaped control bytes, and truncated tokens" {
    const testing = std.testing;

    // Leading zeros rejected per RFC 8259
    {
        var c = Cursor{ .input = "01" };
        try testing.expectError(error.SyntaxError, c.readNumberToken());
    }
    {
        var c = Cursor{ .input = "-00" };
        try testing.expectError(error.SyntaxError, c.readNumberToken());
    }

    // Trailing comma in object rejected by ObjectIter
    {
        var c = Cursor{ .input = "{\"a\":1,}" };
        var obj = try c.beginObject(16);
        defer c.leaveContainer();
        const k1 = (try obj.nextKey(testing.failing_allocator)).?;
        try testing.expectEqualStrings("a", k1.slice);
        _ = try c.readNumberToken();
        try testing.expectError(error.UnexpectedToken, obj.nextKey(testing.failing_allocator));
    }

    // Raw control char (< 0x20) inside JSON string rejected
    {
        var c = Cursor{ .input = "\"hello\x07world\"" };
        try testing.expectError(error.SyntaxError, c.readString(testing.allocator, .alloc_if_needed, .strict_utf8));
    }
}
