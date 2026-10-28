//! Fallback clipboard backend (headless / unsupported OS / disabled native build).

const std = @import("std");
const Allocator = std.mem.Allocator;

const clipboard = @import("mod.zig");

const Error = clipboard.ClipboardError;

fn readTextImpl(_: ?*anyopaque, _: Allocator) Error![]const u8 {
    return error.Unavailable;
}
fn writeTextImpl(_: ?*anyopaque, _: []const u8) Error!void {
    return error.Unavailable;
}
fn readHtmlImpl(_: ?*anyopaque, _: Allocator) Error![]const u8 {
    return error.Unavailable;
}
fn writeHtmlImpl(_: ?*anyopaque, _: []const u8, _: ?[]const u8) Error!void {
    return error.Unavailable;
}
fn clearImpl(_: ?*anyopaque) Error!void {
    return error.Unavailable;
}
fn writeSecretImpl(_: ?*anyopaque, _: []const u8) Error!void {
    return error.Unavailable;
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

test "stub clipboard backend always reports Unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Unavailable, backend().readText(arena.allocator()));
    try std.testing.expectError(error.Unavailable, backend().writeText("x"));
}
