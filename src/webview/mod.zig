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

pub const WindowId = types.WindowId;
pub const RequestId = types.RequestId;
pub const StepMode = types.StepMode;
pub const BackendKind = types.BackendKind;
pub const WebviewError = types.WebviewError;
pub const HeaderPair = types.HeaderPair;
pub const SchemeRequest = types.SchemeRequest;
pub const SchemeResponse = types.SchemeResponse;
pub const SchemeHandler = types.SchemeHandler;
pub const MessageHandler = types.MessageHandler;
pub const CloseHandler = types.CloseHandler;
pub const WindowConfig = types.WindowConfig;
pub const HeadlessMock = mock.HeadlessMock;

/// Runtime-selectable WebView engine wrapping either the native OS WebView (`LinuxGtkBackend`)
/// or the zero-dependency in-memory `HeadlessMock`.
pub const Engine = union(enum) {
    headless_mock: *HeadlessMock,
    linux_gtk: if (has_native_gtk) *linux.LinuxGtkBackend else noreturn,
    macos_wk: if (has_native_macos) *macos.MacOsBackend else noreturn,

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
        }
    }

    pub fn step(self: *Engine, mode: StepMode) bool {
        return switch (self.*) {
            .headless_mock => |m| m.step(mode),
            .linux_gtk => |b| if (comptime has_native_gtk) b.step(mode) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.step(mode) else unreachable,
        };
    }

    pub fn wakeup(self: *Engine) void {
        switch (self.*) {
            .headless_mock => |m| m.wakeup(),
            .linux_gtk => |b| if (comptime has_native_gtk) b.wakeup(),
            .macos_wk => |b| if (comptime has_native_macos) b.wakeup(),
        }
    }

    pub fn requestQuit(self: *Engine) void {
        switch (self.*) {
            .headless_mock => |m| m.requestQuit(),
            .linux_gtk => |b| if (comptime has_native_gtk) b.requestQuit(),
            .macos_wk => |b| if (comptime has_native_macos) b.requestQuit(),
        }
    }

    pub fn registerScheme(self: *Engine, scheme: []const u8, handler: SchemeHandler) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.registerScheme(scheme, handler),
            .linux_gtk => |b| if (comptime has_native_gtk) b.registerScheme(scheme, handler) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.registerScheme(scheme, handler) else unreachable,
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
        }
    }

    pub fn completeRequest(self: *Engine, req_id: RequestId, resp: SchemeResponse) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.completeRequest(req_id, resp),
            .linux_gtk => |b| if (comptime has_native_gtk) b.completeRequest(req_id, resp) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.completeRequest(req_id, resp) else unreachable,
        };
    }

    pub fn createWindow(self: *Engine, cfg: WindowConfig) WebviewError!WindowId {
        return switch (self.*) {
            .headless_mock => |m| m.createWindow(cfg),
            .linux_gtk => |b| if (comptime has_native_gtk) b.createWindow(cfg) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.createWindow(cfg) else unreachable,
        };
    }

    pub fn closeWindow(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.closeWindow(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.closeWindow(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.closeWindow(win_id) else unreachable,
        };
    }

    pub fn nativeHandle(self: *Engine, win_id: WindowId) ?*anyopaque {
        return switch (self.*) {
            .headless_mock => |m| if (m.windows.getPtr(win_id)) |w| w.parent_native_handle else null,
            .linux_gtk => |b| if (comptime has_native_gtk) b.nativeHandle(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.nativeHandle(win_id) else unreachable,
        };
    }

    pub fn setTitle(self: *Engine, win_id: WindowId, title: []const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setTitle(win_id, title),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setTitle(win_id, title) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setTitle(win_id, title) else unreachable,
        };
    }

    pub fn setSize(self: *Engine, win_id: WindowId, size: types.LogicalSize) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setSize(win_id, size),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setSize(win_id, size) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setSize(win_id, size) else unreachable,
        };
    }

    pub fn setMinSize(self: *Engine, win_id: WindowId, size: ?types.LogicalSize) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setMinSize(win_id, size),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setMinSize(win_id, size) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setMinSize(win_id, size) else unreachable,
        };
    }

    pub fn setMaxSize(self: *Engine, win_id: WindowId, size: ?types.LogicalSize) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setMaxSize(win_id, size),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setMaxSize(win_id, size) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setMaxSize(win_id, size) else unreachable,
        };
    }

    pub fn setPosition(self: *Engine, win_id: WindowId, pos: types.LogicalPoint) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setPosition(win_id, pos),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setPosition(win_id, pos) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setPosition(win_id, pos) else unreachable,
        };
    }

    pub fn setResizable(self: *Engine, win_id: WindowId, resizable: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setResizable(win_id, resizable),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setResizable(win_id, resizable) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setResizable(win_id, resizable) else unreachable,
        };
    }

    pub fn setMinimized(self: *Engine, win_id: WindowId, minimized: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setMinimized(win_id, minimized),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setMinimized(win_id, minimized) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setMinimized(win_id, minimized) else unreachable,
        };
    }

    pub fn setMaximized(self: *Engine, win_id: WindowId, maximized: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setMaximized(win_id, maximized),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setMaximized(win_id, maximized) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setMaximized(win_id, maximized) else unreachable,
        };
    }

    pub fn setFullscreen(self: *Engine, win_id: WindowId, fullscreen: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setFullscreen(win_id, fullscreen),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setFullscreen(win_id, fullscreen) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setFullscreen(win_id, fullscreen) else unreachable,
        };
    }

    pub fn setVisible(self: *Engine, win_id: WindowId, visible: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setVisible(win_id, visible),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setVisible(win_id, visible) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setVisible(win_id, visible) else unreachable,
        };
    }

    pub fn setDecorations(self: *Engine, win_id: WindowId, decorations: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setDecorations(win_id, decorations),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setDecorations(win_id, decorations) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setDecorations(win_id, decorations) else unreachable,
        };
    }

    pub fn setAlwaysOnTop(self: *Engine, win_id: WindowId, on_top: bool) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setAlwaysOnTop(win_id, on_top),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setAlwaysOnTop(win_id, on_top) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setAlwaysOnTop(win_id, on_top) else unreachable,
        };
    }

    pub fn setFocus(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.setFocus(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.setFocus(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.setFocus(win_id) else unreachable,
        };
    }

    pub fn startDrag(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.startDrag(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.startDrag(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.startDrag(win_id) else unreachable,
        };
    }

    pub fn addInitScript(self: *Engine, win_id: WindowId, script: []const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.addInitScript(win_id, script),
            .linux_gtk => |b| if (comptime has_native_gtk) b.addInitScript(win_id, script) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.addInitScript(win_id, script) else unreachable,
        };
    }

    pub fn evalJs(self: *Engine, win_id: WindowId, script: []const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.evalJs(win_id, script),
            .linux_gtk => |b| if (comptime has_native_gtk) b.evalJs(win_id, script) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.evalJs(win_id, script) else unreachable,
        };
    }

    pub fn navigate(self: *Engine, win_id: WindowId, url: []const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.navigate(win_id, url),
            .linux_gtk => |b| if (comptime has_native_gtk) b.navigate(win_id, url) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.navigate(win_id, url) else unreachable,
        };
    }

    pub fn loadHtml(self: *Engine, win_id: WindowId, html: []const u8, base_uri: ?[]const u8) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.loadHtml(win_id, html, base_uri),
            .linux_gtk => |b| if (comptime has_native_gtk) b.loadHtml(win_id, html, base_uri) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.loadHtml(win_id, html, base_uri) else unreachable,
        };
    }

    pub fn openDevtools(self: *Engine, win_id: WindowId) WebviewError!void {
        return switch (self.*) {
            .headless_mock => |m| m.openDevtools(win_id),
            .linux_gtk => |b| if (comptime has_native_gtk) b.openDevtools(win_id) else unreachable,
            .macos_wk => |b| if (comptime has_native_macos) b.openDevtools(win_id) else unreachable,
        };
    }
};

test {
    _ = types;
    _ = pending;
    _ = mock;
    _ = c_api;
    _ = coords;
    if (comptime has_native_gtk) {
        _ = linux;
    }
    if (comptime has_native_macos) {
        _ = macos;
    }
}
