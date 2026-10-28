//! macOS native dialogs (`NSOpenPanel` / `NSSavePanel` / `NSAlert`) via the Flat C ABI shim in
//! `../native_macos_shim.m`. The shim returns JSON so no AppKit object ever crosses the boundary.

const std = @import("std");
const cstr = @import("../native_cstr.zig");
const Allocator = std.mem.Allocator;

const dialog = @import("mod.zig");

const Error = dialog.BackendError;

extern "c" fn zts_native_free(ptr: ?*anyopaque) void;
extern "c" fn zts_native_dialog_run(
    mode: c_int,
    title: ?[*:0]const u8,
    default_path: ?[*:0]const u8,
    extensions: ?[*:0]const u8,
    multiple: c_int,
    can_create_directories: c_int,
) ?[*:0]u8;
extern "c" fn zts_native_dialog_message(
    title: ?[*:0]const u8,
    message: ?[*:0]const u8,
    kind: c_int,
    labels: ?[*:0]const u8,
) c_int;

const mode_open_file: c_int = 0;
const mode_open_folder: c_int = 1;
const mode_save: c_int = 2;

/// Joins every filter extension into one comma-separated list. macOS panels accept a single
/// `allowedContentTypes` array, so the filters are unioned instead of being offered as a dropdown.
fn extensionsCsv(allocator: Allocator, filters: []const dialog.DialogFilter) ![:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var first = true;
    for (filters) |f| {
        for (f.extensions) |ext| {
            if (ext.len == 0 or std.mem.eql(u8, ext, "*")) continue;
            if (!first) try aw.writer.writeByte(',');
            try aw.writer.writeAll(ext);
            first = false;
        }
    }
    return cstr.allocZ(allocator, aw.written());
}

fn parsePaths(allocator: Allocator, raw: [*:0]const u8) Error!dialog.Selection {
    defer zts_native_free(@ptrCast(@constCast(raw)));
    const json = std.mem.span(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.Failed;
    defer parsed.deinit();

    switch (parsed.value) {
        .null => return .{},
        .array => |items| {
            if (items.items.len == 0) return .{};
            const paths = allocator.alloc([]const u8, items.items.len) catch return error.OutOfMemory;
            var filled: usize = 0;
            errdefer {
                for (paths[0..filled]) |p| allocator.free(p);
                allocator.free(paths);
            }
            for (items.items) |item| {
                const p = switch (item) {
                    .string => |s| s,
                    else => return error.Failed,
                };
                paths[filled] = allocator.dupe(u8, p) catch return error.OutOfMemory;
                filled += 1;
            }
            return .{ .paths = paths };
        },
        else => return error.Failed,
    }
}

fn run(
    allocator: Allocator,
    mode: c_int,
    title: ?[]const u8,
    default_path: ?[]const u8,
    filters: []const dialog.DialogFilter,
    multiple: bool,
    can_create_directories: bool,
) Error!dialog.Selection {
    const title_z: ?[:0]u8 = if (title) |t| if (t.len > 0) cstr.allocZ(allocator, t) catch return error.OutOfMemory else null else null;
    defer if (title_z) |z| allocator.free(z);

    const path_z: ?[:0]u8 = if (default_path) |p| if (p.len > 0) cstr.allocZ(allocator, p) catch return error.OutOfMemory else null else null;
    defer if (path_z) |z| allocator.free(z);

    const ext_z: ?[:0]u8 = if (filters.len > 0) extensionsCsv(allocator, filters) catch return error.OutOfMemory else null;
    defer if (ext_z) |z| allocator.free(z);

    const raw = zts_native_dialog_run(
        mode,
        if (title_z) |z| z.ptr else null,
        if (path_z) |z| z.ptr else null,
        if (ext_z) |z| z.ptr else null,
        @intFromBool(multiple),
        @intFromBool(can_create_directories),
    ) orelse return error.Failed;

    return parsePaths(allocator, raw);
}

fn openImpl(_: ?*anyopaque, allocator: Allocator, options: dialog.OpenDialogOptions) Error!dialog.Selection {
    return run(
        allocator,
        if (options.directory) mode_open_folder else mode_open_file,
        options.title,
        options.default_path,
        options.filters,
        options.multiple,
        options.can_create_directories orelse true,
    );
}

fn saveImpl(_: ?*anyopaque, allocator: Allocator, options: dialog.SaveDialogOptions) Error!dialog.Selection {
    return run(
        allocator,
        mode_save,
        options.title,
        options.default_path,
        options.filters,
        false,
        options.can_create_directories orelse true,
    );
}

fn messageImpl(_: ?*anyopaque, allocator: Allocator, request: dialog.MessageRequest) Error![]const u8 {
    const title_z: ?[:0]u8 = if (request.title) |t| if (t.len > 0) cstr.allocZ(allocator, t) catch return error.OutOfMemory else null else null;
    defer if (title_z) |z| allocator.free(z);

    const msg_z = cstr.allocZ(allocator, request.message) catch return error.OutOfMemory;
    defer allocator.free(msg_z);

    var labels_buf: [3]dialog.Button = undefined;
    const buttons = request.buttons.labels(&labels_buf);
    if (buttons.len == 0) return error.Failed;

    // `NSAlert` takes the titles as separate strings; the shim splits on '\n'.
    var joined: std.Io.Writer.Allocating = .init(allocator);
    defer joined.deinit();
    for (buttons, 0..) |btn, i| {
        if (i > 0) joined.writer.writeByte('\n') catch return error.OutOfMemory;
        if (std.mem.indexOfScalar(u8, btn.label, '\n') != null) return error.Failed;
        joined.writer.writeAll(btn.label) catch return error.OutOfMemory;
    }
    const labels_z = cstr.allocZ(allocator, joined.written()) catch return error.OutOfMemory;
    defer allocator.free(labels_z);

    const kind: c_int = switch (request.kind) {
        .info => 0,
        .warning => 1,
        .@"error" => 2,
    };

    const chosen = zts_native_dialog_message(
        if (title_z) |z| z.ptr else null,
        msg_z.ptr,
        kind,
        labels_z.ptr,
    );
    if (chosen < 0 or @as(usize, @intCast(chosen)) >= buttons.len) return "Cancel";
    return buttons[@intCast(chosen)].id;
}

const vtable = dialog.Backend.VTable{
    .open = openImpl,
    .save = saveImpl,
    .message = messageImpl,
};

pub fn backend() dialog.Backend {
    return .{ .vtable = &vtable };
}

test "macOS dialog backend links against the AppKit shim" {
    // Constructing the backend must not touch AppKit (the first call does), so this test is safe
    // on a headless runner and proves the shim symbols resolve.
    const b = backend();
    try std.testing.expect(b.vtable.open == openImpl);
}
