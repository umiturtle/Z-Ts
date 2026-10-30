//! macOS native menus via AppKit (`NSMenu` / `NSMenuItem`), through the Flat C shim in
//! `native_macos_shim.m`.
//!
//! The core hands over a **flattened pre-order snapshot** with a `depth` per entry (see
//! `docs/architecture/tauri-menu-tray.md`). `snapshot_wire.zig` validates it and rewrites the
//! platform-specific bits (labels, key equivalents, command ids); this file only owns lifetime
//! and attachment:
//!
//! * `applyAppMenu` → `[NSApp setMainMenu:]`
//! * `applyWindowMenu` → `[window setMenu:]` (AppKit has no per-window menu bar, but `NSWindow`
//!   carries the menu bar shown while that window is key — what upstream `muda` uses too)
//! * `popup` → `[NSMenu popUpMenuPositioningItem:atLocation:inView:]`
//!
//! Everything is process-global, like AppKit itself. One `NSMenu` handle exists per menu target
//! (the app plus every window label), because re-applying a menu must not disturb the others.

const std = @import("std");
const Allocator = std.mem.Allocator;

const menu = @import("mod.zig");
const wire = @import("snapshot_wire.zig");

const Error = menu.MenuError;

/// Process-lifetime allocations: a menu lives until the process (or the window) goes away, which
/// is AppKit's own model. `page_allocator` keeps this independent of the host's allocator.
const gpa = std.heap.page_allocator;

pub const max_depth = wire.max_depth;

/// `ZtsMenuActivateFn` in the shim.
const ActivateFn = *const fn (ctx: ?*anyopaque, command: u16) callconv(.c) void;

extern "c" fn zts_menu_init() c_int;
extern "c" fn zts_menu_new(callback: ?ActivateFn, ctx: ?*anyopaque) ?*anyopaque;
extern "c" fn zts_menu_set_activator(raw: ?*anyopaque, callback: ?ActivateFn, ctx: ?*anyopaque) void;
extern "c" fn zts_menu_free(raw: ?*anyopaque) void;
extern "c" fn zts_menu_apply(raw: ?*anyopaque, entries: ?[*]const wire.WireEntry, count: usize) c_int;
extern "c" fn zts_menu_root(raw: ?*anyopaque) ?*anyopaque;
extern "c" fn zts_menu_set_app(raw: ?*anyopaque) void;
extern "c" fn zts_menu_set_window(raw: ?*anyopaque, ns_window: ?*anyopaque) void;
extern "c" fn zts_menu_popup(raw: ?*anyopaque, ns_view: ?*anyopaque, x: f64, y: f64, has_position: c_int) c_int;
extern "c" fn zts_menu_window_new(width: f64, height: f64) ?*anyopaque;
extern "c" fn zts_menu_window_free(ns_window: ?*anyopaque) void;

// Introspection (tests, plus hosts that want to restyle the bar).
extern "c" fn zts_menu_item_count(raw_menu: ?*anyopaque) usize;
extern "c" fn zts_menu_item_title(raw_menu: ?*anyopaque, index: usize) ?[*:0]u8;
extern "c" fn zts_menu_item_key_equivalent(raw_menu: ?*anyopaque, index: usize) ?[*:0]u8;
extern "c" fn zts_menu_item_key_mask(raw_menu: ?*anyopaque, index: usize) c_int;
extern "c" fn zts_menu_item_enabled(raw_menu: ?*anyopaque, index: usize) c_int;
extern "c" fn zts_menu_item_state(raw_menu: ?*anyopaque, index: usize) c_int;
extern "c" fn zts_menu_item_has_role(raw_menu: ?*anyopaque, index: usize) c_int;
extern "c" fn zts_menu_item_tag(raw_menu: ?*anyopaque, index: usize) c_int;
extern "c" fn zts_menu_submenu_at(raw_menu: ?*anyopaque, index: usize) ?*anyopaque;
extern "c" fn zts_menu_fire(raw: ?*anyopaque, command: u16) c_int;
extern "c" fn zts_native_free(ptr: ?*anyopaque) void;

/// One `NSMenu` handle plus the wire it currently renders (`command` → `MenuId`).
const Menu = struct {
    /// `null` = the application menu bar.
    label: ?[]const u8,
    handle: *anyopaque,
    wire: ?wire.Wire = null,
    /// `NSWindow *` registered for this label (window menus only).
    window: ?*anyopaque = null,
};

var menus: std.ArrayListUnmanaged(*Menu) = .empty;
/// Menus with no attachment (the tray owns them); kept apart from `menus` so `findMenu(null)`
/// keeps meaning "the application menu bar".
var detached: std.ArrayListUnmanaged(*Menu) = .empty;
var activator: menu.Activator = .{};

fn findMenu(label: ?[]const u8) ?*Menu {
    for (menus.items) |m| {
        const matches = if (label) |l| (m.label != null and std.mem.eql(u8, m.label.?, l)) else m.label == null;
        if (matches) return m;
    }
    return null;
}

/// AppKit `action:` receiver → the core's `Activator`.
fn onActivate(ctx: ?*anyopaque, command: u16) callconv(.c) void {
    const m: *Menu = @ptrCast(@alignCast(ctx orelse return));
    const w = m.wire orelse return;
    const id = w.idForCommand(command) orelse return;
    activator.call(activator.ctx, id);
}

fn ensureMenu(label: ?[]const u8) Error!*Menu {
    if (findMenu(label)) |m| return m;

    const copy = if (label) |l| (gpa.dupe(u8, l) catch return error.OutOfMemory) else null;
    errdefer if (copy) |c| gpa.free(c);

    const m = gpa.create(Menu) catch return error.OutOfMemory;
    errdefer gpa.destroy(m);
    m.* = .{ .label = copy, .handle = undefined };
    m.handle = zts_menu_new(onActivate, m) orelse return error.Unavailable;

    menus.append(gpa, m) catch {
        zts_menu_free(m.handle);
        return error.OutOfMemory;
    };
    return m;
}

/// Rebuilds `m` from `snapshot`; the previous wire is only dropped once AppKit accepted the new one.
fn applyTo(m: *Menu, snapshot: menu.Snapshot) Error!void {
    var next = try wire.build(gpa, snapshot, .macos);
    if (zts_menu_apply(m.handle, next.entries.ptr, next.entries.len) != 0) {
        next.deinit();
        return error.Failed;
    }
    if (m.wire) |*old| old.deinit();
    m.wire = next;
    zts_menu_set_activator(m.handle, onActivate, m);
}

fn applyApp(_: ?*anyopaque, snapshot: menu.Snapshot) Error!void {
    const m = try ensureMenu(null);
    try applyTo(m, snapshot);
    zts_menu_set_app(m.handle);
}

fn applyWindow(_: ?*anyopaque, window: ?[]const u8, snapshot: menu.Snapshot) Error!void {
    const label = window orelse return applyApp(null, snapshot);
    const m = try ensureMenu(label);
    try applyTo(m, snapshot);
    if (m.window) |ns_window| zts_menu_set_window(m.handle, ns_window);
}

fn popup(_: ?*anyopaque, window: ?[]const u8, snapshot: menu.Snapshot, at: ?menu.Position) Error!void {
    var w = try wire.build(gpa, snapshot, .macos);
    defer w.deinit();

    const view: ?*anyopaque = blk: {
        const label = window orelse break :blk null;
        const m = findMenu(label) orelse break :blk null;
        break :blk m.window;
    };

    // A throwaway handle: the popup blocks until dismissed, so nothing has to outlive this call.
    // The stack-local `Menu` gives the C callback the wire it needs to map `command` → `MenuId`.
    var temp: Menu = .{ .label = null, .handle = undefined, .wire = w, .window = view };
    const handle = zts_menu_new(onActivate, &temp) orelse return error.Unavailable;
    defer zts_menu_free(handle);
    temp.handle = handle;

    if (zts_menu_apply(handle, w.entries.ptr, w.entries.len) != 0) return error.Failed;
    const position = at orelse menu.Position{ .x = 0, .y = 0 };
    const shown = zts_menu_popup(handle, view, position.x, position.y, if (at != null) 1 else 0);
    if (shown == 0) return error.Unavailable;
}

fn setActivatorImpl(_: ?*anyopaque, next: menu.Activator) void {
    activator = next;
}

const vtable = menu.Backend.VTable{
    .apply_app_menu = applyApp,
    .apply_window_menu = applyWindow,
    .popup = popup,
    .set_activator = setActivatorImpl,
};

/// The AppKit menu backend. `registerWindow` must run for every toplevel that wants a menu bar.
pub fn backend() menu.Backend {
    return .{ .vtable = &vtable };
}

// ============================================================================
// Window attachment / host API
// ============================================================================

/// Registers a toplevel `NSWindow *` so a window menu can be installed on it. A menu that was
/// applied before the window existed is attached immediately (same replay rule as GTK).
pub fn registerWindow(label: []const u8, ns_window: ?*anyopaque) Error!void {
    const handle = ns_window orelse return error.Unsupported;
    const m = try ensureMenu(label);
    m.window = handle;
    if (m.wire != null) zts_menu_set_window(m.handle, handle);
}

/// Forgets a window (the `NSWindow` itself belongs to the host).
pub fn unregisterWindow(label: []const u8) void {
    for (menus.items, 0..) |m, i| {
        if (m.label == null or !std.mem.eql(u8, m.label.?, label)) continue;
        zts_menu_free(m.handle);
        if (m.wire) |*w| w.deinit();
        gpa.free(m.label.?);
        gpa.destroy(m);
        _ = menus.orderedRemove(i);
        return;
    }
}

/// The `NSMenu *` currently rendered for `label` (`null` = the app menu), if any.
pub fn menuFor(label: ?[]const u8) ?*anyopaque {
    const m = findMenu(label) orelse return null;
    return zts_menu_root(m.handle);
}

/// The opaque handle behind `label` (tests drive activations through it).
pub fn handleFor(label: ?[]const u8) ?*anyopaque {
    const m = findMenu(label) orelse return null;
    return m.handle;
}

// ============================================================================
// Detached menus (tray icons and hosts that own the `NSMenu` themselves)
// ============================================================================

/// Builds an `NSMenu` that is not attached to a window or the app bar. It shares this module's
/// `Activator`, so a click anywhere (tray, popover, …) still reaches the item's
/// `Channel<string>` exactly like a menu-bar item.
///
/// The returned handle must be released with `freeDetached`; the `NSMenu *` itself is
/// `nsMenuOf(handle)`.
pub fn buildDetached(snapshot: menu.Snapshot) Error!*anyopaque {
    const m = gpa.create(Menu) catch return error.OutOfMemory;
    errdefer gpa.destroy(m);
    m.* = .{ .label = null, .handle = undefined };
    m.handle = zts_menu_new(onActivate, m) orelse return error.Unavailable;
    errdefer zts_menu_free(m.handle);
    try applyTo(m, snapshot);
    detached.append(gpa, m) catch {
        zts_menu_free(m.handle);
        return error.OutOfMemory;
    };
    return m.handle;
}

pub fn freeDetached(handle: ?*anyopaque) void {
    const target = handle orelse return;
    for (detached.items, 0..) |m, i| {
        if (m.handle != target) continue;
        zts_menu_free(m.handle);
        if (m.wire) |*w| w.deinit();
        gpa.destroy(m);
        _ = detached.orderedRemove(i);
        return;
    }
}

/// The `NSMenu *` behind a handle from `buildDetached` / `handleFor`.
pub fn nsMenuOf(handle: ?*anyopaque) ?*anyopaque {
    return zts_menu_root(handle);
}

/// Clears the process-global registry (tests keep the fixtures isolated).
pub fn resetForTesting() void {
    for (menus.items) |m| {
        zts_menu_free(m.handle);
        if (m.wire) |*w| w.deinit();
        if (m.label) |l| gpa.free(l);
        gpa.destroy(m);
    }
    menus.clearRetainingCapacity();
    for (detached.items) |m| {
        zts_menu_free(m.handle);
        if (m.wire) |*w| w.deinit();
        gpa.destroy(m);
    }
    detached.clearRetainingCapacity();
    activator = .{};
}

// ============================================================================
// Tests — these build real NSMenus (macOS CI runs them; a headless session skips)
// ============================================================================

const testing = std.testing;

fn titleOf(allocator: Allocator, raw_menu: ?*anyopaque, index: usize) ![]u8 {
    const raw = zts_menu_item_title(raw_menu, index) orelse return error.NoTitle;
    defer zts_native_free(@ptrCast(raw));
    return allocator.dupe(u8, std.mem.span(raw));
}

fn keyOf(allocator: Allocator, raw_menu: ?*anyopaque, index: usize) ![]u8 {
    const raw = zts_menu_item_key_equivalent(raw_menu, index) orelse return allocator.dupe(u8, "");
    defer zts_native_free(@ptrCast(raw));
    return allocator.dupe(u8, std.mem.span(raw));
}

test "cocoa menu mirrors the flattened snapshot: nesting, labels, state, accelerators" {
    if (zts_menu_init() == 0) return error.SkipZigTest;
    resetForTesting();
    defer resetForTesting();

    const entries = [_]menu.Entry{
        .{ .kind = .submenu, .id = "1", .text = "_File", .depth = 0 },
        .{ .kind = .item, .id = "2", .text = "_New", .depth = 1, .accelerator = menu.Accelerator.parse("CmdOrCtrl+N") catch unreachable },
        .{ .kind = .separator, .id = "3", .text = "", .depth = 1 },
        .{ .kind = .item, .id = "4", .text = "E_xit", .depth = 1, .enabled = false, .predefined = .Quit },
        .{ .kind = .submenu, .id = "5", .text = "_View", .depth = 0 },
        .{ .kind = .item, .id = "6", .text = "_Grid", .depth = 1, .item_kind = .Check, .checked = true },
        .{ .kind = .item, .id = "7", .text = "Fish & Chips", .depth = 0 },
    };
    try backend().applyAppMenu(.{ .entries = &entries });

    const root = menuFor(null) orelse return error.NotAttached;
    try testing.expectEqual(@as(usize, 3), zts_menu_item_count(root));

    // (1) AppKit has no mnemonics: `_File` must render as `File`.
    const file_title = try titleOf(testing.allocator, root, 0);
    defer testing.allocator.free(file_title);
    try testing.expectEqualStrings("File", file_title);

    // (2) `File` holds New / separator / Exit.
    const file_menu = zts_menu_submenu_at(root, 0) orelse return error.NoSubmenu;
    try testing.expectEqual(@as(usize, 3), zts_menu_item_count(file_menu));

    const new_title = try titleOf(testing.allocator, file_menu, 0);
    defer testing.allocator.free(new_title);
    try testing.expectEqualStrings("New", new_title);

    // (3) The accelerator lives on the item itself (rendered *and* active on macOS).
    const key = try keyOf(testing.allocator, file_menu, 0);
    defer testing.allocator.free(key);
    try testing.expectEqualStrings("n", key);
    const mask = zts_menu_item_key_mask(file_menu, 0);
    try testing.expect(mask & 0x8 != 0); // Command (from CmdOrCtrl)

    // (4) Quit is a native role (`terminate:`) and disabled.
    const quit_title = try titleOf(testing.allocator, file_menu, 2);
    defer testing.allocator.free(quit_title);
    try testing.expectEqualStrings("Exit", quit_title);
    try testing.expectEqual(@as(c_int, 1), zts_menu_item_has_role(file_menu, 2));
    try testing.expectEqual(@as(c_int, 0), zts_menu_item_enabled(file_menu, 2));

    // (5) A check item round-trips `state`, and `&` stays a literal on macOS.
    const view_menu = zts_menu_submenu_at(root, 1) orelse return error.NoSubmenu;
    try testing.expectEqual(@as(c_int, 1), zts_menu_item_state(view_menu, 0));
    const grid = try titleOf(testing.allocator, view_menu, 0);
    defer testing.allocator.free(grid);
    try testing.expectEqualStrings("Grid", grid);
    const chips = try titleOf(testing.allocator, root, 2);
    defer testing.allocator.free(chips);
    try testing.expectEqualStrings("Fish & Chips", chips);
    try testing.expectEqual(@as(c_int, 0), zts_menu_item_has_role(root, 2));

    // (6) Re-applying replaces the items instead of stacking a second menu.
    try backend().applyAppMenu(.{ .entries = &entries });
    try testing.expectEqual(@as(usize, 3), zts_menu_item_count(menuFor(null).?));

    std.debug.print("OK menu-cocoa checks=6 items={d}\n", .{zts_menu_item_count(root)});
}

test "cocoa activation reports the MenuId through the bridge object" {
    if (zts_menu_init() == 0) return error.SkipZigTest;
    resetForTesting();
    defer resetForTesting();

    const Recorder = struct {
        var ids = [_][]const u8{ "", "", "", "" };
        var count: usize = 0;
        fn record(_: ?*anyopaque, id: []const u8) void {
            if (count < ids.len) ids[count] = id;
            count += 1;
        }
    };
    Recorder.count = 0;
    backend().setActivator(.{ .call = Recorder.record });

    const entries = [_]menu.Entry{
        .{ .kind = .item, .id = "save", .text = "Save", .depth = 0 },
        .{ .kind = .item, .id = "grid", .text = "Grid", .depth = 0, .item_kind = .Check },
    };
    try backend().applyAppMenu(.{ .entries = &entries });

    const handle = handleFor(null) orelse return error.NotAttached;
    try testing.expectEqual(@as(c_int, 1), zts_menu_fire(handle, 1));
    try testing.expectEqual(@as(usize, 1), Recorder.count);
    try testing.expectEqualStrings("save", Recorder.ids[0]);

    try testing.expectEqual(@as(c_int, 1), zts_menu_fire(handle, 2));
    try testing.expectEqualStrings("grid", Recorder.ids[1]);

    // An unknown command is simply not found.
    try testing.expectEqual(@as(c_int, 0), zts_menu_fire(handle, 99));
}

test "cocoa per-window menus attach to the registered NSWindow" {
    if (zts_menu_init() == 0) return error.SkipZigTest;
    resetForTesting();
    defer resetForTesting();

    const window = zts_menu_window_new(320, 200) orelse return error.SkipZigTest;
    defer zts_menu_window_free(window);

    // A menu applied before the window exists is replayed by `registerWindow`.
    const entries = [_]menu.Entry{
        .{ .kind = .item, .id = "only", .text = "Only", .depth = 0 },
    };
    try backend().applyWindowMenu("main", .{ .entries = &entries });
    try registerWindow("main", window);
    try testing.expectEqual(@as(usize, 1), zts_menu_item_count(menuFor("main").?));

    // Replacing it through the backend keeps the same NSMenu object (attached to the window).
    try backend().applyWindowMenu("main", .{ .entries = &entries });
    try testing.expectEqual(@as(usize, 1), zts_menu_item_count(menuFor("main").?));

    // A `null` label is the app menu bar.
    try backend().applyWindowMenu(null, .{ .entries = &entries });
    try testing.expect(menuFor(null) != null);

    unregisterWindow("main");
    try testing.expect(menuFor("main") == null);
}

test "the app menu handle is reusable and the backend fails closed without AppKit" {
    resetForTesting();
    defer resetForTesting();

    const entries = [_]menu.Entry{
        .{ .kind = .item, .id = "x", .text = "X", .depth = 0 },
    };
    try backend().applyAppMenu(.{ .entries = &entries });
    const first = handleFor(null).?;
    try backend().applyAppMenu(.{ .entries = &entries });
    try testing.expectEqual(first, handleFor(null).?);

    // A snapshot that skips a level must never reach AppKit.
    const broken = [_]menu.Entry{
        .{ .kind = .item, .id = "deep", .text = "Deep", .depth = 1 },
    };
    try testing.expectError(error.InvalidMenuDepth, backend().applyAppMenu(.{ .entries = &broken }));
}
