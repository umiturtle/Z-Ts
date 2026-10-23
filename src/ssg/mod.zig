//! `zts_ssg` — Standalone Bidirectional Static Site Generation Toolkit (`link_libc = false`).
//!
//! - **Inbound SSG**: `manifest_gen.buildEmbeddedFrontendDir` turns any frontend static build
//!   output (Astro `dist/`, Next.js `out/`, SvelteKit `build/`, Vite `dist/`) into a deterministic,
//!   fully sorted `zts_web.Assets` Zig module backed by `@embedFile`.
//! - **Outbound SSG**: `exporter.exportStaticSite` renders a serverless, subpath-safe `dist/`
//!   bundle (pre-rendered HTML + `_zts/app.wasm` + scoped assets + `.nojekyll` / `_headers` / `404.html`).

const std = @import("std");
const Io = std.Io;

pub const embed_dir_main = @import("embed_dir_main.zig");
pub const exporter = @import("exporter.zig");
pub const manifest_gen = @import("manifest_gen.zig");

/// Entry point used when this module is built as the `embedFrontendDir` build-time tool
/// (`zig build-exe` with `zts_ssg` as the root module).
pub const main = embed_dir_main.main;

pub const ExportOptions = exporter.ExportOptions;
pub const ExportReport = exporter.ExportReport;
pub const ManifestStats = manifest_gen.ManifestStats;
pub const PrerenderRoute = exporter.PrerenderRoute;

pub const buildEmbeddedFrontendDir = manifest_gen.buildEmbeddedFrontendDir;
pub const exportStaticSite = exporter.exportStaticSite;
pub const relativeRootPrefixAlloc = exporter.relativeRootPrefixAlloc;
pub const routeToOutputSubPathAlloc = exporter.routeToOutputSubPathAlloc;

/// Embeds a frontend static directory at compile time and returns a `zts_web.Assets` value:
///
/// ```zig
/// const assets = zts_ssg.embedFrontendDir("dist/index.html");
/// ```
///
/// `embed_frontend` is intended to be called from the *generated* manifest module created by
/// `build.zig`'s `embedFrontendDir` build helper (`src/ssg/embed_dir_main.zig`), where
/// `@embedFile` resolves relative to the generated module's own directory.
pub fn assetsFromEntries(entries: []const @import("zts_web").StaticAsset) @import("zts_web").Assets {
    return .{ .entries = entries };
}

test {
    _ = embed_dir_main;
    _ = exporter;
    _ = manifest_gen;
}
