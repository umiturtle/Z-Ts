//! Single-source `comptime` JSON encoder and decoder for the `zts_rpc` Web ⇔ Zig boundary.
//!
//! Key guarantees (`docs/roadmap/m1-foundation-packages.md` & `docs/architecture/web-zig-boundary.md`):
//! 1. **Compile-time 53-bit integer guard**: Raw `i64`/`u64`/`i128`/`u128`/`usize`/`isize` trigger
//!    `@compileError` directing developers to `i53`/`u53` or `types.BigInt(T)`.
//! 2. **Zero-copy string decoding (`.alloc_if_needed`)**: Unescaped JSON strings borrow directly
//!    from the input slice with 0 bytes allocated on the heap.
//! 3. **Strict `isFinite` float validation**: `NaN` and `±Infinity` (including float overflow like `1e500`)
//!    are rejected on both encode and decode with `error.NonFiniteFloat`.
//! 4. **Automatic `snake_case` ⇔ `camelCase` field mapping**: Preserves hyphenated identifiers
//!    (`@"aria-label"`, `@"data-id"`, `@"--bg"`) verbatim.
//! 5. **`Patch(T)` 3-state semantics**: Distinguishes omitted (`unchanged`), `null`, and `value: T`.
//! 6. **4 `union(enum)` representation modes**: `.internal` (default `{ "kind": "tag", ... }`),
//!    `.adjacent` (`{ "kind": "tag", "value": ... }`), `.external` (`{ "tag": ... }`), and `.untagged`.
//! 7. **Web boundary wrapper types**: `BigInt(T)`, `Bytes`, `OsPath` (lossless non-UTF-8 / WTF-8
//!    roundtrip), and 53-bit generational `Handle`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const naming = @import("naming.zig");
pub const types = @import("types.zig");

/// Policy for handling unpaired UTF-16 surrogates (`\uD800`..`\uDFFF`) in JSON strings.
pub const SurrogatePolicy = enum {
    /// Reject unpaired surrogates in `[]const u8` strings with `error.LoneSurrogate` (default).
    reject,
    /// Replace unpaired surrogates with `U+FFFD` (`\xEF\xBF\xBD`, ``), matching JS `toWellFormed()`.
    replace_with_fffd,
};

/// Wire encoding format for `types.Bytes`.
pub const BytesFormat = enum {
    /// Encode `Bytes` as a standard Base64 JSON string `"SGVsbG8="`.
    base64,
    /// Encode `Bytes` as a JSON array of byte integers `[72,101,108,108,111]`.
    array,
};

/// Options controlling JSON serialization.
pub const EncodeOptions = struct {
    /// Default representation for `union(enum)` types that do not declare `json_union`.
    union_style: types.UnionStyle = .internal,
    /// Wire format for `types.Bytes`.
    bytes_format: BytesFormat = .base64,
    /// Whether optional struct fields `?T` that have a default value should be emitted when `null`.
    /// Required `?T` fields (without a default value) are always emitted, and `Patch(T).unchanged` is always omitted.
    emit_null_optional_fields: bool = true,
    /// Escape `<`, `>`, `&`, U+2028, and U+2029 as `\uXXXX` so output is safe inside HTML `<script>`.
    html_safe: bool = false,
};

/// Options controlling JSON deserialization.
pub const DecodeOptions = struct {
    /// Memory allocation strategy for decoded `[]const u8` strings.
    /// `.alloc_if_needed` (default) borrows unescaped strings directly from the input slice (zero-copy).
    allocate: std.json.AllocWhen = .alloc_if_needed,
    /// Ignore unknown keys in JSON objects instead of returning `error.UnknownField`.
    ignore_unknown_fields: bool = false,
    /// Behavior when a duplicate key is encountered in a JSON object.
    duplicate_field_behavior: enum {
        @"error",
        use_first,
        use_last,
    } = .@"error",
    /// Accept `snake_case` field names in addition to `camelCase` when decoding structs.
    allow_snake_case_fields: bool = false,
    /// Policy for unpaired UTF-16 surrogates (`\uD800`..`\uDFFF`) in `[]const u8` strings.
    surrogate_policy: SurrogatePolicy = .reject,
    /// Default representation for `union(enum)` types that do not declare `json_union`.
    union_style: types.UnionStyle = .internal,
    /// Maximum nesting depth of JSON containers (`{}` / `[]`).
    max_depth: usize = 128,
};

pub const EncodeError = std.Io.Writer.Error || Allocator.Error || error{
    /// A floating-point value (`f16`, `f32`, `f64`, `f128`) was `NaN` or `±Infinity`.
    NonFiniteFloat,
    /// A `[]const u8` string contained invalid UTF-8 bytes (use `types.Bytes` or `types.OsPath` instead).
    InvalidUtf8,
};

pub const DecodeError = Allocator.Error || error{
    SyntaxError,
    UnexpectedEndOfInput,
    UnexpectedToken,
    InvalidNumber,
    Overflow,
    NonFiniteFloat,
    InvalidUtf8,
    LoneSurrogate,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    InvalidBase64,
    MaxDepthExceeded,
};

/// Holds a decoded value of type `T` along with the `ArenaAllocator` owning any allocations made during decoding.
/// When decoding only borrows zero-copy slices (`allocate = .alloc_if_needed`), the arena performs 0 heap allocations.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            self.arena.deinit();
        }
    };
}

// ============================================================================
// Compile-time Type Validation (53-bit Safe Integer & Union Tag Collision Guard)
// ============================================================================

/// Inspects `T` at `comptime` and returns a descriptive error message if `T` (or any nested field/element)
/// violates Web ⇔ Zig RPC boundary rules; returns `null` if `T` is valid.
pub fn checkRpcType(comptime T: type) ?[]const u8 {
    return checkRpcTypeInner(T);
}

fn checkRpcTypeInner(comptime T: type) ?[]const u8 {
    if (T == usize or T == isize) {
        return "zts_rpc: Raw '" ++ @typeName(T) ++ "' is forbidden at the Web/JSON boundary because it is platform-dependent and exceeds IEEE 754 53-bit safe integer precision on 64-bit targets. Use 'u53' / 'i53' for JS 'number', or 'zts_rpc.types.BigInt(" ++ @typeName(T) ++ ")' for JS 'bigint'.";
    }

    switch (@typeInfo(T)) {
        .bool, .void, .null, .@"enum", .enum_literal, .error_set, .float, .comptime_float, .comptime_int => return null,
        .int => |info| {
            if (info.bits > 53) {
                return "zts_rpc: Raw integer type '" ++ @typeName(T) ++ "' (> 53 bits) is forbidden at the Web/JSON boundary because JavaScript IEEE 754 numbers silently lose precision above 2^53 - 1. Use 'i53' / 'u53' for JS 'number', or 'zts_rpc.types.BigInt(" ++ @typeName(T) ++ ")' for string-encoded JS 'bigint'.";
            }
            return null;
        },
        .optional => |opt| return checkRpcTypeInner(opt.child),
        .array => |arr| return checkRpcTypeInner(arr.child),
        .vector => |vec| return checkRpcTypeInner(vec.child),
        .pointer => |ptr| switch (ptr.size) {
            .one => return checkRpcTypeInner(ptr.child),
            .slice => return checkRpcTypeInner(ptr.child),
            else => return "zts_rpc: Unsupported pointer type '" ++ @typeName(T) ++ "'",
        },
        .@"struct" => |s| {
            if (comptime (types.isBigIntType(T) or T == types.Bytes or T == types.OsPath or types.isHandleType(T))) {
                return null;
            }
            if (comptime types.isTaggedUnionWrapper(T)) {
                return checkUnionType(T.InnerUnion, T.union_config);
            }
            inline for (s.field_types) |FieldType| {
                if (checkRpcTypeInner(FieldType)) |err_msg| return err_msg;
            }
            return null;
        },
        .@"union" => |u| {
            if (comptime types.isPatchType(T)) {
                return checkRpcTypeInner(T.Child);
            }
            if (u.tag_type == null) {
                return "zts_rpc: Bare untagged union '" ++ @typeName(T) ++ "' cannot be serialized; use 'union(enum)' (with 'pub const json_union = .untagged' if untagged wire format is desired).";
            }
            const cfg = comptime types.resolveUnionConfig(T, .internal);
            return checkUnionType(T, cfg);
        },
        else => return "zts_rpc: Unsupported type '" ++ @typeName(T) ++ "' at RPC boundary.",
    }
}

fn checkUnionType(comptime U: type, comptime cfg: types.UnionConfig) ?[]const u8 {
    const u = @typeInfo(U).@"union";
    inline for (u.field_names, u.field_types) |variant_name, PayloadType| {
        if (checkRpcTypeInner(PayloadType)) |err_msg| return err_msg;
        if (cfg.style == .internal and @typeInfo(PayloadType) == .@"struct" and !@typeInfo(PayloadType).@"struct".is_tuple) {
            if (!types.isBigIntType(PayloadType) and PayloadType != types.Bytes and PayloadType != types.OsPath and !types.isHandleType(PayloadType) and !types.isTaggedUnionWrapper(PayloadType)) {
                const s = @typeInfo(PayloadType).@"struct";
                inline for (s.field_names) |f_name| {
                    const wire_name = comptime naming.snakeToCamel(f_name);
                    if (comptime std.mem.eql(u8, wire_name, cfg.tag_field)) {
                        return "zts_rpc: Internally tagged union '" ++ @typeName(U) ++ "' variant '" ++ variant_name ++ "' has a field '" ++ f_name ++ "' that collides with union tag_field '" ++ cfg.tag_field ++ "'.";
                    }
                }
            }
        }
    }
    return null;
}

/// Returns `true` if `T` is a valid RPC boundary type.
pub fn isValidRpcType(comptime T: type) bool {
    return checkRpcType(T) == null;
}

/// Triggers `@compileError` with a detailed message if `T` violates Web ⇔ Zig RPC boundary rules.
pub fn assertValidRpcType(comptime T: type) void {
    if (comptime checkRpcType(T)) |err_msg| {
        @compileError(err_msg);
    }
}

// ============================================================================
// Public Encode API
// ============================================================================

/// Encodes `value` as minified JSON to `writer` using default `EncodeOptions`.
pub fn encode(writer: *std.Io.Writer, value: anytype) EncodeError!void {
    return encodeWithOptions(writer, value, .{});
}

/// Encodes `value` as JSON to `writer` using the given `options`.
pub fn encodeWithOptions(writer: *std.Io.Writer, value: anytype, options: EncodeOptions) EncodeError!void {
    const T = @TypeOf(value);
    comptime assertValidRpcType(T);
    try encodeValue(writer, value, options);
}

/// Encodes `value` into a newly allocated JSON byte slice using default `EncodeOptions`.
/// Caller owns the returned slice and must free it with `allocator.free`.
pub fn encodeAlloc(allocator: Allocator, value: anytype) EncodeError![]u8 {
    return encodeAllocWithOptions(allocator, value, .{});
}

/// Encodes `value` into a newly allocated JSON byte slice using the given `options`.
/// Caller owns the returned slice and must free it with `allocator.free`.
pub fn encodeAllocWithOptions(allocator: Allocator, value: anytype, options: EncodeOptions) EncodeError![]u8 {
    const T = @TypeOf(value);
    comptime assertValidRpcType(T);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    encodeValue(&aw.writer, value, options) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return aw.toOwnedSlice();
}

// ============================================================================
// Public Decode API
// ============================================================================

/// Decodes a JSON slice `input` into `Parsed(T)` using default `DecodeOptions`.
/// Call `.deinit()` on the returned `Parsed(T)` when done.
pub fn decode(comptime T: type, allocator: Allocator, input: []const u8) DecodeError!Parsed(T) {
    return decodeWithOptions(T, allocator, input, .{});
}

/// Decodes a JSON slice `input` into `Parsed(T)` using the given `options`.
/// Call `.deinit()` on the returned `Parsed(T)` when done.
pub fn decodeWithOptions(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    options: DecodeOptions,
) DecodeError!Parsed(T) {
    comptime assertValidRpcType(T);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const val = try decodeLeakyWithOptions(T, arena.allocator(), input, options);
    return .{
        .arena = arena,
        .value = val,
    };
}

/// Decodes a JSON slice `input` directly using `allocator` (intended for reusable `ArenaAllocator`
/// such as `rpc.Ctx.scratch` or zero-allocation decoding of unescaped inputs).
pub fn decodeLeaky(comptime T: type, allocator: Allocator, input: []const u8) DecodeError!T {
    return decodeLeakyWithOptions(T, allocator, input, .{});
}

/// Decodes a JSON slice `input` directly using `allocator` and `options`.
pub fn decodeLeakyWithOptions(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    options: DecodeOptions,
) DecodeError!T {
    comptime assertValidRpcType(T);

    var cursor = Cursor{
        .input = input,
        .pos = 0,
        .depth = 0,
    };
    const result = try decodeValue(T, allocator, &cursor, options);
    errdefer freeDecoded(T, allocator, result, input);
    cursor.skipWhitespace();
    if (cursor.pos != cursor.input.len) {
        return error.SyntaxError;
    }
    return result;
}

/// Frees any heap allocations inside `value` that were created by `decodeLeaky` / `decodeLeakyWithOptions`
/// and do not point inside the original `input` JSON buffer.
pub fn freeDecoded(comptime T: type, allocator: Allocator, value: T, input: []const u8) void {
    switch (@typeInfo(T)) {
        .bool, .null, .void, .int, .comptime_int, .float, .comptime_float, .@"enum", .enum_literal, .error_set => {},
        .optional => |opt| {
            if (value) |payload| freeDecoded(opt.child, allocator, payload, input);
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                freeDecoded(ptr.child, allocator, value.*, input);
                allocator.destroy(value);
            },
            .slice => {
                if (ptr.child == u8) {
                    if (ptr.sentinel()) |s| {
                        const slice_z: [:s]const u8 = value;
                        allocator.free(slice_z);
                    } else if (!isSliceInsideInput(value, input)) {
                        allocator.free(value);
                    }
                } else {
                    for (value) |elem| {
                        freeDecoded(ptr.child, allocator, elem, input);
                    }
                    if (ptr.sentinel()) |s| {
                        const slice_z: [:s]const ptr.child = value;
                        allocator.free(slice_z);
                    } else if (value.len > 0) {
                        allocator.free(value);
                    }
                }
            },
            else => {},
        },
        .array => |arr| {
            for (value) |elem| {
                freeDecoded(arr.child, allocator, elem, input);
            }
        },
        .vector => {},
        .@"struct" => |s| {
            if (comptime (types.isBigIntType(T) or types.isHandleType(T))) return;
            if (T == types.Bytes) {
                if (!isSliceInsideInput(value.data, input)) {
                    allocator.free(value.data);
                }
                return;
            }
            if (T == types.OsPath) {
                if (value.display.ptr != value.raw.ptr and !isSliceInsideInput(value.display, input)) {
                    allocator.free(value.display);
                }
                if (!isSliceInsideInput(value.raw, input)) {
                    allocator.free(value.raw);
                }
                return;
            }
            if (comptime types.isTaggedUnionWrapper(T)) {
                freeDecoded(T.InnerUnion, allocator, value.value, input);
                return;
            }
            inline for (s.field_names, s.field_types) |f_name, FType| {
                freeDecoded(FType, allocator, @field(value, f_name), input);
            }
        },
        .@"union" => |u| {
            if (comptime types.isPatchType(T)) {
                switch (value) {
                    .unchanged, .null => {},
                    .value => |v| freeDecoded(T.Child, allocator, v, input),
                }
                return;
            }
            if (u.tag_type) |TagType| {
                const active: TagType = value;
                inline for (u.field_names, u.field_types) |v_name, PayloadType| {
                    if (active == @field(TagType, v_name)) {
                        freeDecoded(PayloadType, allocator, @field(value, v_name), input);
                        return;
                    }
                }
            }
        },
        else => {},
    }
}

fn isSliceInsideInput(slice: []const u8, input: []const u8) bool {
    if (slice.len == 0) return true;
    if (input.len == 0) return false;
    const s_addr = @intFromPtr(slice.ptr);
    const in_start = @intFromPtr(input.ptr);
    const in_end = in_start + input.len;
    return s_addr >= in_start and s_addr < in_end;
}

// ============================================================================
// Internal JSON Encoder Implementation
// ============================================================================

fn isStringSliceType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| arr.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn encodeValue(writer: *std.Io.Writer, value: anytype, options: EncodeOptions) EncodeError!void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .bool => {
            try writer.writeAll(if (value) "true" else "false");
        },
        .null, .void => {
            try writer.writeAll("null");
        },
        .int => {
            try writer.print("{d}", .{value});
        },
        .comptime_int => {
            if (value < types.min_safe_int or value > types.max_safe_int) {
                @compileError("zts_rpc: comptime_int value exceeds IEEE 754 53-bit safe integer range");
            }
            try writer.print("{d}", .{@as(i64, value)});
        },
        .float, .comptime_float => {
            const f: f64 = @floatCast(value);
            if (!std.math.isFinite(f)) return error.NonFiniteFloat;
            const normalized: f64 = if (f == 0.0) 0.0 else f;
            try writer.print("{d}", .{normalized});
        },
        .optional => {
            if (value) |payload| {
                try encodeValue(writer, payload, options);
            } else {
                try writer.writeAll("null");
            }
        },
        .@"enum" => |enum_info| {
            if (enum_info.mode == .nonexhaustive) {
                inline for (enum_info.field_names) |f_name| {
                    if (value == @field(T, f_name)) {
                        try writeJsonString(writer, f_name, options.html_safe);
                        return;
                    }
                }
                return error.InvalidUtf8;
            }
            try writeJsonString(writer, @tagName(value), options.html_safe);
        },
        .enum_literal => {
            try writeJsonString(writer, @tagName(value), options.html_safe);
        },
        .error_set => {
            try writeJsonString(writer, @errorName(value), options.html_safe);
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => switch (@typeInfo(ptr_info.child)) {
                .array => |arr_info| {
                    if (arr_info.child == u8) {
                        const slice: []const u8 = value[0..];
                        if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
                        try writeJsonString(writer, slice, options.html_safe);
                    } else {
                        try encodeSlice(writer, value[0..], options);
                    }
                },
                else => try encodeValue(writer, value.*, options),
            },
            .slice => {
                if (ptr_info.child == u8) {
                    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
                    try writeJsonString(writer, value, options.html_safe);
                } else {
                    try encodeSlice(writer, value, options);
                }
            },
            else => unreachable,
        },
        .array => {
            try encodeSlice(writer, &value, options);
        },
        .vector => |vec_info| {
            const arr: [vec_info.len]vec_info.child = value;
            try encodeSlice(writer, &arr, options);
        },
        .@"struct" => |s_info| {
            // 1. Check special Z-Ts wrapper structs first
            if (comptime types.isBigIntType(T)) {
                try value.writeJson(writer);
                return;
            }
            if (T == types.Bytes) {
                switch (options.bytes_format) {
                    .base64 => {
                        try writer.writeByte('"');
                        try value.writeBase64(writer);
                        try writer.writeByte('"');
                    },
                    .array => {
                        try writer.writeByte('[');
                        for (value.data, 0..) |b, i| {
                            if (i > 0) try writer.writeByte(',');
                            try writer.print("{d}", .{b});
                        }
                        try writer.writeByte(']');
                    },
                }
                return;
            }
            if (T == types.OsPath) {
                try encodeOsPath(writer, value, options);
                return;
            }
            if (comptime types.isHandleType(T)) {
                const raw_u53: u53 = if (@hasDecl(T, "toU53")) value.toU53() else @bitCast(value);
                try writer.print("{d}", .{raw_u53});
                return;
            }
            if (comptime types.isTaggedUnionWrapper(T)) {
                try encodeUnionWithConfig(T.InnerUnion, writer, value.value, T.union_config, options);
                return;
            }
            if (comptime std.meta.hasFn(T, "jsonStringify")) {
                var jw: std.json.Stringify = .{ .writer = writer, .options = .{} };
                try value.jsonStringify(&jw);
                return;
            }

            // 2. Tuple -> JSON Array
            if (s_info.is_tuple) {
                try writer.writeByte('[');
                inline for (s_info.field_names, 0..) |f_name, i| {
                    if (i > 0) try writer.writeByte(',');
                    try encodeValue(writer, @field(value, f_name), options);
                }
                try writer.writeByte(']');
                return;
            }

            // 3. Regular struct -> JSON Object with camelCase keys (preserving hyphenated keys)
            try writer.writeByte('{');
            var first = true;
            try encodeStructFields(T, writer, value, &first, options);
            try writer.writeByte('}');
        },
        .@"union" => {
            if (comptime types.isPatchType(T)) {
                switch (value) {
                    .unchanged, .null => try writer.writeAll("null"),
                    .value => |v| try encodeValue(writer, v, options),
                }
                return;
            }
            const cfg = comptime types.resolveUnionConfig(T, .internal);
            const effective_cfg: types.UnionConfig = if (@hasDecl(T, "json_union") or @hasDecl(T, "zts_union"))
                cfg
            else
                .{ .style = options.union_style, .tag_field = cfg.tag_field, .content_field = cfg.content_field };
            try encodeUnionWithConfig(T, writer, value, effective_cfg, options);
        },
        else => unreachable,
    }
}

fn encodeSlice(writer: *std.Io.Writer, slice: anytype, options: EncodeOptions) EncodeError!void {
    try writer.writeByte('[');
    for (slice, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try encodeValue(writer, item, options);
    }
    try writer.writeByte(']');
}

fn encodeStructFields(
    comptime S: type,
    writer: *std.Io.Writer,
    value: S,
    first: *bool,
    options: EncodeOptions,
) EncodeError!void {
    const s_info = @typeInfo(S).@"struct";
    inline for (s_info.field_names, s_info.field_types, s_info.field_attrs) |f_name, FType, f_attrs| {
        if (FType == void) continue;

        const wire_key = comptime naming.snakeToCamel(f_name);
        const field_val = @field(value, f_name);

        if (comptime types.isPatchType(FType)) {
            switch (field_val) {
                .unchanged => {},
                .null => {
                    if (!first.*) try writer.writeByte(',');
                    first.* = false;
                    try writeJsonString(writer, wire_key, options.html_safe);
                    try writer.writeAll(":null");
                },
                .value => |v| {
                    if (!first.*) try writer.writeByte(',');
                    first.* = false;
                    try writeJsonString(writer, wire_key, options.html_safe);
                    try writer.writeByte(':');
                    try encodeValue(writer, v, options);
                },
            }
        } else if (@typeInfo(FType) == .optional) {
            const has_default = f_attrs.defaultValue(FType) != null;
            if (field_val == null and has_default and !options.emit_null_optional_fields) {
                // Omit optional field with default when emit_null_optional_fields is false
            } else {
                if (!first.*) try writer.writeByte(',');
                first.* = false;
                try writeJsonString(writer, wire_key, options.html_safe);
                try writer.writeByte(':');
                try encodeValue(writer, field_val, options);
            }
        } else {
            if (!first.*) try writer.writeByte(',');
            first.* = false;
            try writeJsonString(writer, wire_key, options.html_safe);
            try writer.writeByte(':');
            try encodeValue(writer, field_val, options);
        }
    }
}

fn isFlattenableStruct(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (info.@"struct".is_tuple) return false;
    if (types.isBigIntType(T) or T == types.Bytes or T == types.OsPath or types.isHandleType(T) or types.isTaggedUnionWrapper(T)) {
        return false;
    }
    return true;
}

fn encodeUnionWithConfig(
    comptime U: type,
    writer: *std.Io.Writer,
    value: U,
    cfg: types.UnionConfig,
    options: EncodeOptions,
) EncodeError!void {
    const u_info = @typeInfo(U).@"union";
    const TagType = u_info.tag_type.?;
    const active_tag: TagType = value;

    inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
        if (active_tag == @field(TagType, v_name)) {
            const payload = @field(value, v_name);
            switch (cfg.style) {
                .internal => {
                    try writer.writeByte('{');
                    try writeJsonString(writer, cfg.tag_field, options.html_safe);
                    try writer.writeByte(':');
                    try writeJsonString(writer, v_name, options.html_safe);

                    if (PayloadType == void) {
                        // Nothing else to write
                    } else if (comptime isFlattenableStruct(PayloadType)) {
                        var first = false;
                        try encodeStructFields(PayloadType, writer, payload, &first, options);
                    } else {
                        try writer.writeByte(',');
                        try writeJsonString(writer, cfg.content_field, options.html_safe);
                        try writer.writeByte(':');
                        try encodeValue(writer, payload, options);
                    }
                    try writer.writeByte('}');
                },
                .adjacent => {
                    try writer.writeByte('{');
                    try writeJsonString(writer, cfg.tag_field, options.html_safe);
                    try writer.writeByte(':');
                    try writeJsonString(writer, v_name, options.html_safe);
                    if (PayloadType != void) {
                        try writer.writeByte(',');
                        try writeJsonString(writer, cfg.content_field, options.html_safe);
                        try writer.writeByte(':');
                        try encodeValue(writer, payload, options);
                    }
                    try writer.writeByte('}');
                },
                .external => {
                    if (PayloadType == void) {
                        try writeJsonString(writer, v_name, options.html_safe);
                    } else {
                        try writer.writeByte('{');
                        try writeJsonString(writer, v_name, options.html_safe);
                        try writer.writeByte(':');
                        try encodeValue(writer, payload, options);
                        try writer.writeByte('}');
                    }
                },
                .untagged => {
                    if (PayloadType == void) {
                        try writer.writeAll("null");
                    } else {
                        try encodeValue(writer, payload, options);
                    }
                },
            }
            return;
        }
    }
}

fn encodeOsPath(writer: *std.Io.Writer, path: types.OsPath, options: EncodeOptions) EncodeError!void {
    if (path.isLosslessUtf8()) {
        try writeJsonString(writer, path.raw, options.html_safe);
        return;
    }

    // Non-UTF-8 or WTF-8 path: emit {"display":"<lossy_utf8>","rawToken":"<base64>"}
    try writer.writeAll("{\"display\":");
    if (path.display.len > 0 and std.unicode.utf8ValidateSlice(path.display)) {
        try writeJsonString(writer, path.display, options.html_safe);
    } else {
        try writeLossyUtf8JsonString(writer, path.raw, options.html_safe);
    }
    try writer.writeAll(",\"rawToken\":\"");
    try std.base64.standard.Encoder.encodeWriter(writer, path.raw);
    try writer.writeAll("\"}");
}

fn writeLossyUtf8JsonString(writer: *std.Io.Writer, raw_bytes: []const u8, html_safe: bool) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < raw_bytes.len) {
        const b0 = raw_bytes[i];
        if (b0 < 0x80) {
            try writeJsonChar(writer, b0, html_safe);
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch {
            try writer.writeAll(types.utf8_replacement_char);
            i += 1;
            continue;
        };
        if (i + seq_len <= raw_bytes.len) {
            if (std.unicode.utf8Decode(raw_bytes[i .. i + seq_len])) |cp| {
                if (html_safe and (cp == 0x2028 or cp == 0x2029)) {
                    try writer.print("\\u{x:0>4}", .{@as(u16, @intCast(cp))});
                } else {
                    try writer.writeAll(raw_bytes[i .. i + seq_len]);
                }
                i += seq_len;
                continue;
            } else |_| {}
        }
        try writer.writeAll(types.utf8_replacement_char);
        if (types.wtf8DecodeSurrogatePrefix(raw_bytes[i..]) != null) {
            i += 3;
        } else {
            i += 1;
        }
    }
    try writer.writeByte('"');
}

/// Writes a valid UTF-8 `str` as a JSON string literal `"..."`.
pub fn writeJsonString(writer: *std.Io.Writer, str: []const u8, html_safe: bool) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var start: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const c = str[i];
        const needs_escape = switch (c) {
            0x00...0x1F, '"', '\\' => true,
            '<', '>', '&' => html_safe,
            0xE2 => html_safe and i + 2 < str.len and str[i + 1] == 0x80 and (str[i + 2] == 0xA8 or str[i + 2] == 0xA9),
            else => false,
        };
        if (!needs_escape) {
            i += 1;
            continue;
        }
        if (i > start) {
            try writer.writeAll(str[start..i]);
        }
        if (c == 0xE2) {
            // U+2028 (E2 80 A8) or U+2029 (E2 80 A9)
            if (str[i + 2] == 0xA8) {
                try writer.writeAll("\\u2028");
            } else {
                try writer.writeAll("\\u2029");
            }
            i += 3;
            start = i;
            continue;
        }
        try writeJsonChar(writer, c, html_safe);
        i += 1;
        start = i;
    }
    if (i > start) {
        try writer.writeAll(str[start..i]);
    }
    try writer.writeByte('"');
}

fn writeJsonChar(writer: *std.Io.Writer, c: u8, html_safe: bool) std.Io.Writer.Error!void {
    switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        '<' => if (html_safe) try writer.writeAll("\\u003c") else try writer.writeByte('<'),
        '>' => if (html_safe) try writer.writeAll("\\u003e") else try writer.writeByte('>'),
        '&' => if (html_safe) try writer.writeAll("\\u0026") else try writer.writeByte('&'),
        0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    }
}

// ============================================================================
// Internal Zero-Allocation-Capable JSON Cursor & Decoder Implementation
// ============================================================================

const TokenKind = enum {
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

const StringDecodeMode = enum {
    strict_utf8,
    lossy_utf8,
    wtf8,
};

const DecodedString = struct {
    slice: []const u8,
    allocated: bool,
    had_wtf8_surrogate: bool = false,

    fn freeIfAllocated(self: DecodedString, allocator: Allocator) void {
        if (self.allocated and self.slice.len > 0) {
            allocator.free(self.slice);
        }
    }
};

const NumberToken = struct {
    slice: []const u8,
    is_float_syntax: bool,
};

const Cursor = struct {
    input: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    fn skipWhitespace(self: *Cursor) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    fn peekKind(self: *Cursor) DecodeError!TokenKind {
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

    fn enterContainer(self: *Cursor, max_depth: usize) DecodeError!void {
        if (self.depth >= max_depth) return error.MaxDepthExceeded;
        self.depth += 1;
    }

    fn leaveContainer(self: *Cursor) void {
        self.depth -= 1;
    }

    fn readBool(self: *Cursor) DecodeError!bool {
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

    fn readNull(self: *Cursor) DecodeError!void {
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

    fn readNumberToken(self: *Cursor) DecodeError!NumberToken {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;

        const start = self.pos;
        var i = start;

        // Check for explicit NaN / Infinity tokens so we can report NonFiniteFloat or SyntaxError clearly
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

        // Integer part
        if (self.input[i] == '0') {
            i += 1;
            // Leading zero must not be followed by another digit per RFC 8259
            if (i < self.input.len and std.ascii.isDigit(self.input[i])) {
                return error.SyntaxError;
            }
        } else if (std.ascii.isDigit(self.input[i])) {
            while (i < self.input.len and std.ascii.isDigit(self.input[i])) : (i += 1) {}
        } else {
            return error.SyntaxError;
        }

        var is_float_syntax = false;

        // Fractional part
        if (i < self.input.len and self.input[i] == '.') {
            is_float_syntax = true;
            i += 1;
            if (i >= self.input.len or !std.ascii.isDigit(self.input[i])) {
                return error.SyntaxError;
            }
            while (i < self.input.len and std.ascii.isDigit(self.input[i])) : (i += 1) {}
        }

        // Exponent part
        if (i < self.input.len and (self.input[i] == 'e' or self.input[i] == 'E')) {
            is_float_syntax = true;
            i += 1;
            if (i < self.input.len and (self.input[i] == '+' or self.input[i] == '-')) {
                i += 1;
            }
            if (i >= self.input.len or !std.ascii.isDigit(self.input[i])) {
                return error.SyntaxError;
            }
            while (i < self.input.len and std.ascii.isDigit(self.input[i])) : (i += 1) {}
        }

        self.pos = i;
        return .{
            .slice = self.input[start..i],
            .is_float_syntax = is_float_syntax,
        };
    }

    fn readString(
        self: *Cursor,
        allocator: Allocator,
        alloc_when: std.json.AllocWhen,
        mode: StringDecodeMode,
    ) DecodeError!DecodedString {
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

        // Fast scan for closing '"' or first '\\'
        while (i < self.input.len) : (i += 1) {
            const c = self.input[i];
            if (c == '"') {
                const raw = self.input[start..i];
                if (!std.unicode.utf8ValidateSlice(raw)) {
                    return error.InvalidUtf8;
                }
                self.pos = i + 1;
                if (alloc_when == .alloc_if_needed) {
                    return .{ .slice = raw, .allocated = false };
                } else {
                    const duped = try allocator.dupe(u8, raw);
                    return .{ .slice = duped, .allocated = true };
                }
            }
            if (c == '\\') break;
            if (c < 0x20) return error.SyntaxError;
        }

        if (i >= self.input.len) return error.UnexpectedEndOfInput;

        // Validate the unescaped prefix before the first '\\'
        const prefix = self.input[start..i];
        if (!std.unicode.utf8ValidateSlice(prefix)) {
            return error.InvalidUtf8;
        }

        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        if (prefix.len > 0) {
            try list.appendSlice(allocator, prefix);
        }

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

            // Flush valid UTF-8 chunk before '\\'
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
                        // Look ahead for a matching low surrogate \uDC00..\uDFFF
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
                            // Lone high surrogate!
                            switch (mode) {
                                .strict_utf8 => return error.LoneSurrogate,
                                .lossy_utf8 => try list.appendSlice(allocator, types.utf8_replacement_char),
                                .wtf8 => {
                                    var wtf8_buf: [3]u8 = undefined;
                                    types.wtf8EncodeSurrogate(cu1, &wtf8_buf);
                                    try list.appendSlice(allocator, &wtf8_buf);
                                    had_wtf8_surrogate = true;
                                },
                            }
                        }
                    } else if (std.unicode.utf16IsLowSurrogate(cu1)) {
                        // Lone low surrogate!
                        switch (mode) {
                            .strict_utf8 => return error.LoneSurrogate,
                            .lossy_utf8 => try list.appendSlice(allocator, types.utf8_replacement_char),
                            .wtf8 => {
                                var wtf8_buf: [3]u8 = undefined;
                                types.wtf8EncodeSurrogate(cu1, &wtf8_buf);
                                try list.appendSlice(allocator, &wtf8_buf);
                                had_wtf8_surrogate = true;
                            },
                        }
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

    fn skipString(self: *Cursor) DecodeError!void {
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

    fn skipValue(self: *Cursor, max_depth: usize) DecodeError!void {
        switch (try self.peekKind()) {
            .eof => return error.UnexpectedEndOfInput,
            .boolean => _ = try self.readBool(),
            .null => try self.readNull(),
            .number => _ = try self.readNumberToken(),
            .string => try self.skipString(),
            .array_begin => {
                try self.enterContainer(max_depth);
                defer self.leaveContainer();
                self.pos += 1; // '['
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
                self.pos += 1; // '{'
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

fn decodeValue(
    comptime T: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!T {
    switch (@typeInfo(T)) {
        .bool => return cursor.readBool(),
        .null => {
            try cursor.readNull();
            return null;
        },
        .void => {
            try cursor.readNull();
            return {};
        },
        .int => {
            const num = try cursor.readNumberToken();
            if (!num.is_float_syntax) {
                return std.fmt.parseInt(T, num.slice, 10) catch |err| switch (err) {
                    error.Overflow => return error.Overflow,
                    error.InvalidCharacter => return error.InvalidNumber,
                };
            }
            // Float syntax for integer (e.g. 1e3 -> 1000; reject fractional 12.34)
            const f = std.fmt.parseFloat(f64, num.slice) catch return error.InvalidNumber;
            if (!std.math.isFinite(f)) return error.NonFiniteFloat;
            if (@round(f) != f) return error.InvalidNumber;
            if (f > @as(f64, @floatFromInt(std.math.maxInt(T))) or f < @as(f64, @floatFromInt(std.math.minInt(T)))) {
                return error.Overflow;
            }
            return @intFromFloat(f);
        },
        .float => {
            const num = try cursor.readNumberToken();
            const f = std.fmt.parseFloat(T, num.slice) catch return error.InvalidNumber;
            if (!std.math.isFinite(f)) return error.NonFiniteFloat;
            return f;
        },
        .optional => |opt_info| {
            if (try cursor.peekKind() == .null) {
                try cursor.readNull();
                return null;
            }
            return try decodeValue(opt_info.child, allocator, cursor, options);
        },
        .@"enum" => |enum_info| {
            const str_mode: StringDecodeMode = if (options.surrogate_policy == .replace_with_fffd) .lossy_utf8 else .strict_utf8;
            const str_tok = try cursor.readString(allocator, .alloc_if_needed, str_mode);
            defer str_tok.freeIfAllocated(allocator);

            inline for (enum_info.field_names) |f_name| {
                if (std.mem.eql(u8, str_tok.slice, f_name)) {
                    return @field(T, f_name);
                }
            }
            return error.InvalidEnumTag;
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => {
                const ptr = try allocator.create(ptr_info.child);
                errdefer allocator.destroy(ptr);
                ptr.* = try decodeValue(ptr_info.child, allocator, cursor, options);
                return ptr;
            },
            .slice => {
                if (ptr_info.child == u8) {
                    const str_mode: StringDecodeMode = if (options.surrogate_policy == .replace_with_fffd) .lossy_utf8 else .strict_utf8;
                    const alloc_mode: std.json.AllocWhen = if (ptr_info.attrs.@"const" and ptr_info.sentinel() == null)
                        options.allocate
                    else
                        .alloc_always;

                    const decoded = try cursor.readString(allocator, alloc_mode, str_mode);
                    if (ptr_info.sentinel()) |sentinel| {
                        defer decoded.freeIfAllocated(allocator);
                        const buf = try allocator.allocSentinel(u8, decoded.slice.len, sentinel);
                        @memcpy(buf, decoded.slice);
                        return buf;
                    }
                    if (!ptr_info.attrs.@"const") {
                        return @constCast(decoded.slice);
                    }
                    return decoded.slice;
                }
                return decodeSlice(T, ptr_info.child, allocator, cursor, options);
            },
            else => unreachable,
        },
        .array => |arr_info| {
            return decodeFixedArray(T, arr_info.child, arr_info.len, allocator, cursor, options);
        },
        .vector => |vec_info| {
            const Arr = [vec_info.len]vec_info.child;
            const arr = try decodeFixedArray(Arr, vec_info.child, vec_info.len, allocator, cursor, options);
            return arr;
        },
        .@"struct" => |s_info| {
            if (comptime types.isBigIntType(T)) {
                const str_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
                defer str_tok.freeIfAllocated(allocator);
                return T.parseDecimalSlice(str_tok.slice);
            }
            if (T == types.Bytes) {
                return decodeBytes(allocator, cursor, options);
            }
            if (T == types.OsPath) {
                return decodeOsPath(allocator, cursor, options);
            }
            if (comptime types.isHandleType(T)) {
                const raw_u53 = try decodeValue(u53, allocator, cursor, options);
                return if (@hasDecl(T, "fromU53")) T.fromU53(raw_u53) else @bitCast(raw_u53);
            }
            if (comptime types.isTaggedUnionWrapper(T)) {
                const inner = try decodeUnionWithConfig(T.InnerUnion, allocator, cursor, T.union_config, options);
                return T.init(inner);
            }
            if (comptime std.meta.hasFn(T, "jsonParse")) {
                cursor.skipWhitespace();
                const val_start = cursor.pos;
                try cursor.skipValue(options.max_depth);
                const val_slice = cursor.input[val_start..cursor.pos];
                return std.json.parseFromSliceLeaky(T, allocator, val_slice, .{
                    .allocate = options.allocate,
                    .ignore_unknown_fields = options.ignore_unknown_fields,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SyntaxError => return error.SyntaxError,
                    error.UnexpectedEndOfInput => return error.UnexpectedEndOfInput,
                    error.InvalidNumber => return error.InvalidNumber,
                    error.Overflow => return error.Overflow,
                    error.InvalidEnumTag => return error.InvalidEnumTag,
                    error.DuplicateField => return error.DuplicateField,
                    error.UnknownField => return error.UnknownField,
                    error.MissingField => return error.MissingField,
                    error.LengthMismatch => return error.LengthMismatch,
                    else => return error.UnexpectedToken,
                };
            }
            if (s_info.is_tuple) {
                return decodeTuple(T, allocator, cursor, options);
            }
            return decodeStruct(T, allocator, cursor, null, options);
        },
        .@"union" => {
            if (comptime types.isPatchType(T)) {
                if (try cursor.peekKind() == .null) {
                    try cursor.readNull();
                    return .null;
                }
                return .{ .value = try decodeValue(T.Child, allocator, cursor, options) };
            }
            const cfg = comptime types.resolveUnionConfig(T, .internal);
            const effective_cfg: types.UnionConfig = if (@hasDecl(T, "json_union") or @hasDecl(T, "zts_union"))
                cfg
            else
                .{ .style = options.union_style, .tag_field = cfg.tag_field, .content_field = cfg.content_field };
            return decodeUnionWithConfig(T, allocator, cursor, effective_cfg, options);
        },
        else => unreachable,
    }
}

fn decodeSlice(
    comptime SliceType: type,
    comptime Child: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!SliceType {
    if (try cursor.peekKind() != .array_begin) {
        return if (try cursor.peekKind() == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
    }
    try cursor.enterContainer(options.max_depth);
    defer cursor.leaveContainer();
    cursor.pos += 1; // '['

    if (try cursor.peekKind() == .array_end) {
        cursor.pos += 1;
        return &.{};
    }

    var list: std.ArrayList(Child) = .empty;
    errdefer {
        for (list.items) |item| {
            freeDecoded(Child, allocator, item, cursor.input);
        }
        list.deinit(allocator);
    }

    while (true) {
        const item = try decodeValue(Child, allocator, cursor, options);
        list.append(allocator, item) catch |err| {
            freeDecoded(Child, allocator, item, cursor.input);
            return err;
        };

        cursor.skipWhitespace();
        if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
        switch (cursor.input[cursor.pos]) {
            ',' => cursor.pos += 1,
            ']' => {
                cursor.pos += 1;
                break;
            },
            else => return error.SyntaxError,
        }
    }

    const ptr_info = @typeInfo(SliceType).pointer;
    if (ptr_info.sentinel()) |s| {
        return try list.toOwnedSliceSentinel(allocator, s);
    }
    return try list.toOwnedSlice(allocator);
}

fn decodeFixedArray(
    comptime ArrType: type,
    comptime Child: type,
    comptime len: usize,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!ArrType {
    if (try cursor.peekKind() != .array_begin) {
        return if (try cursor.peekKind() == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
    }
    try cursor.enterContainer(options.max_depth);
    defer cursor.leaveContainer();
    cursor.pos += 1; // '['

    var result: ArrType = undefined;
    if (len == 0) {
        if (try cursor.peekKind() != .array_end) return error.LengthMismatch;
        cursor.pos += 1;
        return result;
    }

    if (try cursor.peekKind() == .array_end) return error.LengthMismatch;

    var initialized_count: usize = 0;
    errdefer {
        for (0..initialized_count) |idx| {
            freeDecoded(Child, allocator, result[idx], cursor.input);
        }
    }

    for (0..len) |i| {
        if (i > 0) {
            cursor.skipWhitespace();
            if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
            if (cursor.input[cursor.pos] == ']') return error.LengthMismatch;
            if (cursor.input[cursor.pos] != ',') return error.SyntaxError;
            cursor.pos += 1;
        }
        result[i] = try decodeValue(Child, allocator, cursor, options);
        initialized_count = i + 1;
    }

    cursor.skipWhitespace();
    if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
    if (cursor.input[cursor.pos] == ',') return error.LengthMismatch;
    if (cursor.input[cursor.pos] != ']') return error.SyntaxError;
    cursor.pos += 1;
    return result;
}

fn decodeTuple(
    comptime TupleType: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!TupleType {
    const s_info = @typeInfo(TupleType).@"struct";
    if (try cursor.peekKind() != .array_begin) {
        return if (try cursor.peekKind() == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
    }
    try cursor.enterContainer(options.max_depth);
    defer cursor.leaveContainer();
    cursor.pos += 1; // '['

    var result: TupleType = undefined;
    if (s_info.field_types.len == 0) {
        if (try cursor.peekKind() != .array_end) return error.LengthMismatch;
        cursor.pos += 1;
        return result;
    }

    if (try cursor.peekKind() == .array_end) return error.LengthMismatch;

    var fields_done: [s_info.field_types.len]bool = @splat(false);
    errdefer {
        inline for (s_info.field_names, s_info.field_types, 0..) |f_name, FType, idx| {
            if (fields_done[idx]) {
                freeDecoded(FType, allocator, @field(result, f_name), cursor.input);
            }
        }
    }

    inline for (s_info.field_names, s_info.field_types, 0..) |f_name, FType, i| {
        if (i > 0) {
            cursor.skipWhitespace();
            if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
            if (cursor.input[cursor.pos] == ']') return error.LengthMismatch;
            if (cursor.input[cursor.pos] != ',') return error.SyntaxError;
            cursor.pos += 1;
        }
        @field(result, f_name) = try decodeValue(FType, allocator, cursor, options);
        fields_done[i] = true;
    }

    cursor.skipWhitespace();
    if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
    if (cursor.input[cursor.pos] == ',') return error.LengthMismatch;
    if (cursor.input[cursor.pos] != ']') return error.SyntaxError;
    cursor.pos += 1;
    return result;
}

fn decodeBytes(allocator: Allocator, cursor: *Cursor, options: DecodeOptions) DecodeError!types.Bytes {
    switch (try cursor.peekKind()) {
        .string => {
            const str_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
            defer str_tok.freeIfAllocated(allocator);
            return types.Bytes.decodeBase64Alloc(allocator, str_tok.slice) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidBase64,
            };
        },
        .array_begin => {
            const slice = try decodeSlice([]const u8, u8, allocator, cursor, options);
            return types.Bytes.init(slice);
        },
        .eof => return error.UnexpectedEndOfInput,
        else => return error.UnexpectedToken,
    }
}

fn decodeOsPath(allocator: Allocator, cursor: *Cursor, options: DecodeOptions) DecodeError!types.OsPath {
    switch (try cursor.peekKind()) {
        .string => {
            // Decode using WTF-8 mode so lone surrogate escapes (\uD800..\uDFFF) in JSON strings
            // are preserved in `raw` while `display` is converted to valid lossy UTF-8!
            const decoded = try cursor.readString(allocator, options.allocate, .wtf8);
            if (!decoded.had_wtf8_surrogate) {
                return .{
                    .raw = decoded.slice,
                    .display = decoded.slice,
                };
            }
            errdefer decoded.freeIfAllocated(allocator);
            const display_utf8 = try types.allocLossyUtf8(allocator, decoded.slice);
            return .{
                .raw = decoded.slice,
                .display = display_utf8,
            };
        },
        .object_begin => {
            try cursor.enterContainer(options.max_depth);
            defer cursor.leaveContainer();
            cursor.pos += 1; // '{'

            var display_tok: ?DecodedString = null;
            errdefer if (display_tok) |dt| dt.freeIfAllocated(allocator);
            var raw_token_opt: ?[]const u8 = null;
            errdefer if (raw_token_opt) |rt| if (!isSliceInsideInput(rt, cursor.input)) allocator.free(rt);
            var seen_display = false;
            var seen_raw_token = false;

            if (try cursor.peekKind() == .object_end) {
                cursor.pos += 1;
                return error.MissingField;
            }

            while (true) {
                const key_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
                defer key_tok.freeIfAllocated(allocator);

                cursor.skipWhitespace();
                if (cursor.pos >= cursor.input.len or cursor.input[cursor.pos] != ':') return error.SyntaxError;
                cursor.pos += 1;

                if (std.mem.eql(u8, key_tok.slice, "display")) {
                    if (seen_display and options.duplicate_field_behavior == .@"error") return error.DuplicateField;
                    seen_display = true;
                    const d_tok = try cursor.readString(allocator, options.allocate, .strict_utf8);
                    if (display_tok == null) {
                        display_tok = d_tok;
                    } else if (options.duplicate_field_behavior == .use_last) {
                        display_tok.?.freeIfAllocated(allocator);
                        display_tok = d_tok;
                    } else {
                        d_tok.freeIfAllocated(allocator);
                    }
                } else if (std.mem.eql(u8, key_tok.slice, "rawToken") or std.mem.eql(u8, key_tok.slice, "raw_token")) {
                    if (seen_raw_token and options.duplicate_field_behavior == .@"error") return error.DuplicateField;
                    seen_raw_token = true;
                    if (try cursor.peekKind() == .null) {
                        try cursor.readNull();
                        if (raw_token_opt) |rt| {
                            if (options.duplicate_field_behavior == .use_last) {
                                if (!isSliceInsideInput(rt, cursor.input)) allocator.free(rt);
                                raw_token_opt = null;
                            }
                        }
                    } else {
                        const r_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
                        defer r_tok.freeIfAllocated(allocator);
                        const decoded_bytes = types.Bytes.decodeBase64Alloc(allocator, r_tok.slice) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.InvalidBase64,
                        };
                        if (raw_token_opt == null) {
                            raw_token_opt = decoded_bytes.data;
                        } else if (options.duplicate_field_behavior == .use_last) {
                            if (!isSliceInsideInput(raw_token_opt.?, cursor.input)) allocator.free(raw_token_opt.?);
                            raw_token_opt = decoded_bytes.data;
                        } else {
                            if (!isSliceInsideInput(decoded_bytes.data, cursor.input)) allocator.free(decoded_bytes.data);
                        }
                    }
                } else if (options.ignore_unknown_fields) {
                    try cursor.skipValue(options.max_depth);
                } else {
                    return error.UnknownField;
                }

                cursor.skipWhitespace();
                if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
                switch (cursor.input[cursor.pos]) {
                    ',' => cursor.pos += 1,
                    '}' => {
                        cursor.pos += 1;
                        break;
                    },
                    else => return error.SyntaxError,
                }
            }

            if (raw_token_opt) |raw_bytes| {
                const disp = if (display_tok) |dt| dt.slice else try types.allocLossyUtf8(allocator, raw_bytes);
                return .{
                    .raw = raw_bytes,
                    .display = disp,
                };
            }
            if (display_tok) |dt| {
                return .{
                    .raw = dt.slice,
                    .display = dt.slice,
                };
            }
            return error.MissingField;
        },
        .eof => return error.UnexpectedEndOfInput,
        else => return error.UnexpectedToken,
    }
}

/// Decodes a JSON object into struct `S`.
/// If `skip_tag_field` is non-null (used by `.internal` union decoding), a field matching `skip_tag_field`
/// is skipped (and checked for duplicates against `tag_already_consumed`).
fn decodeStruct(
    comptime S: type,
    allocator: Allocator,
    cursor: *Cursor,
    skip_tag_field: ?[]const u8,
    options: DecodeOptions,
) DecodeError!S {
    if (skip_tag_field == null) {
        if (try cursor.peekKind() != .object_begin) {
            return if (try cursor.peekKind() == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
        }
        try cursor.enterContainer(options.max_depth);
        cursor.pos += 1; // '{'
    }
    defer if (skip_tag_field == null) cursor.leaveContainer();

    const s_info = @typeInfo(S).@"struct";
    var result: S = undefined;
    var fields_seen: [s_info.field_names.len]bool = @splat(false);
    var seen_tag_field = false;
    errdefer {
        inline for (s_info.field_names, s_info.field_types, 0..) |f_name, FType, idx| {
            if (fields_seen[idx]) {
                freeDecoded(FType, allocator, @field(result, f_name), cursor.input);
            }
        }
    }

    if (try cursor.peekKind() == .object_end) {
        cursor.pos += 1;
        try fillDefaultStructFields(S, &result, &fields_seen);
        return result;
    }

    while (true) {
        const key_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
        defer key_tok.freeIfAllocated(allocator);

        cursor.skipWhitespace();
        if (cursor.pos >= cursor.input.len or cursor.input[cursor.pos] != ':') return error.SyntaxError;
        cursor.pos += 1;

        if (skip_tag_field) |tf| {
            if (std.mem.eql(u8, key_tok.slice, tf)) {
                if (seen_tag_field and options.duplicate_field_behavior == .@"error") {
                    return error.DuplicateField;
                }
                seen_tag_field = true;
                try cursor.skipString();
                cursor.skipWhitespace();
                if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
                switch (cursor.input[cursor.pos]) {
                    ',' => {
                        cursor.pos += 1;
                        continue;
                    },
                    '}' => {
                        cursor.pos += 1;
                        break;
                    },
                    else => return error.SyntaxError,
                }
            }
        }

        var matched = false;
        inline for (s_info.field_names, s_info.field_types, 0..) |f_name, FType, i| {
            if (!matched and naming.matchesFieldName(f_name, key_tok.slice, options.allow_snake_case_fields)) {
                matched = true;
                if (FType == void) {
                    try cursor.readNull();
                    fields_seen[i] = true;
                } else if (fields_seen[i]) {
                    switch (options.duplicate_field_behavior) {
                        .@"error" => return error.DuplicateField,
                        .use_first => {
                            const ignored = try decodeValue(FType, allocator, cursor, options);
                            freeDecoded(FType, allocator, ignored, cursor.input);
                        },
                        .use_last => {
                            const replacement = try decodeValue(FType, allocator, cursor, options);
                            freeDecoded(FType, allocator, @field(result, f_name), cursor.input);
                            @field(result, f_name) = replacement;
                        },
                    }
                } else {
                    @field(result, f_name) = try decodeValue(FType, allocator, cursor, options);
                    fields_seen[i] = true;
                }
            }
        }

        if (!matched) {
            if (options.ignore_unknown_fields) {
                try cursor.skipValue(options.max_depth);
            } else {
                return error.UnknownField;
            }
        }

        cursor.skipWhitespace();
        if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
        switch (cursor.input[cursor.pos]) {
            ',' => cursor.pos += 1,
            '}' => {
                cursor.pos += 1;
                break;
            },
            else => return error.SyntaxError,
        }
    }

    try fillDefaultStructFields(S, &result, &fields_seen);
    return result;
}

fn fillDefaultStructFields(
    comptime S: type,
    result: *S,
    fields_seen: *const [@typeInfo(S).@"struct".field_names.len]bool,
) DecodeError!void {
    const s_info = @typeInfo(S).@"struct";
    inline for (s_info.field_names, s_info.field_types, s_info.field_attrs, 0..) |f_name, FType, f_attrs, i| {
        if (!fields_seen[i]) {
            if (FType == void) {
                @field(result, f_name) = {};
            } else if (f_attrs.defaultValue(FType)) |default_val| {
                @field(result, f_name) = default_val;
            } else if (comptime types.isPatchType(FType)) {
                @field(result, f_name) = .unchanged;
            } else {
                return error.MissingField;
            }
        }
    }
}

fn decodeUnionWithConfig(
    comptime U: type,
    allocator: Allocator,
    cursor: *Cursor,
    cfg: types.UnionConfig,
    options: DecodeOptions,
) DecodeError!U {
    return switch (cfg.style) {
        .internal => decodeInternalUnion(U, allocator, cursor, cfg, options),
        .adjacent => decodeAdjacentUnion(U, allocator, cursor, cfg, options),
        .external => decodeExternalUnion(U, allocator, cursor, options),
        .untagged => decodeUntaggedUnion(U, allocator, cursor, options),
    };
}

/// Scans an object body (starting right after `{`) to locate `tag_field` and read its string value.
fn findTagFieldInObject(
    allocator: Allocator,
    body_start_cursor: Cursor,
    tag_field: []const u8,
    options: DecodeOptions,
) DecodeError!DecodedString {
    var scan = body_start_cursor;
    if (try scan.peekKind() == .object_end) {
        return error.MissingField;
    }

    var found_tag: ?DecodedString = null;
    errdefer if (found_tag) |ft| ft.freeIfAllocated(allocator);

    while (true) {
        const k = try scan.readString(allocator, .alloc_if_needed, .strict_utf8);
        defer k.freeIfAllocated(allocator);

        scan.skipWhitespace();
        if (scan.pos >= scan.input.len or scan.input[scan.pos] != ':') return error.SyntaxError;
        scan.pos += 1;

        if (std.mem.eql(u8, k.slice, tag_field)) {
            if (found_tag != null and options.duplicate_field_behavior == .@"error") {
                return error.DuplicateField;
            }
            const tag_val = try scan.readString(allocator, .alloc_if_needed, .strict_utf8);
            if (found_tag == null) {
                found_tag = tag_val;
            } else if (options.duplicate_field_behavior == .use_last) {
                found_tag.?.freeIfAllocated(allocator);
                found_tag = tag_val;
            } else {
                tag_val.freeIfAllocated(allocator);
            }
        } else {
            try scan.skipValue(options.max_depth);
        }

        scan.skipWhitespace();
        if (scan.pos >= scan.input.len) return error.UnexpectedEndOfInput;
        switch (scan.input[scan.pos]) {
            ',' => scan.pos += 1,
            '}' => break,
            else => return error.SyntaxError,
        }
    }

    return found_tag orelse error.MissingField;
}

fn decodeInternalUnion(
    comptime U: type,
    allocator: Allocator,
    cursor: *Cursor,
    cfg: types.UnionConfig,
    options: DecodeOptions,
) DecodeError!U {
    if (try cursor.peekKind() != .object_begin) {
        return if (try cursor.peekKind() == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
    }
    try cursor.enterContainer(options.max_depth);
    defer cursor.leaveContainer();
    cursor.pos += 1; // '{'

    const body_start = cursor.*;
    const tag_tok = try findTagFieldInObject(allocator, body_start, cfg.tag_field, options);
    defer tag_tok.freeIfAllocated(allocator);

    const u_info = @typeInfo(U).@"union";
    inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
        if (std.mem.eql(u8, tag_tok.slice, v_name)) {
            if (PayloadType == void) {
                const EmptyStruct = struct {};
                _ = try decodeStruct(EmptyStruct, allocator, cursor, cfg.tag_field, options);
                return @unionInit(U, v_name, {});
            } else if (comptime isFlattenableStruct(PayloadType)) {
                const payload = try decodeStruct(PayloadType, allocator, cursor, cfg.tag_field, options);
                return @unionInit(U, v_name, payload);
            } else {
                // Non-struct payload wrapped under `cfg.content_field` (default `"value"`)
                const payload = try decodeContentFieldObject(PayloadType, allocator, cursor, cfg.tag_field, cfg.content_field, options);
                return @unionInit(U, v_name, payload);
            }
        }
    }
    return error.InvalidEnumTag;
}

fn decodeContentFieldObject(
    comptime PayloadType: type,
    allocator: Allocator,
    cursor: *Cursor,
    tag_field: []const u8,
    content_field: []const u8,
    options: DecodeOptions,
) DecodeError!PayloadType {
    var seen_tag = false;
    var seen_content = false;
    var payload: PayloadType = undefined;
    errdefer if (seen_content) freeDecoded(PayloadType, allocator, payload, cursor.input);

    if (try cursor.peekKind() == .object_end) {
        cursor.pos += 1;
        return error.MissingField;
    }

    while (true) {
        const key_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
        defer key_tok.freeIfAllocated(allocator);

        cursor.skipWhitespace();
        if (cursor.pos >= cursor.input.len or cursor.input[cursor.pos] != ':') return error.SyntaxError;
        cursor.pos += 1;

        if (std.mem.eql(u8, key_tok.slice, tag_field)) {
            if (seen_tag and options.duplicate_field_behavior == .@"error") return error.DuplicateField;
            seen_tag = true;
            try cursor.skipString();
        } else if (std.mem.eql(u8, key_tok.slice, content_field)) {
            if (seen_content) {
                switch (options.duplicate_field_behavior) {
                    .@"error" => return error.DuplicateField,
                    .use_first => {
                        const ignored = try decodeValue(PayloadType, allocator, cursor, options);
                        freeDecoded(PayloadType, allocator, ignored, cursor.input);
                    },
                    .use_last => {
                        const replacement = try decodeValue(PayloadType, allocator, cursor, options);
                        freeDecoded(PayloadType, allocator, payload, cursor.input);
                        payload = replacement;
                    },
                }
            } else {
                payload = try decodeValue(PayloadType, allocator, cursor, options);
                seen_content = true;
            }
        } else if (options.ignore_unknown_fields) {
            try cursor.skipValue(options.max_depth);
        } else {
            return error.UnknownField;
        }

        cursor.skipWhitespace();
        if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
        switch (cursor.input[cursor.pos]) {
            ',' => cursor.pos += 1,
            '}' => {
                cursor.pos += 1;
                break;
            },
            else => return error.SyntaxError,
        }
    }

    if (!seen_content) return error.MissingField;
    return payload;
}

fn decodeAdjacentUnion(
    comptime U: type,
    allocator: Allocator,
    cursor: *Cursor,
    cfg: types.UnionConfig,
    options: DecodeOptions,
) DecodeError!U {
    if (try cursor.peekKind() != .object_begin) {
        return if (try cursor.peekKind() == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
    }
    try cursor.enterContainer(options.max_depth);
    defer cursor.leaveContainer();
    cursor.pos += 1; // '{'

    const body_start = cursor.*;
    const tag_tok = try findTagFieldInObject(allocator, body_start, cfg.tag_field, options);
    defer tag_tok.freeIfAllocated(allocator);

    const u_info = @typeInfo(U).@"union";
    inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
        if (std.mem.eql(u8, tag_tok.slice, v_name)) {
            if (PayloadType == void) {
                try consumeAdjacentVoidObject(allocator, cursor, cfg.tag_field, cfg.content_field, options);
                return @unionInit(U, v_name, {});
            } else {
                const payload = try decodeContentFieldObject(PayloadType, allocator, cursor, cfg.tag_field, cfg.content_field, options);
                return @unionInit(U, v_name, payload);
            }
        }
    }
    return error.InvalidEnumTag;
}

fn consumeAdjacentVoidObject(
    allocator: Allocator,
    cursor: *Cursor,
    tag_field: []const u8,
    content_field: []const u8,
    options: DecodeOptions,
) DecodeError!void {
    var seen_tag = false;
    var seen_content = false;

    while (true) {
        const key_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
        defer key_tok.freeIfAllocated(allocator);

        cursor.skipWhitespace();
        if (cursor.pos >= cursor.input.len or cursor.input[cursor.pos] != ':') return error.SyntaxError;
        cursor.pos += 1;

        if (std.mem.eql(u8, key_tok.slice, tag_field)) {
            if (seen_tag and options.duplicate_field_behavior == .@"error") return error.DuplicateField;
            seen_tag = true;
            try cursor.skipString();
        } else if (std.mem.eql(u8, key_tok.slice, content_field)) {
            if (seen_content and options.duplicate_field_behavior == .@"error") return error.DuplicateField;
            seen_content = true;
            switch (try cursor.peekKind()) {
                .null => try cursor.readNull(),
                .object_begin => {
                    cursor.pos += 1;
                    if (try cursor.peekKind() != .object_end) return error.UnexpectedToken;
                    cursor.pos += 1;
                },
                else => return error.UnexpectedToken,
            }
        } else if (options.ignore_unknown_fields) {
            try cursor.skipValue(options.max_depth);
        } else {
            return error.UnknownField;
        }

        cursor.skipWhitespace();
        if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
        switch (cursor.input[cursor.pos]) {
            ',' => cursor.pos += 1,
            '}' => {
                cursor.pos += 1;
                return;
            },
            else => return error.SyntaxError,
        }
    }
}

fn decodeExternalUnion(
    comptime U: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!U {
    const u_info = @typeInfo(U).@"union";
    switch (try cursor.peekKind()) {
        .string => {
            const tag_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
            defer tag_tok.freeIfAllocated(allocator);

            inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
                if (std.mem.eql(u8, tag_tok.slice, v_name)) {
                    if (PayloadType != void) return error.UnexpectedToken;
                    return @unionInit(U, v_name, {});
                }
            }
            return error.InvalidEnumTag;
        },
        .object_begin => {
            try cursor.enterContainer(options.max_depth);
            defer cursor.leaveContainer();
            cursor.pos += 1; // '{'

            if (try cursor.peekKind() == .object_end) return error.UnexpectedToken;

            const tag_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
            defer tag_tok.freeIfAllocated(allocator);

            cursor.skipWhitespace();
            if (cursor.pos >= cursor.input.len or cursor.input[cursor.pos] != ':') return error.SyntaxError;
            cursor.pos += 1;

            var result: ?U = null;
            inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
                if (std.mem.eql(u8, tag_tok.slice, v_name)) {
                    if (PayloadType == void) {
                        switch (try cursor.peekKind()) {
                            .null => try cursor.readNull(),
                            .object_begin => {
                                cursor.pos += 1;
                                if (try cursor.peekKind() != .object_end) return error.UnexpectedToken;
                                cursor.pos += 1;
                            },
                            else => return error.UnexpectedToken,
                        }
                        result = @unionInit(U, v_name, {});
                    } else {
                        const payload = try decodeValue(PayloadType, allocator, cursor, options);
                        result = @unionInit(U, v_name, payload);
                    }
                }
            }

            if (result == null) return error.InvalidEnumTag;

            cursor.skipWhitespace();
            if (cursor.pos >= cursor.input.len or cursor.input[cursor.pos] != '}') return error.UnexpectedToken;
            cursor.pos += 1;
            return result.?;
        },
        .eof => return error.UnexpectedEndOfInput,
        else => return error.UnexpectedToken,
    }
}

fn decodeUntaggedUnion(
    comptime U: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!U {
    const u_info = @typeInfo(U).@"union";
    const saved = cursor.*;

    inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
        cursor.* = saved;
        if (decodeValue(PayloadType, allocator, cursor, options)) |payload| {
            return @unionInit(U, v_name, payload);
        } else |err| switch (err) {
            error.OutOfMemory, error.SyntaxError, error.UnexpectedEndOfInput, error.MaxDepthExceeded, error.NonFiniteFloat, error.LoneSurrogate => return err,
            else => {},
        }
    }

    return error.UnexpectedToken;
}

// ============================================================================
// Comprehensive Unit Tests (Covering All 10 Boundary Cases & Edge Cases)
// ============================================================================

test "Boundary #1a: zero-copy string decoding (.alloc_if_needed) allocates 0 bytes on unescaped strings" {
    const UserMsg = struct {
        user_name: []const u8,
        greeting_text: []const u8,
        active: bool,
        retry_count: u16,
    };

    const json = "{\"userName\":\"umiturtle\",\"greetingText\":\"Hello, Z-Ts!\",\"active\":true,\"retryCount\":3}";

    // Use FailingAllocator to prove literally ZERO heap allocations occur!
    const decoded = try decodeLeaky(UserMsg, testing.failing_allocator, json);
    try testing.expectEqualStrings("umiturtle", decoded.user_name);
    try testing.expectEqualStrings("Hello, Z-Ts!", decoded.greeting_text);
    try testing.expect(decoded.active);
    try testing.expectEqual(@as(u16, 3), decoded.retry_count);

    // Verify slices point directly into `json` buffer
    const json_start = @intFromPtr(json.ptr);
    const json_end = json_start + json.len;
    try testing.expect(@intFromPtr(decoded.user_name.ptr) >= json_start and @intFromPtr(decoded.user_name.ptr) < json_end);
    try testing.expect(@intFromPtr(decoded.greeting_text.ptr) >= json_start and @intFromPtr(decoded.greeting_text.ptr) < json_end);

    // Even managed `decode` performs 0 heap allocations when no strings are escaped!
    const parsed = try decode(UserMsg, testing.failing_allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("umiturtle", parsed.value.user_name);
}

test "Boundary #1b: lone UTF-16 surrogates in JSON strings (reject, replace_with_fffd, and valid pairs)" {
    // 1. Valid surrogate pair \uD83D\uDE80 (🚀 U+1F680) succeeds in strict mode
    {
        const parsed = try decode([]const u8, testing.allocator, "\"launch \\uD83D\\uDE80!\"");
        defer parsed.deinit();
        try testing.expectEqualStrings("launch 🚀!", parsed.value);
    }

    // 2. Unpaired high surrogate \uD800 and unpaired low surrogate \uDC00 are rejected in strict mode
    try testing.expectError(error.LoneSurrogate, decode([]const u8, testing.allocator, "\"\\uD800\""));
    try testing.expectError(error.LoneSurrogate, decode([]const u8, testing.allocator, "\"\\uDC00\""));
    try testing.expectError(error.LoneSurrogate, decode([]const u8, testing.allocator, "\"prefix_\\uD800_suffix\""));
    try testing.expectError(error.LoneSurrogate, decode([]const u8, testing.allocator, "\"\\uDC00\\uD800\""));

    // 3. With surrogate_policy = .replace_with_fffd, lone surrogates become U+FFFD while valid pairs remain intact
    {
        // Note: \uD800 followed immediately by a valid surrogate pair \uD83D\uDE80!
        const parsed = try decodeWithOptions(
            []const u8,
            testing.allocator,
            "\"lone:\\uD800 pair:\\uD83D\\uDE80 low:\\uDC00\"",
            .{ .surrogate_policy = .replace_with_fffd },
        );
        defer parsed.deinit();
        try testing.expectEqualStrings(
            "lone:" ++ types.utf8_replacement_char ++ " pair:🚀 low:" ++ types.utf8_replacement_char,
            parsed.value,
        );
    }

    // 4. Invalid raw UTF-8 bytes in []const u8 are rejected on both encode and decode
    const bad_utf8 = [_]u8{ 'a', 0xFF, 0xFE, 'b' };
    try testing.expectError(error.InvalidUtf8, encodeAlloc(testing.allocator, @as([]const u8, &bad_utf8)));
    const bad_json = [_]u8{ '"', 'a', 0xFF, '"' };
    try testing.expectError(error.InvalidUtf8, decode([]const u8, testing.allocator, &bad_json));
}

test "Boundary #1c: OsPath roundtrips valid UTF-8, non-UTF-8 POSIX bytes, and Windows WTF-8 surrogates losslessly" {
    // Case 1: Normal UTF-8 path (zero-copy string wire format)
    {
        const orig = types.OsPath.fromUtf8("/home/user/プロジェクト/main.zig");
        const json = try encodeAlloc(testing.allocator, orig);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("\"/home/user/プロジェクト/main.zig\"", json);

        const parsed = try decode(types.OsPath, testing.failing_allocator, json);
        defer parsed.deinit();
        try testing.expect(orig.eql(parsed.value));
        try testing.expectEqualStrings("/home/user/プロジェクト/main.zig", parsed.value.display);
    }

    // Case 2: Arbitrary non-UTF-8 POSIX path bytes (/tmp/icon_\xff\xfe\x80.png)
    {
        const raw_posix = "/tmp/icon_\xff\xfe\x80.png";
        const orig = types.OsPath.fromRawBorrowed(raw_posix);
        const json = try encodeAlloc(testing.allocator, orig);
        defer testing.allocator.free(json);

        // Wire JSON must be valid UTF-8 and contain both "display" and "rawToken"
        try testing.expect(std.unicode.utf8ValidateSlice(json));
        try testing.expect(std.mem.indexOf(u8, json, "\"display\":\"/tmp/icon_") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"rawToken\":\"") != null);

        const parsed = try decode(types.OsPath, testing.allocator, json);
        defer parsed.deinit();
        // Exact raw byte roundtrip!
        try testing.expectEqualSlices(u8, raw_posix, parsed.value.asSlice());
        try testing.expect(std.unicode.utf8ValidateSlice(parsed.value.display));
    }

    // Case 3: Windows WTF-8 path with lone surrogate (0xED 0xA0 0x80 = U+D800)
    {
        const raw_wtf8 = "C:\\Users\\dev\\file_" ++ [3]u8{ 0xED, 0xA0, 0x80 } ++ ".dat";
        const orig = try types.OsPath.init(testing.allocator, raw_wtf8);
        defer orig.deinitDisplayIfAllocated(testing.allocator);

        const json = try encodeAlloc(testing.allocator, orig);
        defer testing.allocator.free(json);

        const parsed = try decode(types.OsPath, testing.allocator, json);
        defer parsed.deinit();
        try testing.expectEqualSlices(u8, raw_wtf8, parsed.value.asSlice());
        try testing.expectEqualStrings("C:\\Users\\dev\\file_" ++ types.utf8_replacement_char ++ ".dat", parsed.value.display);
    }

    // Case 4: JS string with \uD800 escape decoded directly into OsPath preserves WTF-8 in `raw`
    {
        const js_string_json = "\"C:\\\\dir\\\\unpaired_\\uD800.txt\"";
        const parsed = try decode(types.OsPath, testing.allocator, js_string_json);
        defer parsed.deinit();
        const expected_wtf8 = "C:\\dir\\unpaired_" ++ [3]u8{ 0xED, 0xA0, 0x80 } ++ ".txt";
        try testing.expectEqualSlices(u8, expected_wtf8, parsed.value.asSlice());
        try testing.expectEqualStrings("C:\\dir\\unpaired_" ++ types.utf8_replacement_char ++ ".txt", parsed.value.display);
    }
}

test "Boundary #1d: Bytes roundtrips binary data via Base64 and via number array" {
    const raw_bin = [_]u8{ 0x00, 0x01, 0x02, 0x7F, 0x80, 0xFE, 0xFF };
    const payload = struct {
        id: u32,
        chunk: types.Bytes,
    }{
        .id = 7,
        .chunk = types.Bytes.init(&raw_bin),
    };

    // Base64 mode (default)
    {
        const json = try encodeAlloc(testing.allocator, payload);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("{\"id\":7,\"chunk\":\"AAECf4D+/w==\"}", json);

        const parsed = try decode(@TypeOf(payload), testing.allocator, json);
        defer parsed.deinit();
        try testing.expectEqual(@as(u32, 7), parsed.value.id);
        try testing.expectEqualSlices(u8, &raw_bin, parsed.value.chunk.slice());
    }

    // Array mode ([u8, ...])
    {
        const json = try encodeAllocWithOptions(testing.allocator, payload, .{ .bytes_format = .array });
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("{\"id\":7,\"chunk\":[0,1,2,127,128,254,255]}", json);

        const parsed = try decode(@TypeOf(payload), testing.allocator, json);
        defer parsed.deinit();
        try testing.expectEqualSlices(u8, &raw_bin, parsed.value.chunk.slice());
    }
}

test "Boundary #2: Patch(T) 3-state semantics (omitted vs null vs value) and optional field rules" {
    const UpdateProfile = struct {
        user_id: u53,
        display_name: types.Patch([]const u8) = .unchanged,
        bio: types.Patch([]const u8) = .unchanged,
        age: types.Patch(u8) = .unchanged,
    };

    // 1. All Patch fields omitted -> all .unchanged -> re-encodes with all Patch keys omitted!
    {
        const p1 = try decode(UpdateProfile, testing.failing_allocator, "{\"userId\":100}");
        defer p1.deinit();
        try testing.expectEqual(@as(u53, 100), p1.value.user_id);
        try testing.expect(p1.value.display_name == .unchanged);
        try testing.expect(p1.value.bio == .unchanged);
        try testing.expect(p1.value.age == .unchanged);

        const json1 = try encodeAlloc(testing.allocator, p1.value);
        defer testing.allocator.free(json1);
        try testing.expectEqualStrings("{\"userId\":100}", json1);
    }

    // 2. Mixed states: displayName = "Alice", bio = null, age omitted (.unchanged)
    {
        const input = "{\"userId\":100,\"displayName\":\"Alice\",\"bio\":null}";
        const p2 = try decode(UpdateProfile, testing.failing_allocator, input);
        defer p2.deinit();
        try testing.expectEqualStrings("Alice", p2.value.display_name.getValue().?);
        try testing.expect(p2.value.bio == .null);
        try testing.expect(p2.value.age == .unchanged);

        const json2 = try encodeAlloc(testing.allocator, p2.value);
        defer testing.allocator.free(json2);
        try testing.expectEqualStrings(input, json2);
    }

    // 3. Required ?T (no default) vs Optional ?T = null vs T = default
    const StrictOpts = struct {
        req_nullable: ?i32,
        opt_nullable: ?i32 = null,
        opt_with_default: i32 = 42,
    };
    // Missing `reqNullable` must fail with error.MissingField
    try testing.expectError(error.MissingField, decode(StrictOpts, testing.allocator, "{}"));
    // Providing `"reqNullable": null` while omitting the others succeeds
    {
        const parsed = try decode(StrictOpts, testing.failing_allocator, "{\"reqNullable\":null}");
        defer parsed.deinit();
        try testing.expectEqual(@as(?i32, null), parsed.value.req_nullable);
        try testing.expectEqual(@as(?i32, null), parsed.value.opt_nullable);
        try testing.expectEqual(@as(i32, 42), parsed.value.opt_with_default);
    }
}

test "Boundary #3: union(enum) 4 representation modes (.internal, .adjacent, .external, .untagged)" {
    const Shape = union(enum) {
        circle: struct { radius: f64 },
        rect: struct { width: f64, height: f64, border_width: u16 = 1 },
        label: []const u8,
        point: void,
    };

    // 1. Default `.internal` mode: {"kind":"circle","radius":10} & out-of-order {"radius":10,"kind":"circle"}
    {
        const s_circle = Shape{ .circle = .{ .radius = 12.5 } };
        const json_circle = try encodeAlloc(testing.allocator, s_circle);
        defer testing.allocator.free(json_circle);
        try testing.expectEqualStrings("{\"kind\":\"circle\",\"radius\":12.5}", json_circle);

        const d_circle = try decode(Shape, testing.failing_allocator, json_circle);
        try testing.expectEqual(@as(f64, 12.5), d_circle.value.circle.radius);

        // Out-of-order keys where "kind" comes LAST in the JSON object!
        const out_of_order = "{\"width\":100,\"height\":200,\"kind\":\"rect\"}";
        const d_rect = try decode(Shape, testing.failing_allocator, out_of_order);
        try testing.expectEqual(@as(f64, 100), d_rect.value.rect.width);
        try testing.expectEqual(@as(f64, 200), d_rect.value.rect.height);
        try testing.expectEqual(@as(u16, 1), d_rect.value.rect.border_width);

        // Void variant in `.internal` mode
        const s_point: Shape = .point;
        const json_point = try encodeAlloc(testing.allocator, s_point);
        defer testing.allocator.free(json_point);
        try testing.expectEqualStrings("{\"kind\":\"point\"}", json_point);
        const d_point = try decode(Shape, testing.failing_allocator, json_point);
        try testing.expect(d_point.value == .point);

        // Scalar variant in `.internal` mode
        const s_label = Shape{ .label = "center" };
        const json_label = try encodeAlloc(testing.allocator, s_label);
        defer testing.allocator.free(json_label);
        try testing.expectEqualStrings("{\"kind\":\"label\",\"value\":\"center\"}", json_label);
        const d_label = try decode(Shape, testing.failing_allocator, json_label);
        try testing.expectEqualStrings("center", d_label.value.label);
    }

    // 2. `.adjacent` mode: {"kind":"circle","value":{"radius":12.5}}
    {
        const AdjacentShape = types.TaggedUnion(Shape, .{ .style = .adjacent, .tag_field = "type", .content_field = "data" });
        const orig = AdjacentShape.init(.{ .circle = .{ .radius = 5.0 } });
        const json = try encodeAlloc(testing.allocator, orig);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("{\"type\":\"circle\",\"data\":{\"radius\":5}}", json);

        const parsed = try decode(AdjacentShape, testing.failing_allocator, json);
        try testing.expectEqual(@as(f64, 5.0), parsed.value.get().circle.radius);

        // Out-of-order ("data" before "type")
        const parsed_rev = try decode(AdjacentShape, testing.failing_allocator, "{\"data\":{\"radius\":9},\"type\":\"circle\"}");
        try testing.expectEqual(@as(f64, 9.0), parsed_rev.value.get().circle.radius);
    }

    // 3. `.external` mode: {"circle":{"radius":12.5}} and "point"
    {
        const ExternalShape = types.TaggedUnion(Shape, .{ .style = .external });
        const orig = ExternalShape.init(.{ .circle = .{ .radius = 8.0 } });
        const json = try encodeAlloc(testing.allocator, orig);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("{\"circle\":{\"radius\":8}}", json);

        const parsed = try decode(ExternalShape, testing.failing_allocator, json);
        try testing.expectEqual(@as(f64, 8.0), parsed.value.get().circle.radius);

        const orig_pt = ExternalShape.init(.point);
        const json_pt = try encodeAlloc(testing.allocator, orig_pt);
        defer testing.allocator.free(json_pt);
        try testing.expectEqualStrings("\"point\"", json_pt);

        const parsed_pt = try decode(ExternalShape, testing.failing_allocator, json_pt);
        try testing.expect(parsed_pt.value.get() == .point);
    }

    // 4. `.untagged` mode (e.g. CSS value `number | string | { auto: bool }`)
    {
        const CssSize = union(enum) {
            px: f64,
            keyword: []const u8,
            flag: bool,

            pub const json_union = types.UnionStyle.untagged;
        };

        const json_num = try encodeAlloc(testing.allocator, CssSize{ .px = 16.5 });
        defer testing.allocator.free(json_num);
        try testing.expectEqualStrings("16.5", json_num);

        const json_str = try encodeAlloc(testing.allocator, CssSize{ .keyword = "100vh" });
        defer testing.allocator.free(json_str);
        try testing.expectEqualStrings("\"100vh\"", json_str);

        const d_num = try decode(CssSize, testing.failing_allocator, "42");
        try testing.expectEqual(@as(f64, 42.0), d_num.value.px);

        // Even a numeric-looking string `"42"` must match `keyword: []const u8`, NOT `px: f64`!
        const d_str = try decode(CssSize, testing.failing_allocator, "\"42\"");
        try testing.expectEqualStrings("42", d_str.value.keyword);

        const d_flag = try decode(CssSize, testing.failing_allocator, "true");
        try testing.expectEqual(true, d_flag.value.flag);
    }
}

test "Boundary #4: snake_case <-> camelCase conversion and hyphenated HTML/CSS attributes preserved" {
    const DomProps = struct {
        tab_index: i32,
        is_disabled: bool,
        @"aria-label": []const u8,
        @"data-test-id": []const u8,
        @"--theme-bg": []const u8,
    };

    const props = DomProps{
        .tab_index = 0,
        .is_disabled = false,
        .@"aria-label" = "Close window",
        .@"data-test-id" = "close-btn",
        .@"--theme-bg" = "#1a1a1a",
    };

    const json = try encodeAlloc(testing.allocator, props);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"tabIndex\":0,\"isDisabled\":false,\"aria-label\":\"Close window\",\"data-test-id\":\"close-btn\",\"--theme-bg\":\"#1a1a1a\"}",
        json,
    );

    const parsed = try decode(DomProps, testing.failing_allocator, json);
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 0), parsed.value.tab_index);
    try testing.expectEqual(false, parsed.value.is_disabled);
    try testing.expectEqualStrings("Close window", parsed.value.@"aria-label");
    try testing.expectEqualStrings("close-btn", parsed.value.@"data-test-id");
    try testing.expectEqualStrings("#1a1a1a", parsed.value.@"--theme-bg");
}

test "Boundary #5: NaN and +-Infinity are strictly rejected on both encode and decode" {
    const Metrics = struct {
        fps: f64,
        scale: f32 = 1.0,
    };

    // Encode rejects NaN, +Inf, -Inf
    try testing.expectError(error.NonFiniteFloat, encodeAlloc(testing.allocator, std.math.nan(f64)));
    try testing.expectError(error.NonFiniteFloat, encodeAlloc(testing.allocator, std.math.inf(f64)));
    try testing.expectError(error.NonFiniteFloat, encodeAlloc(testing.allocator, -std.math.inf(f64)));
    try testing.expectError(error.NonFiniteFloat, encodeAlloc(testing.allocator, Metrics{ .fps = 60.0, .scale = std.math.nan(f32) }));

    // Decode rejects NaN, Infinity, -Infinity, null into non-optional float, and float overflow (1e500 -> +Inf)
    try testing.expectError(error.NonFiniteFloat, decode(f64, testing.allocator, "NaN"));
    try testing.expectError(error.NonFiniteFloat, decode(f64, testing.allocator, "Infinity"));
    try testing.expectError(error.NonFiniteFloat, decode(f64, testing.allocator, "-Infinity"));
    try testing.expectError(error.NonFiniteFloat, decode(f64, testing.allocator, "1e500"));
    try testing.expectError(error.NonFiniteFloat, decode(f32, testing.allocator, "1e50"));
    try testing.expectError(error.UnexpectedToken, decode(f64, testing.allocator, "null"));

    // Valid finite floats roundtrip cleanly
    const valid = Metrics{ .fps = 144.5, .scale = 2.0 };
    const json = try encodeAlloc(testing.allocator, valid);
    defer testing.allocator.free(json);
    const parsed = try decode(Metrics, testing.failing_allocator, json);
    try testing.expectEqual(@as(f64, 144.5), parsed.value.fps);
    try testing.expectEqual(@as(f32, 2.0), parsed.value.scale);
}

test "Boundary #6 (53-bit integer guard & BigInt): compile-time rejection of raw i64/u64/usize and BigInt roundtrip" {
    // 1. Verify compile-time type validator rejects raw i64, u64, i128, u128, usize, isize
    try testing.expect(!isValidRpcType(i64));
    try testing.expect(!isValidRpcType(u64));
    try testing.expect(!isValidRpcType(i128));
    try testing.expect(!isValidRpcType(u128));
    try testing.expect(!isValidRpcType(usize));
    try testing.expect(!isValidRpcType(isize));
    try testing.expect(!isValidRpcType(i54));
    try testing.expect(!isValidRpcType(u54));
    try testing.expect(!isValidRpcType(struct { bad_field: u64 }));
    try testing.expect(!isValidRpcType(types.Patch(i64)));

    // And accepts i8..i53, u8..u53, and BigInt(i64/u64/i128)
    try testing.expect(isValidRpcType(i53));
    try testing.expect(isValidRpcType(u53));
    try testing.expect(isValidRpcType(i32));
    try testing.expect(isValidRpcType(u32));
    try testing.expect(isValidRpcType(types.BigInt(i64)));
    try testing.expect(isValidRpcType(types.BigInt(u64)));
    try testing.expect(isValidRpcType(types.BigInt(i128)));

    // 2. u53 and i53 boundary values roundtrip as JSON numbers
    {
        const max_u53: u53 = std.math.maxInt(u53); // 9007199254740991
        const json = try encodeAlloc(testing.allocator, max_u53);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("9007199254740991", json);

        const parsed = try decode(u53, testing.failing_allocator, json);
        try testing.expectEqual(max_u53, parsed.value);

        // 2^53 (9007199254740992) overflows u53!
        try testing.expectError(error.Overflow, decode(u53, testing.allocator, "9007199254740992"));
    }

    // 3. BigInt(i64 / u64 / i128) roundtrips >53-bit integers as JSON strings
    {
        const LedgerEntry = struct {
            tx_id: types.BigInt(u64),
            balance_delta: types.BigInt(i64),
            huge_nonce: types.BigInt(i128),
        };
        const entry = LedgerEntry{
            .tx_id = .init(18446744073709551615),
            .balance_delta = .init(-9007199254740993),
            .huge_nonce = .init(170141183460469231731687303715884105727),
        };

        const json = try encodeAlloc(testing.allocator, entry);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings(
            "{\"txId\":\"18446744073709551615\",\"balanceDelta\":\"-9007199254740993\",\"hugeNonce\":\"170141183460469231731687303715884105727\"}",
            json,
        );

        const parsed = try decode(LedgerEntry, testing.failing_allocator, json);
        try testing.expect(entry.tx_id.eql(parsed.value.tx_id));
        try testing.expect(entry.balance_delta.eql(parsed.value.balance_delta));
        try testing.expect(entry.huge_nonce.eql(parsed.value.huge_nonce));

        // Raw JSON number passed to BigInt must be rejected with UnexpectedToken
        try testing.expectError(error.UnexpectedToken, decode(types.BigInt(i64), testing.allocator, "9007199254740993"));
    }
}

test "Boundary #8 & #9 & #10: HTML-safe JSON escaping, Enum string literals, and 53-bit Handle roundtrip" {
    const Theme = enum { light, dark, high_contrast };
    const WinHandle = types.Handle(.window);

    const Payload = struct {
        window: WinHandle,
        theme: Theme,
        xss_snippet: []const u8,
    };

    const orig = Payload{
        .window = .{ .index = 42, .generation = 7 },
        .theme = .high_contrast,
        .xss_snippet = "</script><script>alert(1)&</script>\u{2028}\u{2029}",
    };

    const html_safe_json = try encodeAllocWithOptions(testing.allocator, orig, .{ .html_safe = true });
    defer testing.allocator.free(html_safe_json);

    // Must not contain raw `</script>`, `<`, `>`, `&`, or raw U+2028/U+2029
    try testing.expect(std.mem.indexOf(u8, html_safe_json, "</script>") == null);
    try testing.expect(std.mem.indexOf(u8, html_safe_json, "\\u003c/script\\u003e") != null);
    try testing.expect(std.mem.indexOf(u8, html_safe_json, "\\u0026") != null);
    try testing.expect(std.mem.indexOf(u8, html_safe_json, "\\u2028\\u2029") != null);

    // Roundtrip decode restores the exact struct, enum, handle, and unescaped string
    const parsed = try decode(Payload, testing.allocator, html_safe_json);
    defer parsed.deinit();
    try testing.expect(orig.window.eql(parsed.value.window));
    try testing.expectEqual(@as(u24, 42), parsed.value.window.index);
    try testing.expectEqual(@as(u29, 7), parsed.value.window.generation);
    try testing.expectEqual(Theme.high_contrast, parsed.value.theme);
    try testing.expectEqualStrings(orig.xss_snippet, parsed.value.xss_snippet);

    // Unknown enum tag is rejected with error.InvalidEnumTag
    try testing.expectError(error.InvalidEnumTag, decode(Theme, testing.allocator, "\"solarized\""));
}

test "Error handling: duplicate fields, unknown fields, trailing garbage, and allocation failure" {
    const Item = struct {
        item_id: u32,
        tags: []const []const u8,
    };

    // Unknown field rejected by default, accepted when ignore_unknown_fields = true
    try testing.expectError(
        error.UnknownField,
        decode(Item, testing.allocator, "{\"itemId\":1,\"tags\":[],\"extra\":[1,2,{\"nested\":true}]}"),
    );
    {
        const p = try decodeWithOptions(
            Item,
            testing.allocator,
            "{\"itemId\":1,\"extra\":[1,2,{\"nested\":true}],\"tags\":[\"a\",\"b\"]}",
            .{ .ignore_unknown_fields = true },
        );
        defer p.deinit();
        try testing.expectEqual(@as(u32, 1), p.value.item_id);
        try testing.expectEqual(@as(usize, 2), p.value.tags.len);
        try testing.expectEqualStrings("a", p.value.tags[0]);
        try testing.expectEqualStrings("b", p.value.tags[1]);
    }

    // Duplicate field rejected by default
    try testing.expectError(
        error.DuplicateField,
        decode(Item, testing.allocator, "{\"itemId\":1,\"itemId\":2,\"tags\":[]}"),
    );

    // Trailing non-whitespace characters rejected
    try testing.expectError(
        error.SyntaxError,
        decode(u32, testing.allocator, "42 trailing"),
    );

    // Allocation failure safety (no memory leaks under CheckAllAllocationFailures)
    const alloc_test_fn = struct {
        fn run(gpa: Allocator) !void {
            const p = try decode(
                Item,
                gpa,
                "{\"itemId\":99,\"tags\":[\"escaped\\nstr\",\"second\\tstr\"]}",
            );
            defer p.deinit();
            const out = try encodeAlloc(gpa, p.value);
            defer gpa.free(out);
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, alloc_test_fn, .{});
}

test "Untagged union backtracking with escaped strings and decodeLeaky error cleanup (0 leaks)" {
    const UntaggedEvent = union(enum) {
        mouse: struct { label: []const u8, x: i32, y: i32 },
        keyboard: struct { label: []const u8, key_code: u32 },

        pub const json_union = types.UnionStyle.untagged;
    };

    // Trying `mouse` first will allocate `label` ("line1\nline2") and then fail on `"keyCode"` (UnknownField),
    // clean up its allocation via errdefer, backtrack, and succeed on `keyboard`!
    const input = "{\"label\":\"line1\\nline2\",\"keyCode\":27}";
    const ev = try decodeLeaky(UntaggedEvent, testing.allocator, input);
    defer freeDecoded(UntaggedEvent, testing.allocator, ev, input);

    try testing.expect(ev == .keyboard);
    try testing.expectEqualStrings("line1\nline2", ev.keyboard.label);
    try testing.expectEqual(@as(u32, 27), ev.keyboard.key_code);

    // Also verify decodeLeaky cleans up partial struct allocations when a later field fails
    const BadInput = "{\"label\":\"escaped\\tallocated\",\"x\":\"not_an_int\",\"y\":0}";
    try testing.expectError(error.UnexpectedToken, decodeLeaky(UntaggedEvent, testing.allocator, BadInput));
}

test "Custom jsonParse and jsonStringify hook compatibility (Tauri Channel wire format)" {
    const MockChannel = struct {
        id: u53,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.print("\"__CHANNEL__:{d}\"", .{self.id});
        }

        pub fn jsonParse(
            allocator: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !@This() {
            const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse 1024);
            defer switch (tok) {
                .allocated_number, .allocated_string => |s| allocator.free(s),
                else => {},
            };
            switch (tok) {
                .number, .allocated_number => |s| {
                    const id = std.fmt.parseInt(u53, s, 10) catch return error.InvalidNumber;
                    return .{ .id = id };
                },
                .string, .allocated_string => |s| {
                    const prefix = "__CHANNEL__:";
                    if (!std.mem.startsWith(u8, s, prefix)) return error.UnexpectedToken;
                    const id = std.fmt.parseInt(u53, s[prefix.len..], 10) catch return error.InvalidNumber;
                    return .{ .id = id };
                },
                else => return error.UnexpectedToken,
            }
        }
    };

    const CmdArgs = struct {
        on_progress: MockChannel,
    };

    // Decode from "__CHANNEL__:42" string
    {
        const p = try decode(CmdArgs, testing.allocator, "{\"onProgress\":\"__CHANNEL__:42\"}");
        defer p.deinit();
        try testing.expectEqual(@as(u53, 42), p.value.on_progress.id);

        const encoded = try encodeAlloc(testing.allocator, p.value);
        defer testing.allocator.free(encoded);
        try testing.expectEqualStrings("{\"onProgress\":\"__CHANNEL__:42\"}", encoded);
    }

    // Decode from numeric 77
    {
        const p = try decode(CmdArgs, testing.allocator, "{\"onProgress\":77}");
        defer p.deinit();
        try testing.expectEqual(@as(u53, 77), p.value.on_progress.id);
    }
}

test "Tuples, fixed arrays, vectors, sentinel strings, negative zero normalization, and MaxDepthExceeded" {
    const Complex = struct {
        coords: [3]i32,
        pair: struct { []const u8, bool },
        vec: @Vector(2, f64),
        c_str: [:0]const u8,
    };

    const orig = Complex{
        .coords = .{ 10, 20, 30 },
        .pair = .{ "ok", true },
        .vec = .{ -0.0, 3.5 },
        .c_str = "hello",
    };

    const json = try encodeAlloc(testing.allocator, orig);
    defer testing.allocator.free(json);
    // Note: -0.0 is normalized to 0
    try testing.expectEqualStrings(
        "{\"coords\":[10,20,30],\"pair\":[\"ok\",true],\"vec\":[0,3.5],\"cStr\":\"hello\"}",
        json,
    );

    const parsed = try decode(Complex, testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualSlices(i32, &orig.coords, &parsed.value.coords);
    try testing.expectEqualStrings("ok", parsed.value.pair[0]);
    try testing.expectEqual(true, parsed.value.pair[1]);
    try testing.expectEqual(@as(f64, 0.0), parsed.value.vec[0]);
    try testing.expectEqual(@as(f64, 3.5), parsed.value.vec[1]);
    try testing.expectEqualStrings("hello", parsed.value.c_str);
    try testing.expectEqual(@as(u8, 0), parsed.value.c_str[parsed.value.c_str.len]);

    // Fixed array length mismatch rejected
    try testing.expectError(error.LengthMismatch, decode([3]i32, testing.allocator, "[1,2]"));
    try testing.expectError(error.LengthMismatch, decode([3]i32, testing.allocator, "[1,2,3,4]"));

    // MaxDepthExceeded check
    try testing.expectError(
        error.MaxDepthExceeded,
        decodeWithOptions([]const []const []const u8, testing.allocator, "[[\"deep\"]]", .{ .max_depth = 1 }),
    );

    // Union tag collision check in checkRpcType
    const CollidingUnion = union(enum) {
        bad: struct { kind: []const u8 },
    };
    try testing.expect(!isValidRpcType(CollidingUnion));
}

test {
    _ = naming;
    _ = types;
}
