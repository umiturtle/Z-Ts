//! Standalone C ABI Implementation matching `include/zts_webview.h` (`src/webview/c_api.zig`).
//!
//! Exports 26 flat C functions (`zts_webview_*`) with zero Zig-specific types in signatures,
//! enabling direct linking from C/C++, Rust, SDL3/GLFW engines, or dynamic FFI hosts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const root = @import("mod.zig");
const types = @import("types.zig");

pub const ZTS_WEBVIEW_OK: i32 = 0;
pub const ZTS_WEBVIEW_ERR_INVALID_ARG: i32 = -1;
pub const ZTS_WEBVIEW_ERR_OUT_OF_MEMORY: i32 = -2;
pub const ZTS_WEBVIEW_ERR_UNSUPPORTED: i32 = -3;
pub const ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND: i32 = -4;
pub const ZTS_WEBVIEW_ERR_REQUEST_CANCELED: i32 = -5;
pub const ZTS_WEBVIEW_ERR_DISPLAY_UNAVAILABLE: i32 = -6;
pub const ZTS_WEBVIEW_ERR_PLATFORM_FAILURE: i32 = -7;

pub const CHeader = extern struct {
    name: ?[*]const u8,
    name_len: usize,
    value: ?[*]const u8,
    value_len: usize,
};

pub const CSchemeRequestView = extern struct {
    request_id: u64,
    window_id: u64,
    scheme: [*]const u8,
    scheme_len: usize,
    method: [*]const u8,
    method_len: usize,
    uri: [*]const u8,
    uri_len: usize,
    body: [*]const u8,
    body_len: usize,
    headers: ?[*]const CHeader,
    headers_len: usize,
};

pub const CSchemeHandlerFn = *const fn (
    userdata: ?*anyopaque,
    request: *const CSchemeRequestView,
) callconv(.c) void;

pub const CMessageHandlerFn = *const fn (
    userdata: ?*anyopaque,
    window_id: u64,
    message: [*]const u8,
    message_len: usize,
) callconv(.c) void;

pub const CWindowCloseFn = *const fn (
    userdata: ?*anyopaque,
    window_id: u64,
) callconv(.c) void;

pub const CBytesReleaseFn = *const fn (
    release_ctx: ?*anyopaque,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) void;

pub const CWindowDesc = extern struct {
    title: ?[*:0]const u8 = null,
    width: f64 = 800.0,
    height: f64 = 600.0,
    resizable: bool = true,
    decorations: bool = true,
    transparent: bool = false,
    always_on_top: bool = false,
    visible: bool = true,
    fullscreen: bool = false,
    devtools: bool = false,
    has_background_color: bool = false,
    bg_r: u8 = 0,
    bg_g: u8 = 0,
    bg_b: u8 = 0,
    bg_a: u8 = 255,
    parent_native_handle: ?*anyopaque = null,
    initial_url: ?[*:0]const u8 = null,
    initial_html: ?[*:0]const u8 = null,
};

const CSchemeThunk = struct {
    allocator: Allocator,
    cb: CSchemeHandlerFn,
    userdata: ?*anyopaque,

    fn invoke(raw_ptr: ?*anyopaque, req: types.SchemeRequest) void {
        const self: *CSchemeThunk = @ptrCast(@alignCast(raw_ptr.?));
        var c_hdrs: std.ArrayList(CHeader) = .empty;
        defer c_hdrs.deinit(self.allocator);

        for (req.headers) |h| {
            c_hdrs.append(self.allocator, .{
                .name = h.name.ptr,
                .name_len = h.name.len,
                .value = h.value.ptr,
                .value_len = h.value.len,
            }) catch break;
        }

        const view: CSchemeRequestView = .{
            .request_id = req.request_id.toU53(),
            .window_id = req.window_id.toU53(),
            .scheme = req.scheme.ptr,
            .scheme_len = req.scheme.len,
            .method = req.method.ptr,
            .method_len = req.method.len,
            .uri = req.uri.ptr,
            .uri_len = req.uri.len,
            .body = req.body.ptr,
            .body_len = req.body.len,
            .headers = if (c_hdrs.items.len > 0) c_hdrs.items.ptr else null,
            .headers_len = c_hdrs.items.len,
        };
        self.cb(self.userdata, &view);
    }
};

fn invokeCReleaseCallback(bytes: []const u8, ctx_ptr: ?*anyopaque, ctx_meta: ?*const anyopaque) void {
    const cb: CBytesReleaseFn = @ptrCast(@alignCast(ctx_meta.?));
    cb(ctx_ptr, bytes.ptr, bytes.len);
}

pub const CEngineHandle = struct {
    allocator: Allocator,
    io_threaded: std.Io.Threaded,
    engine: root.Engine,
    msg_cb: ?CMessageHandlerFn = null,
    msg_ud: ?*anyopaque = null,
    close_cb: ?CWindowCloseFn = null,
    close_ud: ?*anyopaque = null,
    scheme_thunks: std.ArrayList(*CSchemeThunk) = .empty,

    fn forwardMsg(raw: ?*anyopaque, win_id: types.WindowId, message: []const u8) void {
        const self: *CEngineHandle = @ptrCast(@alignCast(raw.?));
        if (self.msg_cb) |cb| cb(self.msg_ud, win_id.toU53(), message.ptr, message.len);
    }

    fn forwardClose(raw: ?*anyopaque, win_id: types.WindowId) void {
        const self: *CEngineHandle = @ptrCast(@alignCast(raw.?));
        if (self.close_cb) |cb| cb(self.close_ud, win_id.toU53());
    }
};

fn statusFromError(err: types.WebviewError) i32 {
    return switch (err) {
        error.InvalidArgument => ZTS_WEBVIEW_ERR_INVALID_ARG,
        error.OutOfMemory => ZTS_WEBVIEW_ERR_OUT_OF_MEMORY,
        error.Unsupported => ZTS_WEBVIEW_ERR_UNSUPPORTED,
        error.WindowNotFound => ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND,
        error.RequestCanceled => ZTS_WEBVIEW_ERR_REQUEST_CANCELED,
        error.DisplayUnavailable => ZTS_WEBVIEW_ERR_DISPLAY_UNAVAILABLE,
        error.PlatformFailure => ZTS_WEBVIEW_ERR_PLATFORM_FAILURE,
    };
}

inline fn winFromU64(raw: u64) ?types.WindowId {
    const u53_val = std.math.cast(u53, raw) orelse return null;
    return types.WindowId.fromU53(u53_val) catch null;
}

inline fn reqFromU64(raw: u64) ?types.RequestId {
    const u53_val = std.math.cast(u53, raw) orelse return null;
    return types.RequestId.fromU53(u53_val) catch null;
}

pub export fn zts_webview_engine_create(backend: u32, out_engine: ?*?*CEngineHandle) callconv(.c) i32 {
    const out = out_engine orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const kind: types.BackendKind = switch (backend) {
        0 => .auto,
        1 => .headless_mock,
        2 => .native,
        else => return ZTS_WEBVIEW_ERR_INVALID_ARG,
    };

    const alloc = std.heap.smp_allocator;
    const box = alloc.create(CEngineHandle) catch return ZTS_WEBVIEW_ERR_OUT_OF_MEMORY;
    box.* = .{
        .allocator = alloc,
        .io_threaded = .init_single_threaded,
        .engine = undefined,
    };

    box.engine = root.Engine.init(alloc, box.io_threaded.io(), kind) catch |err| {
        box.io_threaded.deinit();
        alloc.destroy(box);
        return statusFromError(err);
    };

    box.engine.setMessageHandler(.{ .userdata = box, .onMessage = CEngineHandle.forwardMsg });
    box.engine.setCloseHandler(.{ .userdata = box, .onClose = CEngineHandle.forwardClose });
    out.* = box;
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_engine_destroy(handle_opt: ?*CEngineHandle) callconv(.c) void {
    const h = handle_opt orelse return;
    const alloc = h.allocator;
    h.engine.deinit();
    for (h.scheme_thunks.items) |t| alloc.destroy(t);
    h.scheme_thunks.deinit(alloc);
    h.io_threaded.deinit();
    alloc.destroy(h);
}

pub export fn zts_webview_step(handle_opt: ?*CEngineHandle, mode_raw: u32) callconv(.c) bool {
    const h = handle_opt orelse return false;
    const mode: types.StepMode = if (mode_raw == 0) .blocking else .poll;
    return h.engine.step(mode);
}

/// Host-loop convenience wrapper around `zts_webview_step(engine, ZTS_STEP_POLL)` (`M3-03`).
///
/// Embedding hosts (SDL3 / GLFW / GTK / Win32 `WM_TIMER` …) call this once per frame from *their*
/// own loop: it pumps one non-blocking engine iteration and returns `false` once the engine has
/// quit or its last window is gone.
pub export fn zts_webview_poll(handle_opt: ?*CEngineHandle) callconv(.c) bool {
    const h = handle_opt orelse return false;
    return h.engine.step(.poll);
}

pub export fn zts_webview_wakeup(handle_opt: ?*CEngineHandle) callconv(.c) void {
    if (handle_opt) |h| h.engine.wakeup();
}

pub export fn zts_webview_request_quit(handle_opt: ?*CEngineHandle) callconv(.c) void {
    if (handle_opt) |h| h.engine.requestQuit();
}

pub export fn zts_webview_register_scheme(
    handle_opt: ?*CEngineHandle,
    scheme_c: ?[*:0]const u8,
    cb_opt: ?CSchemeHandlerFn,
    userdata: ?*anyopaque,
) callconv(.c) i32 {
    const h = handle_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const scheme = std.mem.span(scheme_c orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    const cb = cb_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;

    const thunk = h.allocator.create(CSchemeThunk) catch return ZTS_WEBVIEW_ERR_OUT_OF_MEMORY;
    thunk.* = .{ .allocator = h.allocator, .cb = cb, .userdata = userdata };
    h.scheme_thunks.append(h.allocator, thunk) catch {
        h.allocator.destroy(thunk);
        return ZTS_WEBVIEW_ERR_OUT_OF_MEMORY;
    };

    h.engine.registerScheme(scheme, .{ .userdata = thunk, .onRequest = CSchemeThunk.invoke }) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_set_message_handler(
    handle_opt: ?*CEngineHandle,
    cb: ?CMessageHandlerFn,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const h = handle_opt orelse return;
    h.msg_cb = cb;
    h.msg_ud = userdata;
}

pub export fn zts_webview_set_close_handler(
    handle_opt: ?*CEngineHandle,
    cb: ?CWindowCloseFn,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const h = handle_opt orelse return;
    h.close_cb = cb;
    h.close_ud = userdata;
}

pub export fn zts_webview_complete_request(
    handle_opt: ?*CEngineHandle,
    request_id_raw: u64,
    status_code: u16,
    content_type_c: ?[*:0]const u8,
    extra_headers_ptr: ?[*]const CHeader,
    extra_headers_len: usize,
    body_ptr: ?[*]const u8,
    body_len: usize,
    release_fn_opt: ?CBytesReleaseFn,
    release_ctx: ?*anyopaque,
) callconv(.c) i32 {
    const h = handle_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const req_id = reqFromU64(request_id_raw) orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const ct = if (content_type_c) |p| std.mem.span(p) else "application/octet-stream";

    const raw_slice: []const u8 = if (body_len > 0 and body_ptr != null) body_ptr.?[0..body_len] else "";

    // Build `OwnedBytes`: either zero-heap inline C destructor callback OR copied internal slice!
    var owned_body: types.OwnedBytes = if (release_fn_opt) |rel_fn|
        types.OwnedBytes.initCustom(raw_slice, release_ctx, @ptrCast(rel_fn), invokeCReleaseCallback)
    else blk: {
        const duped = h.allocator.dupe(u8, raw_slice) catch return ZTS_WEBVIEW_ERR_OUT_OF_MEMORY;
        break :blk types.OwnedBytes.fromOwnedSlice(h.allocator, duped);
    };
    errdefer owned_body.deinit();

    var hdr_buf: std.ArrayList(types.HeaderPair) = .empty;
    defer hdr_buf.deinit(h.allocator);
    if (extra_headers_len > 0 and extra_headers_ptr != null) {
        for (extra_headers_ptr.?[0..extra_headers_len]) |ch| {
            if (ch.name != null and ch.value != null) {
                hdr_buf.append(h.allocator, .{
                    .name = ch.name.?[0..ch.name_len],
                    .value = ch.value.?[0..ch.value_len],
                }) catch return ZTS_WEBVIEW_ERR_OUT_OF_MEMORY;
            }
        }
    }

    h.engine.completeRequest(req_id, .{
        .status_code = status_code,
        .content_type = ct,
        .extra_headers = hdr_buf.items,
        .body = owned_body,
    }) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_create(
    handle_opt: ?*CEngineHandle,
    desc_ptr: ?*const CWindowDesc,
    out_win: ?*u64,
) callconv(.c) i32 {
    const h = handle_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const desc = desc_ptr orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const out = out_win orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;

    const win_id = h.engine.createWindow(.{
        .title = if (desc.title) |t| std.mem.span(t) else "Z-Ts Window",
        .size = .wh(desc.width, desc.height),
        .resizable = desc.resizable,
        .decorations = desc.decorations,
        .transparent = desc.transparent,
        .always_on_top = desc.always_on_top,
        .visible = desc.visible,
        .fullscreen = desc.fullscreen,
        .devtools = desc.devtools,
        .background_color = if (desc.has_background_color)
            .{ .r = desc.bg_r, .g = desc.bg_g, .b = desc.bg_b, .a = desc.bg_a }
        else
            null,
        .parent_native_handle = desc.parent_native_handle,
        .initial_url = if (desc.initial_url) |u| std.mem.span(u) else null,
        .initial_html = if (desc.initial_html) |ht| std.mem.span(ht) else null,
    }) catch |err| return statusFromError(err);

    out.* = win_id.toU53();
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_close(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.closeWindow(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_native_handle(h_opt: ?*CEngineHandle, win: u64) callconv(.c) ?*anyopaque {
    const h = h_opt orelse return null;
    const id = winFromU64(win) orelse return null;
    return h.engine.nativeHandle(id);
}

/// Resizes an **embedded** window to fill its host container's client area (`M3-03`).
/// Toplevel windows return `ZTS_WEBVIEW_ERR_UNSUPPORTED`.
pub export fn zts_webview_window_fit_parent(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.fitParent(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_title(h_opt: ?*CEngineHandle, win: u64, title: ?[*:0]const u8) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const t = std.mem.span(title orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.setTitle(id, t) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_size(h_opt: ?*CEngineHandle, win: u64, width: f64, height: f64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setSize(id, .wh(width, height)) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_min_size(h_opt: ?*CEngineHandle, win: u64, enabled: bool, w: f64, ht: f64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setMinSize(id, if (enabled) .wh(w, ht) else null) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_max_size(h_opt: ?*CEngineHandle, win: u64, enabled: bool, w: f64, ht: f64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setMaxSize(id, if (enabled) .wh(w, ht) else null) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_position(h_opt: ?*CEngineHandle, win: u64, x: f64, y: f64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setPosition(id, .xy(x, y)) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_resizable(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setResizable(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_minimized(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setMinimized(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_maximized(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setMaximized(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_fullscreen(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setFullscreen(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_visible(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setVisible(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_decorations(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setDecorations(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_always_on_top(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setAlwaysOnTop(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_set_focus(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setFocus(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_window_start_drag(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.startDrag(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_add_init_script(h_opt: ?*CEngineHandle, win: u64, js: ?[*:0]const u8) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const s = std.mem.span(js orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.addInitScript(id, s) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_eval_js(h_opt: ?*CEngineHandle, win: u64, js: ?[*:0]const u8) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const s = std.mem.span(js orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.evalJs(id, s) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_navigate(h_opt: ?*CEngineHandle, win: u64, url: ?[*:0]const u8) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const s = std.mem.span(url orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.navigate(id, s) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_load_html(
    h_opt: ?*CEngineHandle,
    win: u64,
    html: ?[*:0]const u8,
    base_uri: ?[*:0]const u8,
) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const s = std.mem.span(html orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.loadHtml(id, s, if (base_uri) |b| std.mem.span(b) else null) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

pub export fn zts_webview_open_devtools(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.openDevtools(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

test "C ABI (`zts_webview_*`) executes full engine, window, scheme & zero-copy destructor callback roundtrip" {
    var eng: ?*CEngineHandle = null;
    try testing.expectEqual(ZTS_WEBVIEW_OK, zts_webview_engine_create(1, &eng));
    defer zts_webview_engine_destroy(eng);

    const CState = struct {
        eng: *CEngineHandle,
        released_bytes: usize = 0,

        fn onRelease(ctx_ptr: ?*anyopaque, _: [*]const u8, len: usize) callconv(.c) void {
            const st: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            st.released_bytes += len;
        }

        fn onScheme(ud: ?*anyopaque, view: *const CSchemeRequestView) callconv(.c) void {
            const st: *@This() = @ptrCast(@alignCast(ud.?));
            const reply = "C-ABI-PONG";
            _ = zts_webview_complete_request(
                st.eng,
                view.request_id,
                200,
                "text/plain",
                null,
                0,
                reply.ptr,
                reply.len,
                onRelease,
                st,
            );
        }
    };

    var st: CState = .{ .eng = eng.? };
    try testing.expectEqual(ZTS_WEBVIEW_OK, zts_webview_register_scheme(eng, "asset", CState.onScheme, &st));

    var win_id: u64 = 0;
    const desc: CWindowDesc = .{ .title = "C Host Window", .width = 1024, .height = 768 };
    try testing.expectEqual(ZTS_WEBVIEW_OK, zts_webview_window_create(eng, &desc, &win_id));
    try testing.expect(win_id != 0);

    try testing.expectEqual(ZTS_WEBVIEW_OK, zts_webview_window_set_title(eng, win_id, "Renamed C Window"));
    try testing.expectEqual(ZTS_WEBVIEW_OK, zts_webview_eval_js(eng, win_id, "window.ok = 1;"));

    _ = try eng.?.engine.headless_mock.simulateSchemeRequest(
        try types.WindowId.fromU53(@intCast(win_id)),
        "GET",
        "asset://localhost/logo.bin",
        &.{},
        "",
    );
    try testing.expect(zts_webview_step(eng, 1));
    try testing.expectEqual(@as(usize, 10), st.released_bytes);

    zts_webview_request_quit(eng);
    try testing.expect(!zts_webview_step(eng, 0));
}
