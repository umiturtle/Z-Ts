//! Desktop `Host` VTable Adapter over `zts_webview.Engine` (`src/webview_host.zig`).
//!
//! Connects `zts_core.Host` (`WindowSpec`, `evalJs`, `navigate`, `completeRequest`, `requestQuit`,
//! window geometry/state operations) directly to a standalone `zts_webview.Engine` (`HeadlessMock`
//! or native `LinuxGtkBackend`) with zero allocation overhead on VTable dispatch.

const std = @import("std");
const testing = std.testing;

const core = @import("zts_core");
const webview = @import("zts_webview");

/// `zts_core.Host` implemented on a `zts_webview.Engine`: windows, IPC, eval and capture all go
/// through the WebView backend, so `zts_tauri` plugins run unchanged on top of it.
pub const WebviewHost = struct {
    engine: *webview.Engine,

    pub fn init(engine: *webview.Engine) WebviewHost {
        return .{ .engine = engine };
    }

    pub fn host(self: *WebviewHost) core.Host {
        return .{
            .userdata = self,
            .vtable = &vtable,
        };
    }

    fn mapErr(err: webview.WebviewError) core.HostError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unsupported => error.Unsupported,
            error.WindowNotFound => error.WindowNotFound,
            error.RequestCanceled => error.RequestCanceled,
            error.InvalidArgument, error.DisplayUnavailable, error.PlatformFailure => error.PlatformFailure,
        };
    }

    const vtable: core.Host.VTable = .{
        .wakeup = vWakeup,
        .requestQuit = vRequestQuit,
        .createWindow = vCreateWindow,
        .closeWindow = vCloseWindow,
        .setWindowTitle = vSetWindowTitle,
        .setWindowSize = vSetWindowSize,
        .setWindowMinSize = vSetWindowMinSize,
        .setWindowMaxSize = vSetWindowMaxSize,
        .setWindowPosition = vSetWindowPosition,
        .setWindowResizable = vSetWindowResizable,
        .setWindowMinimized = vSetWindowMinimized,
        .setWindowMaximized = vSetWindowMaximized,
        .setWindowFullscreen = vSetWindowFullscreen,
        .setWindowVisible = vSetWindowVisible,
        .setWindowDecorations = vSetWindowDecorations,
        .setWindowAlwaysOnTop = vSetWindowAlwaysOnTop,
        .setWindowFocus = vSetWindowFocus,
        .startWindowDrag = vStartWindowDrag,
        .evalJs = vEvalJs,
        .navigate = vNavigate,
        .openDevtools = vOpenDevtools,
        .completeRequest = vCompleteRequest,
    };

    inline fn cast(ptr: ?*anyopaque) *WebviewHost {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn vWakeup(ptr: ?*anyopaque) void {
        cast(ptr).engine.wakeup();
    }

    fn vRequestQuit(ptr: ?*anyopaque) void {
        cast(ptr).engine.requestQuit();
    }

    fn vCreateWindow(ptr: ?*anyopaque, spec: core.WindowSpec) core.HostError!core.WindowId {
        return cast(ptr).engine.createWindow(.{
            .title = spec.title,
            .size = spec.size,
            .min_size = spec.min_size,
            .max_size = spec.max_size,
            .position = spec.position,
            .resizable = spec.resizable,
            .decorations = spec.decorations,
            .transparent = spec.transparent,
            .always_on_top = spec.always_on_top,
            .visible = spec.visible,
            .fullscreen = spec.fullscreen,
            .devtools = spec.devtools,
            .background_color = spec.background_color,
            .initial_url = spec.initial_url,
        }) catch |e| mapErr(e);
    }

    fn vCloseWindow(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        cast(ptr).engine.closeWindow(win) catch |e| return mapErr(e);
    }

    fn vSetWindowTitle(ptr: ?*anyopaque, win: core.WindowId, title: []const u8) core.HostError!void {
        cast(ptr).engine.setTitle(win, title) catch |e| return mapErr(e);
    }

    fn vSetWindowSize(ptr: ?*anyopaque, win: core.WindowId, size: core.LogicalSize) core.HostError!void {
        cast(ptr).engine.setSize(win, size) catch |e| return mapErr(e);
    }

    fn vSetWindowMinSize(ptr: ?*anyopaque, win: core.WindowId, size: ?core.LogicalSize) core.HostError!void {
        cast(ptr).engine.setMinSize(win, size) catch |e| return mapErr(e);
    }

    fn vSetWindowMaxSize(ptr: ?*anyopaque, win: core.WindowId, size: ?core.LogicalSize) core.HostError!void {
        cast(ptr).engine.setMaxSize(win, size) catch |e| return mapErr(e);
    }

    fn vSetWindowPosition(ptr: ?*anyopaque, win: core.WindowId, pos: core.LogicalPoint) core.HostError!void {
        cast(ptr).engine.setPosition(win, pos) catch |e| return mapErr(e);
    }

    fn vSetWindowResizable(ptr: ?*anyopaque, win: core.WindowId, v: bool) core.HostError!void {
        cast(ptr).engine.setResizable(win, v) catch |e| return mapErr(e);
    }

    fn vSetWindowMinimized(ptr: ?*anyopaque, win: core.WindowId, v: bool) core.HostError!void {
        cast(ptr).engine.setMinimized(win, v) catch |e| return mapErr(e);
    }

    fn vSetWindowMaximized(ptr: ?*anyopaque, win: core.WindowId, v: bool) core.HostError!void {
        cast(ptr).engine.setMaximized(win, v) catch |e| return mapErr(e);
    }

    fn vSetWindowFullscreen(ptr: ?*anyopaque, win: core.WindowId, v: bool) core.HostError!void {
        cast(ptr).engine.setFullscreen(win, v) catch |e| return mapErr(e);
    }

    fn vSetWindowVisible(ptr: ?*anyopaque, win: core.WindowId, v: bool) core.HostError!void {
        cast(ptr).engine.setVisible(win, v) catch |e| return mapErr(e);
    }

    fn vSetWindowDecorations(ptr: ?*anyopaque, win: core.WindowId, v: bool) core.HostError!void {
        cast(ptr).engine.setDecorations(win, v) catch |e| return mapErr(e);
    }

    fn vSetWindowAlwaysOnTop(ptr: ?*anyopaque, win: core.WindowId, v: bool) core.HostError!void {
        cast(ptr).engine.setAlwaysOnTop(win, v) catch |e| return mapErr(e);
    }

    fn vSetWindowFocus(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        cast(ptr).engine.setFocus(win) catch |e| return mapErr(e);
    }

    fn vStartWindowDrag(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        cast(ptr).engine.startDrag(win) catch |e| return mapErr(e);
    }

    fn vEvalJs(ptr: ?*anyopaque, win: core.WindowId, script: []const u8) core.HostError!void {
        cast(ptr).engine.evalJs(win, script) catch |e| return mapErr(e);
    }

    fn vNavigate(ptr: ?*anyopaque, win: core.WindowId, url: []const u8) core.HostError!void {
        cast(ptr).engine.navigate(win, url) catch |e| return mapErr(e);
    }

    fn vOpenDevtools(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        cast(ptr).engine.openDevtools(win) catch |e| return mapErr(e);
    }

    fn vCompleteRequest(ptr: ?*anyopaque, req_id: core.RequestId, resp: core.OutgoingResponse) core.HostError!void {
        cast(ptr).engine.completeRequest(req_id, .fromOutgoing(resp)) catch |e| return mapErr(e);
    }
};

test "WebviewHost routes all zts_core.Host operations onto standalone `zts_webview.Engine`" {
    var eng = try webview.Engine.init(testing.allocator, testing.io, .headless_mock);
    defer eng.deinit();

    var wh = WebviewHost.init(&eng);
    const h = wh.host();

    const win = try h.createWindow(.{ .title = "Native or Mock" });
    try h.setWindowTitle(win, "Updated Title");
    try h.setWindowSize(win, .wh(1280, 800));
    try h.evalJs(win, "window.__ok = true;");
    try h.openDevtools(win);
    h.requestQuit();

    try testing.expect(!eng.step(.poll));
    try testing.expectEqualStrings("Updated Title", eng.headless_mock.windows.getPtr(win).?.title);
}
