//! Native Windows Backend — `Win32` window + Direct WebView2 (`src/webview/windows.zig`, `M3-02`).
//!
//! Pure Zig, **no C / C++ / Rust, no `@cImport`, no `WebView2Loader.dll`**: the runtime is located
//! and driven through [`webview2_loader.zig`](webview2_loader.zig) plus the hand-generated COM
//! vtables in [`webview2_com.zig`](webview2_com.zig). It mirrors [`linux.zig`](linux.zig) and
//! [`macos.zig`](macos.zig) one-for-one, so `zts_core.Host`, `zts_tauri.ProtocolRouter`,
//! `DesktopRuntime` and `examples/counter` need **zero** Windows-specific code.
//!
//! Architecture & safety guarantees:
//! 1. **Step-driven STA message pump**: `step(.blocking)` waits on an auto-reset event with
//!    `MsgWaitForMultipleObjectsEx` (1 s cap) and then drains `PeekMessage` — callers keep their
//!    `defer` scopes and 60/120 fps `.poll` loops work unchanged. `wakeup()` = `SetEvent`.
//! 2. **Async window creation**: `createWindow()` returns a `WindowId` immediately; the WebView2
//!    controller completes inside a later `step()` and *then* applies queued init scripts and
//!    navigates, so no Zig code ever blocks the STA.
//! 3. **`ICoreWebView2Deferral` isolation**: the raw COM pointers live in a main-thread-only table
//!    and Zig only ever sees `(window_id, RequestId)` + bytes — Architectural Invariant #4 from
//!    `ADR-0002` holds on Windows exactly as it does on GTK / WKWebView.
//! 4. **No custom scheme API needed**: `tauri://localhost/…` is rewritten to
//!    `http://tauri.localhost/…` (see [`windows_util.toWebView2Url`](windows_util.zig)) and served
//!    through `WebResourceRequested`, the same workaround wry/Tauri ship.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const foundation = @import("zts_foundation");
const types = @import("types.zig");
const pending_mod = @import("pending.zig");
const win32 = @import("win32.zig");
const com = @import("webview2_com.zig");
const loader = @import("webview2_loader.zig");
pub const util = @import("windows_util.zig");

/// Upper bound of request headers forwarded to Zig (same budget as the other backends).
const max_headers: usize = 48;
/// Hard cap for a single intercepted request body (mirrors the macOS shim's 64 MiB).
const max_body_bytes: usize = 64 * 1024 * 1024;
/// How long `init()` waits for the WebView2 environment.
const startup_timeout_ms: u32 = 15_000;
/// Calling convention of every COM method (`winapi` on Windows targets only — see `win32.CC`).
const CALL = win32.CC;
/// `COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL` — **`0`**, not `0xFFFFFFFF` (see `WebView2.h`:
/// `ALL = 0`, then `DOCUMENT = ALL + 1`, …). Passing `-1` here makes the browser walk an
/// out-of-range enum and crash the host process on the first `AddWebResourceRequestedFilter`.
const resource_context_all: i32 = 0;

// ---------------------------------------------------------------------------
// Window record
// ---------------------------------------------------------------------------

const PendingNav = union(enum) {
    url: []u8,
    html: []u8,

    fn deinit(self: PendingNav, allocator: Allocator) void {
        switch (self) {
            .url => |s| allocator.free(s),
            .html => |s| allocator.free(s),
        }
    }
};

const WinWindow = struct {
    backend: *WindowsWebView2Backend,
    id: types.WindowId = .invalid,
    hwnd: win32.HWND = undefined,
    parent: ?win32.HWND = null,

    controller: ?*com.ICoreWebView2Controller = null,
    webview: ?*com.ICoreWebView2 = null,
    settings: ?*com.ICoreWebView2Settings = null,
    ready: bool = false,
    closing: bool = false,
    finalized: bool = false,

    visible: bool = true,
    decorations: bool = true,
    transparent: bool = false,
    resizable: bool = true,
    always_on_top: bool = false,
    fullscreen: bool = false,
    dark: bool = true,

    min_size: ?types.LogicalSize = null,
    max_size: ?types.LogicalSize = null,

    title: []u8 = &.{},
    dpi: u32 = util.base_dpi,
    saved_style: win32.DWORD = 0,
    saved_rect: win32.RECT = .{},

    /// Applied as soon as the controller becomes ready (see `applyQueued`).
    nav_queue: std.ArrayList(PendingNav) = .empty,
    scripts: std.ArrayList([]u8) = .empty,

    token_message: i64 = 0,
    token_resource: i64 = 0,
    token_close: i64 = 0,
};

const SchemeSlot = struct {
    backend: *WindowsWebView2Backend,
    handler: types.SchemeHandler,
    scheme: []u8,
};

/// Only `(backend, token)` crosses thread boundaries; the COM pointers never leave the UI thread.
const PendingToken = struct {
    backend: *WindowsWebView2Backend,
    token: u64,

    fn cancel(self: PendingToken) void {
        self.backend.cancelDeferred(self.token);
    }
};

const Deferred = struct {
    args: *com.ICoreWebView2WebResourceRequestedEventArgs,
    deferral: *com.ICoreWebView2Deferral,
};

// ---------------------------------------------------------------------------
// COM event handler objects
// ---------------------------------------------------------------------------

const HandlerKind = enum(u32) { environment_ready, controller_ready, web_message, web_resource, window_close, noop };

var trace_state: ?bool = null;

/// `ZTS_WEBVIEW_TRACE=1` turns on the COM-stage trace below. It is the only practical way to debug
/// a silent crash inside WebView2 on a CI runner (no debugger attach, no local Windows machine).
fn traceOn() bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (trace_state) |v| return v;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("ZTS_WEBVIEW_TRACE");
    var buf: [4]u16 = undefined;
    const on = win32.GetEnvironmentVariableW(name, &buf, buf.len) > 0;
    trace_state = on;
    return on;
}

fn trace(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.os.tag != .windows) return;
    if (!traceOn()) return;
    std.debug.print("zts.windows: " ++ fmt ++ "\n", args);
}

/// Every WebView2 event handler is `{ vtable, … }` with exactly 4 vtable slots
/// (`QueryInterface`, `AddRef`, `Release`, `Invoke`). One Zig struct therefore backs all of them;
/// only the `Invoke` thunk differs, so each kind gets its own static vtable.
///
/// Handlers are never freed individually — the backend owns them and releases the whole list in
/// `deinit()`, after every controller has been closed, so a late `Invoke` from WebView2 can never
/// observe a dangling pointer.
const Handler = extern struct {
    vtable: *const anyopaque,
    refs: u32 = 1,
    backend: *WindowsWebView2Backend,
    kind: HandlerKind,
    /// `types.WindowId.toU64()` (`0` = backend-wide, e.g. the environment callback).
    ident: u64 = 0,

    fn queryInterface(self: *Handler, riid: *const com.Guid, out: *?*anyopaque) com.HResult {
        const wanted: *const com.Guid = switch (self.kind) {
            .environment_ready => &com.IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
            .controller_ready => &com.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
            .web_message => &com.IID_ICoreWebView2WebMessageReceivedEventHandler,
            .web_resource => &com.IID_ICoreWebView2WebResourceRequestedEventHandler,
            .window_close => &com.IID_ICoreWebView2WindowCloseRequestedEventHandler,
            .noop => &com.IID_IUnknown,
        };
        if (guidEql(riid, &com.IID_IUnknown) or guidEql(riid, wanted)) {
            out.* = self;
            _ = self.addRef();
            return com.S_OK;
        }
        out.* = null;
        return com.E_NOINTERFACE;
    }

    fn addRef(self: *Handler) u32 {
        self.refs += 1;
        return self.refs;
    }

    fn release(self: *Handler) u32 {
        if (self.refs > 0) self.refs -= 1;
        return self.refs;
    }
};

fn guidEql(a: *const com.Guid, b: *const com.Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn handlerBase(comptime Iface: type) type {
    return struct {
        fn query(this: *Iface, riid: *const com.Guid, out: *?*anyopaque) callconv(CALL) com.HResult {
            const self: *Handler = @ptrCast(@alignCast(this));
            return self.queryInterface(riid, out);
        }
        fn addRef(this: *Iface) callconv(CALL) u32 {
            const self: *Handler = @ptrCast(@alignCast(this));
            return self.addRef();
        }
        fn release(this: *Iface) callconv(CALL) u32 {
            const self: *Handler = @ptrCast(@alignCast(this));
            return self.release();
        }
    };
}

const EnvIface = com.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
const ControllerIface = com.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler;
const MessageIface = com.ICoreWebView2WebMessageReceivedEventHandler;
const ResourceIface = com.ICoreWebView2WebResourceRequestedEventHandler;
const CloseIface = com.ICoreWebView2WindowCloseRequestedEventHandler;

fn envInvoke(
    this: *EnvIface,
    hr: com.HResult,
    env: ?*com.ICoreWebView2Environment,
) callconv(CALL) com.HResult {
    const self: *Handler = @ptrCast(@alignCast(this));
    return self.backend.onEnvironmentCreated(hr, env);
}

fn controllerInvoke(
    this: *ControllerIface,
    hr: com.HResult,
    controller: ?*com.ICoreWebView2Controller,
) callconv(CALL) com.HResult {
    const self: *Handler = @ptrCast(@alignCast(this));
    return self.backend.onControllerCreated(self.ident, hr, controller);
}

fn messageInvoke(
    this: *MessageIface,
    sender: ?*com.ICoreWebView2,
    args: ?*com.ICoreWebView2WebMessageReceivedEventArgs,
) callconv(CALL) com.HResult {
    _ = sender;
    const self: *Handler = @ptrCast(@alignCast(this));
    return self.backend.onWebMessage(self.ident, args);
}

fn resourceInvoke(
    this: *ResourceIface,
    sender: ?*com.ICoreWebView2,
    args: ?*com.ICoreWebView2WebResourceRequestedEventArgs,
) callconv(CALL) com.HResult {
    _ = sender;
    const self: *Handler = @ptrCast(@alignCast(this));
    return self.backend.onWebResourceRequested(self.ident, args);
}

fn closeInvoke(
    this: *CloseIface,
    sender: ?*com.ICoreWebView2,
    args: ?*anyopaque,
) callconv(CALL) com.HResult {
    _ = sender;
    _ = args;
    const self: *Handler = @ptrCast(@alignCast(this));
    return self.backend.onWindowCloseRequested(self.ident);
}

fn noopInvoke(this: *Handler, a: ?*anyopaque, b: ?*anyopaque) callconv(CALL) com.HResult {
    _ = this;
    _ = a;
    _ = b;
    return com.S_OK;
}

/// Generic 4-slot vtable used for callbacks whose result Zig never inspects
/// (`AddScriptToExecuteOnDocumentCreated`, `ExecuteScript`). Passing `null` instead makes some
/// WebView2 builds unhappy, and a real object keeps every call site uniform.
const noop_vtable = extern struct {
    QueryInterface: *const fn (*Handler, *const com.Guid, *?*anyopaque) callconv(CALL) com.HResult,
    AddRef: *const fn (*Handler) callconv(CALL) u32,
    Release: *const fn (*Handler) callconv(CALL) u32,
    Invoke: *const fn (*Handler, ?*anyopaque, ?*anyopaque) callconv(CALL) com.HResult,
}{
    .QueryInterface = struct {
        fn f(this: *Handler, riid: *const com.Guid, out: *?*anyopaque) callconv(CALL) com.HResult {
            if (guidEql(riid, &com.IID_IUnknown)) {
                out.* = this;
                _ = this.addRef();
                return com.S_OK;
            }
            out.* = null;
            return com.E_NOINTERFACE;
        }
    }.f,
    .AddRef = struct {
        fn f(this: *Handler) callconv(CALL) u32 {
            return this.addRef();
        }
    }.f,
    .Release = struct {
        fn f(this: *Handler) callconv(CALL) u32 {
            return this.release();
        }
    }.f,
    .Invoke = noopInvoke,
};

const env_vtable = EnvIface.VTable{
    .QueryInterface = handlerBase(EnvIface).query,
    .AddRef = handlerBase(EnvIface).addRef,
    .Release = handlerBase(EnvIface).release,
    .Invoke = envInvoke,
};

const controller_vtable = ControllerIface.VTable{
    .QueryInterface = handlerBase(ControllerIface).query,
    .AddRef = handlerBase(ControllerIface).addRef,
    .Release = handlerBase(ControllerIface).release,
    .Invoke = controllerInvoke,
};

const message_vtable = MessageIface.VTable{
    .QueryInterface = handlerBase(MessageIface).query,
    .AddRef = handlerBase(MessageIface).addRef,
    .Release = handlerBase(MessageIface).release,
    .Invoke = messageInvoke,
};

const resource_vtable = ResourceIface.VTable{
    .QueryInterface = handlerBase(ResourceIface).query,
    .AddRef = handlerBase(ResourceIface).addRef,
    .Release = handlerBase(ResourceIface).release,
    .Invoke = resourceInvoke,
};

const close_vtable = CloseIface.VTable{
    .QueryInterface = handlerBase(CloseIface).query,
    .AddRef = handlerBase(CloseIface).addRef,
    .Release = handlerBase(CloseIface).release,
    .Invoke = closeInvoke,
};

// ---------------------------------------------------------------------------
// The backend
// ---------------------------------------------------------------------------

pub const WindowsWebView2Backend = struct {
    allocator: Allocator,
    io: Io,

    runtime: loader.Runtime,
    com_initialized: bool = false,
    class_atom: win32.ATOM = 0,
    class_name: []u8 = &.{},
    wakeup_event: win32.HANDLE,

    env: ?*com.ICoreWebView2Environment = null,
    env_failed: bool = false,

    windows: foundation.HandlePool(*WinWindow, .window) = .empty,
    scheme_slots: std.ArrayList(*SchemeSlot) = .empty,
    pending: pending_mod.PendingTable(PendingToken) = .{},
    completions: pending_mod.CompletionQueue,
    deferred: std.AutoHashMapUnmanaged(u64, Deferred) = .empty,
    next_token: u64 = 1,
    handlers: std.ArrayList(*Handler) = .empty,

    message_handler: ?types.MessageHandler = null,
    close_handler: ?types.CloseHandler = null,

    quit: bool = false,
    had_windows: bool = false,
    shutting_down: bool = false,
    preflight_count: u64 = 0,

    // -- lifecycle ---------------------------------------------------------

    pub fn init(allocator: Allocator, io: Io) types.WebviewError!*WindowsWebView2Backend {
        _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

        // WebView2 requires an STA. `RPC_E_CHANGED_MODE` means the caller already initialized an MTA
        // (e.g. inside another library) and the browser can never be hosted — fail loudly instead.
        const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
        if (hr == win32.RPC_E_CHANGED_MODE) return error.PlatformFailure;
        const com_initialized = !com.failed(hr);

        const runtime = loader.load(allocator) catch |err| {
            if (com_initialized) win32.CoUninitialize();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // No Evergreen runtime / no `EmbeddedBrowserWebView.dll` → same code as a headless
                // Linux box without a display, so `Engine.init(.native)` degrades identically.
                error.RuntimeNotFound => error.DisplayUnavailable,
                else => error.PlatformFailure,
            };
        };

        const event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse {
            var rt = runtime;
            rt.deinit(allocator);
            if (com_initialized) win32.CoUninitialize();
            return error.PlatformFailure;
        };

        const self = allocator.create(WindowsWebView2Backend) catch {
            var rt = runtime;
            rt.deinit(allocator);
            _ = win32.CloseHandle(event);
            if (com_initialized) win32.CoUninitialize();
            return error.OutOfMemory;
        };
        self.* = .{
            .allocator = allocator,
            .io = io,
            .runtime = runtime,
            .com_initialized = com_initialized,
            .wakeup_event = event,
            .completions = pending_mod.CompletionQueue.init(allocator, io),
        };
        errdefer self.deinit();

        try self.registerWindowClass();
        try self.startEnvironment();
        return self;
    }

    fn registerWindowClass(self: *WindowsWebView2Backend) types.WebviewError!void {
        const name = std.fmt.allocPrint(self.allocator, "ZtsWebView2Window.{x}", .{@intFromPtr(self)}) catch
            return error.OutOfMemory;
        errdefer self.allocator.free(name);
        const name_z = win32.toWide(self.allocator, name) catch return error.OutOfMemory;
        defer self.allocator.free(name_z);

        const cls = win32.WNDCLASSEXW{
            .lpfnWndProc = wndProc,
            .hInstance = win32.GetModuleHandleW(null),
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .lpszClassName = name_z.ptr,
        };
        if (win32.RegisterClassExW(&cls) == 0) return error.PlatformFailure;

        self.class_atom = 1; // any non-zero marker: `UnregisterClassW` only needs the name
        self.class_name = name;
    }

    /// Creates the WebView2 environment and pumps the STA queue until the callback lands.
    fn startEnvironment(self: *WindowsWebView2Backend) types.WebviewError!void {
        const handler = try self.newHandler(.environment_ready, 0);

        const runtime_type: i32 = if (self.runtime.fixed) loader.RUNTIME_TYPE_FIXED else loader.RUNTIME_TYPE_INSTALLED;
        const hr = self.runtime.create(
            win32.TRUE, // `fromClientDll` — the lite loader is linked in-process
            runtime_type,
            null, // default user-data folder (`<exe>.WebView2`)
            null,
            @ptrCast(handler),
        );
        if (com.failed(hr)) return error.PlatformFailure;

        if (!self.waitForEnvironment()) {
            if (self.env) |env| {
                _ = env.vtable.Release(env);
                self.env = null;
            }
            return if (self.env_failed) error.PlatformFailure else error.DisplayUnavailable;
        }
    }

    fn waitForEnvironment(self: *WindowsWebView2Backend) bool {
        var waited: u32 = 0;
        while (waited < startup_timeout_ms) : (waited += 50) {
            self.pumpMessages();
            if (self.env != null) return true;
            if (self.env_failed) return false;
            _ = win32.MsgWaitForMultipleObjectsEx(1, &self.wakeup_event, 50, win32.QS_ALLINPUT, 0);
            _ = win32.ResetEvent(self.wakeup_event);
        }
        return self.env != null;
    }

    pub fn deinit(self: *WindowsWebView2Backend) void {
        self.shutting_down = true;
        self.message_handler = null;
        self.close_handler = null;

        // 1. Cancel in-flight requests; every deferral is completed so WebView2 is never left hanging.
        self.pending.deinitWith(self.allocator, PendingToken.cancel);
        self.clearDeferred();
        self.completions.deinit();

        // 2. Close every controller (releases the browser process for this HWND) before the windows die.
        var it = self.windows.iterator();
        while (it.next()) |slot| self.destroyWebView(slot.value_ptr.*);
        self.pumpMessages();

        // 3. Destroy the remaining native windows, detaching the user-data pointer first so
        //    `wndProc` cannot re-enter `finalizeWindow` for a record that is already freed.
        while (true) {
            var wit = self.windows.iterator();
            const first = wit.next() orelse break;
            const w = first.value_ptr.*;
            w.finalized = true;
            _ = win32.SetWindowLongPtrW(w.hwnd, win32.GWLP_USERDATA, 0);
            _ = win32.DestroyWindow(w.hwnd);
            _ = self.windows.release(first.handle) catch {};
            freeWindow(self.allocator, w);
        }
        self.windows.deinit(self.allocator);
        self.pumpMessages();

        for (self.scheme_slots.items) |slot| {
            self.allocator.free(slot.scheme);
            self.allocator.destroy(slot);
        }
        self.scheme_slots.deinit(self.allocator);

        for (self.handlers.items) |h| self.allocator.destroy(h);
        self.handlers.deinit(self.allocator);

        if (self.env) |env| {
            _ = env.vtable.Release(env);
            self.env = null;
        }

        if (self.class_name.len > 0) {
            if (win32.toWide(self.allocator, self.class_name) catch null) |z| {
                _ = win32.UnregisterClassW(z.ptr, win32.GetModuleHandleW(null));
                self.allocator.free(z);
            }
            self.allocator.free(self.class_name);
            self.class_name = &.{};
        }

        _ = win32.CloseHandle(self.wakeup_event);
        self.runtime.deinit(self.allocator);
        if (self.com_initialized) win32.CoUninitialize();

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    // -- helpers -----------------------------------------------------------

    fn newHandler(self: *WindowsWebView2Backend, kind: HandlerKind, ident: u64) types.WebviewError!*Handler {
        const h = self.allocator.create(Handler) catch return error.OutOfMemory;
        h.* = .{
            .vtable = switch (kind) {
                .environment_ready => &env_vtable,
                .controller_ready => &controller_vtable,
                .web_message => &message_vtable,
                .web_resource => &resource_vtable,
                .window_close => &close_vtable,
                .noop => &noop_vtable,
            },
            .backend = self,
            .kind = kind,
            .ident = ident,
        };
        self.handlers.append(self.allocator, h) catch {
            self.allocator.destroy(h);
            return error.OutOfMemory;
        };
        return h;
    }

    fn pumpMessages(self: *WindowsWebView2Backend) void {
        var msg: win32.MSG = .{};
        while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
            if (msg.message == win32.WM_QUIT) {
                self.quit = true;
                return;
            }
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
    }

    fn windowByIdent(self: *WindowsWebView2Backend, ident: u64) ?*WinWindow {
        if (ident == 0) return null;
        var it = self.windows.iterator();
        while (it.next()) |slot| {
            if (slot.value_ptr.*.id.toU64() == ident) return slot.value_ptr.*;
        }
        return null;
    }

    fn requireWindow(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!*WinWindow {
        const slot = self.windows.get(win_id) orelse return error.WindowNotFound;
        return @constCast(slot.*);
    }

    // -- event loop --------------------------------------------------------

    pub fn step(self: *WindowsWebView2Backend, mode: types.StepMode) bool {
        self.drainCompletions();
        if (self.quit) return false;

        if (mode == .blocking) {
            _ = win32.MsgWaitForMultipleObjectsEx(1, &self.wakeup_event, 1000, win32.QS_ALLINPUT, 0);
            _ = win32.ResetEvent(self.wakeup_event);
        }
        self.pumpMessages();
        self.drainCompletions();

        if (self.quit) return false;
        if (self.had_windows and self.windows.count() == 0) return false;
        return true;
    }

    pub fn wakeup(self: *WindowsWebView2Backend) void {
        _ = win32.SetEvent(self.wakeup_event);
    }

    pub fn requestQuit(self: *WindowsWebView2Backend) void {
        self.quit = true;
        self.wakeup();
    }

    pub fn quitRequested(self: *WindowsWebView2Backend) bool {
        return self.quit;
    }

    /// Number of CORS preflights (`OPTIONS`) absorbed before reaching Zig — the same metric the
    /// macOS shim exposes, so CI markers stay comparable across backends.
    pub fn preflightCount(self: *WindowsWebView2Backend) u64 {
        return self.preflight_count;
    }

    // -- COM callbacks -----------------------------------------------------

    fn onEnvironmentCreated(
        self: *WindowsWebView2Backend,
        hr: com.HResult,
        env: ?*com.ICoreWebView2Environment,
    ) com.HResult {
        const e = env orelse {
            self.env_failed = true;
            return com.S_OK;
        };
        if (com.failed(hr)) {
            self.env_failed = true;
            return com.S_OK;
        }
        _ = e.vtable.AddRef(e);
        self.env = e;
        return com.S_OK;
    }

    fn onControllerCreated(
        self: *WindowsWebView2Backend,
        ident: u64,
        hr: com.HResult,
        controller: ?*com.ICoreWebView2Controller,
    ) com.HResult {
        const w = self.windowByIdent(ident) orelse return com.S_OK;
        const c = controller orelse return com.S_OK;
        if (com.failed(hr) or w.closing) return com.S_OK;
        trace("controller created hr={d}", .{hr});

        _ = c.vtable.AddRef(c);
        w.controller = c;

        var webview: ?*com.ICoreWebView2 = null;
        if (com.failed(c.vtable.get_CoreWebView2(c, &webview))) return com.S_OK;
        const wv = webview orelse return com.S_OK;
        w.webview = wv;
        trace("get_CoreWebView2 ok", .{});

        self.applyBackground(w);
        trace("background applied", .{});
        _ = c.vtable.put_IsVisible(c, if (w.visible) win32.TRUE else win32.FALSE);
        trace("visible applied", .{});
        self.configureWebView(w);
        trace("webview configured", .{});
        self.resizeWebView(w);
        trace("bounds applied", .{});

        w.ready = true;
        self.applyQueued(w);
        trace("queued navigation applied", .{});
        return com.S_OK;
    }

    /// `ICoreWebView2Controller2::put_DefaultBackgroundColor` — transparency & solid backgrounds.
    fn applyBackground(self: *WindowsWebView2Backend, w: *WinWindow) void {
        const c = w.controller orelse return;
        var raw: ?*anyopaque = null;
        if (com.failed(c.vtable.QueryInterface(c, &com.IID_ICoreWebView2Controller2, &raw))) return;
        const c2: *com.ICoreWebView2Controller2 = @ptrCast(@alignCast(raw.?));
        defer _ = c2.vtable.Release(c2);
        const color: com.Color = if (w.transparent) com.transparent else .{};
        _ = c2.vtable.put_DefaultBackgroundColor(c2, color);
        _ = self;
    }

    fn configureWebView(self: *WindowsWebView2Backend, w: *WinWindow) void {
        const wv = w.webview orelse return;

        var settings: ?*com.ICoreWebView2Settings = null;
        if (!com.failed(wv.vtable.get_Settings(wv, &settings))) {
            if (settings) |s| {
                w.settings = s;
                _ = s.vtable.put_AreDevToolsEnabled(s, win32.TRUE); // Zig decides via `devtools` below
                _ = s.vtable.put_IsStatusBarEnabled(s, win32.FALSE);
                _ = s.vtable.put_IsScriptEnabled(s, win32.TRUE);
                _ = s.vtable.put_IsWebMessageEnabled(s, win32.TRUE);
            }
        }
        trace("settings applied", .{});

        // One JS surface for every backend: the shared bootstrap calls `__ztsPostMessage`.
        self.addDocumentScript(w, "window.__ztsPostMessage = (m) => window.chrome.webview.postMessage(typeof m === 'string' ? m : JSON.stringify(m));");

        const message_handler = self.newHandler(.web_message, w.id.toU64()) catch return;
        const message_hr = wv.vtable.add_WebMessageReceived(wv, @ptrCast(message_handler), &w.token_message);
        trace("add_WebMessageReceived hr={d} token={d}", .{ message_hr, w.token_message });

        const resource_handler = self.newHandler(.web_resource, w.id.toU64()) catch return;
        const resource_hr = wv.vtable.add_WebResourceRequested(wv, @ptrCast(resource_handler), &w.token_resource);
        trace("add_WebResourceRequested hr={d} token={d}", .{ resource_hr, w.token_resource });

        for ([_]util.Protocol{ .tauri, .ipc, .asset }) |protocol| {
            var pattern_buf: [64]u8 = undefined;
            const pattern = util.filterPattern(&pattern_buf, protocol) catch continue;
            const z = win32.toWide(self.allocator, pattern) catch continue;
            defer self.allocator.free(z);
            const filter_hr = wv.vtable.AddWebResourceRequestedFilter(wv, z.ptr, resource_context_all);
            trace("AddWebResourceRequestedFilter {s} hr={d}", .{ pattern, filter_hr });
        }

        const close_handler = self.newHandler(.window_close, w.id.toU64()) catch return;
        const close_hr = wv.vtable.add_WindowCloseRequested(wv, @ptrCast(close_handler), &w.token_close);
        trace("add_WindowCloseRequested hr={d}", .{close_hr});
    }

    fn addDocumentScript(self: *WindowsWebView2Backend, w: *WinWindow, script: []const u8) void {
        const wv = w.webview orelse return;
        const z = win32.toWide(self.allocator, script) catch return;
        defer self.allocator.free(z);
        // A real (no-op) completion object rather than `null`: some WebView2 builds dereference the
        // handler unconditionally on the document-created path.
        const handler = self.newHandler(.noop, w.id.toU64()) catch return;
        const hr = wv.vtable.AddScriptToExecuteOnDocumentCreated(wv, z.ptr, @ptrCast(handler));
        trace("AddScriptToExecuteOnDocumentCreated hr={d} len={d}", .{ hr, script.len });
    }

    fn applyQueued(self: *WindowsWebView2Backend, w: *WinWindow) void {
        for (w.scripts.items) |script| self.addDocumentScript(w, script);
        for (w.scripts.items) |script| self.allocator.free(script);
        w.scripts.clearRetainingCapacity();

        for (w.nav_queue.items) |nav| {
            switch (nav) {
                .url => |u| self.navigate(w.id, u) catch {},
                .html => |h| self.loadHtml(w.id, h, null) catch {},
            }
            nav.deinit(self.allocator);
        }
        w.nav_queue.clearRetainingCapacity();
    }

    fn onWebMessage(
        self: *WindowsWebView2Backend,
        ident: u64,
        args: ?*com.ICoreWebView2WebMessageReceivedEventArgs,
    ) com.HResult {
        const a = args orelse return com.S_OK;
        const w = self.windowByIdent(ident) orelse return com.S_OK;

        var wide: ?com.PWStr = null;
        if (com.failed(a.vtable.TryGetWebMessageAsString(a, &wide)) or wide == null) {
            wide = null;
            if (com.failed(a.vtable.get_WebMessageAsJson(a, &wide)) or wide == null) return com.S_OK;
        }
        const text = win32.fromWide(self.allocator, wide.?, true) catch return com.S_OK;
        defer self.allocator.free(text);

        if (self.message_handler) |mh| mh.call(w.id, text);
        return com.S_OK;
    }

    fn onWindowCloseRequested(self: *WindowsWebView2Backend, ident: u64) com.HResult {
        if (self.windowByIdent(ident)) |w| self.beginClose(w);
        return com.S_OK;
    }

    fn onWebResourceRequested(
        self: *WindowsWebView2Backend,
        ident: u64,
        args_opt: ?*com.ICoreWebView2WebResourceRequestedEventArgs,
    ) com.HResult {
        const args = args_opt orelse return com.S_OK;
        const w = self.windowByIdent(ident) orelse return com.S_OK;
        if (self.shutting_down) return com.S_OK;
        const env = self.env orelse return com.S_OK;

        // Scratch arena: request slices handed to Zig only need to live for `handler.call`.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        var request: ?*com.ICoreWebView2WebResourceRequest = null;
        if (com.failed(args.vtable.get_Request(args, &request))) return com.S_OK;
        const req = request orelse return com.S_OK;
        defer _ = req.vtable.Release(req);

        var uri_w: ?com.PWStr = null;
        if (com.failed(req.vtable.get_Uri(req, &uri_w)) or uri_w == null) return com.S_OK;
        const uri = win32.fromWide(scratch, uri_w.?, true) catch return com.S_OK;

        const protocol = classifyVirtualOrigin(uri) orelse return com.S_OK;

        var method_w: ?com.PWStr = null;
        if (com.failed(req.vtable.get_Method(req, &method_w)) or method_w == null) return com.S_OK;
        const method = win32.fromWide(scratch, method_w.?, true) catch return com.S_OK;
        trace("request {s} {s}", .{ method, uri });

        // CORS preflight never reaches Zig (same policy as the macOS shim / Tauri's protocol.rs).
        if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
            self.preflight_count += 1;
            self.sendBuilt(args, env, 204, "No Content", "text/plain", &preflight_pairs, &.{}, "");
            return com.S_OK;
        }

        const slot = self.schemeSlot(@tagName(protocol)) orelse {
            self.sendBuilt(args, env, 404, "Not Found", "text/plain", &.{}, &.{}, "no scheme handler registered");
            return com.S_OK;
        };

        var headers: [max_headers]types.HeaderPair = undefined;
        const header_count = self.readHeaders(scratch, req, &headers);
        const body = self.readRequestBody(scratch, req) orelse "";

        var deferral: ?*com.ICoreWebView2Deferral = null;
        if (com.failed(args.vtable.GetDeferral(args, &deferral))) return com.S_OK;
        const def = deferral orelse return com.S_OK;
        trace("deferral acquired", .{});

        const token = self.next_token;
        self.next_token += 1;

        _ = args.vtable.AddRef(args);
        self.deferred.put(self.allocator, token, .{ .args = args, .deferral = def }) catch {
            _ = def.vtable.Release(def);
            _ = args.vtable.Release(args);
            return com.S_OK;
        };

        const req_id = self.pending.insert(
            self.allocator,
            w.id,
            .{ .backend = self, .token = token },
        ) catch {
            self.cancelDeferred(token);
            return com.S_OK;
        };

        slot.handler.call(.{
            .request_id = req_id,
            .window_id = w.id,
            .scheme = slot.scheme,
            .method = method,
            .uri = uri,
            .headers = headers[0..header_count],
            .body = body,
        });

        trace("handler dispatched", .{});
        // A handler that answered synchronously (`completeRequest` inside `call`) never yields back
        // to the message loop, so flush right here instead of waiting for the next `step()`.
        self.drainCompletions();
        trace("completion drained", .{});
        return com.S_OK;
    }

    fn schemeSlot(self: *WindowsWebView2Backend, scheme: []const u8) ?*SchemeSlot {
        for (self.scheme_slots.items) |slot| {
            if (std.ascii.eqlIgnoreCase(slot.scheme, scheme)) return slot;
        }
        return null;
    }

    fn readHeaders(
        self: *WindowsWebView2Backend,
        scratch: Allocator,
        req: *com.ICoreWebView2WebResourceRequest,
        out: *[max_headers]types.HeaderPair,
    ) usize {
        _ = self;
        var collection: ?*com.ICoreWebView2HttpRequestHeaders = null;
        if (com.failed(req.vtable.get_Headers(req, &collection))) return 0;
        const headers = collection orelse return 0;
        defer _ = headers.vtable.Release(headers);

        var iterator: ?*com.ICoreWebView2HttpHeadersCollectionIterator = null;
        if (com.failed(headers.vtable.GetIterator(headers, &iterator))) return 0;
        const it = iterator orelse return 0;
        defer _ = it.vtable.Release(it);

        var count: usize = 0;
        var has_current: com.BOOL = 0;
        if (com.failed(it.vtable.get_HasCurrentHeader(it, &has_current))) return 0;
        while (has_current != 0 and count < max_headers) {
            var name: ?com.PWStr = null;
            var value: ?com.PWStr = null;
            if (!com.failed(it.vtable.GetCurrentHeader(it, &name, &value))) {
                if (name != null and value != null) {
                    const n = win32.fromWide(scratch, name.?, true) catch "";
                    const v = win32.fromWide(scratch, value.?, true) catch "";
                    if (n.len != 0) {
                        out[count] = .{ .name = n, .value = v };
                        count += 1;
                    }
                }
            }
            if (com.failed(it.vtable.MoveNext(it, &has_current))) break;
        }
        return count;
    }

    fn readRequestBody(
        self: *WindowsWebView2Backend,
        scratch: Allocator,
        req: *com.ICoreWebView2WebResourceRequest,
    ) ?[]u8 {
        _ = self;
        var stream: ?*anyopaque = null;
        if (com.failed(req.vtable.get_Content(req, &stream))) return null;
        const raw = stream orelse return null;
        const st: *win32.IStream = @ptrCast(@alignCast(raw));
        defer _ = st.vtable.Release(st);

        var list: std.ArrayList(u8) = .empty;
        var buf: [8192]u8 = undefined;
        while (true) {
            var read: u32 = 0;
            const hr = st.vtable.Read(st, &buf, @intCast(buf.len), &read);
            if (com.failed(hr) or read == 0) break;
            const n: usize = @intCast(read);
            if (list.items.len + n > max_body_bytes) break;
            list.appendSlice(scratch, buf[0..n]) catch break;
        }
        return list.items;
    }

    // -- responses ---------------------------------------------------------

    const cors_pairs = [_]types.HeaderPair{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        .{ .name = "Access-Control-Expose-Headers", .value = "Tauri-Response, Tauri-Error, Content-Type, Content-Length" },
    };

    /// Everything a preflight needs *on top of* `cors_pairs` — never repeat a header that
    /// `headerBlock` already emits: two `Access-Control-Allow-Origin` values make Chromium reject
    /// the preflight ("contains multiple values"), so the real request is never sent and the page
    /// only sees `TypeError: Failed to fetch`.
    const preflight_pairs = [_]types.HeaderPair{
        .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, PATCH, DELETE, OPTIONS" },
        .{ .name = "Access-Control-Allow-Headers", .value = "*" },
        .{ .name = "Access-Control-Allow-Private-Network", .value = "true" },
        .{ .name = "Access-Control-Max-Age", .value = "86400" },
    };

    fn appendHeader(
        self: *WindowsWebView2Backend,
        out: *std.ArrayList(u8),
        name: []const u8,
        value: []const u8,
    ) std.mem.Allocator.Error!void {
        try appendHeaderLine(out, self.allocator, name, value);
    }

    /// Serialises the mandatory CORS headers + `Content-Type` + handler-provided headers into the
    /// single CRLF block `ICoreWebView2Environment::CreateWebResourceResponse` expects.
    fn headerBlock(
        self: *WindowsWebView2Backend,
        out: *std.ArrayList(u8),
        content_type: []const u8,
        pairs: []const types.HeaderPair,
        owned: []const types.QueuedCompletion.OwnedHeader,
    ) std.mem.Allocator.Error!void {
        for (cors_pairs) |h| try self.appendHeader(out, h.name, h.value);
        if (content_type.len != 0) try self.appendHeader(out, "Content-Type", content_type);
        try self.appendHeader(out, "Cache-Control", "no-store");
        for (pairs) |h| try self.appendHeader(out, h.name, h.value);
        for (owned) |h| try self.appendHeader(out, h.name, h.value);
    }

    fn sendBuilt(
        self: *WindowsWebView2Backend,
        args: *com.ICoreWebView2WebResourceRequestedEventArgs,
        env: *com.ICoreWebView2Environment,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        pairs: []const types.HeaderPair,
        owned: []const types.QueuedCompletion.OwnedHeader,
        body: []const u8,
    ) void {
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(self.allocator);
        self.headerBlock(&block, content_type, pairs, owned) catch return;
        self.sendResponse(args, env, status, reason, block.items, body);
    }

    fn sendResponse(
        self: *WindowsWebView2Backend,
        args: *com.ICoreWebView2WebResourceRequestedEventArgs,
        env: *com.ICoreWebView2Environment,
        status: u16,
        reason: []const u8,
        headers: []const u8,
        body: []const u8,
    ) void {
        const headers_z = win32.toWide(self.allocator, headers) catch return;
        defer self.allocator.free(headers_z);
        const reason_z = win32.toWide(self.allocator, reason) catch return;
        defer self.allocator.free(reason_z);

        // `SHCreateMemStream` copies the bytes into its own buffer, so `body` may be freed right away.
        const stream = if (body.len > 0)
            win32.SHCreateMemStream(body.ptr, @intCast(@min(body.len, @as(usize, std.math.maxInt(u32)))))
        else
            null;
        defer if (stream) |s| {
            const ist: *win32.IStream = @ptrCast(@alignCast(s));
            _ = ist.vtable.Release(ist);
        };

        trace("CreateWebResourceResponse status={d} body={d}", .{ status, body.len });
        var response: ?*com.ICoreWebView2WebResourceResponse = null;
        if (com.failed(env.vtable.CreateWebResourceResponse(
            env,
            stream,
            @intCast(status),
            reason_z.ptr,
            headers_z.ptr,
            &response,
        ))) return;
        const r = response orelse return;
        const put_hr = args.vtable.put_Response(args, r);
        _ = r.vtable.Release(r);
        trace("put_Response hr={d}", .{put_hr});
    }

    /// Called on the main thread for every completed request (possibly submitted by a worker).
    fn completeDeferred(self: *WindowsWebView2Backend, token: u64, item: *const types.QueuedCompletion) void {
        const entry = self.deferred.fetchRemove(token) orelse return;
        if (self.env) |env| {
            self.sendBuilt(
                entry.value.args,
                env,
                item.status_code,
                reasonPhrase(item.status_code),
                item.content_type,
                &.{},
                item.extra_headers,
                item.body.slice(),
            );
        }
        _ = entry.value.deferral.vtable.Complete(entry.value.deferral);
        _ = entry.value.deferral.vtable.Release(entry.value.deferral);
        _ = entry.value.args.vtable.Release(entry.value.args);
    }

    fn reasonPhrase(status: u16) []const u8 {
        return switch (status) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            206 => "Partial Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            413 => "Payload Too Large",
            415 => "Unsupported Media Type",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "OK",
        };
    }

    /// Queues `resp` for the main thread (safe from ANY thread) and wakes the STA message loop.
    pub fn completeRequest(
        self: *WindowsWebView2Backend,
        req_id: types.RequestId,
        resp: types.SchemeResponse,
    ) types.WebviewError!void {
        self.completions.push(req_id, resp) catch return error.OutOfMemory;
        self.wakeup();
    }

    fn drainCompletions(self: *WindowsWebView2Backend) void {
        while (self.completions.tryPop()) |item_val| {
            var item = item_val;
            defer item.deinit(self.allocator);

            const entry = self.pending.take(item.request_id) orelse continue; // canceled / stale
            self.completeDeferred(entry.payload.token, &item);
        }
    }

    fn cancelDeferred(self: *WindowsWebView2Backend, token: u64) void {
        const entry = self.deferred.fetchRemove(token) orelse return;
        if (self.env) |env| {
            self.sendBuilt(entry.value.args, env, 503, "Service Unavailable", "text/plain", &.{}, &.{}, "request canceled");
        }
        _ = entry.value.deferral.vtable.Complete(entry.value.deferral);
        _ = entry.value.deferral.vtable.Release(entry.value.deferral);
        _ = entry.value.args.vtable.Release(entry.value.args);
    }

    fn clearDeferred(self: *WindowsWebView2Backend) void {
        var it = self.deferred.iterator();
        while (it.next()) |entry| {
            _ = entry.value_ptr.deferral.vtable.Complete(entry.value_ptr.deferral);
            _ = entry.value_ptr.deferral.vtable.Release(entry.value_ptr.deferral);
            _ = entry.value_ptr.args.vtable.Release(entry.value_ptr.args);
        }
        self.deferred.deinit(self.allocator);
    }

    // -- custom URI schemes ------------------------------------------------

    pub fn registerScheme(
        self: *WindowsWebView2Backend,
        scheme: []const u8,
        handler: types.SchemeHandler,
    ) types.WebviewError!void {
        if (scheme.len == 0) return error.InvalidArgument;
        for (self.scheme_slots.items) |slot| {
            if (std.ascii.eqlIgnoreCase(slot.scheme, scheme)) return; // idempotent, like GTK
        }
        const name = self.allocator.dupe(u8, scheme) catch return error.OutOfMemory;
        errdefer self.allocator.free(name);
        const slot = self.allocator.create(SchemeSlot) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(slot);
        slot.* = .{ .backend = self, .handler = handler, .scheme = name };
        self.scheme_slots.append(self.allocator, slot) catch return error.OutOfMemory;
    }

    pub fn setMessageHandler(self: *WindowsWebView2Backend, handler: ?types.MessageHandler) void {
        self.message_handler = handler;
    }

    pub fn setCloseHandler(self: *WindowsWebView2Backend, handler: ?types.CloseHandler) void {
        self.close_handler = handler;
    }

    // -- windows -----------------------------------------------------------

    pub fn createWindow(self: *WindowsWebView2Backend, cfg: types.WindowConfig) types.WebviewError!types.WindowId {
        if (self.env == null) return error.PlatformFailure;

        const w = self.allocator.create(WinWindow) catch return error.OutOfMemory;
        w.* = .{
            .backend = self,
            .hwnd = undefined,
            .parent = cfg.parent_native_handle,
            .visible = cfg.visible,
            .decorations = cfg.decorations,
            .transparent = cfg.transparent,
            .resizable = cfg.resizable,
            .always_on_top = cfg.always_on_top,
            .min_size = cfg.min_size,
            .max_size = cfg.max_size,
            .title = self.allocator.dupe(u8, cfg.title) catch {
                self.allocator.destroy(w);
                return error.OutOfMemory;
            },
        };

        var acquired = false;
        errdefer if (!acquired) freeWindow(self.allocator, w);

        const id = self.windows.acquire(self.allocator, w) catch {
            acquired = true; // ownership moved into the pool? no — keep the errdefer honest
            return error.OutOfMemory;
        };
        acquired = true;
        w.id = id;
        errdefer {
            _ = self.windows.release(id) catch {};
            freeWindow(self.allocator, w);
        }

        const title_z = win32.toWide(self.allocator, cfg.title) catch return error.OutOfMemory;
        defer self.allocator.free(title_z);
        const class_z = win32.toWide(self.allocator, self.class_name) catch return error.OutOfMemory;
        defer self.allocator.free(class_z);

        const style = windowStyle(w);
        const ex_style = windowExStyle(w);

        var rect = win32.RECT{
            .left = 0,
            .top = 0,
            .right = util.logicalToPhysical(cfg.size.width.v, w.dpi),
            .bottom = util.logicalToPhysical(cfg.size.height.v, w.dpi),
        };
        _ = win32.AdjustWindowRectEx(&rect, style, win32.FALSE, ex_style);

        var x: i32 = if (cfg.position) |p| util.logicalToPhysical(p.x.v, w.dpi) else win32.CW_USEDEFAULT;
        var y: i32 = if (cfg.position) |p| util.logicalToPhysical(p.y.v, w.dpi) else win32.CW_USEDEFAULT;

        // Overlay embedding (`M3-03`): a `WS_CHILD` window is positioned inside its parent's client
        // area, so the requested size means nothing — fill the host instead (toplevel windows keep
        // the normal `AdjustWindowRectEx` outer size).
        if (w.parent) |parent| {
            var client: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (win32.GetClientRect(parent, &client) != 0 and client.right > 0 and client.bottom > 0) {
                rect.right = client.right;
                rect.bottom = client.bottom;
            }
            x = 0;
            y = 0;
        }

        const hwnd = win32.CreateWindowExW(
            ex_style,
            class_z.ptr,
            title_z.ptr,
            style,
            x,
            y,
            @max(1, rect.width()),
            @max(1, rect.height()),
            w.parent,
            null,
            win32.GetModuleHandleW(null),
            w,
        ) orelse return error.PlatformFailure;

        w.hwnd = hwnd;
        w.saved_style = style;
        const hwnd_dpi = win32.GetDpiForWindow(hwnd);
        w.dpi = if (hwnd_dpi == 0) util.base_dpi else hwnd_dpi;
        self.applyDarkMode(w);
        if (w.always_on_top) {
            _ = win32.SetWindowPos(hwnd, win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
        }

        for (cfg.init_scripts) |script| {
            const copy = self.allocator.dupe(u8, script) catch continue;
            w.scripts.append(self.allocator, copy) catch self.allocator.free(copy);
        }
        if (cfg.initial_html) |html| {
            const copy = self.allocator.dupe(u8, html) catch return error.OutOfMemory;
            w.nav_queue.append(self.allocator, .{ .html = copy }) catch {
                self.allocator.free(copy);
                return error.OutOfMemory;
            };
        } else if (cfg.initial_url) |url| {
            const copy = self.allocator.dupe(u8, url) catch return error.OutOfMemory;
            w.nav_queue.append(self.allocator, .{ .url = copy }) catch {
                self.allocator.free(copy);
                return error.OutOfMemory;
            };
        }

        const env = self.env.?;
        const handler = try self.newHandler(.controller_ready, id.toU64());
        if (com.failed(env.vtable.CreateCoreWebView2Controller(env, hwnd, @ptrCast(handler)))) {
            return error.PlatformFailure;
        }

        self.had_windows = true;
        if (cfg.fullscreen) self.setFullscreen(id, true) catch {};
        if (w.visible) _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        return id;
    }

    fn windowStyle(w: *const WinWindow) win32.DWORD {
        if (w.parent != null) return win32.WS_CHILD | win32.WS_VISIBLE | win32.WS_CLIPCHILDREN | win32.WS_CLIPSIBLINGS;
        var style: win32.DWORD = win32.WS_CLIPCHILDREN | win32.WS_CLIPSIBLINGS;
        if (w.decorations) {
            style |= win32.WS_OVERLAPPEDWINDOW;
            if (!w.resizable) style &= ~@as(win32.DWORD, win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX);
        } else {
            style |= win32.WS_POPUP | win32.WS_MINIMIZEBOX | win32.WS_SYSMENU;
        }
        return style;
    }

    fn windowExStyle(w: *const WinWindow) win32.DWORD {
        var ex: win32.DWORD = 0;
        if (w.transparent) ex |= win32.WS_EX_LAYERED;
        if (w.parent == null) ex |= win32.WS_EX_APPWINDOW;
        return ex;
    }

    /// `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` — silently ignored pre-Windows 10 20H1.
    fn applyDarkMode(self: *WindowsWebView2Backend, w: *WinWindow) void {
        _ = self;
        const on: win32.BOOL = if (w.dark) win32.TRUE else win32.FALSE;
        _ = win32.DwmSetWindowAttribute(w.hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &on, @sizeOf(win32.BOOL));
        const round: i32 = win32.DWMWCP_ROUND;
        _ = win32.DwmSetWindowAttribute(w.hwnd, win32.DWMWA_WINDOW_CORNER_PREFERENCE, &round, @sizeOf(i32));
    }

    pub fn setDarkMode(self: *WindowsWebView2Backend, win_id: types.WindowId, enabled: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.dark = enabled;
        self.applyDarkMode(w);
    }

    pub fn closeWindow(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        self.beginClose(w);
    }

    fn beginClose(self: *WindowsWebView2Backend, w: *WinWindow) void {
        if (w.closing) return;
        w.closing = true;
        const id = w.id;
        self.destroyWebView(w);
        _ = win32.DestroyWindow(w.hwnd); // → WM_NCDESTROY → `finalizeWindow`
        // The OS may have already destroyed the window (session shutdown), in which case no
        // `WM_NCDESTROY` ever arrives — finalize here instead, but only if the record is still live.
        if (self.windows.get(id)) |still| self.finalizeWindow(@constCast(still.*));
    }

    fn destroyWebView(self: *WindowsWebView2Backend, w: *WinWindow) void {
        _ = self;
        if (w.webview) |wv| {
            if (w.token_message != 0) _ = wv.vtable.remove_WebMessageReceived(wv, w.token_message);
            if (w.token_resource != 0) _ = wv.vtable.remove_WebResourceRequested(wv, w.token_resource);
            if (w.token_close != 0) _ = wv.vtable.remove_WindowCloseRequested(wv, w.token_close);
            w.token_message = 0;
            w.token_resource = 0;
            w.token_close = 0;
            _ = wv.vtable.Release(wv);
            w.webview = null;
        }
        if (w.settings) |s| {
            _ = s.vtable.Release(s);
            w.settings = null;
        }
        if (w.controller) |c| {
            _ = c.vtable.Close(c);
            _ = c.vtable.Release(c);
            w.controller = null;
        }
        w.ready = false;
    }

    fn finalizeWindow(self: *WindowsWebView2Backend, w: *WinWindow) void {
        if (w.finalized) return;
        w.finalized = true;

        _ = self.pending.cancelForWindow(self.allocator, w.id, PendingToken.cancel);
        self.destroyWebView(w);

        const id = w.id;
        _ = win32.SetWindowLongPtrW(w.hwnd, win32.GWLP_USERDATA, 0);
        _ = self.windows.release(id) catch {};
        if (self.close_handler) |ch| ch.call(id);
        freeWindow(self.allocator, w);
    }

    fn freeWindow(allocator: Allocator, w: *WinWindow) void {
        if (w.title.len > 0) allocator.free(w.title);
        for (w.scripts.items) |s| allocator.free(s);
        w.scripts.deinit(allocator);
        for (w.nav_queue.items) |nav| nav.deinit(allocator);
        w.nav_queue.deinit(allocator);
        allocator.destroy(w);
    }

    fn closeByIdent(self: *WindowsWebView2Backend, ident: u64) void {
        if (self.windowByIdent(ident)) |w| self.beginClose(w);
    }

    pub fn nativeHandle(self: *WindowsWebView2Backend, win_id: types.WindowId) ?*anyopaque {
        const w = self.windows.get(win_id) orelse return null;
        return w.*.hwnd;
    }

    /// Overlay embedding (`M3-03`): resize the child HWND to fill the host's client area.
    /// `PUT/SetWindowPos` on a `WS_CHILD` window is the Win32 equivalent of
    /// `gtk_widget_set_size_request` / `[NSView setFrame:]` in the other two backends.
    pub fn fitParent(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const parent = w.*.parent orelse return error.Unsupported;
        var client: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (win32.GetClientRect(parent, &client) == 0) return error.PlatformFailure;
        var bounds: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (win32.GetWindowRect(w.*.hwnd, &bounds) == 0) return error.PlatformFailure;
        const width = @max(1, client.right - client.left);
        const height = @max(1, client.bottom - client.top);
        // `GetWindowRect` is in *screen* coordinates, so only the extent is comparable with the
        // parent-relative client rect.
        if (bounds.width() == width and bounds.height() == height) return;
        if (win32.SetWindowPos(
            w.*.hwnd,
            null,
            0,
            0,
            width,
            height,
            win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        ) == 0) return error.PlatformFailure;
    }

    // -- window properties -------------------------------------------------

    fn styleBits(style: u32) isize {
        return @as(isize, @as(i32, @bitCast(style)));
    }

    fn currentStyle(self: *WindowsWebView2Backend, w: *WinWindow) win32.DWORD {
        _ = self;
        const raw = win32.GetWindowLongPtrW(w.hwnd, win32.GWL_STYLE);
        return @bitCast(@as(i32, @truncate(raw)));
    }

    fn currentExStyle(self: *WindowsWebView2Backend, w: *WinWindow) win32.DWORD {
        _ = self;
        const raw = win32.GetWindowLongPtrW(w.hwnd, win32.GWL_EXSTYLE);
        return @bitCast(@as(i32, @truncate(raw)));
    }

    pub fn setTitle(self: *WindowsWebView2Backend, win_id: types.WindowId, title: []const u8) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const z = win32.toWide(self.allocator, title) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        _ = win32.SetWindowTextW(w.hwnd, z.ptr);
        const copy = self.allocator.dupe(u8, title) catch return error.OutOfMemory;
        if (w.title.len > 0) self.allocator.free(w.title);
        w.title = copy;
    }

    pub fn setSize(self: *WindowsWebView2Backend, win_id: types.WindowId, size: types.LogicalSize) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        var rect = win32.RECT{
            .left = 0,
            .top = 0,
            .right = util.logicalToPhysical(size.width.v, w.dpi),
            .bottom = util.logicalToPhysical(size.height.v, w.dpi),
        };
        _ = win32.AdjustWindowRectEx(&rect, self.currentStyle(w), win32.FALSE, self.currentExStyle(w));
        _ = win32.SetWindowPos(
            w.hwnd,
            null,
            0,
            0,
            @max(1, rect.width()),
            @max(1, rect.height()),
            win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        );
        self.resizeWebView(w);
    }

    pub fn setMinSize(self: *WindowsWebView2Backend, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.min_size = size;
    }

    pub fn setMaxSize(self: *WindowsWebView2Backend, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.max_size = size;
    }

    pub fn setPosition(self: *WindowsWebView2Backend, win_id: types.WindowId, pos: types.LogicalPoint) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        _ = win32.SetWindowPos(
            w.hwnd,
            null,
            util.logicalToPhysical(pos.x.v, w.dpi),
            util.logicalToPhysical(pos.y.v, w.dpi),
            0,
            0,
            win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        );
    }

    pub fn setResizable(self: *WindowsWebView2Backend, win_id: types.WindowId, resizable: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.resizable = resizable;
        self.applyStyle(w);
    }

    pub fn setMinimized(self: *WindowsWebView2Backend, win_id: types.WindowId, minimized: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        _ = win32.ShowWindow(w.hwnd, if (minimized) win32.SW_MINIMIZE else win32.SW_RESTORE);
    }

    pub fn setMaximized(self: *WindowsWebView2Backend, win_id: types.WindowId, maximized: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        _ = win32.ShowWindow(w.hwnd, if (maximized) win32.SW_MAXIMIZE else win32.SW_RESTORE);
    }

    pub fn setFullscreen(self: *WindowsWebView2Backend, win_id: types.WindowId, fullscreen: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        if (w.fullscreen == fullscreen) return;
        w.fullscreen = fullscreen;

        if (fullscreen) {
            var rect: win32.RECT = .{};
            _ = win32.GetWindowRect(w.hwnd, &rect);
            w.saved_rect = rect;
            _ = win32.SetWindowLongPtrW(w.hwnd, win32.GWL_STYLE, styleBits(win32.WS_POPUP | win32.WS_VISIBLE));
            const cx = @max(1, win32.GetSystemMetrics(win32.SM_CXSCREEN));
            const cy = @max(1, win32.GetSystemMetrics(win32.SM_CYSCREEN));
            _ = win32.SetWindowPos(w.hwnd, win32.HWND_TOP, 0, 0, cx, cy, win32.SWP_FRAMECHANGED | win32.SWP_SHOWWINDOW);
        } else {
            _ = win32.SetWindowLongPtrW(w.hwnd, win32.GWL_STYLE, styleBits(w.saved_style));
            _ = win32.SetWindowPos(
                w.hwnd,
                null,
                w.saved_rect.left,
                w.saved_rect.top,
                @max(1, w.saved_rect.width()),
                @max(1, w.saved_rect.height()),
                win32.SWP_FRAMECHANGED | win32.SWP_NOZORDER,
            );
        }
        self.resizeWebView(w);
    }

    pub fn setVisible(self: *WindowsWebView2Backend, win_id: types.WindowId, visible: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.visible = visible;
        _ = win32.ShowWindow(w.hwnd, if (visible) win32.SW_SHOW else win32.SW_HIDE);
        if (w.controller) |c| _ = c.vtable.put_IsVisible(c, if (visible) win32.TRUE else win32.FALSE);
    }

    pub fn setDecorations(self: *WindowsWebView2Backend, win_id: types.WindowId, decorations: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.decorations = decorations;
        self.applyStyle(w);
    }

    pub fn setAlwaysOnTop(self: *WindowsWebView2Backend, win_id: types.WindowId, on_top: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.always_on_top = on_top;
        _ = win32.SetWindowPos(
            w.hwnd,
            if (on_top) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE,
        );
    }

    pub fn setFocus(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        _ = win32.SetForegroundWindow(w.hwnd);
        _ = win32.SetFocus(w.hwnd);
        if (w.controller) |c| _ = c.vtable.MoveFocus(c, 0);
    }

    pub fn startDrag(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        // Hand the caption hit-test to the window manager: it then runs the native modal move loop,
        // which is exactly what a frameless HTML titlebar needs for `data-tauri-drag-region`.
        _ = win32.ReleaseCapture();
        _ = win32.SendMessageW(w.hwnd, win32.WM_NCLBUTTONDOWN, win32.HTCAPTION, 0);
    }

    fn applyStyle(self: *WindowsWebView2Backend, w: *WinWindow) void {
        _ = win32.SetWindowLongPtrW(w.hwnd, win32.GWL_STYLE, styleBits(windowStyle(w)));
        _ = win32.SetWindowLongPtrW(w.hwnd, win32.GWL_EXSTYLE, styleBits(windowExStyle(w)));
        _ = win32.SetWindowPos(
            w.hwnd,
            null,
            0,
            0,
            0,
            0,
            win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED,
        );
        self.resizeWebView(w);
    }

    fn resizeWebView(self: *WindowsWebView2Backend, w: *WinWindow) void {
        _ = self;
        const controller = w.controller orelse return;
        var rect: win32.RECT = .{};
        if (win32.GetClientRect(w.hwnd, &rect) == 0) return;
        _ = controller.vtable.put_Bounds(controller, .{
            .left = 0,
            .top = 0,
            .right = @max(1, rect.width()),
            .bottom = @max(1, rect.height()),
        });
    }

    // -- web content -------------------------------------------------------

    pub fn addInitScript(self: *WindowsWebView2Backend, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        if (w.webview != null) {
            self.addDocumentScript(w, script);
            return;
        }
        const copy = self.allocator.dupe(u8, script) catch return error.OutOfMemory;
        w.scripts.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return error.OutOfMemory;
        };
    }

    pub fn evalJs(self: *WindowsWebView2Backend, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const wv = w.webview orelse return error.PlatformFailure;
        const z = win32.toWide(self.allocator, script) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        _ = wv.vtable.ExecuteScript(wv, z.ptr, null);
    }

    pub fn navigate(self: *WindowsWebView2Backend, win_id: types.WindowId, url: []const u8) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const wv = w.webview orelse {
            const copy = self.allocator.dupe(u8, url) catch return error.OutOfMemory;
            w.nav_queue.append(self.allocator, .{ .url = copy }) catch {
                self.allocator.free(copy);
                return error.OutOfMemory;
            };
            return;
        };
        var buf: [8192]u8 = undefined;
        const mapped = util.toWebView2Url(&buf, url) catch url;
        const z = win32.toWide(self.allocator, mapped) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        _ = wv.vtable.Navigate(wv, z.ptr);
    }

    pub fn loadHtml(
        self: *WindowsWebView2Backend,
        win_id: types.WindowId,
        html: []const u8,
        base_uri: ?[]const u8,
    ) types.WebviewError!void {
        _ = base_uri;
        const w = try self.requireWindow(win_id);
        const wv = w.webview orelse {
            const copy = self.allocator.dupe(u8, html) catch return error.OutOfMemory;
            w.nav_queue.append(self.allocator, .{ .html = copy }) catch {
                self.allocator.free(copy);
                return error.OutOfMemory;
            };
            return;
        };
        const z = win32.toWide(self.allocator, html) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        _ = wv.vtable.NavigateToString(wv, z.ptr);
    }

    pub fn openDevtools(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const wv = w.webview orelse return error.PlatformFailure;
        _ = wv.vtable.OpenDevToolsWindow(wv);
    }
};

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------

fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(CALL) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const create: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (create.lpCreateParams) |p| {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(p)));
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const raw = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    const w: ?*WinWindow = if (raw == 0) null else @ptrFromInt(@as(usize, @bitCast(raw)));

    switch (msg) {
        win32.WM_CLOSE => {
            if (w) |win| {
                win.backend.closeByIdent(win.id.toU64());
                return 0;
            }
            _ = win32.DestroyWindow(hwnd);
            return 0;
        },
        win32.WM_DESTROY => {
            return 0;
        },
        win32.WM_NCDESTROY => {
            if (w) |win| win.backend.finalizeWindow(win);
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_SIZE => {
            if (w) |win| win.backend.resizeWebView(win);
            return 0;
        },
        win32.WM_MOVE => {
            if (w) |win| {
                if (win.controller) |c| _ = c.vtable.NotifyParentWindowPositionChanged(c);
            }
            return 0;
        },
        win32.WM_DPICHANGED => {
            if (w) |win| {
                const dpi: u32 = win32.loword(lparam);
                win.dpi = if (dpi == 0) util.base_dpi else dpi;
                const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = win32.SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    @max(1, suggested.width()),
                    @max(1, suggested.height()),
                    win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
                );
                win.backend.resizeWebView(win);
            }
            return 0;
        },
        win32.WM_GETMINMAXINFO => {
            if (w) |win| {
                const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (win.min_size) |ms| {
                    info.ptMinTrackSize = .{
                        .x = util.logicalToPhysical(ms.width.v, win.dpi),
                        .y = util.logicalToPhysical(ms.height.v, win.dpi),
                    };
                }
                if (win.max_size) |xs| {
                    info.ptMaxTrackSize = .{
                        .x = util.logicalToPhysical(xs.width.v, win.dpi),
                        .y = util.logicalToPhysical(xs.height.v, win.dpi),
                    };
                }
            }
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// `http://tauri.localhost/…` and the raw `tauri://localhost/…` spelling both classify; any other
/// host (including a look-alike such as `evil.tauri.localhost`) is left to the network stack.
fn classifyVirtualOrigin(uri: []const u8) ?util.Protocol {
    const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return null;
    const scheme = uri[0..scheme_end];
    const rest = uri[scheme_end + 3 ..];
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..host_end];

    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        if (std.ascii.eqlIgnoreCase(host, "tauri.localhost")) return .tauri;
        if (std.ascii.eqlIgnoreCase(host, "ipc.localhost")) return .ipc;
        if (std.ascii.eqlIgnoreCase(host, "asset.localhost")) return .asset;
        return null;
    }
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
    return util.protocolFromScheme(scheme);
}

/// Serialises one `name: value` line into the header block handed to
/// `ICoreWebView2Environment::CreateWebResourceResponse`.
///
/// WebView2 parses that string as `name: value` lines separated by a **single `\n`** and expects
/// **no terminator after the last header** (the shape `wry` emits). A trailing newline makes the
/// runtime throw the *whole* block away: the response is still delivered, so the page renders, but
/// `Access-Control-Allow-Origin` / `Tauri-Response` silently disappear and every cross-origin
/// `fetch` dies with `TypeError: Failed to fetch` (`M3-02`, diagnosed on `ci-windows`).
fn appendHeaderLine(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    name: []const u8,
    value: []const u8,
) std.mem.Allocator.Error!void {
    if (out.items.len != 0) try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, ": ");
    try out.appendSlice(allocator, value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "classifyVirtualOrigin recognises the WebView2 spellings and rejects look-alikes" {
    try std.testing.expectEqual(util.Protocol.tauri, classifyVirtualOrigin("http://tauri.localhost/index.html").?);
    try std.testing.expectEqual(util.Protocol.ipc, classifyVirtualOrigin("http://ipc.localhost/invoke").?);
    try std.testing.expectEqual(util.Protocol.asset, classifyVirtualOrigin("http://asset.localhost/a.png").?);
    try std.testing.expectEqual(util.Protocol.tauri, classifyVirtualOrigin("tauri://localhost/index.html").?);
    try std.testing.expect(classifyVirtualOrigin("http://example.com/x") == null);
    try std.testing.expect(classifyVirtualOrigin("http://evil.tauri.localhost/x") == null);
    try std.testing.expect(classifyVirtualOrigin("about:blank") == null);
}

test "styleBits preserves the signed LONG semantics of Get/SetWindowLongPtrW" {
    const style: u32 = win32.WS_POPUP | win32.WS_VISIBLE;
    const bits = WindowsWebView2Backend.styleBits(style);
    try std.testing.expectEqual(@as(isize, -0x7000_0000), bits);
    try std.testing.expectEqual(@as(u32, 0x9000_0000), @as(u32, @bitCast(@as(i32, @truncate(bits)))));
}

test "response header lines are LF separated with no trailing terminator" {
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(std.testing.allocator);

    try appendHeaderLine(&block, std.testing.allocator, "Access-Control-Allow-Origin", "*");
    try appendHeaderLine(&block, std.testing.allocator, "Content-Type", "text/plain");

    // Exactly two lines, one `\n` in between, nothing at the end: Chromium only sees
    // `Access-Control-Allow-Origin: *` when the block stops at the final byte of the last value.
    try std.testing.expectEqualStrings("Access-Control-Allow-Origin: *\nContent-Type: text/plain", block.items);
}

test "a preflight block carries exactly one Access-Control-Allow-Origin" {
    var backend: WindowsWebView2Backend = undefined;
    backend.allocator = std.testing.allocator;

    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(std.testing.allocator);
    try backend.headerBlock(&block, "text/plain", &WindowsWebView2Backend.preflight_pairs, &.{});

    var occurrences: usize = 0;
    var rest: []const u8 = block.items;
    while (std.mem.indexOf(u8, rest, "Access-Control-Allow-Origin:")) |at| {
        occurrences += 1;
        rest = rest[at + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 1), occurrences);
    try std.testing.expect(std.mem.indexOf(u8, block.items, "Access-Control-Allow-Methods: GET, POST") != null);
}
