//! `zts_rpc` — Standalone `comptime` RPC Router, Type-Safe JSON Codec & TypeScript Generator (`link_libc = false`).
//!
//! Exports the full RPC layer (`M1-03` + `M1-04`) built cleanly atop `zts_core`:
//! - `Schema` / `merge` & `bind`: Zero-overhead `comptime` multi-namespace router composition.
//! - `Ctx` & `Handler`: Platform-independent per-call context & 2-word fat-pointer dispatcher.
//! - `tsgen`: Strict TypeScript bindings & client generator (`--strict --exactOptionalPropertyTypes --erasableSyntaxOnly`).
//! - `codec` / `types` / `naming`: 53-bit safe integer guard, zero-copy string borrowing, `BigInt`, `Bytes`, `OsPath`, `Patch`, `Handle`.

pub const codec = @import("codec.zig");
pub const ctx = @import("ctx.zig");
pub const naming = @import("naming.zig");
pub const scanner = @import("scanner.zig");
pub const schema = @import("schema.zig");
pub const tsgen = @import("tsgen.zig");
pub const types = @import("types.zig");

// Router & Context types (`M1-04`)
pub const AuthorizeFn = ctx.AuthorizeFn;
pub const CommandMeta = schema.CommandMeta;
pub const Ctx = ctx.Ctx;
pub const Handler = ctx.Handler;
pub const NamespaceMeta = schema.NamespaceMeta;
pub const Responses = ctx.Responses;
pub const Schema = schema.Schema;
pub const merge = schema.merge;

// Boundary Wrapper Types (`M1-03`)
pub const BigInt = types.BigInt;
pub const Bytes = types.Bytes;
pub const Handle = types.Handle;
pub const OsPath = types.OsPath;
pub const Patch = types.Patch;
pub const SafeInt = types.SafeInt;
pub const TaggedUnion = types.TaggedUnion;
pub const UnionConfig = types.UnionConfig;
pub const UnionStyle = types.UnionStyle;

// Codec Options & Functions (`M1-03`)
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
    _ = ctx;
    _ = naming;
    _ = scanner;
    _ = schema;
    _ = tsgen;
    _ = types;
}
