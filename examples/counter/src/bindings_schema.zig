//! `M5-01`: the schema handed to the `bindings.gen.ts` generator.
//!
//! `zig build tsgen` builds a tiny generator binary from this file (through
//! `src/build_tools/tsgen_main.zig`) and writes `examples/counter/web/bindings.gen.ts`.
//! The whole `.ts` module is materialised at `comptime` by `zts_rpc.tsgen`, so this file is
//! only the "which schema" declaration.

const app = @import("app.zig");

pub const Schema = app.App(.desktop).Schema;
