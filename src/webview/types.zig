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

pub const StepMode = enum(u32) {
    blocking = 0,
    poll = 1,
};

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

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

/// Immutable view over an incoming custom URI scheme request (`tauri://`, `ipc://`, `asset://`, ...).
/// Lifetime of slice fields is valid for the duration of `SchemeHandler.call`; handlers that dispatch
/// asynchronously onto worker threads simply dupe the slices they need and complete later via `RequestId`.
pub const SchemeRequest = struct {
    request_id: RequestId,
    window_id: WindowId,
    scheme: []const u8,
    method: []const u8,
    uri: []const u8,
    headers: []const HeaderPair = &.{},
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
    status_code: u16 = 200,
    content_type: []const u8 = "application/octet-stream",
    extra_headers: []const HeaderPair = &.{},
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

pub const SchemeHandler = struct {
    userdata: ?*anyopaque = null,
    onRequest: *const fn (userdata: ?*anyopaque, req: SchemeRequest) void,

    pub inline fn call(self: SchemeHandler, req: SchemeRequest) void {
        self.onRequest(self.userdata, req);
    }
};

pub const MessageHandler = struct {
    userdata: ?*anyopaque = null,
    onMessage: *const fn (userdata: ?*anyopaque, window_id: WindowId, message: []const u8) void,

    pub inline fn call(self: MessageHandler, window_id: WindowId, message: []const u8) void {
        self.onMessage(self.userdata, window_id, message);
    }
};

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
    png = 0,
};

/// A finished screen capture: PNG bytes plus the dimensions parsed back out of the IHDR chunk.
///
/// Ownership: `takeCapture()` moves the value to the caller, who must call `deinit()`. The backend
/// never frees bytes it has already handed out, and `closeWindow()` / `deinit()` free anything the
/// caller left behind (verified with `std.testing.allocator`).
pub const Capture = struct {
    bytes: []u8,
    width: u32,
    height: u32,
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

pub const WindowConfig = struct {
    title: []const u8 = "Z-Ts Window",
    size: LogicalSize = .wh(800, 600),
    min_size: ?LogicalSize = null,
    max_size: ?LogicalSize = null,
    position: ?LogicalPoint = null,
    resizable: bool = true,
    decorations: bool = true,
    transparent: bool = false,
    always_on_top: bool = false,
    visible: bool = true,
    fullscreen: bool = false,
    devtools: bool = false,
    background_color: ?Color = null,
    /// Optional native parent widget/view handle (`*GtkWidget` / `NSView*` / `HWND`) for embedding
    /// a WebView inside an existing game engine / broadcast dock window!
    parent_native_handle: ?*anyopaque = null,
    /// UserScripts injected at `DOCUMENT_START` before any page `<script>` executes.
    init_scripts: []const []const u8 = &.{},
    initial_url: ?[]const u8 = null,
    initial_html: ?[]const u8 = null,
};
