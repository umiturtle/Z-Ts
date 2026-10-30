//! Core Types & Callbacks for `zts_webview` (`src/webview/types.zig`).
//!
//! Strictly depends ONLY on `zts_foundation` so `zts_webview` remains 100% independent of
//! `zts_rpc`, `zts_bridge`, `zts_tauri`, and `zts_core`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("zts_foundation");
const png = @import("png.zig");

pub const Handle = foundation.Handle;
pub const OwnedBytes = foundation.OwnedBytes;
pub const OutgoingResponse = foundation.OutgoingResponse;
pub const IpcStatus = foundation.IpcStatus;
pub const LogicalPoint = foundation.geometry.LogicalPoint;
pub const LogicalSize = foundation.geometry.LogicalSize;
pub const Color = foundation.geometry.Color;

/// Nominal 53-bit generational window identifier (`foundation.Handle(.window)` — exact same type as `zts_core.WindowId`!).
pub const WindowId = Handle(.window);

/// Nominal 53-bit generational pending scheme request identifier (`foundation.Handle(.ipc_request)`).
pub const RequestId = Handle(.ipc_request);

/// How long `step()` is allowed to block.
///
/// * `.blocking` — park the calling thread until at least one event (input, navigation, pending
///   scheme completion) arrives. Use it for a plain `while (running) try app.step(.blocking);`.
/// * `.poll` — return immediately, even when nothing happened. Use it when the main thread has
///   other work to do (a 60fps render loop, a game engine, an embedded host that owns the run loop).
pub const StepMode = enum(u32) {
    blocking = 0,
    poll = 1,
};

/// Which engine `Backend.init()` should build.
///
/// `.auto` picks a native backend when one was compiled in **and** the platform can actually open a
/// window (a GTK backend without `$DISPLAY` falls back), otherwise `HeadlessMock`. `.native` and
/// `.headless_mock` are for tests that must not silently change engine.
pub const BackendKind = enum(u32) {
    auto = 0,
    headless_mock = 1,
    native = 2,
};

pub const WebviewError = error{
    InvalidArgument,
    OutOfMemory,
    Unsupported,
    WindowNotFound,
    RequestCanceled,
    DisplayUnavailable,
    PlatformFailure,
};

/// One HTTP header of a scheme request or response. Names are ASCII, values are opaque bytes.
pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

/// Immutable view over an incoming custom URI scheme request (`tauri://`, `ipc://`, `asset://`, ...).
/// Lifetime of slice fields is valid for the duration of `SchemeHandler.call`; handlers that dispatch
/// asynchronously onto worker threads simply dupe the slices they need and complete later via `RequestId`.
pub const SchemeRequest = struct {
    /// Token to answer with (`completeRequest` / `zts_webview_complete_request`).
    request_id: RequestId,
    /// Window the request came from.
    window_id: WindowId,
    /// Scheme without `://` (`tauri`, `ipc`, `asset`).
    scheme: []const u8,
    /// HTTP method (`GET`, `POST`, …).
    method: []const u8,
    /// Full request URI, still percent-encoded.
    uri: []const u8,
    /// Request headers, borrowed for the duration of the handler call.
    headers: []const HeaderPair = &.{},
    /// Request body bytes (empty for `GET`).
    body: []const u8 = "",

    pub fn header(self: SchemeRequest, target_name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, target_name)) return h.value;
        }
        return null;
    }
};

/// Custom response envelope supporting full HTTP status, extra headers (e.g. `Content-Range`,
/// `Tauri-Response`), and zero-copy `OwnedBytes` payload completion.
pub const SchemeResponse = struct {
    /// HTTP status (`200`, `404`, …).
    status_code: u16 = 200,
    /// `Content-Type` header value.
    content_type: []const u8 = "application/octet-stream",
    extra_headers: []const HeaderPair = &.{},
    /// Response bytes; ownership transfers to the engine.
    body: OwnedBytes,

    pub fn fromOutgoing(out: OutgoingResponse) SchemeResponse {
        const status_hdr: HeaderPair = .{
            .name = "Tauri-Response",
            .value = if (out.status == .ok) "ok" else "error",
        };
        _ = status_hdr;
        return .{
            .status_code = out.http_code,
            .content_type = out.content_type,
            .extra_headers = if (out.status == .ok)
                &.{.{ .name = "Tauri-Response", .value = "ok" }}
            else
                &.{.{ .name = "Tauri-Response", .value = "error" }},
            .body = out.body,
        };
    }

    pub fn deinit(self: *SchemeResponse) void {
        self.body.deinit();
    }
};

/// Owned heap copy of `SchemeResponse` queued safely across worker -> main UI thread boundaries.
pub const QueuedCompletion = struct {
    request_id: RequestId,
    status_code: u16,
    content_type: []u8,
    extra_headers: []OwnedHeader,
    body: OwnedBytes,

    pub const OwnedHeader = struct {
        name: []u8,
        value: []u8,
    };

    pub fn cloneFrom(allocator: Allocator, request_id: RequestId, resp: SchemeResponse) Allocator.Error!QueuedCompletion {
        // Note: on OOM caller still owns `resp.body` until moved at the very end!
        const ct_copy = try allocator.dupe(u8, resp.content_type);
        errdefer allocator.free(ct_copy);

        const hdrs = try allocator.alloc(OwnedHeader, resp.extra_headers.len);
        var initialized: usize = 0;
        errdefer {
            for (hdrs[0..initialized]) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(hdrs);
        }

        for (resp.extra_headers, 0..) |src_h, idx| {
            const n = try allocator.dupe(u8, src_h.name);
            errdefer allocator.free(n);
            const v = try allocator.dupe(u8, src_h.value);
            hdrs[idx] = .{ .name = n, .value = v };
            initialized += 1;
        }

        return .{
            .request_id = request_id,
            .status_code = resp.status_code,
            .content_type = ct_copy,
            .extra_headers = hdrs,
            .body = resp.body,
        };
    }

    pub fn deinit(self: *QueuedCompletion, allocator: Allocator) void {
        allocator.free(self.content_type);
        for (self.extra_headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.extra_headers);
        self.body.deinit();
    }
};

/// Callback invoked (on the backend's main thread) for every `tauri://` / `ipc://` / `asset://` hit.
///
/// `onRequest` must either call `completeRequest()` before returning — synchronous handlers such as
/// `zts_bridge` do exactly that — or keep the `RequestId` and complete it from a worker thread;
/// the backend holds the request pending until then (`step()` keeps servicing the UI meanwhile).
pub const SchemeHandler = struct {
    userdata: ?*anyopaque = null,
    onRequest: *const fn (userdata: ?*anyopaque, req: SchemeRequest) void,

    pub inline fn call(self: SchemeHandler, req: SchemeRequest) void {
        self.onRequest(self.userdata, req);
    }
};

/// Receives `window.__zts.postMessage(...)` payloads from the page (`ipc://` channel).
///
/// `message` is borrowed for the duration of the call; dupe it if the handler hands it to a queue.
/// Returning is the only acknowledgement the page gets, so a handler that needs to reply should do
/// so through the same IPC channel rather than through the return path.
pub const MessageHandler = struct {
    userdata: ?*anyopaque = null,
    onMessage: *const fn (userdata: ?*anyopaque, window_id: WindowId, message: []const u8) void,

    pub inline fn call(self: MessageHandler, window_id: WindowId, message: []const u8) void {
        self.onMessage(self.userdata, window_id, message);
    }
};

/// Called after a window has been closed (user clicked the frame button, or the app called
/// `closeWindow()`). By the time it runs the `WindowId` is already invalid, so the handler is for
/// bookkeeping — dropping per-window state, decrementing a "quit when zero" counter — not for
/// cancelling the close.
pub const CloseHandler = struct {
    userdata: ?*anyopaque = null,
    onClose: *const fn (userdata: ?*anyopaque, window_id: WindowId) void,

    pub inline fn call(self: CloseHandler, window_id: WindowId) void {
        self.onClose(self.userdata, window_id);
    }
};

/// Image format requested from `captureWindow()`. All backends are required to support `.png`
/// (cairo, `NSBitmapImageRep`, WebView2 `CapturePreview` all encode it natively); the enum exists so
/// a future `.jpeg` can be added without changing the ABI.
pub const CaptureFormat = enum(u32) {
    /// PNG — the only format every backend can encode natively.
    png = 0,
};

/// A finished screen capture: PNG bytes plus the dimensions parsed back out of the IHDR chunk.
///
/// Ownership: `takeCapture()` moves the value to the caller, who must call `deinit()`. The backend
/// never frees bytes it has already handed out, and `closeWindow()` / `deinit()` free anything the
/// caller left behind (verified with `std.testing.allocator`).
pub const Capture = struct {
    /// PNG bytes. Freed by `deinit()`, never by the backend.
    bytes: []u8,
    /// Width parsed from the PNG's IHDR chunk.
    width: u32,
    /// Height parsed from the PNG's IHDR chunk.
    height: u32,
    /// Allocator that owns `bytes`.
    allocator: Allocator,

    /// Takes ownership of `bytes`; returns `error.PlatformFailure` (and frees them) when the buffer
    /// is not a readable PNG, so a broken encoder can never surface as a "0×0 screenshot".
    pub fn initOwned(allocator: Allocator, bytes: []u8) WebviewError!Capture {
        const size = png.parseSize(bytes) catch {
            allocator.free(bytes);
            return error.PlatformFailure;
        };
        return .{
            .bytes = bytes,
            .width = size.width,
            .height = size.height,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Capture) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Everything a window needs at creation time. Every field has a default, so
/// `.{}` is a valid (and common) configuration.
///
/// String fields are borrowed only until `createWindow()` returns; the backend copies what it keeps.
/// `size` / `min_size` / `position` are in **logical (CSS) pixels**, which is what a HiDPI screen
/// scales for you — the same numbers produce the same layout on every OS.
pub const WindowConfig = struct {
    title: []const u8 = "Z-Ts Window",
    size: LogicalSize = .wh(800, 600),
    /// Lower bound for user resizing.
    min_size: ?LogicalSize = null,
    /// Upper bound for user resizing.
    max_size: ?LogicalSize = null,
    /// Initial top-left corner; `null` lets the window manager place it.
    position: ?LogicalPoint = null,
    /// Whether the user may resize the window.
    resizable: bool = true,
    /// Draw the native title bar and frame.
    decorations: bool = true,
    /// Transparent background; needs a compositor.
    transparent: bool = false,
    /// Keep the window above others.
    always_on_top: bool = false,
    /// Map the window immediately; `false` creates it hidden.
    visible: bool = true,
    /// Start fullscreen.
    fullscreen: bool = false,
    /// Allow the WebView inspector for this window.
    devtools: bool = false,
    /// Painted before the first frame, so a dark theme does not flash white.
    background_color: ?Color = null,
    /// Optional native parent widget/view handle (`*GtkWidget` / `NSView*` / `HWND`) for embedding
    /// a WebView inside an existing game engine / broadcast dock window!
    parent_native_handle: ?*anyopaque = null,
    /// UserScripts injected at `DOCUMENT_START` before any page `<script>` executes.
    init_scripts: []const []const u8 = &.{},
    initial_url: ?[]const u8 = null,
    initial_html: ?[]const u8 = null,
};
