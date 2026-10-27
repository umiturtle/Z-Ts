//! `zts_webview` — Standalone Minimal Native WebView & Headless Mock Engine (`src/webview/mod.zig`).
//!
//! Strictly depends ONLY on `zts_foundation` (plus optional build option `webview_options`) with
//! ZERO JSON, RPC, HTTP server, or Tauri coupling:
//! - Embeddable standalone in Zig engines, C/C++ hosts (`include/zts_webview.h`), or Z-Ts desktop apps.
//! - Step-driven event loop (`step(.blocking / .poll)`) so callers NEVER lose main-thread control
//!   or `defer` leak-detection scopes, and 60fps/120fps render loops integrate trivially via `.poll`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const webview_options = @import("webview_options");

pub const types = @import("types.zig");
pub const pending = @import("pending.zig");
pub const mock = @import("mock.zig");
pub const c_api = @import("c_api.zig");
pub const png = @import("png.zig");

comptime {
    // Force Zig's lazy semantic analyzer to emit all `export fn zts_webview_*` C ABI symbols
    // when building `zts_webview` as a standalone static/shared C library (`.a` / `.so` / `.dll` / `.dylib`).
    _ = c_api;
}

pub const coords = @import("coords.zig");

pub const has_native_gtk = (builtin.os.tag == .linux) and webview_options.enable_gtk;
pub const linux = if (has_native_gtk) @import("linux.zig") else struct {};

/// Native macOS `NSApplication` + `WKWebView` backend availability (`M3-01`).
pub const has_native_macos = (builtin.os.tag == .macos) and webview_options.enable_macos;
pub const macos = if (has_native_macos) @import("macos.zig") else struct {};

/// Native Windows `Win32` + Direct `WebView2` backend availability (`M3-02`).
/// No `WebView2Loader.dll`: the Evergreen runtime is located in the registry and
/// `EmbeddedBrowserWebView.dll` is loaded directly (see `webview2_loader.zig`).
pub const has_native_windows = (builtin.os.tag == .windows) and webview_options.enable_windows;
pub const windows = if (has_native_windows) @import("windows.zig") else struct {};

/// Hand-generated `ICoreWebView2*` COM vtables (`M3-02`). Pure declarations, so the vtable
/// slot-count assertions and the IID/GUID parsing test also run on Linux and macOS CI.
pub const webview2_com = @import("webview2_com.zig");

/// OS-independent Windows/WebView2 helpers (registry keys, `http://<proto>.localhost` rewriting,
/// DPI math). Zero Win32 imports, so these are unit-tested on every OS (`M3-02`).
pub const windows_util = @import("windows_util.zig");

pub const WindowId = types.WindowId;
pub const RequestId = types.RequestId;
pub const StepMode = types.StepMode;
pub const BackendKind = types.BackendKind;
pub const WebviewError = types.WebviewError;
pub const HeaderPair = types.HeaderPair;
pub const OwnedBytes = types.OwnedBytes;
pub const SchemeRequest = types.SchemeRequest;
pub const SchemeResponse = types.SchemeResponse;
pub const SchemeHandler = types.SchemeHandler;
pub const MessageHandler = types.MessageHandler;
pub const CloseHandler = types.CloseHandler;
pub const WindowConfig = types.WindowConfig;
pub const Capture = types.Capture;
pub const CaptureFormat = types.CaptureFormat;
pub const HeadlessMock = mock.HeadlessMock;

/// Runtime-selectable WebView engine wrapping either the native OS WebView (`LinuxGtkBackend`)
/// or the zero-dependency in-memory `HeadlessMock`.
pub const Engine = union(enum) {
    headless_mock: *HeadlessMock,
    linux_gtk: if (has_native_gtk) *linux.LinuxGtkBackend else noreturn,
    macos_wk: if (has_native_macos) *macos.MacOsBackend else noreturn,
    windows_webview2: if (has_native_windows) *windows.WindowsWebView2Backend else noreturn,

    pub fn init(allocator: Allocator, io: Io, kind: BackendKind) WebviewError!Engine {
        switch (kind) {
            .headless_mock => {
                const m = allocator.create(HeadlessMock) catch return error.OutOfMemory;
                m.* = HeadlessMock.init(allocator, io);
                return .{ .headless_mock = m };
            },
            .native => {
                if (comptime has_native_gtk) {
                    return .{ .linux_gtk = try linux.LinuxGtkBackend.init(allocator, io) };
                }
                if (comptime has_native_macos) {
                    return .{ .macos_wk = try macos.MacOsBackend.init(allocator, io) };
                }
                if (comptime has_native_windows) {
                    return .{ .windows_webview2 = try windows.WindowsWebView2Backend.init(allocator, io) };
                }
                return error.Unsupported;
            },
            .auto => {
                if (comptime has_native_gtk) {
                    if (linux.LinuxGtkBackend.init(allocator, io)) |gtk_backend| {
                        return .{ .linux_gtk = gtk_backend };
                    } else |err| switch (err) {
                        error.DisplayUnavailable => {},
                        else => return err,
                    }
                }
                if (comptime has_native_macos) {
                    if (macos.MacOsBackend.init(allocator, io)) |mac_b| {
                        return .{ .macos_wk = mac_b };
                    } else |err| switch (err) {
                        error.DisplayUnavailable => {},
                        else => return err,
                    }
                }
                if (comptime has_native_windows) {
                    if (windows.WindowsWebView2Backend.init(allocator, io)) |win_b| {
                        return .{ .windows_webview2 = win_b };
                    } else |err| switch (err) {
                        error.DisplayUnavailable => {},
                        else => return err,
                    }
                }
                const m = allocator.create(HeadlessMock) catch return error.OutOfMemory;
                m.* = HeadlessMock.init(allocator, io);
                return .{ .headless_mock = m };
            },
        }
    }

    pub fn deinit(self: *Engine) void {
        switch (self.*) {
            .headless_mock => |m| {
                const alloc = m.allocator;
                m.deinit();
                alloc.destroy(m);
            },
            .linux_gtk => |b| if (comptime has_native_gtk) b.deinit(),
            .macos_wk => |b| if (comptime has_native_macos) b.deinit(),
            .windows_webview2 => |b| if (comptime has_native_windows) b.deinit(),
        }
    }

    pub fn step(self: *Engine, mode: StepMode) bool {
        return switch (self.*) {
            .headless_mock => |m| m.step(mode),
            .linux_gtk => |b| if (comptime has_native_gtk) b.step(mode) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.step(mode) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.step(mode) else unreachable,
        };
    }

    pub fn wakeup(self: *Engine) void {
        switch (self.*) {
            .headless_mock => |m| m.wakeup(),
            .linux_gtk => |b| if (comptime has_native_gtk) b.wakeup(),
            .macos_wk => |b| if (comptime has_native_macos) b.wakeup(),
            .windows_webview2 => |b| if (comptime has_native_windows) b.wakeup(),
        }
    }

    pub fn requestQuit(self: *Engine) void {
        switch (self.*) {
            .headless_mock => |m| m.requestQuit(),
            .linux_gtk => |b| if (comptime has_native_gtk) b.requestQuit(),
            .macos_wk => |b| if (comptime has_native_macos) b.requestQuit(),
            .windows_webview2 => |b| if (comptime has_native_windows) b.requestQuit(),
        }
    }

    pub fn registerScheme(self: *Engine, scheme: []const u8, handler: SchemeHandler) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.registerScheme(scheme, handler),
            .linux_gtk => |b| if (comptime has_native_gtk) b.registerScheme(scheme, handler) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.registerScheme(scheme, handler) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.registerScheme(scheme, handler) else unreachable,
        };
    }

    pub fn setMessageHandler(self: *Engine, handler: ?MessageHandler) void {
        switch (self.*) {
            .headless_mock => |m| m.message_handler = handler,
            .linux_gtk => |b| if (comptime has_native_gtk) {
                b.message_handler = handler;
            },
            .macos_wk => |b| if (comptime has_native_macos) {
                b.message_handler = handler;
            },
            .windows_webview2 => |b| if (comptime has_native_windows) {
                b.message_handler = handler;
            },
        }
    }

    pub fn setCloseHandler(self: *Engine, handler: ?CloseHandler) void {
        switch (self.*) {
            .headless_mock => |m| m.close_handler = handler,
            .linux_gtk => |b| if (comptime has_native_gtk) {
                b.close_handler = handler;
            },
            .macos_wk => |b| if (comptime has_native_macos) {
                b.close_handler = handler;
            },
            .windows_webview2 => |b| if (comptime has_native_windows) {
                b.close_handler = handler;
            },
        }
    }

    /// CORS preflights (`OPTIONS`) absorbed by the platform layer before reaching Zig. Non-zero on
    /// the backends that intercept them itself (WKWebView shim, WebView2 `WebResourceRequested`),
    /// so E2E reports can prove the CORS path was exercised without a Zig round trip.
    pub fn preflightCount(self: *Engine) u64 {
        return switch (self.*) {
            .headless_mock => 0,
            .linux_gtk => 0,
            .macos_wk => |b| if (comptime has_native_macos) b.preflightCount() else 0,
            .windows_webview2 => |b| if (comptime has_native_windows) b.preflightCount() else 0,
        };
    }

    /// Human-readable native WebView runtime version (`"155.0.4283.62"` for WebView2), or `null`
    /// on backends where the OS provides the engine without a queryable version.
    pub fn runtimeVersion(self: *Engine) ?[]const u8 {
        return switch (self.*) {
            .headless_mock => null,
            .linux_gtk => null,
            .macos_wk => null,
            .windows_webview2 => |b| if (comptime has_native_windows) b.runtime.versionString() else null,
        };
    }

    pub fn completeRequest(self: *Engine, req_id: RequestId, resp: SchemeResponse) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.completeRequest(req_id, resp),
            .linux_gtk => |b| if (comptime has_native_gtk) b.completeRequest(req_id, resp) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.completeRequest(req_id, resp) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.completeRequest(req_id, resp) else unreachable,
        };
    }

    pub fn createWindow(self: *Engine, cfg: WindowConfig) WebviewError!WindowId {
        return switch (self.*) {
            .headless_mock => |m| m.createWindow(cfg),
            .linux_gtk => |b| if (comptime has_native_gtk) b.createWindow(cfg) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.createWindow(cfg) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.createWindow(cfg) else unreachable,
        };
    }

    pub fn closeWindow(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.closeWindow(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.closeWindow(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.closeWindow(win_id) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.closeWindow(win_id) else unreachable,
        };
    }

    pub fn nativeHandle(self: *Engine, win_id: WindowId) ?*anyopaque {
        return switch (self.*) {
            .headless_mock => |m| if (m.windows.getPtr(win_id)) |w| w.parent_native_handle else null,
            .linux_gtk => |b| if (comptime has_native_gtk) b.nativeHandle(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.nativeHandle(win_id) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.nativeHandle(win_id) else unreachable,
        };
    }

    /// Resizes an **embedded** window (`WindowConfig.parent_native_handle != null`) to fill its
    /// host container's client area (`M3-03`). Toplevel windows return `error.Unsupported`; hosts
    /// driving their own loop can call this once per frame next to `step(.poll)`.
    pub fn fitParent(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.fitParent(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.fitParent(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.fitParent(win_id) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.fitParent(win_id) else unreachable,
        };
    }

    pub fn setTitle(self: *Engine, win_id: WindowId, title: []const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setTitle(win_id, title),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setTitle(win_id, title) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setTitle(win_id, title) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setTitle(win_id, title) else unreachable,
        };
    }

    pub fn setSize(self: *Engine, win_id: WindowId, size: types.LogicalSize) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setSize(win_id, size),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setSize(win_id, size) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setSize(win_id, size) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setSize(win_id, size) else unreachable,
        };
    }

    pub fn setMinSize(self: *Engine, win_id: WindowId, size: ?types.LogicalSize) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setMinSize(win_id, size),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setMinSize(win_id, size) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setMinSize(win_id, size) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setMinSize(win_id, size) else unreachable,
        };
    }

    pub fn setMaxSize(self: *Engine, win_id: WindowId, size: ?types.LogicalSize) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setMaxSize(win_id, size),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setMaxSize(win_id, size) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setMaxSize(win_id, size) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setMaxSize(win_id, size) else unreachable,
        };
    }

    pub fn setPosition(self: *Engine, win_id: WindowId, pos: types.LogicalPoint) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setPosition(win_id, pos),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setPosition(win_id, pos) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setPosition(win_id, pos) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setPosition(win_id, pos) else unreachable,
        };
    }

    pub fn setResizable(self: *Engine, win_id: WindowId, resizable: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setResizable(win_id, resizable),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setResizable(win_id, resizable) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setResizable(win_id, resizable) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setResizable(win_id, resizable) else unreachable,
        };
    }

    pub fn setMinimized(self: *Engine, win_id: WindowId, minimized: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setMinimized(win_id, minimized),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setMinimized(win_id, minimized) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setMinimized(win_id, minimized) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setMinimized(win_id, minimized) else unreachable,
        };
    }

    pub fn setMaximized(self: *Engine, win_id: WindowId, maximized: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setMaximized(win_id, maximized),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setMaximized(win_id, maximized) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setMaximized(win_id, maximized) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setMaximized(win_id, maximized) else unreachable,
        };
    }

    pub fn setFullscreen(self: *Engine, win_id: WindowId, fullscreen: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setFullscreen(win_id, fullscreen),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setFullscreen(win_id, fullscreen) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setFullscreen(win_id, fullscreen) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setFullscreen(win_id, fullscreen) else unreachable,
        };
    }

    pub fn setVisible(self: *Engine, win_id: WindowId, visible: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setVisible(win_id, visible),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setVisible(win_id, visible) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setVisible(win_id, visible) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setVisible(win_id, visible) else unreachable,
        };
    }

    pub fn setDecorations(self: *Engine, win_id: WindowId, decorations: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setDecorations(win_id, decorations),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setDecorations(win_id, decorations) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setDecorations(win_id, decorations) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setDecorations(win_id, decorations) else unreachable,
        };
    }

    pub fn setAlwaysOnTop(self: *Engine, win_id: WindowId, on_top: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setAlwaysOnTop(win_id, on_top),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setAlwaysOnTop(win_id, on_top) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setAlwaysOnTop(win_id, on_top) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setAlwaysOnTop(win_id, on_top) else unreachable,
        };
    }

    pub fn setFocus(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setFocus(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setFocus(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setFocus(win_id) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.setFocus(win_id) else unreachable,
        };
    }

    pub fn startDrag(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.startDrag(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.startDrag(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.startDrag(win_id) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.startDrag(win_id) else unreachable,
        };
    }

    pub fn addInitScript(self: *Engine, win_id: WindowId, script: []const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.addInitScript(win_id, script),
            .linux_gtk => |b| if (comptime has_native_gtk) b.addInitScript(win_id, script) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.addInitScript(win_id, script) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.addInitScript(win_id, script) else unreachable,
        };
    }

    pub fn evalJs(self: *Engine, win_id: WindowId, script: []const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.evalJs(win_id, script),
            .linux_gtk => |b| if (comptime has_native_gtk) b.evalJs(win_id, script) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.evalJs(win_id, script) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.evalJs(win_id, script) else unreachable,
        };
    }

    pub fn navigate(self: *Engine, win_id: WindowId, url: []const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.navigate(win_id, url),
            .linux_gtk => |b| if (comptime has_native_gtk) b.navigate(win_id, url) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.navigate(win_id, url) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.navigate(win_id, url) else unreachable,
        };
    }

    pub fn loadHtml(self: *Engine, win_id: WindowId, html: []const u8, base_uri: ?[]const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.loadHtml(win_id, html, base_uri),
            .linux_gtk => |b| if (comptime has_native_gtk) b.loadHtml(win_id, html, base_uri) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.loadHtml(win_id, html, base_uri) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.loadHtml(win_id, html, base_uri) else unreachable,
        };
    }

    /// Starts an asynchronous PNG screenshot of `win_id`'s current viewport (`M5-04`).
    ///
    /// All three native backends capture asynchronously (WebKit snapshot / `WKWebView`
    /// `takeSnapshotWithConfiguration:` / WebView2 `CapturePreview`), so this only *queues* the work:
    /// drive the loop with `step(.poll)` and collect the result with `takeCapture()`. Calling it
    /// again before collection replaces the pending image instead of leaking it.
    pub fn captureWindow(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.captureWindow(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.captureWindow(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.captureWindow(win_id) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.captureWindow(win_id) else unreachable,
        };
    }

    /// Moves a finished screenshot to the caller, or `null` while the backend is still rendering.
    /// The caller owns the returned `Capture` and must `deinit()` it.
    pub fn takeCapture(self: *Engine, win_id: WindowId) WebviewError!?Capture {
        return switch (self.*) {
            .headless_mock => |m| m.takeCapture(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.takeCapture(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.takeCapture(win_id) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.takeCapture(win_id) else unreachable,
        };
    }

    pub fn openDevtools(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.openDevtools(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.openDevtools(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.openDevtools(win_id) else unreachable,
            .windows_webview2 => |b| if (comptime has_native_windows) b.openDevtools(win_id) else unreachable,
        };
    }
};

test {
    _ = types;
    _ = pending;
    _ = png;
    _ = @import("capture_test.zig");
    _ = mock;
    _ = c_api;
    _ = coords;
    _ = @import("embed_test.zig");
    _ = webview2_com;
    _ = windows_util;
    // The Windows files are pure Zig (no `@cImport`, no header parsing), so they stay *analyzable*
    // on every host. Importing them here means the Linux/macOS CI jobs unit-test the Win32 UTF-16
    // helpers, the registry-path composition, the runtime search order and the virtual-origin
    // classifier — not just `windows-latest` (ADR-0007).
    _ = @import("win32.zig");
    _ = @import("windows.zig");
    _ = @import("webview2_loader.zig");
    if (comptime has_native_gtk) {
        _ = linux;
    }
    if (comptime has_native_macos) {
        _ = macos;
    }
    if (comptime has_native_windows) {
        _ = windows;
    }
}
