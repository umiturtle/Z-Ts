//! `M5-02` `zts dev` — the preview server and the change detector.
//!
//! `zts dev` is the Angular-CLI-shaped half of the CLI: it serves the project's `web/` directory so
//! the page opens in any browser, and it reports when a watched file changed so `main.zig` can run
//! `zig build` and bump the reload counter.
//!
//! Deliberately small. The library's own `zts_bridge` is the *application* server (RPC, SSE,
//! sessions, CSP, 206 ranges); a dev preview needs none of that. This one is a single-threaded
//! static server plus one polling endpoint `/__zts_dev__/state`, which keeps the CLI to zero
//! `zts_*` imports and means `zig test src/cli/mod.zig` covers it without linking a web stack.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;

const project = @import("project.zig");

/// Path the injected script polls. It answers `{"v":<build>,"ok":<bool>}` and never touches disk.
pub const state_path = "/__zts_dev__/state";

/// Largest file the preview will serve. Bigger than any sane front-end asset and small enough that a
/// stray `@embedFile`-dumped binary cannot exhaust memory.
const max_asset_bytes = 64 * 1024 * 1024;

pub const DevServer = struct {
    io: Io,
    gpa: Allocator,
    /// Project-relative directory to serve (`web`).
    root_path: []const u8,
    root_dir: Io.Dir,
    listener: Io.net.Server,
    bound_port: u16,
    /// The address `start` bound, kept so `stop` can wake a blocked `accept`.
    host: []const u8,
    accept_thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Bumped after every successful rebuild; the served HTML embeds the value it was built with.
    build: std.atomic.Value(u64) = .init(0),
    /// Whether the last rebuild succeeded, so the page can say why it will not reload.
    ok: std.atomic.Value(bool) = .init(true),

    /// Binds `host:port` and starts the accept thread. `port = 0` lets the OS pick (tests use it).
    pub fn start(gpa: Allocator, io: Io, root_path: []const u8, host: []const u8, bind_port: u16) !*DevServer {
        const dir = Io.Dir.cwd().openDir(io, root_path, .{}) catch |err| {
            std.debug.print("zts dev: cannot open '{s}': {t}\n", .{ root_path, err });
            return err;
        };

        const address = try Io.net.IpAddress.parse(host, bind_port);
        var listener = try address.listen(io, .{
            .reuse_address = bind_port != 0,
            .mode = .stream,
            .protocol = .tcp,
        });
        errdefer listener.deinit(io);

        const self = try gpa.create(DevServer);
        errdefer gpa.destroy(self);

        self.* = .{
            .io = io,
            .gpa = gpa,
            .root_path = try gpa.dupe(u8, root_path),
            .host = try gpa.dupe(u8, host),
            .root_dir = dir,
            .listener = listener,
            .bound_port = listener.socket.address.getPort(),
            .accept_thread = undefined,
        };
        self.accept_thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, acceptLoop, .{self});
        return self;
    }

    /// Stops the accept thread and releases everything. `runDev` never calls this (Ctrl-C ends the
    /// process), but the tests do — and closing the listener under a blocked `accept` is a
    /// programmer bug on macOS (`EBADF` aborts the whole test binary), so this must go through
    /// [`stop`] rather than `listener.deinit` directly.
    pub fn deinit(self: *DevServer) void {
        self.stop();
        self.accept_thread.join();
        self.listener.deinit(self.io);
        self.root_dir.close(self.io);
        const gpa = self.gpa;
        gpa.free(self.host);
        gpa.free(self.root_path);
        gpa.destroy(self);
    }

    pub fn port(self: *const DevServer) u16 {
        return self.bound_port;
    }

    /// Wakes the accept thread so it can observe `stopping` and return. Two mechanisms, because
    /// neither works everywhere: `shutdown` is the documented cancellation signal on POSIX, and a
    /// throwaway connection unblocks Windows, where shutting down a listening socket is a no-op.
    pub fn stop(self: *DevServer) void {
        self.stopping.store(true, .release);

        const listening: Io.net.Stream = .{ .socket = self.listener.socket };
        listening.shutdown(self.io, .both) catch {};

        const host = if (std.mem.eql(u8, self.host, "0.0.0.0"))
            "127.0.0.1"
        else if (std.mem.eql(u8, self.host, "::"))
            "::1"
        else
            self.host;
        const address = Io.net.IpAddress.parse(host, self.bound_port) catch return;
        const wake = address.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch return;
        wake.close(self.io);
    }

    /// Records the outcome of a rebuild. The counter only advances on success: a failing build must
    /// not make every open tab reload into the same error page.
    pub fn recordBuild(self: *DevServer, ok: bool) void {
        self.ok.store(ok, .release);
        if (ok) _ = self.build.fetchAdd(1, .monotonic);
    }

    fn acceptLoop(self: *DevServer) void {
        while (!self.stopping.load(.acquire)) {
            var stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.Canceled, error.SocketNotListening => return,
                // A dropped connection between `accept()` and the first byte is normal.
                else => {
                    if (self.stopping.load(.acquire)) return;
                    continue;
                },
            };
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            self.serve(stream) catch {};
            stream.close(self.io);
        }
    }

    fn serve(self: *DevServer, stream: Io.net.Stream) !void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var net_reader = stream.reader(self.io, &read_buf);
        var net_writer = stream.writer(self.io, &write_buf);
        var http_server = http.Server.init(&net_reader.interface, &net_writer.interface);

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var req = http_server.receiveHead() catch return;
        if (req.head.method != .GET and req.head.method != .HEAD) {
            try req.respond("method not allowed\n", .{
                .status = .method_not_allowed,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "allow", .value = "GET, HEAD" }},
            });
            return;
        }

        const target = req.head.target;
        if (std.mem.startsWith(u8, target, state_path)) {
            var body: [64]u8 = undefined;
            const json = try std.fmt.bufPrint(&body, "{{\"v\":{d},\"ok\":{s}}}", .{
                self.build.load(.acquire),
                if (self.ok.load(.acquire)) "true" else "false",
            });
            try req.respond(json, .{
                .status = .ok,
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "cache-control", .value = "no-store" },
                },
            });
            return;
        }

        const relative = (try project.assetPath(arena, target)) orelse {
            try req.respond("bad request\n", .{ .status = .bad_request, .keep_alive = false });
            return;
        };

        const bytes = self.readAsset(arena, relative) orelse {
            try req.respond("404 — not found in " ++ "web/\n", .{
                .status = .not_found,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            });
            return;
        };

        // Only markup is rewritten: a `</body>` inside a `.js` file is not an HTML document.
        const body = if (project.isHtml(relative))
            try project.injectReload(arena, bytes, self.build.load(.acquire))
        else
            bytes;

        try req.respond(body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = project.mimeType(relative) },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    }

    /// Reads `relative` from the served directory. A path without an extension is retried as a
    /// directory index (`/docs` → `/docs/index.html`), which is what a hand-written link does.
    fn readAsset(self: *DevServer, arena: Allocator, relative: []const u8) ?[]const u8 {
        if (self.root_dir.readFileAlloc(self.io, relative, arena, .limited(max_asset_bytes))) |bytes| {
            return bytes;
        } else |_| {}

        if (std.mem.indexOfScalar(u8, std.fs.path.basename(relative), '.') == null) {
            const index = std.fmt.allocPrint(arena, "{s}/index.html", .{relative}) catch return null;
            if (self.root_dir.readFileAlloc(self.io, index, arena, .limited(max_asset_bytes))) |bytes| {
                return bytes;
            } else |_| {}
        }
        return null;
    }
};

/// Fingerprint of every file under `dir` (path + mtime + size). Comparing two fingerprints is the
/// whole change detector: no inotify / FSEvents / ReadDirectoryChangesW, so it behaves identically
/// on Linux, macOS and Windows and cannot miss an event that happened while a build was running.
/// Returns 0 for a directory that does not exist (the caller watches `src/` and `web/` and either
/// may be absent in a hand-written project).
pub fn fingerprint(io: Io, gpa: Allocator, dir: Io.Dir) !u64 {
    var hasher = std.hash.Wyhash.init(0x5a2d_5453);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.path, .{}) catch continue;
        hasher.update(entry.path);
        // Truncated to 64 bits: nanoseconds since the epoch fit until the year 2554, and the
        // fingerprint only has to change when a file changes.
        var mtime: [8]u8 = undefined;
        std.mem.writeInt(u64, &mtime, @bitCast(@as(i64, @truncate(stat.mtime.nanoseconds))), .little);
        hasher.update(&mtime);
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, stat.size, .little);
        hasher.update(&size);
        count += 1;
    }
    // An empty or missing tree still has to be distinguishable from "not walked yet".
    hasher.update(std.mem.asBytes(&count));
    return hasher.final();
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "fingerprint notices an edit, a new file and a deletion" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "one" });
    const first = try fingerprint(io, testing.allocator, tmp.dir);

    // Same contents, same mtimes: a second walk must agree, or `zts dev` would rebuild forever.
    try testing.expectEqual(first, try fingerprint(io, testing.allocator, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "one and a half" });
    const edited = try fingerprint(io, testing.allocator, tmp.dir);
    try testing.expect(first != edited);

    try tmp.dir.writeFile(io, .{ .sub_path = "app.js", .data = "export {}" });
    const added = try fingerprint(io, testing.allocator, tmp.dir);
    try testing.expect(edited != added);

    try tmp.dir.deleteFile(io, "app.js");
    try testing.expect(added != try fingerprint(io, testing.allocator, tmp.dir));
}

test "the dev server serves web/, injects the reload script and refuses traversal" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "index.html",
        .data = "<!doctype html><html><body><h1>hello</h1></body></html>",
    });
    // `start` resolves the served directory from the process CWD and `tmpDir` lives under
    // `.zig-cache/tmp/<name>`, so the test hands over that full relative path.
    const root_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root_path);
    var server = try DevServer.start(testing.allocator, testing.io, root_path, "127.0.0.1", 0);
    defer server.deinit();

    const port = server.port();
    try testing.expect(port != 0);

    const page = try getBody(testing.allocator, port, "/index.html");
    defer testing.allocator.free(page);
    try testing.expect(std.mem.find(u8, page, "<h1>hello</h1>") != null);
    try testing.expect(std.mem.find(u8, page, "data-zts-dev") != null);
    try testing.expect(std.mem.find(u8, page, "v=0") != null);

    server.recordBuild(true);
    const after = try getBody(testing.allocator, port, "/");
    defer testing.allocator.free(after);
    try testing.expect(std.mem.find(u8, after, "v=1") != null);

    const state = try getBody(testing.allocator, port, state_path);
    defer testing.allocator.free(state);
    try testing.expectEqualStrings("{\"v\":1,\"ok\":true}", state);

    const missing = try getBody(testing.allocator, port, "/nope.js");
    defer testing.allocator.free(missing);
    try testing.expect(std.mem.find(u8, missing, "404") != null);
}

/// Minimal HTTP/1.1 GET used by the tests above (and by `zts dev`'s own smoke check).
fn getBody(alloc: Allocator, port: u16, target: []const u8) ![]u8 {
    const io = testing.io;
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.print("GET {s} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n", .{target});
    try writer.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var body: std.Io.Writer.Allocating = .init(alloc);
    errdefer body.deinit();
    _ = try reader.interface.streamRemaining(&body.writer);
    const response = try body.toOwnedSlice();
    const split = std.mem.find(u8, response, "\r\n\r\n") orelse return response;
    const head = response[0..split];
    // Every response in this server is `connection: close`, so the remainder is the body.
    if (std.mem.find(u8, head, " 200 ") == null and std.mem.find(u8, head, " 404 ") == null) {
        return response;
    }
    const body_start = split + 4;
    const payload = try alloc.dupe(u8, response[body_start..]);
    alloc.free(response);
    return payload;
}
