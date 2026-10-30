//! `@tauri-apps/api/tray` v2 wire-compatible System Tray plugin (`plugin:tray|*`).
//!
//! Same split as `plugin:menu` (see `src/tauri/menu/mod.zig`): the wire layer is Pure Zig and the
//! only thing a native backend receives is a plain options struct plus the flattened menu snapshot.
//!
//! ```text
//! TrayIcon.new({ icon, tooltip, menu, action })      invoke('plugin:tray|new', { options, handler })
//!         │                                                   │
//!         ▼                                                   ▼
//!   TrayState.create(...) ──► Backend.create(TrayOptions, ?Snapshot)
//!         ▲                                                   │ (GTK status icon / NSStatusItem /
//!         │  trayState.emit(scratch, id, event)                │  Shell_NotifyIconW)
//!    Channel<TrayIconEvent> ◄─────────────────────────────────┘
//! ```
//!
//! Event payloads match `@tauri-apps/api/tray`'s `mapEvent`: `position` / `rect.position` are plain
//! `{x, y}` objects and `rect.size` is `{width, height}` (the JS side wraps them in
//! `PhysicalPosition` / `PhysicalSize`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");

const Channel = @import("../channel.zig").Channel;
const ResourceTable = @import("../resources.zig").ResourceTable;
const menu = @import("../menu/mod.zig");

pub const TrayError = error{
    Unavailable,
    Failed,
    BadResourceId,
    /// `get_by_id` / `remove_by_id` found no tray with that id.
    NotFound,
    OutOfMemory,
};

// ============================================================================
// Wire types
// ============================================================================

/// `@tauri-apps/api/tray` `TrayIconOptions` (`camelCase` on the wire). Only `menu` and `icon` have
/// native equivalents on all three platforms; the rest degrade gracefully (a tooltip on a menu-bar
/// icon is a no-op on macOS, for instance).
pub const TrayIconOptions = struct {
    /// Tray id; generated (`"1"`, `"2"`, …) when omitted.
    id: ?[]const u8 = null,
    /// `(rid, ItemKind)` of an existing `Menu` / `Submenu` resource.
    menu: ?struct { u53, menu.ItemKind } = null,
    /// Status icon (path, bytes or a loaded image).
    icon: ?menu.Icon = null,
    /// Hover text. Rendered on Windows/Linux; ignored by the macOS menu bar.
    tooltip: ?[]const u8 = null,
    /// Text next to the icon. macOS shows it in the menu bar; Windows ignores it.
    title: ?[]const u8 = null,
    /// Where to unpack image data that has to exist as a file (Windows).
    temp_dir_path: ?[]const u8 = null,
    /// Treat the icon as a template image, so macOS tints it for light/dark.
    icon_as_template: ?bool = null,
    /// Open the tray menu on left click.
    menu_on_left_click: ?bool = null,
    /// Deprecated upstream alias of `menu_on_left_click`; kept for wire compatibility.
    show_menu_on_left_click: ?bool = null,

    /// Decodes the options object `plugin:tray|new` receives.
    pub fn decodeZtsJson(allocator: Allocator, raw: []const u8) rpc.DecodeError!TrayIconOptions {
        const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.UnexpectedToken,
        };
        const obj = switch (value) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };

        var out: TrayIconOptions = .{};
        var it = obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "id")) {
                out.id = stringOf(v) orelse return error.UnexpectedToken;
            } else if (std.mem.eql(u8, key, "menu")) {
                if (v == .null) continue;
                const tuple = switch (v) {
                    .array => |a| a,
                    else => return error.UnexpectedToken,
                };
                if (tuple.items.len != 2) return error.UnexpectedToken;
                const rid = u53Of(tuple.items[0]) orelse return error.UnexpectedToken;
                const kind = itemKindOf(tuple.items[1]) orelse return error.UnknownField;
                out.menu = .{ rid, kind };
            } else if (std.mem.eql(u8, key, "icon")) {
                out.icon = if (v == .null) null else (menu.Icon.fromValue(v) orelse return error.UnexpectedToken);
            } else if (std.mem.eql(u8, key, "tooltip")) {
                out.tooltip = if (v == .null) null else (stringOf(v) orelse return error.UnexpectedToken);
            } else if (std.mem.eql(u8, key, "title")) {
                out.title = if (v == .null) null else (stringOf(v) orelse return error.UnexpectedToken);
            } else if (std.mem.eql(u8, key, "tempDirPath")) {
                out.temp_dir_path = if (v == .null) null else (stringOf(v) orelse return error.UnexpectedToken);
            } else if (std.mem.eql(u8, key, "iconAsTemplate")) {
                out.icon_as_template = boolOf(v) orelse return error.UnexpectedToken;
            } else if (std.mem.eql(u8, key, "menuOnLeftClick")) {
                out.menu_on_left_click = boolOf(v) orelse return error.UnexpectedToken;
            } else if (std.mem.eql(u8, key, "showMenuOnLeftClick")) {
                out.show_menu_on_left_click = boolOf(v) orelse return error.UnexpectedToken;
            }
        }
        return out;
    }
};

/// `tauri::tray::TrayIconEvent` as `@tauri-apps/api/tray` reads it.
pub const TrayEvent = struct {
    /// `"Click"` / `"DoubleClick"` / `"Enter"` / `"Move"` / `"Leave"`.
    type: []const u8 = "Click",
    /// Tray the event belongs to.
    id: []const u8,
    /// Cursor position in physical pixels, relative to the screen.
    position: Point = .{},
    /// Bounding box of the tray icon, in physical pixels.
    rect: Rect = .{},
    /// `"Left"` / `"Right"` / `"Middle"` (`Click` & `DoubleClick` only).
    button: ?[]const u8 = null,
    /// `"Up"` / `"Down"` (`Click` only).
    button_state: ?[]const u8 = null,

    /// Cursor position, in physical pixels relative to the screen origin.
    pub const Point = struct {
        /// X in physical pixels.
        x: f64 = 0,
        /// Y in physical pixels.
        y: f64 = 0,
    };
    /// Size of the icon, in physical pixels.
    pub const Size = struct {
        /// Width in physical pixels.
        width: f64 = 0,
        /// Height in physical pixels.
        height: f64 = 0,
    };
    /// Bounding box of the tray icon on screen.
    pub const Rect = struct {
        /// Top-left corner of the icon.
        position: Point = .{},
        /// Size of the icon.
        size: Size = .{},
    };

    /// Convenience constructor for a `Click` event (used by the mock and by tests).
    pub fn click(id: []const u8, x: f64, y: f64, button: []const u8, state: []const u8) TrayEvent {
        return .{ .type = "Click", .id = id, .position = .{ .x = x, .y = y }, .button = button, .button_state = state };
    }
};

// ============================================================================
// Backend vtable
// ============================================================================

/// Receiver for tray interactions (click / double-click / hover). The native backend reports the
/// raw `TrayEvent`; the core forwards it into the tray's `Channel<TrayEvent>`.
pub const Emitter = struct {
    /// Opaque pointer passed back to `emit`.
    ctx: ?*anyopaque = null,
    /// Delivers a `TrayEvent` to the JS `Channel<TrayEvent>`.
    emit: *const fn (ctx: ?*anyopaque, event: TrayEvent) void = noop,

    fn noop(_: ?*anyopaque, _: TrayEvent) void {}
};

/// A native tray backend (AppKit `NSStatusItem`, Win32 `Shell_NotifyIcon`, GTK `StatusIcon`) plus the
/// function table `TrayState` drives. `Mock` records calls so all three OSes run the same assertions.
pub const Backend = struct {
    /// Opaque pointer handed back to every vtable entry.
    ctx: ?*anyopaque = null,
    /// The native implementation; `StubBackend.vtable` reports `error.Unavailable`.
    vtable: *const VTable,

    /// The operations a native tray backend must provide.
    pub const VTable = struct {
        /// Creates (or replaces) the tray `id`. `menu` is the flattened menu to attach, if any.
        create: *const fn (ctx: ?*anyopaque, id: []const u8, options: TrayIconOptions, menu_snapshot: ?menu.Snapshot) TrayError!void,
        /// Applies `options` to an existing tray (`null` members mean "unchanged" where the toolkit
        /// supports it; the core always passes the full current state).
        update: *const fn (ctx: ?*anyopaque, id: []const u8, options: TrayIconOptions, menu_snapshot: ?menu.Snapshot) TrayError!void,
        remove: *const fn (ctx: ?*anyopaque, id: []const u8) TrayError!void,
        /// Shows / hides the icon without touching the rest of the tray state.
        set_visible: *const fn (ctx: ?*anyopaque, id: []const u8, visible: bool) TrayError!void,
        /// Registers the interaction receiver (called by `TrayState` before every apply).
        set_emitter: *const fn (ctx: ?*anyopaque, emitter: Emitter) void,
    };

    /// Creates (or replaces) the tray `id`, attaching `snapshot` when given.
    pub fn create(self: Backend, id: []const u8, options: TrayIconOptions, snapshot: ?menu.Snapshot) TrayError!void {
        return self.vtable.create(self.ctx, id, options, snapshot);
    }
    /// Applies the full current options to an existing tray.
    pub fn update(self: Backend, id: []const u8, options: TrayIconOptions, snapshot: ?menu.Snapshot) TrayError!void {
        return self.vtable.update(self.ctx, id, options, snapshot);
    }
    /// Removes the tray and its icon.
    pub fn remove(self: Backend, id: []const u8) TrayError!void {
        return self.vtable.remove(self.ctx, id);
    }
    /// Shows or hides the icon without touching the rest of the state.
    pub fn setVisible(self: Backend, id: []const u8, visible: bool) TrayError!void {
        return self.vtable.set_visible(self.ctx, id, visible);
    }
    /// Registers the interaction receiver; `TrayState` calls this before every apply.
    pub fn setEmitter(self: Backend, emitter: Emitter) void {
        self.vtable.set_emitter(self.ctx, emitter);
    }
};

/// Fallback backend, identical in spirit to `menu.StubBackend`.
pub const StubBackend = struct {
    /// The fallback table: every operation reports `error.Unavailable`.
    pub const vtable = Backend.VTable{
        .create = unavailable,
        .update = unavailable,
        .remove = unavailableRemove,
        .set_visible = unavailableVisible,
        .set_emitter = ignoreEmitter,
    };
    fn ignoreEmitter(_: ?*anyopaque, _: Emitter) void {}
    fn unavailable(_: ?*anyopaque, _: []const u8, _: TrayIconOptions, _: ?menu.Snapshot) TrayError!void {
        return error.Unavailable;
    }
    fn unavailableRemove(_: ?*anyopaque, _: []const u8) TrayError!void {
        return error.Unavailable;
    }
    fn unavailableVisible(_: ?*anyopaque, _: []const u8, _: bool) TrayError!void {
        return error.Unavailable;
    }
};

// ============================================================================
// State
// ============================================================================

/// `plugin:tray` state: the live trays, the shared menu tree they attach to, and the resource table
/// that gives the JS side its handles.
pub const TrayState = struct {
    /// Allocator that owns the recorded options.
    allocator: Allocator,
    /// IO reactor used for the state mutex.
    io: Io,
    /// Shared `plugin:resources` table: the JS side addresses a tray by handle.
    resources: *ResourceTable,
    /// Menu tree the trays attach to.
    menu_state: *menu.MenuState,
    /// Native backend that actually draws the icons.
    backend: Backend,
    /// Counter behind the generated ids.
    next_id: u32 = 1,
    /// Wire tray id → current options (owned strings).
    trays: std.StringHashMapUnmanaged(TrayRecord) = .empty,
    /// Tray id → event channel.
    channels: std.StringHashMapUnmanaged(EventChannel) = .empty,

    /// Everything the state remembers about one tray.
    pub const TrayRecord = struct {
        /// Owned copy of the last options applied.
        options: OwnedOptions,
        /// `plugin:resources` handle handed to JS (`get_by_id` must return the *same* one).
        rid: u53 = 0,
        visible: bool = true,
    };

    /// Where a tray's interactions are delivered.
    pub const EventChannel = struct {
        /// Channel the JS `handler` listens on; the payload is a `TrayEvent`.
        channel: Channel(TrayEvent),
        /// Caller context captured at creation, so the event carries its window.
        call_ctx: ?core.CallContext = null,
    };

    /// `TrayIconOptions` with every string copied into `TrayState.allocator`.
    pub const OwnedOptions = struct {
        id: []const u8 = "",
        has_menu: bool = false,
        menu_rid: u53 = 0,
        menu_kind: menu.ItemKind = .Menu,
        icon: ?menu.Icon = null,
        tooltip: ?[]const u8 = null,
        title: ?[]const u8 = null,
        temp_dir_path: ?[]const u8 = null,
        icon_as_template: ?bool = null,
        menu_on_left_click: ?bool = null,
        show_menu_on_left_click: ?bool = null,
        owned: std.ArrayListUnmanaged([]u8) = .empty,

        pub fn deinit(self: *OwnedOptions, allocator: Allocator) void {
            for (self.owned.items) |s| allocator.free(s);
            self.owned.deinit(allocator);
        }

        fn adopt(self: *OwnedOptions, allocator: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
            const copy = try allocator.dupe(u8, bytes);
            errdefer allocator.free(copy);
            try self.owned.append(allocator, copy);
            return copy;
        }

        pub fn from(allocator: Allocator, options: TrayIconOptions) Allocator.Error!OwnedOptions {
            var out: OwnedOptions = .{};
            errdefer out.deinit(allocator);
            if (options.id) |id| out.id = try out.adopt(allocator, id);
            if (options.menu) |m| {
                out.has_menu = true;
                out.menu_rid = m[0];
                out.menu_kind = m[1];
            }
            out.icon = options.icon;
            if (options.tooltip) |v| out.tooltip = try out.adopt(allocator, v);
            if (options.title) |v| out.title = try out.adopt(allocator, v);
            if (options.temp_dir_path) |v| out.temp_dir_path = try out.adopt(allocator, v);
            out.icon_as_template = options.icon_as_template;
            out.menu_on_left_click = options.menu_on_left_click;
            out.show_menu_on_left_click = options.show_menu_on_left_click;
            return out;
        }

        /// Re-renders the owned record back into the borrowed wire struct for the backend.
        pub fn toOptions(self: OwnedOptions) TrayIconOptions {
            return .{
                .id = self.id,
                .menu = if (self.has_menu) .{ self.menu_rid, self.menu_kind } else null,
                .icon = self.icon,
                .tooltip = self.tooltip,
                .title = self.title,
                .temp_dir_path = self.temp_dir_path,
                .icon_as_template = self.icon_as_template,
                .menu_on_left_click = self.menu_on_left_click,
                .show_menu_on_left_click = self.show_menu_on_left_click,
            };
        }
    };

    /// Creates empty state that draws through `StubBackend`.
    pub fn init(allocator: Allocator, io: Io, resources: *ResourceTable, menu_state: *menu.MenuState) TrayState {
        return .{
            .allocator = allocator,
            .io = io,
            .resources = resources,
            .menu_state = menu_state,
            .backend = .{ .vtable = &StubBackend.vtable },
        };
    }

    /// Returns a copy of `self` that draws through `backend`.
    pub fn withBackend(self: TrayState, backend: Backend) TrayState {
        var copy = self;
        copy.backend = backend;
        return copy;
    }

    /// Removes every tray from the backend and frees the recorded options.
    pub fn deinit(self: *TrayState) void {
        var it = self.trays.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.options.deinit(self.allocator);
        }
        self.trays.deinit(self.allocator);
        var ch = self.channels.iterator();
        while (ch.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.channels.deinit(self.allocator);
    }

    /// Snapshot of the tray's menu, or `null` when the tray has none.
    fn menuSnapshot(self: *TrayState, scratch: Allocator, record: *TrayRecord) TrayError!?menu.Snapshot {
        if (!record.options.has_menu) return null;
        const node = self.menu_state.lookup(record.options.menu_rid, record.options.menu_kind) orelse return null;
        const entries = menu.flatten(scratch, node) catch return error.OutOfMemory;
        return .{ .entries = entries };
    }

    /// Called by native backends (and the `Mock`) when the user interacts with a tray icon.
    pub fn emit(self: *TrayState, scratch: Allocator, event: TrayEvent) void {
        const entry = self.channels.getPtr(event.id) orelse return;
        const call_ctx = entry.call_ctx orelse return;
        entry.channel.send(call_ctx.host, call_ctx.window_id, scratch, event) catch {};
    }

    /// Points the backend's interaction receiver at this state (before every apply).
    fn syncEmitter(self: *TrayState) void {
        self.backend.setEmitter(.{ .ctx = self, .emit = emitterThunk });
    }

    fn emitterThunk(ctx: ?*anyopaque, event: TrayEvent) void {
        const self: *TrayState = @ptrCast(@alignCast(ctx orelse return));
        self.emit(self.allocator, event);
    }

    /// Re-pushes every tray menu after a `plugin:menu` mutation.
    pub fn refreshMenus(self: *TrayState, scratch: Allocator) TrayError!void {
        self.syncEmitter();
        var it = self.trays.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.options.has_menu) continue;
            const snapshot = try self.menuSnapshot(scratch, entry.value_ptr);
            try self.backend.update(entry.key_ptr.*, entry.value_ptr.options.toOptions(), snapshot);
        }
    }
};

// ============================================================================
// Mock backend
// ============================================================================

/// Recording backend used by tests: every `create` / `update` / `remove` / `set_visible` call is
/// appended, so a test can assert the sequence instead of a rendered picture.
pub const Mock = struct {
    /// Which backend entry was called.
    pub const CallKind = enum { create, update, remove, set_visible };

    /// One recorded backend call, with owned copies of everything the backend saw.
    pub const Call = struct {
        /// The entry point that was called.
        kind: CallKind,
        /// Tray id the call targeted.
        id: []const u8,
        /// `null` when the tray has no menu; otherwise the flattened menu ids.
        menu_ids: []const []const u8,
        tooltip: ?[]const u8 = null,
        title: ?[]const u8 = null,
        visible: ?bool = null,
    };

    /// Allocator that owns the recorded ids, tooltips and titles.
    allocator: Allocator,
    /// Every backend call, in order.
    calls: std.ArrayListUnmanaged(Call) = .empty,
    /// The receiver the state installed, so `interact()` can replay a click.
    emitter: ?Emitter = null,

    /// Creates a backend that records what it is asked to do.
    pub fn init(allocator: Allocator) Mock {
        return .{ .allocator = allocator };
    }

    /// Frees every recorded call.
    pub fn deinit(self: *Mock) void {
        for (self.calls.items) |call| {
            self.allocator.free(call.id);
            if (call.tooltip) |t| self.allocator.free(t);
            if (call.title) |t| self.allocator.free(t);
            for (call.menu_ids) |id| self.allocator.free(id);
            self.allocator.free(call.menu_ids);
        }
        self.calls.deinit(self.allocator);
    }

    /// The `Backend` view of `self`, ready for `TrayState.withBackend`.
    pub fn backend(self: *Mock) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// The most recent call, or `null` when nothing has been applied yet.
    pub fn lastCall(self: *Mock) ?Call {
        if (self.calls.items.len == 0) return null;
        return self.calls.items[self.calls.items.len - 1];
    }

    const vtable = Backend.VTable{
        .create = create,
        .update = update,
        .remove = remove,
        .set_visible = setVisible,
        .set_emitter = setEmitter,
    };

    fn setEmitter(ctx: ?*anyopaque, emitter: Emitter) void {
        const self: *Mock = @ptrCast(@alignCast(ctx.?));
        self.emitter = emitter;
    }

    /// Simulates a user interaction with tray `id` (native backends do the same).
    pub fn interact(self: *Mock, event: TrayEvent) void {
        if (self.emitter) |emitter| emitter.emit(emitter.ctx, event);
    }

    fn create(ctx: ?*anyopaque, id: []const u8, options: TrayIconOptions, snapshot: ?menu.Snapshot) TrayError!void {
        return record(ctx, .create, id, options, snapshot);
    }

    fn update(ctx: ?*anyopaque, id: []const u8, options: TrayIconOptions, snapshot: ?menu.Snapshot) TrayError!void {
        return record(ctx, .update, id, options, snapshot);
    }

    fn remove(ctx: ?*anyopaque, id: []const u8) TrayError!void {
        const self: *Mock = @ptrCast(@alignCast(ctx.?));
        try self.calls.append(self.allocator, .{
            .kind = .remove,
            .id = try self.allocator.dupe(u8, id),
            .menu_ids = try self.allocator.alloc([]const u8, 0),
        });
    }

    fn setVisible(ctx: ?*anyopaque, id: []const u8, visible: bool) TrayError!void {
        const self: *Mock = @ptrCast(@alignCast(ctx.?));
        try self.calls.append(self.allocator, .{
            .kind = .set_visible,
            .id = try self.allocator.dupe(u8, id),
            .menu_ids = try self.allocator.alloc([]const u8, 0),
            .visible = visible,
        });
    }

    fn record(
        ctx: ?*anyopaque,
        kind: CallKind,
        id: []const u8,
        options: TrayIconOptions,
        snapshot: ?menu.Snapshot,
    ) TrayError!void {
        const self: *Mock = @ptrCast(@alignCast(ctx.?));
        const ids = try self.allocator.alloc([]const u8, if (snapshot) |s| s.entries.len else 0);
        errdefer self.allocator.free(ids);
        for (ids, 0..) |*slot, i| slot.* = try self.allocator.dupe(u8, snapshot.?.entries[i].id);
        try self.calls.append(self.allocator, .{
            .kind = kind,
            .id = try self.allocator.dupe(u8, id),
            .menu_ids = ids,
            .tooltip = if (options.tooltip) |t| try self.allocator.dupe(u8, t) else null,
            .title = if (options.title) |t| try self.allocator.dupe(u8, t) else null,
        });
    }
};

// ============================================================================
// RPC commands
// ============================================================================

/// The `plugin:tray|*` RPC namespace (`create`, `update`, `remove`, …). Mounted by
/// `withCorePlugins()`; every command resolves its tray through `TrayState`.
pub const Commands = struct {
    /// Every command in this namespace starts with this prefix.
    pub const rpc_prefix = "plugin:tray|";
    /// The state type `zts_rpc` resolves per app; identical to `TrayState` here.
    pub const RpcState = TrayState;

    const Created = struct { u53, []const u8 };

    fn callCtx(ctx: *rpc.Ctx) ?core.CallContext {
        const ptr = ctx.getEnv(core.CallContext) orelse return null;
        return ptr.*;
    }

    /// `TrayIcon.new({ options, handler })` — returns `[rid, id]`.
    pub fn new(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        options: TrayIconOptions = .{},
        handler: ?Channel(TrayEvent) = null,
    }) TrayError!Created {
        var options = args.options;
        if (options.id == null) {
            options.id = std.fmt.allocPrint(ctx.scratch, "{d}", .{state.next_id}) catch return error.OutOfMemory;
            state.next_id += 1;
        }
        const id = options.id.?;

        var owned = TrayState.OwnedOptions.from(state.allocator, options) catch return error.OutOfMemory;
        errdefer owned.deinit(state.allocator);

        const key = state.allocator.dupe(u8, id) catch return error.OutOfMemory;
        errdefer state.allocator.free(key);
        if (try state.trays.fetchPut(state.allocator, key, .{ .options = owned })) |old| {
            state.allocator.free(old.key);
            var previous = old.value.options;
            previous.deinit(state.allocator);
        }

        const record = state.trays.getPtr(id).?;
        const snapshot = try state.menuSnapshot(ctx.scratch, record);
        state.syncEmitter();
        try state.backend.create(id, record.options.toOptions(), snapshot);

        if (args.handler) |handler| {
            const ch_key = state.allocator.dupe(u8, id) catch return error.OutOfMemory;
            errdefer state.allocator.free(ch_key);
            try state.channels.put(state.allocator, ch_key, .{
                .channel = handler,
                .call_ctx = callCtx(ctx),
            });
        }

        const handle_id = state.allocator.dupe(u8, id) catch return error.OutOfMemory;
        const rid = state.resources.insertOwned(TrayHandle, .{ .allocator = state.allocator, .id = handle_id }) catch {
            state.allocator.free(handle_id);
            return error.OutOfMemory;
        };
        if (state.trays.getPtr(id)) |entry_record| {
            if (entry_record.rid != 0) state.resources.closeRid(entry_record.rid) catch {};
            entry_record.rid = rid;
        }
        return .{ rid, id };
    }

    /// `get_by_id` — the handle for a tray id, or `null` when it is gone.
    pub fn get_by_id(ctx: *rpc.Ctx, state: *TrayState, args: struct { id: []const u8 }) TrayError!?u53 {
        _ = ctx;
        const record = state.trays.getPtr(args.id) orelse return null;
        return record.rid;
    }

    /// `remove_by_id` — destroys the tray and its channel.
    pub fn remove_by_id(ctx: *rpc.Ctx, state: *TrayState, args: struct { id: []const u8 }) TrayError!void {
        _ = ctx;
        if (state.trays.fetchRemove(args.id)) |entry| {
            state.allocator.free(entry.key);
            var options = entry.value.options;
            options.deinit(state.allocator);
        } else return error.NotFound;
        if (state.channels.fetchRemove(args.id)) |entry| state.allocator.free(entry.key);
        state.syncEmitter();
        try state.backend.remove(args.id);
    }

    /// One state change applied to an existing tray. Values are passed explicitly (nested `fn`
    /// cannot capture locals) and then re-pushed to the backend as a full snapshot.
    pub const Mutation = union(enum) {
        icon: ?menu.Icon,
        menu: ?struct { u53, menu.ItemKind },
        tooltip: ?[]const u8,
        title: ?[]const u8,
        temp_dir_path: ?[]const u8,
        icon_as_template: bool,
        show_menu_on_left_click: bool,
        icon_with_template: struct { icon: ?menu.Icon, as_template: bool },
    };

    fn update(ctx: *rpc.Ctx, state: *TrayState, id: []const u8, mutation: Mutation) TrayError!void {
        const record = state.trays.getPtr(id) orelse return error.BadResourceId;
        try apply(record, state.allocator, mutation);
        const snapshot = try state.menuSnapshot(ctx.scratch, record);
        state.syncEmitter();
        try state.backend.update(id, record.options.toOptions(), snapshot);
    }

    fn apply(record: *TrayState.TrayRecord, alloc: Allocator, mutation: Mutation) TrayError!void {
        switch (mutation) {
            .icon => |icon| record.options.icon = icon,
            .menu => |m| {
                if (m) |target| {
                    record.options.has_menu = true;
                    record.options.menu_rid = target[0];
                    record.options.menu_kind = target[1];
                } else record.options.has_menu = false;
            },
            .tooltip => |value| record.options.tooltip = try adoptOpt(&record.options, alloc, value),
            .title => |value| record.options.title = try adoptOpt(&record.options, alloc, value),
            .temp_dir_path => |value| record.options.temp_dir_path = try adoptOpt(&record.options, alloc, value),
            .icon_as_template => |value| record.options.icon_as_template = value,
            .show_menu_on_left_click => |value| record.options.show_menu_on_left_click = value,
            .icon_with_template => |value| {
                record.options.icon = value.icon;
                record.options.icon_as_template = value.as_template;
            },
        }
    }

    fn adoptOpt(options: *TrayState.OwnedOptions, alloc: Allocator, value: ?[]const u8) TrayError!?[]const u8 {
        const bytes = value orelse return null;
        return options.adopt(alloc, bytes) catch return error.OutOfMemory;
    }

    fn idOf(state: *TrayState, rid: u53) TrayError![]const u8 {
        const handle = state.resources.getPtr(TrayHandle, rid) catch return error.BadResourceId;
        return handle.id;
    }

    /// `set_icon` — replaces the icon image.
    pub fn set_icon(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        rid: u53,
        icon: menu.JsonArg = .{},
    }) TrayError!void {
        const id = try idOf(state, args.rid);
        const icon = if (args.icon.value) |v| menu.Icon.fromValue(v) else null;
        return update(ctx, state, id, .{ .icon = icon });
    }

    /// `set_menu` — attaches (or detaches, with `null`) the tray's menu.
    pub fn set_menu(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        rid: u53,
        menu: menu.JsonArg = .{},
    }) TrayError!void {
        const id = try idOf(state, args.rid);
        const target: ?struct { u53, menu.ItemKind } = blk: {
            const value = args.menu.value orelse break :blk null;
            const tuple = switch (value) {
                .array => |a| a,
                else => return error.Failed,
            };
            if (tuple.items.len != 2) return error.Failed;
            const mrid = u53Of(tuple.items[0]) orelse return error.Failed;
            const kind = itemKindOf(tuple.items[1]) orelse return error.Failed;
            break :blk .{ mrid, kind };
        };
        return update(ctx, state, id, .{ .menu = target });
    }

    /// `set_tooltip` — sets the hover text.
    pub fn set_tooltip(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        rid: u53,
        tooltip: ?[]const u8 = null,
    }) TrayError!void {
        const id = try idOf(state, args.rid);
        return update(ctx, state, id, .{ .tooltip = args.tooltip });
    }

    /// `set_title` — sets the text shown next to the icon on macOS.
    pub fn set_title(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        rid: u53,
        title: ?[]const u8 = null,
    }) TrayError!void {
        const id = try idOf(state, args.rid);
        return update(ctx, state, id, .{ .title = args.title });
    }

    /// `set_visible` — shows or hides the icon.
    pub fn set_visible(ctx: *rpc.Ctx, state: *TrayState, args: struct { rid: u53, visible: bool }) TrayError!void {
        _ = ctx;
        const id = try idOf(state, args.rid);
        if (state.trays.getPtr(id)) |record| record.visible = args.visible;
        state.syncEmitter();
        try state.backend.setVisible(id, args.visible);
    }

    /// `set_temp_dir_path` — where the backend may unpack an icon file.
    pub fn set_temp_dir_path(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        rid: u53,
        path: ?[]const u8 = null,
    }) TrayError!void {
        const id = try idOf(state, args.rid);
        return update(ctx, state, id, .{ .temp_dir_path = args.path });
    }

    /// `set_icon_as_template` — treats the icon as a macOS template image.
    pub fn set_icon_as_template(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        rid: u53,
        as_template: bool,
    }) TrayError!void {
        const id = try idOf(state, args.rid);
        return update(ctx, state, id, .{ .icon_as_template = args.as_template });
    }

    /// `set_icon_with_as_template` — replaces the icon and its template flag in one call.
    pub fn set_icon_with_as_template(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        rid: u53,
        icon: menu.JsonArg = .{},
        as_template: bool,
    }) TrayError!void {
        const id = try idOf(state, args.rid);
        const icon = if (args.icon.value) |v| menu.Icon.fromValue(v) else null;
        return update(ctx, state, id, .{ .icon_with_template = .{ .icon = icon, .as_template = args.as_template } });
    }

    /// `set_show_menu_on_left_click` — whether a left click opens the menu.
    pub fn set_show_menu_on_left_click(ctx: *rpc.Ctx, state: *TrayState, args: struct {
        rid: u53,
        on_left: bool,
    }) TrayError!void {
        const id = try idOf(state, args.rid);
        return update(ctx, state, id, .{ .show_menu_on_left_click = args.on_left });
    }
};

/// Opaque `plugin:resources` payload so `tray.close()` resolves the tray by id.
pub const TrayHandle = struct {
    /// Allocator that owns `id`.
    allocator: Allocator,
    /// Wire tray id, so `tray.close()` can find the record again.
    id: []u8,

    /// Frees the tray id (called when the resource table drops the handle).
    pub fn deinit(self: *TrayHandle) void {
        self.allocator.free(self.id);
    }
};

// ============================================================================
// JSON helpers
// ============================================================================

fn stringOf(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn boolOf(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn u53Of(value: std.json.Value) ?u53 {
    return switch (value) {
        .integer => |n| if (n < 0) null else @intCast(n),
        .float => |f| if (f < 0) null else @intFromFloat(f),
        else => null,
    };
}

fn itemKindOf(value: std.json.Value) ?menu.ItemKind {
    const raw = stringOf(value) orelse return null;
    inline for (@typeInfo(menu.ItemKind).@"enum".field_names, 0..) |field_name, index| {
        if (std.mem.eql(u8, raw, field_name)) return @fromBackingInt(@intCast(index));
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const TestSchema = rpc.Schema(.{
    .menu = menu.Commands,
    .tray = Commands,
    .resources = @import("../resources.zig").Commands,
});

const Fixture = struct {
    resources: ResourceTable,
    menu_mock: menu.Mock,
    menu_state: menu.MenuState,
    mock: Mock,
    state: TrayState,
    host: core.RecordingHost,
    window: core.WindowId,
    arena: std.heap.ArenaAllocator,

    fn create() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.resources = ResourceTable.init(testing.allocator, testing.io);
        self.menu_mock = menu.Mock.init(testing.allocator);
        self.menu_state = menu.MenuState.init(testing.allocator, testing.io, &self.resources)
            .withBackend(self.menu_mock.backend());
        self.mock = Mock.init(testing.allocator);
        self.state = TrayState.init(testing.allocator, testing.io, &self.resources, &self.menu_state)
            .withBackend(self.mock.backend());
        self.host = core.RecordingHost.init(testing.allocator);
        self.window = try self.host.host().createWindow(.{ .title = "tray" });
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.resources.deinit();
        self.state.deinit();
        self.mock.deinit();
        self.menu_state.deinit();
        self.menu_mock.deinit();
        self.host.deinit();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    fn invoke(self: *Fixture, command: []const u8, payload: []const u8) !core.OutgoingResponse {
        _ = self.arena.reset(.retain_capacity);
        var router = TestSchema.bind(.{
            .menu = &self.menu_state,
            .tray = &self.state,
            .resources = &self.resources,
        });
        var handler = router.handler();
        var call_ctx = core.CallContext{ .host = self.host.host(), .window_id = self.window };
        var ctx = rpc.Ctx.init(testing.io, self.arena.allocator()).withEnv(&call_ctx);
        return handler.dispatch(testing.allocator, &ctx, command, payload);
    }

    fn body(self: *Fixture, command: []const u8, payload: []const u8) ![]u8 {
        var resp = try self.invoke(command, payload);
        defer resp.deinit();
        if (resp.status != .ok) std.debug.print("\n[tray] {d} {s}\n", .{ resp.http_code, resp.body.slice() });
        try testing.expectEqual(core.IpcStatus.ok, resp.status);
        return testing.allocator.dupe(u8, resp.body.slice());
    }
};

test "plugin:tray|new records the tray, resolves its rid by id and forwards the menu snapshot" {
    var f = try Fixture.create();
    defer f.destroy();

    // A tray that owns a menu with two items.
    const menu_body = try f.body("plugin:menu|new", "{\"kind\":\"Menu\",\"options\":{\"items\":[{\"text\":\"Show\",\"id\":\"show\"},{\"text\":\"Quit\",\"id\":\"quit\"}]}}");
    defer testing.allocator.free(menu_body);
    var parsed = try std.json.parseFromSlice([2]std.json.Value, testing.allocator, menu_body, .{});
    defer parsed.deinit();
    const menu_rid: u53 = @intCast(parsed.value[0].integer);

    const new_payload = try std.fmt.allocPrint(testing.allocator, "{{\"options\":{{\"id\":\"main\",\"tooltip\":\"Z-Ts\",\"menu\":[{d},\"Menu\"]}},\"handler\":\"__CHANNEL__:77\"}}", .{menu_rid});
    defer testing.allocator.free(new_payload);
    const created = try f.body("plugin:tray|new", new_payload);
    defer testing.allocator.free(created);

    const call = f.mock.lastCall().?;
    try testing.expectEqualStrings("main", call.id);
    try testing.expectEqualStrings("Z-Ts", call.tooltip.?);
    try testing.expectEqual(@as(usize, 2), call.menu_ids.len);
    try testing.expectEqualStrings("show", call.menu_ids[0]);

    // `get_by_id` returns the rid handed out at creation (upstream returns the stored rid).
    const rid_body = try f.body("plugin:tray|get_by_id", "{\"id\":\"main\"}");
    defer testing.allocator.free(rid_body);
    var created_parsed = try std.json.parseFromSlice([2]std.json.Value, testing.allocator, created, .{});
    defer created_parsed.deinit();
    const created_rid = try std.fmt.allocPrint(testing.allocator, "{d}", .{created_parsed.value[0].integer});
    defer testing.allocator.free(created_rid);
    try testing.expectEqualStrings(created_rid, rid_body);

    // Tray events reach the `Channel<TrayIconEvent>` with `mapEvent`-compatible fields.
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    f.state.emit(scratch.allocator(), TrayEvent.click("main", 10, 20, "Left", "Up"));
    try testing.expectEqual(@as(usize, 1), f.host.eval_log.items.len);
    try testing.expect(std.mem.indexOf(u8, f.host.eval_log.items[0], "\"type\":\"Click\"") != null);
    try testing.expect(std.mem.indexOf(u8, f.host.eval_log.items[0], "\"position\":{\"x\":10") != null);
    try testing.expect(std.mem.indexOf(u8, f.host.eval_log.items[0], "\"buttonState\":\"Up\"") != null);

    // Removal notifies the backend and clears the id.
    const removed = try f.body("plugin:tray|remove_by_id", "{\"id\":\"main\"}");
    defer testing.allocator.free(removed);
    try testing.expectEqualStrings("null", removed);
    try testing.expectEqual(Mock.CallKind.remove, f.mock.lastCall().?.kind);

    const gone = try f.body("plugin:tray|get_by_id", "{\"id\":\"main\"}");
    defer testing.allocator.free(gone);
    try testing.expectEqualStrings("null", gone);
}

test "plugin:tray setters update the owned options and re-push the menu snapshot" {
    var f = try Fixture.create();
    defer f.destroy();

    const created = try f.body("plugin:tray|new", "{\"options\":{\"id\":\"t\"}}");
    defer testing.allocator.free(created);
    var parsed = try std.json.parseFromSlice([2]std.json.Value, testing.allocator, created, .{});
    defer parsed.deinit();
    const rid: u53 = @intCast(parsed.value[0].integer);

    const set_tooltip = try std.fmt.allocPrint(testing.allocator, "{{\"rid\":{d},\"tooltip\":\"Hello\"}}", .{rid});
    defer testing.allocator.free(set_tooltip);
    const tooltip_body = try f.body("plugin:tray|set_tooltip", set_tooltip);
    defer testing.allocator.free(tooltip_body);
    try testing.expectEqualStrings("Hello", f.mock.lastCall().?.tooltip.?);

    const set_visible = try std.fmt.allocPrint(testing.allocator, "{{\"rid\":{d},\"visible\":false}}", .{rid});
    defer testing.allocator.free(set_visible);
    const visible_body = try f.body("plugin:tray|set_visible", set_visible);
    defer testing.allocator.free(visible_body);
    try testing.expectEqual(Mock.CallKind.set_visible, f.mock.lastCall().?.kind);
    try testing.expectEqual(false, f.mock.lastCall().?.visible.?);

    // Unknown rid and unknown id are rejected rather than silently ignored.
    {
        var resp = try f.invoke("plugin:tray|set_title", "{\"rid\":999999,\"title\":\"x\"}");
        defer resp.deinit();
        try testing.expectEqual(core.IpcStatus.err, resp.status);
    }
}

test "plugin:tray forwards native interactions into the tray's Channel<TrayEvent>" {
    var f = try Fixture.create();
    defer f.destroy();

    const created = try f.body(
        "plugin:tray|new",
        "{\"options\":{\"id\":\"main\",\"tooltip\":\"Z-Ts\"},\"handler\":\"__CHANNEL__:7777\"}",
    );
    defer testing.allocator.free(created);

    // `TrayState` installed itself as the interaction receiver before creating the icon, so a
    // backend that reports a click (here via `Mock.interact`) lands in `Channel<TrayEvent>`.
    try testing.expect(f.mock.emitter != null);
    f.mock.interact(TrayEvent.click("main", 10, 20, "Left", "Up"));

    try testing.expectEqual(@as(usize, 1), f.host.eval_log.items.len);
    const script = f.host.eval_log.items[0];
    try testing.expect(std.mem.indexOf(u8, script, "runCallback(7777,") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"type\":\"Click\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "\"position\":{\"x\":10") != null);
}
