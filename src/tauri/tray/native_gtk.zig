//! Linux system-tray icons via GTK3 `GtkStatusIcon`.
//!
//! `GtkStatusIcon` is deprecated (GTK4 removed it) but it is still shipped by every GTK 3.24
//! desktop and — unlike `libayatana-appindicator` — needs **no extra system dependency**, which
//! keeps `zig build -Dgtk=true` working on a bare runner. Upstream `tauri` uses
//! `libappindicator`; the wire layer above is identical either way, so swapping the widget later
//! does not touch the plugin.
//!
//! Each tray is one `GtkStatusIcon` plus a `GtkMenu` built from the tray's menu snapshot with the
//! same builder as the menu bar (`menu/native_gtk.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const tray = @import("mod.zig");
const menu = @import("../menu/mod.zig");
const gtk = @import("../native_gtk.zig");
const cstr = @import("../native_cstr.zig");
const menu_gtk = @import("../menu/native_gtk.zig");

const Error = tray.TrayError;
const gpa = std.heap.page_allocator;

const Entry = struct {
    id: []const u8, // owned
    icon: ?*gtk.GtkStatusIcon = null,
    menu: ?*gtk.GtkWidget = null,
    visible: bool = true,
    tooltip: ?[]const u8 = null, // owned
    title: ?[]const u8 = null, // owned
};

/// One heap allocation per tray, so the `*Entry` handed to GTK signal handlers stays valid when
/// the registry grows.
var icons: std.ArrayListUnmanaged(*Entry) = .empty;
var emitter: tray.Emitter = .{};

fn find(id: []const u8) ?*Entry {
    for (icons.items) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn onActivate(_: ?*gtk.GtkStatusIcon, user_data: ?*anyopaque) callconv(.c) void {
    const entry: *Entry = @ptrCast(@alignCast(user_data orelse return));
    emitter.emit(emitter.ctx, tray.TrayEvent.click(entry.id, 0, 0, "Left", "Up"));
}

fn onPopupMenu(icon: ?*gtk.GtkStatusIcon, button: gtk.guint, activate_time: gtk.guint, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = activate_time;
    const entry: *Entry = @ptrCast(@alignCast(user_data orelse return));
    // Report the click first (upstream sends `Click` for the right button too) …
    emitter.emit(emitter.ctx, tray.TrayEvent.click(entry.id, 0, 0, "Right", "Up"));
    // … then show the menu, if any.
    if (entry.menu) |popup_menu| {
        gtk.gtk_widget_show_all(popup_menu);
        gtk.gtk_menu_popup_at_pointer(@ptrCast(popup_menu), null);
    }
    _ = icon;
}

/// `Icon.native` → a freedesktop icon name; a `JsImage` path is used verbatim.
fn iconName(icon: menu.Icon) ?[]const u8 {
    return switch (icon) {
        .native => |native| switch (native) {
            .Add => "list-add",
            .Remove => "list-remove",
            .About => "help-about",
            .Services => "applications-system",
            .Separator => null,
            .Copy => "edit-copy",
            .Cut => "edit-cut",
            .Paste => "edit-paste",
            .SelectAll => "edit-select-all",
            .Undo => "edit-undo",
            .Redo => "edit-redo",
            .Minimize => "window-minimize",
            else => null,
        },
        .image => null,
    };
}

fn createIcon(options: tray.TrayIconOptions) Error!?*gtk.GtkStatusIcon {
    if (options.icon) |icon| {
        switch (icon) {
            .native => |native| {
                if (iconName(.{ .native = native })) |name| {
                    const z = cstr.allocZ(gpa, name) catch return error.OutOfMemory;
                    defer gpa.free(z);
                    if (gtk.gtk_status_icon_new_from_icon_name(z)) |status_icon| return status_icon;
                }
            },
            .image => |image| switch (image) {
                .path => |path| {
                    if (path.len == 0) return null;
                    const z = cstr.allocZ(gpa, path) catch return error.OutOfMemory;
                    defer gpa.free(z);
                    if (gtk.gtk_status_icon_new_from_file(z)) |status_icon| return status_icon;
                },
                // Raw bytes / `plugin:resources` icons need a PNG decode step that lives in
                // `zts_webview`; the tray falls back to the platform placeholder icon instead.
                .bytes, .resource => {},
            },
        }
    }
    const z = cstr.allocZ(gpa, "image-missing") catch return error.OutOfMemory;
    defer gpa.free(z);
    return gtk.gtk_status_icon_new_from_icon_name(z);
}

fn freeEntry(entry: *Entry) void {
    gpa.free(entry.id);
    if (entry.tooltip) |t| gpa.free(t);
    if (entry.title) |t| gpa.free(t);
}

fn buildMenu(snapshot: menu.Snapshot) Error!*gtk.GtkWidget {
    // The menu builder has its own (larger) error set; anything it rejects here is a defective
    // menu definition, which the tray surfaces as a generic backend failure.
    return menu_gtk.buildContextMenu(snapshot.entries) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unavailable => error.Unavailable,
        else => error.Failed,
    };
}

fn apply(entry: *Entry, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    const icon = entry.icon orelse (try createIcon(options)) orelse return error.Unavailable;
    entry.icon = icon;

    if (options.tooltip) |tooltip| {
        if (entry.tooltip) |old| gpa.free(old);
        entry.tooltip = gpa.dupe(u8, tooltip) catch return error.OutOfMemory;
        const z = cstr.allocZ(gpa, tooltip) catch return error.OutOfMemory;
        defer gpa.free(z);
        gtk.gtk_status_icon_set_tooltip_text(icon, z);
    }
    if (options.title) |title| {
        if (entry.title) |old| gpa.free(old);
        entry.title = gpa.dupe(u8, title) catch return error.OutOfMemory;
        const z = cstr.allocZ(gpa, title) catch return error.OutOfMemory;
        defer gpa.free(z);
        gtk.gtk_status_icon_set_title(icon, z);
    }
    if (snapshot) |menu_snapshot| {
        if (entry.menu) |old| gtk.gtk_widget_destroy(old);
        entry.menu = try buildMenu(menu_snapshot);
    }
    gtk.gtk_status_icon_set_visible(icon, @intFromBool(entry.visible));
}

fn create(_: ?*anyopaque, id: []const u8, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    if (find(id) != null) return update(null, id, options, snapshot);

    const owned = gpa.dupe(u8, id) catch return error.OutOfMemory;
    errdefer gpa.free(owned);
    const entry = gpa.create(Entry) catch return error.OutOfMemory;
    entry.* = .{ .id = owned };
    errdefer gpa.destroy(entry);
    icons.append(gpa, entry) catch return error.OutOfMemory;

    const icon = (try createIcon(options)) orelse return error.Unavailable;
    entry.icon = icon;
    _ = gtk.g_signal_connect_data(@ptrCast(icon), "activate", @ptrCast(&onActivate), @ptrCast(entry), null, 0);
    _ = gtk.g_signal_connect_data(@ptrCast(icon), "popup-menu", @ptrCast(&onPopupMenu), @ptrCast(entry), null, 0);
    try apply(entry, options, snapshot);
}

fn update(_: ?*anyopaque, id: []const u8, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    const entry = find(id) orelse return error.NotFound;
    try apply(entry, options, snapshot);
}

fn remove(_: ?*anyopaque, id: []const u8) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    for (icons.items, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry.id, id)) continue;
        if (entry.icon) |icon| gtk.g_object_unref(@ptrCast(icon));
        if (entry.menu) |popup_menu| gtk.gtk_widget_destroy(popup_menu);
        freeEntry(entry);
        gpa.destroy(entry);
        _ = icons.orderedRemove(i);
        return;
    }
}

fn setVisible(_: ?*anyopaque, id: []const u8, visible: bool) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    const entry = find(id) orelse return error.NotFound;
    entry.visible = visible;
    if (entry.icon) |icon| gtk.gtk_status_icon_set_visible(icon, @intFromBool(visible));
}

fn setEmitterImpl(_: ?*anyopaque, next: tray.Emitter) void {
    emitter = next;
}

const vtable = tray.Backend.VTable{
    .create = create,
    .update = update,
    .remove = remove,
    .set_visible = setVisible,
    .set_emitter = setEmitterImpl,
};

pub fn backend() tray.Backend {
    return .{ .vtable = &vtable };
}

/// Test helper: the live `GtkStatusIcon` for `id`.
pub fn statusIconFor(id: []const u8) ?*gtk.GtkStatusIcon {
    const entry = find(id) orelse return null;
    return entry.icon;
}

pub fn resetForTesting() void {
    menu_gtk.popdown();
    for (icons.items) |entry| {
        freeEntry(entry);
        gpa.destroy(entry);
    }
    icons.clearRetainingCapacity();
    emitter = .{};
}

// ============================================================================
// Tests (a real `GtkStatusIcon`; CI runs these under Xvfb)
// ============================================================================

const testing = std.testing;

test "gtk tray creates one status icon per id and applies tooltip / title / visibility" {
    if (!gtk.ensureInit()) return error.SkipZigTest;
    resetForTesting();
    defer resetForTesting();

    const backend_ = backend();
    const options = tray.TrayIconOptions{ .id = "main", .tooltip = "Z-Ts", .title = "Z-Ts tray" };
    try backend_.create("main", options, null);
    try backend_.create("second", .{ .id = "second" }, null);

    // Two icons, distinct handles (the `*Entry` handed to GTK survives the second insert).
    const first = statusIconFor("main") orelse return error.NoStatusIcon;
    const second = statusIconFor("second") orelse return error.NoStatusIcon;
    try testing.expect(first != second);
    try testing.expect(gtk.gtk_status_icon_get_visible(first) != 0);

    try backend_.setVisible("main", false);
    try testing.expectEqual(@as(gtk.gboolean, 0), gtk.gtk_status_icon_get_visible(first));
    try testing.expect(gtk.gtk_status_icon_get_visible(second) != 0);

    try backend_.remove("main");
    try testing.expect(statusIconFor("main") == null);
    try testing.expect(statusIconFor("second") != null);

    try testing.expectError(error.NotFound, backend_.setVisible("nope", true));
}

test "gtk tray reports clicks through the emitter and attaches the menu snapshot" {
    if (!gtk.ensureInit()) return error.SkipZigTest;
    resetForTesting();
    defer resetForTesting();

    const Recorder = struct {
        var count: usize = 0;
        var last_id: []const u8 = "";
        var last_type: []const u8 = "";
        fn record(_: ?*anyopaque, event: tray.TrayEvent) void {
            count += 1;
            last_id = event.id;
            last_type = event.type;
        }
    };
    Recorder.count = 0;
    const backend_ = backend();
    backend_.setEmitter(.{ .emit = Recorder.record });

    const entries = [_]menu.Entry{
        .{ .kind = .item, .id = "toggle", .text = "Toggle", .depth = 0 },
    };
    try backend_.create("main", .{ .id = "main", .title = "Z-Ts" }, .{ .entries = &entries });
    const icon = statusIconFor("main") orelse return error.NoStatusIcon;

    gtk.g_signal_emit_by_name(@ptrCast(icon), "activate");
    try testing.expectEqual(@as(usize, 1), Recorder.count);
    try testing.expectEqualStrings("main", Recorder.last_id);
    try testing.expectEqualStrings("Click", Recorder.last_type);
}
