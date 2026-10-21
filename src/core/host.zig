//! OS-Independent Platform Host Interface (`Host` VTable) & Test Spy (`RecordingHost`).
//!
//! Resolves the circular-dependency problem identified in `ADR-0002` (Rev 4):
//! - Neither `zts_rpc` nor `zts_tauri` imports `zts_webview` (GTK / Cocoa / Win32) or `zts_bridge`.
//! - Instead, runtime contexts carry a 2-word `Host` fat pointer (`userdata + vtable`), allowing
//!    identical command modules (`window`, `event`, `webview`, user RPC handlers) to execute
//!   against Native WebViews, Browser HTTP Bridges, or 0ms in-memory `RecordingHost` unit tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const handle_pool = @import("handle_pool.zig");
const owned_bytes = @import("owned_bytes.zig");
const geometry = @import("geometry.zig");

pub const Handle = handle_pool.Handle;
pub const OwnedBytes = owned_bytes.OwnedBytes;
pub const LogicalPoint = geometry.LogicalPoint;
pub const LogicalSize = geometry.LogicalSize;
pub const Color = geometry.Color;

/// Generational 53-bit identifier for a window/webview instance.
pub const WindowId = Handle(.window);

/// Generational 53-bit identifier for an in-flight custom-scheme / IPC request.
pub const RequestId = Handle(.ipc_request);

/// Event-loop progression mode (`app.step(mode)`).
pub const StepMode = enum {
    /// Blocks until at least one OS / wakeup event arrives and processes pending events.
    blocking,
    /// Processes any immediately pending events without blocking (ideal for 60fps game loops).
    poll,
};

pub const WindowTheme = enum {
    system,
    light,
    dark,
};

/// Declarative initial window creation specification.
pub const WindowSpec = struct {
    label: []const u8 = "main",
    title: []const u8 = "Z-Ts Application",
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
    theme: WindowTheme = .system,
    initial_url: []const u8 = "tauri://localhost/",
};

pub const IpcStatus = enum {
    ok,
    err,
};

/// Payload returned to complete a pending IPC / custom-protocol request on the main loop.
pub const OutgoingResponse = struct {
    status: IpcStatus = .ok,
    http_code: u16 = 200,
    content_type: []const u8 = "application/json",
    body: OwnedBytes = .empty,

    pub fn deinit(self: *OutgoingResponse) void {
        self.body.deinit();
    }
};

pub const HostError = error{
    Unsupported,
    WindowNotFound,
    RequestCanceled,
    OutOfMemory,
    PlatformFailure,
};

/// Two-word fat-pointer interface implemented by `zts_webview` (Linux/macOS/Windows/Mock)
/// and `zts_bridge` (HTTP + SSE live preview).
///
/// Every method is safe to call from any thread: implementations either enqueue an internal
/// main-thread command via `wakeup` or act directly on thread-safe state.
pub const Host = struct {
    userdata: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Wakes the main OS event loop from any background thread (lock-free / async-signal-safe).
        wakeup: *const fn (userdata: ?*anyopaque) void = noopWakeup,
        /// Requests graceful termination so `step()` returns `false`.
        requestQuit: *const fn (userdata: ?*anyopaque) void = noopWakeup,

        createWindow: ?*const fn (userdata: ?*anyopaque, spec: WindowSpec) HostError!WindowId = null,
        closeWindow: ?*const fn (userdata: ?*anyopaque, win: WindowId) HostError!void = null,
        setWindowTitle: ?*const fn (userdata: ?*anyopaque, win: WindowId, title: []const u8) HostError!void = null,
        setWindowSize: ?*const fn (userdata: ?*anyopaque, win: WindowId, size: LogicalSize) HostError!void = null,
        setWindowMinSize: ?*const fn (userdata: ?*anyopaque, win: WindowId, size: ?LogicalSize) HostError!void = null,
        setWindowMaxSize: ?*const fn (userdata: ?*anyopaque, win: WindowId, size: ?LogicalSize) HostError!void = null,
        setWindowPosition: ?*const fn (userdata: ?*anyopaque, win: WindowId, pos: LogicalPoint) HostError!void = null,
        setWindowResizable: ?*const fn (userdata: ?*anyopaque, win: WindowId, resizable: bool) HostError!void = null,
        setWindowMinimized: ?*const fn (userdata: ?*anyopaque, win: WindowId, minimized: bool) HostError!void = null,
        setWindowMaximized: ?*const fn (userdata: ?*anyopaque, win: WindowId, maximized: bool) HostError!void = null,
        setWindowFullscreen: ?*const fn (userdata: ?*anyopaque, win: WindowId, fullscreen: bool) HostError!void = null,
        setWindowVisible: ?*const fn (userdata: ?*anyopaque, win: WindowId, visible: bool) HostError!void = null,
        setWindowDecorations: ?*const fn (userdata: ?*anyopaque, win: WindowId, decorations: bool) HostError!void = null,
        setWindowAlwaysOnTop: ?*const fn (userdata: ?*anyopaque, win: WindowId, on_top: bool) HostError!void = null,
        setWindowFocus: ?*const fn (userdata: ?*anyopaque, win: WindowId) HostError!void = null,
        startWindowDrag: ?*const fn (userdata: ?*anyopaque, win: WindowId) HostError!void = null,

        evalJs: ?*const fn (userdata: ?*anyopaque, win: WindowId, script: []const u8) HostError!void = null,
        navigate: ?*const fn (userdata: ?*anyopaque, win: WindowId, url: []const u8) HostError!void = null,
        openDevtools: ?*const fn (userdata: ?*anyopaque, win: WindowId) HostError!void = null,
        completeRequest: ?*const fn (userdata: ?*anyopaque, req_id: RequestId, resp: OutgoingResponse) HostError!void = null,
    };

    /// Null object host returning `error.Unsupported` for optional operations without crashing.
    pub const null_host: Host = .{ .userdata = null, .vtable = &.{
        .wakeup = noopWakeup,
        .requestQuit = noopWakeup,
    } };

    fn noopWakeup(_: ?*anyopaque) void {}

    pub inline fn wakeup(self: Host) void {
        self.vtable.wakeup(self.userdata);
    }

    pub inline fn requestQuit(self: Host) void {
        self.vtable.requestQuit(self.userdata);
    }

    pub fn createWindow(self: Host, spec: WindowSpec) HostError!WindowId {
        const f = self.vtable.createWindow orelse return error.Unsupported;
        return f(self.userdata, spec);
    }

    pub fn closeWindow(self: Host, win: WindowId) HostError!void {
        const f = self.vtable.closeWindow orelse return error.Unsupported;
        return f(self.userdata, win);
    }

    pub fn setWindowTitle(self: Host, win: WindowId, title: []const u8) HostError!void {
        const f = self.vtable.setWindowTitle orelse return error.Unsupported;
        return f(self.userdata, win, title);
    }

    pub fn setWindowSize(self: Host, win: WindowId, size: LogicalSize) HostError!void {
        const f = self.vtable.setWindowSize orelse return error.Unsupported;
        return f(self.userdata, win, size);
    }

    pub fn setWindowMinSize(self: Host, win: WindowId, size: ?LogicalSize) HostError!void {
        const f = self.vtable.setWindowMinSize orelse return error.Unsupported;
        return f(self.userdata, win, size);
    }

    pub fn setWindowMaxSize(self: Host, win: WindowId, size: ?LogicalSize) HostError!void {
        const f = self.vtable.setWindowMaxSize orelse return error.Unsupported;
        return f(self.userdata, win, size);
    }

    pub fn setWindowPosition(self: Host, win: WindowId, pos: LogicalPoint) HostError!void {
        const f = self.vtable.setWindowPosition orelse return error.Unsupported;
        return f(self.userdata, win, pos);
    }

    pub fn setWindowResizable(self: Host, win: WindowId, resizable: bool) HostError!void {
        const f = self.vtable.setWindowResizable orelse return error.Unsupported;
        return f(self.userdata, win, resizable);
    }

    pub fn setWindowMinimized(self: Host, win: WindowId, minimized: bool) HostError!void {
        const f = self.vtable.setWindowMinimized orelse return error.Unsupported;
        return f(self.userdata, win, minimized);
    }

    pub fn setWindowMaximized(self: Host, win: WindowId, maximized: bool) HostError!void {
        const f = self.vtable.setWindowMaximized orelse return error.Unsupported;
        return f(self.userdata, win, maximized);
    }

    pub fn setWindowFullscreen(self: Host, win: WindowId, fullscreen: bool) HostError!void {
        const f = self.vtable.setWindowFullscreen orelse return error.Unsupported;
        return f(self.userdata, win, fullscreen);
    }

    pub fn setWindowVisible(self: Host, win: WindowId, visible: bool) HostError!void {
        const f = self.vtable.setWindowVisible orelse return error.Unsupported;
        return f(self.userdata, win, visible);
    }

    pub fn setWindowDecorations(self: Host, win: WindowId, decorations: bool) HostError!void {
        const f = self.vtable.setWindowDecorations orelse return error.Unsupported;
        return f(self.userdata, win, decorations);
    }

    pub fn setWindowAlwaysOnTop(self: Host, win: WindowId, on_top: bool) HostError!void {
        const f = self.vtable.setWindowAlwaysOnTop orelse return error.Unsupported;
        return f(self.userdata, win, on_top);
    }

    pub fn setWindowFocus(self: Host, win: WindowId) HostError!void {
        const f = self.vtable.setWindowFocus orelse return error.Unsupported;
        return f(self.userdata, win);
    }

    pub fn startWindowDrag(self: Host, win: WindowId) HostError!void {
        const f = self.vtable.startWindowDrag orelse return error.Unsupported;
        return f(self.userdata, win);
    }

    pub fn evalJs(self: Host, win: WindowId, script: []const u8) HostError!void {
        const f = self.vtable.evalJs orelse return error.Unsupported;
        return f(self.userdata, win, script);
    }

    pub fn navigate(self: Host, win: WindowId, url: []const u8) HostError!void {
        const f = self.vtable.navigate orelse return error.Unsupported;
        return f(self.userdata, win, url);
    }

    pub fn openDevtools(self: Host, win: WindowId) HostError!void {
        const f = self.vtable.openDevtools orelse return error.Unsupported;
        return f(self.userdata, win);
    }

    /// Transfers ownership of `resp` to the host. On error, automatically releases `resp.body`
    /// so callers never leak response buffers when a window closes mid-flight!
    pub fn completeRequest(self: Host, req_id: RequestId, resp: OutgoingResponse) HostError!void {
        var owned = resp;
        const f = self.vtable.completeRequest orelse {
            owned.deinit();
            return error.Unsupported;
        };
        f(self.userdata, req_id, owned) catch |err| {
            owned.deinit();
            return err;
        };
    }
};

// ============================================================================
// Built-in In-Memory Test Spy (`RecordingHost`) for Downstream Unit Tests
// ============================================================================

/// Lightweight deterministic `Host` implementation for unit-testing `zts_rpc` and `zts_tauri`
/// command handlers without spinning up any GUI window or network socket.
pub const RecordingHost = struct {
    allocator: Allocator,
    windows: handle_pool.HandlePool(MockWindow, .window) = .empty,
    eval_log: std.ArrayList([]u8) = .empty,
    wakeups: usize = 0,
    quit_requested: bool = false,
    drag_count: usize = 0,

    pub const MockWindow = struct {
        label: []u8,
        title: []u8,
        size: LogicalSize,
        position: LogicalPoint = .xy(0, 0),
        minimized: bool = false,
        maximized: bool = false,
        fullscreen: bool = false,
        visible: bool = true,
        decorations: bool = true,
        always_on_top: bool = false,
        resizable: bool = true,
    };

    pub fn init(allocator: Allocator) RecordingHost {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RecordingHost) void {
        const alloc = self.allocator;
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.value_ptr.label);
            alloc.free(entry.value_ptr.title);
        }
        self.windows.deinit(alloc);
        for (self.eval_log.items) |s| alloc.free(s);
        self.eval_log.deinit(alloc);
    }

    pub fn host(self: *RecordingHost) Host {
        return .{
            .userdata = self,
            .vtable = &vtable_impl,
        };
    }

    const vtable_impl: Host.VTable = .{
        .wakeup = onWakeup,
        .requestQuit = onQuit,
        .createWindow = onCreateWindow,
        .closeWindow = onCloseWindow,
        .setWindowTitle = onSetTitle,
        .setWindowSize = onSetSize,
        .setWindowPosition = onSetPos,
        .setWindowMinimized = onSetMin,
        .setWindowMaximized = onSetMax,
        .setWindowFullscreen = onSetFull,
        .setWindowVisible = onSetVis,
        .setWindowDecorations = onSetDeco,
        .setWindowAlwaysOnTop = onSetTop,
        .setWindowResizable = onSetResizable,
        .startWindowDrag = onStartDrag,
        .evalJs = onEvalJs,
    };

    fn cast(u: ?*anyopaque) *RecordingHost {
        return @ptrCast(@alignCast(u.?));
    }

    fn onWakeup(u: ?*anyopaque) void {
        cast(u).wakeups += 1;
    }

    fn onQuit(u: ?*anyopaque) void {
        cast(u).quit_requested = true;
    }

    fn onCreateWindow(u: ?*anyopaque, spec: WindowSpec) HostError!WindowId {
        const self = cast(u);
        const label = try self.allocator.dupe(u8, spec.label);
        errdefer self.allocator.free(label);
        const title = try self.allocator.dupe(u8, spec.title);
        errdefer self.allocator.free(title);

        return self.windows.acquire(self.allocator, .{
            .label = label,
            .title = title,
            .size = spec.size,
            .position = spec.position orelse .xy(0, 0),
            .visible = spec.visible,
            .decorations = spec.decorations,
            .always_on_top = spec.always_on_top,
            .fullscreen = spec.fullscreen,
            .resizable = spec.resizable,
        }) catch return error.OutOfMemory;
    }

    fn onCloseWindow(u: ?*anyopaque, win: WindowId) HostError!void {
        const self = cast(u);
        const removed = self.windows.release(win) catch return error.WindowNotFound;
        self.allocator.free(removed.label);
        self.allocator.free(removed.title);
    }

    fn onSetTitle(u: ?*anyopaque, win: WindowId, title: []const u8) HostError!void {
        const self = cast(u);
        const w = self.windows.getPtr(win) orelse return error.WindowNotFound;
        const copy = try self.allocator.dupe(u8, title);
        self.allocator.free(w.title);
        w.title = copy;
    }

    fn onSetSize(u: ?*anyopaque, win: WindowId, size: LogicalSize) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.size = size;
    }

    fn onSetPos(u: ?*anyopaque, win: WindowId, pos: LogicalPoint) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.position = pos;
    }

    fn onSetMin(u: ?*anyopaque, win: WindowId, v: bool) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.minimized = v;
    }

    fn onSetMax(u: ?*anyopaque, win: WindowId, v: bool) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.maximized = v;
    }

    fn onSetFull(u: ?*anyopaque, win: WindowId, v: bool) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.fullscreen = v;
    }

    fn onSetVis(u: ?*anyopaque, win: WindowId, v: bool) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.visible = v;
    }

    fn onSetDeco(u: ?*anyopaque, win: WindowId, v: bool) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.decorations = v;
    }

    fn onSetTop(u: ?*anyopaque, win: WindowId, v: bool) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.always_on_top = v;
    }

    fn onSetResizable(u: ?*anyopaque, win: WindowId, v: bool) HostError!void {
        const w = cast(u).windows.getPtr(win) orelse return error.WindowNotFound;
        w.resizable = v;
    }

    fn onStartDrag(u: ?*anyopaque, win: WindowId) HostError!void {
        const self = cast(u);
        if (!self.windows.contains(win)) return error.WindowNotFound;
        self.drag_count += 1;
    }

    fn onEvalJs(u: ?*anyopaque, win: WindowId, script: []const u8) HostError!void {
        const self = cast(u);
        if (!self.windows.contains(win)) return error.WindowNotFound;
        const copy = try self.allocator.dupe(u8, script);
        try self.eval_log.append(self.allocator, copy);
    }
};

// ============================================================================
// Unit & Leak-Safety Tests
// ============================================================================

test "Host & RecordingHost: lifecycle, stale window rejection, and automatic response cleanup on error" {
    const alloc = std.testing.allocator;

    var rec = RecordingHost.init(alloc);
    defer rec.deinit();

    const h = rec.host();
    const win = try h.createWindow(.{ .label = "main", .title = "Initial", .size = .wh(900, 700) });
    try h.setWindowTitle(win, "Updated Title");
    try h.setWindowSize(win, .wh(1280, 720));
    try h.evalJs(win, "window.__ready = true;");
    try h.startWindowDrag(win);
    h.wakeup();

    try std.testing.expectEqualStrings("Updated Title", rec.windows.get(win).?.title);
    try std.testing.expectEqual(@as(f64, 1280.0), rec.windows.get(win).?.size.width.v);
    try std.testing.expectEqual(@as(usize, 1), rec.eval_log.items.len);
    try std.testing.expectEqual(@as(usize, 1), rec.drag_count);
    try std.testing.expectEqual(@as(usize, 1), rec.wakeups);

    // Calling an unimplemented method on `null_host` with an allocator-owned body MUST NOT leak!
    const owned_body = try OwnedBytes.dupe(alloc, "in-flight response payload");
    try std.testing.expectError(
        error.Unsupported,
        Host.null_host.completeRequest(.{ .index = 0, .generation = 1 }, .{ .body = owned_body }),
    );

    // Closing the window invalidates the generational `WindowId` immediately
    try h.closeWindow(win);
    try std.testing.expectError(error.WindowNotFound, h.setWindowTitle(win, "Should Fail"));
    try std.testing.expectError(error.WindowNotFound, h.evalJs(win, "alert(1)"));
}
