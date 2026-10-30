//! Outbound Isomorphic SSG Exporter (`src/ssg/exporter.zig`).
//!
//! Produces a completely self-contained static directory (`dist/`) ready for zero-server deployment
//! to GitHub Pages (including repository subpaths!), Cloudflare Pages, Netlify, Vercel, or itch.io:
//!
//! 1. **Depth-aware relative URLs**: Injects `<head>` bootstrap scripts with relative `wasmUrl`
//!    (`"./_zts/app.wasm"`, `"../_zts/app.wasm"`, `"../../_zts/app.wasm"`) and `assetBaseUrl` so
//!    nested routes work identically whether hosted at `/` or `/my-repo-subpath/`.
//! 2. **Build-time Route Pre-rendering**: Renders custom `PrerenderRoute` definitions into clean
//!    directory indices (`dist/<route>/index.html`) with HTML-escaped `<title>`, OpenGraph `<meta>`,
//!    XSS-safe `<script id="__ZTS_SSG_DATA__" type="application/json">`, and static HTML fragments.
//! 3. **Scoped Asset Bundling**: Copies only files matching `asset_scope_globs` from `asset_source_dir`
//!    into `dist/_zts/assets/...`, preventing accidental leakage of secrets or unapproved files.
//! 4. **Static Hosting Metadata**: Emits `.nojekyll`, `_headers` (`application/wasm`, CSP, optional
//!    COOP/COEP isolation headers), and SPA `404.html` fallback automatically.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const foundation = @import("zts_foundation");
const web = @import("zts_web");
const wasm = @import("zts_wasm");

const glob = foundation.glob;
const html_escape = foundation.html_escape;

/// One page to render at build time. `route` is the URL the page will be served at; every other
/// field is optional and only affects that page.
pub const PrerenderRoute = struct {
    /// Clean URL route (e.g. `"/"`, `"/about"`, `"/chapters/prologue"`).
    route: []const u8,
    /// Optional template route inside `assets` (defaults to the route itself with SPA fallback).
    template_route: ?[]const u8 = null,
    /// Optional page `<title>` & `og:title` (HTML-escaped).
    title: ?[]const u8 = null,
    /// Optional `<meta name="description">` & `og:description` (HTML-escaped).
    description: ?[]const u8 = null,
    /// Optional precomputed JSON payload written into `<script id="__ZTS_SSG_DATA__" type="application/json">`
    /// with full `<`, `>`, `&`, U+2028/2029 escaping to block `</script>` injection!
    initial_json: ?[]const u8 = null,
    /// Optional static pre-rendered HTML injected into `<div id="app"></div>` (or before `</body>`).
    body_html: ?[]const u8 = null,
};

/// Inputs for `exportStaticSite()` — the `dist/` half of the 3-artifact story (desktop binary,
/// Live Preview server, static site). Build it once in `build.zig` and let CI publish the output.
pub const ExportOptions = struct {
    /// Embedded or scanned frontend asset set (`zts_web.Assets`).
    assets: web.Assets,
    /// Window label surfaced to `@tauri-apps/api`.
    window_label: []const u8 = "main",
    /// Optional compiled `wasm32-freestanding` binary written to `dist/_zts/app.wasm`.
    wasm_bytes: ?[]const u8 = null,
    /// Additional dynamic or static routes to pre-render at build time.
    prerender_routes: []const PrerenderRoute = &.{},
    /// Optional external asset directory whose glob-matching files are copied into `dist/_zts/assets/`.
    asset_source_dir: ?Io.Dir = null,
    /// Allowed glob patterns when copying from `asset_source_dir` (e.g. `&.{ "audio/**", "images/**" }`).
    asset_scope_globs: []const []const u8 = &.{},
    /// Emit `404.html` client-side router fallback (used automatically by GitHub Pages & Cloudflare Pages).
    emit_spa_404: bool = true,
    /// Emit `.nojekyll` so GitHub Pages serves `_zts/`, `_astro/`, and `_next/` directories!
    emit_nojekyll: bool = true,
    /// Emit `_headers` for Cloudflare Pages / Netlify (`Content-Type: application/wasm`, CSP, etc.).
    emit_headers_file: bool = true,
    /// Emit `Cross-Origin-Opener-Policy` + `Cross-Origin-Embedder-Policy` in `_headers`.
    cross_origin_isolated: bool = false,
};

/// What `exportStaticSite()` actually wrote. Returned so `build.zig` (and CI) can assert on it
/// instead of trusting a silent success.
pub const ExportReport = struct {
    html_pages_written: usize = 0,
    static_files_written: usize = 0,
    bundled_assets_written: usize = 0,
    skipped_out_of_scope_assets: usize = 0,
    wasm_bytes_written: usize = 0,
};

/// Computes the relative path prefix from `out_sub_path` (e.g. `"chapters/prologue/index.html"`)
/// back to the root of `dist/` (`"../../"`, or `"./"` for a top-level `"index.html"`).
pub fn relativeRootPrefixAlloc(allocator: Allocator, out_sub_path: []const u8) Allocator.Error![]u8 {
    var depth: usize = 0;
    for (out_sub_path) |ch| {
        if (ch == '/') depth += 1;
    }
    if (depth == 0) return allocator.dupe(u8, "./");
    const out = try allocator.alloc(u8, depth * 3);
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        @memcpy(out[i * 3 .. i * 3 + 3], "../");
    }
    return out;
}

/// Converts a clean route (`"/"`, `"/about"`, `"/about/"`, `"/feed.html"`) into a relative output file path inside `dist/`.
pub fn routeToOutputSubPathAlloc(allocator: Allocator, raw_route: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, raw_route, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, "index.html");
    if (std.mem.endsWith(u8, trimmed, ".html") or std.mem.endsWith(u8, trimmed, ".htm")) {
        return allocator.dupe(u8, trimmed);
    }
    return std.fmt.allocPrint(allocator, "{s}/index.html", .{trimmed});
}

/// Case-insensitive ASCII substring search (Zig 0.17 `std.ascii` ships no `indexOfIgnoreCase`).
fn indexOfAsciiIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Escapes raw JSON text so it can never terminate its surrounding `<script>` element.
fn writeHtmlSafeJsonRaw(writer: *std.Io.Writer, raw_json: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < raw_json.len) : (i += 1) {
        const b = raw_json[i];
        switch (b) {
            '<' => try writer.writeAll("\\u003c"),
            '>' => try writer.writeAll("\\u003e"),
            '&' => try writer.writeAll("\\u0026"),
            0xE2 => {
                if (i + 2 < raw_json.len and raw_json[i + 1] == 0x80 and (raw_json[i + 2] == 0xA8 or raw_json[i + 2] == 0xA9)) {
                    if (raw_json[i + 2] == 0xA8) try writer.writeAll("\\u2028") else try writer.writeAll("\\u2029");
                    i += 2;
                } else {
                    try writer.writeByte(b);
                }
            },
            else => try writer.writeByte(b),
        }
    }
}

fn writeHeadSnippet(
    w: *std.Io.Writer,
    window_label: []const u8,
    wasm_url: []const u8,
    asset_base: []const u8,
    route_meta: ?PrerenderRoute,
) std.Io.Writer.Error!void {
    if (route_meta) |rm| {
        if (rm.title) |t| {
            try w.writeAll("<meta property=\"og:title\" content=\"");
            try html_escape.writeHtmlText(w, t);
            try w.writeAll("\">");
        }
        if (rm.description) |desc| {
            try w.writeAll("<meta name=\"description\" content=\"");
            try html_escape.writeHtmlText(w, desc);
            try w.writeAll("\"><meta property=\"og:description\" content=\"");
            try html_escape.writeHtmlText(w, desc);
            try w.writeAll("\">");
        }
        if (rm.initial_json) |json| {
            try w.writeAll("<script id=\"__ZTS_SSG_DATA__\" type=\"application/json\">");
            try writeHtmlSafeJsonRaw(w, json);
            try w.writeAll("</script>");
        }
    }

    try wasm.js_bootstrap.writeInlineHtmlTag(w, .{
        .label = window_label,
        .wasm_url = wasm_url,
        .asset_base_url = asset_base,
    });
}

fn writeHtmlHeadSnippet(
    allocator: Allocator,
    out_sub_path: []const u8,
    window_label: []const u8,
    route_meta: ?PrerenderRoute,
) Allocator.Error![]u8 {
    const prefix = try relativeRootPrefixAlloc(allocator, out_sub_path);
    defer allocator.free(prefix);

    const wasm_url = try std.fmt.allocPrint(allocator, "{s}_zts/app.wasm", .{prefix});
    defer allocator.free(wasm_url);
    const asset_base = try std.fmt.allocPrint(allocator, "{s}_zts/assets/", .{prefix});
    defer allocator.free(asset_base);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    writeHeadSnippet(w, window_label, wasm_url, asset_base, route_meta) catch return error.OutOfMemory;

    return aw.toOwnedSlice();
}

fn transformHtmlPageAlloc(
    allocator: Allocator,
    raw_html: []const u8,
    out_sub_path: []const u8,
    window_label: []const u8,
    route_meta: ?PrerenderRoute,
) Allocator.Error![]u8 {
    var working = try allocator.dupe(u8, raw_html);
    errdefer allocator.free(working);

    // 1. Replace or insert `<title>...</title>` when a pre-render title is requested.
    if (route_meta) |rm| {
        if (rm.title) |new_title| {
            var title_aw: std.Io.Writer.Allocating = .init(allocator);
            defer title_aw.deinit();
            title_aw.writer.writeAll("<title>") catch return error.OutOfMemory;
            html_escape.writeHtmlText(&title_aw.writer, new_title) catch return error.OutOfMemory;
            title_aw.writer.writeAll("</title>") catch return error.OutOfMemory;

            if (indexOfAsciiIgnoreCase(working, "<title>")) |t_start| {
                if (indexOfAsciiIgnoreCase(working[t_start..], "</title>")) |rel_end| {
                    const t_end = t_start + rel_end + "</title>".len;
                    const replaced = try std.mem.concat(allocator, u8, &.{
                        working[0..t_start],
                        title_aw.written(),
                        working[t_end..],
                    });
                    allocator.free(working);
                    working = replaced;
                }
            }
        }

        // 2. Inject pre-rendered HTML fragment into `<div id="app"></div>` or before `</body>`.
        if (rm.body_html) |fragment| {
            const marker = "<div id=\"app\"></div>";
            if (std.mem.indexOf(u8, working, marker)) |pos| {
                const injected = try std.fmt.allocPrint(allocator, "{s}<div id=\"app\">{s}</div>{s}", .{
                    working[0..pos],
                    fragment,
                    working[pos + marker.len ..],
                });
                allocator.free(working);
                working = injected;
            } else if (indexOfAsciiIgnoreCase(working, "</body>")) |b_end| {
                const injected = try std.mem.concat(allocator, u8, &.{ working[0..b_end], fragment, working[b_end..] });
                allocator.free(working);
                working = injected;
            }
        }
    }

    // 3. Inject the bootstrap snippet right after `<head>` (comment / BOM / DOCTYPE aware).
    const snippet = try writeHtmlHeadSnippet(allocator, out_sub_path, window_label, route_meta);
    defer allocator.free(snippet);

    const out = try html_escape.injectIntoHead(allocator, working, snippet);
    allocator.free(working);
    return out;
}

fn writeDistFile(io: Io, dist_dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, sub_path, '/')) |slash| {
        try dist_dir.createDirPath(io, sub_path[0..slash]);
    }
    try dist_dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

fn matchesAnyScope(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pattern| {
        if (glob.match(pattern, path)) return true;
    }
    return false;
}

/// Exports a complete serverless static site into `dist_dir`.
pub fn exportStaticSite(
    allocator: Allocator,
    io: Io,
    dist_dir: Io.Dir,
    opts: ExportOptions,
) !ExportReport {
    var report: ExportReport = .{};

    // Output paths written by explicit pre-renders win over bulk asset copying.
    var rendered_set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var kit = rendered_set.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        rendered_set.deinit(allocator);
    }

    // 1. Pre-render explicitly declared routes first.
    for (opts.prerender_routes) |pr| {
        const out_rel = try routeToOutputSubPathAlloc(allocator, pr.route);
        errdefer allocator.free(out_rel);

        const lookup_route = pr.template_route orelse pr.route;
        var resolved = try opts.assets.resolve(allocator, lookup_route, .{ .spa_fallback = true });
        defer resolved.deinit();

        const raw_html = if (resolved.status == .ok)
            resolved.body.slice()
        else
            "<!doctype html><html><head><title>Z-Ts App</title></head><body><div id=\"app\"></div></body></html>";

        const final_html = try transformHtmlPageAlloc(allocator, raw_html, out_rel, opts.window_label, pr);
        defer allocator.free(final_html);

        try writeDistFile(io, dist_dir, out_rel, final_html);
        try rendered_set.put(allocator, out_rel, {});
        report.html_pages_written += 1;
    }

    // 2. Emit every remaining embedded/hosted frontend entry.
    for (opts.assets.entries) |entry| {
        const trimmed = std.mem.trimStart(u8, entry.path, "/");
        if (trimmed.len == 0) continue;
        if (rendered_set.contains(trimmed)) continue;

        const is_html = std.mem.endsWith(u8, trimmed, ".html") or std.mem.endsWith(u8, trimmed, ".htm");
        if (is_html) {
            const final_html = try transformHtmlPageAlloc(allocator, entry.bytes, trimmed, opts.window_label, null);
            defer allocator.free(final_html);
            try writeDistFile(io, dist_dir, trimmed, final_html);
            report.html_pages_written += 1;
        } else {
            try writeDistFile(io, dist_dir, trimmed, entry.bytes);
            report.static_files_written += 1;
        }
    }

    // 3. Emit `404.html` SPA fallback (GitHub Pages / Cloudflare Pages auto-serve it for unknown paths).
    if (opts.emit_spa_404 and !rendered_set.contains("404.html")) {
        var root_res = try opts.assets.resolve(allocator, "/index.html", .{ .spa_fallback = false });
        defer root_res.deinit();
        if (root_res.status == .ok) {
            const html_404 = try transformHtmlPageAlloc(allocator, root_res.body.slice(), "404.html", opts.window_label, null);
            defer allocator.free(html_404);
            try writeDistFile(io, dist_dir, "404.html", html_404);
            report.html_pages_written += 1;
        }
    }

    // 4. Write the compiled Wasm binary (`_zts/app.wasm`).
    if (opts.wasm_bytes) |wasm_bin| {
        try writeDistFile(io, dist_dir, "_zts/app.wasm", wasm_bin);
        report.wasm_bytes_written = wasm_bin.len;
    }

    // 5. Copy glob-scoped runtime assets, strictly rejecting out-of-scope files!
    if (opts.asset_source_dir) |src_dir| {
        var walker = try src_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;

            const norm = try allocator.dupe(u8, entry.path);
            defer allocator.free(norm);
            for (norm) |*c| {
                if (c.* == '\\') c.* = '/';
            }

            if (!matchesAnyScope(opts.asset_scope_globs, norm)) {
                report.skipped_out_of_scope_assets += 1;
                continue;
            }

            const data = try src_dir.readFileAlloc(io, entry.path, allocator, .unlimited);
            defer allocator.free(data);

            const dest_path = try std.fmt.allocPrint(allocator, "_zts/assets/{s}", .{norm});
            defer allocator.free(dest_path);

            try writeDistFile(io, dist_dir, dest_path, data);
            report.bundled_assets_written += 1;
        }
    }

    // 6. Emit static-host metadata files.
    if (opts.emit_nojekyll) {
        try writeDistFile(io, dist_dir, ".nojekyll", "");
    }

    if (opts.emit_headers_file) {
        var hdr_aw: std.Io.Writer.Allocating = .init(allocator);
        defer hdr_aw.deinit();
        try hdr_aw.writer.writeAll(
            \\/_zts/*.wasm
            \\  Content-Type: application/wasm
            \\  Cache-Control: public, max-age=31536000, immutable
            \\
        );
        if (opts.cross_origin_isolated) {
            try hdr_aw.writer.writeAll(
                \\/*
                \\  Cross-Origin-Opener-Policy: same-origin
                \\  Cross-Origin-Embedder-Policy: require-corp
                \\
            );
        }
        try writeDistFile(io, dist_dir, "_headers", hdr_aw.written());
    }

    return report;
}

test "relativeRootPrefixAlloc computes depth-aware prefixes" {
    const a = try relativeRootPrefixAlloc(testing.allocator, "index.html");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("./", a);

    const b = try relativeRootPrefixAlloc(testing.allocator, "chapters/prologue/index.html");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("../../", b);
}

test "exportStaticSite computes subpath-safe Wasm URLs, pre-renders routes safely, and filters out-of-scope assets" {
    var asset_src = testing.tmpDir(.{});
    defer asset_src.cleanup();
    var dist_out = testing.tmpDir(.{});
    defer dist_out.cleanup();

    try asset_src.dir.createDirPath(testing.io, "audio");
    try asset_src.dir.createDirPath(testing.io, "secret");
    try asset_src.dir.writeFile(testing.io, .{ .sub_path = "audio/bgm.ogg", .data = "OGG_BYTES" });
    try asset_src.dir.writeFile(testing.io, .{ .sub_path = "secret/key.pem", .data = "PRIVATE_KEY" });

    const site_assets: web.Assets = .{
        .entries = &.{
            .{ .path = "/index.html", .bytes = "<!doctype html><html><head><title>Default</title></head><body><div id=\"app\"></div></body></html>" },
            .{ .path = "/app.js", .bytes = "console.log('ready');" },
        },
    };

    const asset_dir = try asset_src.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer asset_dir.close(testing.io);

    const report = try exportStaticSite(testing.allocator, testing.io, dist_out.dir, .{
        .assets = site_assets,
        .wasm_bytes = "\x00asm\x01\x00\x00\x00",
        .prerender_routes = &.{
            .{
                .route = "/chapters/prologue",
                .title = "Prologue <Chapter 1>",
                .description = "Opening scene",
                .initial_json = "{\"xss\":\"</script><script>alert(1)\"}",
                .body_html = "<article>Pre-rendered Prologue</article>",
            },
        },
        .asset_source_dir = asset_dir,
        .asset_scope_globs = &.{"audio/**"},
    });

    try testing.expectEqual(@as(usize, 3), report.html_pages_written); // nested route + `/index.html` + `404.html`
    try testing.expectEqual(@as(usize, 1), report.static_files_written); // `/app.js`
    try testing.expectEqual(@as(usize, 1), report.bundled_assets_written); // `audio/bgm.ogg`
    try testing.expectEqual(@as(usize, 1), report.skipped_out_of_scope_assets); // `secret/key.pem` blocked!

    // Root `/index.html` must reference `./_zts/app.wasm`
    const root_html = try dist_out.dir.readFileAlloc(testing.io, "index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(root_html);
    try testing.expect(std.mem.indexOf(u8, root_html, "\"./_zts/app.wasm\"") != null);

    // Depth-2 `/chapters/prologue/index.html` must reference `../../_zts/app.wasm` AND escape `</script>`!
    const nested_html = try dist_out.dir.readFileAlloc(testing.io, "chapters/prologue/index.html", testing.allocator, .unlimited);
    defer testing.allocator.free(nested_html);
    try testing.expect(std.mem.indexOf(u8, nested_html, "\"../../_zts/app.wasm\"") != null);
    try testing.expect(std.mem.indexOf(u8, nested_html, "<title>Prologue &lt;Chapter 1&gt;</title>") != null);
    try testing.expect(std.mem.indexOf(u8, nested_html, "<div id=\"app\"><article>Pre-rendered Prologue</article></div>") != null);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, nested_html, "<script>alert(1)"));

    // `.nojekyll` and `_headers` must exist, while `_zts/assets/secret/key.pem` MUST NOT exist!
    try dist_out.dir.access(testing.io, ".nojekyll", .{});
    try dist_out.dir.access(testing.io, "_headers", .{});
    try dist_out.dir.access(testing.io, "_zts/assets/audio/bgm.ogg", .{});
    try testing.expectError(error.FileNotFound, dist_out.dir.access(testing.io, "_zts/assets/secret/key.pem", .{}));
}
