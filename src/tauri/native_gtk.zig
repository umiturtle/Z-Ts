//! Minimal Pure-Zig GTK3 / GDK3 bindings shared by the native dialog & clipboard backends.
//!
//! Only the symbols these two plugins need are declared (no `@cImport`, no `addTranslateC`):
//! the cold-start penalty of parsing `gtk/gtk.h` would be paid on every `zig build`.
//! Signatures were verified against GTK 3.24 (`gtk+-3.0`).

const std = @import("std");
const cstr = @import("native_cstr.zig");
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

// `M4-03`: menu / tray widgets.
pub const GtkMenuBar = opaque {};
pub const GtkMenu = opaque {};
pub const GtkMenuShell = opaque {};
pub const GtkMenuItem = opaque {};
pub const GtkCheckMenuItem = opaque {};
pub const GtkBox = opaque {};
pub const GtkContainer = opaque {};
pub const GtkAccelGroup = opaque {};
pub const GtkStatusIcon = opaque {};
pub const GtkBin = opaque {};

/// `GList` (the menu / container child list; same three-field layout as `GSList` plus `prev`).
pub const GList = extern struct {
    data: ?*anyopaque,
    next: ?*GList,
    prev: ?*GList,
};

/// `GTypeInstance` view of a widget, used to identify it (`G_OBJECT_TYPE` → `g_type_name`)
/// without the C type-check macros.
pub const GTypeInstance = extern struct {
    g_class: ?*GTypeClass,

    pub const GTypeClass = extern struct {
        g_type: usize,
    };

    /// The GType name (`"GtkBox"`, `"GtkMenuBar"`, …) or `null` for a non-GObject pointer.
    pub fn typeName(self: *const GTypeInstance) ?[*:0]const u8 {
        const class = self.g_class orelse return null;
        if (class.g_type == 0) return null;
        return g_type_name(class.g_type);
    }
};

pub const GdkRectangle = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
};

// GtkOrientation
pub const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
pub const GTK_ORIENTATION_VERTICAL: c_int = 1;

// GtkAccelFlags
pub const GTK_ACCEL_VISIBLE: guint = 1;

// GdkGravity
pub const GDK_GRAVITY_NORTH_WEST: c_int = 1;
pub const GDK_GRAVITY_SOUTH_WEST: c_int = 7;

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

// ------------------------------------------------------------------ menus (M4-03)

pub const GTK_WINDOW_TOPLEVEL: c_int = 0;

pub extern "c" fn gtk_window_new(window_type: c_int) *GtkWidget;
pub extern "c" fn gtk_box_new(orientation: c_int, spacing: gint) *GtkWidget;
pub extern "c" fn gtk_window_set_default_size(window: *GtkWindow, width: gint, height: gint) void;
pub extern "c" fn gtk_menu_bar_new() *GtkWidget;
pub extern "c" fn gtk_menu_new() *GtkWidget;
pub extern "c" fn gtk_menu_item_new() *GtkWidget;
pub extern "c" fn gtk_menu_item_new_with_mnemonic(label: [*:0]const u8) *GtkWidget;
pub extern "c" fn gtk_check_menu_item_new_with_mnemonic(label: [*:0]const u8) *GtkWidget;
pub extern "c" fn gtk_separator_menu_item_new() *GtkWidget;
pub extern "c" fn gtk_menu_item_set_submenu(item: *GtkMenuItem, submenu: *GtkWidget) void;
pub extern "c" fn gtk_menu_item_get_submenu(item: *GtkMenuItem) ?*GtkWidget;
pub extern "c" fn gtk_menu_item_get_label(item: *GtkMenuItem) ?[*:0]u8;
pub extern "c" fn gtk_menu_shell_append(shell: *GtkMenuShell, child: *GtkWidget) void;
pub extern "c" fn gtk_check_menu_item_get_active(item: *GtkCheckMenuItem) gboolean;
pub extern "c" fn gtk_check_menu_item_set_active(item: *GtkCheckMenuItem, active: gboolean) void;
pub extern "c" fn gtk_widget_set_sensitive(widget: *GtkWidget, sensitive: gboolean) void;
pub extern "c" fn gtk_widget_get_sensitive(widget: *GtkWidget) gboolean;
pub extern "c" fn gtk_widget_set_visible(widget: *GtkWidget, visible: gboolean) void;
pub extern "c" fn gtk_widget_show_all(widget: *GtkWidget) void;
pub extern "c" fn gtk_widget_get_parent(widget: *GtkWidget) ?*GtkWidget;
pub extern "c" fn gtk_bin_get_child(bin: *GtkBin) ?*GtkWidget;
pub extern "c" fn gtk_container_get_children(container: *GtkContainer) ?*GList;
pub extern "c" fn gtk_container_add(container: *GtkContainer, widget: *GtkWidget) void;
pub extern "c" fn gtk_box_pack_start(box: *GtkBox, child: *GtkWidget, expand: gboolean, fill: gboolean, padding: guint) void;
pub extern "c" fn gtk_box_reorder_child(box: *GtkBox, child: *GtkWidget, position: gint) void;
pub extern "c" fn gtk_accel_group_new() *GtkAccelGroup;
pub extern "c" fn gtk_window_add_accel_group(window: *GtkWindow, group: *GtkAccelGroup) void;
pub extern "c" fn gtk_accelerator_parse(accelerator: [*:0]const u8, key: ?*guint, mods: ?*c_int) gboolean;
pub extern "c" fn gtk_widget_add_accelerator(
    widget: *GtkWidget,
    accel_signal: [*:0]const u8,
    group: *GtkAccelGroup,
    key: guint,
    mods: c_int,
    flags: guint,
) void;
pub extern "c" fn gtk_menu_popup_at_pointer(menu: *GtkMenu, trigger_event: ?*anyopaque) void;
pub extern "c" fn gtk_menu_popup_at_rect(
    menu: *GtkMenu,
    rect_window: ?*anyopaque,
    rect: *const GdkRectangle,
    rect_anchor: c_int,
    menu_anchor: c_int,
    trigger_event: ?*anyopaque,
) void;
pub extern "c" fn gtk_menu_popdown(menu: *GtkMenu) void;
pub extern "c" fn gtk_container_remove(container: *GtkContainer, widget: *GtkWidget) void;
pub extern "c" fn gtk_widget_get_window(widget: *GtkWidget) ?*anyopaque;
pub extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: ?*const anyopaque,
    data: ?*anyopaque,
    destroy_data: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    connect_flags: c_int,
) c_ulong;
pub extern "c" fn g_object_ref(obj: *anyopaque) *anyopaque;
pub extern "c" fn g_signal_emit_by_name(instance: *anyopaque, detailed_signal: [*:0]const u8, ...) void;
pub extern "c" fn g_type_name(gtype: usize) [*:0]const u8;
pub extern "c" fn g_list_free(list: *GList) void;
pub extern "c" fn g_list_length(list: ?*GList) guint;
pub extern "c" fn g_object_unref(obj: ?*anyopaque) void;

// ------------------------------------------------------------------ tray (M4-03)

pub extern "c" fn gtk_status_icon_new_from_icon_name(name: [*:0]const u8) ?*GtkStatusIcon;
pub extern "c" fn gtk_status_icon_new_from_file(filename: [*:0]const u8) ?*GtkStatusIcon;
pub extern "c" fn gtk_status_icon_set_from_icon_name(icon: *GtkStatusIcon, name: [*:0]const u8) void;
pub extern "c" fn gtk_status_icon_set_from_file(icon: *GtkStatusIcon, filename: [*:0]const u8) void;
pub extern "c" fn gtk_status_icon_set_tooltip_text(icon: *GtkStatusIcon, text: [*:0]const u8) void;
pub extern "c" fn gtk_status_icon_set_title(icon: *GtkStatusIcon, title: [*:0]const u8) void;
pub extern "c" fn gtk_status_icon_set_visible(icon: *GtkStatusIcon, visible: gboolean) void;
pub extern "c" fn gtk_status_icon_get_visible(icon: *GtkStatusIcon) gboolean;

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
    return cstr.allocZ(allocator, s);
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

/// Layout of a GTK menu-item tree, as a test / host can inspect it. Mirrors the information a user
/// sees, so a native menu can be asserted from the GTK side without synthesising clicks.
pub const MenuItemInfo = struct {
    pub const Kind = enum { menu_bar, menu, item, check_item, separator, other };

    kind: Kind,
    label: ?[]const u8,
    sensitive: bool,
    active: bool,
    children: usize,
};

/// Identifies `widget` (`GtkMenuBar` / `GtkMenu` / `GtkMenuItem` / `GtkCheckMenuItem` / …).
pub fn widgetKind(widget: *GtkWidget) MenuItemInfo.Kind {
    const instance: *GTypeInstance = @ptrCast(@alignCast(widget));
    const name = instance.typeName() orelse return .other;
    const span = std.mem.span(name);
    if (std.mem.eql(u8, span, "GtkMenuBar")) return .menu_bar;
    if (std.mem.eql(u8, span, "GtkMenu")) return .menu;
    if (std.mem.eql(u8, span, "GtkCheckMenuItem")) return .check_item;
    if (std.mem.eql(u8, span, "GtkSeparatorMenuItem")) return .separator;
    if (std.mem.eql(u8, span, "GtkMenuItem")) return .item;
    return .other;
}

/// Reads back one menu node (label / sensitivity / check state / child count).
pub fn describeMenuItem(allocator: Allocator, widget: *GtkWidget) !MenuItemInfo {
    const kind = widgetKind(widget);
    var label: ?[]const u8 = null;
    if (kind == .item or kind == .check_item) {
        if (gtk_menu_item_get_label(@ptrCast(widget))) |raw| {
            // `gtk_menu_item_get_label` is **transfer none**: the string belongs to the widget, so
            // it is copied and must never be handed to `g_free` (that corrupts the heap).
            label = try allocator.dupe(u8, std.mem.span(raw));
        }
    }
    const list = gtk_container_get_children(@ptrCast(widget));
    defer if (list) |l| g_list_free(l);
    return .{
        .kind = kind,
        .label = label,
        .sensitive = gtk_widget_get_sensitive(widget) != 0,
        .active = kind == .check_item and gtk_check_menu_item_get_active(@ptrCast(widget)) != 0,
        .children = if (kind == .menu_bar or kind == .menu) g_list_length(list) else 0,
    };
}

/// N-th child of a `GtkMenuShell` / `GtkBox` (`g_list_nth_data` without the extra binding).
pub fn nthChild(container: *GtkWidget, n: usize) ?*GtkWidget {
    var list = gtk_container_get_children(@ptrCast(container));
    defer if (list) |l| g_list_free(l);
    var i: usize = 0;
    while (list) |node| : (i += 1) {
        if (i == n) return @ptrCast(@alignCast(node.data orelse return null));
        list = node.next;
    }
    return null;
}

/// Number of children of a container widget.
pub fn childCount(widget: *GtkWidget) usize {
    const list = gtk_container_get_children(@ptrCast(widget));
    defer if (list) |l| g_list_free(l);
    return g_list_length(list);
}
