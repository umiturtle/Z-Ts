//! `zts_rpc` — Type-Safe Web ⇔ Zig JSON Codec, Wire Wrapper Types & Naming Rules (`link_libc = false`).
//!
//! Built directly atop `zts_core` (`Handle(Tag)` nominal identity + `html_escape` XSS-safe string streaming).
//! Ready for `M1-04` (`schema.zig` / `tsgen.zig`) to plug in cleanly without touching existing files.

pub const codec = @import("codec.zig");
pub const naming = @import("naming.zig");
pub const scanner = @import("scanner.zig");
pub const types = @import("types.zig");

// Top-level ergonomic type & codec re-exports
pub const BigInt = types.BigInt;
pub const Bytes = types.Bytes;
pub const Handle = types.Handle;
pub const OsPath = types.OsPath;
pub const Patch = types.Patch;
pub const SafeInt = types.SafeInt;
pub const TaggedUnion = types.TaggedUnion;
pub const UnionConfig = types.UnionConfig;
pub const UnionStyle = types.UnionStyle;

pub const BytesFormat = codec.BytesFormat;
pub const DecodeError = codec.DecodeError;
pub const DecodeOptions = codec.DecodeOptions;
pub const DuplicateFieldBehavior = codec.DuplicateFieldBehavior;
pub const EncodeError = codec.EncodeError;
pub const EncodeOptions = codec.EncodeOptions;
pub const Parsed = codec.Parsed;
pub const SurrogatePolicy = codec.SurrogatePolicy;

pub const assertValidRpcType = codec.assertValidRpcType;
pub const checkRpcType = codec.checkRpcType;
pub const decode = codec.decode;
pub const decodeLeaky = codec.decodeLeaky;
pub const decodeLeakyWithOptions = codec.decodeLeakyWithOptions;
pub const decodeWithOptions = codec.decodeWithOptions;
pub const encode = codec.encode;
pub const encodeAlloc = codec.encodeAlloc;
pub const encodeAllocWithOptions = codec.encodeAllocWithOptions;
pub const encodeWithOptions = codec.encodeWithOptions;
pub const freeDecoded = codec.freeDecoded;
pub const isValidRpcType = codec.isValidRpcType;

test {
    _ = codec;
    _ = naming;
    _ = scanner;
    _ = types;
}
