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
const monitor = @import("monitor.zig");
const event = @import("event.zig");

/// `plugin:window` failures: the host blew up (`core.HostError`) or the request itself was wrong.
/// `MissingHostContext` means the plugin was used without a `Host` (a unit test forgot `.withHost`),
/// `UnknownWindowLabel` means the JS asked for a window that was never created.
pub const WindowPluginError = core.HostError || error{
    MissingHostContext,
    UnknownWindowLabel,
    /// `new WebviewWindow()` / `new Window()` sent a bad `label` or duplicated an existing one.
    InvalidLabel,
    DuplicateLabel,
    /// `options` was not a JSON object, or a required field had the wrong type.
    MalformedOptions,
    /// `options.url` used a scheme ziggurats never loads (`javascript:`, `file:`, …).
    InvalidUrl,
    /// A monitor/DPI command was called before a `MonitorRegistry` was attached.
    MonitorsUnavailable,
    /// An enum setter received a value Tauri does not define.
    InvalidValue,
    /// A native window event name outside the P1 allowlist was requested.
    IllegalWindowEvent,
};

/// Maximum label length. Upstream allows `a-zA-Z0-9-/:_`; the cap keeps a hostile frontend from
/// allocating unbounded strings and matches the config importer's expectations.
pub const max_label_len = 128;

/// Tauri v2 label grammar: `a-zA-Z0-9-/:_`.
pub fn isValidLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > max_label_len) return false;
    for (label) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        switch (c) {
            '-', '/', ':', '_' => {},
            else => return false,
        }
    }
    return true;
}

/// JSON helpers shared by `plugin:window|create` and `plugin:webview|*`. `options` is a raw JSON
/// value so the dozens of upstream `WindowOptions` / `WebviewOptions` keys we do not act on are
/// simply ignored instead of failing the whole command.
pub const JsonHelpers = struct {
    /// Looks up the first present key in a JSON object.
    pub fn field(value: std.json.Value, names: []const []const u8) ?std.json.Value {
        if (value != .object) return null;
        for (names) |name| {
            if (value.object.get(name)) |v| {
                if (v == .null) return null;
                return v;
            }
        }
        return null;
    }

    /// Extracts a string field, or `null`.
    pub fn string(value: std.json.Value, names: []const []const u8) ?[]const u8 {
        const v = field(value, names) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// Extracts a numeric field, or `null`.
    pub fn number(value: std.json.Value, names: []const []const u8) ?f64 {
        const v = field(value, names) orelse return null;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string => |n| std.fmt.parseFloat(f64, n) catch null,
            else => null,
        };
    }

    /// Extracts a boolean field, or `null`.
    pub fn boolean(value: std.json.Value, names: []const []const u8) ?bool {
        const v = field(value, names) orelse return null;
        return if (v == .bool) v.bool else null;
    }
};

/// Normalises `options.url` into a URL the custom-protocol router can serve. Relative paths map to
/// `tauri://localhost/<path>`; only http(s), tauri, asset, isolation and ipc schemes pass through.
/// Returns `InvalidUrl` for `javascript:` / `file:` / `data:` and for a NUL byte.
pub fn normalizeUrl(allocator: Allocator, raw_url: ?[]const u8) WindowPluginError![]const u8 {
    const url = raw_url orelse return "tauri://localhost/";
    if (url.len == 0) return "tauri://localhost/";
    if (std.mem.indexOfScalar(u8, url, 0) != null) return error.InvalidUrl;
    const colon = std.mem.indexOfScalar(u8, url, ':');
    if (colon) |i| {
        const scheme = url[0..i];
        const allowed = [_][]const u8{ "http", "https", "tauri", "asset", "isolation", "ipc" };
        for (allowed) |ok| {
            if (std.ascii.eqlIgnoreCase(scheme, ok)) return url;
        }
        return error.InvalidUrl;
    }
    return std.fmt.allocPrint(allocator, "tauri://localhost/{s}", .{std.mem.trimStart(u8, url, "/")});
}

/// Builds a `core.WindowSpec` from the raw `{ label, ...WindowOptions }` object sent by
/// `new Window()` / `new WebviewWindow()`. Unknown keys are ignored (forward compatibility).
pub fn specFromOptions(allocator: Allocator, raw_json: []const u8) WindowPluginError!core.WindowSpec {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, raw_json, .{}) catch
        return error.MalformedOptions;
    if (parsed != .object) return error.MalformedOptions;
    const opts = parsed;
    const h = JsonHelpers;

    const label = h.string(opts, &.{"label"}) orelse return error.InvalidLabel;
    if (!isValidLabel(label)) return error.InvalidLabel;

    const width = h.number(opts, &.{ "width", "width_" }) orelse 800;
    const height = h.number(opts, &.{ "height", "height_" }) orelse 600;
    const x = h.number(opts, &.{"x"});
    const y = h.number(opts, &.{"y"});
    const min_w = h.number(opts, &.{ "minWidth", "min_width" });
    const min_h = h.number(opts, &.{ "minHeight", "min_height" });
    const max_w = h.number(opts, &.{ "maxWidth", "max_width" });
    const max_h = h.number(opts, &.{ "maxHeight", "max_height" });

    var spec: core.WindowSpec = .{
        .label = label,
        .title = h.string(opts, &.{"title"}) orelse label,
        .size = .wh(width, height),
        .min_size = if (min_w != null and min_h != null) .wh(min_w.?, min_h.?) else null,
        .max_size = if (max_w != null and max_h != null) .wh(max_w.?, max_h.?) else null,
        .position = if (x != null and y != null) .xy(x.?, y.?) else null,
        .resizable = h.boolean(opts, &.{"resizable"}) orelse true,
        .decorations = h.boolean(opts, &.{"decorations"}) orelse true,
        .transparent = h.boolean(opts, &.{"transparent"}) orelse false,
        .always_on_top = h.boolean(opts, &.{ "alwaysOnTop", "always_on_top" }) orelse false,
        .visible = h.boolean(opts, &.{"visible"}) orelse true,
        .fullscreen = h.boolean(opts, &.{"fullscreen"}) orelse false,
        .devtools = h.boolean(opts, &.{"devtools"}) orelse false,
        .initial_url = try normalizeUrl(allocator, h.string(opts, &.{"url"})),
    };
    // `theme` is accepted but only the `dark`/`light` values are meaningful on all 3 OSes.
    if (h.string(opts, &.{"theme"})) |theme| {
        if (std.mem.eql(u8, theme, "dark")) spec.theme = .dark;
        if (std.mem.eql(u8, theme, "light")) spec.theme = .light;
    }
    return spec;
}

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
/// P1 #8 — state recorded by the remaining `plugin:window|set_*` commands. Every field is a
/// scalar or an enum, so no per-command allocation can leak and the state is byte-identical on all
/// three OSes. Visual effects that need a real OS object are applied by the backend where
/// available; the command always records the intent and emits the matching event.
pub const Theme = enum { system, dark, light };
/// Taskbar progress-bar state accepted by `set_progress_bar`.
pub const ProgressStatus = enum { none, normal, indeterminate, paused, @"error" };
/// Cursor shapes accepted by `set_cursor_icon`.
pub const CursorIcon = enum { default, arrow, crosshair, hand, text, move, wait, help, progress, not_allowed, resize_ew, resize_ns, grab, grabbing };
/// User-attention levels accepted by `request_user_attention`.
pub const AttentionType = enum { none, critical, informational };
/// Named background effects accepted by `set_effects`.
pub const Effect = enum { none, blur, acrylic, mica, tabbed };

/// Pair of progress state and percentage used by `set_progress_bar`.
pub const ProgressUpdate = struct { status: ProgressStatus, progress: ?u8 };
/// RGBA background colour used by `set_background_color`.
pub const ColorValue = struct { r: u8, g: u8, b: u8, a: u8 };

/// State recorded by the remaining `plugin:window|set_*` commands.
pub const WindowExtras = struct {
    /// Requested title-bar theme.
    theme: Theme = .system,
    /// Hide the window from the taskbar / dock.
    skip_taskbar: bool = false,
    /// Progress-bar state.
    progress_status: ProgressStatus = .none,
    /// Progress percentage (0..100), or `null`.
    progress_value: ?u8 = null,
    /// Dock / taskbar badge count, or `null` to clear it.
    badge_count: ?u32 = null,
    /// Current cursor shape.
    cursor_icon: CursorIcon = .default,
    /// Cursor X position in physical pixels.
    cursor_x: i32 = 0,
    /// Cursor Y position in physical pixels.
    cursor_y: i32 = 0,
    /// Whether the cursor is grabbed (confined to the window).
    cursor_grab: bool = false,
    /// Whether the cursor is drawn.
    cursor_visible: bool = true,
    /// Let mouse events pass through the window.
    ignore_cursor_events: bool = false,
    /// Whether `plugin:window|center` was requested.
    centered: bool = false,
    /// Last requested user-attention type.
    user_attention: AttentionType = .none,
    /// Prevent screenshots / screen capture of this window.
    content_protected: bool = false,
    /// Show the window on every virtual desktop.
    visible_on_all_workspaces: bool = false,
    /// Whether the window draws a drop shadow.
    shadow: bool = true,
    /// Keep the window below every other window.
    always_on_bottom: bool = false,
    /// Whether the window accepts input.
    enabled: bool = true,
    /// Requested background effect.
    effect: Effect = .none,
    /// Whether a background colour was set.
    bg_set: bool = false,
    /// Background red channel.
    bg_r: u8 = 0,
    /// Background green channel.
    bg_g: u8 = 0,
    /// Background blue channel.
    bg_b: u8 = 0,
    /// Background alpha channel.
    bg_a: u8 = 255,
    /// Deterministic hash of the icon bytes supplied to `set_icon`.
    icon_hash: u64 = 0,
    /// Devtools open of this record.
    devtools_open: bool = false,
};

/// One live window in the registry, with its label and last known state.
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
    /// P1 #8 setters state.
    extras: WindowExtras = .{},

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
    /// Optional runtime hook. `DesktopRuntime` installs `openWindow` so a window created from JS
    /// receives the *same* per-label bootstrap injection as one created at startup. Without it the
    /// command falls back to `ctx.host.createWindow()` (which is what unit-test hosts provide).
    window_factory_ctx: ?*anyopaque = null,
    /// Optional runtime hook that injects a per-label bootstrap into new windows.
    window_factory: ?*const fn (?*anyopaque, core.WindowSpec) core.HostError!core.WindowId = null,
    /// P1 #9 — monitor/DPI provider. `null` keeps the old behaviour (scale factor 1.0).
    monitors: ?*monitor.MonitorRegistry = null,
    /// P1 #7 — event bus used to emit window lifecycle events to JS listeners.
    events: ?*event.EventBus = null,

    /// Installs a runtime window factory (see the field docs). Returns `self` for chaining.
    pub fn withWindowFactory(
        self: *WindowRegistry,
        ctx: ?*anyopaque,
        factory: *const fn (?*anyopaque, core.WindowSpec) core.HostError!core.WindowId,
    ) *WindowRegistry {
        self.window_factory_ctx = ctx;
        self.window_factory = factory;
        return self;
    }

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

    /// P1 #6 — devtools state for a window (upstream `isDevtoolsOpen`). The Host vtable has an
    /// `openDevtools` hook but no portable "close" hook, so the registry owns the boolean and all
    /// three OSes report the same value after `open_devtools` / `close_devtools`.
    pub fn setDevtoolsOpen(self: *WindowRegistry, label: ?[]const u8, fallback_id: core.WindowId, value: bool) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.findLocked(label, fallback_id)) |e| {
            e.extras.devtools_open = value;
            return true;
        }
        return false;
    }

    /// Whether devtools are recorded as open for this window.
    pub fn devtoolsOpen(self: *WindowRegistry, label: ?[]const u8, fallback_id: core.WindowId) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return if (self.findLocked(label, fallback_id)) |e| e.extras.devtools_open else false;
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

/// P1 #7 — emits a native→JS window event to the target window's listeners. `dispatchRaw` uses
/// `Host.evalJs`, so the same path works for the real WebView and `RecordingHost` in tests. A
/// missing event bus (standalone `WindowRegistry` usage) is a no-op, never an error.
fn emitWindowEvent(
    ctx: *rpc.Ctx,
    reg: *WindowRegistry,
    label: ?[]const u8,
    event_name: []const u8,
    payload_json: []const u8,
) void {
    const bus = reg.events orelse return;
    const call = ctx.getEnv(core.CallContext) orelse return;
    const target: event.EventTarget = if (label) |lbl|
        .{ .Window = .{ .label = lbl } }
    else
        .Any;
    bus.dispatchRaw(call.host, ctx.scratch, target, event_name, payload_json) catch {};
}

/// Names native backends / the app may push through `plugin:window|emit_window_event`. Keeping an
/// allowlist stops a webview from forging unrelated application events.
pub const window_event_names = [_][]const u8{
    "tauri://resize",
    "tauri://move",
    "tauri://focus",
    "tauri://blur",
    "tauri://scale-change",
    "tauri://theme-changed",
    "tauri://close-requested",
    "tauri://file-drop",
    "tauri://page-load",
    "tauri://navigation",
    "tauri://window-created",
    "tauri://window-destroyed",
    "tauri://window-flags-changed",
};

/// Whether a name is on the allowlist of native window events.
pub fn isWindowEventName(name: []const u8) bool {
    for (window_event_names) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}

/// P1 #8 — shared body of the scalar setters. Resolves the window, records the intent under the
/// registry mutex and emits the matching native→JS event. No allocation, no OS branch.
fn applyExtras(
    ctx: *rpc.Ctx,
    reg: *WindowRegistry,
    label: ?[]const u8,
    comptime apply: anytype,
    value: anytype,
    event_name: []const u8,
) WindowPluginError!void {
    const t = try resolveTarget(ctx, reg, label);
    reg.mu.lockUncancelable(reg.io);
    defer reg.mu.unlock(reg.io);
    if (reg.findLocked(label, t.win_id)) |entry| apply(&entry.extras, value);
    emitWindowEvent(ctx, reg, label, event_name, "null");
}

/// Opens a window through the runtime factory (production) or through `ctx.host` (unit tests),
/// then records it in the registry so `label` based commands can find it immediately.
pub fn openWindow(
    reg: *WindowRegistry,
    host_opt: ?core.Host,
    spec: core.WindowSpec,
) WindowPluginError!core.WindowId {
    const id: core.WindowId = if (reg.window_factory) |factory|
        try factory(reg.window_factory_ctx, spec)
    else if (host_opt) |host|
        try host.createWindow(spec)
    else
        return error.MissingHostContext;
    try reg.registerWindow(id, spec);
    return id;
}

/// `plugin:window|*` RPC command namespace (`Schema` key: `.window`).
pub const Commands = struct {
    /// Every command in this namespace starts with this prefix.
    pub const rpc_prefix = "plugin:window|";
    /// The state type `zts_rpc` resolves per app; identical to `WindowRegistry` here.
    pub const RpcState = WindowRegistry;

    /// `plugin:window|create` — `new Window(label, options)`.
    ///
    /// The wire payload is `{ "options": { "label": "...", ...WindowOptions } }`. Keeping
    /// `options` as `RawJson` means every upstream option we do not implement (`center`,
    /// `skipTaskbar`, `titleBarStyle`, …) is ignored instead of failing the call.
    pub fn create(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { options: rpc.RawJson },
    ) WindowPluginError!void {
        const spec = try specFromOptions(ctx.scratch, args.options.raw);
        if (reg.resolveId(spec.label, core.WindowId.invalid) != null) return error.DuplicateLabel;
        const call_ctx = ctx.getEnv(core.CallContext);
        const host: ?core.Host = if (call_ctx) |c| c.host else null;
        _ = try openWindow(reg, host, spec);
    }

    // ---- P1 #9: Monitor / DPI --------------------------------------------------------------

    fn monitorsOf(reg: *WindowRegistry) WindowPluginError!*monitor.MonitorRegistry {
        return reg.monitors orelse error.MonitorsUnavailable;
    }

    /// `plugin:window|available_monitors` — all displays in physical pixels.
    pub fn available_monitors(ctx: *rpc.Ctx, reg: *WindowRegistry) Allocator.Error![]const monitor.Monitor {
        return (monitorsOf(reg) catch return error.OutOfMemory).all(ctx.scratch);
    }

    /// `plugin:window|primary_monitor` — the first display.
    pub fn primary_monitor(_: *rpc.Ctx, reg: *WindowRegistry) WindowPluginError!monitor.Monitor {
        return (try monitorsOf(reg)).primary();
    }

    /// `plugin:window|current_monitor` — the display containing the window's centre.
    pub fn current_monitor(
        _: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { label: ?[]const u8 = null },
    ) WindowPluginError!?monitor.Monitor {
        const m = try monitorsOf(reg);
        const fb = core.WindowId.invalid;
        const found = reg.findLocked(args.label, fb) orelse return m.primary();
        const cx: i32 = @intFromFloat(@round(found.position.x.v + found.size.width.v / 2));
        const cy: i32 = @intFromFloat(@round(found.position.y.v + found.size.height.v / 2));
        return m.fromPoint(cx, cy) orelse m.primary();
    }

    /// `plugin:window|monitor_from_point` — the display containing a physical pixel.
    pub fn monitor_from_point(
        _: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { x: i32, y: i32 },
    ) WindowPluginError!?monitor.Monitor {
        return (try monitorsOf(reg)).fromPoint(args.x, args.y);
    }

    /// `plugin:window|cursor_position` — the cursor in physical pixels.
    pub fn cursor_position(_: *rpc.Ctx, reg: *WindowRegistry) WindowPluginError!monitor.Point {
        return (try monitorsOf(reg)).cursor();
    }

    // ---- P1 #7 / #8: native events and the remaining setters ----------------------------------

    /// `plugin:window|emit_window_event` — pushes a native window event to JS listeners.
    /// Only the allowlisted `tauri://…` names are accepted (see `isWindowEventName`), so a
    /// webview cannot forge arbitrary application events.
    pub fn emit_window_event(
        ctx: *rpc.Ctx,
        reg: *WindowRegistry,
        args: struct { event: []const u8, label: ?[]const u8 = null, payload: rpc.RawJson = .{} },
    ) WindowPluginError!void {
        if (!isWindowEventName(args.event)) return error.IllegalWindowEvent;
        emitWindowEvent(ctx, reg, args.label, args.event, args.payload.raw);
    }

    /// `plugin:window|set_theme` — `system` / `dark` / `light`.
    pub fn set_theme(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: []const u8 }) WindowPluginError!void {
        const parsed = std.meta.stringToEnum(Theme, args.value) orelse return error.InvalidValue;
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: Theme) void {
                e.theme = v;
            }
        }.f, parsed, "tauri://theme-changed");
    }

    /// `plugin:window|set_skip_taskbar`.
    pub fn set_skip_taskbar(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.skip_taskbar = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_progress_bar` — `status` + optional 0..100 percentage.
    pub fn set_progress_bar(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct {
        label: ?[]const u8 = null,
        status: []const u8,
        progress: ?u8 = null,
    }) WindowPluginError!void {
        const parsed = std.meta.stringToEnum(ProgressStatus, args.status) orelse return error.InvalidValue;
        if (args.progress) |p| if (p > 100) return error.InvalidValue;
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: ProgressUpdate) void {
                e.progress_status = v.status;
                e.progress_value = v.progress;
            }
        }.f, ProgressUpdate{ .status = parsed, .progress = args.progress }, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_badge_count` — `null` clears the badge.
    pub fn set_badge_count(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: ?u32 = null }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: ?u32) void {
                e.badge_count = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_cursor_icon`.
    pub fn set_cursor_icon(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: []const u8 }) WindowPluginError!void {
        const parsed = std.meta.stringToEnum(CursorIcon, args.value) orelse return error.InvalidValue;
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: CursorIcon) void {
                e.cursor_icon = v;
            }
        }.f, parsed, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_cursor_position` — physical pixels.
    pub fn set_cursor_position(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, x: i32, y: i32 }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: monitor.Point) void {
                e.cursor_x = v.x;
                e.cursor_y = v.y;
            }
        }.f, monitor.Point{ .x = args.x, .y = args.y }, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_cursor_grab`.
    pub fn set_cursor_grab(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.cursor_grab = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_cursor_visible`.
    pub fn set_cursor_visible(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.cursor_visible = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_ignore_cursor_events`.
    pub fn set_ignore_cursor_events(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.ignore_cursor_events = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// `plugin:window|center` — records the request; the backend centres the window when it can.
    pub fn center(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, _: void) void {
                e.centered = true;
            }
        }.f, {}, "tauri://move");
    }

    /// `plugin:window|request_user_attention` — `none` / `critical` / `informational`.
    pub fn request_user_attention(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: []const u8 }) WindowPluginError!void {
        const parsed = std.meta.stringToEnum(AttentionType, args.value) orelse return error.InvalidValue;
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: AttentionType) void {
                e.user_attention = v;
            }
        }.f, parsed, "tauri://focus");
    }

    /// `plugin:window|set_content_protected`.
    pub fn set_content_protected(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.content_protected = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_visible_on_all_workspaces`.
    pub fn set_visible_on_all_workspaces(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.visible_on_all_workspaces = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_shadow`.
    pub fn set_shadow(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.shadow = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_effects` — one named effect; unknown names are refused.
    pub fn set_effects(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: []const u8 }) WindowPluginError!void {
        const parsed = std.meta.stringToEnum(Effect, args.value) orelse return error.InvalidValue;
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: Effect) void {
                e.effect = v;
            }
        }.f, parsed, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_background_color` — RGBA, all four channels 0..255.
    pub fn set_background_color(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct {
        label: ?[]const u8 = null,
        r: u8,
        g: u8,
        b: u8,
        a: u8 = 255,
    }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: ColorValue) void {
                e.bg_set = true;
                e.bg_r = v.r;
                e.bg_g = v.g;
                e.bg_b = v.b;
                e.bg_a = v.a;
            }
        }.f, ColorValue{ .r = args.r, .g = args.g, .b = args.b, .a = args.a }, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_icon` — records a deterministic hash of the icon bytes/path.
    pub fn set_icon(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: []const u8 }) WindowPluginError!void {
        const hash = std.hash.Wyhash.hash(0, args.value);
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: u64) void {
                e.icon_hash = v;
            }
        }.f, hash, "tauri://window-flags-changed");
    }

    /// `plugin:window|set_always_on_bottom` / `set_enabled` — the last two scalar setters.
    pub fn set_always_on_bottom(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.always_on_bottom = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

    /// Enables or disables window input and emits a flags-changed event.
    pub fn set_enabled(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null, value: bool }) WindowPluginError!void {
        try applyExtras(ctx, reg, args.label, struct {
            fn f(e: *WindowExtras, v: bool) void {
                e.enabled = v;
            }
        }.f, args.value, "tauri://window-flags-changed");
    }

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
        emitWindowEvent(ctx, reg, args.label, "tauri://window-flags-changed", "null");
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
        emitWindowEvent(ctx, reg, args.label, "tauri://resize", "null");
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
        emitWindowEvent(ctx, reg, args.label, "tauri://move", "null");
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
        emitWindowEvent(ctx, reg, args.label, "tauri://resize", "null");
    }

    /// `plugin:window|minimize` — minimises (iconifies) the window.
    pub fn minimize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMinimized(t.win_id, true);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.minimized = true;
        emitWindowEvent(ctx, reg, args.label, "tauri://resize", "null");
    }

    /// `plugin:window|unminimize` — restores a minimised window.
    pub fn unminimize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMinimized(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.minimized = false;
        emitWindowEvent(ctx, reg, args.label, "tauri://resize", "null");
    }

    /// `plugin:window|maximize` — maximises / zooms the window.
    pub fn maximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMaximized(t.win_id, true);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.maximized = true;
        emitWindowEvent(ctx, reg, args.label, "tauri://resize", "null");
    }

    /// `plugin:window|unmaximize` — restores a maximised window.
    pub fn unmaximize(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowMaximized(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.maximized = false;
        emitWindowEvent(ctx, reg, args.label, "tauri://resize", "null");
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
        emitWindowEvent(ctx, reg, args.label, "tauri://window-flags-changed", "null");
    }

    /// `plugin:window|hide` — unmaps the window without destroying it.
    pub fn hide(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowVisible(t.win_id, false);
        reg.mu.lockUncancelable(reg.io);
        defer reg.mu.unlock(reg.io);
        if (reg.findLocked(args.label, t.win_id)) |e| e.visible = false;
        emitWindowEvent(ctx, reg, args.label, "tauri://window-flags-changed", "null");
    }

    /// `plugin:window|close` — asks the window to close (close handlers still run).
    pub fn close(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.closeWindow(t.win_id);
        emitWindowEvent(ctx, reg, args.label, "tauri://close-requested", "null");
    }

    /// `plugin:window|destroy` — closes the window unconditionally, skipping close handlers.
    pub fn destroy(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        emitWindowEvent(ctx, reg, args.label, "tauri://window-destroyed", "null");
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
        emitWindowEvent(ctx, reg, args.label, "tauri://window-flags-changed", "null");
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
        emitWindowEvent(ctx, reg, args.label, "tauri://window-flags-changed", "null");
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
        emitWindowEvent(ctx, reg, args.label, "tauri://window-flags-changed", "null");
    }

    /// `plugin:window|set_focus` — raises and focuses the window.
    pub fn set_focus(ctx: *rpc.Ctx, reg: *WindowRegistry, args: struct { label: ?[]const u8 = null }) WindowPluginError!void {
        const t = try resolveTarget(ctx, reg, args.label);
        try t.host.setWindowFocus(t.win_id);
        emitWindowEvent(ctx, reg, args.label, "tauri://focus", "null");
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
        emitWindowEvent(ctx, reg, args.label, "tauri://move", "null");
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
