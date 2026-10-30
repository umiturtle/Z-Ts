//! Linux native dialogs via GTK3 `GtkFileChooserNative` / `GtkMessageDialog`.
//!
//! `GtkFileChooserNative` (not the deprecated `GtkFileChooserDialog`) lets the running desktop
//! substitute its own portal (xdg-desktop-portal) dialog while remaining testable under Xvfb.
//! Everything runs on the calling thread with `gtk_dialog_run*`, which is exactly how the host
//! event loop drives `plugin:dialog|open` (a blocking RPC call).

const std = @import("std");
const Allocator = std.mem.Allocator;

const dialog = @import("mod.zig");
const gtk = @import("../native_gtk.zig");
const path = @import("../path.zig");

const Error = dialog.BackendError;

fn mapResponse(response: c_int) bool {
    return response == gtk.GTK_RESPONSE_ACCEPT;
}

fn addFilters(chooser: *gtk.GtkFileChooser, filters: []const dialog.DialogFilter, allocator: Allocator) Error!void {
    for (filters) |filter| {
        const gtk_filter = gtk.gtk_file_filter_new();
        // The filter object is owned by the chooser once added (floating ref is consumed).
        const name_z = gtk.toZ(allocator, filter.name) catch return error.OutOfMemory;
        defer allocator.free(name_z);
        gtk.gtk_file_filter_set_name(gtk_filter, name_z.ptr);
        for (filter.extensions) |ext| {
            if (ext.len == 0) continue;
            var buf: std.Io.Writer.Allocating = .init(allocator);
            defer buf.deinit();
            buf.writer.print("*.{s}", .{ext}) catch return error.OutOfMemory;
            const pattern = gtk.toZ(allocator, buf.written()) catch return error.OutOfMemory;
            defer allocator.free(pattern);
            gtk.gtk_file_filter_add_pattern(gtk_filter, pattern.ptr);
        }
        gtk.gtk_file_chooser_add_filter(chooser, gtk_filter);
    }
}

fn setInitialPath(chooser: *gtk.GtkFileChooser, default_path: ?[]const u8, allocator: Allocator) Error!void {
    const raw = default_path orelse return;
    if (raw.len == 0) return;
    const z = gtk.toZ(allocator, raw) catch return error.OutOfMemory;
    defer allocator.free(z);

    // Upstream `set_default_path`: an existing directory becomes the folder, anything else is
    // split into "folder + file name" so the save dialog pre-fills the name.
    switch (path.PathStyle.current()) {
        .posix => {
            if (raw[raw.len - 1] == '/') {
                _ = gtk.gtk_file_chooser_set_current_folder(chooser, z.ptr);
                return;
            }
        },
        .windows => {
            const sep: u8 = if (raw[raw.len - 1] == '\\') '\\' else '/';
            if (raw[raw.len - 1] == sep) {
                _ = gtk.gtk_file_chooser_set_current_folder(chooser, z.ptr);
                return;
            }
        },
    }

    const dir = path.dirnameWithStyle(path.PathStyle.current(), raw);
    const base = path.basenameWithStyle(path.PathStyle.current(), raw, null);
    if (dir.len > 0) {
        const dir_z = gtk.toZ(allocator, dir) catch return error.OutOfMemory;
        defer allocator.free(dir_z);
        _ = gtk.gtk_file_chooser_set_current_folder(chooser, dir_z.ptr);
    }
    if (base.len > 0) {
        const base_z = gtk.toZ(allocator, base) catch return error.OutOfMemory;
        defer allocator.free(base_z);
        gtk.gtk_file_chooser_set_current_name(chooser, base_z.ptr);
    }
}

fn gFreeCb(mem: ?*anyopaque) callconv(.c) void {
    gtk.g_free(mem);
}

fn openImpl(_: ?*anyopaque, allocator: Allocator, options: dialog.OpenDialogOptions) Error!dialog.Selection {
    if (!gtk.ensureInit()) return error.Unavailable;

    const title_z = if (options.title) |t| gtk.toZ(allocator, t) catch return error.OutOfMemory else null;
    defer if (title_z) |z| allocator.free(z);

    const native = gtk.gtk_file_chooser_native_new(
        if (title_z) |z| z.ptr else null,
        null,
        if (options.directory) gtk.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER else gtk.GTK_FILE_CHOOSER_ACTION_OPEN,
        null,
        null,
    );
    defer gtk.gtk_native_dialog_destroy(native);

    const chooser: *gtk.GtkFileChooser = @ptrCast(native);
    if (options.multiple and !options.directory) {
        gtk.gtk_file_chooser_set_select_multiple(chooser, 1);
    }
    try setInitialPath(chooser, options.default_path, allocator);
    try addFilters(chooser, options.filters, allocator);

    if (!mapResponse(gtk.gtk_native_dialog_run(native))) return .{};

    if (options.multiple and !options.directory) {
        const list = gtk.gtk_file_chooser_get_filenames(chooser) orelse return .{};
        defer gtk.g_slist_free_full(list, gFreeCb);

        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |p| allocator.free(p);
            out.deinit(allocator);
        }
        var node: ?*gtk.GSList = list;
        while (node) |n| : (node = nextOf(n)) {
            const data = dataOf(n);
            if (data) |raw| {
                out.append(allocator, try gtk.fromGtkAlloc(allocator, @ptrCast(raw))) catch return error.OutOfMemory;
            }
        }
        return .{ .paths = out.items };
    }

    const raw = gtk.gtk_file_chooser_get_filename(chooser) orelse return .{};
    const one = gtk.fromGtkAlloc(allocator, raw) catch return error.OutOfMemory;
    errdefer allocator.free(one);
    const paths = allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
    paths[0] = one;
    return .{ .paths = paths };
}

fn saveImpl(_: ?*anyopaque, allocator: Allocator, options: dialog.SaveDialogOptions) Error!dialog.Selection {
    if (!gtk.ensureInit()) return error.Unavailable;

    const title_z = if (options.title) |t| gtk.toZ(allocator, t) catch return error.OutOfMemory else null;
    defer if (title_z) |z| allocator.free(z);

    const native = gtk.gtk_file_chooser_native_new(
        if (title_z) |z| z.ptr else null,
        null,
        gtk.GTK_FILE_CHOOSER_ACTION_SAVE,
        null,
        null,
    );
    defer gtk.gtk_native_dialog_destroy(native);

    const chooser: *gtk.GtkFileChooser = @ptrCast(native);
    try setInitialPath(chooser, options.default_path, allocator);
    try addFilters(chooser, options.filters, allocator);

    if (!mapResponse(gtk.gtk_native_dialog_run(native))) return .{};

    const raw = gtk.gtk_file_chooser_get_filename(chooser) orelse return .{};
    const one = gtk.fromGtkAlloc(allocator, raw) catch return error.OutOfMemory;
    errdefer allocator.free(one);
    const paths = allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
    paths[0] = one;
    return .{ .paths = paths };
}

fn messageImpl(_: ?*anyopaque, allocator: Allocator, request: dialog.MessageRequest) Error![]const u8 {
    if (!gtk.ensureInit()) return error.Unavailable;

    const message_type = switch (request.kind) {
        .info => gtk.GTK_MESSAGE_INFO,
        .warning => gtk.GTK_MESSAGE_WARNING,
        .@"error" => gtk.GTK_MESSAGE_ERROR,
    };
    const msg_z = gtk.toZ(allocator, request.message) catch return error.OutOfMemory;
    defer allocator.free(msg_z);

    // `"%s"` + argument: the message is data, never a format string.
    const widget = gtk.gtk_message_dialog_new(null, gtk.GTK_DIALOG_MODAL, message_type, gtk.GTK_BUTTONS_NONE, "%s", msg_z.ptr);
    defer gtk.gtk_widget_destroy(widget);

    if (request.title) |title| {
        const title_z = gtk.toZ(allocator, title) catch return error.OutOfMemory;
        defer allocator.free(title_z);
        gtk.gtk_window_set_title(@ptrCast(widget), title_z.ptr);
    }

    var labels_buf: [3]dialog.Button = undefined;
    const buttons = request.buttons.labels(&labels_buf);
    if (buttons.len == 0) return error.Failed;

    // Response ids are 1-based so `0`/`DELETE_EVENT` can mean "closed without choosing".
    for (buttons, 0..) |btn, i| {
        const label_z = gtk.toZ(allocator, btn.label) catch return error.OutOfMemory;
        defer allocator.free(label_z);
        _ = gtk.gtk_dialog_add_button(widget, label_z.ptr, @intCast(i + 1));
    }

    const response = gtk.gtk_dialog_run(widget);
    if (response <= 0 or @as(usize, @intCast(response)) > buttons.len) return "Cancel";
    return buttons[@intCast(response - 1)].id;
}

const vtable = dialog.Backend.VTable{
    .open = openImpl,
    .save = saveImpl,
    .message = messageImpl,
};

pub fn backend() dialog.Backend {
    return .{ .ctx = null, .vtable = &vtable };
}

// `GSList` is `{ data: gpointer, next: *GSList }`; the fields are opaque here, so read them
// through a local mirror instead of importing glib's layout.
const GSListMirror = extern struct {
    data: ?*anyopaque,
    next: ?*anyopaque,
};

fn dataOf(node: *gtk.GSList) ?*anyopaque {
    return @as(*const GSListMirror, @ptrCast(@alignCast(node))).data;
}

fn nextOf(node: *gtk.GSList) ?*gtk.GSList {
    const next = @as(*const GSListMirror, @ptrCast(@alignCast(node))).next;
    return if (next) |p| @ptrCast(@alignCast(p)) else null;
}

test "gtk dialog backend degrades to Unavailable without a display" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (gtk.ensureInit()) return error.SkipZigTest;

    try std.testing.expectError(error.Unavailable, backend().open(arena.allocator(), .{}));
    try std.testing.expectError(error.Unavailable, backend().save(arena.allocator(), .{}));
    try std.testing.expectError(
        error.Unavailable,
        backend().message(arena.allocator(), .{ .message = "hi" }),
    );
}
