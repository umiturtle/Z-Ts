//! Pure-Zig Zero-`@cImport` Bindings for GLib 2.0 / GIO / GDK 3 / GTK 3 / Soup 3 / WebKit2GTK 4.1.
//!
//! Verified 1-for-1 against `/usr/include/{glib-2.0,gtk-3.0,libsoup-3.0,webkitgtk-4.1}`:
//! - Eliminates multi-second `translate-c` overhead on cold-start builds (`<1.5s` full compile).
//! - Keeps C types completely private to `src/webview/linux.zig` so downstream callers never
//!   need GTK headers unless building the native Linux WebView backend.

pub const gboolean = c_int;
pub const gint = c_int;
pub const guint = c_uint;
pub const gint64 = i64;
pub const gssize = isize;
pub const gsize = usize;
pub const gdouble = f64;
pub const gchar = u8;
pub const gpointer = ?*anyopaque;
pub const gconstpointer = ?*const anyopaque;
pub const GType = usize;

pub const G_PRIORITY_HIGH: c_int = -100;
pub const G_PRIORITY_DEFAULT: c_int = 0;
pub const G_SOURCE_REMOVE: gboolean = 0;

// Opaque C handles
pub const GMainContext = opaque {};
pub const GCancellable = opaque {};
pub const GAsyncResult = opaque {};
pub const GInputStream = opaque {};
pub const GMemoryInputStream = opaque {};
pub const GBytes = opaque {};
pub const GdkScreen = opaque {};
pub const GdkVisual = opaque {};
pub const GdkWindow = opaque {};
pub const GtkWidget = opaque {};
pub const GtkContainer = opaque {};
pub const GtkWindow = opaque {};
pub const SoupMessageHeaders = opaque {};
pub const JSCValue = opaque {};
pub const WebKitWebContext = opaque {};
pub const WebKitSecurityManager = opaque {};
pub const WebKitUserContentManager = opaque {};
pub const WebKitUserScript = opaque {};
pub const WebKitJavascriptResult = opaque {};
pub const WebKitSettings = opaque {};
pub const WebKitWebInspector = opaque {};
pub const WebKitWebView = opaque {};
pub const WebKitURISchemeRequest = opaque {};
pub const WebKitURISchemeResponse = opaque {};

pub const GError = extern struct {
    domain: u32,
    code: gint,
    message: ?[*:0]const gchar,
};

pub const GdkRGBA = extern struct {
    red: gdouble,
    green: gdouble,
    blue: gdouble,
    alpha: gdouble,
};

pub const GdkGeometry = extern struct {
    min_width: gint = 0,
    min_height: gint = 0,
    max_width: gint = 0,
    max_height: gint = 0,
    base_width: gint = 0,
    base_height: gint = 0,
    width_inc: gint = 0,
    height_inc: gint = 0,
    min_aspect: gdouble = 0,
    max_aspect: gdouble = 0,
    win_gravity: c_int = 1, // GDK_GRAVITY_NORTH_WEST
};

pub const GDK_HINT_MIN_SIZE: c_uint = 1 << 1;
pub const GDK_HINT_MAX_SIZE: c_uint = 1 << 2;

pub const GTK_WINDOW_TOPLEVEL: c_int = 0;

pub const SOUP_MESSAGE_HEADERS_RESPONSE: c_int = 1;

pub const WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES: c_int = 0;
pub const WEBKIT_USER_CONTENT_INJECT_TOP_FRAME: c_int = 1;
pub const WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START: c_int = 0;
pub const WEBKIT_HARDWARE_ACCELERATION_POLICY_ON_DEMAND: c_int = 0;
pub const WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER: c_int = 2;

pub const GDestroyNotify = *const fn (data: gpointer) callconv(.c) void;
pub const GSourceFunc = *const fn (user_data: gpointer) callconv(.c) gboolean;
pub const GCallback = *const fn () callconv(.c) void;
pub const GClosureNotify = ?*const fn (data: gpointer, closure: gpointer) callconv(.c) void;
pub const GAsyncReadyCallback = ?*const fn (
    source_object: gpointer,
    res: *GAsyncResult,
    user_data: gpointer,
) callconv(.c) void;

pub const WebKitURISchemeRequestCallback = *const fn (
    request: *WebKitURISchemeRequest,
    user_data: gpointer,
) callconv(.c) void;

pub const SoupMessageHeadersForeachFunc = *const fn (
    name: [*:0]const gchar,
    value: [*:0]const gchar,
    user_data: gpointer,
) callconv(.c) void;

// --- GLib / GObject / GIO ---
pub extern "c" fn g_free(mem: gpointer) void;
pub extern "c" fn g_error_new_literal(domain: u32, code: gint, message: [*:0]const gchar) *GError;
pub extern "c" fn g_error_free(err: *GError) void;
pub extern "c" fn g_quark_from_static_string(str: [*:0]const gchar) u32;
pub extern "c" fn g_main_context_iteration(context: ?*GMainContext, may_block: gboolean) gboolean;
pub extern "c" fn g_idle_add_full(
    priority: gint,
    function: GSourceFunc,
    data: gpointer,
    notify: ?GDestroyNotify,
) guint;

pub extern "c" fn g_object_new(object_type: GType, first_property_name: [*:0]const gchar, ...) *anyopaque;
pub extern "c" fn g_object_ref(object: *anyopaque) *anyopaque;
pub extern "c" fn g_object_unref(object: *anyopaque) void;
pub extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const gchar,
    c_handler: GCallback,
    data: gpointer,
    destroy_data: GClosureNotify,
    connect_flags: c_uint,
) c_ulong;

pub extern "c" fn g_bytes_new_static(data: gconstpointer, size: gsize) *GBytes;
pub extern "c" fn g_bytes_new_with_free_func(
    data: gconstpointer,
    size: gsize,
    free_func: GDestroyNotify,
    user_data: gpointer,
) *GBytes;
pub extern "c" fn g_bytes_get_data(bytes: *GBytes, size: *gsize) ?[*]const u8;
pub extern "c" fn g_bytes_unref(bytes: *GBytes) void;

pub extern "c" fn g_memory_input_stream_new_from_bytes(bytes: *GBytes) *GInputStream;
pub extern "c" fn g_input_stream_read_bytes_async(
    stream: *GInputStream,
    count: gsize,
    io_priority: c_int,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: gpointer,
) void;
pub extern "c" fn g_input_stream_read_bytes_finish(
    stream: *GInputStream,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*GBytes;

// --- GDK 3 / GTK 3 ---
pub extern "c" fn gtk_init_check(argc: ?*c_int, argv: ?*anyopaque) gboolean;
pub extern "c" fn gtk_window_new(win_type: c_int) *GtkWidget;
pub extern "c" fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const gchar) void;
pub extern "c" fn gtk_window_set_default_size(window: *GtkWindow, width: gint, height: gint) void;
pub extern "c" fn gtk_window_resize(window: *GtkWindow, width: gint, height: gint) void;
pub extern "c" fn gtk_window_set_geometry_hints(
    window: *GtkWindow,
    geometry_widget: ?*GtkWidget,
    geometry: ?*const GdkGeometry,
    geom_mask: c_uint,
) void;
pub extern "c" fn gtk_window_move(window: *GtkWindow, x: gint, y: gint) void;
pub extern "c" fn gtk_window_set_resizable(window: *GtkWindow, resizable: gboolean) void;
pub extern "c" fn gtk_window_iconify(window: *GtkWindow) void;
pub extern "c" fn gtk_window_deiconify(window: *GtkWindow) void;
pub extern "c" fn gtk_window_maximize(window: *GtkWindow) void;
pub extern "c" fn gtk_window_unmaximize(window: *GtkWindow) void;
pub extern "c" fn gtk_window_fullscreen(window: *GtkWindow) void;
pub extern "c" fn gtk_window_unfullscreen(window: *GtkWindow) void;
pub extern "c" fn gtk_window_set_decorated(window: *GtkWindow, setting: gboolean) void;
pub extern "c" fn gtk_window_set_keep_above(window: *GtkWindow, setting: gboolean) void;
pub extern "c" fn gtk_window_present(window: *GtkWindow) void;
pub extern "c" fn gtk_window_begin_move_drag(
    window: *GtkWindow,
    button: gint,
    root_x: gint,
    root_y: gint,
    timestamp: u32,
) void;

pub extern "c" fn gtk_container_add(container: *GtkContainer, widget: *GtkWidget) void;
/// Overlay embedding (`M3-03`): a child added to a `GtkBox` only fills it when it expands, and
/// `gtk_widget_get_parent` is the structural proof that the WebView really lives in the host tree.
pub extern "c" fn gtk_box_new(orientation: c_int, spacing: gint) *GtkWidget;
pub extern "c" fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern "c" fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern "c" fn gtk_widget_get_parent(widget: *GtkWidget) ?*GtkWidget;
pub extern "c" fn gtk_widget_get_allocated_width(widget: *GtkWidget) gint;
pub extern "c" fn gtk_widget_get_allocated_height(widget: *GtkWidget) gint;
pub extern "c" fn gtk_widget_set_size_request(widget: *GtkWidget, width: gint, height: gint) void;
pub extern "c" fn gtk_widget_queue_resize(widget: *GtkWidget) void;
pub const GTK_ORIENTATION_VERTICAL: c_int = 1;
pub extern "c" fn gtk_widget_show_all(widget: *GtkWidget) void;
pub extern "c" fn gtk_widget_show(widget: *GtkWidget) void;
pub extern "c" fn gtk_widget_hide(widget: *GtkWidget) void;
pub extern "c" fn gtk_widget_destroy(widget: *GtkWidget) void;
pub extern "c" fn gtk_widget_set_app_paintable(widget: *GtkWidget, app_paintable: gboolean) void;
pub extern "c" fn gtk_widget_get_screen(widget: *GtkWidget) ?*GdkScreen;
pub extern "c" fn gtk_widget_set_visual(widget: *GtkWidget, visual: *GdkVisual) void;
pub extern "c" fn gdk_screen_get_rgba_visual(screen: *GdkScreen) ?*GdkVisual;

// --- LibSoup 3.0 ---
pub extern "c" fn soup_message_headers_new(hdr_type: c_int) *SoupMessageHeaders;
pub extern "c" fn soup_message_headers_unref(hdrs: *SoupMessageHeaders) void;
pub extern "c" fn soup_message_headers_append(
    hdrs: *SoupMessageHeaders,
    name: [*:0]const gchar,
    value: [*:0]const gchar,
) void;
pub extern "c" fn soup_message_headers_foreach(
    hdrs: *SoupMessageHeaders,
    func: SoupMessageHeadersForeachFunc,
    user_data: gpointer,
) void;

// --- JavaScriptCoreGTK 4.1 & WebKit2GTK 4.1 ---
pub extern "c" fn jsc_value_is_string(value: *JSCValue) gboolean;
pub extern "c" fn jsc_value_to_string(value: *JSCValue) ?[*:0]gchar;
pub extern "c" fn jsc_value_to_json(value: *JSCValue, indent: guint) ?[*:0]gchar;

pub extern "c" fn webkit_web_view_get_type() GType;
pub extern "c" fn webkit_web_context_new() *WebKitWebContext;
pub extern "c" fn webkit_web_context_get_security_manager(context: *WebKitWebContext) *WebKitSecurityManager;
pub extern "c" fn webkit_web_context_register_uri_scheme(
    context: *WebKitWebContext,
    scheme: [*:0]const gchar,
    callback: WebKitURISchemeRequestCallback,
    user_data: gpointer,
    user_data_destroy_func: ?GDestroyNotify,
) void;

pub extern "c" fn webkit_security_manager_register_uri_scheme_as_secure(
    security_manager: *WebKitSecurityManager,
    scheme: [*:0]const gchar,
) void;
pub extern "c" fn webkit_security_manager_register_uri_scheme_as_cors_enabled(
    security_manager: *WebKitSecurityManager,
    scheme: [*:0]const gchar,
) void;

pub extern "c" fn webkit_user_content_manager_new() *WebKitUserContentManager;
pub extern "c" fn webkit_user_content_manager_add_script(
    manager: *WebKitUserContentManager,
    script: *WebKitUserScript,
) void;
pub extern "c" fn webkit_user_content_manager_register_script_message_handler(
    manager: *WebKitUserContentManager,
    name: [*:0]const gchar,
) gboolean;

pub extern "c" fn webkit_user_script_new(
    source: [*:0]const gchar,
    injected_frames: c_int,
    injection_time: c_int,
    allow_list: ?*const ?[*:0]const gchar,
    block_list: ?*const ?[*:0]const gchar,
) *WebKitUserScript;
pub extern "c" fn webkit_user_script_unref(user_script: *WebKitUserScript) void;

pub extern "c" fn webkit_javascript_result_get_js_value(js_result: *WebKitJavascriptResult) *JSCValue;

pub extern "c" fn webkit_web_view_get_settings(web_view: *WebKitWebView) *WebKitSettings;
pub extern "c" fn webkit_web_view_set_background_color(web_view: *WebKitWebView, rgba: *const GdkRGBA) void;
pub extern "c" fn webkit_web_view_load_uri(web_view: *WebKitWebView, uri: [*:0]const gchar) void;
pub extern "c" fn webkit_web_view_load_html(
    web_view: *WebKitWebView,
    content: [*:0]const gchar,
    base_uri: ?[*:0]const gchar,
) void;
pub extern "c" fn webkit_web_view_evaluate_javascript(
    web_view: *WebKitWebView,
    script: [*]const u8,
    length: gssize,
    world_name: ?[*:0]const gchar,
    source_uri: ?[*:0]const gchar,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: gpointer,
) void;
pub extern "c" fn webkit_web_view_get_inspector(web_view: *WebKitWebView) *WebKitWebInspector;
pub extern "c" fn webkit_web_inspector_show(inspector: *WebKitWebInspector) void;

pub extern "c" fn webkit_settings_set_enable_developer_extras(settings: *WebKitSettings, enabled: gboolean) void;
pub extern "c" fn webkit_settings_set_hardware_acceleration_policy(settings: *WebKitSettings, policy: c_int) void;

pub extern "c" fn webkit_uri_scheme_request_get_scheme(request: *WebKitURISchemeRequest) [*:0]const gchar;
pub extern "c" fn webkit_uri_scheme_request_get_uri(request: *WebKitURISchemeRequest) [*:0]const gchar;
pub extern "c" fn webkit_uri_scheme_request_get_web_view(request: *WebKitURISchemeRequest) ?*WebKitWebView;
pub extern "c" fn webkit_uri_scheme_request_get_http_method(request: *WebKitURISchemeRequest) ?[*:0]const gchar;
pub extern "c" fn webkit_uri_scheme_request_get_http_headers(request: *WebKitURISchemeRequest) ?*SoupMessageHeaders;
pub extern "c" fn webkit_uri_scheme_request_get_http_body(request: *WebKitURISchemeRequest) ?*GInputStream;
pub extern "c" fn webkit_uri_scheme_request_finish_with_response(
    request: *WebKitURISchemeRequest,
    response: *WebKitURISchemeResponse,
) void;
pub extern "c" fn webkit_uri_scheme_request_finish_error(
    request: *WebKitURISchemeRequest,
    err: *GError,
) void;

pub extern "c" fn webkit_uri_scheme_response_new(
    input_stream: *GInputStream,
    stream_length: gint64,
) *WebKitURISchemeResponse;
pub extern "c" fn webkit_uri_scheme_response_set_status(
    response: *WebKitURISchemeResponse,
    status_code: guint,
    reason_phrase: ?[*:0]const gchar,
) void;
pub extern "c" fn webkit_uri_scheme_response_set_content_type(
    response: *WebKitURISchemeResponse,
    content_type: [*:0]const gchar,
) void;
pub extern "c" fn webkit_uri_scheme_response_set_http_headers(
    response: *WebKitURISchemeResponse,
    headers: *SoupMessageHeaders,
) void;

// --- Screenshot capture (`M5-04`): `WebKitWebView` snapshot + cairo PNG stream ---
//
// `webkit_web_view_get_snapshot()` renders the page offscreen (no X11 screen grab, so it works in
// Xvfb and never needs a compositor). The result is a `cairo_surface_t*` that we serialise with
// `cairo_surface_write_to_png_stream()`, keeping the whole path inside libcairo — no GDK pixbuf,
// no extra package, and identical bytes on every machine.
pub const cairo_surface_t = opaque {};
pub const cairo_status_t = c_int;
pub const CAIRO_STATUS_SUCCESS: cairo_status_t = 0;

/// `WebKitSnapshotRegion` (`WebKitWebView.h`) — visible viewport vs. the whole document.
pub const WebKitSnapshotRegion = c_int;
pub const WEBKIT_SNAPSHOT_REGION_VISIBLE: WebKitSnapshotRegion = 0;
pub const WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT: WebKitSnapshotRegion = 1;

/// `WebKitSnapshotOptions` bit flags.
pub const WebKitSnapshotOptions = c_uint;
pub const WEBKIT_SNAPSHOT_OPTIONS_NONE: WebKitSnapshotOptions = 0;
pub const WEBKIT_SNAPSHOT_OPTIONS_INCLUDE_SELECTION_HIGHLIGHTING: WebKitSnapshotOptions = 1 << 0;
pub const WEBKIT_SNAPSHOT_OPTIONS_TRANSPARENT_BACKGROUND: WebKitSnapshotOptions = 1 << 1;

/// `cairo_write_func_t`: append `length` bytes to the caller's buffer; return 0 (`SUCCESS`).
pub const CairoWriteFunc = *const fn (closure: ?*anyopaque, data: [*]const u8, length: c_uint) callconv(.c) cairo_status_t;

pub extern "c" fn webkit_web_view_get_snapshot(
    web_view: *WebKitWebView,
    region: WebKitSnapshotRegion,
    options: WebKitSnapshotOptions,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: gpointer,
) void;
pub extern "c" fn webkit_web_view_get_snapshot_finish(
    web_view: *WebKitWebView,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*cairo_surface_t;

pub extern "c" fn cairo_surface_write_to_png_stream(
    surface: *cairo_surface_t,
    write_func: CairoWriteFunc,
    closure: ?*anyopaque,
) cairo_status_t;
pub extern "c" fn cairo_surface_destroy(surface: *cairo_surface_t) void;
