//! P1 #9 — Monitor / DPI information, in Pure Zig (`src/tauri/monitor.zig`).
//!
//! Tauri v2 exposes `currentMonitor()`, `primaryMonitor()`, `availableMonitors()`,
//! `monitorFromPoint()` and `cursorPosition()`. Enumerating real displays needs an OS API per
//! backend, so ziggurats keeps that behind a tiny provider vtable in the same spirit as
//! `core.Host`: the default provider is a **deterministic single 1920×1080 @1.0 monitor** used by
//! `HeadlessMock`, CI and screenshot parity checks; a native backend can install its own provider
//! without any `if (windows)` branch in application code.
//!
//! All coordinates are physical pixels, matching `@tauri-apps/api/window` and `@tauri-apps/api/dpi`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Physical-pixel point.
pub const Point = struct { x: i32, y: i32 };
/// Physical-pixel size.
pub const Size = struct { width: u32, height: u32 };
/// Physical-pixel rectangle (work area / monitor bounds).
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };

/// Wire-compatible with `@tauri-apps/api/window`'s `Monitor`.
pub const Monitor = struct {
    /// Human-readable display name, when the backend supplies one.
    name: ?[]const u8 = null,
    /// Device pixel ratio (1.0 = no HiDPI scaling).
    scale_factor: f64 = 1.0,
    /// Top-left corner in physical pixels.
    position: Point = .{ .x = 0, .y = 0 },
    /// Full size in physical pixels.
    size: Size = .{ .width = 1920, .height = 1080 },
    /// Usable area in physical pixels (excludes the menu bar / dock / taskbar).
    work_area: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1040 },

    /// Full physical-pixel rectangle of this display.
    pub fn bounds(self: Monitor) Rect {
        return .{ .x = self.position.x, .y = self.position.y, .width = self.size.width, .height = self.size.height };
    }

    /// Whether this physical pixel lies inside the display bounds.
    pub fn contains(self: Monitor, x: i32, y: i32) bool {
        const b = self.bounds();
        return x >= b.x and y >= b.y and
            x < b.x + @as(i32, @intCast(b.width)) and
            y < b.y + @as(i32, @intCast(b.height));
    }
};

/// A live source of monitor information. Both callbacks may be `null`; the built-in deterministic
/// list / cursor are used then. Native backends install one provider for the whole process.
pub const Provider = struct {
    /// Opaque pointer handed back to every provider callback.
    ctx: ?*anyopaque = null,
    /// Returns an **owned** slice. `setProvider` copies it and frees the returned buffer.
    list: ?*const fn (?*anyopaque, Allocator) Allocator.Error![]const Monitor = null,
    /// Current cursor position in physical pixels.
    cursor: ?*const fn (?*anyopaque) Point = null,
};

/// Registry of the displays the app can see. Mutable because `setMonitors()` may be called when a
/// monitor is plugged in; guarded so a command on the event loop cannot race a worker thread.
pub const MonitorRegistry = struct {
    /// Allocator that owns this object's strings and buffers.
    allocator: Allocator,
    /// IO reactor used for filesystem access and mutexes.
    io: Io,
    /// Guards mutable state; commands may arrive from any thread.
    mu: Io.Mutex = .init,
    /// Owned copy of the current monitor list.
    monitors: []Monitor = &.{},
    /// Optional native source of live display information.
    provider: Provider = .{},

    /// Creates an empty, deterministic instance.
    pub fn init(allocator: Allocator, io: Io) Allocator.Error!MonitorRegistry {
        const one = try allocator.alloc(Monitor, 1);
        one[0] = .{ .name = "default" };
        return .{ .allocator = allocator, .io = io, .monitors = one };
    }

    /// Frees every owned buffer and poisons the value.
    pub fn deinit(self: *MonitorRegistry) void {
        self.allocator.free(self.monitors);
        self.monitors = &.{};
    }

    /// Installs a native provider and immediately refreshes the list.
    pub fn setProvider(self: *MonitorRegistry, provider: Provider) Allocator.Error!void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.provider = provider;
        if (provider.list) |list_fn| {
            const fresh = try list_fn(provider.ctx, self.allocator);
            if (fresh.ptr == self.monitors.ptr) return; // provider handed back our own buffer
            const copy = self.allocator.dupe(Monitor, fresh) catch |err| {
                self.allocator.free(fresh);
                return err;
            };
            self.allocator.free(fresh);
            self.allocator.free(self.monitors);
            self.monitors = copy;
        }
    }

    /// Replaces the monitor list (called on a display-change notification).
    pub fn setMonitors(self: *MonitorRegistry, monitors: []const Monitor) Allocator.Error!void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const copy = try self.allocator.dupe(Monitor, monitors);
        self.allocator.free(self.monitors);
        self.monitors = copy;
    }

    /// Primary display: first entry, or a deterministic fallback when the provider returns none.
    pub fn primary(self: *MonitorRegistry) Monitor {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return if (self.monitors.len > 0) self.monitors[0] else .{ .name = "default" };
    }

    /// All displays, copied into `allocator` (the caller usually uses `ctx.scratch`).
    pub fn all(self: *MonitorRegistry, allocator: Allocator) Allocator.Error![]const Monitor {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return allocator.dupe(Monitor, self.monitors);
    }

    /// The display containing `(x, y)`, or `null` when the point is outside every display.
    pub fn fromPoint(self: *MonitorRegistry, x: i32, y: i32) ?Monitor {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.monitors) |m| {
            if (m.contains(x, y)) return m;
        }
        return null;
    }

    /// Current cursor position in physical pixels.
    pub fn cursor(self: *MonitorRegistry) Point {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.provider.cursor) |cursor_fn| return cursor_fn(self.provider.ctx);
        return .{ .x = 0, .y = 0 };
    }
};

/// Logical → physical conversion used by `scale_factor` and the DPI helpers.
pub fn toPhysical(logical: f64, scale_factor: f64) i32 {
    const sf = if (scale_factor > 0) scale_factor else 1.0;
    return @intFromFloat(@round(logical * sf));
}

test "P1 #9: deterministic default monitor, point lookup and logical → physical" {
    var reg = try MonitorRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();

    const primary = reg.primary();
    try testing.expectEqualStrings("default", primary.name.?);
    try testing.expectEqual(@as(f64, 1), primary.scale_factor);
    try testing.expectEqual(@as(u32, 1920), primary.size.width);
    try testing.expect(reg.fromPoint(100, 100) != null);
    try testing.expect(reg.fromPoint(-1, 0) == null);
    try testing.expect(reg.fromPoint(1920, 0) == null);
    try testing.expectEqual(@as(i32, 200), toPhysical(100, 2));
    try testing.expectEqual(@as(i32, 100), toPhysical(100, 0));

    const monitors = [_]Monitor{
        .{ .name = "left", .position = .{ .x = 0, .y = 0 }, .size = .{ .width = 1920, .height = 1080 }, .scale_factor = 1 },
        .{ .name = "right", .position = .{ .x = 1920, .y = 0 }, .size = .{ .width = 2560, .height = 1440 }, .scale_factor = 2 },
    };
    try reg.setMonitors(&monitors);
    try testing.expectEqualStrings("left", reg.primary().name.?);
    try testing.expectEqualStrings("right", reg.fromPoint(2000, 100).?.name.?);
    try testing.expect(reg.fromPoint(-10, 0) == null);
    const all = try reg.all(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
}

test "P1 #9: a native provider supplies monitors and a cursor without OS branches in the caller" {
    const Ctx = struct {
        var calls: usize = 0;
        fn list(_: ?*anyopaque, allocator: Allocator) Allocator.Error![]const Monitor {
            calls += 1;
            const out = try allocator.alloc(Monitor, 1);
            out[0] = .{ .name = "native", .scale_factor = 1.5, .size = .{ .width = 3840, .height = 2160 } };
            return out;
        }
        fn cursor(_: ?*anyopaque) Point {
            return .{ .x = 42, .y = 24 };
        }
    };
    var reg = try MonitorRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    try reg.setProvider(.{ .list = Ctx.list, .cursor = Ctx.cursor });
    try testing.expectEqual(@as(usize, 1), Ctx.calls);
    try testing.expectEqualStrings("native", reg.primary().name.?);
    try testing.expectEqual(@as(f64, 1.5), reg.primary().scale_factor);
    try testing.expectEqual(@as(i32, 42), reg.cursor().x);
    try testing.expectEqual(@as(i32, 150), toPhysical(100, 1.5));
}
