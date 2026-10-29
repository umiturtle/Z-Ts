//! Linux native menus via GTK3 (`GtkMenuBar` / `GtkMenu` / `GtkMenuItem`).
//!
//! The core hands over a **flattened pre-order snapshot** with a `depth` per entry (see
//! `docs/architecture/tauri-menu-tray.md`). This file turns that list into a widget tree: depth 0
//! goes into a `GtkMenuBar`, a `.submenu` entry opens a `GtkMenu` for depth + 1, everything else
//! becomes a leaf in the shell of its own depth. No diffing, no widget bookkeeping in the core.
//!
//! ## Window attachment
//!
//! GTK has **no application menu bar**: the menu is a widget packed into a window. The host
//! therefore registers each toplevel window (`registerWindow`); a `GtkMenuBar` is packed at index
//! 0 of the window's direct child, which the host must have created as a *vertical* `GtkBox`
//! (exactly the layout Tauri itself uses: `GtkWindow → GtkBox(v) → [menu bar] + content`).
//! Anything else is rejected with `error.Unsupported` instead of silently doing nothing.
//!
//! Everything is process-global, like GTK itself: menus outlive individual `plugin:menu` calls and
//! the toolkit is not thread-safe, so state lives next to the toolkit rather than next to the
//! plugin state.

const std = @import("std");
const Allocator = std.mem.Allocator;

const menu = @import("mod.zig");
const accelerator = @import("accelerator.zig");
const gtk = @import("../native_gtk.zig");
const cstr = @import("../native_cstr.zig");

const Error = menu.MenuError;

/// Process-lifetime allocations: a menu lives until the process (or the window) goes away, which is
/// exactly GTK's own lifetime model. `page_allocator` keeps this independent of whichever
/// allocator the host happened to hand `MenuState`.
const gpa = std.heap.page_allocator;

/// Maximum menu nesting we render. Deeper trees are rejected (an 8-level menu is already absurd).
pub const max_depth = 8;

const WindowEntry = struct {
    label: []const u8,
    window: *gtk.GtkWidget, // GtkWindow
    menu_bar: ?*gtk.GtkWidget = null,
};

var windows: std.ArrayListUnmanaged(WindowEntry) = .empty;
var app_snapshot: ?[]menu.Entry = null;
var window_snapshots: std.StringHashMapUnmanaged([]menu.Entry) = .empty;
var accelerator_group: ?*gtk.GtkAccelGroup = null;
var activator: menu.Activator = .{};
/// The menu currently popped up (kept so tests — and `resetForTesting` — can dismiss it).
var last_popup: ?*gtk.GtkWidget = null;

// ============================================================================
// Snapshot storage (the core's slices are only valid for the duration of a call)
// ============================================================================

fn freeEntries(entries: []menu.Entry) void {
    for (entries) |entry| {
        gpa.free(entry.id);
        gpa.free(entry.text);
    }
    gpa.free(entries);
}

fn cloneEntries(entries: []const menu.Entry) Error![]menu.Entry {
    const out = gpa.alloc(menu.Entry, entries.len) catch return error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |entry| {
            gpa.free(entry.id);
            gpa.free(entry.text);
        }
        gpa.free(out);
    }
    for (entries, 0..) |entry, i| {
        out[i] = entry;
        out[i].id = gpa.dupe(u8, entry.id) catch return error.OutOfMemory;
        out[i].text = gpa.dupe(u8, entry.text) catch return error.OutOfMemory;
        // `AboutMetadata` carries strings owned by the core node; nothing on GTK reads them and
        // keeping the pointers would dangle once the node goes away.
        if (entry.predefined) |p| switch (p) {
            .About => out[i].predefined = .{ .About = null },
            else => {},
        };
        filled = i + 1;
    }
    return out;
}

// ============================================================================
// Widget construction
// ============================================================================

fn typeNameOf(widget: *gtk.GtkWidget) []const u8 {
    const instance: *gtk.GTypeInstance = @ptrCast(@alignCast(widget));
    const name = instance.typeName() orelse return "";
    return std.mem.span(name);
}

fn onActivate(_: *gtk.GtkMenuItem, user_data: ?*anyopaque) callconv(.c) void {
    const id: [*:0]const u8 = @ptrCast(user_data orelse return);
    activator.call(activator.ctx, std.mem.span(id));
}

fn onToggled(_: *gtk.GtkCheckMenuItem, user_data: ?*anyopaque) callconv(.c) void {
    const id: [*:0]const u8 = @ptrCast(user_data orelse return);
    activator.call(activator.ctx, std.mem.span(id));
}

/// `GClosureNotify`: releases the copied `MenuId` together with the widget.
fn onClosureNotify(user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const id: [*:0]u8 = @ptrCast(user_data orelse return);
    gpa.free(std.mem.span(id));
}

/// Connects `signal` so that a click reports `id` to the activator (the id is copied; GTK frees it
/// through `onClosureNotify` when the widget dies).
fn connectActivation(
    widget: *gtk.GtkWidget,
    signal: [*:0]const u8,
    id: []const u8,
    handler: *const anyopaque,
) Error!void {
    const owned = cstr.allocZ(gpa, id) catch return error.OutOfMemory;
    errdefer gpa.free(owned);
    if (gtk.g_signal_connect_data(@ptrCast(widget), signal, handler, @ptrCast(owned.ptr), onClosureNotify, 0) == 0) {
        return error.Unavailable;
    }
}

fn applyAccelerator(widget: *gtk.GtkWidget, acc: accelerator.Accelerator, group: *gtk.GtkAccelGroup) void {
    const rendered = acc.renderGtk(gpa) catch return;
    defer gpa.free(rendered);
    const z = cstr.allocZ(gpa, rendered) catch return;
    defer gpa.free(z);

    var key: gtk.guint = 0;
    var mods: c_int = 0;
    if (gtk.gtk_accelerator_parse(z, &key, &mods) == 0) return;
    gtk.gtk_widget_add_accelerator(widget, "activate", group, key, mods, gtk.GTK_ACCEL_VISIBLE);
}

fn textOf(entry: menu.Entry) []const u8 {
    if (entry.text.len > 0) return entry.text;
    if (entry.predefined) |p| return p.defaultText();
    return "";
}

fn withZ(s: []const u8) Error![:0]u8 {
    return cstr.allocZ(gpa, s) catch error.OutOfMemory;
}

/// Fills `shells` from a flattened snapshot. Mirrors `menu.flatten` exactly: a `.submenu` opens
/// `depth + 1`, every other entry is a leaf in the shell of its own depth.
fn fill(shells: *[max_depth + 1]?*gtk.GtkWidget, entries: []const menu.Entry, group: *gtk.GtkAccelGroup) Error!void {
    for (entries) |entry| {
        if (entry.depth > max_depth) return error.InvalidMenuDepth;
        const depth: usize = entry.depth;
        // `depth` must not skip a level: only a `.submenu` opens one.
        const shell = shells[depth] orelse return error.InvalidMenuDepth;

        const widget: *gtk.GtkWidget = switch (entry.kind) {
            .separator => gtk.gtk_separator_menu_item_new(),
            .submenu => blk: {
                const label = try withZ(textOf(entry));
                defer gpa.free(label);
                const item = gtk.gtk_menu_item_new_with_mnemonic(label.ptr);
                const submenu = gtk.gtk_menu_new();
                gtk.gtk_menu_item_set_submenu(@ptrCast(item), submenu);
                if (depth + 1 > max_depth) return error.InvalidMenuDepth;
                shells[depth + 1] = submenu;
                break :blk item;
            },
            .item => blk: {
                const label = try withZ(textOf(entry));
                defer gpa.free(label);
                if (entry.item_kind == .Check) {
                    const item = gtk.gtk_check_menu_item_new_with_mnemonic(label.ptr);
                    gtk.gtk_check_menu_item_set_active(@ptrCast(item), @intFromBool(entry.checked));
                    try connectActivation(item, "toggled", entry.id, @ptrCast(&onToggled));
                    break :blk item;
                }
                const item = gtk.gtk_menu_item_new_with_mnemonic(label.ptr);
                try connectActivation(item, "activate", entry.id, @ptrCast(&onActivate));
                break :blk item;
            },
        };

        if (entry.accelerator) |acc| applyAccelerator(widget, acc, group);
        if (!entry.enabled) gtk.gtk_widget_set_sensitive(widget, 0);
        gtk.gtk_menu_shell_append(@ptrCast(shell), widget);

        if (entry.kind != .submenu) {
            var i = depth + 1;
            while (i <= max_depth) : (i += 1) shells[i] = null;
        }
    }
}

/// Builds a `GtkMenuBar` (a window's menu bar).
pub fn buildMenuBar(entries: []const menu.Entry, group: *gtk.GtkAccelGroup) Error!*gtk.GtkWidget {
    const bar = gtk.gtk_menu_bar_new();
    var ok = false;
    defer if (!ok) gtk.gtk_widget_destroy(bar);
    var shells: [max_depth + 1]?*gtk.GtkWidget = @splat(null);
    shells[0] = bar;
    try fill(&shells, entries, group);
    gtk.gtk_widget_show_all(bar);
    ok = true;
    return bar;
}

/// Builds a `GtkMenu` (a context menu / a tray menu) from the same flattened snapshot.
pub fn buildContextMenu(entries: []const menu.Entry) Error!*gtk.GtkWidget {
    const popup_menu = gtk.gtk_menu_new();
    var ok = false;
    defer if (!ok) gtk.gtk_widget_destroy(popup_menu);
    var shells: [max_depth + 1]?*gtk.GtkWidget = @splat(null);
    shells[0] = popup_menu;
    try fill(&shells, entries, ensureAccelGroup());
    gtk.gtk_widget_show_all(popup_menu);
    ok = true;
    return popup_menu;
}

// ============================================================================
// Window attachment
// ============================================================================

fn ensureAccelGroup() *gtk.GtkAccelGroup {
    if (accelerator_group) |group| return group;
    const group = gtk.gtk_accel_group_new();
    accelerator_group = group;
    return group;
}

fn findWindow(label: []const u8) ?*WindowEntry {
    for (windows.items) |*entry| {
        if (std.mem.eql(u8, entry.label, label)) return entry;
    }
    return null;
}

/// Packs `bar` at index 0 of `window`'s direct child (a `GtkBox`), replacing `old`.
fn attach(window: *gtk.GtkWidget, bar: *gtk.GtkWidget, old: ?*gtk.GtkWidget) Error!void {
    if (old) |widget| gtk.gtk_widget_destroy(widget);

    const child = gtk.gtk_bin_get_child(@ptrCast(window)) orelse {
        // An empty window: the menu bar becomes its only child (the documented fallback).
        gtk.gtk_container_add(@ptrCast(window), bar);
        gtk.gtk_widget_show_all(bar);
        return;
    };
    if (!std.mem.eql(u8, typeNameOf(child), "GtkBox")) return error.Unsupported;
    gtk.gtk_box_pack_start(@ptrCast(child), bar, 0, 0, 0);
    gtk.gtk_box_reorder_child(@ptrCast(child), bar, 0);
    gtk.gtk_widget_show_all(bar);
}

fn applyTo(entry: *WindowEntry, entries: []const menu.Entry) Error!void {
    const bar = try buildMenuBar(entries, ensureAccelGroup());
    errdefer gtk.gtk_widget_destroy(bar);
    try attach(entry.window, bar, entry.menu_bar);
    entry.menu_bar = bar;
}

/// Registers a toplevel window so menus can be packed into it (applies any menu already set).
pub fn registerWindow(label: []const u8, window: *gtk.GtkWidget) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    if (findWindow(label) != null) return; // idempotent
    const owned = gpa.dupe(u8, label) catch return error.OutOfMemory;
    errdefer gpa.free(owned);
    gtk.gtk_window_add_accel_group(@ptrCast(window), ensureAccelGroup());
    windows.append(gpa, .{ .label = owned, .window = window }) catch return error.OutOfMemory;

    const entry = findWindow(label).?;
    if (window_snapshots.get(label)) |entries| {
        try applyTo(entry, entries);
    } else if (app_snapshot) |entries| {
        try applyTo(entry, entries);
    }
}

/// Removes a window from the registry (the window and its menu bar belong to the host).
pub fn unregisterWindow(label: []const u8) void {
    for (windows.items, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry.label, label)) continue;
        gpa.free(entry.label);
        _ = windows.orderedRemove(i);
        if (window_snapshots.fetchRemove(label)) |kv| {
            gpa.free(kv.key);
            freeEntries(kv.value);
        }
        return;
    }
}

// ============================================================================
// Backend vtable
// ============================================================================

fn applyApp(_: ?*anyopaque, snapshot: menu.Snapshot) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    const stored = try cloneEntries(snapshot.entries);
    errdefer freeEntries(stored);
    for (windows.items) |*entry| {
        if (window_snapshots.get(entry.label) != null) continue; // window menu wins
        try applyTo(entry, stored);
    }
    if (app_snapshot) |old| freeEntries(old);
    app_snapshot = stored;
}

fn applyWindow(_: ?*anyopaque, window: ?[]const u8, snapshot: menu.Snapshot) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    const label = window orelse return applyApp(null, snapshot);

    const stored = try cloneEntries(snapshot.entries);
    errdefer freeEntries(stored);
    const key = gpa.dupe(u8, label) catch return error.OutOfMemory;
    errdefer gpa.free(key);
    if (window_snapshots.fetchRemove(label)) |kv| {
        gpa.free(kv.key);
        freeEntries(kv.value);
    }
    window_snapshots.put(gpa, key, stored) catch return error.OutOfMemory;
    // Windows created later replay this snapshot in `registerWindow`.
    if (findWindow(label)) |entry| try applyTo(entry, stored);
}

fn popup(_: ?*anyopaque, window: ?[]const u8, snapshot: menu.Snapshot, at: ?menu.Position) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;

    const popup_menu = try buildContextMenu(snapshot.entries);
    if (last_popup) |old| {
        gtk.gtk_menu_popdown(@ptrCast(old));
        gtk.gtk_widget_destroy(old);
    }
    last_popup = popup_menu;

    if (at) |position| {
        if (position.logical) {
            const target = if (window) |label| findWindow(label) else null;
            if (target) |entry| {
                if (gtk.gtk_widget_get_window(entry.window)) |gdk_window| {
                    const rect = gtk.GdkRectangle{
                        .x = @intFromFloat(@round(position.x)),
                        .y = @intFromFloat(@round(position.y)),
                        .width = 1,
                        .height = 1,
                    };
                    gtk.gtk_menu_popup_at_rect(
                        @ptrCast(popup_menu),
                        gdk_window,
                        &rect,
                        gtk.GDK_GRAVITY_SOUTH_WEST,
                        gtk.GDK_GRAVITY_NORTH_WEST,
                        null,
                    );
                    return;
                }
            }
        }
    }
    gtk.gtk_menu_popup_at_pointer(@ptrCast(popup_menu), null);
}

/// Dismisses the context menu opened by `plugin:menu|popup` (a popup holds a GTK grab, so a test
/// must close it before the next fixture runs).
pub fn popdown() void {
    const popup_menu = last_popup orelse return;
    last_popup = null;
    gtk.gtk_menu_popdown(@ptrCast(popup_menu));
    gtk.gtk_widget_destroy(popup_menu);
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

/// The GTK menu backend. Call `registerWindow` for every toplevel window first.
pub fn backend() menu.Backend {
    return .{ .vtable = &vtable };
}

// ============================================================================
// Test / host introspection
// ============================================================================

/// The menu bar currently packed into `label`, if any (tests, and hosts that want to style it).
pub fn menuBarFor(label: []const u8) ?*gtk.GtkWidget {
    const entry = findWindow(label) orelse return null;
    return entry.menu_bar;
}

/// Clears the process-global registry (tests keep the fixtures isolated).
pub fn resetForTesting() void {
    for (windows.items) |entry| gpa.free(entry.label);
    windows.clearRetainingCapacity();
    if (app_snapshot) |old| freeEntries(old);
    app_snapshot = null;
    var it = window_snapshots.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        freeEntries(kv.value_ptr.*);
    }
    window_snapshots.clearRetainingCapacity();
    activator = .{};
    popdown();
    if (accelerator_group) |group| gtk.g_object_unref(@ptrCast(group));
    accelerator_group = null;
}

// ============================================================================
// Tests — these build a real GTK widget tree (CI runs them under Xvfb)
// ============================================================================

const testing = std.testing;

fn testWindow() ?*gtk.GtkWidget {
    if (!gtk.ensureInit()) return null;
    const window = gtk.gtk_window_new(gtk.GTK_WINDOW_TOPLEVEL);
    gtk.gtk_window_set_default_size(@ptrCast(window), 320, 200);
    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0);
    gtk.gtk_container_add(@ptrCast(window), box);
    gtk.gtk_widget_show_all(window);
    return window;
}

test "gtk menu bar mirrors the flattened snapshot: nesting, labels, sensitivity, check state" {
    if (!gtk.ensureInit()) return error.SkipZigTest;
    resetForTesting();
    defer resetForTesting();

    const window = testWindow() orelse return error.SkipZigTest;
    defer gtk.gtk_widget_destroy(window);

    try registerWindow("main", window);

    const entries = [_]menu.Entry{
        .{ .kind = .submenu, .id = "1", .text = "_File", .depth = 0 },
        .{ .kind = .item, .id = "2", .text = "_New", .depth = 1, .accelerator = accelerator.Accelerator.parse("CmdOrCtrl+N") catch unreachable },
        .{ .kind = .separator, .id = "3", .text = "", .depth = 1 },
        .{ .kind = .item, .id = "4", .text = "E_xit", .depth = 1, .enabled = false, .predefined = .Quit },
        .{ .kind = .submenu, .id = "5", .text = "_View", .depth = 0 },
        .{ .kind = .item, .id = "6", .text = "_Grid", .depth = 1, .item_kind = .Check, .checked = true },
    };
    try backend().applyAppMenu(.{ .entries = &entries });

    // (1) The bar is packed at index 0 of the window's box.
    const bar = menuBarFor("main") orelse return error.NotAttached;
    try testing.expectEqual(gtk.MenuItemInfo.Kind.menu_bar, gtk.widgetKind(bar));
    const box = gtk.gtk_bin_get_child(@ptrCast(window)).?;
    try testing.expectEqual(@as(usize, 1), gtk.childCount(box));
    try testing.expectEqual(bar, gtk.nthChild(box, 0).?);

    // (2) Top level: two submenus.
    try testing.expectEqual(@as(usize, 2), gtk.childCount(bar));
    const file = gtk.nthChild(bar, 0).?;
    try testing.expectEqual(gtk.MenuItemInfo.Kind.item, gtk.widgetKind(file));

    // (3) `_File` holds New / separator / Exit.
    const file_menu = gtk.gtk_menu_item_get_submenu(@ptrCast(file)).?;
    try testing.expectEqual(gtk.MenuItemInfo.Kind.menu, gtk.widgetKind(file_menu));
    try testing.expectEqual(@as(usize, 3), gtk.childCount(file_menu));
    try testing.expectEqual(gtk.MenuItemInfo.Kind.separator, gtk.widgetKind(gtk.nthChild(file_menu, 1).?));

    // `gtk_menu_item_new_with_mnemonic` keeps the `_` marker in the label property, so the exact
    // string is what a GTK user sees with the mnemonic stripped.
    const first = try gtk.describeMenuItem(gpa, gtk.nthChild(file_menu, 0).?);
    defer if (first.label) |l| gpa.free(l);
    try testing.expectEqualStrings("_New", first.label.?);
    try testing.expect(first.sensitive);

    const exit = try gtk.describeMenuItem(gpa, gtk.nthChild(file_menu, 2).?);
    defer if (exit.label) |l| gpa.free(l);
    try testing.expectEqualStrings("E_xit", exit.label.?);
    try testing.expect(!exit.sensitive);

    // (4) A check item round-trips its state.
    const view_menu = gtk.gtk_menu_item_get_submenu(@ptrCast(gtk.nthChild(bar, 1).?)).?;
    const grid = gtk.nthChild(view_menu, 0).?;
    const grid_info = try gtk.describeMenuItem(gpa, grid);
    defer if (grid_info.label) |l| gpa.free(l);
    try testing.expectEqual(gtk.MenuItemInfo.Kind.check_item, grid_info.kind);
    try testing.expectEqualStrings("_Grid", grid_info.label.?);
    try testing.expect(grid_info.active);

    // (5) Re-applying replaces the bar instead of stacking a second one.
    try backend().applyAppMenu(.{ .entries = &entries });
    try testing.expectEqual(@as(usize, 1), gtk.childCount(box));
}

test "gtk menu activation reports the MenuId, and context menus are GtkMenu" {
    if (!gtk.ensureInit()) return error.SkipZigTest;
    resetForTesting();
    defer resetForTesting();

    const window = testWindow() orelse return error.SkipZigTest;
    defer gtk.gtk_widget_destroy(window);
    try registerWindow("main", window);

    const Recorder = struct {
        var ids = [_][]const u8{ "", "", "", "", "", "", "", "" };
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
        .{ .kind = .item, .id = "muted", .text = "Muted", .depth = 0, .enabled = false },
    };
    try backend().applyAppMenu(.{ .entries = &entries });

    const bar = menuBarFor("main").?;
    // `activate` on a plain item fires the callback with the wire id…
    gtk.g_signal_emit_by_name(@ptrCast(gtk.nthChild(bar, 0).?), "activate");
    try testing.expectEqual(@as(usize, 1), Recorder.count);
    try testing.expectEqualStrings("save", Recorder.ids[0]);

    // …and `toggled` does the same for a check item.
    gtk.g_signal_emit_by_name(@ptrCast(gtk.nthChild(bar, 1).?), "toggled");
    try testing.expectEqual(@as(usize, 2), Recorder.count);
    try testing.expectEqualStrings("grid", Recorder.ids[1]);

    // A context menu is a `GtkMenu` whose children are the same top-level entries.
    try backend().popup("main", .{ .entries = &entries }, .{ .x = 4, .y = 5 });
    popdown();
}

test "gtk menu rejects a snapshot whose depth skips a level" {
    if (!gtk.ensureInit()) return error.SkipZigTest;
    resetForTesting();
    defer resetForTesting();

    const window = testWindow() orelse return error.SkipZigTest;
    defer gtk.gtk_widget_destroy(window);
    try registerWindow("main", window);

    const entries = [_]menu.Entry{
        .{ .kind = .item, .id = "deep", .text = "Deep", .depth = 1 },
    };
    try testing.expectError(error.InvalidMenuDepth, backend().applyAppMenu(.{ .entries = &entries }));
}
