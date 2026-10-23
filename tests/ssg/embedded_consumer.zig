//! Inbound SSG consumer test (`M2-01`): imports the module generated at build time by
//! `build.zig`'s `embedFrontendDir` helper and exercises it through `zts_web.Assets`.

const std = @import("std");
const testing = std.testing;

const web = @import("zts_web");
const frontend = @import("embedded_frontend");

test "embedFrontendDir embeds a deterministic multi-page SSG tree" {
    try testing.expectEqual(@as(usize, 3), frontend.entries.len);

    // Deterministic lexicographic ordering (`/about/index.html`, `/assets/app.js`, `/index.html`).
    try testing.expectEqualStrings("/about/index.html", frontend.entries[0].path);
    try testing.expectEqualStrings("/assets/app.js", frontend.entries[1].path);
    try testing.expectEqualStrings("/index.html", frontend.entries[2].path);

    // SHA-256 digests are emitted for every entry (usable for immutable CSP / ETag handling).
    try testing.expectEqual(frontend.entries.len, frontend.sha256_digests.len);
    try testing.expectEqual(@as(usize, 64), frontend.sha256_digests[0].len);
}

test "embedded multi-page SSG assets resolve directory indices, MIME & 404 correctly" {
    const assets = web.Assets{ .entries = frontend.entries };

    // `/` -> `/index.html`
    var root = try assets.resolve(testing.allocator, "/", .{});
    defer root.deinit();
    try testing.expectEqual(web.assets.AssetStatus.ok, root.status);
    try testing.expect(std.mem.indexOf(u8, root.body.slice(), "Inbound SSG Home") != null);

    // `/about` -> `/about/index.html` (multi-page SSG directory index, NOT SPA fallback)
    var about = try assets.resolve(testing.allocator, "/about/", .{});
    defer about.deinit();
    try testing.expectEqual(web.assets.AssetStatus.ok, about.status);
    try testing.expectEqual(false, about.used_spa_fallback);
    try testing.expect(std.mem.indexOf(u8, about.body.slice(), "About page pre-rendered") != null);

    // Extensionless hashed/missing subresource must stay `404` (never fall back to HTML).
    var missing = try assets.resolve(testing.allocator, "/missing.js", .{});
    defer missing.deinit();
    try testing.expectEqual(web.assets.AssetStatus.not_found, missing.status);

    // ES module MIME type is served correctly.
    var js = try assets.resolve(testing.allocator, "/assets/app.js", .{});
    defer js.deinit();
    try testing.expectEqual(web.assets.AssetStatus.ok, js.status);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", js.mime_type);
}
