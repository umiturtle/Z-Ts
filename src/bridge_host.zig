//! Desktop `Host` VTable Adapter over `zts_bridge.BridgeServer` (`src/bridge_host.zig`).
//!
//! Bridges `zts_core.Host` window/webview operations directly onto a live `BridgeServer` SSE
//! stream so identical application code (`plugin:window|*`, `evalJs`, `navigate`, `emitEvent`,
//! `app.step()`) runs identically inside a native OS WebView OR inside any external browser /
//! Arena Live Preview / Playwright E2E runner without compiling GTK/WebKit/Cocoa/WebView2.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const core = @import("zts_core");
const bridge = @import("zts_bridge");

pub const BridgeHost = struct {
    allocator: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    server: *bridge.BridgeServer,
    backing: core.RecordingHost,

    pub fn init(allocator: Allocator, io: Io, server: *bridge.BridgeServer) BridgeHost {
        return .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .backing = core.RecordingHost.init(allocator),
        };
    }

    pub fn deinit(self: *BridgeHost) void {
        self.backing.deinit();
    }

    pub fn host(self: *BridgeHost) core.Host {
        return .{
            .userdata = self,
            .vtable = &vtable,
        };
    }

    pub fn emitEvent(self: *BridgeHost, event_name: []const u8, json_payload: []const u8) Allocator.Error!usize {
        return self.server.emitEvent(event_name, json_payload);
    }

    pub fn quitRequested(self: *BridgeHost) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.quit_requested;
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
    };

    inline fn cast(ptr: ?*anyopaque) *BridgeHost {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn vWakeup(ptr: ?*anyopaque) void {
        const self = cast(ptr);
        self.backing.host().wakeup();
    }

    fn vRequestQuit(ptr: ?*anyopaque) void {
        const self = cast(ptr);
        self.backing.host().requestQuit();
    }

    fn vCreateWindow(ptr: ?*anyopaque, spec: core.WindowSpec) core.HostError!core.WindowId {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        const win_id = self.backing.host().createWindow(spec) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
        _ = self.server.broadcastWindowTitle(spec.title) catch return error.OutOfMemory;
        return win_id;
    }

    fn vCloseWindow(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().closeWindow(win);
    }

    fn vSetWindowTitle(ptr: ?*anyopaque, win: core.WindowId, title: []const u8) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        self.backing.host().setWindowTitle(win, title) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
        _ = self.server.broadcastWindowTitle(title) catch return error.OutOfMemory;
    }

    fn vSetWindowSize(ptr: ?*anyopaque, win: core.WindowId, size: core.LogicalSize) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowSize(win, size);
    }

    fn vSetWindowMinSize(ptr: ?*anyopaque, win: core.WindowId, size: ?core.LogicalSize) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowMinSize(win, size);
    }

    fn vSetWindowMaxSize(ptr: ?*anyopaque, win: core.WindowId, size: ?core.LogicalSize) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowMaxSize(win, size);
    }

    fn vSetWindowPosition(ptr: ?*anyopaque, win: core.WindowId, pos: core.LogicalPoint) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowPosition(win, pos);
    }

    fn vSetWindowResizable(ptr: ?*anyopaque, win: core.WindowId, resizable: bool) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowResizable(win, resizable);
    }

    fn vSetWindowMinimized(ptr: ?*anyopaque, win: core.WindowId, minimized: bool) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowMinimized(win, minimized);
    }

    fn vSetWindowMaximized(ptr: ?*anyopaque, win: core.WindowId, maximized: bool) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowMaximized(win, maximized);
    }

    fn vSetWindowFullscreen(ptr: ?*anyopaque, win: core.WindowId, fullscreen: bool) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowFullscreen(win, fullscreen);
    }

    fn vSetWindowVisible(ptr: ?*anyopaque, win: core.WindowId, visible: bool) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowVisible(win, visible);
    }

    fn vSetWindowDecorations(ptr: ?*anyopaque, win: core.WindowId, decorations: bool) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowDecorations(win, decorations);
    }

    fn vSetWindowAlwaysOnTop(ptr: ?*anyopaque, win: core.WindowId, on_top: bool) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowAlwaysOnTop(win, on_top);
    }

    fn vSetWindowFocus(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().setWindowFocus(win);
    }

    fn vStartWindowDrag(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.backing.host().startWindowDrag(win);
    }

    fn vEvalJs(ptr: ?*anyopaque, win: core.WindowId, script: []const u8) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        self.backing.host().evalJs(win, script) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
        _ = self.server.evalJs(script) catch return error.OutOfMemory;
    }

    fn vNavigate(ptr: ?*anyopaque, win: core.WindowId, url: []const u8) core.HostError!void {
        const self = cast(ptr);
        self.mu.lockUncancelable(self.io);
        self.backing.host().navigate(win, url) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);

        var js_buf: std.ArrayList(u8) = .empty;
        defer js_buf.deinit(self.allocator);
        var aw: Io.Writer.Allocating = .fromArrayList(self.allocator, &js_buf);
        aw.writer.writeAll("window.location.assign(") catch return error.OutOfMemory;
        core.html_escape.writeJsonString(&aw.writer, url, true) catch return error.OutOfMemory;
        aw.writer.writeAll(");") catch return error.OutOfMemory;
        js_buf = aw.toArrayList();

        _ = self.server.evalJs(js_buf.items) catch return error.OutOfMemory;
    }

    fn vOpenDevtools(_: ?*anyopaque, _: core.WindowId) core.HostError!void {
        // Browser tabs already expose built-in F12 DevTools!
    }
};

test "BridgeHost implements zts_core.Host VTable cleanly atop live BridgeServer" {
    const srv = try bridge.BridgeServer.start(testing.allocator, testing.io, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    defer srv.stopAndDeinit();

    var bh = BridgeHost.init(testing.allocator, testing.io, srv);
    defer bh.deinit();

    const h = bh.host();
    const win = try h.createWindow(.{ .title = "Boot" });
    try h.setWindowTitle(win, "Studio Live Preview");
    try h.evalJs(win, "console.log('ready');");
    try h.openDevtools(win);
    h.requestQuit();

    try testing.expect(bh.quitRequested());
    try testing.expectEqualStrings("Studio Live Preview", bh.backing.windows.get(win).?.title);
}
