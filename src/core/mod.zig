//! `zts_core` — Desktop Framework Core & Re-Exports of Standalone Packages (`link_libc = false`).
//!
//! Aggregates:
//! - `foundation` (`zts_foundation`): Pure domain-independent data structures (`OwnedBytes`, `HandlePool`, `RingQueue`, `geometry`, `glob`).
//! - `web` (`zts_web`): Embedded asset server, HTTP `206` Range seeking, MIME, URL normalization & CSP.
//! - `host`: Platform-independent Desktop Window/WebView `Host` VTable & `RecordingHost` spy.

pub const foundation = @import("zts_foundation");
pub const web = @import("zts_web");
pub const host = @import("host.zig");

pub const assets = web.assets;
pub const csp = web.csp;
pub const geometry = foundation.geometry;
pub const glob = foundation.glob;
pub const handle_pool = foundation.handle_pool;
pub const html_escape = foundation.html_escape;
pub const http_range = web.http_range;
pub const mime = web.mime;
pub const owned_bytes = foundation.owned_bytes;
pub const queue = foundation.queue;
pub const response = foundation.response;
pub const url = foundation.url;

// Top-level ergonomic type re-exports (M1-01)
pub const MAX_JS_SAFE_INT = foundation.MAX_JS_SAFE_INT;
pub const Handle = foundation.Handle;
pub const HandleError = foundation.HandleError;
pub const HandlePool = foundation.HandlePool;

pub const OwnedBytes = foundation.OwnedBytes;

pub const QueueError = foundation.QueueError;
pub const RingQueue = foundation.RingQueue;

pub const Color = foundation.Color;
pub const GeometryError = foundation.GeometryError;
pub const LogicalPoint = foundation.LogicalPoint;
pub const LogicalPx = foundation.LogicalPx;
pub const LogicalRect = foundation.LogicalRect;
pub const LogicalSize = foundation.LogicalSize;
pub const PhysicalPoint = foundation.PhysicalPoint;
pub const PhysicalPx = foundation.PhysicalPx;
pub const PhysicalRect = foundation.PhysicalRect;
pub const PhysicalSize = foundation.PhysicalSize;
pub const ScaleFactor = foundation.ScaleFactor;

pub const CallContext = host.CallContext;
pub const Host = host.Host;
pub const HostError = host.HostError;
pub const IpcStatus = foundation.IpcStatus;
pub const OutgoingResponse = foundation.OutgoingResponse;
pub const RecordingHost = host.RecordingHost;
pub const RequestId = host.RequestId;
pub const StepMode = host.StepMode;
pub const WindowId = host.WindowId;
pub const WindowSpec = host.WindowSpec;
pub const WindowTheme = host.WindowTheme;

// Top-level ergonomic type re-exports (M1-02)
pub const AssetResponse = web.AssetResponse;
pub const AssetStatus = web.AssetStatus;
pub const Assets = web.Assets;
pub const FallbackLoader = web.FallbackLoader;
pub const ResolveOptions = web.ResolveOptions;
pub const StaticAsset = web.StaticAsset;

pub const ByteRange = web.ByteRange;
pub const RangeEval = web.RangeEval;
pub const ParsedUrl = foundation.ParsedUrl;
pub const UrlError = foundation.UrlError;

test {
    _ = host;
}
