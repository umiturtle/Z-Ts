//! macOS system-tray icons via AppKit (`NSStatusItem`), through the Flat C shim in
//! `native_macos_shim.m`.
//!
//! One `NSStatusItem` per tray id. The menu attached to a tray is built by the **menu** backend
//! (`menu/native_macos.zig` → `buildDetached`), so a tray menu click reaches the item's
//! `Channel<string>` through exactly the same activator as a menu-bar click — the tray never
//! re-implements that plumbing.
//!
//! Clicks arrive through `button.target` / `button.action` (`NSEventMaskLeftMouseUp |
//! NSEventMaskRightMouseUp`) and are forwarded into the tray's `Channel<TrayIconEvent>`; the shim
//! pops the attached menu up for right clicks (and for left clicks when
//! `menu_on_left_click`/`show_menu_on_left_click` is set).

const std = @import("std");
const Allocator = std.mem.Allocator;

const tray = @import("mod.zig");
const menu = @import("../menu/mod.zig");
const menu_macos = @import("../menu/native_macos.zig");
const cstr = @import("../native_cstr.zig");

const Error = tray.TrayError;

const gpa = std.heap.page_allocator;

/// `ZtsTrayEventFn` in the shim: `type` 0 = Click / 1 = DoubleClick, `button` 0 = left / 1 = right.
const EventFn = *const fn (ctx: ?*anyopaque, kind: c_int, button: c_int) callconv(.c) void;

extern "c" fn zts_tray_new(callback: EventFn, ctx: ?*anyopaque, menu_on_left_click: c_int) ?*anyopaque;
extern "c" fn zts_tray_free(raw: ?*anyopaque) void;
extern "c" fn zts_tray_set_menu_on_left_click(raw: ?*anyopaque, enabled: c_int) void;
extern "c" fn zts_tray_set_menu(raw: ?*anyopaque, ns_menu: ?*anyopaque) void;
extern "c" fn zts_tray_set_tooltip(raw: ?*anyopaque, tooltip: ?[*:0]const u8) void;
extern "c" fn zts_tray_set_title(raw: ?*anyopaque, title: ?[*:0]const u8) void;
extern "c" fn zts_tray_set_visible(raw: ?*anyopaque, visible: c_int) void;
extern "c" fn zts_tray_set_image_path(raw: ?*anyopaque, path: ?[*:0]const u8, as_template: c_int) void;
extern "c" fn zts_tray_set_image_bytes(raw: ?*anyopaque, data: ?*const anyopaque, len: usize, as_template: c_int) void;
extern "c" fn zts_tray_set_native_image(raw: ?*anyopaque, native_icon: c_int, as_template: c_int) void;

extern "c" fn zts_tray_is_visible(raw: ?*anyopaque) c_int;
extern "c" fn zts_tray_tooltip(raw: ?*anyopaque) ?[*:0]u8;
extern "c" fn zts_tray_title(raw: ?*anyopaque) ?[*:0]u8;
extern "c" fn zts_tray_symbol(raw: ?*anyopaque) ?[*:0]u8;
extern "c" fn zts_tray_has_image(raw: ?*anyopaque) c_int;
extern "c" fn zts_tray_is_template(raw: ?*anyopaque) c_int;
extern "c" fn zts_tray_menu_item_count(raw: ?*anyopaque) c_int;
extern "c" fn zts_tray_has_action(raw: ?*anyopaque) c_int;
extern "c" fn zts_tray_click(raw: ?*anyopaque) c_int;
extern "c" fn zts_native_free(ptr: ?*anyopaque) void;

const Entry = struct {
    id: []const u8, // owned
    handle: *anyopaque,
    /// Menu handle from `menu/native_macos.zig buildDetached` (freed with the tray).
    attached: ?*anyopaque = null,
    visible: bool = true,
    tooltip: ?[]const u8 = null, // owned
    title: ?[]const u8 = null, // owned
};

var trays: std.ArrayListUnmanaged(*Entry) = .empty;
var emitter: tray.Emitter = .{};

fn find(id: []const u8) ?*Entry {
    for (trays.items) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn onEvent(ctx: ?*anyopaque, kind: c_int, button: c_int) callconv(.c) void {
    const entry: *Entry = @ptrCast(@alignCast(ctx orelse return));
    const name = if (kind == 1) "DoubleClick" else "Click";
    const which = switch (button) {
        1 => "Right",
        2 => "Middle",
        else => "Left",
    };
    emitter.emit(emitter.ctx, .{
        .type = name,
        .id = entry.id,
        .button = which,
        .button_state = if (kind == 1) null else "Up",
    });
}

fn replaceOwned(slot: *?[]const u8, value: []const u8) Error!void {
    if (slot.*) |old| gpa.free(old);
    slot.* = gpa.dupe(u8, value) catch return error.OutOfMemory;
}

fn withZ(value: []const u8) Error![:0]u8 {
    return cstr.allocZ(gpa, value) catch error.OutOfMemory;
}

/// Applies the icon (`NativeIcon` / path / raw bytes). `resource` icons need the webview's
/// `plugin:resources` table and are skipped (the tray keeps whatever image it had).
fn applyIcon(entry: *Entry, icon: ?menu.Icon, as_template: bool) Error!void {
    const template: c_int = @intFromBool(as_template);
    const image = icon orelse {
        zts_tray_set_image_path(entry.handle, null, template);
        return;
    };
    switch (image) {
        .native => |native| zts_tray_set_native_image(entry.handle, @intCast(@backingInt(native)), template),
        .image => |js| switch (js) {
            .path => |path| {
                if (path.len == 0) {
                    zts_tray_set_image_path(entry.handle, null, template);
                    return;
                }
                const z = try withZ(path);
                defer gpa.free(z);
                zts_tray_set_image_path(entry.handle, z.ptr, template);
            },
            .bytes => |bytes| {
                if (bytes.len == 0) {
                    zts_tray_set_image_path(entry.handle, null, template);
                    return;
                }
                zts_tray_set_image_bytes(entry.handle, @ptrCast(bytes.ptr), bytes.len, template);
            },
            .resource => {},
        },
    }
}

fn apply(entry: *Entry, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    const as_template = options.icon_as_template orelse false;
    try applyIcon(entry, options.icon, as_template);

    if (options.tooltip) |tooltip| {
        try replaceOwned(&entry.tooltip, tooltip);
        const z = try withZ(tooltip);
        defer gpa.free(z);
        zts_tray_set_tooltip(entry.handle, z.ptr);
    }
    if (options.title) |title| {
        try replaceOwned(&entry.title, title);
        const z = try withZ(title);
        defer gpa.free(z);
        zts_tray_set_title(entry.handle, z.ptr);
    }

    const left_click_menu = options.show_menu_on_left_click orelse options.menu_on_left_click orelse false;
    zts_tray_set_menu_on_left_click(entry.handle, @intFromBool(left_click_menu));

    if (snapshot) |menu_snapshot| {
        const built = menu_macos.buildDetached(menu_snapshot) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unavailable => error.Unavailable,
            else => error.Failed,
        };
        if (entry.attached) |old| menu_macos.freeDetached(old);
        entry.attached = built;
        zts_tray_set_menu(entry.handle, menu_macos.nsMenuOf(built));
    }

    zts_tray_set_visible(entry.handle, @intFromBool(entry.visible));
}

fn create(_: ?*anyopaque, id: []const u8, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    if (find(id) != null) return update(null, id, options, snapshot);

    const owned = gpa.dupe(u8, id) catch return error.OutOfMemory;
    errdefer gpa.free(owned);
    const entry = gpa.create(Entry) catch return error.OutOfMemory;
    errdefer gpa.destroy(entry);
    entry.* = .{ .id = owned, .handle = undefined };

    const menu_on_left_click = options.show_menu_on_left_click orelse options.menu_on_left_click orelse false;
    entry.handle = zts_tray_new(onEvent, entry, @intFromBool(menu_on_left_click)) orelse return error.Unavailable;

    trays.append(gpa, entry) catch {
        zts_tray_free(entry.handle);
        return error.OutOfMemory;
    };
    try apply(entry, options, snapshot);
}

fn update(_: ?*anyopaque, id: []const u8, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    const entry = find(id) orelse return error.NotFound;
    try apply(entry, options, snapshot);
}

fn remove(_: ?*anyopaque, id: []const u8) Error!void {
    for (trays.items, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry.id, id)) continue;
        if (entry.attached) |handle| menu_macos.freeDetached(handle);
        zts_tray_free(entry.handle);
        gpa.free(entry.id);
        if (entry.tooltip) |t| gpa.free(t);
        if (entry.title) |t| gpa.free(t);
        gpa.destroy(entry);
        _ = trays.orderedRemove(i);
        return;
    }
}

fn setVisible(_: ?*anyopaque, id: []const u8, visible: bool) Error!void {
    const entry = find(id) orelse return error.NotFound;
    entry.visible = visible;
    zts_tray_set_visible(entry.handle, @intFromBool(visible));
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

// ============================================================================
// Introspection (tests, hosts)
// ============================================================================

pub fn statusItemFor(id: []const u8) ?*anyopaque {
    const entry = find(id) orelse return null;
    return entry.handle;
}

pub fn resetForTesting() void {
    for (trays.items) |entry| {
        if (entry.attached) |handle| menu_macos.freeDetached(handle);
        zts_tray_free(entry.handle);
        gpa.free(entry.id);
        if (entry.tooltip) |t| gpa.free(t);
        if (entry.title) |t| gpa.free(t);
        gpa.destroy(entry);
    }
    trays.clearRetainingCapacity();
    emitter = .{};
}

// ============================================================================
// Tests — real `NSStatusItem`s (macOS CI runs them; a headless session skips)
// ============================================================================

const testing = std.testing;

fn copyString(allocator: Allocator, raw: ?[*:0]u8) ![]u8 {
    const value = raw orelse return allocator.dupe(u8, "");
    defer zts_native_free(@ptrCast(value));
    return allocator.dupe(u8, std.mem.span(value));
}

test "cocoa tray applies tooltip / title / visibility and one status item per id" {
    resetForTesting();
    defer resetForTesting();

    const backend_ = backend();
    try backend_.create("main", .{ .id = "main", .tooltip = "Z-Ts", .title = "Z-Ts tray" }, null);
    try backend_.create("second", .{ .id = "second" }, null);

    const first = statusItemFor("main") orelse return error.NoStatusItem;
    const second = statusItemFor("second") orelse return error.NoStatusItem;
    try testing.expect(first != second);

    try testing.expectEqual(@as(c_int, 1), zts_tray_is_visible(first));
    try testing.expectEqual(@as(c_int, 1), zts_tray_has_action(first));

    const tooltip = try copyString(testing.allocator, zts_tray_tooltip(first));
    defer testing.allocator.free(tooltip);
    try testing.expectEqualStrings("Z-Ts", tooltip);

    const title = try copyString(testing.allocator, zts_tray_title(first));
    defer testing.allocator.free(title);
    try testing.expectEqualStrings("Z-Ts tray", title);

    try backend_.setVisible("main", false);
    try testing.expectEqual(@as(c_int, 0), zts_tray_is_visible(first));
    try testing.expectEqual(@as(c_int, 1), zts_tray_is_visible(second));

    try backend_.remove("main");
    try testing.expect(statusItemFor("main") == null);
    try testing.expect(statusItemFor("second") != null);
    try testing.expectError(error.NotFound, backend_.setVisible("nope", true));
}

test "cocoa tray reports clicks through the emitter and attaches its menu snapshot" {
    resetForTesting();
    defer resetForTesting();

    const Recorder = struct {
        var count: usize = 0;
        var last_id: []const u8 = "";
        var last_type: []const u8 = "";
        var last_button: []const u8 = "";
        fn record(_: ?*anyopaque, event: tray.TrayEvent) void {
            count += 1;
            last_id = event.id;
            last_type = event.type;
            last_button = event.button orelse "";
        }
    };
    Recorder.count = 0;
    const backend_ = backend();
    backend_.setEmitter(.{ .emit = Recorder.record });

    const entries = [_]menu.Entry{
        .{ .kind = .item, .id = "toggle", .text = "Toggle", .depth = 0 },
        .{ .kind = .item, .id = "quit", .text = "Quit", .depth = 0 },
    };
    try backend_.create("main", .{ .id = "main", .title = "Z-Ts" }, .{ .entries = &entries });
    const item = statusItemFor("main") orelse return error.NoStatusItem;

    // The menu was built and installed on the status item.
    try testing.expectEqual(@as(c_int, 2), zts_tray_menu_item_count(item));

    // A real `target`/`action` dispatch, exactly what a click does.
    try testing.expectEqual(@as(c_int, 1), zts_tray_click(item));
    try testing.expectEqual(@as(usize, 1), Recorder.count);
    try testing.expectEqualStrings("main", Recorder.last_id);
    try testing.expectEqualStrings("Click", Recorder.last_type);
    try testing.expectEqualStrings("Left", Recorder.last_button);

    std.debug.print("OK tray-cocoa checks=4 menu={d}\n", .{zts_tray_menu_item_count(item)});
}

test "cocoa tray icons: path, raw bytes and the native (SF Symbol) table" {
    resetForTesting();
    defer resetForTesting();

    const backend_ = backend();
    try backend_.create("main", .{ .id = "main", .title = "Z-Ts" }, null);
    const item = statusItemFor("main") orelse return error.NoStatusItem;

    // No icon yet: the status item is just the title text.
    try testing.expectEqual(@as(c_int, 0), zts_tray_has_image(item));

    // A stock icon maps to an SF Symbol (macOS 11+).
    try backend_.update("main", .{ .id = "main", .icon = .{ .native = .About } }, null);
    try testing.expectEqual(@as(c_int, 1), zts_tray_has_image(item));
    const symbol = try copyString(testing.allocator, zts_tray_symbol(item));
    defer testing.allocator.free(symbol);
    try testing.expectEqualStrings("info.circle", symbol);

    // `iconAsTemplate` round-trips onto `NSImage.template`.
    try backend_.update("main", .{ .id = "main", .icon = .{ .native = .Quit }, .icon_as_template = true }, null);
    try testing.expectEqual(@as(c_int, 1), zts_tray_is_template(item));

    // Raw bytes that are not an image must not crash and must not leave a bogus image behind.
    try backend_.update("main", .{ .id = "main", .icon = .{ .image = .{ .bytes = "not an image" } } }, null);
    try testing.expectEqual(@as(c_int, 0), zts_tray_has_image(item));
}
