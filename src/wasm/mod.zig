//! `zts_wasm` — Standalone WebAssembly Isomorphic Runtime (`link_libc = false`).
//!
//! Enables compiling ANY Z-Ts application (`rpc.Schema` + `zts_tauri` plugins) directly to
//! `wasm32-freestanding` with zero application source modifications.

pub const host = @import("host.zig");
pub const io_stub = @import("io_stub.zig");
pub const js_bootstrap = @import("js_bootstrap.zig");
pub const runtime = @import("runtime.zig");

pub const EvalHook = host.EvalHook;
pub const Instance = runtime.Instance;
pub const ResponseKind = runtime.ResponseKind;
pub const WasmBootstrapOptions = js_bootstrap.WasmBootstrapOptions;
pub const WasmHost = host.WasmHost;
pub const exportApp = runtime.exportApp;
pub const wasmIo = io_stub.wasmIo;

test {
    _ = host;
    _ = io_stub;
    _ = js_bootstrap;
    _ = runtime;
}
