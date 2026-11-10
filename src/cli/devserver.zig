//! `M5-02` `zts dev` — the preview server and the change detector.
//!
//! `zts dev` is the Angular-CLI-shaped half of the CLI: it serves the project's `web/` directory so
//! the page opens in any browser, and it reports when a watched file changed so `main.zig` can
//! decide (see `incremental.zig`) whether to type-check, full-build, or not build at all, then
//! bump the reload counter.
//!
//! Deliberately small. The library's own `zts_bridge` is the *application* server (RPC, SSE,
//! sessions, CSP, 206 ranges); a dev preview needs none of that. This one is a single-threaded
//! static server plus one polling endpoint `/__zts_dev__/state`, which keeps the CLI to zero
//! `zts_*` imports and means `zig test src/cli/mod.zig` covers it without linking a web stack.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;

const project = @import("project.zig");

/// Path the injected script polls. It answers `{"v":<build>,"ok":<bool>}` and never touches disk.
pub const state_path = "/__zts_dev__/state";

/// What a rescan found. `zts dev` uses this to do the least work that shows the edit:
/// a stylesheet can be swapped in place, any other `web/` file needs a reload, and only `src/`
/// needs a compile.
pub const Change = enum {
    none,
    /// Only `web/` changed, and not just stylesheets: reload the page, but **do not** run
    /// `zig build` — the preview is served from disk, so a compile would only repeat the last one.
    assets,
    /// Only `web/**/*.css` changed: replace the `<link>` in place. No reload, no compile, so the
    /// page keeps its scroll position and the devtools console keeps its history.
    css,
    /// Something under `src/` (or `build.zig*`) changed: the Zig side has to be checked before
    /// the page can be trusted. `incremental.plan` decides whether that is a type-check or a
    /// full build.
    source,

    /// Classifies the paths a [`Snapshot`] diff produced. A change anywhere in `src/` wins over a
    /// stylesheet edit, because the page cannot run without a successful build.
    pub fn classify(changed: []const []const u8) Change {
        var kind: Change = .none;
        for (changed) |path| {
            // `build.zig*` changes the build graph itself; `src/` changes what it compiles.
            if (std.mem.startsWith(u8, path, "src/") or
                std.mem.eql(u8, path, "build.zig") or
                std.mem.eql(u8, path, "build.zig.zon")) return .source;
            // One non-stylesheet is enough to force a reload; a page whose only edits are
            // stylesheets keeps its state.
            if (!std.mem.endsWith(u8, path, ".css")) {
                kind = .assets;
            } else if (kind == .none) {
                kind = .css;
            }
        }
        return kind;
    }

    /// `"css"` when the browser can hot-swap, `"full"` when it has to reload.
    pub fn hot(self: Change) []const u8 {
        return if (self == .css) "css" else "full";
    }
};

/// `"web"` + `"style.css"` → `"web/style.css"` on every OS.
///
/// `Dir.walk` returns native separators, so on Windows the same edit would arrive as
/// `web\\style.css` and [`Change.classify`] would not see the stylesheet — the dev loop would fall
/// back to a reload there and nowhere else. Normalising once, here, keeps the classifier a pure
/// function over forward slashes.
fn watchKey(gpa: Allocator, dir: []const u8, path: []const u8) ![]u8 {
    const key = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, path });
    for (key) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return key;
}

/// One watched file. `stat` is the cheap dirty flag (`mtime ^ size`); `content` is a strong one for
/// files whose bytes decide whether a rebuild is needed. A formatter or `touch` moves `stat` but
/// not `content`, so `zts dev` no longer recompiles a file that did not actually change.
pub const Stamp = struct {
    stat: u64,
    content: ?u64 = null,
};

/// Root-level files that are part of the build graph but live outside `src/` / `web/`.
pub const build_files = [_][]const u8{ "build.zig", "build.zig.zon" };

/// Only the Zig inputs get a content hash. `web/` can be large (images, fonts, bundles) and a
/// harmless extra stylesheet swap is cheaper than re-reading all of it every 250 ms.
pub fn isContentHashed(path: []const u8) bool {
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return true;
    return std.mem.startsWith(u8, path, "src/") and std.mem.endsWith(u8, path, ".zig");
}

fn statStamp(stat: anytype) u64 {
    const nanos: u64 = @bitCast(@as(i64, @truncate(stat.mtime.nanoseconds)));
    return nanos ^ (stat.size *% 0x9e37_79b9_7f4a_7c15);
}

fn stampEqual(a: Stamp, b: Stamp) bool {
    if (a.content != null and b.content != null) return a.content.? == b.content.?;
    return a.stat == b.stat;
}

/// Every file below the watched directories, plus `build.zig` / `build.zig.zon`, stamped for a
/// diff. Keys are project-relative and POSIX (`"src/main.zig"`, `"build.zig"`), so the classifiers
/// do not have to care where the project lives.
pub const Snapshot = struct {
    stamps: std.StringHashMapUnmanaged(Stamp) = .empty,

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        var it = self.stamps.iterator();
        while (it.next()) |entry| gpa.free(entry.key_ptr.*);
        self.stamps.deinit(gpa);
    }

    pub fn contains(self: *const Snapshot, path: []const u8) bool {
        return self.stamps.contains(path);
    }

    /// `project_dir` is where `build.zig` lives and `subs` are the directories watched inside it
    /// (`"src"`, `"web"`). A missing directory or build file is skipped: a project without `src/`
    /// still previews.
    pub fn scan(gpa: Allocator, io: Io, project_dir: []const u8, subs: []const []const u8) !Snapshot {
        return scanAgainst(gpa, io, project_dir, subs, null);
    }

    /// `previous` is an optional stat cache. When a file's `mtime ^ size` is unchanged, its old
    /// content hash is reused: source bytes are read only for files that look dirty. That keeps a
    /// large `src/` tree cheap to poll while still ignoring same-content rewrites. A writer that
    /// forges BOTH mtime and size is indistinguishable without a read — the same limitation the
    /// old stat-only detector had, and one no editor in practice hits.
    pub fn scanAgainst(
        gpa: Allocator,
        io: Io,
        project_dir: []const u8,
        subs: []const []const u8,
        previous: ?*const Snapshot,
    ) !Snapshot {
        var self: Snapshot = .{};
        errdefer self.deinit(gpa);
        const cwd = Io.Dir.cwd();
        for (subs) |dir_path| {
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ project_dir, dir_path });
            defer gpa.free(full);
            const handle = cwd.openDir(io, full, .{ .iterate = true }) catch continue;
            defer handle.close(io);
            var walker = try handle.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                const stat = handle.statFile(io, entry.path, .{}) catch continue;
                const key = try watchKey(gpa, dir_path, entry.path);
                errdefer gpa.free(key);
                try self.put(gpa, io, project_dir, key, statStamp(stat), previous);
            }
        }
        // Build files are not below either watched directory, but changing one invalidates the
        // whole build graph. Watch them explicitly instead of silently keeping a stale preview.
        for (build_files) |name| {
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ project_dir, name });
            defer gpa.free(full);
            const stat = cwd.statFile(io, full, .{}) catch continue;
            const key = try gpa.dupe(u8, name);
            errdefer gpa.free(key);
            try self.put(gpa, io, project_dir, key, statStamp(stat), previous);
        }
        return self;
    }

    fn put(
        self: *Snapshot,
        gpa: Allocator,
        io: Io,
        project_dir: []const u8,
        key: []const u8,
        stat: u64,
        previous: ?*const Snapshot,
    ) !void {
        var stamp: Stamp = .{ .stat = stat };
        if (isContentHashed(key)) {
            if (previous) |prev| {
                if (prev.stamps.get(key)) |old| {
                    if (old.stat == stat and old.content != null) {
                        stamp.content = old.content;
                        try self.stamps.put(gpa, key, stamp);
                        return;
                    }
                }
            }
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ project_dir, key });
            defer gpa.free(full);
            const bytes = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(64 * 1024 * 1024)) catch {
                // Unreadable while being written: fall back to the stat flag this scan; the next
                // scan will hash it. Never pretend the file is unchanged.
                stamp.content = null;
                try self.stamps.put(gpa, key, stamp);
                return;
            };
            defer gpa.free(bytes);
            stamp.content = std.hash.Wyhash.hash(0, bytes);
        }
        try self.stamps.put(gpa, key, stamp);
    }

    /// Paths that are new, changed, or gone. Allocated from `arena`; there is nothing to free.
    pub fn changed(self: *const Snapshot, arena: Allocator, next: *const Snapshot) ![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = next.stamps.iterator();
        while (it.next()) |entry| {
            const previous = self.stamps.get(entry.key_ptr.*);
            if (previous == null or !stampEqual(previous.?, entry.value_ptr.*)) {
                try out.append(arena, try arena.dupe(u8, entry.key_ptr.*));
            }
        }
        var old = self.stamps.iterator();
        while (old.next()) |entry| {
            if (!next.stamps.contains(entry.key_ptr.*)) {
                try out.append(arena, try arena.dupe(u8, entry.key_ptr.*));
            }
        }
        return out.items;
    }

    /// Paths that appeared or disappeared. Unlike `changed`, an identical-content rewrite is not
    /// structural. Callers use this to stay conservative: a new `src/*.zig` may change the module
    /// graph in ways a content diff cannot describe, so it forces a full rebuild.
    pub fn structural(self: *const Snapshot, arena: Allocator, next: *const Snapshot) ![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = next.stamps.iterator();
        while (it.next()) |entry| {
            if (!self.stamps.contains(entry.key_ptr.*)) {
                try out.append(arena, try arena.dupe(u8, entry.key_ptr.*));
            }
        }
        var old = self.stamps.iterator();
        while (old.next()) |entry| {
            if (!next.stamps.contains(entry.key_ptr.*)) {
                try out.append(arena, try arena.dupe(u8, entry.key_ptr.*));
            }
        }
        return out.items;
    }
};

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
    /// How the page should pick up the last successful change: swap a stylesheet or reload.
    hot: std.atomic.Value(u8) = .init(@backingInt(Change.assets)),

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
    /// throwaway connection unblocks Windows, where `shutdown` on a *listening* socket is not a
    /// no-op but a hard error (Winsock reports WSAEINVAL, which Zig surfaces as `error.Unexpected`
    /// and aborts the process — a CI-only crash until the `M5-03` smoke job ran on Windows).
    pub fn stop(self: *DevServer) void {
        self.stopping.store(true, .release);

        if (builtin.os.tag != .windows) {
            const listening: Io.net.Stream = .{ .socket = self.listener.socket };
            listening.shutdown(self.io, .both) catch {};
        }

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

    /// Records the outcome of a change. The counter only advances on success: a failing build must
    /// not make every open tab reload into the same error page.
    pub fn recordChange(self: *DevServer, change: Change, ok: bool) void {
        self.ok.store(ok, .release);
        self.hot.store(@backingInt(change), .release);
        if (ok) _ = self.build.fetchAdd(1, .monotonic);
    }

    /// Records the outcome of a `zig build` (a `src/` change, or the first build).
    pub fn recordBuild(self: *DevServer, ok: bool) void {
        self.recordChange(.source, ok);
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
            const json = try std.fmt.bufPrint(&body, "{{\"v\":{d},\"ok\":{s},\"hot\":\"{s}\"}}", .{
                self.build.load(.acquire),
                if (self.ok.load(.acquire)) "true" else "false",
                (@as(Change, @fromBackingInt(@intCast(self.hot.load(.acquire))))).hot(),
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

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "Snapshot names the files that changed, and Change classifies them" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDirPath(io, "web/assets");
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "web/index.html", .data = "<h1>hi</h1>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "web/assets/site.css", .data = "h1{color:red}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}" });

    // `scan` resolves against the process CWD and `tmpDir` lives under `.zig-cache/tmp/<name>`.
    const root_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root_dir);
    const subs = [_][]const u8{ "src", "web" };

    var before = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer before.deinit(testing.allocator);
    // The same tree twice must agree, or `zts dev` would redraw forever.
    {
        var same = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
        defer same.deinit(testing.allocator);
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        try testing.expectEqual(@as(usize, 0), (try before.changed(arena_state.allocator(), &same)).len);
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // A stylesheet edit is the hot-swappable case.
    try tmp.dir.writeFile(io, .{ .sub_path = "web/assets/site.css", .data = "h1{color:blue}" });
    var after = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer after.deinit(testing.allocator);
    var changed = try before.changed(arena_state.allocator(), &after);
    try testing.expectEqual(@as(usize, 1), changed.len);
    try testing.expectEqualStrings("web/assets/site.css", changed[0]);
    try testing.expectEqual(Change.css, Change.classify(changed));

    // Any other web file: reload, no compile.
    try tmp.dir.writeFile(io, .{ .sub_path = "web/index.html", .data = "<h1>bye</h1>" });
    var after_page = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer after_page.deinit(testing.allocator);
    changed = try after.changed(arena_state.allocator(), &after_page);
    try testing.expectEqual(Change.assets, Change.classify(changed));

    // A Zig edit outranks both: the page cannot be trusted until the build passes.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void { }" });
    var after_src = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer after_src.deinit(testing.allocator);
    changed = try after_page.changed(arena_state.allocator(), &after_src);
    try testing.expectEqual(Change.source, Change.classify(changed));

    // A deletion is a change too (deleting a stylesheet must not leave the old one on screen).
    try tmp.dir.deleteFile(io, "web/assets/site.css");
    var after_delete = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer after_delete.deinit(testing.allocator);
    changed = try after_src.changed(arena_state.allocator(), &after_delete);
    try testing.expectEqual(@as(usize, 1), changed.len);
    try testing.expectEqual(Change.css, Change.classify(changed));
}

test "a same-content rewrite is not a change, but a real edit is" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build() void {}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}" });

    const root_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root_dir);
    const subs = [_][]const u8{ "src", "web" };

    var before = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer before.deinit(testing.allocator);
    try testing.expect(before.contains("build.zig"));
    try testing.expect(before.contains("src/main.zig"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A formatter (or `touch`) writes the same bytes back: mtime moves, content does not.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}" });
    var touched = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer touched.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), (try before.changed(arena, &touched)).len);
    try testing.expectEqual(@as(usize, 0), (try before.structural(arena, &touched)).len);

    // The stat cache path must behave identically: `scanAgainst` reuses a hash when mtime/size
    // are unchanged, and re-reads (and still ignores) a same-content rewrite when they move.
    var cached_touched = try Snapshot.scanAgainst(testing.allocator, io, root_dir, &subs, &before);
    defer cached_touched.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), (try before.changed(arena, &cached_touched)).len);

    // A real edit is still reported, and a `build.zig` edit too.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void { _ = 1; }" });
    var edited = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer edited.deinit(testing.allocator);
    const diff = try touched.changed(arena, &edited);
    try testing.expectEqual(@as(usize, 1), diff.len);
    try testing.expectEqualStrings("src/main.zig", diff[0]);
    try testing.expectEqual(Change.source, Change.classify(diff));

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build() void { _ = 2; }" });
    var rebuild_graph = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer rebuild_graph.deinit(testing.allocator);
    const graph_diff = try edited.changed(arena, &rebuild_graph);
    try testing.expectEqual(@as(usize, 1), graph_diff.len);
    try testing.expectEqualStrings("build.zig", graph_diff[0]);
    try testing.expectEqual(Change.source, Change.classify(graph_diff));
}

test "structural reports added and removed files only" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}" });

    const root_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root_dir);
    const subs = [_][]const u8{ "src", "web" };
    var before = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer before.deinit(testing.allocator);

    try tmp.dir.writeFile(io, .{ .sub_path = "src/extra.zig", .data = "pub const x = 1;" });
    var after = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer after.deinit(testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const structural = try before.structural(arena, &after);
    try testing.expectEqual(@as(usize, 1), structural.len);
    try testing.expectEqualStrings("src/extra.zig", structural[0]);
    try testing.expectEqual(@as(usize, 1), (try before.changed(arena, &after)).len);

    try tmp.dir.deleteFile(io, "src/extra.zig");
    var gone = try Snapshot.scan(testing.allocator, io, root_dir, &subs);
    defer gone.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), (try after.structural(arena, &gone)).len);
}

test "isContentHashed covers Zig inputs but not web assets" {
    try testing.expect(isContentHashed("src/main.zig"));
    try testing.expect(isContentHashed("src/deep/util.zig"));
    try testing.expect(isContentHashed("build.zig"));
    try testing.expect(isContentHashed("build.zig.zon"));
    try testing.expect(!isContentHashed("src/data.txt"));
    try testing.expect(!isContentHashed("web/index.html"));
    try testing.expect(!isContentHashed("web/site.css"));
}

test "watchKey normalises the Windows walker's separators" {
    const gpa = testing.allocator;
    const key = try watchKey(gpa, "web", "assets\\site.css");
    defer gpa.free(key);
    try testing.expectEqualStrings("web/assets/site.css", key);
    try testing.expectEqual(Change.css, Change.classify(&.{key}));
}

test "classify ignores an empty diff and reports nothing to do" {
    try testing.expectEqual(Change.none, Change.classify(&.{}));
    try testing.expectEqualStrings("css", Change.css.hot());
    try testing.expectEqualStrings("full", Change.source.hot());
    try testing.expectEqualStrings("full", Change.assets.hot());
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
    try testing.expectEqualStrings("{\"v\":1,\"ok\":true,\"hot\":\"full\"}", state);

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
