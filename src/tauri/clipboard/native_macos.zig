//! macOS native clipboard (`NSPasteboard`) via the Flat C ABI shim.

const std = @import("std");
const cstr = @import("../native_cstr.zig");
const Allocator = std.mem.Allocator;

const clipboard = @import("mod.zig");

const Error = clipboard.ClipboardError;

extern "c" fn zts_native_free(ptr: ?*anyopaque) void;
extern "c" fn zts_native_clipboard_write_text(text: ?[*:0]const u8) c_int;
extern "c" fn zts_native_clipboard_read_text() ?[*:0]u8;
extern "c" fn zts_native_clipboard_write_html(html: ?[*:0]const u8, alt_text: ?[*:0]const u8) c_int;
extern "c" fn zts_native_clipboard_read_html() ?[*:0]u8;
extern "c" fn zts_native_clipboard_clear() void;
extern "c" fn zts_native_clipboard_write_secret(text: ?[*:0]const u8) c_int;

fn takeString(allocator: Allocator, raw: ?[*:0]u8) Error![]const u8 {
    const ptr = raw orelse return "";
    defer zts_native_free(@ptrCast(ptr));
    const slice = std.mem.span(ptr);
    if (slice.len == 0) return "";
    return allocator.dupe(u8, slice) catch error.OutOfMemory;
}

fn readTextImpl(_: ?*anyopaque, allocator: Allocator) Error![]const u8 {
    return takeString(allocator, zts_native_clipboard_read_text());
}

fn writeTextImpl(_: ?*anyopaque, text: []const u8) Error!void {
    const z = cstr.allocZ(std.heap.c_allocator, text) catch return error.OutOfMemory;
    defer std.heap.c_allocator.free(z);
    if (zts_native_clipboard_write_text(z.ptr) != 0) return error.Failed;
}

fn readHtmlImpl(_: ?*anyopaque, allocator: Allocator) Error![]const u8 {
    return takeString(allocator, zts_native_clipboard_read_html());
}

fn writeHtmlImpl(_: ?*anyopaque, html: []const u8, alt_text: ?[]const u8) Error!void {
    const alloc = std.heap.c_allocator;
    const html_z = cstr.allocZ(alloc, html) catch return error.OutOfMemory;
    defer alloc.free(html_z);
    const alt_z = if (alt_text) |alt| cstr.allocZ(alloc, alt) catch return error.OutOfMemory else null;
    defer if (alt_z) |z| alloc.free(z);

    if (zts_native_clipboard_write_html(html_z.ptr, if (alt_z) |z| z.ptr else null) != 0) return error.Failed;
}

fn clearImpl(_: ?*anyopaque) Error!void {
    zts_native_clipboard_clear();
}

fn writeSecretImpl(_: ?*anyopaque, text: []const u8) Error!void {
    const z = cstr.allocZ(std.heap.c_allocator, text) catch return error.OutOfMemory;
    defer std.heap.c_allocator.free(z);
    if (zts_native_clipboard_write_secret(z.ptr) != 0) return error.Failed;
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
    return .{ .vtable = &vtable };
}

test "macOS clipboard round-trips text through NSPasteboard" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    try backend().writeText("zts clipboard こんにちは");
    const text = try backend().readText(arena.allocator());
    try std.testing.expectEqualStrings("zts clipboard こんにちは", text);

    try backend().writeSecret("hunter2");
    const secret = try backend().readText(arena.allocator());
    try std.testing.expectEqualStrings("hunter2", secret);

    try backend().clear();
    const cleared = try backend().readText(arena.allocator());
    try std.testing.expectEqualStrings("", cleared);
}
