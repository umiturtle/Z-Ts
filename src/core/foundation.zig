//! `zts_foundation` — Standalone Zero-Dependency Runtime Primitives (`link_libc = false`).
//!
//! Contains pure, domain-independent data structures reusable across any Zig project
//! (engines, media/streaming tools, servers, CLI tools, and desktop frameworks)
//! with **zero dependency on WebViews, windowing VTables, or HTTP routing**:
//! - `OwnedBytes` & `OutgoingResponse`: Zero-copy static / heap / foreign-callback byte buffers.
//! - `Handle(Tag)` & `HandlePool(T, Tag)`: 53-bit ABA-safe generational slot map (`O(1)`).
//! - `RingQueue(T)`: Multi-producer `std.Io`-synchronized ring buffer with wakeup coalescing.
//! - `geometry`: Strongly typed `LogicalPx` / `PhysicalPx` / `ScaleFactor` / `Color` math.
//! - `url` & `glob`: Path/URI canonicalization & linear-time `O(N)` glob pattern matcher.
//! - `html_escape`: Single-pass HTML-safe JSON string escaper & `<head>` tag scanner.

pub const geometry = @import("geometry.zig");
pub const glob = @import("glob.zig");
pub const handle_pool = @import("handle_pool.zig");
pub const html_escape = @import("html_escape.zig");
pub const owned_bytes = @import("owned_bytes.zig");
pub const queue = @import("queue.zig");
pub const response = @import("response.zig");
pub const url = @import("url.zig");

pub const MAX_JS_SAFE_INT = handle_pool.MAX_JS_SAFE_INT;
pub const Handle = handle_pool.Handle;
pub const HandleError = handle_pool.HandleError;
pub const HandlePool = handle_pool.HandlePool;

pub const OwnedBytes = owned_bytes.OwnedBytes;
pub const IpcStatus = response.IpcStatus;
pub const OutgoingResponse = response.OutgoingResponse;

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

pub const ParsedUrl = url.ParsedUrl;
pub const UrlError = url.UrlError;

test {
    _ = geometry;
    _ = glob;
    _ = handle_pool;
    _ = html_escape;
    _ = owned_bytes;
    _ = queue;
    _ = response;
    _ = url;
}
