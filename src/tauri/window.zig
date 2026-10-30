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

/// `plugin:window` failures: the host blew up (`core.HostError`) or the request itself was wrong.
/// `MissingHostContext` means the plugin was used without a `Host` (a unit test forgot `.withHost`),
/// `UnknownWindowLabel` means the JS asked for a window that was never created.
pub const WindowPluginError = core.HostError || error{
    MissingHostContext,
    UnknownWindowLabel,
};

/// Width/height pair as it arrives on the wire, in the unit named by the enclosing union arm.
pub const RawDims = struct {
    /// Width in the unit named by the caller (logical for `.Logical`, device pixels for `.Physical`).
    width: f64,
    /// Height in the same unit as `width`.
    height: f64,
};

/// X/Y pair as it arrives on the wire.
pub const RawPoint = struct {
    /// X position in the unit named by the caller.
    x: f64,
    /// Y position in the same unit as `x`.
    y: f64,
};

/// Wire-compatible with `@tauri-apps/api/dpi` `new Size(...)` (`{"Logical":{...}} | {"Physical":{...}}`).
pub const WireSize = union(enum) {
    /// Size in logical (CSS) pixels — the unit a page lays out in.
    Logical: RawDims,
    /// Size in device pixels; scaled by the window's factor before use.
    Physical: RawDims,

    /// Externally tagged (`{ "Logical": { width, height } }`), as upstream sends it.
    pub const json_union: rpc.UnionConfig = .{ .style = .external };

    /// Converts either arm to logical pixels, using `scale_factor` for the physical one.
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
    /// Position in logical (CSS) pixels.
    Logical: RawPoint,
    /// Position in device pixels.
    Physical: RawPoint,

    /// Externally tagged (`{ "Physical": { x, y } }`).
    pub const json_union: rpc.UnionConfig = .{ .style = .external };

    /// Converts either arm to logical pixels.
    pub fn toLogical(self: WirePosition, scale_factor: f64) core.LogicalPoint {
        const sf = if (scale_factor > 0.0) scale_factor else 1.0;
        return switch (self) {
            .Logical => |p| .xy(p.x, p.y),
            .Physical => |p| .xy(p.x / sf, p.y / sf),
        };
    }
};

/// Physical (device) pixels as reported by the host — what `@tauri-apps/api` expects back from
/// `innerSize()`. Divide by the scale factor to get the logical size the page was laid out in.
pub const PhysicalSizeDto = struct {
    /// Width in device pixels.
    width: i32,
    /// Height in device pixels.
    height: i32,
};

/// Physical (device) pixel position of the window's outer top-left corner.
pub const PhysicalPosDto = struct {
    /// X in device pixels, relative to the screen origin.
    x: i32,
    /// Y in device pixels, relative to the screen origin.
    y: i32,
};

/// `null` means "no constraint on that side", which is different from `0` (a window may not be
/// resized to 0×0 but the constraint itself is absent).
pub const SizeConstraintsDto = struct {
    /// Smallest allowed width in logical pixels; `null` = unconstrained.
    min_width: ?f64 = null,
    /// Smallest allowed height; `null` = unconstrained.
    min_height: ?f64 = null,
    /// Largest allowed width; `null` = unconstrained.
    max_width: ?f64 = null,
    /// Largest allowed height; `null` = unconstrained.
    max_height: ?f64 = null,
};

/// The engine's mirror of one OS window. The WebView is the source of truth for pixels; this book
/// keeping exists because `@tauri-apps/api` can read back properties (`isMaximized()`,
/// `scaleFactor()`, …) that a WebView API cannot answer synchronously.
pub const TrackedWindow = struct {
    /// Live `WindowId`; `0` once the window is gone.
    id: core.WindowId,
    /// Stable JS-visible label (`"main"`, `"settings"`, …). Owned copy, never borrowed.
    label: []u8,
    /// Last title set through the API (the OS may have been changed externally).
    title: []u8,
    /// Client-area size in logical pixels, as last reported by the backend.
    size: core.LogicalSize = .wh(800, 600),
    /// Outer top-left corner in logical pixels.
    position: core.LogicalPoint = .xy(0, 0),
    /// Device pixel ratio last reported by the backend (1.0 = no HiDPI).
    scale_factor: f64 = 1.0,
    /// Whether the window is fullscreen.
    fullscreen: bool = false,
    /// Whether the window is minimised.
    minimized: bool = false,
    /// Whether the window is maximised.
    maximized: bool = false,
    /// Whether the window currently has keyboard focus.
    focused: bool = true,
    /// Whether the native title bar is drawn.
    decorated: bool = true,
    /// Whether the user may resize the window.
    resizable: bool = true,
    /// Whether the maximise button is enabled.
    maximizable: bool = true,
    /// Whether the minimise button is enabled.
    minimizable: bool = true,
    /// Whether the close button is enabled.
    closable: bool = true,
    /// Whether the window is mapped.
    visible: bool = true,
    /// Whether the window accepts input (`setEnabled`).
    enabled: bool = true,
    /// Whether the window stays above others.
    always_on_top: bool = false,
    /// How many `startDragging()` calls are outstanding; the OS drag ends when it returns to 0.
    drag_count: usize = 0,
    /// Title-bar theme requested for this window.
    theme: []const u8 = "dark",

    fn deinit(self: *TrackedWindow, allocator: Allocator) void {
        allocator.free(self.label);
        allocator.free(self.title);
    }
};

/// Label ⇄ `WindowId` map for `plugin:window`. Guarded by a mutex because a command may be
/// dispatched from the event loop while a worker thread reads a label.
pub const WindowRegistry = struct {
    /// Allocator that owns the labels, titles and entry array.
    allocator: Allocator,
    /// IO reactor used for the mutex.
    io: Io,
    /// Guards `entries`: commands run on the event loop while worker threads may read.
    mu: Io.Mutex = .init,
    /// Every live window, in creation order.
    entries: std.ArrayList(TrackedWindow) = .empty,

    /// Creates an empty registry. One per engine; `withCorePlugins()` owns it.
    pub fn init(allocator: Allocator, io: Io) WindowRegistry {
        return .{ .allocator = allocator, .io = io };
    }

    /// Frees every tracked window's label and title.
    pub fn deinit(self: *WindowRegistry) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Records a window the host just created. Called by the plugin before the first command can see it.
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

    /// Forgets a closed window. Safe to call for an id that is already gone.
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

    /// How many `start_dragging()` calls are outstanding for `label` (0 = not being dragged).
    pub fn dragCount(self: *WindowRegistry, label: []const u8) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.label, label)) return e.drag_count;
        }
        return 0;
    }

    /// Maps a JS `label` (or `null` for the focused window) to a live `WindowId`, or `error.UnknownWindowLabel`.
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

    /// Returns an owned copy of the label for `id`, or `null` when the window is gone.
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
    /// Every command in this namespace starts with this prefix.
    pub const rpc_prefix = "plugin:window|";
    /// The state type `zts_rpc` resolves per app; identical to `WindowRegistry` here.
    pub const RpcState = WindowRegistry;

    /// `plugin:window|get_all_windows` — labels of every open window.
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

    /// `plugin:window|scale_factor` — device pixel ratio of the window (1.0 = no HiDPI).
    pub fn scale_factor(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) f64 {
        const call_ctx = ctx.getEnv(core.CallContext);
        const fb = if (call_ctx) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.scale_factor else 1.0;
    }

    /// `plugin:window|inner_size` — client-area size in device pixels.
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

    /// `plugin:window|outer_size` — size including the frame, in device pixels.
    pub fn outer_size(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) PhysicalSizeDto {
        return inner_size(ctx, reg, .{ .label = args.label });
    }

    /// `plugin:window|inner_position` — client-area origin in device pixels.
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

    /// `plugin:window|outer_position` — window origin including the frame, in device pixels.
    pub fn outer_position(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) PhysicalPosDto {
        return inner_position(ctx, reg, .{ .label = args.label });
    }

    /// `plugin:window|title` — current title.
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

    /// `plugin:window|theme` — title-bar theme (`"dark"` / `"light"`).
    pub fn theme(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) []const u8 {
        const call_ctx = ctx.getEnv(core.CallContext);
        const fb = if (call_ctx) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.theme else "dark";
    }

    /// `plugin:window|is_fullscreen`.
    pub fn is_fullscreen(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.fullscreen else false;
    }

    /// `plugin:window|is_minimized`.
    pub fn is_minimized(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.minimized else false;
    }

    /// `plugin:window|is_maximized`.
    pub fn is_maximized(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.maximized else false;
    }

    /// `plugin:window|is_focused`.
    pub fn is_focused(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.focused else true;
    }

    /// `plugin:window|is_decorated`.
    pub fn is_decorated(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.decorated else true;
    }

    /// `plugin:window|is_resizable`.
    pub fn is_resizable(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.resizable else true;
    }

    /// `plugin:window|is_maximizable`.
    pub fn is_maximizable(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.maximizable else true;
    }

    /// `plugin:window|is_minimizable`.
    pub fn is_minimizable(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.minimizable else true;
    }

    /// `plugin:window|is_closable`.
    pub fn is_closable(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.closable else true;
    }

    /// `plugin:window|is_visible`.
    pub fn is_visible(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.visible else true;
    }

    /// `plugin:window|is_enabled`.
    pub fn is_enabled(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.enabled else true;
    }

    /// `plugin:window|is_always_on_top`.
    pub fn is_always_on_top(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) bool {
        const fb = if (ctx.getEnv(core.CallContext)) |c| c.window_id else core.WindowId.invalid;
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        return if (reg.findLocked(args.label, fb)) |e| e.always_on_top else false;
    }

    /// `plugin:window|set_title` — replaces the title bar text.
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

    /// `plugin:window|set_size` — resizes to a `Logical` or `Physical` size.
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

    /// `plugin:window|set_min_size` — sets or clears (`null`) the lower resize bound.
    pub fn set_min_size(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: ?WireSize = null },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        const logical = if (args.value) |v| v.toLogical(t.scale) else null;
        try t.host.setWindowMinSize(t.win_id, logical);
    }

    /// `plugin:window|set_max_size` — sets or clears (`null`) the upper resize bound.
    pub fn set_max_size(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null, value: ?WireSize = null },
    ) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        const logical = if (args.value) |v| v.toLogical(t.scale) else null;
        try t.host.setWindowMaxSize(t.win_id, logical);
    }

    /// `plugin:window|set_size_constraints` — sets both bounds at once; absent fields are cleared.
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

    /// `plugin:window|set_position` — moves the window (logical or physical).
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

    /// `plugin:window|set_fullscreen` — enters or leaves fullscreen.
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

    /// `plugin:window|minimize` — minimises (iconifies) the window.
    pub fn minimize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMinimized(t.win_id, true);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.minimized = true;
    }

    /// `plugin:window|unminimize` — restores a minimised window.
    pub fn unminimize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMinimized(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.minimized = false;
    }

    /// `plugin:window|maximize` — maximises / zooms the window.
    pub fn maximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMaximized(t.win_id, true);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.maximized = true;
    }

    /// `plugin:window|unmaximize` — restores a maximised window.
    pub fn unmaximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMaximized(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.maximized = false;
    }

    /// `plugin:window|toggle_maximize` — flips the maximised state.
    pub fn toggle_maximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const is_max = is_maximized(ctx, reg, .{ .label = args.label });
        if (is_max) return unmaximize(ctx, reg, .{ .label = args.label }) else return maximize(ctx, reg, .{ .label = args.label });
    }

    /// `plugin:window|internal_toggle_maximize` — the double-click-on-titlebar path; same effect as `toggle_maximize`, kept separate so the JS shim can call it with a different argument shape.
    pub fn internal_toggle_maximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        return toggle_maximize(ctx, reg, .{ .label = args.label });
    }

    /// `plugin:window|show` — maps the window (and focuses it if it was hidden).
    pub fn show(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowVisible(t.win_id, true);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.visible = true;
    }

    /// `plugin:window|hide` — unmaps the window without destroying it.
    pub fn hide(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowVisible(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.visible = false;
    }

    /// `plugin:window|close` — asks the window to close (close handlers still run).
    pub fn close(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.closeWindow(t.win_id);
    }

    /// `plugin:window|destroy` — closes the window unconditionally, skipping close handlers.
    pub fn destroy(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        return close(ctx, reg, .{ .label = args.label });
    }

    /// `plugin:window|set_decorations` — adds or removes the native frame and title bar.
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

    /// `plugin:window|set_always_on_top` — keeps the window above (or below) others.
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

    /// `plugin:window|set_resizable` — toggles user resizing.
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

    /// `plugin:window|set_focus` — raises and focuses the window.
    pub fn set_focus(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowFocus(t.win_id);
    }

    /// `plugin:window|start_dragging` — begins an OS window move from the current cursor position.
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
