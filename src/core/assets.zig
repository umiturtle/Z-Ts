//! Static / directory-backed web asset resolution with SPA and Range support.
//!
//! `zts_core` never performs OS I/O: embedded assets live in a `StaticMap`,
//! while directory-backed sources are plugged in through the `Loader` function
//! pointer table (implemented by `zts_bridge` / `zts_webview`). That keeps this
//! module testable with zero filesystem access and keeps `link_libc = false`.
//!
//! Security invariants:
//! - the request target is percent-decoded *before* traversal checks
//! - `..`, NUL, backslash, control characters and non-UTF-8 paths 404
//! - SPA fallback only applies to extension-less paths (never `.js` → HTML,
//!   which would break module MIME checks and mask missing assets)
//! - HEAD responses keep the real `Content-Length` with an empty body
//! - `416` responses carry no body but expose `total_length` so the caller can
//!   emit `Content-Range: bytes */<total>`

const std = @import("std");
const http_range = @import("http_range.zig");
const mime = @import("mime.zig");
const url = @import("url.zig");

/// A single servable asset. `bytes` is borrowed and must outlive the response.
pub const Asset = struct {
    bytes: []const u8,
    /// Content type override; when null `mime.detect` is used.
    mime: ?[]const u8 = null,
    /// Strong validator including quotes (e.g. `"\"v1\""`), used by `If-Range`.
    etag: ?[]const u8 = null,
};

/// A read-only, compile-time-friendly list of embedded assets.
pub const StaticMap = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        /// Absolute web path, including the leading `/` (e.g. `/index.html`).
        path: []const u8,
        asset: Asset,
    };

    pub fn get(self: StaticMap, path: []const u8) ?Asset {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.asset;
        }
        return null;
    }

    pub fn len(self: StaticMap) usize {
        return self.entries.len;
    }

    pub fn isEmpty(self: StaticMap) bool {
        return self.entries.len == 0;
    }
};

/// Directory / archive source. `load` receives a path relative to the asset root
/// (`"assets/app.js"`); it must return bytes allocated with the given allocator
/// (or `null` when the file does not exist). `release` is called exactly once per
/// successfully loaded buffer when the response is deinitialized.
pub const Loader = struct {
    ctx: ?*anyopaque = null,
    load_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8,
    release_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, bytes: []u8) void,

    pub fn load(self: Loader, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
        return self.load_fn(self.ctx, allocator, path);
    }

    pub fn release(self: Loader, allocator: std.mem.Allocator, bytes: []u8) void {
        self.release_fn(self.ctx, allocator, bytes);
    }
};

pub const ResolveError = error{
    OutOfMemory,
    /// The loader failed for a reason other than "not found".
    LoadFailure,
};

/// Asset root with optional SPA routing.
///
/// `Assets` itself is immutable configuration and is safe to share across
/// threads; concurrent `resolve` calls are safe as long as the injected
/// `Loader` is thread-safe. Every call uses a private arena for path strings, so
/// no state is mutated during resolution.
pub const Assets = struct {
    static: StaticMap = .{},
    loader: ?Loader = null,
    /// File served for directory requests and SPA fallback.
    index_file: []const u8 = "index.html",
    /// Serve the index file for extension-less unknown paths.
    spa_fallback: bool = true,
    /// Reject request targets longer than this (defensive bound).
    max_path_len: usize = 4096,

    pub const Method = enum { get, head };

    pub const Options = struct {
        method: Method = .get,
        /// Raw `Range` header value, if any.
        range: ?[]const u8 = null,
        /// Raw `If-Range` header value, if any.
        if_range: ?[]const u8 = null,
    };

    pub const Status = enum(u16) {
        ok = 200,
        partial_content = 206,
        not_found = 404,
        range_not_satisfiable = 416,
    };

    /// Result of a lookup. Always call `deinit` to release loader-owned bytes.
    pub const Response = struct {
        status: Status = .not_found,
        mime: []const u8 = "text/plain; charset=utf-8",
        /// Body to send. Empty for HEAD and 416 responses.
        body: []const u8 = &.{},
        /// Decimal `Content-Length` to advertise.
        content_length: u64 = 0,
        /// Full size of the underlying asset.
        total_length: u64 = 0,
        /// Present for `206 Partial Content`.
        range: ?http_range.ByteRange = null,
        etag: ?[]const u8 = null,

        owned: ?[]u8 = null,
        release_ctx: ?*anyopaque = null,
        release_fn: ?*const fn (?*anyopaque, std.mem.Allocator, []u8) void = null,

        pub fn isSuccess(self: Response) bool {
            return self.status == .ok or self.status == .partial_content;
        }

        /// HTTP status code as an integer (for status lines).
        pub fn statusCode(self: Response) u16 {
            return @backingInt(self.status);
        }

        pub fn reasonPhrase(self: Response) []const u8 {
            return switch (self.status) {
                .ok => "OK",
                .partial_content => "Partial Content",
                .not_found => "Not Found",
                .range_not_satisfiable => "Range Not Satisfiable",
            };
        }

        /// Writes the `Content-Range` value required by 206 / 416 responses.
        /// Emits nothing for 200 / 404.
        pub fn writeContentRange(self: Response, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.status) {
                .partial_content => {
                    const range = self.range orelse return;
                    try writer.print("bytes {d}-{d}/{d}", .{ range.start, range.end, self.total_length });
                },
                .range_not_satisfiable => try writer.print("bytes */{d}", .{self.total_length}),
                .ok, .not_found => {},
            }
        }

        pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
            if (self.owned) |bytes| {
                if (self.release_fn) |release| {
                    release(self.release_ctx, allocator, bytes);
                } else {
                    allocator.free(bytes);
                }
            }
            self.owned = null;
            self.release_fn = null;
            self.release_ctx = null;
            self.body = &.{};
        }
    };

    pub fn init(entries: []const StaticMap.Entry) Assets {
        return .{ .static = .{ .entries = entries } };
    }

    pub fn withLoader(entries: []const StaticMap.Entry, loader: Loader) Assets {
        return .{ .static = .{ .entries = entries }, .loader = loader };
    }

    /// Resolves `target` (a URL path, possibly with query/fragment) to a response.
    pub fn resolve(
        self: Assets,
        allocator: std.mem.Allocator,
        target: []const u8,
        options: Options,
    ) ResolveError!Response {
        // Only path strings live in the arena; asset bytes use the real allocator
        // so they can outlive this call.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const normalized = (try self.normalizeRequest(scratch, target)) orelse return notFound();
        var candidate = normalized.bytes;
        if (normalized.directory) {
            candidate = try self.indexPath(scratch, normalized.bytes);
        }

        var found = try self.fetch(allocator, candidate);
        if (found == null and self.spa_fallback and !hasExtension(normalized.bytes)) {
            const root_index = try self.indexPath(scratch, "/");
            // Directory requests already tried `/index.html`; avoid a duplicate
            // loader hit (and duplicate I/O) for the same path.
            if (!std.mem.eql(u8, candidate, root_index)) {
                candidate = root_index;
                found = try self.fetch(allocator, candidate);
            }
        }

        const loaded = found orelse return notFound();
        return self.buildResponse(candidate, loaded, options);
    }

    const Normalized = struct {
        /// Canonical absolute path: leading `/`, no trailing slash (except `/`).
        bytes: []const u8,
        directory: bool,
    };

    const Loaded = struct {
        asset: Asset,
        owned: ?[]u8 = null,
        release: ?Loader = null,
    };

    fn normalizeRequest(
        self: Assets,
        scratch: std.mem.Allocator,
        target: []const u8,
    ) error{OutOfMemory}!?Normalized {
        var path = target;
        if (std.mem.findAny(u8, path, "?#")) |index| path = path[0..index];
        if (path.len == 0) path = "/";
        if (path.len > self.max_path_len) return null;

        var decoded: ?[]u8 = null;
        defer if (decoded) |bytes| scratch.free(bytes);
        if (std.mem.findScalar(u8, path, '%') != null) {
            decoded = url.percentDecodeAlloc(scratch, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidPercentEncoding => return null,
            };
            path = decoded.?;
        }

        if (!std.unicode.utf8ValidateSlice(path)) return null;

        var output = std.Io.Writer.Allocating.init(scratch);
        errdefer output.deinit();

        var segments = std.mem.splitScalar(u8, path, '/');
        while (segments.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
            // Traversal is rejected, not normalized away.
            if (std.mem.eql(u8, segment, "..")) return null;
            for (segment) |c| {
                if (c == 0 or c == '\\' or c < 0x20 or c == 0x7f) return null;
            }
            output.writer.writeByte('/') catch return error.OutOfMemory;
            output.writer.writeAll(segment) catch return error.OutOfMemory;
        }
        if (output.writer.buffered().len == 0) {
            output.writer.writeByte('/') catch return error.OutOfMemory;
        }

        const bytes = output.toOwnedSlice() catch return error.OutOfMemory;
        return .{ .bytes = bytes, .directory = path.len > 0 and path[path.len - 1] == '/' };
    }

    fn indexPath(self: Assets, scratch: std.mem.Allocator, directory: []const u8) error{OutOfMemory}![]const u8 {
        const base = if (std.mem.eql(u8, directory, "/")) "" else directory;
        return std.fmt.allocPrint(scratch, "{s}/{s}", .{ base, self.index_file });
    }

    fn fetch(self: Assets, allocator: std.mem.Allocator, candidate: []const u8) ResolveError!?Loaded {
        if (self.static.get(candidate)) |asset| return .{ .asset = asset };

        const loader = self.loader orelse return null;
        const relative = if (candidate.len > 0 and candidate[0] == '/') candidate[1..] else candidate;
        const bytes = loader.load(allocator, relative) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LoadFailure,
        };
        const owned = bytes orelse return null;
        return .{
            .asset = .{ .bytes = owned },
            .owned = owned,
            .release = loader,
        };
    }

    fn buildResponse(self: Assets, candidate: []const u8, loaded: Loaded, options: Options) Response {
        _ = self;
        const total: u64 = @intCast(loaded.asset.bytes.len);
        var response: Response = .{
            .status = .ok,
            .mime = loaded.asset.mime orelse mime.detect(candidate, loaded.asset.bytes),
            .body = loaded.asset.bytes,
            .content_length = total,
            .total_length = total,
            .etag = loaded.asset.etag,
            .owned = loaded.owned,
        };
        if (loaded.release) |loader| {
            response.release_ctx = loader.ctx;
            response.release_fn = loader.release_fn;
        }

        const head_only = options.method == .head;
        if (head_only) response.body = &.{};

        if (options.range) |range_header| {
            const range_allowed = if (options.if_range) |if_range|
                http_range.ifRangeMatches(if_range, loaded.asset.etag, null)
            else
                true;

            if (range_allowed) {
                switch (http_range.resolve(range_header, total)) {
                    .full => {},
                    .partial => |range| {
                        response.status = .partial_content;
                        response.range = range;
                        response.content_length = range.length();
                        response.body = if (head_only) &.{} else range.slice(loaded.asset.bytes) orelse &.{};
                    },
                    .unsatisfiable => {
                        response.status = .range_not_satisfiable;
                        response.range = null;
                        response.body = &.{};
                        response.content_length = 0;
                    },
                }
            }
        }

        return response;
    }
};

fn notFound() Assets.Response {
    return .{
        .status = .not_found,
        .mime = "text/plain; charset=utf-8",
        .body = &.{},
        .content_length = 0,
        .total_length = 0,
    };
}

fn hasExtension(path: []const u8) bool {
    const slash = std.mem.findScalarLast(u8, path, '/') orelse 0;
    const basename = path[slash..];
    return std.mem.findScalarLast(u8, basename, '.') != null;
}

const testing = std.testing;

const index_html = "<!doctype html><html><body>index</body></html>";
const script_js = "export const answer = 42;\n";

fn staticAssets() [4]StaticMap.Entry {
    return .{
        .{ .path = "/index.html", .asset = .{ .bytes = index_html, .etag = "\"index-v1\"" } },
        .{ .path = "/assets/app.js", .asset = .{ .bytes = script_js } },
        .{ .path = "/assets/style.css", .asset = .{ .bytes = "body{color:red}" } },
        .{ .path = "/assets/data.bin", .asset = .{ .bytes = "0123456789" } },
    };
}

test "assets: serves embedded index, scripts and styles with correct MIME" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    var root = try assets.resolve(allocator, "/", .{});
    defer root.deinit(allocator);
    try testing.expectEqual(Assets.Status.ok, root.status);
    try testing.expectEqualStrings(index_html, root.body);
    try testing.expectEqualStrings("text/html; charset=utf-8", root.mime);
    try testing.expectEqual(@as(u64, index_html.len), root.content_length);
    try testing.expectEqualStrings("\"index-v1\"", root.etag.?);

    var script = try assets.resolve(allocator, "/assets/app.js?v=1", .{});
    defer script.deinit(allocator);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", script.mime);
    try testing.expectEqualStrings(script_js, script.body);

    var css = try assets.resolve(allocator, "/assets/style.css#hash", .{});
    defer css.deinit(allocator);
    try testing.expectEqualStrings("text/css; charset=utf-8", css.mime);
}

test "assets: unknown paths and unsafe paths are 404" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    const cases = [_][]const u8{
        "/missing.html",
        "/missing.js", // has extension: SPA must not mask it
        "/../../etc/passwd",
        "/%2e%2e/%2e%2e/etc/passwd",
        "/assets/%00/app.js",
        "/assets\\app.js",
        "/%zz",
        "/%",
    };
    for (cases) |target| {
        var response = try assets.resolve(allocator, target, .{});
        defer response.deinit(allocator);
        try testing.expectEqual(Assets.Status.not_found, response.status);
        try testing.expectEqual(@as(usize, 0), response.body.len);
        try testing.expectEqual(@as(u64, 0), response.content_length);
    }
}

test "assets: SPA fallback only for extension-less nested paths" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    for ([_][]const u8{ "/users/42", "/settings/profile", "/dashboard/" }) |target| {
        var response = try assets.resolve(allocator, target, .{});
        defer response.deinit(allocator);
        try testing.expectEqual(Assets.Status.ok, response.status);
        try testing.expectEqualStrings(index_html, response.body);
        try testing.expectEqualStrings("text/html; charset=utf-8", response.mime);
    }

    var disabled = assets;
    disabled.spa_fallback = false;
    var response = try disabled.resolve(allocator, "/users/42", .{});
    defer response.deinit(allocator);
    try testing.expectEqual(Assets.Status.not_found, response.status);
}

test "assets: directory requests resolve to index_file" {
    const entries = [_]StaticMap.Entry{
        .{ .path = "/index.html", .asset = .{ .bytes = index_html } },
        .{ .path = "/docs/index.html", .asset = .{ .bytes = "<html>docs</html>" } },
    };
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    var docs = try assets.resolve(allocator, "/docs/", .{});
    defer docs.deinit(allocator);
    try testing.expectEqualStrings("<html>docs</html>", docs.body);

    // Unknown extension-less directories are SPA routes and serve the shell.
    var spa_route = try assets.resolve(allocator, "/blog/", .{});
    defer spa_route.deinit(allocator);
    try testing.expectEqual(Assets.Status.ok, spa_route.status);
    try testing.expectEqualStrings(index_html, spa_route.body);
}

test "assets: Range requests produce 206 with the correct slice" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    var response = try assets.resolve(allocator, "/assets/data.bin", .{ .range = "bytes=2-4" });
    defer response.deinit(allocator);
    try testing.expectEqual(Assets.Status.partial_content, response.status);
    try testing.expectEqualStrings("234", response.body);
    try testing.expectEqual(@as(u64, 3), response.content_length);
    try testing.expectEqual(@as(u64, 10), response.total_length);
    try testing.expect(response.range.?.eql(.{ .start = 2, .end = 4 }));

    var suffix = try assets.resolve(allocator, "/assets/data.bin", .{ .range = "bytes=-3" });
    defer suffix.deinit(allocator);
    try testing.expectEqualStrings("789", suffix.body);
}

test "assets: unsatisfiable Range produces 416 without a body" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    var response = try assets.resolve(allocator, "/assets/data.bin", .{ .range = "bytes=100-" });
    defer response.deinit(allocator);
    try testing.expectEqual(Assets.Status.range_not_satisfiable, response.status);
    try testing.expectEqual(@as(usize, 0), response.body.len);
    try testing.expectEqual(@as(u64, 0), response.content_length);
    try testing.expectEqual(@as(u64, 10), response.total_length);
    try testing.expect(response.range == null);
}

test "assets: malformed and multi-range headers fall back to 200" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    for ([_][]const u8{ "bytes=abc", "bytes=0-1,4-5", "items=0-1", "bytes=5-2" }) |header| {
        var response = try assets.resolve(allocator, "/assets/data.bin", .{ .range = header });
        defer response.deinit(allocator);
        try testing.expectEqual(Assets.Status.ok, response.status);
        try testing.expectEqualStrings("0123456789", response.body);
        try testing.expectEqual(@as(u64, 10), response.content_length);
    }
}

test "assets: If-Range disables or enables the partial response" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    var stale = try assets.resolve(allocator, "/assets/data.bin", .{
        .range = "bytes=0-1",
        .if_range = "\"other\"",
    });
    defer stale.deinit(allocator);
    try testing.expectEqual(Assets.Status.ok, stale.status);
    try testing.expectEqual(@as(u64, 10), stale.content_length);

    var fresh = try assets.resolve(allocator, "/index.html", .{
        .range = "bytes=0-1",
        .if_range = "\"index-v1\"",
    });
    defer fresh.deinit(allocator);
    try testing.expectEqual(Assets.Status.partial_content, fresh.status);
    try testing.expectEqualStrings("<!", fresh.body);
}

test "assets: HEAD keeps Content-Length but omits the body" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    var full = try assets.resolve(allocator, "/assets/data.bin", .{ .method = .head });
    defer full.deinit(allocator);
    try testing.expectEqual(Assets.Status.ok, full.status);
    try testing.expectEqual(@as(usize, 0), full.body.len);
    try testing.expectEqual(@as(u64, 10), full.content_length);

    var ranged = try assets.resolve(allocator, "/assets/data.bin", .{
        .method = .head,
        .range = "bytes=0-3",
    });
    defer ranged.deinit(allocator);
    try testing.expectEqual(Assets.Status.partial_content, ranged.status);
    try testing.expectEqual(@as(usize, 0), ranged.body.len);
    try testing.expectEqual(@as(u64, 4), ranged.content_length);
}

const MemorySource = struct {
    files: []const File = &.{},
    load_calls: usize = 0,
    release_calls: usize = 0,
    last_path_buf: [256]u8 = undefined,
    last_path_len: usize = 0,

    const File = struct { path: []const u8, bytes: []const u8 };

    fn lastPath(self: *const MemorySource) []const u8 {
        return self.last_path_buf[0..self.last_path_len];
    }

    fn loader(self: *MemorySource) Loader {
        return .{ .ctx = self, .load_fn = load, .release_fn = release };
    }

    fn load(ctx: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *MemorySource = @ptrCast(@alignCast(ctx.?));
        self.load_calls += 1;
        const captured = @min(path.len, self.last_path_buf.len);
        @memcpy(self.last_path_buf[0..captured], path[0..captured]);
        self.last_path_len = captured;
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return try allocator.dupe(u8, file.bytes);
        }
        return null;
    }

    fn release(ctx: ?*anyopaque, allocator: std.mem.Allocator, bytes: []u8) void {
        const self: *MemorySource = @ptrCast(@alignCast(ctx.?));
        self.release_calls += 1;
        allocator.free(bytes);
    }
};

test "assets: loader-backed directory source with exact release accounting" {
    const files = [_]MemorySource.File{
        .{ .path = "index.html", .bytes = "<html>spa</html>" },
        .{ .path = "app.js", .bytes = script_js },
        .{ .path = "assets/logo.svg", .bytes = "<svg></svg>" },
    };
    var source = MemorySource{ .files = &files };
    const assets = Assets.withLoader(&.{}, source.loader());
    const allocator = testing.allocator;

    var script = try assets.resolve(allocator, "/app.js", .{});
    try testing.expectEqual(Assets.Status.ok, script.status);
    try testing.expectEqualStrings(script_js, script.body);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", script.mime);
    try testing.expectEqualStrings("app.js", source.lastPath());
    script.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), source.release_calls);

    var logo = try assets.resolve(allocator, "/assets/logo.svg", .{});
    defer logo.deinit(allocator);
    try testing.expectEqualStrings("image/svg+xml", logo.mime);
    try testing.expectEqualStrings("assets/logo.svg", source.lastPath());

    var spa = try assets.resolve(allocator, "/users/42", .{});
    defer spa.deinit(allocator);
    try testing.expectEqualStrings("<html>spa</html>", spa.body);
    try testing.expectEqualStrings("index.html", source.lastPath());
}

test "assets: loader is never called for unsafe or malformed paths" {
    var source = MemorySource{ .files = &.{} };
    const assets = Assets.withLoader(&.{}, source.loader());
    const allocator = testing.allocator;

    for ([_][]const u8{
        "/../secret.txt",
        "/%2e%2e/secret.txt",
        "/%2E%2E%2Fsecret.txt",
        "/a%00b",
        "/a\\b",
        "/%zz",
        "/a\xffb",
    }) |target| {
        var response = try assets.resolve(allocator, target, .{});
        defer response.deinit(allocator);
        try testing.expectEqual(Assets.Status.not_found, response.status);
    }
    try testing.expectEqual(@as(usize, 0), source.load_calls);
    try testing.expectEqual(@as(usize, 0), source.release_calls);
}

test "assets: encoded separators are decoded before lookup" {
    var source = MemorySource{
        .files = &.{.{
            .path = "nested/app.js",
            .bytes = script_js,
        }},
    };
    const assets = Assets.withLoader(&.{}, source.loader());
    const allocator = testing.allocator;

    var response = try assets.resolve(allocator, "/nested%2Fapp.js", .{});
    defer response.deinit(allocator);
    try testing.expectEqual(Assets.Status.ok, response.status);
    try testing.expectEqualStrings("nested/app.js", source.lastPath());
}

test "assets: range on a loader-backed asset keeps ownership correct" {
    var source = MemorySource{ .files = &.{.{
        .path = "clip.mp4",
        .bytes = "0123456789",
    }} };
    const assets = Assets.withLoader(&.{}, source.loader());
    const allocator = testing.allocator;

    var response = try assets.resolve(allocator, "/clip.mp4", .{ .range = "bytes=4-" });
    try testing.expectEqual(Assets.Status.partial_content, response.status);
    try testing.expectEqualStrings("456789", response.body);
    try testing.expectEqualStrings("video/mp4", response.mime);
    response.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), source.release_calls);
}

test "assets: loader failures surface as LoadFailure" {
    const Failing = struct {
        fn load(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?[]u8 {
            return error.DiskOnFire;
        }
        fn release(_: ?*anyopaque, _: std.mem.Allocator, _: []u8) void {}
    };
    const assets = Assets.withLoader(&.{}, .{ .load_fn = Failing.load, .release_fn = Failing.release });
    try testing.expectError(error.LoadFailure, assets.resolve(testing.allocator, "/app.js", .{}));
}

test "assets: oversized targets are rejected before any work" {
    const entries = staticAssets();
    var assets = Assets.init(&entries);
    assets.max_path_len = 8;
    const allocator = testing.allocator;

    var response = try assets.resolve(allocator, "/assets/app.js", .{});
    defer response.deinit(allocator);
    try testing.expectEqual(Assets.Status.not_found, response.status);
}

test "assets: MIME override wins over extension detection" {
    const entries = [_]StaticMap.Entry{
        .{ .path = "/data.js", .asset = .{ .bytes = "{}", .mime = "application/manifest+json; charset=utf-8" } },
    };
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    var response = try assets.resolve(allocator, "/data.js", .{});
    defer response.deinit(allocator);
    try testing.expectEqualStrings("application/manifest+json; charset=utf-8", response.mime);
}

test "assets: Response exposes status/code and Content-Range builder" {
    const entries = staticAssets();
    const assets = Assets.init(&entries);
    const allocator = testing.allocator;

    var partial = try assets.resolve(allocator, "/assets/data.bin", .{ .range = "bytes=2-4" });
    defer partial.deinit(allocator);
    try testing.expectEqual(@as(u16, 206), partial.statusCode());
    try testing.expectEqualStrings("Partial Content", partial.reasonPhrase());
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try partial.writeContentRange(&writer);
    try testing.expectEqualStrings("bytes 2-4/10", writer.buffered());

    var unsatisfied = try assets.resolve(allocator, "/assets/data.bin", .{ .range = "bytes=100-" });
    defer unsatisfied.deinit(allocator);
    try testing.expectEqual(@as(u16, 416), unsatisfied.statusCode());
    try testing.expectEqualStrings("Range Not Satisfiable", unsatisfied.reasonPhrase());
    var ubuf: [64]u8 = undefined;
    var uwriter = std.Io.Writer.fixed(&ubuf);
    try unsatisfied.writeContentRange(&uwriter);
    try testing.expectEqualStrings("bytes */10", uwriter.buffered());

    var full = try assets.resolve(allocator, "/assets/data.bin", .{});
    defer full.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), full.statusCode());
    try testing.expectEqualStrings("OK", full.reasonPhrase());
    var fbuf: [8]u8 = undefined;
    var fwriter = std.Io.Writer.fixed(&fbuf);
    try full.writeContentRange(&fwriter);
    try testing.expectEqualStrings("", fwriter.buffered());
}

test "assets: StaticMap helpers" {
    const entries = staticAssets();
    const map = StaticMap{ .entries = &entries };
    try testing.expectEqual(@as(usize, 4), map.len());
    try testing.expect(!map.isEmpty());
    try testing.expect(map.get("/index.html") != null);
    try testing.expect(map.get("/nope") == null);
    try testing.expect((StaticMap{}).isEmpty());
}
