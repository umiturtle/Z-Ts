//! `WasmHost` — Browser / WebAssembly `zts_core.Host` VTable Implementation (`src/wasm/host.zig`).
//!
//! Bridges `zts_core.Host` operations inside `wasm32-freestanding` directly into the host page
//! via a single FFI import `zts_host.zts_host_eval_js(ptr, len)` (or a custom Zig callback when
//! running native unit tests!).
//!
//! Because `Channel(T)` frames, `EventBus` broadcasts/targeted events, and `document.title` sync
//! all flow through `evalJs`, EVERY Tauri v2 core plugin works identically inside a serverless
//! static WebAssembly page with **zero application code changes**!

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const foundation = @import("zts_foundation");
const core = @import("zts_core");

const is_wasm = builtin.cpu.arch.isWasm();

extern "zts_host" fn zts_host_eval_js(ptr: [*]const u8, len: usize) void;

/// Reports a panic message to the browser console before trapping.
/// Zig's default freestanding panic handler cannot print, so this makes wasm crashes debuggable.
pub fn reportPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (is_wasm) {
        var buf: [640]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        const w = &fbs;
        w.writeAll("console.error(\"Z-TS WASM PANIC: ") catch {};
        for (msg) |c| {
            switch (c) {
                '"' => w.writeAll("\\\"") catch {},
                '\\' => w.writeAll("\\\\") catch {},
                '\n' => w.writeAll("\\n") catch {},
                '\r' => {},
                else => w.writeByte(c) catch {},
            }
        }
        if (first_trace_addr) |addr| {
            w.writeAll(" at 0x") catch {};
            w.print("{x}", .{addr}) catch {};
        }
        w.writeAll("\");") catch {};
        zts_host_eval_js(fbs.buffered().ptr, fbs.buffered().len);
    }
    @trap();
}

pub const EvalHook = struct {
    ctx: ?*anyopaque = null,
    callFn: *const fn (ctx: ?*anyopaque, script: []const u8) void,
};

pub const WasmHost = struct {
    allocator: Allocator,
    backing: core.RecordingHost,
    /// Optional custom hook (used in native unit tests; defaults to `zts_host_eval_js` on Wasm).
    eval_hook: ?EvalHook = null,

    pub fn init(allocator: Allocator) WasmHost {
        return .{
            .allocator = allocator,
            .backing = core.RecordingHost.init(allocator),
        };
    }

    pub fn deinit(self: *WasmHost) void {
        self.backing.deinit();
    }

    pub fn host(self: *WasmHost) core.Host {
        return .{
            .userdata = self,
            .vtable = &vtable,
        };
    }

    pub fn quitRequested(self: *const WasmHost) bool {
        return self.backing.quit_requested;
    }

    fn dispatchJs(self: *WasmHost, script: []const u8) void {
        if (self.eval_hook) |h| {
            h.callFn(h.ctx, script);
            return;
        }
        if (is_wasm and script.len > 0) {
            zts_host_eval_js(script.ptr, script.len);
        }
    }

    fn syncDocumentTitle(self: *WasmHost, title: []const u8) core.HostError!void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        aw.writer.writeAll("if(typeof document!==\"undefined\"){document.title=") catch return error.OutOfMemory;
        foundation.html_escape.writeJsonString(&aw.writer, title, true) catch return error.OutOfMemory;
        aw.writer.writeAll(";}") catch return error.OutOfMemory;
        self.dispatchJs(aw.written());
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

    inline fn cast(ptr: ?*anyopaque) *WasmHost {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn vWakeup(ptr: ?*anyopaque) void {
        cast(ptr).backing.host().wakeup();
    }

    fn vRequestQuit(ptr: ?*anyopaque) void {
        const self = cast(ptr);
        self.backing.host().requestQuit();
        self.dispatchJs("if(typeof window!==\"undefined\"&&window.__ZTS_ON_QUIT__){window.__ZTS_ON_QUIT__();}");
    }

    fn vCreateWindow(ptr: ?*anyopaque, spec: core.WindowSpec) core.HostError!core.WindowId {
        const self = cast(ptr);
        const wid = try self.backing.host().createWindow(spec);
        try self.syncDocumentTitle(spec.title);
        return wid;
    }

    fn vCloseWindow(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        return cast(ptr).backing.host().closeWindow(win);
    }

    fn vSetWindowTitle(ptr: ?*anyopaque, win: core.WindowId, title: []const u8) core.HostError!void {
        const self = cast(ptr);
        try self.backing.host().setWindowTitle(win, title);
        try self.syncDocumentTitle(title);
    }

    fn vSetWindowSize(ptr: ?*anyopaque, win: core.WindowId, size: core.LogicalSize) core.HostError!void {
        return cast(ptr).backing.host().setWindowSize(win, size);
    }

    fn vSetWindowMinSize(ptr: ?*anyopaque, win: core.WindowId, size: ?core.LogicalSize) core.HostError!void {
        return cast(ptr).backing.host().setWindowMinSize(win, size);
    }

    fn vSetWindowMaxSize(ptr: ?*anyopaque, win: core.WindowId, size: ?core.LogicalSize) core.HostError!void {
        return cast(ptr).backing.host().setWindowMaxSize(win, size);
    }

    fn vSetWindowPosition(ptr: ?*anyopaque, win: core.WindowId, pos: core.LogicalPoint) core.HostError!void {
        return cast(ptr).backing.host().setWindowPosition(win, pos);
    }

    fn vSetWindowResizable(ptr: ?*anyopaque, win: core.WindowId, resizable: bool) core.HostError!void {
        return cast(ptr).backing.host().setWindowResizable(win, resizable);
    }

    fn vSetWindowMinimized(ptr: ?*anyopaque, win: core.WindowId, minimized: bool) core.HostError!void {
        return cast(ptr).backing.host().setWindowMinimized(win, minimized);
    }

    fn vSetWindowMaximized(ptr: ?*anyopaque, win: core.WindowId, maximized: bool) core.HostError!void {
        return cast(ptr).backing.host().setWindowMaximized(win, maximized);
    }

    fn vSetWindowFullscreen(ptr: ?*anyopaque, win: core.WindowId, fullscreen: bool) core.HostError!void {
        return cast(ptr).backing.host().setWindowFullscreen(win, fullscreen);
    }

    fn vSetWindowVisible(ptr: ?*anyopaque, win: core.WindowId, visible: bool) core.HostError!void {
        return cast(ptr).backing.host().setWindowVisible(win, visible);
    }

    fn vSetWindowDecorations(ptr: ?*anyopaque, win: core.WindowId, decorations: bool) core.HostError!void {
        return cast(ptr).backing.host().setWindowDecorations(win, decorations);
    }

    fn vSetWindowAlwaysOnTop(ptr: ?*anyopaque, win: core.WindowId, on_top: bool) core.HostError!void {
        return cast(ptr).backing.host().setWindowAlwaysOnTop(win, on_top);
    }

    fn vSetWindowFocus(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        return cast(ptr).backing.host().setWindowFocus(win);
    }

    fn vStartWindowDrag(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        return cast(ptr).backing.host().startWindowDrag(win);
    }

    fn vEvalJs(ptr: ?*anyopaque, win: core.WindowId, script: []const u8) core.HostError!void {
        const self = cast(ptr);
        try self.backing.host().evalJs(win, script);
        self.dispatchJs(script);
    }

    fn vNavigate(ptr: ?*anyopaque, win: core.WindowId, url: []const u8) core.HostError!void {
        return cast(ptr).backing.host().navigate(win, url);
    }

    fn vOpenDevtools(ptr: ?*anyopaque, win: core.WindowId) core.HostError!void {
        return cast(ptr).backing.host().openDevtools(win);
    }
};
