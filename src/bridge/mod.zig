//! `zts_bridge` — Standalone HTTP/1.1 + RPC + Server-Sent Events Transport (`link_libc = false`).
//!
//! Exports `BridgeServer` and its cryptographic CSRF defense, SSE broker, and HTML `<head>`
//! bootstrap script generator without pulling in any OS GUI / WebView dependencies:
//! - Serves `zts_web.Assets` (`200 OK`, SPA routing, `206 Partial Content` media seeking, `416`, `404`).
//! - Dispatches `POST /__zts_ipc__/<cmd>` into `zts_rpc.Handler` guarded by 3 independent secrets/checks
//!   (`HttpOnly; SameSite=Strict` 256-bit cookie + 256-bit `Tauri-Invoke-Key` + strict `Origin` match).
//! - Streams live server -> client `emit` / `eval` / `window` / custom events over `GET /__zts_events__`.

pub const auth = @import("auth.zig");
pub const js_init = @import("js_init.zig");
pub const server = @import("server.zig");
pub const sse = @import("sse.zig");

pub const BridgeServer = server.BridgeServer;
pub const Config = server.Config;
pub const OriginPolicy = auth.OriginPolicy;
pub const SecurityState = auth.SecurityState;
pub const SseHub = sse.SseHub;

test {
    _ = auth;
    _ = js_init;
    _ = server;
    _ = sse;
}
