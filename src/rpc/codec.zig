//! Web ⇔ Zig JSON RPC Codec (`src/rpc/codec.zig`).
//!
//! Built cleanly atop `zts_core.html_escape` (`M1-02`), `zts_core.Handle` (`M1-01`),
//! `src/rpc/naming.zig`, `src/rpc/types.zig`, and `src/rpc/scanner.zig`.
//!
//! Enforces all Web ⇔ Zig boundary guarantees at `comptime` and runtime:
//! 1. Zero-copy UTF-8 string decoding (`allocate = .alloc_if_needed` -> 0 heap allocations on unescaped strings),
//!    strict/lossy UTF-16 lone surrogate handling, `Bytes` (`Base64` / `[u8]`), and lossless `OsPath` (WTF-8 + `rawToken`).
//! 2. `Patch(T)` 3-state semantics (`.unchanged` omitted vs `.null` vs `.value`) & strict optional defaults.
//! 3. `union(enum)` 4 wire styles (`.internal` with O(1) cursor rewind, `.adjacent`, `.external`, `.untagged`).
//! 4. `comptime` `snake_case` ⇔ `camelCase` with verbatim preservation of hyphenated keys (`aria-*`, `data-*`, `--*`).
//! 5. Strict non-finite float rejection (`NaN`, `±Infinity` -> `error.NonFiniteFloat`).
//! 6. Compile-time 53-bit integer precision guard (`@compileError` on bare `i64`/`u64`/`usize`), `SafeInt`, & `BigInt(T)`.
//! 7. HTML-safe JSON escaping via `core.html_escape`, nominal `core.Handle(Tag)` (`core.WindowId`) identity, and custom `jsonParse`/`jsonStringify` hooks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_foundation");
const html_escape = core.html_escape;
pub const naming = @import("naming.zig");
pub const scanner = @import("scanner.zig");
pub const types = @import("types.zig");

const Cursor = scanner.Cursor;
const DecodedString = scanner.DecodedString;
const StringDecodeMode = scanner.StringDecodeMode;

// ============================================================================
// Options & Error Types
// ============================================================================

/// How `zts_rpc.types.Bytes` (opaque binary) crosses the wire.
///
/// * `.base64` — a single JSON string. Compact, and what `ArrayBuffer` decoding in the generated
///   TypeScript expects.
/// * `.array` — a JSON array of numbers. Verbose, but readable in a log or a `curl` session.
pub const BytesFormat = enum {
    /// One Base64 string (compact, what the JS client expects).
    base64,
    /// An array of byte values (debuggable, larger).
    array,
};

/// What to do with an unpaired UTF-16 surrogate (`\uD800` with no low half).
///
/// `.reject` is the default because a lone surrogate cannot be re-encoded as UTF-8; `.replace_with_fffd`
/// is for parsers that must accept hostile input without failing the whole request.
pub const SurrogatePolicy = enum {
    /// Fail with `error.LoneSurrogate` (the default).
    reject,
    /// Substitute U+FFFD and keep going.
    replace_with_fffd,
};

/// What to do when a JSON object repeats a field. The default is `.@"error"`: silently picking the
/// first or the last occurrence is how request smuggling bugs get in.
pub const DuplicateFieldBehavior = enum {
    /// Keep the first occurrence.
    use_first,
    /// Keep the last occurrence.
    use_last,
    /// Reject the whole payload. Surfacing the ambiguity beats guessing: a request that sets the
    /// same key twice does not say which value it meant.
    @"error",
};

/// Knobs for the encoder. `.{}` (every default) is what the RPC router and `tsgen` assume.
///
/// * `html_safe` — escape `<`, `>` and `&` so the payload can be embedded in an inline `<script>`.
/// * `bytes_format` — see `BytesFormat`.
/// * `default_union_style` — wire shape used for `union(enum)` values that did not declare
///   `pub const json_union`.
/// * `emit_null_optional_fields` — emit `"field":null` instead of omitting the key. TypeScript
///   optional properties decode both, but `exactOptionalPropertyTypes` users usually want `false`.
pub const EncodeOptions = struct {
    /// Escape `<`, `>` and `&` so the payload can sit inside an inline `<script>`.
    html_safe: bool = false,
    /// How `Bytes` values are written.
    bytes_format: BytesFormat = .base64,
    /// Wire shape for `union(enum)` values that did not declare one.
    default_union_style: types.UnionStyle = .internal,
    /// Write `"field": null` instead of omitting optional fields.
    emit_null_optional_fields: bool = true,
};

/// Knobs for the decoder. Every value is validated *before* it reaches a field, so a malformed body
/// fails with a typed error instead of a half-populated struct.
///
/// * `allocate` — `std.json` allocation strategy for strings (`.alloc_if_needed` avoids copying when
///   the input is already owned by the caller).
/// * `surrogate_policy` — see `SurrogatePolicy`.
/// * `ignore_unknown_fields` — tolerate extra keys (forward compatibility with a newer frontend).
/// * `allow_snake_case_fallback` — accept `user_id` for a Zig field `userId`, which is what a
///   hand-written client sends.
/// * `duplicate_field_behavior` — see `DuplicateFieldBehavior`.
/// * `max_depth` — recursion limit; a deeply nested body is a denial-of-service vector.
pub const DecodeOptions = struct {
    /// Whether decoded strings are borrowed or copied.
    allocate: std.json.AllocWhen = .alloc_if_needed,
    /// What to do with lone surrogates.
    surrogate_policy: SurrogatePolicy = .reject,
    /// Accept fields the target type does not declare.
    ignore_unknown_fields: bool = false,
    /// Accept `snake_case` where the wire used `camelCase`.
    allow_snake_case_fallback: bool = false,
    /// What to do when a field repeats.
    duplicate_field_behavior: DuplicateFieldBehavior = .@"error",
    /// Wire shape assumed for `union(enum)` values.
    default_union_style: types.UnionStyle = .internal,
    /// Nesting limit; deeper documents fail instead of overflowing the stack.
    max_depth: usize = 256,
};

pub const EncodeError = error{
    WriteFailed,
    OutOfMemory,
    NonFiniteFloat,
    InvalidUtf8,
    InvalidEnumTag,
    Overflow,
};

/// Every failure the decoder can report. `scanner.ScanError` covers syntax, the rest are semantic
/// (a number too large for the field, an unknown enum tag, a duplicate key, …).
pub const DecodeError = scanner.ScanError || error{
    Overflow,
    InvalidNumber,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    InvalidBase64,
    InvalidHandle,
};

/// Holds a decoded value of type `T` along with the `ArenaAllocator` owning any decoded allocations.
/// Performs **zero heap allocations** when all strings are unescaped and borrowed (`allocate = .alloc_if_needed`).
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
// Compile-time Type Validation
// ============================================================================

/// Returns `null` when `T` may cross the Web/JSON boundary, or a human-readable reason why not.
///
/// This is the compile-time guard that keeps `usize`, `i64`, bare untagged unions and other
/// JavaScript-hostile types out of a command signature: `usize` is 64-bit on the host but a JS
/// `number` only holds 53 bits of integer, so a value would silently change. Use `u53` / `i53` /
/// `types.BigInt(T)` instead. Called from `assertValidRpcType` at every encode/decode entry point.
pub fn checkRpcType(comptime T: type) ?[]const u8 {
    return checkRpcTypeInner(T);
}

fn hasCustomJsonHook(comptime T: type) bool {
    return std.meta.hasFn(T, "jsonStringify") or
        std.meta.hasFn(T, "jsonParse") or
        std.meta.hasFn(T, "decodeZtsJson");
}

fn checkRpcTypeInner(comptime T: type) ?[]const u8 {
    if (T == usize or T == isize) {
        return "zts_rpc: Raw '" ++ @typeName(T) ++ "' is forbidden at the Web/JSON boundary because it is platform-dependent and exceeds IEEE 754 53-bit safe integer precision on 64-bit targets. Use 'u53' / 'i53' / 'SafeInt' for JS 'number', or 'zts_rpc.types.BigInt(" ++ @typeName(T) ++ ")' for JS 'bigint'.";
    }

    switch (@typeInfo(T)) {
        .bool, .void, .null, .@"enum", .enum_literal, .error_set, .float, .comptime_float, .comptime_int => return null,
        .int => |info| {
            if (info.bits > 53) {
                return "zts_rpc: Raw integer type '" ++ @typeName(T) ++ "' (> 53 bits) is forbidden at the Web/JSON boundary because JavaScript IEEE 754 numbers silently lose precision above 2^53 - 1. Use 'u53' / 'i53' / 'SafeInt' for JS 'number', or 'zts_rpc.types.BigInt(" ++ @typeName(T) ++ ")' for string-encoded JS 'bigint'.";
            }
            return null;
        },
        .optional => |opt| return checkRpcTypeInner(opt.child),
        .array => |arr| return checkRpcTypeInner(arr.child),
        .vector => |vec| return checkRpcTypeInner(vec.child),
        .pointer => |ptr| switch (ptr.size) {
            .one, .slice => return checkRpcTypeInner(ptr.child),
            else => return "zts_rpc: Unsupported pointer type '" ++ @typeName(T) ++ "'",
        },
        .@"struct" => |s| {
            if (comptime (types.isBigIntType(T) or T == types.SafeInt or T == types.Bytes or T == types.OsPath or types.isHandleType(T))) {
                return null;
            }
            if (comptime types.isTaggedUnionWrapper(T)) {
                return checkUnionType(T.InnerUnion, T.union_config);
            }
            // Custom wire types (e.g. `Channel(T)` carrying runtime `*anyopaque` / `usize` handles) manage their own JSON wire representation!
            if (comptime hasCustomJsonHook(T)) {
                return null;
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
            if (comptime hasCustomJsonHook(T)) {
                return null;
            }
            if (u.tag_type == null) {
                return "zts_rpc: Bare untagged union '" ++ @typeName(T) ++ "' cannot be serialized; use 'union(enum)' (with 'pub const json_union = .untagged' if untagged wire format is desired).";
            }
            return checkUnionType(T, comptime types.resolveUnionConfig(T, .internal));
        },
        else => return "zts_rpc: Unsupported type '" ++ @typeName(T) ++ "' at RPC boundary.",
    }
}

fn checkUnionType(comptime U: type, comptime cfg: types.UnionConfig) ?[]const u8 {
    const u = @typeInfo(U).@"union";
    inline for (u.field_names, u.field_types) |variant_name, PayloadType| {
        if (checkRpcTypeInner(PayloadType)) |err_msg| return err_msg;
        if (cfg.style == .internal and @typeInfo(PayloadType) == .@"struct" and !@typeInfo(PayloadType).@"struct".is_tuple) {
            if (!types.isBigIntType(PayloadType) and PayloadType != types.SafeInt and PayloadType != types.Bytes and
                PayloadType != types.OsPath and !types.isHandleType(PayloadType) and
                !types.isTaggedUnionWrapper(PayloadType) and !hasCustomJsonHook(PayloadType))
            {
                inline for (@typeInfo(PayloadType).@"struct".field_names) |f_name| {
                    if (comptime std.mem.eql(u8, naming.snakeToCamel(f_name), cfg.tag_field)) {
                        return "zts_rpc: Internally tagged union '" ++ @typeName(U) ++ "' variant '" ++ variant_name ++ "' has a field '" ++ f_name ++ "' that collides with union tag_field '" ++ cfg.tag_field ++ "'.";
                    }
                }
            }
        }
    }
    return null;
}

/// `true` when `checkRpcType(T) == null` — usable in `comptime if` to branch a generic API.
pub fn isValidRpcType(comptime T: type) bool {
    return checkRpcType(T) == null;
}

/// `@compileError`s with the explanation from `checkRpcType`. Called by every public encode/decode
/// function, so an invalid signature fails at the first instantiation rather than at runtime.
pub fn assertValidRpcType(comptime T: type) void {
    if (comptime checkRpcType(T)) |err_msg| @compileError(err_msg);
}

// ============================================================================
// Public Encode & Decode APIs
// ============================================================================

/// Encodes `value` as JSON into `writer`, using the default `EncodeOptions`.
pub fn encode(writer: *std.Io.Writer, value: anytype) EncodeError!void {
    return encodeWithOptions(writer, value, .{});
}

/// Same as `encode`, with explicit options. Validates the type at compile time.
pub fn encodeWithOptions(writer: *std.Io.Writer, value: anytype, options: EncodeOptions) EncodeError!void {
    comptime assertValidRpcType(@TypeOf(value));
    try encodeValue(writer, value, options);
}

/// Encodes `value` into a freshly allocated slice — the caller owns it and must free it with the
/// same allocator. Convenient for tests and for `completeRequest()` bodies.
pub fn encodeAlloc(allocator: Allocator, value: anytype) EncodeError![]u8 {
    return encodeAllocWithOptions(allocator, value, .{});
}

/// `encodeAlloc` with explicit options.
pub fn encodeAllocWithOptions(allocator: Allocator, value: anytype, options: EncodeOptions) EncodeError![]u8 {
    comptime assertValidRpcType(@TypeOf(value));
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    encodeValue(&aw.writer, value, options) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return aw.toOwnedSlice();
}

/// Decodes `input` into `T` and returns it inside a `Parsed(T)`, an arena that owns every string.
/// Call `parsed.deinit()`; the value must not outlive it. This is the form to use for a request.
pub fn decode(comptime T: type, allocator: Allocator, input: []const u8) DecodeError!Parsed(T) {
    return decodeWithOptions(T, allocator, input, .{});
}

/// `decode` with explicit options.
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
    return .{ .arena = arena, .value = val };
}

/// Decodes into `T` using `allocator` directly, without an arena. Every string in the result is a
/// separate allocation, so `T.deinit(allocator)` (or a manual walk) is required — prefer `decode`
/// unless you are decoding into an arena you already own.
pub fn decodeLeaky(comptime T: type, allocator: Allocator, input: []const u8) DecodeError!T {
    return decodeLeakyWithOptions(T, allocator, input, .{});
}

/// `decodeLeaky` with explicit options.
pub fn decodeLeakyWithOptions(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    options: DecodeOptions,
) DecodeError!T {
    comptime assertValidRpcType(T);
    var cursor = Cursor{ .input = input };
    const result = try decodeValue(T, allocator, &cursor, options);
    errdefer freeDecoded(T, allocator, result, input);
    cursor.skipWhitespace();
    if (cursor.pos != cursor.input.len) return error.SyntaxError;
    return result;
}

/// Frees any heap allocations inside `value` produced by `decodeLeaky`, safely skipping
/// zero-copy slices borrowed directly from `input`.
pub fn freeDecoded(comptime T: type, allocator: Allocator, value: T, input: []const u8) void {
    switch (@typeInfo(T)) {
        .optional => if (value) |payload| freeDecoded(@typeInfo(T).optional.child, allocator, payload, input),
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                freeDecoded(ptr.child, allocator, value.*, input);
                allocator.destroy(@constCast(value));
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
                    for (value) |elem| freeDecoded(ptr.child, allocator, elem, input);
                    if (value.len > 0) allocator.free(value);
                }
            },
            else => {},
        },
        .array => |arr| for (value) |elem| freeDecoded(arr.child, allocator, elem, input),
        .@"struct" => |s| {
            if (comptime (types.isBigIntType(T) or T == types.SafeInt or types.isHandleType(T))) return;
            if (comptime T == types.Bytes) {
                if (!isSliceInsideInput(value.data, input)) allocator.free(value.data);
                return;
            }
            if (comptime T == types.OsPath) {
                if (value.display.len > 0 and value.display.ptr != value.raw.ptr and !isSliceInsideInput(value.display, input)) {
                    allocator.free(value.display);
                }
                if (!isSliceInsideInput(value.raw, input)) allocator.free(value.raw);
                return;
            }
            if (comptime T == types.RawJson) {
                if (!std.mem.eql(u8, value.raw, "null") and !isSliceInsideInput(value.raw, input)) {
                    allocator.free(value.raw);
                }
                return;
            }
            if (comptime types.isTaggedUnionWrapper(T)) {
                freeDecoded(T.InnerUnion, allocator, value.value, input);
                return;
            }
            if (comptime hasCustomJsonHook(T)) return;
            inline for (s.field_names, s.field_types) |f_name, FType| {
                freeDecoded(FType, allocator, @field(value, f_name), input);
            }
        },
        .@"union" => |u| {
            if (comptime types.isPatchType(T)) {
                if (value == .value) freeDecoded(T.Child, allocator, value.value, input);
                return;
            }
            if (comptime hasCustomJsonHook(T)) return;
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
    return s_addr >= in_start and s_addr < in_start + input.len;
}

// ============================================================================
// Internal JSON Encoder Implementation
// ============================================================================

fn encodeValue(writer: *std.Io.Writer, value: anytype, options: EncodeOptions) EncodeError!void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .null, .void => try writer.writeAll("null"),
        .int => try writer.print("{d}", .{value}),
        .comptime_int => {
            if (value < types.min_safe_int or value > types.max_safe_int) {
                @compileError("zts_rpc: comptime_int exceeds IEEE 754 53-bit safe integer range");
            }
            try writer.print("{d}", .{@as(i64, value)});
        },
        .float, .comptime_float => {
            const f: f64 = @floatCast(value);
            if (!std.math.isFinite(f)) return error.NonFiniteFloat;
            try writer.print("{d}", .{if (f == 0.0) @as(f64, 0.0) else f});
        },
        .optional => if (value) |payload| try encodeValue(writer, payload, options) else try writer.writeAll("null"),
        .@"enum" => |enum_info| {
            if (enum_info.mode == .nonexhaustive) {
                inline for (enum_info.field_names) |f_name| {
                    if (value == @field(T, f_name)) {
                        try html_escape.writeJsonString(writer, f_name, options.html_safe);
                        return;
                    }
                }
                return error.InvalidEnumTag;
            }
            try html_escape.writeJsonString(writer, @tagName(value), options.html_safe);
        },
        .enum_literal => try html_escape.writeJsonString(writer, @tagName(value), options.html_safe),
        .error_set => try html_escape.writeJsonString(writer, @errorName(value), options.html_safe),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => switch (@typeInfo(ptr_info.child)) {
                .array => |arr_info| if (arr_info.child == u8) {
                    const slice: []const u8 = value[0..];
                    if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
                    try html_escape.writeJsonString(writer, slice, options.html_safe);
                } else try encodeSlice(writer, value[0..], options),
                else => try encodeValue(writer, value.*, options),
            },
            .slice => if (ptr_info.child == u8) {
                if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
                try html_escape.writeJsonString(writer, value, options.html_safe);
            } else try encodeSlice(writer, value, options),
            else => unreachable,
        },
        .array => try encodeSlice(writer, value[0..], options),
        .vector => |vec_info| {
            const arr: [vec_info.len]vec_info.child = value;
            try encodeSlice(writer, arr[0..], options);
        },
        .@"struct" => |s_info| {
            if (comptime T == types.SafeInt) {
                if (value.value < types.min_safe_int or value.value > types.max_safe_int) return error.Overflow;
                try writer.print("{d}", .{value.value});
                return;
            }
            if (comptime types.isHandleType(T)) {
                try writer.print("{d}", .{value.toU53()});
                return;
            }
            if (comptime types.isBigIntType(T)) {
                try writer.print("\"{d}\"", .{value.get()});
                return;
            }
            if (comptime T == types.Bytes) {
                switch (options.bytes_format) {
                    .base64 => {
                        try writer.writeByte('"');
                        try value.writeBase64(writer);
                        try writer.writeByte('"');
                    },
                    .array => try encodeSlice(writer, value.data, options),
                }
                return;
            }
            if (comptime T == types.OsPath) {
                try encodeOsPath(writer, value, options.html_safe);
                return;
            }
            if (comptime T == types.RawJson) {
                try writer.writeAll(if (value.raw.len == 0) "null" else value.raw);
                return;
            }
            if (comptime types.isTaggedUnionWrapper(T)) {
                try encodeUnion(writer, T.InnerUnion, value.value, T.union_config, options);
                return;
            }
            if (comptime std.meta.hasFn(T, "writeJson")) {
                try value.writeJson(writer);
                return;
            }
            if (comptime std.meta.hasFn(T, "jsonStringify")) {
                var jw: std.json.Stringify = .{ .writer = writer };
                value.jsonStringify(&jw) catch return error.WriteFailed;
                return;
            }
            if (s_info.is_tuple) {
                try writer.writeByte('[');
                inline for (s_info.field_names, 0..) |f_name, i| {
                    if (i > 0) try writer.writeByte(',');
                    try encodeValue(writer, @field(value, f_name), options);
                }
                try writer.writeByte(']');
                return;
            }
            try writer.writeByte('{');
            _ = try encodeStructFields(writer, T, value, options, false);
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
            if (comptime std.meta.hasFn(T, "jsonStringify")) {
                var jw: std.json.Stringify = .{ .writer = writer };
                value.jsonStringify(&jw) catch return error.WriteFailed;
                return;
            }
            try encodeUnion(writer, T, value, types.resolveUnionConfig(T, options.default_union_style), options);
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
    writer: *std.Io.Writer,
    comptime S: type,
    value: S,
    options: EncodeOptions,
    already_wrote_field: bool,
) EncodeError!bool {
    var wrote_any = already_wrote_field;
    const s_info = @typeInfo(S).@"struct";

    inline for (s_info.field_names, s_info.field_types) |f_name, FType| {
        if (comptime FType == void) continue;
        const field_val = @field(value, f_name);
        const wire_key = comptime naming.snakeToCamel(f_name);

        if (comptime types.isPatchType(FType)) {
            switch (field_val) {
                .unchanged => {},
                .null => {
                    if (wrote_any) try writer.writeByte(',');
                    try html_escape.writeJsonString(writer, wire_key, options.html_safe);
                    try writer.writeAll(":null");
                    wrote_any = true;
                },
                .value => |v| {
                    if (wrote_any) try writer.writeByte(',');
                    try html_escape.writeJsonString(writer, wire_key, options.html_safe);
                    try writer.writeByte(':');
                    try encodeValue(writer, v, options);
                    wrote_any = true;
                },
            }
        } else if (comptime @typeInfo(FType) == .optional) {
            if (field_val != null or options.emit_null_optional_fields) {
                if (wrote_any) try writer.writeByte(',');
                try html_escape.writeJsonString(writer, wire_key, options.html_safe);
                try writer.writeByte(':');
                try encodeValue(writer, field_val, options);
                wrote_any = true;
            }
        } else {
            if (wrote_any) try writer.writeByte(',');
            try html_escape.writeJsonString(writer, wire_key, options.html_safe);
            try writer.writeByte(':');
            try encodeValue(writer, field_val, options);
            wrote_any = true;
        }
    }
    return wrote_any;
}

fn encodeUnion(
    writer: *std.Io.Writer,
    comptime U: type,
    value: U,
    cfg: types.UnionConfig,
    options: EncodeOptions,
) EncodeError!void {
    const u_info = @typeInfo(U).@"union";
    const TagType = u_info.tag_type.?;
    const active_tag: TagType = value;

    inline for (u_info.field_names, u_info.field_types) |variant_name, PayloadType| {
        if (active_tag == @field(TagType, variant_name)) {
            const payload = @field(value, variant_name);
            switch (cfg.style) {
                .internal => {
                    try writer.writeByte('{');
                    try html_escape.writeJsonString(writer, cfg.tag_field, options.html_safe);
                    try writer.writeByte(':');
                    try html_escape.writeJsonString(writer, variant_name, options.html_safe);
                    if (PayloadType != void) {
                        if (@typeInfo(PayloadType) == .@"struct" and !@typeInfo(PayloadType).@"struct".is_tuple and
                            !types.isBigIntType(PayloadType) and PayloadType != types.SafeInt and
                            PayloadType != types.Bytes and PayloadType != types.OsPath and
                            !types.isHandleType(PayloadType) and !types.isTaggedUnionWrapper(PayloadType) and
                            !hasCustomJsonHook(PayloadType))
                        {
                            _ = try encodeStructFields(writer, PayloadType, payload, options, true);
                        } else {
                            try writer.writeByte(',');
                            try html_escape.writeJsonString(writer, cfg.content_field, options.html_safe);
                            try writer.writeByte(':');
                            try encodeValue(writer, payload, options);
                        }
                    }
                    try writer.writeByte('}');
                },
                .adjacent => {
                    try writer.writeByte('{');
                    try html_escape.writeJsonString(writer, cfg.tag_field, options.html_safe);
                    try writer.writeByte(':');
                    try html_escape.writeJsonString(writer, variant_name, options.html_safe);
                    if (PayloadType != void) {
                        try writer.writeByte(',');
                        try html_escape.writeJsonString(writer, cfg.content_field, options.html_safe);
                        try writer.writeByte(':');
                        try encodeValue(writer, payload, options);
                    }
                    try writer.writeByte('}');
                },
                .external => {
                    if (PayloadType == void) {
                        try html_escape.writeJsonString(writer, variant_name, options.html_safe);
                    } else {
                        try writer.writeByte('{');
                        try html_escape.writeJsonString(writer, variant_name, options.html_safe);
                        try writer.writeByte(':');
                        try encodeValue(writer, payload, options);
                        try writer.writeByte('}');
                    }
                },
                .untagged => try encodeValue(writer, payload, options),
            }
            return;
        }
    }
    unreachable;
}

fn encodeOsPath(writer: *std.Io.Writer, path: types.OsPath, html_safe: bool) EncodeError!void {
    if (std.unicode.utf8ValidateSlice(path.raw)) {
        try html_escape.writeJsonString(writer, path.raw, html_safe);
        return;
    }
    try writer.writeAll("{\"display\":");
    if (path.display.len > 0 and std.unicode.utf8ValidateSlice(path.display)) {
        try html_escape.writeJsonString(writer, path.display, html_safe);
    } else {
        try writeLossyJsonString(writer, path.raw, html_safe);
    }
    try writer.writeAll(",\"rawToken\":\"");
    try types.Bytes.init(path.raw).writeBase64(writer);
    try writer.writeAll("\"}");
}

fn writeLossyJsonString(writer: *std.Io.Writer, raw_bytes: []const u8, html_safe: bool) EncodeError!void {
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < raw_bytes.len) {
        const b = raw_bytes[i];
        if (b < 0x80) {
            switch (b) {
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
                0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{b}),
                else => try writer.writeByte(b),
            }
            i += 1;
            continue;
        }
        if (types.wtf8DecodeSurrogatePrefix(raw_bytes[i..])) |_| {
            try writer.writeAll(types.utf8_replacement_char);
            i += 3;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            try writer.writeAll(types.utf8_replacement_char);
            i += 1;
            continue;
        };
        if (i + seq_len > raw_bytes.len) {
            try writer.writeAll(types.utf8_replacement_char);
            break;
        }
        if (std.unicode.utf8Decode(raw_bytes[i .. i + seq_len])) |cp| {
            if (html_safe and (cp == 0x2028 or cp == 0x2029)) {
                try writer.writeAll(if (cp == 0x2028) "\\u2028" else "\\u2029");
            } else {
                try writer.writeAll(raw_bytes[i .. i + seq_len]);
            }
            i += seq_len;
        } else |_| {
            try writer.writeAll(types.utf8_replacement_char);
            i += 1;
        }
    }
    try writer.writeByte('"');
}

// ============================================================================
// Internal Zero-Allocation JSON Decoder Implementation
// ============================================================================

fn decodeValue(
    comptime T: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!T {
    switch (@typeInfo(T)) {
        .bool => return cursor.readBool(),
        .void, .null => {
            try cursor.readNull();
            return if (T == void) {} else null;
        },
        .int => return parseJsonInt(T, try cursor.readNumberToken()),
        .float => |float_info| {
            const tok = try cursor.readNumberToken();
            const f = std.fmt.parseFloat(f64, tok.slice) catch return error.InvalidNumber;
            if (!std.math.isFinite(f)) return error.NonFiniteFloat;
            if (float_info.bits == 32) {
                const f32_val: f32 = @floatCast(f);
                if (!std.math.isFinite(f32_val)) return error.NonFiniteFloat;
                return if (f32_val == 0.0) 0.0 else f32_val;
            }
            const cast_val: T = @floatCast(f);
            return if (cast_val == 0.0) 0.0 else cast_val;
        },
        .optional => |opt_info| {
            if (try cursor.peekKind() == .null) {
                cursor.pos += 4;
                if (cursor.pos > cursor.input.len or !std.mem.eql(u8, cursor.input[cursor.pos - 4 .. cursor.pos], "null")) {
                    cursor.pos -= 4;
                    try cursor.readNull();
                }
                return null;
            }
            return try decodeValue(opt_info.child, allocator, cursor, options);
        },
        .@"enum" => {
            const str_mode: StringDecodeMode = if (options.surrogate_policy == .replace_with_fffd) .lossy_utf8 else .strict_utf8;
            const decoded = try cursor.readString(allocator, .alloc_if_needed, str_mode);
            defer decoded.freeIfAllocated(allocator);
            return std.meta.stringToEnum(T, decoded.slice) orelse error.InvalidEnumTag;
        },
        .error_set => |err_info| {
            const str_mode: StringDecodeMode = if (options.surrogate_policy == .replace_with_fffd) .lossy_utf8 else .strict_utf8;
            const decoded = try cursor.readString(allocator, .alloc_if_needed, str_mode);
            defer decoded.freeIfAllocated(allocator);
            if (err_info) |errors| {
                inline for (errors) |e| {
                    if (std.mem.eql(u8, decoded.slice, e.name)) return @field(T, e.name);
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
                    if (ptr_info.sentinel()) |s| {
                        defer decoded.freeIfAllocated(allocator);
                        return try allocator.dupeSentinel(u8, decoded.slice, s);
                    }
                    if (!ptr_info.attrs.@"const") return @constCast(decoded.slice);
                    return decoded.slice;
                }
                return decodeSlice(T, ptr_info.child, allocator, cursor, options);
            },
            else => unreachable,
        },
        .array => |arr_info| return decodeFixedArray(arr_info.len, arr_info.child, allocator, cursor, options),
        .vector => |vec_info| return awaitVector(vec_info.len, vec_info.child, allocator, cursor, options),
        .@"struct" => |s_info| {
            if (comptime T == types.SafeInt) {
                const raw = try parseJsonInt(i64, try cursor.readNumberToken());
                return types.SafeInt.init(raw) catch error.Overflow;
            }
            if (comptime types.isHandleType(T)) {
                const raw = try parseJsonInt(u53, try cursor.readNumberToken());
                return T.fromU53(raw) catch error.InvalidHandle;
            }
            if (comptime types.isBigIntType(T)) {
                const decoded = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
                defer decoded.freeIfAllocated(allocator);
                return T.parseDecimalSlice(decoded.slice) catch |err| switch (err) {
                    error.Overflow => error.Overflow,
                    error.InvalidNumber => error.InvalidNumber,
                };
            }
            if (comptime T == types.Bytes) return decodeBytes(allocator, cursor, options);
            if (comptime T == types.OsPath) return decodeOsPath(allocator, cursor, options);
            if (comptime T == types.RawJson) {
                cursor.skipWhitespace();
                const start_pos = cursor.pos;
                try cursor.skipValue(options.max_depth);
                const slice = cursor.input[start_pos..cursor.pos];
                return .{ .raw = if (options.allocate == .alloc_always) try allocator.dupe(u8, slice) else slice };
            }
            if (comptime types.isTaggedUnionWrapper(T)) {
                return T.init(try decodeUnion(T.InnerUnion, allocator, cursor, T.union_config, options));
            }
            if (comptime std.meta.hasFn(T, "decodeZtsJson")) {
                cursor.skipWhitespace();
                const start_pos = cursor.pos;
                try cursor.skipValue(options.max_depth);
                return T.decodeZtsJson(allocator, cursor.input[start_pos..cursor.pos]);
            }
            if (comptime std.meta.hasFn(T, "jsonParse")) {
                return decodeCustomJsonParse(T, allocator, cursor, options);
            }
            if (s_info.is_tuple) return decodeTuple(T, allocator, cursor, options);
            return decodeStruct(T, allocator, cursor, options, null);
        },
        .@"union" => {
            if (comptime types.isPatchType(T)) {
                if (try cursor.peekKind() == .null) {
                    try cursor.readNull();
                    return .null;
                }
                return .{ .value = try decodeValue(T.Child, allocator, cursor, options) };
            }
            if (comptime std.meta.hasFn(T, "jsonParse")) {
                return decodeCustomJsonParse(T, allocator, cursor, options);
            }
            return decodeUnion(T, allocator, cursor, types.resolveUnionConfig(T, options.default_union_style), options);
        },
        else => unreachable,
    }
}

fn awaitVector(
    comptime len: usize,
    comptime Child: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!@Vector(len, Child) {
    const arr = try decodeFixedArray(len, Child, allocator, cursor, options);
    return arr;
}

fn parseJsonInt(comptime T: type, tok: scanner.NumberToken) DecodeError!T {
    if (!tok.is_float_syntax) {
        return std.fmt.parseInt(T, tok.slice, 10) catch |err| switch (err) {
            error.Overflow => error.Overflow,
            error.InvalidCharacter => error.InvalidNumber,
        };
    }
    const f = std.fmt.parseFloat(f64, tok.slice) catch return error.InvalidNumber;
    if (!std.math.isFinite(f)) return error.NonFiniteFloat;
    if (@trunc(f) != f) return error.InvalidNumber;
    if (f > @as(f64, @floatFromInt(std.math.maxInt(T))) or f < @as(f64, @floatFromInt(std.math.minInt(T)))) {
        return error.Overflow;
    }
    return @intFromFloat(f);
}

fn decodeCustomJsonParse(
    comptime T: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!T {
    const start_pos = cursor.pos;
    try cursor.skipValue(options.max_depth);
    const value_slice = cursor.input[start_pos..cursor.pos];

    var std_scanner = std.json.Scanner.initCompleteInput(allocator, value_slice);
    defer std_scanner.deinit();

    return T.jsonParse(allocator, &std_scanner, .{
        .allocate = options.allocate,
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .max_value_len = value_slice.len + 64,
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError => error.SyntaxError,
        error.UnexpectedEndOfInput => error.UnexpectedEndOfInput,
        error.Overflow => error.Overflow,
        error.InvalidNumber => error.InvalidNumber,
        error.InvalidEnumTag => error.InvalidEnumTag,
        error.DuplicateField => error.DuplicateField,
        error.UnknownField => error.UnknownField,
        error.MissingField => error.MissingField,
        error.LengthMismatch => error.LengthMismatch,
        else => error.UnexpectedToken,
    };
}

fn decodeSlice(
    comptime SliceType: type,
    comptime Child: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError!SliceType {
    const kind = try cursor.peekKind();
    if (kind != .array_begin) return if (kind == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
    try cursor.enterContainer(options.max_depth);
    defer cursor.leaveContainer();
    cursor.pos += 1;

    var list: std.ArrayList(Child) = .empty;
    errdefer {
        for (list.items) |elem| freeDecoded(Child, allocator, elem, cursor.input);
        list.deinit(allocator);
    }

    if (try cursor.peekKind() == .array_end) {
        cursor.pos += 1;
        return try list.toOwnedSlice(allocator);
    }

    while (true) {
        const elem = try decodeValue(Child, allocator, cursor, options);
        errdefer freeDecoded(Child, allocator, elem, cursor.input);
        try list.append(allocator, elem);

        cursor.skipWhitespace();
        if (cursor.pos >= cursor.input.len) return error.UnexpectedEndOfInput;
        switch (cursor.input[cursor.pos]) {
            ',' => cursor.pos += 1,
            ']' => {
                cursor.pos += 1;
                return try list.toOwnedSlice(allocator);
            },
            else => return error.SyntaxError,
        }
    }
}

fn decodeFixedArray(
    comptime len: usize,
    comptime Child: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
) DecodeError![len]Child {
    const kind = try cursor.peekKind();
    if (kind != .array_begin) return if (kind == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
    try cursor.enterContainer(options.max_depth);
    defer cursor.leaveContainer();
    cursor.pos += 1;

    var result: [len]Child = undefined;
    if (len == 0) {
        if (try cursor.peekKind() != .array_end) return error.LengthMismatch;
        cursor.pos += 1;
        return result;
    }
    if (try cursor.peekKind() == .array_end) return error.LengthMismatch;

    var initialized_count: usize = 0;
    errdefer for (0..initialized_count) |idx| freeDecoded(Child, allocator, result[idx], cursor.input);

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
    const kind = try cursor.peekKind();
    if (kind != .array_begin) return if (kind == .eof) error.UnexpectedEndOfInput else error.UnexpectedToken;
    try cursor.enterContainer(options.max_depth);
    defer cursor.leaveContainer();
    cursor.pos += 1;

    var result: TupleType = undefined;
    if (s_info.field_types.len == 0) {
        if (try cursor.peekKind() != .array_end) return error.LengthMismatch;
        cursor.pos += 1;
        return result;
    }
    if (try cursor.peekKind() == .array_end) return error.LengthMismatch;

    var fields_done: [s_info.field_types.len]bool = @splat(false);
    errdefer inline for (s_info.field_names, s_info.field_types, 0..) |f_name, FType, idx| {
        if (fields_done[idx]) freeDecoded(FType, allocator, @field(result, f_name), cursor.input);
    };

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
    return switch (try cursor.peekKind()) {
        .string => blk: {
            const str_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
            defer str_tok.freeIfAllocated(allocator);
            break :blk types.Bytes.decodeBase64Alloc(allocator, str_tok.slice) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidBase64,
            };
        },
        .array_begin => types.Bytes.init(try decodeSlice([]const u8, u8, allocator, cursor, options)),
        .eof => error.UnexpectedEndOfInput,
        else => error.UnexpectedToken,
    };
}

fn decodeOsPath(allocator: Allocator, cursor: *Cursor, options: DecodeOptions) DecodeError!types.OsPath {
    switch (try cursor.peekKind()) {
        .string => {
            const decoded = try cursor.readString(allocator, options.allocate, .wtf8);
            if (!decoded.had_wtf8_surrogate) return .{ .raw = decoded.slice, .display = decoded.slice };
            errdefer decoded.freeIfAllocated(allocator);
            return .{ .raw = decoded.slice, .display = try types.allocLossyUtf8(allocator, decoded.slice) };
        },
        .object_begin => {
            var obj = try cursor.beginObject(options.max_depth);
            defer cursor.leaveContainer();

            var display_tok: ?DecodedString = null;
            errdefer if (display_tok) |dt| dt.freeIfAllocated(allocator);
            var raw_token_opt: ?[]const u8 = null;
            errdefer if (raw_token_opt) |rt| if (!isSliceInsideInput(rt, cursor.input)) allocator.free(rt);
            var seen_display = false;
            var seen_raw_token = false;

            while (try obj.nextKey(allocator)) |key_tok| {
                defer key_tok.freeIfAllocated(allocator);

                if (std.mem.eql(u8, key_tok.slice, "display")) {
                    if (seen_display and options.duplicate_field_behavior == .@"error") return error.DuplicateField;
                    seen_display = true;
                    const d_tok = try cursor.readString(allocator, options.allocate, .strict_utf8);
                    if (display_tok == null) {
                        display_tok = d_tok;
                    } else if (options.duplicate_field_behavior == .use_last) {
                        display_tok.?.freeIfAllocated(allocator);
                        display_tok = d_tok;
                    } else d_tok.freeIfAllocated(allocator);
                } else if (std.mem.eql(u8, key_tok.slice, "rawToken") or std.mem.eql(u8, key_tok.slice, "raw_token")) {
                    if (seen_raw_token and options.duplicate_field_behavior == .@"error") return error.DuplicateField;
                    seen_raw_token = true;
                    if (try cursor.peekKind() == .null) {
                        try cursor.readNull();
                        if (raw_token_opt) |rt| if (options.duplicate_field_behavior == .use_last) {
                            if (!isSliceInsideInput(rt, cursor.input)) allocator.free(rt);
                            raw_token_opt = null;
                        };
                    } else {
                        const tok_str = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
                        defer tok_str.freeIfAllocated(allocator);
                        const decoded_raw = (types.Bytes.decodeBase64Alloc(allocator, tok_str.slice) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.InvalidBase64,
                        }).data;
                        if (raw_token_opt == null) {
                            raw_token_opt = decoded_raw;
                        } else if (options.duplicate_field_behavior == .use_last) {
                            if (!isSliceInsideInput(raw_token_opt.?, cursor.input)) allocator.free(raw_token_opt.?);
                            raw_token_opt = decoded_raw;
                        } else allocator.free(decoded_raw);
                    }
                } else if (options.ignore_unknown_fields) {
                    try cursor.skipValue(options.max_depth);
                } else return error.UnknownField;
            }

            const final_display = display_tok orelse return error.MissingField;
            return .{
                .raw = raw_token_opt orelse final_display.slice,
                .display = final_display.slice,
            };
        },
        .eof => return error.UnexpectedEndOfInput,
        else => return error.UnexpectedToken,
    }
}

fn decodeStruct(
    comptime S: type,
    allocator: Allocator,
    cursor: *Cursor,
    options: DecodeOptions,
    skip_tag_key: ?[]const u8,
) DecodeError!S {
    const s_info = @typeInfo(S).@"struct";
    var obj = try cursor.beginObject(options.max_depth);
    defer cursor.leaveContainer();

    var result: S = undefined;
    var fields_seen: [s_info.field_types.len]bool = @splat(false);
    var skip_tag_seen = false;

    errdefer inline for (s_info.field_names, s_info.field_types, 0..) |f_name, FType, idx| {
        if (fields_seen[idx]) freeDecoded(FType, allocator, @field(result, f_name), cursor.input);
    };

    while (try obj.nextKey(allocator)) |key_tok| {
        defer key_tok.freeIfAllocated(allocator);

        if (skip_tag_key) |tag_k| {
            if (std.mem.eql(u8, key_tok.slice, tag_k)) {
                if (skip_tag_seen and options.duplicate_field_behavior == .@"error") return error.DuplicateField;
                skip_tag_seen = true;
                try cursor.skipValue(options.max_depth);
                continue;
            }
        }

        var matched = false;
        inline for (s_info.field_names, s_info.field_types, 0..) |f_name, FType, idx| {
            if (!matched and naming.matchesFieldName(f_name, key_tok.slice, options.allow_snake_case_fallback)) {
                matched = true;
                if (fields_seen[idx]) {
                    switch (options.duplicate_field_behavior) {
                        .@"error" => return error.DuplicateField,
                        .use_first => try cursor.skipValue(options.max_depth),
                        .use_last => {
                            freeDecoded(FType, allocator, @field(result, f_name), cursor.input);
                            fields_seen[idx] = false;
                            @field(result, f_name) = try decodeValue(FType, allocator, cursor, options);
                            fields_seen[idx] = true;
                        },
                    }
                } else {
                    @field(result, f_name) = try decodeValue(FType, allocator, cursor, options);
                    fields_seen[idx] = true;
                }
            }
        }

        if (!matched) {
            if (options.ignore_unknown_fields) {
                try cursor.skipValue(options.max_depth);
            } else return error.UnknownField;
        }
    }

    inline for (s_info.field_names, s_info.field_types, s_info.field_attrs, 0..) |f_name, FType, f_attr, idx| {
        if (!fields_seen[idx]) {
            if (f_attr.defaultValue(FType)) |def_val| {
                @field(result, f_name) = def_val;
            } else if (comptime types.isPatchType(FType)) {
                @field(result, f_name) = .unchanged;
            } else return error.MissingField;
        }
    }
    return result;
}

fn findTagFieldInObject(
    allocator: Allocator,
    cursor: *Cursor,
    tag_field: []const u8,
    options: DecodeOptions,
) DecodeError!DecodedString {
    var obj = try cursor.beginObject(options.max_depth);
    defer cursor.leaveContainer();

    var found_tag: ?DecodedString = null;
    errdefer if (found_tag) |t| t.freeIfAllocated(allocator);

    while (try obj.nextKey(allocator)) |key_tok| {
        defer key_tok.freeIfAllocated(allocator);
        if (std.mem.eql(u8, key_tok.slice, tag_field)) {
            if (found_tag != null) {
                switch (options.duplicate_field_behavior) {
                    .@"error" => return error.DuplicateField,
                    .use_first => try cursor.skipValue(options.max_depth),
                    .use_last => {
                        found_tag.?.freeIfAllocated(allocator);
                        found_tag = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
                    },
                }
            } else {
                found_tag = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
            }
        } else {
            try cursor.skipValue(options.max_depth);
        }
    }
    return found_tag orelse error.MissingField;
}

fn decodeContentFieldObject(
    comptime PayloadType: type,
    allocator: Allocator,
    cursor: *Cursor,
    tag_field: []const u8,
    content_field: []const u8,
    options: DecodeOptions,
) DecodeError!PayloadType {
    var obj = try cursor.beginObject(options.max_depth);
    defer cursor.leaveContainer();

    var payload_val: ?PayloadType = null;
    errdefer if (payload_val) |pv| freeDecoded(PayloadType, allocator, pv, cursor.input);

    while (try obj.nextKey(allocator)) |key_tok| {
        defer key_tok.freeIfAllocated(allocator);
        if (std.mem.eql(u8, key_tok.slice, tag_field)) {
            try cursor.skipValue(options.max_depth);
        } else if (std.mem.eql(u8, key_tok.slice, content_field)) {
            if (payload_val != null) {
                switch (options.duplicate_field_behavior) {
                    .@"error" => return error.DuplicateField,
                    .use_first => try cursor.skipValue(options.max_depth),
                    .use_last => {
                        freeDecoded(PayloadType, allocator, payload_val.?, cursor.input);
                        payload_val = null;
                        payload_val = try decodeValue(PayloadType, allocator, cursor, options);
                    },
                }
            } else {
                payload_val = try decodeValue(PayloadType, allocator, cursor, options);
            }
        } else if (options.ignore_unknown_fields) {
            try cursor.skipValue(options.max_depth);
        } else return error.UnknownField;
    }
    return payload_val orelse error.MissingField;
}

fn consumeVoidVariantObject(
    allocator: Allocator,
    cursor: *Cursor,
    tag_field: []const u8,
    content_field: ?[]const u8,
    options: DecodeOptions,
) DecodeError!void {
    var obj = try cursor.beginObject(options.max_depth);
    defer cursor.leaveContainer();

    while (try obj.nextKey(allocator)) |key_tok| {
        defer key_tok.freeIfAllocated(allocator);
        if (std.mem.eql(u8, key_tok.slice, tag_field)) {
            try cursor.skipValue(options.max_depth);
        } else if (content_field != null and std.mem.eql(u8, key_tok.slice, content_field.?)) {
            try cursor.readNull();
        } else if (options.ignore_unknown_fields) {
            try cursor.skipValue(options.max_depth);
        } else return error.UnknownField;
    }
}

fn decodeUnion(
    comptime U: type,
    allocator: Allocator,
    cursor: *Cursor,
    cfg: types.UnionConfig,
    options: DecodeOptions,
) DecodeError!U {
    const u_info = @typeInfo(U).@"union";

    switch (cfg.style) {
        .internal => {
            const saved = cursor.*;
            var probe = saved;
            const tag_tok = try findTagFieldInObject(allocator, &probe, cfg.tag_field, options);
            defer tag_tok.freeIfAllocated(allocator);

            inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
                if (std.mem.eql(u8, tag_tok.slice, v_name)) {
                    cursor.* = saved;
                    if (PayloadType == void) {
                        try consumeVoidVariantObject(allocator, cursor, cfg.tag_field, null, options);
                        return @unionInit(U, v_name, {});
                    }
                    if (@typeInfo(PayloadType) == .@"struct" and !@typeInfo(PayloadType).@"struct".is_tuple and
                        !types.isBigIntType(PayloadType) and PayloadType != types.SafeInt and
                        PayloadType != types.Bytes and PayloadType != types.OsPath and
                        !types.isHandleType(PayloadType) and !types.isTaggedUnionWrapper(PayloadType) and
                        !hasCustomJsonHook(PayloadType))
                    {
                        return @unionInit(U, v_name, try decodeStruct(PayloadType, allocator, cursor, options, cfg.tag_field));
                    }
                    return @unionInit(U, v_name, try decodeContentFieldObject(PayloadType, allocator, cursor, cfg.tag_field, cfg.content_field, options));
                }
            }
            return error.InvalidEnumTag;
        },
        .adjacent => {
            const saved = cursor.*;
            var probe = saved;
            const tag_tok = try findTagFieldInObject(allocator, &probe, cfg.tag_field, options);
            defer tag_tok.freeIfAllocated(allocator);

            inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
                if (std.mem.eql(u8, tag_tok.slice, v_name)) {
                    cursor.* = saved;
                    if (PayloadType == void) {
                        try consumeVoidVariantObject(allocator, cursor, cfg.tag_field, cfg.content_field, options);
                        return @unionInit(U, v_name, {});
                    }
                    return @unionInit(U, v_name, try decodeContentFieldObject(PayloadType, allocator, cursor, cfg.tag_field, cfg.content_field, options));
                }
            }
            return error.InvalidEnumTag;
        },
        .external => {
            switch (try cursor.peekKind()) {
                .string => {
                    const tag_tok = try cursor.readString(allocator, .alloc_if_needed, .strict_utf8);
                    defer tag_tok.freeIfAllocated(allocator);
                    inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
                        if (PayloadType == void and std.mem.eql(u8, tag_tok.slice, v_name)) {
                            return @unionInit(U, v_name, {});
                        }
                    }
                    return error.InvalidEnumTag;
                },
                .object_begin => {
                    var obj = try cursor.beginObject(options.max_depth);
                    defer cursor.leaveContainer();

                    const key_tok = (try obj.nextKey(allocator)) orelse return error.MissingField;
                    defer key_tok.freeIfAllocated(allocator);

                    var decoded_union: ?U = null;
                    errdefer if (decoded_union) |du| freeDecoded(U, allocator, du, cursor.input);

                    inline for (u_info.field_names, u_info.field_types) |v_name, PayloadType| {
                        if (decoded_union == null and std.mem.eql(u8, key_tok.slice, v_name)) {
                            if (PayloadType == void) {
                                switch (try cursor.peekKind()) {
                                    .null => try cursor.readNull(),
                                    .object_begin => {
                                        var inner = try cursor.beginObject(options.max_depth);
                                        defer cursor.leaveContainer();
                                        if (try inner.nextKey(allocator)) |k| {
                                            k.freeIfAllocated(allocator);
                                            return error.UnexpectedToken;
                                        }
                                    },
                                    else => return error.UnexpectedToken,
                                }
                                decoded_union = @unionInit(U, v_name, {});
                            } else {
                                decoded_union = @unionInit(U, v_name, try decodeValue(PayloadType, allocator, cursor, options));
                            }
                        }
                    }
                    if (decoded_union == null) return error.InvalidEnumTag;

                    // Must be a single-key object `{ "<variant>": <payload> }`
                    if (try obj.nextKey(allocator)) |extra_k| {
                        extra_k.freeIfAllocated(allocator);
                        return error.SyntaxError;
                    }
                    return decoded_union.?;
                },
                .eof => return error.UnexpectedEndOfInput,
                else => return error.UnexpectedToken,
            }
        },
        .untagged => {
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
        },
    }
}

// ============================================================================
// Comprehensive Unit Tests
// ============================================================================

test "Boundary #1a: zero-copy string decoding (.alloc_if_needed) allocates 0 bytes on unescaped strings" {
    const UserMsg = struct {
        user_name: []const u8,
        greeting_text: []const u8,
        active: bool,
        retry_count: u16,
    };

    const json = "{\"userName\":\"umiturtle\",\"greetingText\":\"Hello, Z-Ts!\",\"active\":true,\"retryCount\":3}";

    const decoded = try decodeLeaky(UserMsg, testing.failing_allocator, json);
    try testing.expectEqualStrings("umiturtle", decoded.user_name);
    try testing.expectEqualStrings("Hello, Z-Ts!", decoded.greeting_text);
    try testing.expect(decoded.active);
    try testing.expectEqual(@as(u16, 3), decoded.retry_count);

    const json_start = @intFromPtr(json.ptr);
    try testing.expect(@intFromPtr(decoded.user_name.ptr) >= json_start and @intFromPtr(decoded.user_name.ptr) < json_start + json.len);

    const parsed = try decode(UserMsg, testing.failing_allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("umiturtle", parsed.value.user_name);
}

test "Boundary #1b: lone UTF-16 surrogates in JSON strings (reject, replace_with_fffd, and valid pairs)" {
    {
        const parsed = try decode([]const u8, testing.allocator, "\"launch \\uD83D\\uDE80!\"");
        defer parsed.deinit();
        try testing.expectEqualStrings("launch 🚀!", parsed.value);
    }

    try testing.expectError(error.LoneSurrogate, decode([]const u8, testing.allocator, "\"\\uD800\""));
    try testing.expectError(error.LoneSurrogate, decode([]const u8, testing.allocator, "\"\\uDC00\""));
    try testing.expectError(error.LoneSurrogate, decode([]const u8, testing.allocator, "\"prefix_\\uD800_suffix\""));
    try testing.expectError(error.LoneSurrogate, decode([]const u8, testing.allocator, "\"\\uDC00\\uD800\""));

    {
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

    const bad_utf8 = [_]u8{ 'a', 0xFF, 0xFE, 'b' };
    try testing.expectError(error.InvalidUtf8, encodeAlloc(testing.allocator, @as([]const u8, &bad_utf8)));
    const bad_json = [_]u8{ '"', 'a', 0xFF, '"' };
    try testing.expectError(error.InvalidUtf8, decode([]const u8, testing.allocator, &bad_json));
}

test "Boundary #1c: OsPath roundtrips valid UTF-8, non-UTF-8 POSIX bytes, and Windows WTF-8 surrogates losslessly" {
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

    {
        const raw_posix = "/tmp/icon_\xff\xfe\x80.png";
        const orig = types.OsPath.fromRawBorrowed(raw_posix);
        const json = try encodeAlloc(testing.allocator, orig);
        defer testing.allocator.free(json);
        try testing.expect(std.unicode.utf8ValidateSlice(json));

        const parsed = try decode(types.OsPath, testing.allocator, json);
        defer parsed.deinit();
        try testing.expectEqualSlices(u8, raw_posix, parsed.value.asSlice());
        try testing.expect(std.unicode.utf8ValidateSlice(parsed.value.display));
    }

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

    {
        const parsed = try decode(types.OsPath, testing.allocator, "\"C:\\\\dir\\\\unpaired_\\uD800.txt\"");
        defer parsed.deinit();
        const expected_wtf8 = "C:\\dir\\unpaired_" ++ [3]u8{ 0xED, 0xA0, 0x80 } ++ ".txt";
        try testing.expectEqualSlices(u8, expected_wtf8, parsed.value.asSlice());
        try testing.expectEqualStrings("C:\\dir\\unpaired_" ++ types.utf8_replacement_char ++ ".txt", parsed.value.display);
    }
}

test "Boundary #1d: Bytes roundtrips binary data via Base64 and via number array" {
    const raw_bin = [_]u8{ 0x00, 0x01, 0x02, 0x7F, 0x80, 0xFE, 0xFF };
    const payload = struct { id: u32, chunk: types.Bytes }{ .id = 7, .chunk = types.Bytes.init(&raw_bin) };

    {
        const json = try encodeAlloc(testing.allocator, payload);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("{\"id\":7,\"chunk\":\"AAECf4D+/w==\"}", json);

        const parsed = try decode(@TypeOf(payload), testing.allocator, json);
        defer parsed.deinit();
        try testing.expectEqualSlices(u8, &raw_bin, parsed.value.chunk.slice());
    }

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

    {
        const p1 = try decode(UpdateProfile, testing.failing_allocator, "{\"userId\":100}");
        defer p1.deinit();
        try testing.expect(p1.value.display_name == .unchanged and p1.value.bio == .unchanged and p1.value.age == .unchanged);

        const json1 = try encodeAlloc(testing.allocator, p1.value);
        defer testing.allocator.free(json1);
        try testing.expectEqualStrings("{\"userId\":100}", json1);
    }

    {
        const input = "{\"userId\":100,\"displayName\":\"Alice\",\"bio\":null}";
        const p2 = try decode(UpdateProfile, testing.failing_allocator, input);
        defer p2.deinit();
        try testing.expectEqualStrings("Alice", p2.value.display_name.getValue().?);
        try testing.expect(p2.value.bio == .null and p2.value.age == .unchanged);

        const json2 = try encodeAlloc(testing.allocator, p2.value);
        defer testing.allocator.free(json2);
        try testing.expectEqualStrings(input, json2);
    }

    const StrictOpts = struct { req_nullable: ?i32, opt_nullable: ?i32 = null, opt_with_default: i32 = 42 };
    try testing.expectError(error.MissingField, decode(StrictOpts, testing.allocator, "{}"));
    {
        const parsed = try decode(StrictOpts, testing.failing_allocator, "{\"reqNullable\":null}");
        defer parsed.deinit();
        try testing.expectEqual(@as(?i32, null), parsed.value.req_nullable);
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

    {
        const s_circle = Shape{ .circle = .{ .radius = 12.5 } };
        const json_circle = try encodeAlloc(testing.allocator, s_circle);
        defer testing.allocator.free(json_circle);
        try testing.expectEqualStrings("{\"kind\":\"circle\",\"radius\":12.5}", json_circle);

        const d_circle = try decode(Shape, testing.failing_allocator, json_circle);
        try testing.expectEqual(@as(f64, 12.5), d_circle.value.circle.radius);

        const d_rect = try decode(Shape, testing.failing_allocator, "{\"width\":100,\"height\":200,\"kind\":\"rect\"}");
        try testing.expectEqual(@as(f64, 100), d_rect.value.rect.width);
        try testing.expectEqual(@as(u16, 1), d_rect.value.rect.border_width);

        const json_point = try encodeAlloc(testing.allocator, @as(Shape, .point));
        defer testing.allocator.free(json_point);
        try testing.expectEqualStrings("{\"kind\":\"point\"}", json_point);
        try testing.expect((try decode(Shape, testing.failing_allocator, json_point)).value == .point);

        const json_label = try encodeAlloc(testing.allocator, Shape{ .label = "center" });
        defer testing.allocator.free(json_label);
        try testing.expectEqualStrings("{\"kind\":\"label\",\"value\":\"center\"}", json_label);
        try testing.expectEqualStrings("center", (try decode(Shape, testing.failing_allocator, json_label)).value.label);
    }

    {
        const AdjacentShape = types.TaggedUnion(Shape, .{ .style = .adjacent, .tag_field = "type", .content_field = "data" });
        const json = try encodeAlloc(testing.allocator, AdjacentShape.init(.{ .circle = .{ .radius = 5.0 } }));
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("{\"type\":\"circle\",\"data\":{\"radius\":5}}", json);
        try testing.expectEqual(@as(f64, 9.0), (try decode(AdjacentShape, testing.failing_allocator, "{\"data\":{\"radius\":9},\"type\":\"circle\"}")).value.get().circle.radius);
    }

    {
        const ExternalShape = types.TaggedUnion(Shape, .{ .style = .external });
        const json = try encodeAlloc(testing.allocator, ExternalShape.init(.{ .circle = .{ .radius = 8.0 } }));
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("{\"circle\":{\"radius\":8}}", json);
        try testing.expectEqual(@as(f64, 8.0), (try decode(ExternalShape, testing.failing_allocator, json)).value.get().circle.radius);

        const json_pt = try encodeAlloc(testing.allocator, ExternalShape.init(.point));
        defer testing.allocator.free(json_pt);
        try testing.expectEqualStrings("\"point\"", json_pt);
        try testing.expect((try decode(ExternalShape, testing.failing_allocator, json_pt)).value.get() == .point);
    }

    {
        const CssSize = union(enum) {
            px: f64,
            keyword: []const u8,
            flag: bool,
            pub const json_union = types.UnionStyle.untagged;
        };
        try testing.expectEqual(@as(f64, 42.0), (try decode(CssSize, testing.failing_allocator, "42")).value.px);
        try testing.expectEqualStrings("42", (try decode(CssSize, testing.failing_allocator, "\"42\"")).value.keyword);
        try testing.expectEqual(true, (try decode(CssSize, testing.failing_allocator, "true")).value.flag);
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
    try testing.expectEqualStrings("Close window", parsed.value.@"aria-label");
    try testing.expectEqualStrings("#1a1a1a", parsed.value.@"--theme-bg");
}

test "Boundary #5: NaN and +-Infinity are strictly rejected on both encode and decode" {
    const Metrics = struct { fps: f64, scale: f32 = 1.0 };

    try testing.expectError(error.NonFiniteFloat, encodeAlloc(testing.allocator, std.math.nan(f64)));
    try testing.expectError(error.NonFiniteFloat, encodeAlloc(testing.allocator, std.math.inf(f64)));
    try testing.expectError(error.NonFiniteFloat, encodeAlloc(testing.allocator, -std.math.inf(f64)));
    try testing.expectError(error.NonFiniteFloat, encodeAlloc(testing.allocator, Metrics{ .fps = 60.0, .scale = std.math.nan(f32) }));

    try testing.expectError(error.NonFiniteFloat, decode(f64, testing.allocator, "NaN"));
    try testing.expectError(error.NonFiniteFloat, decode(f64, testing.allocator, "Infinity"));
    try testing.expectError(error.NonFiniteFloat, decode(f64, testing.allocator, "-Infinity"));
    try testing.expectError(error.NonFiniteFloat, decode(f64, testing.allocator, "1e500"));
    try testing.expectError(error.NonFiniteFloat, decode(f32, testing.allocator, "1e50"));
    try testing.expectError(error.UnexpectedToken, decode(f64, testing.allocator, "null"));
}

test "Boundary #6 (53-bit integer guard & BigInt): compile-time rejection of raw i64/u64/usize and BigInt roundtrip" {
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

    try testing.expect(isValidRpcType(i53));
    try testing.expect(isValidRpcType(u53));
    try testing.expect(isValidRpcType(types.SafeInt));
    try testing.expect(isValidRpcType(types.BigInt(i64)));
    try testing.expect(isValidRpcType(types.BigInt(u64)));
    try testing.expect(isValidRpcType(types.BigInt(i128)));

    {
        const max_u53: u53 = std.math.maxInt(u53);
        const json = try encodeAlloc(testing.allocator, max_u53);
        defer testing.allocator.free(json);
        try testing.expectEqualStrings("9007199254740991", json);
        try testing.expectEqual(max_u53, (try decode(u53, testing.failing_allocator, json)).value);
        try testing.expectError(error.Overflow, decode(u53, testing.allocator, "9007199254740992"));
    }

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
        const parsed = try decode(LedgerEntry, testing.failing_allocator, json);
        try testing.expect(entry.tx_id.eql(parsed.value.tx_id));
        try testing.expect(entry.balance_delta.eql(parsed.value.balance_delta));
        try testing.expect(entry.huge_nonce.eql(parsed.value.huge_nonce));
        try testing.expectError(error.UnexpectedToken, decode(types.BigInt(i64), testing.allocator, "9007199254740993"));
    }
}

test "Boundary #8 & #9 & #10: HTML-safe JSON escaping, Enum string literals, and unified Handle(.window) roundtrip" {
    const WindowHandle = core.Handle(.window);
    // Compile-time proof that `types.Handle(.window)` and `foundation.Handle(.window)` are the EXACT same Zig type!
    comptime std.debug.assert(types.Handle(.window) == WindowHandle);

    const Theme = enum { light, dark, high_contrast };
    const NonExhaustiveAction = enum(u8) { open = 1, close = 2, _ };

    const Payload = struct {
        window: WindowHandle,
        theme: Theme,
        action: NonExhaustiveAction,
        signed_safe: types.SafeInt,
        xss_snippet: []const u8,
    };

    const orig = Payload{
        .window = .{ .index = 42, .generation = 7 },
        .theme = .high_contrast,
        .action = .open,
        .signed_safe = try types.SafeInt.init(-9007199254740991),
        .xss_snippet = "</script><script>alert(1)&</script>\u{2028}\u{2029}",
    };

    const html_safe_json = try encodeAllocWithOptions(testing.allocator, orig, .{ .html_safe = true });
    defer testing.allocator.free(html_safe_json);

    try testing.expect(std.mem.indexOf(u8, html_safe_json, "</script>") == null);
    try testing.expect(std.mem.indexOf(u8, html_safe_json, "\\u003c/script\\u003e") != null);
    try testing.expect(std.mem.indexOf(u8, html_safe_json, "\\u0026") != null);
    try testing.expect(std.mem.indexOf(u8, html_safe_json, "\\u2028\\u2029") != null);

    // Unnamed/unknown non-exhaustive enum integer tag is safely rejected with error.InvalidEnumTag
    try testing.expectError(error.InvalidEnumTag, encodeAlloc(testing.allocator, @as(NonExhaustiveAction, @fromBackingInt(@intCast(99)))));

    // Invalid generation-0 handle & out-of-range SafeInt are rejected on decode
    try testing.expectError(error.InvalidHandle, decode(WindowHandle, testing.failing_allocator, "0"));
    try testing.expectError(error.Overflow, decode(types.SafeInt, testing.failing_allocator, "-9007199254740992"));

    const parsed = try decode(Payload, testing.allocator, html_safe_json);
    defer parsed.deinit();
    try testing.expect(orig.window.eql(parsed.value.window));
    try testing.expectEqual(Theme.high_contrast, parsed.value.theme);
    try testing.expectEqual(NonExhaustiveAction.open, parsed.value.action);
    try testing.expectEqual(@as(i64, -9007199254740991), parsed.value.signed_safe.get());
    try testing.expectEqualStrings(orig.xss_snippet, parsed.value.xss_snippet);
}

test "Error handling: duplicate fields, unknown fields, trailing garbage, and allocation failure" {
    const Item = struct { item_id: u32, tags: []const []const u8 };

    try testing.expectError(error.UnknownField, decode(Item, testing.allocator, "{\"itemId\":1,\"tags\":[],\"extra\":[1,2,{\"nested\":true}]}"));
    {
        const p = try decodeWithOptions(Item, testing.allocator, "{\"itemId\":1,\"extra\":[1,2,{\"nested\":true}],\"tags\":[\"a\",\"b\"]}", .{ .ignore_unknown_fields = true });
        defer p.deinit();
        try testing.expectEqual(@as(usize, 2), p.value.tags.len);
    }

    try testing.expectError(error.DuplicateField, decode(Item, testing.allocator, "{\"itemId\":1,\"itemId\":2,\"tags\":[]}"));
    try testing.expectError(error.SyntaxError, decode(u32, testing.allocator, "42 trailing"));

    const alloc_test_fn = struct {
        fn run(gpa: Allocator) !void {
            const p = try decode(Item, gpa, "{\"itemId\":99,\"tags\":[\"escaped\\nstr\",\"second\\tstr\"]}");
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

    const input = "{\"label\":\"line1\\nline2\",\"keyCode\":27}";
    const ev = try decodeLeaky(UntaggedEvent, testing.allocator, input);
    defer freeDecoded(UntaggedEvent, testing.allocator, ev, input);

    try testing.expect(ev == .keyboard);
    try testing.expectEqualStrings("line1\nline2", ev.keyboard.label);

    const bad_input = "{\"label\":\"escaped\\tallocated\",\"x\":\"not_an_int\",\"y\":0}";
    try testing.expectError(error.UnexpectedToken, decodeLeaky(UntaggedEvent, testing.allocator, bad_input));
}

test "Custom jsonParse/jsonStringify hooks allow internal runtime pointers & usize fields (Channel compatibility)" {
    const StatefulChannel = struct {
        id: u53,
        // Internal runtime-only fields (`?*anyopaque`, `usize`) must NOT trigger checkRpcType errors!
        host_ctx: ?*anyopaque = null,
        seq_counter: usize = 0,

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
                .number, .allocated_number => |s| return .{ .id = std.fmt.parseInt(u53, s, 10) catch return error.InvalidNumber },
                .string, .allocated_string => |s| {
                    const prefix = "__CHANNEL__:";
                    if (!std.mem.startsWith(u8, s, prefix)) return error.UnexpectedToken;
                    return .{ .id = std.fmt.parseInt(u53, s[prefix.len..], 10) catch return error.InvalidNumber };
                },
                else => return error.UnexpectedToken,
            }
        }
    };

    const CmdArgs = struct { on_progress: StatefulChannel };

    {
        const p = try decode(CmdArgs, testing.allocator, "{\"onProgress\":\"__CHANNEL__:42\"}");
        defer p.deinit();
        try testing.expectEqual(@as(u53, 42), p.value.on_progress.id);

        const encoded = try encodeAlloc(testing.allocator, p.value);
        defer testing.allocator.free(encoded);
        try testing.expectEqualStrings("{\"onProgress\":\"__CHANNEL__:42\"}", encoded);
    }

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
    try testing.expectEqualStrings("{\"coords\":[10,20,30],\"pair\":[\"ok\",true],\"vec\":[0,3.5],\"cStr\":\"hello\"}", json);

    const parsed = try decode(Complex, testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualSlices(i32, &orig.coords, &parsed.value.coords);
    try testing.expectEqualStrings("ok", parsed.value.pair[0]);
    try testing.expectEqualStrings("hello", parsed.value.c_str);
    try testing.expectEqual(@as(u8, 0), parsed.value.c_str[parsed.value.c_str.len]);

    try testing.expectError(error.LengthMismatch, decode([3]i32, testing.allocator, "[1,2]"));
    try testing.expectError(error.LengthMismatch, decode([3]i32, testing.allocator, "[1,2,3,4]"));
    try testing.expectError(error.MaxDepthExceeded, decodeWithOptions([]const []const []const u8, testing.allocator, "[[\"deep\"]]", .{ .max_depth = 1 }));

    const CollidingUnion = union(enum) { bad: struct { kind: []const u8 } };
    try testing.expect(!isValidRpcType(CollidingUnion));
}
