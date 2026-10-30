//! Pure (std-only) helpers shared by the `M5-01` build tools.
//!
//! Everything here is deliberately free of `std.Build` and of every `zts_*` module, so it can be
//! unit-tested by `./zigw quick-test` on Linux while the build-script glue in `mod.zig` stays a
//! thin wrapper. Three concerns live here:
//!
//! * **gzip precompression** — each asset gets a deterministic `.gz` twin (fixed header, no mtime),
//!   so two builds of the same `dist/` produce byte-identical output.
//! * **CSP hashes** — inline `<script>` / `<style>` bodies become `sha256-<base64>` entries, which
//!   is what `tauri-codegen` feeds into the `Content-Security-Policy` header.
//! * **manifest rendering** — a deterministic `assets_manifest.zig` (sorted by path) exposing the
//!   `zts_web.Assets` the server side already consumes, plus the gzip twins and CSP hashes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const testing = std.testing;

pub const Options = struct {
    /// Emit a gzip twin for every asset.
    gzip: bool = true,
    /// Extract `sha256-…` hashes from inline `<script>` / `<style>` bodies.
    csp: bool = true,
    /// `std.compress.flate` tuning (`Options.default` = level 6).
    level: flate.Compress.Options = .default,
};

pub const Input = struct {
    /// POSIX path relative to the frontend build directory (`"assets/app.js"`).
    path: []const u8,
    bytes: []const u8,
};

pub const Output = struct {
    /// Index-aligned with the sorted input list; `null` when gzip was disabled.
    gzip: []?[]u8,
    /// `sha256-<base64>` per inline script/style, sorted and de-duplicated.
    csp_hashes: [][]u8,
    /// The rendered `assets_manifest.zig`.
    manifest: []u8,

    pub fn deinit(self: *Output, allocator: Allocator) void {
        for (self.gzip) |maybe| if (maybe) |gz| allocator.free(gz);
        allocator.free(self.gzip);
        for (self.csp_hashes) |hash| allocator.free(hash);
        allocator.free(self.csp_hashes);
        allocator.free(self.manifest);
        self.* = undefined;
    }
};

/// gzip-compresses `bytes` with a deterministic header (`MTIME = 0`, `OS = Unix`).
pub fn gzipAlloc(allocator: Allocator, bytes: []const u8, level: flate.Compress.Options) ![]u8 {
    var window: [flate.max_window_len]u8 = undefined;
    // `flate.Compress.init` asserts an output buffer of at least 8 bytes.
    var buffer = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    errdefer buffer.deinit();
    var compress = try flate.Compress.init(&buffer.writer, &window, .gzip, level);
    try compress.writer.writeAll(bytes);
    try compress.finish();
    return try buffer.toOwnedSlice();
}

/// Round-trips `compressed` back into a fresh allocation (used by the tests and by hosts that want
/// to verify a twin before serving it).
pub fn gunzipAlloc(allocator: Allocator, compressed: []const u8) ![]u8 {
    var source: std.Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(&source, .gzip, &window);
    return try decompress.reader.allocRemaining(allocator, .unlimited);
}

/// SHA-256 of `bytes`, lowercase hex (64 bytes).
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// `sha256-<base64>` of the body, exactly how a CSP `script-src` / `style-src` hash is written.
pub fn cspHashOf(allocator: Allocator, body: []const u8) Allocator.Error![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, "sha256-".len + encoder.calcSize(digest.len));
    @memcpy(out[0.."sha256-".len], "sha256-");
    _ = encoder.encode(out["sha256-".len..], &digest);
    return out;
}

/// Extracts the `sha256-…` hashes of every **inline** `<script>` / `<style>` in `html`.
///
/// Tags with `src=` (or any other attribute) are skipped; only the element *body* is hashed, which
/// is what the browser computes. The scan is case-insensitive and quote-aware, so
/// `<script data-x="a > b">` does not end the opening tag early.
pub fn inlineCspHashes(allocator: Allocator, html: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |hash| allocator.free(hash);
        out.deinit(allocator);
    }

    var cursor: usize = 0;
    while (findTagOpen(html, cursor, "script")) |open| {
        cursor = open.after_name;
        const tag_end = findTagEnd(html, open.after_name) orelse break;
        cursor = tag_end + 1;

        const attributes = html[open.after_name..tag_end];
        if (hasAttribute(attributes, "src")) continue;

        const close = findTagOpen(html, cursor, "/script") orelse break;
        const body = html[cursor..close.start];
        cursor = close.after_name;

        if (body.len == 0) continue;
        try appendUnique(allocator, &out, try cspHashOf(allocator, body));
    }

    cursor = 0;
    while (findTagOpen(html, cursor, "style")) |open| {
        cursor = open.after_name;
        const tag_end = findTagEnd(html, open.after_name) orelse break;
        cursor = tag_end + 1;

        const close = findTagOpen(html, cursor, "/style") orelse break;
        const body = html[cursor..close.start];
        cursor = close.after_name;

        if (body.len == 0) continue;
        try appendUnique(allocator, &out, try cspHashOf(allocator, body));
    }

    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort([]u8, slice, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return slice;
}

const TagOpen = struct {
    /// Index of the `<` that opened the tag.
    start: usize,
    /// Index just past `<tagname` (where the attribute list starts).
    after_name: usize,
};

/// Finds `<name` (case-insensitive) at or after `from`, requiring a tag boundary after the name.
fn findTagOpen(haystack: []const u8, from: usize, comptime name: []const u8) ?TagOpen {
    var i = from;
    while (i + 1 + name.len <= haystack.len) : (i += 1) {
        if (haystack[i] != '<') continue;
        if (!std.ascii.eqlIgnoreCase(haystack[i + 1 ..][0..name.len], name)) continue;
        const after = i + 1 + name.len;
        if (after < haystack.len) {
            const next = haystack[after];
            const boundary = std.ascii.isWhitespace(next) or next == '>' or next == '/';
            if (!boundary) continue;
        }
        return .{ .start = i, .after_name = after };
    }
    return null;
}

/// Index of the `>` that closes the opening tag, ignoring `>` inside quotes.
fn findTagEnd(haystack: []const u8, from: usize) ?usize {
    var quote: ?u8 = null;
    var i = from;
    while (i < haystack.len) : (i += 1) {
        const ch = haystack[i];
        if (quote) |q| {
            if (ch == q) quote = null;
        } else switch (ch) {
            '"', '\'' => quote = ch,
            '>' => return i,
            else => {},
        }
    }
    return null;
}

/// `true` when the attribute list carries `name` as a bare attribute (`src`, `src=`, `src="…"`).
fn hasAttribute(attributes: []const u8, comptime name: []const u8) bool {
    var i: usize = 0;
    while (i + name.len <= attributes.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(attributes[i..][0..name.len], name)) continue;
        const before_ok = i == 0 or std.ascii.isWhitespace(attributes[i - 1]);
        const after = i + name.len;
        const after_ok = after == attributes.len or std.ascii.isWhitespace(attributes[after]) or
            attributes[after] == '=' or attributes[after] == '/';
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn appendUnique(allocator: Allocator, list: *std.ArrayListUnmanaged([]u8), hash: []u8) Allocator.Error!void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, hash)) {
            allocator.free(hash);
            return;
        }
    }
    errdefer allocator.free(hash);
    try list.append(allocator, hash);
}

/// Everything a build needs to render the manifest module.
pub const Entry = struct {
    /// POSIX path relative to the frontend build directory.
    path: []const u8,
    bytes: []const u8,
    /// gzip twin (may be `null`).
    gzip: ?[]const u8 = null,
};

/// Collects the gzip twins, the CSP hashes and the rendered manifest.
///
/// `inputs` may be in any order: the output is sorted by `path` so two runs over the same tree
/// produce byte-identical files. Duplicate paths are rejected (`error.DuplicatePath`).
pub fn build(allocator: Allocator, inputs: []const Input, opts: Options) !Output {
    const order = try allocator.alloc(usize, inputs.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, inputs, struct {
        fn lessThan(ctx: []const Input, a: usize, b: usize) bool {
            return std.mem.order(u8, ctx[a].path, ctx[b].path) == .lt;
        }
    }.lessThan);
    if (order.len > 1) {
        for (order[1..], order[0 .. order.len - 1]) |current, previous| {
            if (std.mem.eql(u8, inputs[previous].path, inputs[current].path)) return error.DuplicatePath;
        }
    }

    const gzip = try allocator.alloc(?[]u8, inputs.len);
    for (gzip) |*slot| slot.* = null;
    errdefer {
        for (gzip) |maybe| if (maybe) |gz| allocator.free(gz);
        allocator.free(gzip);
    }

    if (opts.gzip) {
        for (order) |index| {
            const twin = try gzipAlloc(allocator, inputs[index].bytes, opts.level);
            if (twin.len >= inputs[index].bytes.len) {
                // Incompressible payload: keep the raw bytes only (a `.gz` twin would be larger).
                allocator.free(twin);
                continue;
            }
            gzip[index] = twin;
        }
    }

    var hashes: [][]u8 = &.{};
    if (opts.csp) {
        var collected: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (collected.items) |hash| allocator.free(hash);
            collected.deinit(allocator);
        }
        for (order) |index| {
            const path = inputs[index].path;
            if (!std.mem.endsWith(u8, path, ".html")) continue;
            const found = try inlineCspHashes(allocator, inputs[index].bytes);
            defer allocator.free(found);
            for (found) |hash| {
                try appendUnique(allocator, &collected, hash);
            }
        }
        const slice = try collected.toOwnedSlice(allocator);
        std.mem.sort([]u8, slice, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        hashes = slice;
    }
    errdefer {
        for (hashes) |hash| allocator.free(hash);
        allocator.free(hashes);
    }

    const manifest = try renderManifest(allocator, inputs, order, gzip, hashes);
    return .{ .gzip = gzip, .csp_hashes = hashes, .manifest = manifest };
}

/// Renders the `assets_manifest.zig` module. `order` is the sorted index list, `gzip` and
/// `hashes` are the already-computed twins / CSP hashes.
pub fn renderManifest(
    allocator: Allocator,
    inputs: []const Input,
    order: []const usize,
    gzip: []const ?[]const u8,
    hashes: []const []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\//! Auto-generated by Z-Ts `M5-01` build tools — DO NOT EDIT MANUALLY.
        \\//!
        \\//! `entries` / `assets` are drop-in compatible with the `zts_ssg` manifest; the extra
        \\//! `gzip_entries` (deterministic twins, `null` when not compressible) and `csp_hashes`
        \\//! (inline `<script>` / `<style>` bodies) are what `M5-01` adds.
        \\const web = @import("zts_web");
        \\
        \\pub const entries: []const web.StaticAsset = &.{
        \\
    );
    for (order) |index| {
        const route = try routeOf(allocator, inputs[index].path);
        defer allocator.free(route);
        const staged = try stagedPath(allocator, inputs[index].path, false);
        defer allocator.free(staged);
        try w.writeAll("    .{ .path = ");
        try writeZigString(w, route);
        try w.writeAll(", .bytes = @embedFile(");
        try writeZigString(w, staged);
        try w.writeAll(") },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\pub const sha256_digests: []const []const u8 = &.{
        \\
    );
    for (order) |index| {
        const hex = sha256Hex(inputs[index].bytes);
        try w.print("    \"{s}\",\n", .{hex[0..]});
    }
    try w.writeAll(
        \\};
        \\
        \\/// gzip twin per entry (index-aligned with `entries`); `null` = serve the raw bytes.
        \\pub const gzip_entries: []const ?[]const u8 = &.{
        \\
    );
    for (order) |index| {
        if (gzip[index] != null) {
            const staged = try stagedPath(allocator, inputs[index].path, true);
            defer allocator.free(staged);
            try w.writeAll("    @embedFile(");
            try writeZigString(w, staged);
            try w.writeAll("),\n");
        } else {
            try w.writeAll("    null,\n");
        }
    }
    try w.writeAll(
        \\};
        \\
        \\/// `sha256-<base64>` of every inline <script> / <style>, ready for a CSP header.
        \\pub const csp_hashes: []const []const u8 = &.{
        \\
    );
    for (hashes) |hash| {
        try w.writeAll("    ");
        try writeZigString(w, hash);
        try w.writeAll(",\n");
    }
    try w.writeAll(
        \\};
        \\
        \\pub const assets: web.Assets = .{ .entries = entries };
        \\
    );

    return try aw.toOwnedSlice();
}

fn routeOf(allocator: Allocator, path: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "/{s}", .{path});
}

fn stagedPath(allocator: Allocator, path: []const u8, gzip: bool) Allocator.Error![]const u8 {
    return if (gzip)
        std.fmt.allocPrint(allocator, "files/{s}.gz", .{path})
    else
        std.fmt.allocPrint(allocator, "files/{s}", .{path});
}

fn writeZigString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\x{x:0>2}", .{ch}) else try w.writeByte(ch),
    };
    try w.writeByte('"');
}

// ============================================================================
// Tests
// ============================================================================

test "gzip twins round-trip and use a deterministic header" {
    const payload = comptime blk: {
        var acc: []const u8 = "";
        for (0..32) |_| acc = acc ++ "console.log('zts');\n";
        break :blk acc;
    };

    const first = try gzipAlloc(testing.allocator, payload, .default);
    defer testing.allocator.free(first);
    const second = try gzipAlloc(testing.allocator, payload, .default);
    defer testing.allocator.free(second);

    try testing.expectEqualSlices(u8, first, second);
    // gzip magic + MTIME = 0 + OS = 3 (Unix): the same bytes on every OS.
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 }, first[0..10]);
    try testing.expect(first.len < payload.len);

    const restored = try gunzipAlloc(testing.allocator, first);
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(payload, restored);
}

test "gzip of the empty payload still produces a valid member" {
    const compressed = try gzipAlloc(testing.allocator, "", .fastest);
    defer testing.allocator.free(compressed);
    const restored = try gunzipAlloc(testing.allocator, compressed);
    defer testing.allocator.free(restored);
    try testing.expectEqual(@as(usize, 0), restored.len);
}

test "csp hashes cover inline script/style only" {
    const html =
        \\<html><head>
        \\<style>body { color: red }</style>
        \\<script>console.log("inline")</script>
        \\<script src="/app.js"></script>
        \\<script data-x="a > b">console.log("quoted")</script>
        \\</head><body></body></html>
    ;
    const hashes = try inlineCspHashes(testing.allocator, html);
    defer {
        for (hashes) |hash| testing.allocator.free(hash);
        testing.allocator.free(hashes);
    }

    // style + 2 inline scripts; the `src=` one is skipped.
    try testing.expectEqual(@as(usize, 3), hashes.len);
    const style_hash = try cspHashOf(testing.allocator, "body { color: red }");
    defer testing.allocator.free(style_hash);
    const inline_hash = try cspHashOf(testing.allocator, "console.log(\"inline\")");
    defer testing.allocator.free(inline_hash);
    const quoted_hash = try cspHashOf(testing.allocator, "console.log(\"quoted\")");
    defer testing.allocator.free(quoted_hash);

    try testing.expect(containsHash(hashes, style_hash));
    try testing.expect(containsHash(hashes, inline_hash));
    try testing.expect(containsHash(hashes, quoted_hash));
    try testing.expect(std.mem.startsWith(u8, style_hash, "sha256-"));

    // Sorted by their own bytes, so the output is stable across runs.
    for (hashes[1..], hashes[0 .. hashes.len - 1]) |current, previous| {
        try testing.expect(std.mem.order(u8, previous, current) == .lt);
    }
}

fn containsHash(hashes: []const []u8, needle: []const u8) bool {
    for (hashes) |hash| {
        if (std.mem.eql(u8, hash, needle)) return true;
    }
    return false;
}

test "csp hashes ignore uppercase tags, duplicates and empty bodies" {
    const html =
        \\<SCRIPT>a()</SCRIPT><script>a()</script><style></style><style> b </style>
    ;
    const hashes = try inlineCspHashes(testing.allocator, html);
    defer {
        for (hashes) |hash| testing.allocator.free(hash);
        testing.allocator.free(hashes);
    }
    try testing.expectEqual(@as(usize, 2), hashes.len);
}

test "manifest is sorted, hashed, compressed and quoted safely" {
    const inputs = [_]Input{
        .{ .path = "z-last.html", .bytes = "<script>z()</script>" },
        .{ .path = "a/b.js", .bytes = "let a = 1;\nlet a = 1;\nlet a = 1;\nlet a = 1;\nlet a = 1;\nlet a = 1;\n" },
        .{ .path = "with\"quote.txt", .bytes = "plain" },
    };
    var out = try build(testing.allocator, &inputs, .{});
    defer out.deinit(testing.allocator);

    const first = out.manifest;
    var again = try build(testing.allocator, &inputs, .{});
    defer again.deinit(testing.allocator);
    try testing.expectEqualStrings(first, again.manifest);

    // Order is by path, so `a/b.js` comes first even though it was passed second.
    const a_index = std.mem.indexOf(u8, first, "files/a/b.js").?;
    const z_index = std.mem.indexOf(u8, first, "files/z-last.html").?;
    try testing.expect(a_index < z_index);

    // Routes are absolute and the escaped quote never breaks the literal.
    try testing.expect(std.mem.indexOf(u8, first, "\"/a/b.js\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "with\\\"quote.txt") != null);

    // `z-last.html` is compressible, `with"quote.txt` is tiny (skipped: the twin would be bigger).
    try testing.expect(out.gzip[1] != null);
    try testing.expect(out.gzip[2] == null);
    const restored = try gunzipAlloc(testing.allocator, out.gzip[1].?);
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(inputs[1].bytes, restored);

    // The single inline script of `z-last.html` made it into the CSP list.
    try testing.expectEqual(@as(usize, 1), out.csp_hashes.len);
    try testing.expect(std.mem.indexOf(u8, first, out.csp_hashes[0]) != null);
}

test "duplicate paths are rejected" {
    const inputs = [_]Input{
        .{ .path = "index.html", .bytes = "a" },
        .{ .path = "index.html", .bytes = "b" },
    };
    try testing.expectError(error.DuplicatePath, build(testing.allocator, &inputs, .{}));
}

test "gzip and csp can be disabled independently" {
    const inputs = [_]Input{.{ .path = "index.html", .bytes = "<style>a{}</style><style>a{}</style><style>a{}</style><style>a{}</style>" }};
    var plain = try build(testing.allocator, &inputs, .{ .gzip = false, .csp = false });
    defer plain.deinit(testing.allocator);
    try testing.expect(plain.gzip[0] == null);
    try testing.expectEqual(@as(usize, 0), plain.csp_hashes.len);
    try testing.expect(std.mem.indexOf(u8, plain.manifest, "pub const csp_hashes") != null);
}
