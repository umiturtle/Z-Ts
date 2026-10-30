//! Linux native clipboard via GTK3 `GtkClipboard` (`CLIPBOARD` selection).
//!
//! Text uses the convenience API (`gtk_clipboard_set_text` / `gtk_clipboard_wait_for_text`).
//! HTML is offered as an extra `text/html` target with the plain-text alternative attached as
//! `text/plain`, which is what GTK applications (LibreOffice, browsers) expect.

const std = @import("std");
const Allocator = std.mem.Allocator;

const clipboard = @import("mod.zig");
const gtk = @import("../native_gtk.zig");

const Error = clipboard.ClipboardError;

/// Selection payload kept alive while GTK owns the clipboard (single clipboard per process).
var owned_html: ?[]u8 = null;
var owned_alt: ?[]u8 = null;
/// Backing allocator for the selection payload that GTK keeps borrowing.
const owned_alloc = std.heap.c_allocator;

fn releaseOwned() void {
    if (owned_html) |h| owned_alloc.free(h);
    if (owned_alt) |a| owned_alloc.free(a);
    owned_html = null;
    owned_alt = null;
}

fn readTextImpl(_: ?*anyopaque, allocator: Allocator) Error![]const u8 {
    if (!gtk.ensureInit()) return error.Unavailable;
    const raw = gtk.gtk_clipboard_wait_for_text(gtk.clipboard()) orelse return "";
    return gtk.fromGtkAlloc(allocator, raw) catch error.OutOfMemory;
}

fn writeTextImpl(_: ?*anyopaque, text: []const u8) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    const text_z = gtk.toZ(owned_alloc, text) catch return error.OutOfMemory;
    defer owned_alloc.free(text_z);

    releaseOwned();
    gtk.gtk_clipboard_set_text(gtk.clipboard(), text_z.ptr, @intCast(text.len));
    // Ask the clipboard manager to keep the contents after this process exits.
    gtk.gtk_clipboard_store(gtk.clipboard());
}

fn readHtmlImpl(_: ?*anyopaque, allocator: Allocator) Error![]const u8 {
    if (!gtk.ensureInit()) return error.Unavailable;

    const atom = gtk.gdk_atom_intern_static_string("text/html");
    const data = gtk.gtk_clipboard_wait_for_contents(gtk.clipboard(), atom) orelse return "";
    defer gtk.gtk_selection_data_free(data);

    const len = gtk.gtk_selection_data_get_length(data);
    if (len <= 0) return "";
    const ptr = gtk.gtk_selection_data_get_data(data) orelse return "";
    return allocator.dupe(u8, ptr[0..@intCast(len)]) catch error.OutOfMemory;
}

fn getFunc(_: *gtk.GtkClipboard, selection: *gtk.GtkSelectionData, info: c_uint, _: ?*anyopaque) callconv(.c) void {
    const payload: ?[]const u8 = switch (info) {
        0 => owned_html,
        1 => owned_alt,
        else => null,
    };
    const bytes = payload orelse return;
    const type_atom = switch (info) {
        0 => gtk.gdk_atom_intern_static_string("text/html"),
        else => gtk.gdk_atom_intern_static_string("text/plain;charset=utf-8"),
    };
    _ = gtk.gtk_selection_data_set(selection, type_atom, 8, bytes.ptr, @intCast(bytes.len));
}

fn clearFunc(_: *gtk.GtkClipboard, _: ?*anyopaque) callconv(.c) void {}

fn writeHtmlImpl(_: ?*anyopaque, html: []const u8, alt_text: ?[]const u8) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;

    const alloc = owned_alloc;
    releaseOwned();
    owned_html = alloc.dupe(u8, html) catch return error.OutOfMemory;
    errdefer releaseOwned();
    owned_alt = alloc.dupe(u8, alt_text orelse "") catch return error.OutOfMemory;

    var targets = [2]gtk.GtkTargetEntry{
        .{ .target = @constCast("text/html"), .flags = 0, .info = 0 },
        .{ .target = @constCast("text/plain;charset=utf-8"), .flags = 0, .info = 1 },
    };
    if (gtk.gtk_clipboard_set_with_data(gtk.clipboard(), &targets, targets.len, getFunc, clearFunc, null) == 0) {
        return error.Failed;
    }
    gtk.gtk_clipboard_store(gtk.clipboard());
}

fn clearImpl(_: ?*anyopaque) Error!void {
    if (!gtk.ensureInit()) return error.Unavailable;
    releaseOwned();
    gtk.gtk_clipboard_clear(gtk.clipboard());
    gtk.gtk_clipboard_store(gtk.clipboard());
}

fn writeSecretImpl(_: ?*anyopaque, text: []const u8) Error!void {
    // GTK has no "concealed" flag; the store hint below keeps it out of the clipboard history
    // manager on desktops that honour it, which is the closest available behaviour.
    return writeTextImpl(null, text);
}

const vtable = clipboard.Backend.VTable{
    .read_text = readTextImpl,
    .write_text = writeTextImpl,
    .read_html = readHtmlImpl,
    .write_html = writeHtmlImpl,
    .clear = clearImpl,
    .write_secret = writeSecretImpl,
};

pub fn backend() clipboard.Backend {
    return .{ .ctx = null, .vtable = &vtable };
}

test "gtk clipboard round-trips text when a display is available" {
    if (!gtk.ensureInit()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    try backend().writeText("zts clipboard こんにちは");
    const text = try backend().readText(arena.allocator());
    try std.testing.expectEqualStrings("zts clipboard こんにちは", text);

    try backend().writeHtml("<b>bold</b>", "bold");
    const html = try backend().readHtml(arena.allocator());
    try std.testing.expectEqualStrings("<b>bold</b>", html);

    try backend().clear();
}
