//! Fallback dialog backend: no OS dialog is available in this build (headless CI without Xvfb,
//! unsupported OS, or `-Dgtk=false`). Every call reports `error.Unavailable`, which the command
//! layer surfaces as `{"code":"Unavailable"}` instead of crashing or pretending to work.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dialog = @import("mod.zig");

const Error = dialog.BackendError;

fn openImpl(_: ?*anyopaque, _: Allocator, _: dialog.OpenDialogOptions) Error!dialog.Selection {
    return error.Unavailable;
}

fn saveImpl(_: ?*anyopaque, _: Allocator, _: dialog.SaveDialogOptions) Error!dialog.Selection {
    return error.Unavailable;
}

fn messageImpl(_: ?*anyopaque, _: Allocator, _: dialog.MessageRequest) Error![]const u8 {
    return error.Unavailable;
}

const vtable = dialog.Backend.VTable{
    .open = openImpl,
    .save = saveImpl,
    .message = messageImpl,
};

pub fn backend() dialog.Backend {
    return .{ .vtable = &vtable };
}

test "stub dialog backend always reports Unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Unavailable, backend().open(arena.allocator(), .{}));
    try std.testing.expectError(error.Unavailable, backend().message(arena.allocator(), .{ .message = "x" }));
}
