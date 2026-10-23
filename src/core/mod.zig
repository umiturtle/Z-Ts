//! `zts_core` — Zero-Dependency Pure Zig Primitives & Platform Contracts (`link_libc = false`).
//!
//! Exports foundational data structures and Web/security engines shared across `zts_rpc`,
//! `zts_webview`, `zts_bridge`, and `zts_tauri` without pulling in any OS GUI libraries or libc.

pub const assets = @import("assets.zig");
pub const csp = @import("csp.zig");
pub const geometry = @import("geometry.zig");
pub const glob = @import("glob.zig");
pub const handle_pool = @import("handle_pool.zig");
pub const host = @import("host.zig");
pub const html_escape = @import("html_escape.zig");
pub const http_range = @import("http_range.zig");
pub const mime = @import("mime.zig");
pub const owned_bytes = @import("owned_bytes.zig");
pub const queue = @import("queue.zig");
pub const url = @import("url.zig");

// Top-level ergonomic type re-exports (M1-01)
pub const MAX_JS_SAFE_INT = handle_pool.MAX_JS_SAFE_INT;
pub const Handle = handle_pool.Handle;
pub const HandleError = handle_pool.HandleError;
pub const HandlePool = handle_pool.HandlePool;

pub const OwnedBytes = owned_bytes.OwnedBytes;

pub const QueueError = queue.QueueError;
pub const RingQueue = queue.RingQueue;

pub const Color = geometry.Color;
pub const GeometryError = geometry.GeometryError;
pub const LogicalPoint = geometry.LogicalPoint;
pub const LogicalPx = geometry.LogicalPx;
pub const LogicalRect = geometry.LogicalRect;
pub const LogicalSize = geometry.LogicalSize;
pub const PhysicalPoint = geometry.PhysicalPoint;
pub const PhysicalPx = geometry.PhysicalPx;
pub const PhysicalRect = geometry.PhysicalRect;
pub const PhysicalSize = geometry.PhysicalSize;
pub const ScaleFactor = geometry.ScaleFactor;

pub const Host = host.Host;
pub const HostError = host.HostError;
pub const IpcStatus = host.IpcStatus;
pub const OutgoingResponse = host.OutgoingResponse;
pub const RecordingHost = host.RecordingHost;
pub const RequestId = host.RequestId;
pub const StepMode = host.StepMode;
pub const WindowId = host.WindowId;
pub const WindowSpec = host.WindowSpec;
pub const WindowTheme = host.WindowTheme;

// Top-level ergonomic type re-exports (M1-02)
pub const AssetResponse = assets.AssetResponse;
pub const AssetStatus = assets.AssetStatus;
pub const Assets = assets.Assets;
pub const FallbackLoader = assets.FallbackLoader;
pub const ResolveOptions = assets.ResolveOptions;
pub const StaticAsset = assets.StaticAsset;

pub const ByteRange = http_range.ByteRange;
pub const RangeEval = http_range.RangeEval;
pub const ParsedUrl = url.ParsedUrl;
pub const UrlError = url.UrlError;

test {
    _ = assets;
    _ = csp;
    _ = geometry;
    _ = glob;
    _ = handle_pool;
    _ = host;
    _ = html_escape;
    _ = http_range;
    _ = mime;
    _ = owned_bytes;
    _ = queue;
    _ = url;
}
