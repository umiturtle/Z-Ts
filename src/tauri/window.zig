//! `plugin:window|*` Multi-Window Registry & Tauri v2 Wire Commands (`src/tauri/window.zig`).
//!
//! Matches `@tauri-apps/api/window` & `@tauri-apps/api/dpi` wire formats bit-for-bit:
//! - Incoming `Size` uses Rust `serde` external tagging: `{"Logical":{"width":...,"height":...}}`
//!   or `{"Physical":{"width":...,"height":...}}` (via `pub const json_union = .{ .style = .external }`).
//! - Outgoing size/position queries (`inner_size`, `outer_size`, `inner_position`, `outer_position`)
//!   return physical pixel structs `{ width, height }` / `{ x, y }` scaled by `scale_factor`.
//! - Every mutation delegates immediately to `ctx.host` VTable (`WebviewHost`, `BridgeHost`, or `RecordingHost`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");

pub const WindowPluginError = core.HostError || error{
    MissingHostContext,
    UnknownWindowLabel,
};

pub const RawDims = struct {
    width: f64,
    height: f64,
};

pub const RawPoint = struct {
    x: f64,
    y: f64,
};

/// Wire-compatible with `@tauri-apps/api/dpi` `new Size(...)` (`{"Logical":{...}} | {"Physical":{...}}`).
pub const WireSize = union(enum) {
    Logical: RawDims,
    Physical: RawDims,

    pub const json_union: rpc.UnionConfig = .{ .style = .external };

    pub fn toLogical(self: WireSize, scale_factor: f64) core.LogicalSize {
        const sf = if (scale_factor > 0.0) scale_factor else 1.0;
        return switch (self) {
            .Logical => |d| .wh(d.width, d.height),
            .Physical => |d| .wh(d.width / sf, d.height / sf),
        };
    }
};

/// Wire-compatible with `@tauri-apps/api/dpi` `new Position(...)` (`{"Logical":{...}} | {"Physical":{...}}`).
pub const WirePosition = union(enum) {
    Logical: RawPoint,
    Physical: RawPoint,

    pub const json_union: rpc.UnionConfig = .{ .style = .external };

    pub fn toLogical(self: WirePosition, scale_factor: f64) core.LogicalPoint {
        const sf = if (scale_factor > 0.0) scale_factor else 1.0;
        return switch (self) {
            .Logical => |p| .xy(p.x, p.y),
            .Physical => |p| .xy(p.x / sf, p.y / sf),
        };
    }
};

pub const PhysicalSizeDto = struct {
    width: i32,
    height: i32,
};

pub const PhysicalPosDto = struct {
    x: i32,
    y: i32,
};

pub const SizeConstraintsDto = struct {
    min_width: ?f64 = null,
    min_height: ?f64 = null,
    max_width: ?f64 = null,
    max_height: ?f64 = null,
};

pub const TrackedWindow = struct {
    id: core.WindowId,
    label: []u8,
    title: []u8,
    size: core.LogicalSize = .wh(800, 600),
    position: core.LogicalPoint = .xy(0, 0),
    scale_factor: f64 = 1.0,
    fullscreen: bool = false,
    minimized: bool = false,
    maximized: bool = false,
    focused: bool = true,
    decorated: bool = true,
    resizable: bool = true,
    maximizable: bool = true,
    minimizable: bool = true,
    closable: bool = true,
    visible: bool = true,
    enabled: bool = true,
    always_on_top: bool = false,
    drag_count: usize = 0,
    theme: []const u8 = "dark",

    fn deinit(self: *TrackedWindow, allocator: Allocator) void {
        allocator.free(self.label);
        allocator.free(self.title);
    }
};

pub const WindowRegistry = struct {
    allocator: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    entries: std.ArrayList(TrackedWindow) = .empty,

    pub fn init(allocator: Allocator, io: Io) WindowRegistry {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *WindowRegistry) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn registerWindow(self: *WindowRegistry, id: core.WindowId, spec: core.WindowSpec) Allocator.Error!void {
        const lbl = try self.allocator.dupe(u8, spec.label);
        errdefer self.allocator.free(lbl);
        const ttl = try self.allocator.dupe(u8, spec.title);
        errdefer self.allocator.free(ttl);

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        // Replace existing label if re-opened
        for (self.entries.items) |*existing| {
            if (std.mem.eql(u8, existing.label, spec.label)) {
                self.allocator.free(existing.label);
                self.allocator.free(existing.title);
                existing.* = .{
                    .id = id,
                    .label = lbl,
                    .title = ttl,
                    .size = spec.size,
                    .position = spec.position orelse .xy(0, 0),
                    .fullscreen = spec.fullscreen,
                    .decorated = spec.decorations,
                    .resizable = spec.resizable,
                    .visible = spec.visible,
                    .always_on_top = spec.always_on_top,
                };
                return;
            }
        }

        try self.entries.append(self.allocator, .{
            .id = id,
            .label = lbl,
            .title = ttl,
            .size = spec.size,
            .position = spec.position orelse .xy(0, 0),
            .fullscreen = spec.fullscreen,
            .decorated = spec.decorations,
            .resizable = spec.resizable,
            .visible = spec.visible,
            .always_on_top = spec.always_on_top,
        });
    }

    pub fn unregisterWindow(self: *WindowRegistry, id: core.WindowId) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.entries.items, 0..) |*e, i| {
            if (e.id.eql(id)) {
                e.deinit(self.allocator);
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    pub fn dragCount(self: *WindowRegistry, label: []const u8) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.label, label)) return e.drag_count;
        }
        return 0;
    }

    pub fn resolveId(self: *WindowRegistry, label: ?[]const u8, fallback_id: core.WindowId) ?core.WindowId {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        if (label) |lbl| {
            for (self.entries.items) |*e| {
                if (std.mem.eql(u8, e.label, lbl)) return e.id;
            }
            if (self.entries.items.len == 0 and fallback_id.isValid()) return fallback_id;
            return null;
        }
        if (fallback_id.isValid()) return fallback_id;
        return if (self.entries.items.len > 0) self.entries.items[0].id else null;
    }

    pub fn labelForIdAlloc(self: *WindowRegistry, allocator: Allocator, id: core.WindowId) Allocator.Error!?[]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.entries.items) |*e| {
            if (e.id.eql(id)) return try allocator.dupe(u8, e.label);
        }
        return null;
    }

    fn findLocked(self: *WindowRegistry, label: ?[]const u8, fallback_id: core.WindowId) ?*TrackedWindow {
        if (label) |lbl| {
            for (self.entries.items) |*e| {
                if (std.mem.eql(u8, e.label, lbl)) return e;
            }
        }
        for (self.entries.items) |*e| {
            if (e.id.eql(fallback_id)) return e;
        }
        return if (label == null and self.entries.items.len > 0) &self.entries.items[0] else null;
    }
};

fn resolveTarget(
    ctx: *rpc.Ctx,
    reg: *WindowRegistry,
    label: ?[]const u8,
) WindowPluginError!struct { host: core.Host, win_id: core.WindowId, scale: f64 } {
    const call_ctx = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;
    reg.mu.lockUncancelable(reg.io);
    defer reg.mu.unlock(reg.io);

    if (reg.findLocked(label, call_ctx.window_id)) |entry| {
        return .{ .host = call_ctx.host, .win_id = entry.id, .scale = entry.scale_factor };
    }
    if (call_ctx.window_id.isValid()) {
        return .{ .host = call_ctx.host, .win_id = call_ctx.window_id, .scale = 1.0 };
    }
    return error.UnknownWindowLabel;
}

/// `plugin:window|*` RPC command namespace (`Schema` key: `.window`).
pub const Commands = struct {
    pub const rpc_prefix = "plugin:window|";
    pub const RpcState = WindowRegistry;

    pub fn get_all_windows(ctx: *rpc.Ctx, reg: *WindowRegistry) Allocator.Error![]const []const u8 {
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.entries.items.len == 0) {
            const single = try ctx.scratch.alloc([]const u8, 1);
            single[0] = "main";
            return single;
        }
        const out = try ctx.scratch.alloc([]const u8, reg.entries.items.len);
        for (reg.entries.items, 0..) |e, i| {
            out[i] = try ctx.scratch.dupe(u8, e.label);
        }
        return out;
    }

    pub fn scale_factor(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) f64 {
        const call_ctx = ctx.getEnv(core.CallContext);
        const fb = if (call_ctx) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.scale_factor else 1.0;
    }

    pub fn inner_size(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) PhysicalSizeDto {
        const call_ctx = ctx.getEnv(core.CallContext);
        const fb = if (call_ctx) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, fb)) |e| {
            return .{
                .width = @intFromFloat(@round(e.size.width.v * e.scale_factor)),
                .height = @intFromFloat(@round(e.size.height.v * e.scale_factor)),
            };
        }
        return .{ .width = 800, .height = 600 };
    }

    pub fn outer_size(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) PhysicalSizeDto {
        return inner_size(ctx, reg, .{ .label = args.label });
    }

    pub fn inner_position(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) PhysicalPosDto {
        const call_ctx = ctx.getEnv(core.CallContext);
        const fb = if (call_ctx) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, fb)) |e| {
            return .{
                .x = @intFromFloat(@round(e.position.x.v * e.scale_factor)),
                .y = @intFromFloat(@round(e.position.y.v * e.scale_factor)),
            };
        }
        return .{ .x = 0, .y = 0 };
    }

    pub fn outer_position(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) PhysicalPosDto {
        return inner_position(ctx, reg, .{ .label = args.label });
    }

    pub fn title(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) Allocator.Error![]const u8 {
        const call_ctx = ctx.getEnv(core.CallContext);
        const fb = if (call_ctx) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, fb)) |e| {
            return ctx.scratch.dupe(u8, e.title);
        }
        return "Z-Ts Application";
    }

    pub fn theme(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) []const u8 {
        const call_ctx = ctx.getEnv(core.CallContext);
        const fb = if (call_ctx) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.theme else "dark";
    }

    pub fn is_fullscreen(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.fullscreen else false;
    }

    pub fn is_minimized(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.minimized else false;
    }

    pub fn is_maximized(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.maximized else false;
    }

    pub fn is_focused(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.focused else true;
    }

    pub fn is_decorated(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.decorated else true;
    }

    pub fn is_resizable(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.resizable else true;
    }

    pub fn is_maximizable(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.maximizable else true;
    }

    pub fn is_minimizable(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.minimizable else true;
    }

    pub fn is_closable(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.closable else true;
    }

    pub fn is_visible(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.visible else true;
    }

    pub fn is_enabled(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.enabled else true;
    }

    pub fn is_always_on_top(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.always_on_top else false;
    }

    pub fn set_title(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: []const u8 },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowTitle(t.win_id, args.value);

        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| {
            const copy = try reg.allocator.dupe(u8, args.value);
            reg.allocator.free(e.title);
            e.title = copy;
        }
    }

    pub fn set_size(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: WireSize },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        const logical = args.value.toLogical(t.scale);
        try t.host.setWindowSize(t.win_id, logical);

        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| {
            e.size = logical;
        }
    }

    pub fn set_min_size(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: ?WireSize = null },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        const logical = if (args.value) |v| v.toLogical(t.scale) else null;
        try t.host.setWindowMinSize(t.win_id, logical);
    }

    pub fn set_max_size(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: ?WireSize = null },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        const logical = if (args.value) |v| v.toLogical(t.scale) else null;
        try t.host.setWindowMaxSize(t.win_id, logical);
    }

    pub fn set_size_constraints(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: SizeConstraintsDto },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        if (args.value.min_width != null or args.value.min_height != null) {
            try t.host.setWindowMinSize(t.win_id, .wh(args.value.min_width orelse 0, args.value.min_height orelse 0));
        }
        if (args.value.max_width != null or args.value.max_height != null) {
            try t.host.setWindowMaxSize(t.win_id, .wh(args.value.max_width orelse 16384, args.value.max_height orelse 16384));
        }
    }

    pub fn set_position(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: WirePosition },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        const logical = args.value.toLogical(t.scale);
        try t.host.setWindowPosition(t.win_id, logical);

        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| {
            e.position = logical;
        }
    }

    pub fn set_fullscreen(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: bool },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowFullscreen(t.win_id, args.value);

        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.fullscreen = args.value;
    }

    pub fn minimize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMinimized(t.win_id, true);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.minimized = true;
    }

    pub fn unminimize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMinimized(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.minimized = false;
    }

    pub fn maximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMaximized(t.win_id, true);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.maximized = true;
    }

    pub fn unmaximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMaximized(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.maximized = false;
    }

    pub fn toggle_maximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const is_max = is_maximized(ctx, reg, .{ .label = args.label });
        if (is_max) return unmaximize(ctx, reg, .{ .label = args.label }) else return maximize(ctx, reg, .{ .label = args.label });
    }

    pub fn internal_toggle_maximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        return toggle_maximize(ctx, reg, .{ .label = args.label });
    }

    pub fn show(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowVisible(t.win_id, true);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.visible = true;
    }

    pub fn hide(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowVisible(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.visible = false;
    }

    pub fn close(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.closeWindow(t.win_id);
    }

    pub fn destroy(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        return close(ctx, reg, .{ .label = args.label });
    }

    pub fn set_decorations(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: bool },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowDecorations(t.win_id, args.value);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.decorated = args.value;
    }

    pub fn set_always_on_top(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: bool },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowAlwaysOnTop(t.win_id, args.value);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.always_on_top = args.value;
    }

    pub fn set_resizable(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: bool },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowResizable(t.win_id, args.value);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.resizable = args.value;
    }

    pub fn set_focus(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowFocus(t.win_id);
    }

    pub fn start_dragging(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        {
            reg.mu.lockUncancelable(reg.io);
            defer reg.mu.unlock(reg.io);
            if (reg.findLocked(args.label, t.win_id)) |e| e.drag_count += 1;
        }
        try t.host.startWindowDrag(t.win_id);
    }
};

test "plugin:window handles Tauri Size external tagging, HiDPI scaling, drag & double-click maximize" {
    var rec = core.RecordingHost.init(testing.allocator);
    defer rec.deinit();
    const win_id = try rec.host().createWindow(.{ .label = "main", .title = "Init", .size = .wh(800, 600) });

    var reg = WindowRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    try reg.registerWindow(win_id, .{ .label = "main", .title = "Init", .size = .wh(800, 600) });
    reg.entries.items[0].scale_factor = 2.0; // Simulate 2x Retina / 200% HiDPI display!

    const S = rpc.Schema(.{ .window = Commands });
    var router = S.bind(.{ .window = &reg });
    const h = router.handler();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var call_ctx: core.CallContext = .{ .host = rec.host(), .window_id = win_id };
    var ctx = rpc.Ctx.init(testing.io, arena.allocator()).withEnv(&call_ctx);

    // Physical 2560x1440 at 2.0x scale -> 1280x720 LogicalSize on Host!
    var r1 = h.dispatch(
        arena.allocator(),
        &ctx,
        "plugin:window|set_size",
        "{\"label\":\"main\",\"value\":{\"Physical\":{\"width\":2560,\"height\":1440}}}",
    );
    defer r1.deinit();
    try testing.expectEqual(core.IpcStatus.ok, r1.status);
    try testing.expectEqual(@as(f64, 1280.0), reg.entries.items[0].size.width.v);
    try testing.expectEqual(@as(f64, 720.0), reg.entries.items[0].size.height.v);

    // Drag & double-click internal_toggle_maximize
    var r2 = h.dispatch(arena.allocator(), &ctx, "plugin:window|start_dragging", "{}");
    defer r2.deinit();
    var r3 = h.dispatch(arena.allocator(), &ctx, "plugin:window|internal_toggle_maximize", "{}");
    defer r3.deinit();
    try testing.expect(reg.entries.items[0].maximized);
}
