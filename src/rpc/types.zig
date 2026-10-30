//! Web ⇔ Zig boundary wrapper types for `zts_rpc`.
//!
//! Resolves the core type-system impedance mismatches documented in
//! `docs/architecture/web-zig-boundary.md`:
//! - `BigInt(T)`: 64-bit / 128-bit integers serialized as decimal JSON strings (`"..."` ⇔ TS `bigint`).
//! - `Bytes`: Arbitrary binary data (`[]const u8` ⇔ Base64 / byte array ⇔ TS `Uint8Array`).
//! - `OsPath`: Lossless OS file path (`display` valid UTF-8 + `raw` non-UTF-8 / WTF-8 roundtrip token).
//! - `Patch(T)`: 3-state partial update field (`unchanged` [omitted] | `null` | `value: T`).
//! - `UnionStyle` / `UnionConfig` / `TaggedUnion`: 4 representation modes for `union(enum)`.
//! - `Handle(Tag)`: 53-bit generational handle (`packed struct(u53) { index: u24, generation: u29 }`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const core = @import("zts_foundation");

/// Maximum unsigned integer exactly representable in an IEEE 754 `f64` (`Number.MAX_SAFE_INTEGER = 2^53 - 1`).
pub const max_safe_uint: u53 = @intCast(core.MAX_JS_SAFE_INT);

/// `Number.MAX_SAFE_INTEGER` (`9007199254740991`).
pub const max_safe_int: i64 = @intCast(core.MAX_JS_SAFE_INT);

/// `Number.MIN_SAFE_INTEGER` (`-9007199254740991`).
pub const min_safe_int: i64 = -max_safe_int;

/// Lossless signed JS safe integer wrapper (`[-9007199254740991, +9007199254740991]` ⇔ JS `number`).
/// Complements `u53` (`[0, 2^53 - 1]`) and `i53` (`[-2^52, 2^52 - 1]`) when full `±(2^53 - 1)` signed range is needed.
pub const SafeInt = struct {
    /// The integer, guaranteed to round-trip through a JS `number`.
    value: i64,

    /// Codegen marker: serialize as a plain JSON number, checked against the safe range.
    pub const zts_rpc_type = .safe_int;

    /// Validates the range and fails with `error.Overflow` outside it.
    pub fn init(v: i64) error{Overflow}!SafeInt {
        if (v < min_safe_int or v > max_safe_int) return error.Overflow;
        return .{ .value = v };
    }

    /// The wrapped integer.
    pub inline fn get(self: SafeInt) i64 {
        return self.value;
    }

    /// Compares two values.
    pub inline fn eql(a: SafeInt, b: SafeInt) bool {
        return a.value == b.value;
    }
};

/// Zero-copy syntax-validated raw JSON value slice (`unknown` in TypeScript).
///
/// Ideal for generic event brokers (`plugin:event|emit`), pass-through RPC gateways,
/// and late-bound payloads where re-parsing and re-serializing arbitrary JSON trees is unnecessary.
pub const RawJson = struct {
    /// The JSON text, borrowed; `"null"` when the wire sent nothing.
    raw: []const u8 = "null",

    /// Codegen marker: pass the bytes through untouched.
    pub const zts_rpc_type = .raw_json;
    /// TypeScript type emitted for this wrapper.
    pub const zts_ts_type: []const u8 = "unknown";

    /// Wraps a slice, substituting `null` for an empty one.
    pub inline fn init(raw_slice: []const u8) RawJson {
        return .{ .raw = if (raw_slice.len == 0) "null" else raw_slice };
    }
};

/// UTF-8 encoding of `U+FFFD REPLACEMENT CHARACTER` (`""`).
pub const utf8_replacement_char = "\xEF\xBF\xBD";

/// Returns `true` if `T` is a Zig integer type that is guaranteed at the type level
/// to fit within IEEE 754 double-precision safe integer range (`bits <= 53`, excluding platform-sized `usize`/`isize`).
pub fn isSafeJsIntegerType(comptime T: type) bool {
    if (T == usize or T == isize) return false;
    return switch (@typeInfo(T)) {
        .int => |info| info.bits <= 53,
        else => false,
    };
}

/// Validates that `slice` is a canonical base-10 integer string (optional leading `'-'` if `is_signed`,
/// followed by one or more ASCII digits `'0'...'9'`).
pub fn isCanonicalDecimalInt(slice: []const u8, is_signed: bool) bool {
    if (slice.len == 0) return false;
    var idx: usize = 0;
    if (slice[0] == '-') {
        if (!is_signed or slice.len == 1) return false;
        idx = 1;
    }
    while (idx < slice.len) : (idx += 1) {
        if (!std.ascii.isDigit(slice[idx])) return false;
    }
    return true;
}

/// Wrapper for 64-bit / 128-bit integers (`i64`, `u64`, `i128`, `u128`, `isize`, `usize`)
/// that crosses the JSON boundary as a base-10 string (`"9007199254740993"`) and maps to TypeScript `bigint`.
pub fn BigInt(comptime T: type) type {
    if (@typeInfo(T) != .int) {
        @compileError("BigInt(T) requires an integer type, got '" ++ @typeName(T) ++ "'");
    }

    return struct {
        value: T,

        pub const ValueType = T;
        pub const zts_rpc_type = .big_int;

        pub fn init(v: T) @This() {
            return .{ .value = v };
        }

        pub fn get(self: @This()) T {
            return self.value;
        }

        pub fn eql(self: @This(), other: @This()) bool {
            return self.value == other.value;
        }

        pub fn parseDecimalSlice(slice: []const u8) error{ InvalidNumber, Overflow }!@This() {
            const is_signed = @typeInfo(T).int.signedness == .signed;
            if (!isCanonicalDecimalInt(slice, is_signed)) return error.InvalidNumber;
            const parsed = std.fmt.parseInt(T, slice, 10) catch |err| switch (err) {
                error.Overflow => return error.Overflow,
                error.InvalidCharacter => return error.InvalidNumber,
            };
            return .{ .value = parsed };
        }

        pub fn writeJson(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("\"{d}\"", .{self.value});
        }

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.print("\"{d}\"", .{self.value});
        }

        pub fn jsonParse(
            allocator: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !@This() {
            const token = try source.nextAllocMax(
                allocator,
                .alloc_if_needed,
                options.max_value_len orelse std.json.default_max_value_len,
            );
            defer switch (token) {
                .allocated_number, .allocated_string => |s| allocator.free(s),
                else => {},
            };
            const slice = switch (token) {
                .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            return parseDecimalSlice(slice);
        }
    };
}

/// Returns `true` if `T` is an instantiation of `BigInt(...)`.
pub fn isBigIntType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "zts_rpc_type") and
        @TypeOf(T.zts_rpc_type) == @TypeOf(.big_int) and
        T.zts_rpc_type == .big_int;
}

/// Raw binary data wrapper (`[]const u8` ⇔ TS `Uint8Array`).
///
/// Distinct from `[]const u8`, which is strictly a UTF-8 text string (`TS string`).
/// In JSON mode, `Bytes` encodes as a Base64 string (or `[u8, ...]` array when configured)
/// and decodes from either a Base64 string or a JSON array of `0..255` numbers.
pub const Bytes = struct {
    /// The raw bytes, borrowed from the input.
    data: []const u8,

    /// Codegen marker: Base64 on the wire, `Uint8Array` in TypeScript.
    pub const zts_rpc_type = .bytes;

    /// Wraps a borrowed slice.
    pub fn init(data: []const u8) Bytes {
        return .{ .data = data };
    }

    /// The zero-length value.
    pub fn empty() Bytes {
        return .{ .data = "" };
    }

    /// The raw bytes.
    pub fn slice(self: Bytes) []const u8 {
        return self.data;
    }

    /// Length in bytes.
    pub fn len(self: Bytes) usize {
        return self.data.len;
    }

    /// Compares contents.
    pub fn eql(self: Bytes, other: Bytes) bool {
        return std.mem.eql(u8, self.data, other.data);
    }

    /// Writes the standard Base64 representation of `self.data` (without surrounding quotes) to `writer`.
    pub fn writeBase64(self: Bytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.base64.standard.Encoder.encodeWriter(writer, self.data);
    }

    /// Allocates and returns the standard Base64 string for `self.data`.
    pub fn encodeBase64Alloc(self: Bytes, allocator: Allocator) Allocator.Error![]u8 {
        const encoded_len = std.base64.standard.Encoder.calcSize(self.data.len);
        const buf = try allocator.alloc(u8, encoded_len);
        _ = std.base64.standard.Encoder.encode(buf, self.data);
        return buf;
    }

    /// Decodes a standard Base64 string into a newly allocated `Bytes`.
    pub fn decodeBase64Alloc(allocator: Allocator, encoded: []const u8) (Allocator.Error || std.base64.Error)!Bytes {
        if (encoded.len == 0) {
            return .{ .data = "" };
        }
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const buf = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(buf);
        try std.base64.standard.Decoder.decode(buf, encoded);
        return .{ .data = buf };
    }

    /// Writes standard Base64 (what `Uint8Array` transports as).
    pub fn jsonStringify(self: Bytes, jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        try self.writeBase64(jw.writer);
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }

    /// Decodes standard Base64 into a buffer owned by the caller's allocator.
    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Bytes {
        const max_len = options.max_value_len orelse std.json.default_max_value_len;
        switch (try source.peekNextTokenType()) {
            .string => {
                const tok = try source.nextAllocMax(allocator, .alloc_if_needed, max_len);
                defer switch (tok) {
                    .allocated_string => |s| allocator.free(s),
                    else => {},
                };
                const str = switch (tok) {
                    .string, .allocated_string => |s| s,
                    else => unreachable,
                };
                return decodeBase64Alloc(allocator, str) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.UnexpectedToken,
                };
            },
            .array_begin => {
                _ = try source.next();
                var list: std.ArrayList(u8) = .empty;
                errdefer list.deinit(allocator);
                while (true) {
                    if (try source.peekNextTokenType() == .array_end) {
                        _ = try source.next();
                        break;
                    }
                    const byte_val = try std.json.innerParse(u8, allocator, source, options);
                    try list.append(allocator, byte_val);
                }
                return .{ .data = try list.toOwnedSlice(allocator) };
            },
            else => return error.UnexpectedToken,
        }
    }
};

/// Encodes a lone UTF-16 surrogate (`0xD800..0xDFFF`) into its 3-byte WTF-8 representation
/// (`0xED 0xA0..0xBF 0x80..0xBF`).
pub fn wtf8EncodeSurrogate(code_unit: u16, out: *[3]u8) void {
    std.debug.assert(code_unit >= 0xD800 and code_unit <= 0xDFFF);
    out[0] = @intCast(0xE0 | (code_unit >> 12));
    out[1] = @intCast(0x80 | ((code_unit >> 6) & 0x3F));
    out[2] = @intCast(0x80 | (code_unit & 0x3F));
}

/// If `bytes` begins with a 3-byte WTF-8 encoded surrogate (`0xED 0xA0..0xBF 0x80..0xBF`),
/// returns the decoded UTF-16 surrogate code unit (`0xD800..0xDFFF`); otherwise returns `null`.
pub fn wtf8DecodeSurrogatePrefix(bytes: []const u8) ?u16 {
    if (bytes.len < 3) return null;
    if (bytes[0] != 0xED) return null;
    if (bytes[1] < 0xA0 or bytes[1] > 0xBF) return null;
    if (bytes[2] < 0x80 or bytes[2] > 0xBF) return null;
    const cp: u16 = (@as(u16, bytes[0] & 0x0F) << 12) |
        (@as(u16, bytes[1] & 0x3F) << 6) |
        @as(u16, bytes[2] & 0x3F);
    return cp;
}

/// Writes a valid UTF-8 representation of `raw_bytes` to `writer`, replacing any ill-formed
/// UTF-8 byte sequence (or 3-byte WTF-8 lone surrogate sequence) with `U+FFFD` (`\xEF\xBF\xBD`).
pub fn writeLossyUtf8(raw_bytes: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var i: usize = 0;
    var valid_start: usize = 0;

    while (i < raw_bytes.len) {
        const b0 = raw_bytes[i];
        if (b0 < 0x80) {
            i += 1;
            continue;
        }

        // Check for valid UTF-8 multi-byte sequence
        const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch {
            if (i > valid_start) try writer.writeAll(raw_bytes[valid_start..i]);
            try writer.writeAll(utf8_replacement_char);
            i += 1;
            valid_start = i;
            continue;
        };

        if (i + seq_len <= raw_bytes.len) {
            if (std.unicode.utf8Decode(raw_bytes[i .. i + seq_len])) |_| {
                i += seq_len;
                continue;
            } else |_| {}
        }

        // Flush preceding valid UTF-8 chunk
        if (i > valid_start) try writer.writeAll(raw_bytes[valid_start..i]);
        try writer.writeAll(utf8_replacement_char);

        // If this is a 3-byte WTF-8 surrogate sequence (0xED 0xA0..0xBF 0x80..0xBF),
        // consume all 3 bytes as a single lone surrogate replacement!
        if (wtf8DecodeSurrogatePrefix(raw_bytes[i..]) != null) {
            i += 3;
        } else {
            i += 1;
        }
        valid_start = i;
    }

    if (i > valid_start) {
        try writer.writeAll(raw_bytes[valid_start..i]);
    }
}

/// Allocates a valid UTF-8 string from `raw_bytes`, replacing ill-formed sequences with `U+FFFD`.
pub fn allocLossyUtf8(allocator: Allocator, raw_bytes: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    writeLossyUtf8(raw_bytes, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Lossless OS file path across the Web ⇔ Zig boundary (`docs/architecture/web-zig-boundary.md` #1).
///
/// - On POSIX (Linux), paths are arbitrary byte slices (`[]const u8`) that may contain non-UTF-8 bytes.
/// - On Windows, paths are UTF-16LE with possible unpaired surrogates, represented in Zig as WTF-8.
/// - On the JSON wire:
///   - Valid UTF-8 paths can be represented directly as a UTF-8 string `"/path/to/file"` or
///     as `{"display":"/path/to/file","rawToken":null}`.
///   - Non-UTF-8 / WTF-8 paths are serialized as `{"display":"...","rawToken":"<base64>"}` where
///     `display` is guaranteed valid UTF-8 (with `U+FFFD` replacement) for UI rendering and
///     `rawToken` preserves the exact raw OS bytes for 100% lossless roundtrip back to Zig.
pub const OsPath = struct {
    /// Exact OS path bytes (valid UTF-8, Windows WTF-8, or arbitrary POSIX path bytes).
    raw: []const u8,
    /// Valid UTF-8 display string for UI rendering.
    /// When `raw` is valid UTF-8, `display` aliases `raw` directly.
    /// When initialized via `fromRawBorrowed` on non-UTF-8 bytes, `display` may be `""` and is
    /// computed on the fly during JSON encoding.
    display: []const u8,

    /// Codegen marker: `{ raw, display }` object on the wire.
    pub const zts_rpc_type = .os_path;

    /// Constructs an `OsPath` from a known valid UTF-8 slice with zero allocation.
    pub fn fromUtf8(utf8_path: []const u8) OsPath {
        std.debug.assert(std.unicode.utf8ValidateSlice(utf8_path));
        return .{
            .raw = utf8_path,
            .display = utf8_path,
        };
    }

    /// Constructs an `OsPath` from arbitrary raw OS bytes without allocating.
    /// If `raw_bytes` is valid UTF-8, `display` aliases `raw_bytes`.
    /// Otherwise `display` is set to `""` and lossy UTF-8 is streamed on demand during JSON encoding.
    pub fn fromRawBorrowed(raw_bytes: []const u8) OsPath {
        if (std.unicode.utf8ValidateSlice(raw_bytes)) {
            return .{ .raw = raw_bytes, .display = raw_bytes };
        }
        return .{ .raw = raw_bytes, .display = "" };
    }

    /// Constructs an `OsPath` from arbitrary raw OS bytes, allocating a lossy UTF-8 `display` string
    /// only when `raw_bytes` is not already valid UTF-8.
    pub fn init(allocator: Allocator, raw_bytes: []const u8) Allocator.Error!OsPath {
        if (std.unicode.utf8ValidateSlice(raw_bytes)) {
            return .{
                .raw = raw_bytes,
                .display = raw_bytes,
            };
        }
        const lossy = try allocLossyUtf8(allocator, raw_bytes);
        return .{
            .raw = raw_bytes,
            .display = lossy,
        };
    }

    /// Frees `self.display` if it was separately allocated (i.e. does not alias `self.raw` and is non-empty).
    pub fn deinitDisplayIfAllocated(self: OsPath, allocator: Allocator) void {
        if (self.display.len > 0 and self.display.ptr != self.raw.ptr) {
            allocator.free(self.display);
        }
    }

    /// Returns `true` if `self.raw` is valid UTF-8 (meaning no `rawToken` is needed).
    pub fn isLosslessUtf8(self: OsPath) bool {
        return std.unicode.utf8ValidateSlice(self.raw);
    }

    /// Returns the exact raw OS path bytes for passing to `std.Io.File` / OS filesystem APIs.
    pub fn asSlice(self: OsPath) []const u8 {
        return self.raw;
    }

    /// Compares the raw bytes.
    pub fn eql(self: OsPath, other: OsPath) bool {
        return std.mem.eql(u8, self.raw, other.raw);
    }
};

/// 3-state wrapper for partial updates (`PATCH` semantics, `docs/architecture/web-zig-boundary.md` #2).
///
/// Distinguishes:
/// - `.unchanged`: Key was omitted in JSON (`{}` / JS `undefined`)
/// - `.null`: Key was explicitly set to `null` (`{"field": null}`)
/// - `.value`: Key was explicitly set to a value (`{"field": <T>}`)
pub fn Patch(comptime T: type) type {
    return union(enum) {
        unchanged,
        null,
        value: T,

        pub const Child = T;
        pub const zts_rpc_type = .patch;

        pub fn initValue(v: T) @This() {
            return .{ .value = v };
        }

        pub fn isUnchanged(self: @This()) bool {
            return self == .unchanged;
        }

        pub fn isNull(self: @This()) bool {
            return self == .null;
        }

        pub fn hasValue(self: @This()) bool {
            return self == .value;
        }

        pub fn getValue(self: @This()) ?T {
            return switch (self) {
                .value => |v| v,
                .unchanged, .null => null,
            };
        }

        /// Applies this patch to an optional target field `target: *?T`:
        /// - `.unchanged` leaves `target.*` unmodified.
        /// - `.null` sets `target.* = null`.
        /// - `.value` sets `target.* = v`.
        pub fn apply(self: @This(), target: *?T) void {
            switch (self) {
                .unchanged => {},
                .null => target.* = null,
                .value => |v| target.* = v,
            }
        }

        /// Applies this patch to a non-optional target field `target: *T`:
        /// - `.unchanged` leaves `target.*` unmodified.
        /// - `.null` returns `error.NullNotAllowed`.
        /// - `.value` sets `target.* = v`.
        pub fn applyNonNull(self: @This(), target: *T) error{NullNotAllowed}!void {
            switch (self) {
                .unchanged => {},
                .null => return error.NullNotAllowed,
                .value => |v| target.* = v,
            }
        }
    };
}

/// Returns `true` if `T` is an instantiation of `Patch(...)`.
pub fn isPatchType(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and
        @hasDecl(T, "zts_rpc_type") and
        @TypeOf(T.zts_rpc_type) == @TypeOf(.patch) and
        T.zts_rpc_type == .patch;
}

/// Wire representation mode for `union(enum)` (`docs/architecture/web-zig-boundary.md` #3).
pub const UnionStyle = enum {
    /// Internally tagged object (default):
    /// - `void` payload: `{"kind":"point"}`
    /// - `struct` payload: `{"kind":"circle","r":10}`
    /// - scalar/slice payload: `{"kind":"text","value":"hello"}`
    internal,

    /// Adjacently tagged object:
    /// - `void` payload: `{"kind":"point"}`
    /// - non-`void` payload: `{"kind":"circle","value":{"r":10}}`
    adjacent,

    /// Externally tagged value:
    /// - `void` payload: `"point"` (also accepts `{"point":{}}` or `{"point":null}` when decoding)
    /// - non-`void` payload: `{"circle":{"r":10}}`
    external,

    /// Untagged union (e.g. `number | string` for CSS values):
    /// - Encodes payload directly (`100` or `"100px"`).
    /// - Decodes by matching JSON token type / trying variants in declaration order.
    untagged,
};

/// Configuration for `union(enum)` JSON representation.
/// Can be declared on a union type as `pub const json_union: UnionConfig = .{ ... };`
/// (or `pub const json_union = UnionStyle.untagged;`).
pub const UnionConfig = struct {
    /// How the tag and payload are laid out in JSON.
    style: UnionStyle = .internal,
    /// Key that carries the variant name.
    tag_field: []const u8 = "kind",
    /// Key that carries the payload for `.internal` scalar and `.adjacent` variants.
    content_field: []const u8 = "value",
};

/// Wraps a `union(enum)` type `U` with an explicit `UnionConfig` without modifying `U` itself.
pub fn TaggedUnion(comptime U: type, comptime config: UnionConfig) type {
    if (@typeInfo(U) != .@"union" or @typeInfo(U).@"union".tag_type == null) {
        @compileError("TaggedUnion(U, config) requires a tagged union(enum), got '" ++ @typeName(U) ++ "'");
    }

    return struct {
        value: U,

        pub const InnerUnion = U;
        pub const union_config = config;
        pub const zts_rpc_type = .tagged_union;

        pub fn init(v: U) @This() {
            return .{ .value = v };
        }

        pub fn get(self: @This()) U {
            return self.value;
        }
    };
}

/// Resolves the `UnionConfig` for a tagged union type `U`, falling back to `default_style`
/// when `U` does not declare `pub const json_union` or `pub const zts_union`.
pub fn resolveUnionConfig(comptime U: type, default_style: UnionStyle) UnionConfig {
    if (@hasDecl(U, "json_union")) {
        const DeclType = @TypeOf(U.json_union);
        if (DeclType == UnionConfig) return U.json_union;
        if (DeclType == UnionStyle or @typeInfo(DeclType) == .enum_literal) {
            return .{ .style = U.json_union };
        }
    }
    if (@hasDecl(U, "zts_union")) {
        const DeclType = @TypeOf(U.zts_union);
        if (DeclType == UnionConfig) return U.zts_union;
        if (DeclType == UnionStyle or @typeInfo(DeclType) == .enum_literal) {
            return .{ .style = U.zts_union };
        }
    }
    return .{ .style = default_style };
}

/// Returns `true` if `T` is an instantiation of `TaggedUnion(...)`.
pub fn isTaggedUnionWrapper(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "zts_rpc_type") and
        @TypeOf(T.zts_rpc_type) == @TypeOf(.tagged_union) and
        T.zts_rpc_type == .tagged_union;
}

/// Canonical 53-bit generational resource handle re-exported directly from `zts_core.Handle`.
///
/// Using a single nominal type definition ensures `core.WindowId` (`core.Handle(.window)`) and
/// `rpc.types.Handle(.window)` are 100% identical Zig types with zero conversion boilerplate.
pub const Handle = core.Handle;

/// Returns `true` if `T` is a 53-bit generational handle type (either `rpc.types.Handle(Tag)`
/// or `core.HandlePool(T, Tag).Handle` implementing `toU53`/`fromU53` or `zts_handle_tag`).
pub fn isHandleType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (@hasDecl(T, "zts_handle_tag")) return true;
    if (@hasDecl(T, "zts_rpc_type") and @TypeOf(T.zts_rpc_type) == @TypeOf(.handle) and T.zts_rpc_type == .handle) {
        return true;
    }
    if (@hasDecl(T, "toU53") and @hasDecl(T, "fromU53")) {
        return true;
    }
    if (info.@"struct".layout == .@"packed" and info.@"struct".backing_integer == u53) {
        return @hasField(T, "index") and @hasField(T, "generation");
    }
    return false;
}

/// Returns the tag name of a `Handle` type `T` at `comptime` (for `tsgen` branded type generation).
pub fn handleTagName(comptime T: type) []const u8 {
    if (!isHandleType(T)) {
        @compileError("handleTagName requires a Handle type, got '" ++ @typeName(T) ++ "'");
    }
    if (@hasDecl(T, "zts_handle_tag")) {
        const TagType = @TypeOf(T.zts_handle_tag);
        if (TagType == @TypeOf(.enum_literal) or @typeInfo(TagType) == .@"enum") {
            return @tagName(T.zts_handle_tag);
        }
        if (TagType == []const u8) {
            return T.zts_handle_tag;
        }
    }
    if (@hasDecl(T, "handle_tag")) {
        const TagType = @TypeOf(T.handle_tag);
        if (TagType == @TypeOf(.enum_literal) or @typeInfo(TagType) == .@"enum") {
            return @tagName(T.handle_tag);
        }
        if (TagType == []const u8) {
            return T.handle_tag;
        }
    }
    return @typeName(T);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "BigInt wraps 64-bit and 128-bit integers and validates decimal strings" {
    const I64Big = BigInt(i64);
    const U64Big = BigInt(u64);
    const I128Big = BigInt(i128);

    const a = try I64Big.parseDecimalSlice("-9007199254740993");
    try testing.expectEqual(@as(i64, -9007199254740993), a.get());

    const b = try U64Big.parseDecimalSlice("18446744073709551615");
    try testing.expectEqual(std.math.maxInt(u64), b.get());

    const c = try I128Big.parseDecimalSlice("-170141183460469231731687303715884105728");
    try testing.expectEqual(std.math.minInt(i128), c.get());

    // Reject non-canonical or overflowing strings
    try testing.expectError(error.InvalidNumber, I64Big.parseDecimalSlice(""));
    try testing.expectError(error.InvalidNumber, I64Big.parseDecimalSlice("-"));
    try testing.expectError(error.InvalidNumber, I64Big.parseDecimalSlice("+123"));
    try testing.expectError(error.InvalidNumber, I64Big.parseDecimalSlice("1_000"));
    try testing.expectError(error.InvalidNumber, I64Big.parseDecimalSlice("12.34"));
    try testing.expectError(error.InvalidNumber, U64Big.parseDecimalSlice("-1"));
    try testing.expectError(error.Overflow, U64Big.parseDecimalSlice("18446744073709551616"));
}

test "Bytes Base64 encode and decode roundtrips arbitrary binary data" {
    const raw = [_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF, 'Z', '-', 'T', 's' };
    const b = Bytes.init(&raw);

    const b64 = try b.encodeBase64Alloc(testing.allocator);
    defer testing.allocator.free(b64);

    const decoded = try Bytes.decodeBase64Alloc(testing.allocator, b64);
    defer testing.allocator.free(decoded.data);

    try testing.expect(b.eql(decoded));
    try testing.expectEqualSlices(u8, &raw, decoded.slice());
}

test "OsPath handles valid UTF-8 zero-copy and non-UTF-8 / WTF-8 with U+FFFD display" {
    // Valid UTF-8 path (zero allocation)
    const utf8_p = try OsPath.init(testing.allocator, "/home/user/書類/report.txt");
    defer utf8_p.deinitDisplayIfAllocated(testing.allocator);
    try testing.expect(utf8_p.isLosslessUtf8());
    try testing.expectEqual(utf8_p.raw.ptr, utf8_p.display.ptr);
    try testing.expectEqualStrings("/home/user/書類/report.txt", utf8_p.display);

    // Non-UTF-8 Linux path
    const linux_raw = "/tmp/broken_\xff\xfe_name.bin";
    const linux_p = try OsPath.init(testing.allocator, linux_raw);
    defer linux_p.deinitDisplayIfAllocated(testing.allocator);
    try testing.expect(!linux_p.isLosslessUtf8());
    try testing.expectEqualSlices(u8, linux_raw, linux_p.asSlice());
    try testing.expect(std.unicode.utf8ValidateSlice(linux_p.display));
    try testing.expectEqualStrings("/tmp/broken_" ++ utf8_replacement_char ++ utf8_replacement_char ++ "_name.bin", linux_p.display);

    // Windows WTF-8 path containing a 3-byte lone surrogate (U+D800 -> 0xED 0xA0 0x80)
    var surr_bytes: [3]u8 = undefined;
    wtf8EncodeSurrogate(0xD800, &surr_bytes);
    try testing.expectEqual(@as(?u16, 0xD800), wtf8DecodeSurrogatePrefix(&surr_bytes));

    const win_raw = "C:\\Users\\test_" ++ [3]u8{ 0xED, 0xA0, 0x80 } ++ ".txt";
    const win_p = try OsPath.init(testing.allocator, win_raw);
    defer win_p.deinitDisplayIfAllocated(testing.allocator);
    try testing.expect(!win_p.isLosslessUtf8());
    try testing.expectEqualSlices(u8, win_raw, win_p.asSlice());
    try testing.expect(std.unicode.utf8ValidateSlice(win_p.display));
    // 3-byte WTF-8 surrogate is replaced by a SINGLE U+FFFD replacement character
    try testing.expectEqualStrings("C:\\Users\\test_" ++ utf8_replacement_char ++ ".txt", win_p.display);
}

test "Patch(T) 3-state semantics and apply helpers" {
    const P = Patch([]const u8);
    const p_unchanged: P = .unchanged;
    const p_null: P = .null;
    const p_val: P = P.initValue("updated");

    try testing.expect(p_unchanged.isUnchanged());
    try testing.expect(p_null.isNull());
    try testing.expect(p_val.hasValue());
    try testing.expectEqualStrings("updated", p_val.getValue().?);

    var target_opt: ?[]const u8 = "initial";
    p_unchanged.apply(&target_opt);
    try testing.expectEqualStrings("initial", target_opt.?);
    p_val.apply(&target_opt);
    try testing.expectEqualStrings("updated", target_opt.?);
    p_null.apply(&target_opt);
    try testing.expect(target_opt == null);

    var target_req: []const u8 = "initial";
    try p_unchanged.applyNonNull(&target_req);
    try testing.expectEqualStrings("initial", target_req);
    try p_val.applyNonNull(&target_req);
    try testing.expectEqualStrings("updated", target_req);
    try testing.expectError(error.NullNotAllowed, p_null.applyNonNull(&target_req));
}

test "Handle(Tag) packs index and generation into 53-bit integer" {
    const WindowHandle = Handle(.window);
    try testing.expect(isHandleType(WindowHandle));
    try testing.expectEqualStrings("window", comptime handleTagName(WindowHandle));

    const h = WindowHandle{
        .index = 0xFFFFFE,
        .generation = 0x1FFFFFFF,
    };
    const raw = h.toU53();
    try testing.expectEqual(max_safe_uint - 1, raw);

    const restored = try WindowHandle.fromU53(raw);
    try testing.expect(h.eql(restored));
    try testing.expectEqual(@as(u24, 0xFFFFFE), restored.index);
    try testing.expectEqual(@as(u29, 0x1FFFFFFF), restored.generation);

    // Generation 0 and index 0xFFFFFF (FREE_LIST_END sentinel) are rejected as InvalidHandle
    try testing.expectError(error.InvalidHandle, WindowHandle.fromU53(0));
    const sentinel = WindowHandle{ .index = 0xFFFFFF, .generation = 1 };
    try testing.expectError(error.InvalidHandle, WindowHandle.fromU53(sentinel.toU53()));
}
