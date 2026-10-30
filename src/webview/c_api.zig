//! Standalone C ABI Implementation matching `include/zts_webview.h` (`src/webview/c_api.zig`).
//!
//! Exports flat C functions (`zts_webview_*`) with zero Zig-specific types in signatures,
//! enabling direct linking from C/C++, Rust, SDL3/GLFW engines, or dynamic FFI hosts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const root = @import("mod.zig");
const types = @import("types.zig");

/// Status code returned by every fallible `zts_webview_*` function. Non-zero is a failure and the
/// out-parameter (if any) is left untouched.
pub const ZTS_WEBVIEW_OK: i32 = 0;
/// A pointer/handle argument was null, or a length or enum value was out of range.
pub const ZTS_WEBVIEW_ERR_INVALID_ARG: i32 = -1;
/// An allocation for a request body, a C string copy or a capture buffer failed.
pub const ZTS_WEBVIEW_ERR_OUT_OF_MEMORY: i32 = -2;
/// The requested mode is not compiled into this build (e.g. `.native` on a `-Dgtk=false` host) or the
/// feature does not exist on this OS.
pub const ZTS_WEBVIEW_ERR_UNSUPPORTED: i32 = -3;
/// The `window_id` was never created, or was already closed (handles are generational, so a stale id
/// never resolves to a recycled window).
pub const ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND: i32 = -4;
/// The pending request was cancelled before the host answered it — typically because the window
/// closed while the page was waiting.
pub const ZTS_WEBVIEW_ERR_REQUEST_CANCELED: i32 = -5;
/// No display/desktop session (headless CI without `$DISPLAY`, SSH without X forwarding). The
/// headless mock backend is the way to run in that situation.
pub const ZTS_WEBVIEW_ERR_DISPLAY_UNAVAILABLE: i32 = -6;
/// The OS refused the operation: GTK/Win32 call failed, `NSWindow` could not be created, …
pub const ZTS_WEBVIEW_ERR_PLATFORM_FAILURE: i32 = -7;

/// One borrowed HTTP header: **not** NUL-terminated, use the explicit length. The bytes stay valid
/// only for the duration of the callback that received them.
pub const CHeader = extern struct {
    name: ?[*]const u8,
    name_len: usize,
    value: ?[*]const u8,
    value_len: usize,
};

/// A custom-scheme request as seen from C. Every slice is borrowed for the duration of
/// `CSchemeHandlerFn`; copy what you need before returning, then answer (possibly later, from another
/// thread) with `zts_webview_complete_request(request_id, …)`.
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

/// `zts_capture_t` — a finished PNG screenshot. `data` is owned by the caller once
/// `zts_webview_capture_take()` returns `ZTS_WEBVIEW_OK`; release it with
/// `zts_webview_capture_free()`. `data == NULL && len == 0` means "still rendering".
pub const CCapture = extern struct {
    data: ?[*]u8 = null,
    len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// Called on the backend's main thread for every `tauri://` / `ipc://` / `asset://` request.
/// Answering is mandatory: a request that is never completed keeps the page's `fetch()` pending until
/// the window closes (`ZTS_WEBVIEW_ERR_REQUEST_CANCELED`).
pub const CSchemeHandlerFn = *const fn (
    userdata: ?*anyopaque,
    request: *const CSchemeRequestView,
) callconv(.c) void;

/// Called with the payload of `window.__zts.postMessage(…)`. `message` is borrowed and may contain
/// arbitrary bytes (including NUL), so always use `message_len`.
pub const CMessageHandlerFn = *const fn (
    userdata: ?*anyopaque,
    window_id: u64,
    message: [*]const u8,
    message_len: usize,
) callconv(.c) void;

/// Called after a window closed. `window_id` is already invalid at this point.
pub const CWindowCloseFn = *const fn (
    userdata: ?*anyopaque,
    window_id: u64,
) callconv(.c) void;

/// Destructor for bytes handed *to* the engine (request bodies). The engine calls it exactly once
/// after the response has been written, so a host can stream a file straight from its own buffer.
pub const CBytesReleaseFn = *const fn (
    release_ctx: ?*anyopaque,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) void;

/// Flat, POD mirror of `WindowConfig` for C hosts. Zero-initialise it and set only the fields you
/// care about — the defaults below are the same as `WindowConfig`'s, except that `title == null`
/// means "use `Z-Ts Window`".
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

/// Opaque engine box behind the `zts_webview_engine_*` functions. C callers only ever see `void *`;
/// the struct lives in Zig so the allocator, the IO reactor and the per-window bookkeeping all stay
/// in one place.
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

/// Creates an engine and writes it to `*out_engine`. `backend` is a `BackendKind` value
/// (`0 = auto`, `1 = headless_mock`, `2 = native`). Returns `ZTS_WEBVIEW_ERR_UNSUPPORTED` when the
/// requested backend was not compiled in and `ZTS_WEBVIEW_ERR_DISPLAY_UNAVAILABLE` when a native
/// backend cannot open a display.
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

/// Destroys the engine, closing every window it owns. Safe to call with `null`; the pointer must not
/// be used afterwards.
pub export fn zts_webview_engine_destroy(handle_opt: ?*CEngineHandle) callconv(.c) void {
    const h = handle_opt orelse return;
    const alloc = h.allocator;
    h.engine.deinit();
    for (h.scheme_thunks.items) |t| alloc.destroy(t);
    h.scheme_thunks.deinit(alloc);
    h.io_threaded.deinit();
    alloc.destroy(h);
}

/// Runs one iteration of the event loop. `mode_raw` is a `StepMode` value (`0 = blocking`,
/// `1 = poll`). Returns `true` while the loop should keep running, `false` once the last window has
/// closed or `zts_webview_request_quit()` was called.
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

/// Wakes a `step(blocking)` that is parked in another thread. Call it after a worker thread has
/// queued work (typically a completed scheme request) so the main loop notices immediately.
pub export fn zts_webview_wakeup(handle_opt: ?*CEngineHandle) callconv(.c) void {
    if (handle_opt) |h| h.engine.wakeup();
}

/// Asks the loop to exit: the next `zts_webview_step()` returns `false`. Windows are not closed by
/// this call, so handlers still see their close callbacks.
pub export fn zts_webview_request_quit(handle_opt: ?*CEngineHandle) callconv(.c) void {
    if (handle_opt) |h| h.engine.requestQuit();
}

/// Registers `cb` for a URL scheme (`"tauri"`, `"ipc"`, `"asset"`, …). The scheme string is copied.
/// `cb == null` unregisters it and makes every later request fail with 404.
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

/// Installs the `window.__zts.postMessage(…)` receiver. `cb == null` detaches it.
pub export fn zts_webview_set_message_handler(
    handle_opt: ?*CEngineHandle,
    cb: ?CMessageHandlerFn,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const h = handle_opt orelse return;
    h.msg_cb = cb;
    h.msg_ud = userdata;
}

/// Installs the window-closed notification. `cb == null` detaches it.
pub export fn zts_webview_set_close_handler(
    handle_opt: ?*CEngineHandle,
    cb: ?CWindowCloseFn,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const h = handle_opt orelse return;
    h.close_cb = cb;
    h.close_ud = userdata;
}

/// Answers a pending scheme request. `body` is borrowed until `release_fn` is called (pass
/// `null`/`0` for an empty body); the engine calls `release_fn(release_ctx, body, len)` exactly once
/// after the response is written, possibly on another thread.
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

/// Opens a window described by `desc` and writes its 53-bit id to `*out_win`. The id is
/// generational: a closed id never becomes valid again, so stale ids fail with
/// `ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND` instead of hitting an unrelated window.
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

/// Closes a window and frees everything it owns (pending requests are cancelled).
pub export fn zts_webview_window_close(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.closeWindow(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Returns the underlying `GtkWidget *` / `NSWindow *` / `HWND` so a C host can reparent or embed the
/// window. `null` for the headless mock and for ids that no longer exist.
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

/// Replaces the window title. `title` is copied; `null` resets it to the default.
pub export fn zts_webview_window_set_title(h_opt: ?*CEngineHandle, win: u64, title: ?[*:0]const u8) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const t = std.mem.span(title orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.setTitle(id, t) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Resizes the window to `width` x `height` **logical** pixels (the OS applies the DPI scale).
pub export fn zts_webview_window_set_size(h_opt: ?*CEngineHandle, win: u64, width: f64, height: f64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setSize(id, .wh(width, height)) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Enables (`enabled = true`) or clears the minimum size, in logical pixels.
pub export fn zts_webview_window_set_min_size(h_opt: ?*CEngineHandle, win: u64, enabled: bool, w: f64, ht: f64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setMinSize(id, if (enabled) .wh(w, ht) else null) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Enables (`enabled = true`) or clears the maximum size, in logical pixels.
pub export fn zts_webview_window_set_max_size(h_opt: ?*CEngineHandle, win: u64, enabled: bool, w: f64, ht: f64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setMaxSize(id, if (enabled) .wh(w, ht) else null) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Moves the window's top-left corner to `(x, y)`, in logical pixels relative to the screen.
pub export fn zts_webview_window_set_position(h_opt: ?*CEngineHandle, win: u64, x: f64, y: f64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setPosition(id, .xy(x, y)) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Toggles user resizing (the OS still honours programmatic `set_size`).
pub export fn zts_webview_window_set_resizable(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setResizable(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Minimises (iconifies) or restores the window.
pub export fn zts_webview_window_set_minimized(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setMinimized(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Maximises or restores the window.
pub export fn zts_webview_window_set_maximized(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setMaximized(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Enters or leaves fullscreen.
pub export fn zts_webview_window_set_fullscreen(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setFullscreen(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Shows or hides the window without destroying it.
pub export fn zts_webview_window_set_visible(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setVisible(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Adds or removes the native title bar and frame. Removing decorations is how a custom title bar is
/// built; pair it with `zts_webview_window_start_drag()`.
pub export fn zts_webview_window_set_decorations(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setDecorations(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Keeps the window above (or no longer above) all other windows.
pub export fn zts_webview_window_set_always_on_top(h_opt: ?*CEngineHandle, win: u64, v: bool) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setAlwaysOnTop(id, v) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Raises and focuses the window (and its WebView, so keystrokes reach the page).
pub export fn zts_webview_window_set_focus(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.setFocus(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Starts an OS window move from the current mouse position — call it from the `mousedown` handler
/// of a custom title bar in an undecorated window.
pub export fn zts_webview_window_start_drag(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.startDrag(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Registers JavaScript that runs at `DOCUMENT_START`, before any page script. `js` must be
/// NUL-terminated UTF-8 and is copied. Scripts are injected in registration order, per window.
pub export fn zts_webview_add_init_script(h_opt: ?*CEngineHandle, win: u64, js: ?[*:0]const u8) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const s = std.mem.span(js orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.addInitScript(id, s) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Evaluates `js` in the page's main world. Fire-and-forget: the return value is discarded, so use
/// a custom scheme or the message channel to get data back.
pub export fn zts_webview_eval_js(h_opt: ?*CEngineHandle, win: u64, js: ?[*:0]const u8) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const s = std.mem.span(js orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.evalJs(id, s) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Navigates to an absolute URL. The request goes through the registered scheme handlers, which is
/// why `tauri://localhost/index.html` never touches the network.
pub export fn zts_webview_navigate(h_opt: ?*CEngineHandle, win: u64, url: ?[*:0]const u8) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    const s = std.mem.span(url orelse return ZTS_WEBVIEW_ERR_INVALID_ARG);
    h.engine.navigate(id, s) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Loads an HTML string with `base_uri` as the document base (so relative assets resolve). Handy for
/// a splash screen or a unit test that does not want a file on disk.
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

/// Opens the WebView inspector. Only meaningful when devtools are enabled in the build
/// (`-Ddevtools`) and by the platform; returns `ZTS_WEBVIEW_ERR_UNSUPPORTED` otherwise.
pub export fn zts_webview_open_devtools(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.openDevtools(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

// --- 5. Screenshot capture (`M5-04`) ---------------------------------------
//
// Host loop shape:
//
//     zts_webview_window_capture(engine, win);        // queue
//     while (running) {
//         zts_webview_poll(engine);                   // drive the renderer
//         zts_capture_t shot = {0};
//         if (zts_webview_capture_take(engine, win, &shot) == ZTS_WEBVIEW_OK) {
//             write_png(shot.data, shot.len);         // 0 bytes => not ready yet
//             zts_webview_capture_free(engine, &shot);
//         }
//     }

/// Starts an asynchronous PNG capture of the window's visible viewport.
/// Returns `ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND` for an unknown window.
pub export fn zts_webview_window_capture(h_opt: ?*CEngineHandle, win: u64) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;
    h.engine.captureWindow(id) catch |err| return statusFromError(err);
    return ZTS_WEBVIEW_OK;
}

/// Moves a finished capture into `out`.
/// - `ZTS_WEBVIEW_OK` with `out.len > 0`: the caller now owns `out.data`.
/// - `ZTS_WEBVIEW_OK` with `out.len == 0`: still rendering, poll again.
/// - any error: the render failed (`ZTS_WEBVIEW_ERR_PLATFORM_FAILURE`) or the window is gone.
pub export fn zts_webview_capture_take(h_opt: ?*CEngineHandle, win: u64, out: ?*CCapture) callconv(.c) i32 {
    const h = h_opt orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    const slot = out orelse return ZTS_WEBVIEW_ERR_INVALID_ARG;
    slot.* = .{};
    const id = winFromU64(win) orelse return ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND;

    const maybe = h.engine.takeCapture(id) catch |err| return statusFromError(err);
    const capture = maybe orelse return ZTS_WEBVIEW_OK; // not ready yet

    // Ownership transfer: the bytes were allocated by this engine's allocator, so the pointer stays
    // valid until `zts_webview_capture_free()` hands it back. `capture` is deliberately *not*
    // deinitialised — C now owns the buffer.
    slot.data = capture.bytes.ptr;
    slot.len = capture.bytes.len;
    slot.width = capture.width;
    slot.height = capture.height;
    return ZTS_WEBVIEW_OK;
}

/// Releases a capture previously handed out by `zts_webview_capture_take()`.
/// Safe to call twice, and safe on a zero-initialised struct.
pub export fn zts_webview_capture_free(h_opt: ?*CEngineHandle, capture: ?*CCapture) callconv(.c) void {
    const h = h_opt orelse return;
    const c = capture orelse return;
    if (c.data) |ptr| {
        if (c.len > 0) h.allocator.free(ptr[0..c.len]);
    }
    c.* = .{};
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
