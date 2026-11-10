//! P1 #12 — runtime updates of the `asset://` scope (`src/tauri/asset_scope.zig`).
//!
//! `ProtocolConfig.asset_allow_globs` is a build-time, immutable slice. Real apps need to grant a
//! path *after* the user picked it in a file dialog (Tauri's `persisted-scope` idea). `AssetScope`
//! is the mutable, mutex-guarded companion: globs added at runtime are checked by
//! `ProtocolRouter.handleFilesystemAsset()` and optionally persisted as a JSON array under
//! `$APPDATA`, so the grant survives a restart.
//!
//! Pure Zig, `link_libc = false`, no OS-specific branch. The same object can be shared between the
//! protocol router and `FsState.withAssetScope()`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const foundation = @import("zts_foundation");
const glob = foundation.glob;

pub const AssetScopeError = Allocator.Error || error{
    /// The `persist_path` could not be written / parsed.
    PersistFailed,
    /// A glob was empty or longer than the 512-byte cap.
    InvalidGlob,
};

pub const max_glob_len = 512;

pub const AssetScope = struct {
    allocator: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    /// Owned glob strings, in insertion order (deterministic).
    globs: std.ArrayList([]u8) = .empty,
    /// Optional JSON file that mirrors `globs`. `null` = in-memory only.
    persist_path: ?[]const u8 = null,

    pub fn init(
        allocator: Allocator,
        io: Io,
        initial: []const []const u8,
        persist_path: ?[]const u8,
    ) AssetScopeError!AssetScope {
        var self: AssetScope = .{ .allocator = allocator, .io = io, .persist_path = persist_path };
        errdefer self.deinit();
        for (initial) |g| try self.appendOwned(g);
        if (persist_path) |_| {
            self.restore() catch |err| switch (err) {
                error.PersistFailed => {}, // no saved grants yet is the normal first-run case
                else => return err,
            };
        }
        return self;
    }

    pub fn deinit(self: *AssetScope) void {
        for (self.globs.items) |g| self.allocator.free(g);
        self.globs.deinit(self.allocator);
    }

    fn appendOwned(self: *AssetScope, pattern: []const u8) AssetScopeError!void {
        if (pattern.len == 0 or pattern.len > max_glob_len) return error.InvalidGlob;
        const copy = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(copy);
        try self.globs.append(self.allocator, copy);
    }

    /// Adds a grant. Returns `false` when it was already present (no duplicate, no disk write).
    pub fn add(self: *AssetScope, pattern: []const u8) AssetScopeError!bool {
        if (pattern.len == 0 or pattern.len > max_glob_len) return error.InvalidGlob;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.globs.items) |g| {
            if (std.mem.eql(u8, g, pattern)) return false;
        }
        try self.appendOwned(pattern);
        try self.persistLocked();
        return true;
    }

    /// Removes a grant. Returns `false` when it was not present.
    pub fn remove(self: *AssetScope, pattern: []const u8) AssetScopeError!bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.globs.items, 0..) |g, i| {
            if (std.mem.eql(u8, g, pattern)) {
                const owned = self.globs.swapRemove(i);
                self.allocator.free(owned);
                try self.persistLocked();
                return true;
            }
        }
        return false;
    }

    pub fn clear(self: *AssetScope) AssetScopeError!void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.globs.items) |g| self.allocator.free(g);
        self.globs.clearRetainingCapacity();
        try self.persistLocked();
    }

    /// Whether any glob admits `path`. Called on every `asset://` request.
    pub fn allows(self: *AssetScope, path: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.globs.items) |g| {
            if (glob.match(g, path)) return true;
        }
        return false;
    }

    /// Snapshot of the current grants, allocated from `allocator`.
    pub fn list(self: *AssetScope, allocator: Allocator) Allocator.Error![]const []const u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const out = try allocator.alloc([]const u8, self.globs.items.len);
        for (self.globs.items, out) |g, *slot| slot.* = g;
        return out;
    }

    fn persistLocked(self: *AssetScope) AssetScopeError!void {
        const path = self.persist_path orelse return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("[") catch return error.OutOfMemory;
        for (self.globs.items, 0..) |g, i| {
            if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
            const escaped = std.json.Stringify.valueAlloc(self.allocator, g, .{}) catch return error.OutOfMemory;
            defer self.allocator.free(escaped);
            w.writeAll(escaped) catch return error.OutOfMemory;
        }
        w.writeAll("]\n") catch return error.OutOfMemory;
        const bytes = try aw.toOwnedSlice();
        defer self.allocator.free(bytes);
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch return error.PersistFailed;
    }

    /// Loads saved grants from `persist_path`. Missing/unreadable files are not an error.
    pub fn restore(self: *AssetScope) AssetScopeError!void {
        const path = self.persist_path orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch
            return error.PersistFailed;
        defer self.allocator.free(bytes);
        // `Value` parsing allocates string buffers. Keep them in a scratch arena so a restored
        // grant list never leaks, while the owned glob copies live in `self.allocator`.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{}) catch
            return error.PersistFailed;
        if (parsed != .array) return error.PersistFailed;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (parsed.array.items) |item| {
            if (item != .string) continue;
            const s = item.string;
            if (s.len == 0 or s.len > max_glob_len) continue;
            var duplicate = false;
            for (self.globs.items) |g| {
                if (std.mem.eql(u8, g, s)) duplicate = true;
            }
            if (!duplicate) try self.appendOwned(s);
        }
    }
};

test "P1 #12: runtime grants are checked, de-duplicated, removed and listed deterministically" {
    var scope = try AssetScope.init(testing.allocator, testing.io, &.{"allowed/**"}, null);
    defer scope.deinit();

    try testing.expect(scope.allows("allowed/pic.png"));
    try testing.expect(!scope.allows("private/secret.txt"));

    try testing.expect(try scope.add("private/**"));
    try testing.expect(!try scope.add("private/**")); // duplicate is a no-op
    try testing.expect(scope.allows("private/secret.txt"));
    const list = try scope.list(testing.allocator);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("allowed/**", list[0]);
    try testing.expectEqualStrings("private/**", list[1]);

    try testing.expect(try scope.remove("private/**"));
    try testing.expect(!try scope.remove("private/**"));
    try testing.expect(!scope.allows("private/secret.txt"));
    try testing.expectError(error.InvalidGlob, scope.add(""));
    var too_long: [513]u8 = undefined;
    @memset(&too_long, 'a');
    try testing.expectError(error.InvalidGlob, scope.add(&too_long));

    try scope.clear();
    try testing.expect(!scope.allows("allowed/pic.png"));
}

test "P1 #12: grants are persisted to JSON and restored on the next launch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = "asset-scope.json";
    // Use an absolute path inside the sandbox-visible temp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPath(testing.io, &path_buf);
    const abs = path_buf[0..abs_len];
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ abs, rel });
    defer testing.allocator.free(full);

    {
        var scope = try AssetScope.init(testing.allocator, testing.io, &.{}, full);
        defer scope.deinit();
        try testing.expect(try scope.add("pictures/**"));
        try testing.expect(try scope.add("$APPDATA/**"));
        const saved = try tmp.dir.readFileAlloc(testing.io, rel, testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(saved);
        try testing.expect(std.mem.indexOf(u8, saved, "pictures/**") != null);
    }
    {
        var scope = try AssetScope.init(testing.allocator, testing.io, &.{}, full);
        defer scope.deinit();
        try testing.expect(scope.allows("pictures/cat.png"));
        try testing.expect(scope.allows("$APPDATA/config.json"));
        try testing.expect(!scope.allows("../../etc/passwd"));
    }
}
