//! Minimal Pure-Zig GTK3 / GDK3 bindings shared by the native dialog & clipboard backends.
//!
//! Only the symbols these two plugins need are declared (no `@cImport`, no `addTranslateC`):
//! the cold-start penalty of parsing `gtk/gtk.h` would be paid on every `zig build`.
//! Signatures were verified against GTK 3.24 (`gtk+-3.0`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const gboolean = c_int;
pub const gint = c_int;
pub const guint = c_uint;
pub const gchar = u8;
pub const gpointer = ?*anyopaque;
pub const GdkAtom = usize;

pub const GtkWidget = opaque {};
pub const GtkDialog = opaque {};
pub const GtkWindow = opaque {};
pub const GtkFileChooser = opaque {};
pub const GtkNativeDialog = opaque {};
pub const GtkFileFilter = opaque {};
pub const GtkClipboard = opaque {};
pub const GtkSelectionData = opaque {};
pub const GSList = opaque {};

pub const GtkTargetEntry = extern struct {
    target: [*:0]u8,
    flags: guint,
    info: guint,
};

// GtkMessageType
pub const GTK_MESSAGE_INFO: gint = 0;
pub const GTK_MESSAGE_WARNING: gint = 1;
pub const GTK_MESSAGE_QUESTION: gint = 2;
pub const GTK_MESSAGE_ERROR: gint = 3;

// GtkFileChooserAction
pub const GTK_FILE_CHOOSER_ACTION_OPEN: gint = 0;
pub const GTK_FILE_CHOOSER_ACTION_SAVE: gint = 1;
pub const GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER: gint = 2;

pub const GTK_BUTTONS_NONE: gint = 0;
pub const GTK_RESPONSE_ACCEPT: gint = -3;
pub const GTK_RESPONSE_DELETE_EVENT: gint = -4;

pub const GTK_DIALOG_MODAL: gint = 1;
pub const GDK_SELECTION_CLIPBOARD: [*:0]const u8 = "CLIPBOARD";

pub extern "c" fn gtk_init_check(argc: ?*c_int, argv: ?*?[*]?[*:0]u8) gboolean;

pub extern "c" fn gtk_widget_destroy(widget: *GtkWidget) void;
pub extern "c" fn gtk_message_dialog_new(parent: ?*GtkWindow, flags: gint, message_type: gint, buttons: gint, message_format: [*:0]const u8, ...) *GtkWidget;
pub extern "c" fn gtk_dialog_add_button(dialog: *GtkWidget, button_text: [*:0]const u8, response_id: gint) *GtkWidget;
pub extern "c" fn gtk_dialog_run(dialog: *GtkWidget) gint;
pub extern "c" fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;

pub extern "c" fn gtk_file_chooser_native_new(
    title: ?[*:0]const u8,
    parent: ?*GtkWindow,
    action: gint,
    accept_label: ?[*:0]const u8,
    cancel_label: ?[*:0]const u8,
) *GtkNativeDialog;
pub extern "c" fn gtk_native_dialog_run(dialog: *GtkNativeDialog) gint;
pub extern "c" fn gtk_native_dialog_destroy(dialog: *GtkNativeDialog) void;
pub extern "c" fn gtk_file_chooser_set_select_multiple(chooser: *GtkFileChooser, multiple: gboolean) void;
pub extern "c" fn gtk_file_chooser_set_current_folder(chooser: *GtkFileChooser, filename: [*:0]const u8) gboolean;
pub extern "c" fn gtk_file_chooser_set_current_name(chooser: *GtkFileChooser, name: [*:0]const u8) void;
pub extern "c" fn gtk_file_chooser_set_filename(chooser: *GtkFileChooser, filename: [*:0]const u8) gboolean;
pub extern "c" fn gtk_file_chooser_get_filename(chooser: *GtkFileChooser) ?[*:0]u8;
pub extern "c" fn gtk_file_chooser_get_filenames(chooser: *GtkFileChooser) ?*GSList;
pub extern "c" fn gtk_file_chooser_add_filter(chooser: *GtkFileChooser, filter: *GtkFileFilter) void;
pub extern "c" fn gtk_file_filter_new() *GtkFileFilter;
pub extern "c" fn gtk_file_filter_set_name(filter: *GtkFileFilter, name: [*:0]const u8) void;
pub extern "c" fn gtk_file_filter_add_pattern(filter: *GtkFileFilter, pattern: [*:0]const u8) void;
pub extern "c" fn g_slist_free_full(list: *GSList, free_func: *const fn (?*anyopaque) callconv(.c) void) void;
pub extern "c" fn g_free(mem: ?*anyopaque) void;

pub extern "c" fn gdk_atom_intern_static_string(name: [*:0]const u8) GdkAtom;
pub extern "c" fn gtk_clipboard_get(atom: GdkAtom) *GtkClipboard;
pub extern "c" fn gtk_clipboard_set_text(clipboard: *GtkClipboard, text: [*:0]const u8, len: gint) void;
pub extern "c" fn gtk_clipboard_wait_for_text(clipboard: *GtkClipboard) ?[*:0]u8;
pub extern "c" fn gtk_clipboard_clear(clipboard: *GtkClipboard) void;
pub extern "c" fn gtk_clipboard_wait_for_contents(clipboard: *GtkClipboard, target: GdkAtom) ?*GtkSelectionData;
pub extern "c" fn gtk_selection_data_get_data(data: *GtkSelectionData) ?[*]const u8;
pub extern "c" fn gtk_selection_data_get_length(data: *GtkSelectionData) gint;
pub extern "c" fn gtk_selection_data_set(
    data: *GtkSelectionData,
    type_: GdkAtom,
    format: gint,
    bytes: [*]const u8,
    length: gint,
) gboolean;
pub extern "c" fn gtk_selection_data_free(data: *GtkSelectionData) void;
pub extern "c" fn gtk_clipboard_set_with_data(
    clipboard: *GtkClipboard,
    targets: [*]const GtkTargetEntry,
    n_targets: guint,
    get_func: ?*const fn (*GtkClipboard, *GtkSelectionData, guint, ?*anyopaque) callconv(.c) void,
    clear_func: ?*const fn (*GtkClipboard, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) gboolean;
pub extern "c" fn gtk_clipboard_store(clipboard: *GtkClipboard) void;

var gtk_ready: ?bool = null;

/// Initializes GTK once. Returns `false` when there is no display (headless CI without Xvfb).
pub fn ensureInit() bool {
    if (gtk_ready) |ready| return ready;
    const ok = gtk_init_check(null, null) != 0;
    gtk_ready = ok;
    return ok;
}

/// Whether GTK can be used in this process (does not require a display check on every call).
pub fn isAvailable() bool {
    return ensureInit();
}

pub fn clipboard() *GtkClipboard {
    return gtk_clipboard_get(gdk_atom_intern_static_string(GDK_SELECTION_CLIPBOARD));
}

/// Converts a slice to a NUL-terminated buffer allocated from `allocator` (caller frees).
pub fn toZ(allocator: Allocator, s: []const u8) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf;
}

/// Copies an owned `gchar*` into `allocator` and releases it with `g_free`.
pub fn fromGtkAlloc(allocator: Allocator, ptr: [*:0]const u8) ![]u8 {
    const slice = std.mem.span(ptr);
    const out = try allocator.dupe(u8, slice);
    g_free(@constCast(ptr));
    return out;
}

test "gtk bindings compile without a display" {
    // `isAvailable()` must be safe to call anywhere (headless CI, unit tests): it never traps.
    const available = isAvailable();
    if (!available) return error.SkipZigTest;
    _ = clipboard();
}
