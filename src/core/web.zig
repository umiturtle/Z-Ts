//! `zts_web` — Standalone Embedded Asset, HTTP `Range` (`206`) & Security Engine (`link_libc = false`).
//!
//! Reusable in any application serving embedded archives, media streams, browser overlays,
//! or local HTTP endpoints — **zero dependency on windowing VTables or RPC codecs**:
//! - `Assets`: Static memory / dynamic fallback asset resolver with SPA routing & `400` traversal defense.
//! - `http_range`: RFC 9110 `Range: bytes=...` parser & slicer (`206 Partial Content` / `416`) for audio/video seeking.
//! - `mime`: Extension & magic-byte MIME sniffer (ES modules, Wasm, SVG, fonts, audio/video).
//! - `csp` & re-exported `url` / `glob` / `html_escape` from `zts_foundation`.

const foundation = @import("zts_foundation");

pub const assets = @import("assets.zig");
pub const csp = @import("csp.zig");
pub const http_range = @import("http_range.zig");
pub const mime = @import("mime.zig");

pub const glob = foundation.glob;
pub const html_escape = foundation.html_escape;
pub const owned_bytes = foundation.owned_bytes;
pub const response = foundation.response;
pub const url = foundation.url;

pub const OwnedBytes = foundation.OwnedBytes;
pub const IpcStatus = foundation.IpcStatus;
pub const OutgoingResponse = foundation.OutgoingResponse;

pub const AssetResponse = assets.AssetResponse;
pub const AssetStatus = assets.AssetStatus;
pub const Assets = assets.Assets;
pub const FallbackLoader = assets.FallbackLoader;
pub const ResolveOptions = assets.ResolveOptions;
pub const StaticAsset = assets.StaticAsset;

pub const ByteRange = http_range.ByteRange;
pub const RangeEval = http_range.RangeEval;
pub const ParsedUrl = foundation.ParsedUrl;
pub const UrlError = foundation.UrlError;

test {
    _ = assets;
    _ = csp;
    _ = http_range;
    _ = mime;
}
