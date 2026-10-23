//! Native Windows Backend — `Win32` window + WebView2 (`src/webview/windows.zig`, `M3-02`).
//!
//! Pure Zig, **no C / C++ / Rust, no `@cImport`, no `WebView2Loader.dll`**: the runtime is located
//! and driven through [`webview2_loader.zig`](webview2_loader.zig) + the hand-generated COM vtables
//! in [`webview2_com.zig`](webview2_com.zig). It mirrors [`linux.zig`](linux.zig) and
//! [`macos.zig`](macos.zig) one-for-one, so `zts_core.Host`, `zts_tauri.ProtocolRouter`,
//! `DesktopRuntime` and `examples/counter` need **zero** Windows-specific code.
//!
//! Architecture & Safety Guarantees:
//! 1. **Step-driven STA message pump**: `step(.blocking)` waits on an auto-reset event with
//!    `MsgWaitForMultipleObjectsEx` (1 s cap) and then drains `PeekMessage` — the caller keeps
//!    `defer` scopes and 60/120 fps `.poll` loops work unchanged. `wakeup()` = `SetEvent`.
//! 2. **Async window creation**: `createWindow()` returns a `WindowId` immediately; the WebView2
//!    controller completes on a later `step()` and *then* applies queued init scripts and navigates.
//! 3. **`ICoreWebView2Deferral` isolation**: request payloads are copied out, the raw COM pointers
//!    live in a main-thread-only table, and Zig only ever sees `(window_id, token)` + bytes.
//! 4. **No new windows / no navigation hijack**: URLs are rewritten `tauri://` →
//!    `http://tauri.localhost/` by [`windows_util.toWebView2Url`](windows_util.zig) (unit-tested on
//!    Linux/macOS too), so the same `ProtocolRouter` classification handles both OS families.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

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
/// How long `init()` and `createWindow()` wait for the WebView2 environment/controller.
const startup_timeout_ms: u32 = 15_000;

// ---------------------------------------------------------------------------
// Window record
// ---------------------------------------------------------------------------

const WinWindow = struct {
    backend: *WindowsWebView2Backend,
    hwnd: win32.HWND,
    ident: u64,

    controller: ?*com.ICoreWebView2Controller = null,
    webview: ?*com.ICoreWebView2 = null,
    ready: bool = false,

    title: []u8 = &.{},
    want_visible: bool = true,
    top_level: bool = true,
    resizable: bool = true,
    decorations: bool = true,
    always_on_top: bool = false,
    devtools: bool = false,

    min_size: ?types.LogicalSize = null,
    max_size: ?types.LogicalSize = null,

    /// Init scripts / navigations issued before the controller finished creating.
    queued_scripts: std.ArrayList([]u8) = .empty,
    queued_url: ?[]u8 = null,
    queued_html: ?[]u8 = null,

    close_requested: bool = false,
    dpi: u32 = 96,
    /// `EventRegistrationToken`s for the three handlers so teardown can unsubscribe cleanly.
    msg_token: i64 = 0,
    resource_token: i64 = 0,
    close_token: i64 = 0,

    fn deinit(self: *WinWindow, allocator: Allocator) void {
        for (self.queued_scripts.items) |s| allocator.free(s);
        self.queued_scripts.deinit(allocator);
        if (self.queued_url) |u| allocator.free(u);
        if (self.queued_html) |h| allocator.free(h);
        if (self.title.len > 0) allocator.free(self.title);
    }
};

/// A deferred `WebResourceRequested` callback (main thread only).
const DeferredTask = struct {
    args: *com.ICoreWebView2WebResourceRequestedEventArgs,
    deferral: *com.ICoreWebView2Deferral,
};

/// Only `(backend, token)` crosses thread boundaries; the COM pointers never leave the UI thread.
const PendingToken = struct {
    backend: *WindowsWebView2Backend,
    token: u64,

    fn cancel(self: PendingToken) void {
        self.backend.failDeferred(self.token);
    }
};

// ---------------------------------------------------------------------------
// COM event handler objects (IUnknown + Invoke)
// ---------------------------------------------------------------------------

const HandlerKind = enum(u32) { environment_ready, controller_ready, web_message, web_resource, window_close };

/// Every WebView2 event handler shares the layout `{ vtable, ... }` + 4 slots
/// (`QueryInterface`, `AddRef`, `Release`, `Invoke`). One Zig struct can therefore back all of
/// them; only the `Invoke` thunk differs. `iid` keeps `QueryInterface` honest.
const Handler = extern struct {
    vtable: *const HandlerVTable,
    refs: u32 = 1,
    backend: *WindowsWebView2Backend,
    ident: u64,
    kind: HandlerKind,
    iid: com.Guid,

    const HandlerVTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const com.Guid, ?*?*anyopaque) callconv(.winapi) com.HResult,
        AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
        Release: *const fn (*anyopaque) callconv(.winapi) u32,
        /// `a`/`b` are the interface's two payload arguments. Both are 64-bit wide on every
        /// Windows ABI this backend supports (an `HRESULT` occupies the low 32 bits of `a`).
        Invoke: *const fn (*anyopaque, a: usize, b: usize) callconv(.winapi) com.HResult,
    };
};

pub const IID_IUnknown = com.guid("00000000-0000-0000-c000-000000000046");

fn handlerQueryInterface(this: *anyopaque, riid: *const com.Guid, out: ?*?*anyopaque) callconv(.winapi) com.HResult {
    const self: *Handler = @ptrCast(@alignCast(this));
    const dst = out orelse return com.E_POINTER;
    if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &self.iid)) {
        dst.* = this;
        _ = handlerAddRef(this);
        return com.S_OK;
    }
    dst.* = null;
    return com.E_NOINTERFACE;
}

fn handlerAddRef(this: *anyopaque) callconv(.winapi) u32 {
    const self: *Handler = @ptrCast(@alignCast(this));
    self.refs +%= 1;
    return self.refs;
}

fn handlerRelease(this: *anyopaque) callconv(.winapi) u32 {
    const self: *Handler = @ptrCast(@alignCast(this));
    self.refs -%= 1;
    // Memory is arena-owned by the backend and released in `deinit()`, so a `Release` racing the
    // teardown can never free memory WebView2 still touches (no use-after-free by construction).
    return self.refs;
}

fn guidEql(a: *const com.Guid, b: *const com.Guid) bool {
    return a.d1 == b.d1 and a.d2 == b.d2 and a.d3 == b.d3 and std.mem.eql(u8, &a.d4, &b.d4);
}

fn handlerInvokeRaw(this: *anyopaque, a: usize, b: usize) callconv(.winapi) com.HResult {
    const self: *Handler = @ptrCast(@alignCast(this));
    return switch (self.kind) {
        .environment_ready => self.backend.onEnvironmentReady(self, @as(com.HResult, @bitCast(@as(u32, @truncate(a)))), b),
        .controller_ready => self.backend.onControllerReady(self, @as(com.HResult, @bitCast(@as(u32, @truncate(a)))), b),
        .web_message => self.backend.onWebMessage(self, a, b),
        .web_resource => self.backend.onWebResourceRequested(self, a, b),
        .window_close => self.backend.onWindowCloseRequested(self, a, b),
    };
}

const handler_vtable: Handler.HandlerVTable = .{
    .QueryInterface = handlerQueryInterface,
    .AddRef = handlerAddRef,
    .Release = handlerRelease,
    .Invoke = handlerInvokeRaw,
};

// ---------------------------------------------------------------------------
// Backend
// ---------------------------------------------------------------------------

pub const WindowsWebView2Backend = struct {
    allocator: Allocator,
    io: Io,

    runtime: loader.Runtime,
    env: ?*com.ICoreWebView2Environment = null,
    com_initialized: bool = false,

    wakeup_event: win32.HANDLE,
    window_class: [32]u8 = @splat(0),
    window_class_len: usize = 0,
    next_ident: u64 = 1,

    windows: foundation.HandlePool(*WinWindow, .window) = .empty,
    scheme_slots: std.ArrayList(*SchemeSlot) = .empty,
    pending: pending_mod.PendingTable(PendingToken) = .{},
    completions: pending_mod.CompletionQueue,
    deferred: std.AutoHashMapUnmanaged(u64, DeferredTask) = .empty,
    next_token: u64 = 1,

    /// COM handler objects live here for the whole backend lifetime (see `handlerRelease`).
    handlers: std.heap.ArenaAllocator,

    message_handler: ?types.MessageHandler = null,
    close_handler: ?types.CloseHandler = null,

    quit: bool = false,
    had_windows: bool = false,

    pub fn init(allocator: Allocator, io: Io) types.WebviewError!*WindowsWebView2Backend {
        var rt = loader.load(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // No Evergreen runtime installed -> let `.auto` degrade to `HeadlessMock`.
            error.RuntimeNotFound, error.LoadFailed, error.ExportMissing => return error.DisplayUnavailable,
        };
        errdefer rt.deinit();

        const event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse return error.PlatformFailure;

        const self = allocator.create(WindowsWebView2Backend) catch {
            _ = win32.CloseHandle(event);
            return error.OutOfMemory;
        };
        self.* = .{
            .allocator = allocator,
            .io = io,
            .runtime = rt,
            .wakeup_event = event,
            .completions = pending_mod.CompletionQueue.init(allocator, io),
            .handlers = std.heap.ArenaAllocator.init(allocator),
        };

        // STA is mandatory: WebView2 callbacks are dispatched on the thread that created the
        // environment, and that same thread is the one calling `step()`.
        const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
        // `RPC_E_CHANGED_MODE` (0x80010106) simply means the host already initialized MTA/STA.
        if (com.failed(hr) and hr != @as(com.HResult, @bitCast(@as(u32, 0x80010106)))) {
            self.deinit();
            return error.PlatformFailure;
        }
        self.com_initialized = !com.failed(hr);

        self.registerWindowClass() catch {
            self.deinit();
            return error.PlatformFailure;
        };
        self.createEnvironment() catch |err| {
            self.deinit();
            return err;
        };
        return self;
    }

    pub fn deinit(self: *WindowsWebView2Backend) void {
        const alloc = self.allocator;

        // 1. Detach app callbacks before anything can re-enter the torn-down backend.
        self.message_handler = null;
        self.close_handler = null;

        // 2. Destroy windows (also closes their WebView2 controllers).
        var idents: std.ArrayList(u64) = .empty;
        defer idents.deinit(alloc);
        var it = self.windows.iterator();
        while (it.next()) |slot| idents.append(alloc, slot.value_ptr.*.ident) catch {};

        for (idents.items) |ident| self.closeWindowByIdent(ident);

        // 3. Fail every still-deferred request (unblocks WebView2, no leaks).
        self.pending.deinitWith(alloc, PendingToken.cancel);
        self.deferred.deinit(alloc);
        self.completions.deinit();

        for (self.scheme_slots.items) |slot| {
            alloc.free(slot.scheme);
            alloc.destroy(slot);
        }
        self.scheme_slots.deinit(alloc);

        if (self.env) |env| {
            _ = env.vtable.Release(env);
            self.env = null;
        }

        self.windows.deinit(alloc);
        self.handlers.deinit();

        if (self.window_class_len > 0) {
            const cls = win32.toWide(alloc, self.windowClass()) catch null;
            if (cls) |c| {
                defer alloc.free(c);
                const hinstance = win32.GetModuleHandleW(null);
                _ = win32.UnregisterClassW(c.ptr, hinstance);
            }
        }

        _ = win32.CloseHandle(self.wakeup_event);
        self.runtime.deinit();
        if (self.com_initialized) win32.CoUninitialize();
        alloc.destroy(self);
    }

    fn windowClass(self: *const WindowsWebView2Backend) []const u8 {
        return self.window_class[0..self.window_class_len];
    }

    fn registerWindowClass(self: *WindowsWebView2Backend) !void {
        const name = std.fmt.bufPrint(&self.window_class, "ZtsWebView2Window{x}", .{@as(u32, @truncate(@intFromPtr(self)))}) catch
            return error.OutOfMemory;
        self.window_class_len = name.len;

        const name_z = try win32.toWide(self.allocator, name);
        defer self.allocator.free(name_z);

        const hinstance = win32.GetModuleHandleW(null);
        const cls: win32.WNDCLASSEXW = .{
            .lpfnWndProc = ztsWndProc,
            .hInstance = hinstance,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = @ptrFromInt(@as(usize, win32.COLOR_WINDOW + 1)),
            .lpszClassName = name_z.ptr,
        };
        if (win32.RegisterClassExW(&cls) == 0) {
            // A stale class from a previous instance in the same process is fine.
            if (win32.GetLastError() != 1410) return error.PlatformFailure; // ERROR_CLASS_ALREADY_EXISTS
        }
    }

    fn createEnvironment(self: *WindowsWebView2Backend) types.WebviewError!void {
        const alloc = self.allocator;

        // `<exe>.WebView2` — exactly Microsoft's default, but always explicit so the folder is
        // writable even when the exe lives in a read-only cache directory.
        var exe_buf: [1024]u16 = undefined;
        const exe_len = win32.GetModuleFileNameW(null, &exe_buf, exe_buf.len);
        exe_buf[if (exe_len < exe_buf.len) exe_len else exe_buf.len - 1] = 0;

        const exe_utf8 = win32.fromWide(alloc, @ptrCast(&exe_buf), false) catch return error.OutOfMemory;
        defer alloc.free(exe_utf8);

        var folder_buf: [1200]u8 = undefined;
        const folder = util.defaultUserDataFolder(&folder_buf, exe_utf8) catch return error.OutOfMemory;
        const folder_z = win32.toWide(alloc, folder) catch return error.OutOfMemory;
        defer alloc.free(folder_z);

        const handler = self.newHandler(0, .environment_ready, com.IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler);
        const hr = self.runtime.create(
            win32.TRUE,
            loader.RUNTIME_TYPE_INSTALLED,
            folder_z.ptr,
            null,
            @ptrCast(handler),
        );
        if (com.failed(hr)) return error.PlatformFailure;

        self.pumpUntil(&self.env, startup_timeout_ms) catch return error.PlatformFailure;
        if (self.env == null) return error.PlatformFailure;
    }

    fn newHandler(self: *WindowsWebView2Backend, ident: u64, kind: HandlerKind, iid: com.Guid) *Handler {
        const h = self.handlers.allocator().create(Handler) catch @panic("OOM allocating COM handler");
        h.* = .{
            .vtable = &handler_vtable,
            .backend = self,
            .ident = ident,
            .kind = kind,
            .iid = iid,
        };
        return h;
    }

    /// Runs the message pump until `*flag` becomes non-null (async COM completion) or timeout.
    fn pumpUntil(self: *WindowsWebView2Backend, flag: *?*com.ICoreWebView2Environment, timeout_ms: u32) !void {
        var waited: u32 = 0;
        while (flag.* == null) {
            if (waited >= timeout_ms) return error.Timeout;
            _ = win32.MsgWaitForMultipleObjectsEx(
                1,
                &self.wakeup_event,
                10,
                win32.QS_ALLINPUT,
                win32.MWMO_INPUTAVAILABLE,
            );
            _ = win32.ResetEvent(self.wakeup_event);
            self.pumpMessages();
            waited += 10;
        }
    }

    fn pumpMessages(self: *WindowsWebView2Backend) void {
        _ = self;
        var msg: win32.MSG = .{};
        while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
    }

    // ----------------------------------------------------------------------
    // COM callbacks
    // ----------------------------------------------------------------------

    fn onEnvironmentReady(self: *WindowsWebView2Backend, h: *Handler, hr: com.HResult, result: usize) com.HResult {
        _ = h;
        if (com.failed(hr) or result == 0) return com.S_OK;
        const env: *com.ICoreWebView2Environment = @ptrFromInt(result);
        _ = env.vtable.AddRef(env);
        self.env = env;
        return com.S_OK;
    }

    fn onControllerReady(self: *WindowsWebView2Backend, h: *Handler, hr: com.HResult, result: usize) com.HResult {
        if (com.failed(hr) or result == 0) return com.S_OK;
        const win = self.windowByIdent(h.ident) orelse return com.S_OK;
        if (win.close_requested) return com.S_OK;

        const controller: *com.ICoreWebView2Controller = @ptrFromInt(result);
        _ = controller.vtable.AddRef(controller);
        win.controller = controller;

        var webview: ?*com.ICoreWebView2 = null;
        if (com.failed(controller.vtable.get_CoreWebView2(controller, &webview))) return com.S_OK;
        const wv = webview orelse return com.S_OK;
        win.webview = wv;

        _ = controller.vtable.put_IsVisible(controller, win32.TRUE);
        self.configureWebView(win, wv);
        self.applyQueuedWork(win);
        win.ready = true;

        if (win.want_visible) _ = win32.ShowWindow(win.hwnd, win32.SW_SHOW);
        return com.S_OK;
    }

    fn configureWebView(self: *WindowsWebView2Backend, win: *WinWindow, wv: *com.ICoreWebView2) void {
        var settings: ?*com.ICoreWebView2Settings = null;
        if (!com.failed(wv.vtable.get_Settings(wv, &settings))) {
            if (settings) |s| {
                _ = s.vtable.put_AreDevToolsEnabled(s, if (win.devtools) win32.TRUE else win32.FALSE);
                _ = s.vtable.put_IsStatusBarEnabled(s, win32.FALSE);
                _ = s.vtable.put_IsWebMessageEnabled(s, win32.TRUE);
                _ = s.vtable.put_IsScriptEnabled(s, win32.TRUE);
                _ = s.vtable.Release(s);
            }
        }

        // `window.__ztsPostMessage` so the shared JS bootstrap has one code path on every OS.
        const bridge = "window.__ztsPostMessage = (m) => window.chrome.webview.postMessage(m);";
        self.addDocumentScript(win, wv, bridge);

        var token: i64 = 0;
        const msg_handler = self.newHandler(win.ident, .web_message, com.IID_ICoreWebView2WebMessageReceivedEventHandler);
        if (!com.failed(wv.vtable.add_WebMessageReceived(wv, @ptrCast(msg_handler), &token))) {
            win.msg_token = token;
        }

        // Intercept the three Tauri sub-origins (WebView2 has no custom-scheme support).
        const resource_handler = self.newHandler(win.ident, .web_resource, com.IID_ICoreWebView2WebResourceRequestedEventHandler);
        var resource_token: i64 = 0;
        const added = !com.failed(wv.vtable.add_WebResourceRequested(wv, @ptrCast(resource_handler), &resource_token));
        if (added) win.resource_token = resource_token;

        for ([_]util.Protocol{ .tauri, .ipc, .asset }) |p| {
            var filter_buf: [64]u8 = undefined;
            const pattern = util.filterPattern(&filter_buf, p) catch continue;
            const pattern_z = win32.toWide(self.allocator, pattern) catch continue;
            defer self.allocator.free(pattern_z);
            // COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL == 0xF (all contexts).
            _ = wv.vtable.AddWebResourceRequestedFilter(wv, pattern_z.ptr, 0xF);
        }

        const close_handler = self.newHandler(win.ident, .window_close, com.IID_ICoreWebView2WindowCloseRequestedEventHandler);
        var close_token: i64 = 0;
        if (!com.failed(wv.vtable.add_WindowCloseRequested(wv, @ptrCast(close_handler), &close_token))) {
            win.close_token = close_token;
        }
    }

    fn addDocumentScript(self: *WindowsWebView2Backend, win: *WinWindow, wv: *com.ICoreWebView2, script: []const u8) void {
        const z = win32.toWide(self.allocator, script) catch return;
        defer self.allocator.free(z);
        _ = wv.vtable.AddScriptToExecuteOnDocumentCreated(wv, z.ptr, null);
        _ = win;
    }

    fn applyQueuedWork(self: *WindowsWebView2Backend, win: *WinWindow) void {
        const wv = win.webview orelse return;

        for (win.queued_scripts.items) |script| self.addDocumentScript(win, wv, script);
        for (win.queued_scripts.items) |s| self.allocator.free(s);
        win.queued_scripts.clearRetainingCapacity();

        if (win.queued_html) |html| {
            self.navigateHtml(win, wv, html);
            self.allocator.free(html);
            win.queued_html = null;
        } else if (win.queued_url) |url| {
            self.navigateUrl(win, wv, url);
            self.allocator.free(url);
            win.queued_url = null;
        }
    }

    fn navigateUrl(self: *WindowsWebView2Backend, win: *WinWindow, wv: *com.ICoreWebView2, url: []const u8) void {
        _ = win;
        var buf: [4096]u8 = undefined;
        const rewritten = util.toWebView2Url(&buf, url) catch return;
        const z = win32.toWide(self.allocator, rewritten) catch return;
        defer self.allocator.free(z);
        _ = wv.vtable.Navigate(wv, z.ptr);
    }

    fn navigateHtml(self: *WindowsWebView2Backend, win: *WinWindow, wv: *com.ICoreWebView2, html: []const u8) void {
        _ = win;
        const z = win32.toWide(self.allocator, html) catch return;
        defer self.allocator.free(z);
        _ = wv.vtable.NavigateToString(wv, z.ptr);
    }

    fn onWebMessage(self: *WindowsWebView2Backend, h: *Handler, sender: usize, args_ptr: usize) com.HResult {
        _ = sender;
        if (args_ptr == 0) return com.S_OK;
        const args: *com.ICoreWebView2WebMessageReceivedEventArgs = @ptrFromInt(args_ptr);

        var wide: ?[*:0]u16 = null;
        var text: ?[]u8 = null;
        if (!com.failed(args.vtable.TryGetWebMessageAsString(args, &wide))) {
            if (wide) |w| text = win32.fromWide(self.allocator, w, true) catch null;
        }
        if (text == null) {
            wide = null;
            if (!com.failed(args.vtable.get_WebMessageAsJson(args, &wide))) {
                if (wide) |w| text = win32.fromWide(self.allocator, w, true) catch null;
            }
        }

        if (text) |payload| {
            defer self.allocator.free(payload);
            if (self.message_handler) |mh| {
                if (self.windowIdForIdent(h.ident)) |wid| mh.call(wid, payload);
            }
        }
        return com.S_OK;
    }

    fn onWindowCloseRequested(self: *WindowsWebView2Backend, h: *Handler, sender: usize, args: usize) com.HResult {
        _ = sender;
        _ = args;
        if (self.windowByIdent(h.ident)) |win| win.close_requested = true;
        return com.S_OK;
    }

    fn onWebResourceRequested(self: *WindowsWebView2Backend, h: *Handler, sender: usize, args_ptr: usize) com.HResult {
        _ = sender;
        if (args_ptr == 0) return com.S_OK;
        const win = self.windowByIdent(h.ident) orelse return com.S_OK;
        const args: *com.ICoreWebView2WebResourceRequestedEventArgs = @ptrFromInt(args_ptr);
        const alloc = self.allocator;

        var request: ?*com.ICoreWebView2WebResourceRequest = null;
        if (com.failed(args.vtable.get_Request(args, &request))) return com.S_OK;
        const req = request orelse return com.S_OK;
        defer _ = req.vtable.Release(req);

        var uri_wide: ?[*:0]u16 = null;
        if (com.failed(req.vtable.get_Uri(req, &uri_wide))) return com.S_OK;
        const uri = win32.fromWide(alloc, uri_wide.?, true) catch return com.S_OK;
        defer alloc.free(uri);

        if (util.classify(uri) == null) return com.S_OK; // not ours: let WebView2 handle it

        var method_wide: ?[*:0]u16 = null;
        if (com.failed(req.vtable.get_Method(req, &method_wide))) return com.S_OK;
        const method = win32.fromWide(alloc, method_wide.?, true) catch return com.S_OK;
        defer alloc.free(method);

        // CORS preflight never reaches Zig (same policy as the macOS shim).
        if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
            self.respondPreflight(win, args);
            return com.S_OK;
        }

        var headers_buf: [max_headers]types.HeaderPair = undefined;
        var header_names: [max_headers][*:0]u16 = undefined;
        var header_values: [max_headers][*:0]u16 = undefined;
        const header_count = self.readHeaders(req, &header_names, &header_values, max_headers);
        for (0..header_count) |idx| {
            headers_buf[idx] = .{
                .name = win32.fromWide(alloc, header_names[idx], false) catch "",
                .value = win32.fromWide(alloc, header_values[idx], false) catch "",
            };
        }
        defer for (headers_buf[0..header_count]) |hp| {
            if (hp.name.len > 0) alloc.free(@constCast(hp.name));
            if (hp.value.len > 0) alloc.free(@constCast(hp.value));
        };
        for (0..header_count) |idx| {
            win32.CoTaskMemFree(@ptrCast(header_names[idx]));
            win32.CoTaskMemFree(@ptrCast(header_values[idx]));
        }

        const body = self.readRequestBody(req) catch |err| switch (err) {
            error.OutOfMemory => return com.S_OK,
        };
        defer if (body) |b| alloc.free(b);
        const body_slice: []const u8 = if (body) |b| b else "";

        var deferral: ?*com.ICoreWebView2Deferral = null;
        if (com.failed(args.vtable.GetDeferral(args, &deferral))) return com.S_OK;
        const def = deferral orelse return com.S_OK;

        const token = self.next_token;
        self.next_token += 1;
        _ = args.vtable.AddRef(args);
        self.deferred.put(alloc, token, .{ .args = args, .deferral = def }) catch {
            _ = def.vtable.Complete(def);
            _ = def.vtable.Release(def);
            _ = args.vtable.Release(args);
            return com.S_OK;
        };

        const win_id = self.windowIdForIdent(win.ident) orelse {
            self.failDeferred(token);
            return com.S_OK;
        };
        const req_id = self.pending.insert(alloc, win_id, .{ .backend = self, .token = token }) catch {
            _ = self.deferred.fetchRemove(token);
            _ = def.vtable.Complete(def);
            _ = def.vtable.Release(def);
            _ = args.vtable.Release(args);
            return com.S_OK;
        };

        for (self.scheme_slots.items) |slot| {
            if (!std.ascii.eqlIgnoreCase(slot.scheme, protocolScheme(uri))) continue;
            slot.handler.call(.{
                .request_id = req_id,
                .window_id = win_id,
                .scheme = slot.scheme,
                .method = method,
                .uri = uri,
                .headers = headers_buf[0..header_count],
                .body = body_slice,
            });
            return com.S_OK;
        }

        // No handler registered for this origin.
        self.failDeferred(token);
        return com.S_OK;
    }

    fn readHeaders(
        self: *WindowsWebView2Backend,
        req: *com.ICoreWebView2WebResourceRequest,
        names: *[max_headers][*:0]u16,
        values: *[max_headers][*:0]u16,
        cap: usize,
    ) usize {
        _ = self;
        var collection: ?*com.ICoreWebView2HttpRequestHeaders = null;
        if (com.failed(req.vtable.get_Headers(req, &collection))) return 0;
        const hdrs = collection orelse return 0;
        defer _ = hdrs.vtable.Release(hdrs);

        var iter: ?*com.ICoreWebView2HttpHeadersCollectionIterator = null;
        if (com.failed(hdrs.vtable.GetIterator(hdrs, &iter))) return 0;
        const it = iter orelse return 0;
        defer _ = it.vtable.Release(it);

        var count: usize = 0;
        var has_current: i32 = 0;
        if (com.failed(it.vtable.get_HasCurrentHeader(it, &has_current))) return 0;
        while (has_current != 0 and count < cap) {
            var name: ?[*:0]u16 = null;
            var value: ?[*:0]u16 = null;
            if (!com.failed(it.vtable.GetCurrentHeader(it, &name, &value))) {
                if (name != null and value != null) {
                    names[count] = name.?;
                    values[count] = value.?;
                    count += 1;
                }
            }
            if (com.failed(it.vtable.MoveNext(it, &has_current))) break;
        }
        return count;
    }

    fn readRequestBody(self: *WindowsWebView2Backend, req: *com.ICoreWebView2WebResourceRequest) !?[]u8 {
        var stream: ?*anyopaque = null;
        if (com.failed(req.vtable.get_Content(req, &stream))) return null;
        const raw = stream orelse return null;
        const istream: *win32.IStream = @ptrCast(@alignCast(raw));
        defer _ = istream.vtable.Release(istream);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var chunk: [16 * 1024]u8 = undefined;
        while (out.items.len < max_body_bytes) {
            var read: u32 = 0;
            if (com.failed(istream.vtable.Read(istream, @ptrCast(&chunk), chunk.len, &read))) break;
            if (read == 0) break;
            try out.appendSlice(self.allocator, chunk[0..read]);
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn respondPreflight(self: *WindowsWebView2Backend, win: *WinWindow, args: *com.ICoreWebView2WebResourceRequestedEventArgs) void {
        _ = win;
        const headers = "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: *\r\n" ++
            "Access-Control-Expose-Headers: Tauri-Response,Tauri-Callback,Tauri-Error,Content-Type\r\n" ++
            "Access-Control-Max-Age: 86400\r\n";

        const env = self.env orelse return;
        const headers_z = win32.toWide(self.allocator, headers) catch return;
        defer self.allocator.free(headers_z);
        const reason_z = win32.toWide(self.allocator, "No Content") catch return;
        defer self.allocator.free(reason_z);

        var resp: ?*com.ICoreWebView2WebResourceResponse = null;
        if (com.failed(env.vtable.CreateWebResourceResponse(env, null, 204, reason_z.ptr, headers_z.ptr, &resp))) return;
        if (resp) |r| {
            _ = args.vtable.put_Response(args, r);
            _ = r.vtable.Release(r);
        }
    }

    /// Completes a deferred request with a real response (main thread only).
    fn completeDeferred(
        self: *WindowsWebView2Backend,
        task: DeferredTask,
        status: u16,
        content_type: []const u8,
        extra_headers: []const types.HeaderPair,
        body: []const u8,
    ) void {
        const alloc = self.allocator;
        const env = self.env orelse return;

        var header_list: std.ArrayList(u8) = .empty;
        defer header_list.deinit(alloc);
        const w = &header_list;

        w.appendSlice(alloc, "Content-Type: ") catch return;
        w.appendSlice(alloc, content_type) catch return;
        w.appendSlice(alloc, "\r\n") catch return;
        // CORS: the page origin (`http://tauri.localhost`) differs from the IPC origin.
        w.appendSlice(alloc, "Access-Control-Allow-Origin: *\r\n") catch return;
        w.appendSlice(alloc, "Access-Control-Expose-Headers: Tauri-Response,Tauri-Callback,Tauri-Error,Content-Type,Content-Length,Access-Control-Allow-Origin\r\n") catch return;
        for (extra_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) continue;
            w.appendSlice(alloc, h.name) catch return;
            w.appendSlice(alloc, ": ") catch return;
            w.appendSlice(alloc, h.value) catch return;
            w.appendSlice(alloc, "\r\n") catch return;
        }

        const headers_z = win32.toWide(alloc, header_list.items) catch return;
        defer alloc.free(headers_z);
        const reason = switch (status) {
            204 => "No Content",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            500 => "Internal Server Error",
            else => "OK",
        };
        const reason_z = win32.toWide(alloc, reason) catch return;
        defer alloc.free(reason_z);

        const stream = if (body.len > 0)
            win32.SHCreateMemStream(body.ptr, @intCast(@min(body.len, @as(usize, std.math.maxInt(u32)))))
        else
            null;
        defer if (stream) |s| {
            const istream: *win32.IStream = @ptrCast(@alignCast(s));
            _ = istream.vtable.Release(istream);
        };

        var resp: ?*com.ICoreWebView2WebResourceResponse = null;
        const hr = env.vtable.CreateWebResourceResponse(env, stream, status, reason_z.ptr, headers_z.ptr, &resp);
        if (!com.failed(hr)) {
            if (resp) |r| {
                _ = task.args.vtable.put_Response(task.args, r);
                _ = r.vtable.Release(r);
            }
        }
        _ = task.deferral.vtable.Complete(task.deferral);
        _ = task.deferral.vtable.Release(task.deferral);
        _ = task.args.vtable.Release(task.args);
    }

    fn failDeferred(self: *WindowsWebView2Backend, token: u64) void {
        const entry = self.deferred.fetchRemove(token) orelse return;
        self.completeDeferred(entry.value, 500, "text/plain", &.{}, "request canceled");
    }

    // ----------------------------------------------------------------------
    // Event loop
    // ----------------------------------------------------------------------

    pub fn step(self: *WindowsWebView2Backend, mode: types.StepMode) bool {
        self.drainCompletions();
        self.processCloseRequests();
        if (self.quit) return false;

        if (mode == .blocking) {
            _ = win32.MsgWaitForMultipleObjectsEx(
                1,
                &self.wakeup_event,
                1000,
                win32.QS_ALLINPUT,
                win32.MWMO_INPUTAVAILABLE,
            );
            _ = win32.ResetEvent(self.wakeup_event);
        }
        self.pumpMessages();
        self.drainCompletions();
        self.processCloseRequests();

        if (self.quit) return false;
        if (self.windows.count() > 0) {
            self.had_windows = true;
        } else if (self.had_windows) {
            return false;
        }
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

    fn processCloseRequests(self: *WindowsWebView2Backend) void {
        var idents: std.ArrayList(u64) = .empty;
        defer idents.deinit(self.allocator);
        var it = self.windows.iterator();
        while (it.next()) |slot| {
            if (slot.value_ptr.*.close_requested) idents.append(self.allocator, slot.value_ptr.*.ident) catch {};
        }
        for (idents.items) |ident| self.closeWindowByIdent(ident);
    }

    pub fn completeRequest(self: *WindowsWebView2Backend, req_id: types.RequestId, resp: types.SchemeResponse) types.WebviewError!void {
        self.completions.push(req_id, resp) catch return error.OutOfMemory;
        self.wakeup();
    }

    fn drainCompletions(self: *WindowsWebView2Backend) void {
        while (self.completions.tryPop()) |item_val| {
            var item = item_val;
            defer item.deinit(self.allocator);

            const entry = self.pending.take(item.request_id) orelse continue; // canceled / stale
            const task = self.deferred.fetchRemove(entry.payload.token) orelse continue;

            // `QueuedCompletion` owns mutable `OwnedHeader`s; `completeDeferred` only reads names and
            // values, so a bounded stack view avoids a second heap allocation.
            var hdrs: [16]types.HeaderPair = undefined;
            const n = @min(item.extra_headers.len, hdrs.len);
            for (item.extra_headers[0..n], 0..) |h, i| hdrs[i] = .{ .name = h.name, .value = h.value };
            self.completeDeferred(task.value, item.status_code, item.content_type, hdrs[0..n], item.body.slice());
        }
    }

    // ----------------------------------------------------------------------
    // Custom URI schemes
    // ----------------------------------------------------------------------

    pub fn registerScheme(self: *WindowsWebView2Backend, scheme: []const u8, handler: types.SchemeHandler) types.WebviewError!void {
        if (scheme.len == 0) return error.InvalidArgument;
        for (self.scheme_slots.items) |slot| {
            if (std.ascii.eqlIgnoreCase(slot.scheme, scheme)) return; // idempotent, like GTK
        }

        const slot = self.allocator.create(SchemeSlot) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(slot);
        const owned = self.allocator.dupe(u8, scheme) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned);
        slot.* = .{ .handler = handler, .scheme = owned };
        self.scheme_slots.append(self.allocator, slot) catch return error.OutOfMemory;
    }

    // ----------------------------------------------------------------------
    // Windows
    // ----------------------------------------------------------------------

    fn windowByIdent(self: *WindowsWebView2Backend, ident: u64) ?*WinWindow {
        var it = self.windows.iterator();
        while (it.next()) |slot| {
            if (slot.value_ptr.*.ident == ident) return slot.value_ptr.*;
        }
        return null;
    }

    fn windowIdForIdent(self: *WindowsWebView2Backend, ident: u64) ?types.WindowId {
        var it = self.windows.iterator();
        while (it.next()) |slot| {
            if (slot.value_ptr.*.ident == ident) return slot.handle;
        }
        return null;
    }

    pub fn createWindow(self: *WindowsWebView2Backend, cfg: types.WindowConfig) types.WebviewError!types.WindowId {
        const alloc = self.allocator;
        const env = self.env orelse return error.PlatformFailure;
        _ = env;

        const title_z = win32.toWide(alloc, cfg.title) catch return error.OutOfMemory;
        defer alloc.free(title_z);
        const class_z = win32.toWide(alloc, self.windowClass()) catch return error.OutOfMemory;
        defer alloc.free(class_z);

        const top_level = cfg.parent_native_handle == null;
        const style: u32 = blk: {
            if (!top_level) break :blk win32.WS_CHILD | win32.WS_CLIPCHILDREN;
            var s: u32 = win32.WS_OVERLAPPEDWINDOW | win32.WS_CLIPCHILDREN;
            if (!cfg.decorations) s = win32.WS_POPUP | win32.WS_CLIPCHILDREN;
            if (!cfg.resizable) s &= ~@as(u32, win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX);
            break :blk s;
        };
        const ex_style: u32 = if (cfg.always_on_top) win32.WS_EX_TOPMOST else 0;

        // Physical size: DPI is unknown before the HWND exists, so start at 96 and let
        // `WM_DPICHANGED` / the first `WM_SIZE` correct the WebView2 bounds (they use the client
        // rect, which is already physical).
        const physical_w = util.logicalToPhysical(cfg.size.width.v, win32_base_dpi);
        const physical_h = util.logicalToPhysical(cfg.size.height.v, win32_base_dpi);

        // `CW_USEDEFAULT` is `0x80000000`, i.e. `INT_MIN`, so it must be written as a bit-cast.
        const cw_used_default: i32 = @bitCast(@as(u32, 0x80000000));
        const x = if (cfg.position) |p| util.logicalToPhysical(p.x.v, win32_base_dpi) else cw_used_default;
        const y = if (cfg.position) |p| util.logicalToPhysical(p.y.v, win32_base_dpi) else cw_used_default;

        const hwnd = win32.CreateWindowExW(
            ex_style,
            class_z.ptr,
            title_z.ptr,
            style,
            x,
            y,
            @max(physical_w, 1),
            @max(physical_h, 1),
            if (cfg.parent_native_handle) |p| @ptrCast(p) else null,
            null,
            win32.GetModuleHandleW(null),
            null,
        ) orelse return error.PlatformFailure;

        const win = alloc.create(WinWindow) catch {
            _ = win32.DestroyWindow(hwnd);
            return error.OutOfMemory;
        };
        win.* = .{
            .backend = self,
            .hwnd = hwnd,
            .ident = self.next_ident,
            .want_visible = cfg.visible,
            .top_level = top_level,
            .resizable = cfg.resizable,
            .decorations = cfg.decorations,
            .always_on_top = cfg.always_on_top,
            .devtools = cfg.devtools,
            .min_size = cfg.min_size,
            .max_size = cfg.max_size,
        };
        self.next_ident += 1;

        win.title = alloc.dupe(u8, cfg.title) catch {
            alloc.destroy(win);
            _ = win32.DestroyWindow(hwnd);
            return error.OutOfMemory;
        };

        const win_id = self.windows.acquire(alloc, win) catch {
            alloc.destroy(win);
            _ = win32.DestroyWindow(hwnd);
            return error.OutOfMemory;
        };

        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @intCast(@intFromPtr(win)));

        for (cfg.init_scripts) |script| {
            const copy = alloc.dupe(u8, script) catch continue;
            win.queued_scripts.append(alloc, copy) catch alloc.free(copy);
        }
        if (cfg.initial_html) |html| {
            win.queued_html = alloc.dupe(u8, html) catch null;
        } else if (cfg.initial_url) |url| {
            win.queued_url = alloc.dupe(u8, url) catch null;
        }

        if (cfg.fullscreen) _ = win32.ShowWindow(hwnd, win32.SW_MAXIMIZE);
        self.applyWindowFrame(win);

        const handler = self.newHandler(win.ident, .controller_ready, com.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler);
        if (com.failed(self.env.?.vtable.CreateCoreWebView2Controller(self.env.?, hwnd, @ptrCast(handler)))) {
            self.closeWindow(win_id) catch {};
            return error.PlatformFailure;
        }
        return win_id;
    }

    fn applyWindowFrame(self: *WindowsWebView2Backend, win: *WinWindow) void {
        _ = self;
        if (!win.top_level) return;
        if (win.decorations) {
            // Dark title bar on Windows 10 20H1+; failure on older builds is harmless.
            var dark: i32 = 1;
            _ = win32.DwmSetWindowAttribute(win.hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(i32));
        }
        if (!win.want_visible) _ = win32.ShowWindow(win.hwnd, win32.SW_HIDE);
    }

    pub fn closeWindow(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        self.closeWindowByIdent(win.*.ident);
    }

    fn closeWindowByIdent(self: *WindowsWebView2Backend, ident: u64) void {
        const win_id = self.windowIdForIdent(ident) orelse return;
        const win = self.windows.get(win_id) orelse return;

        const w = win.*;
        w.close_requested = true;
        _ = self.pending.cancelForWindow(self.allocator, win_id, PendingToken.cancel);

        if (w.webview) |wv| {
            if (w.msg_token != 0) _ = wv.vtable.remove_WebMessageReceived(wv, w.msg_token);
            if (w.resource_token != 0) _ = wv.vtable.remove_WebResourceRequested(wv, w.resource_token);
            if (w.close_token != 0) _ = wv.vtable.remove_WindowCloseRequested(wv, w.close_token);
            _ = wv.vtable.Release(wv);
            w.webview = null;
        }
        if (w.controller) |c| {
            _ = c.vtable.Close(c);
            _ = c.vtable.Release(c);
            w.controller = null;
        }

        _ = win32.SetWindowLongPtrW(w.hwnd, win32.GWLP_USERDATA, 0);
        _ = win32.DestroyWindow(w.hwnd);

        const removed = self.windows.release(win_id) catch return;
        if (self.close_handler) |ch| ch.call(win_id);
        removed.deinit(self.allocator);
        self.allocator.destroy(removed);
    }

    pub fn nativeHandle(self: *WindowsWebView2Backend, win_id: types.WindowId) ?*anyopaque {
        const win = self.windows.get(win_id) orelse return null;
        return win.*.hwnd;
    }

    // ----------------------------------------------------------------------
    // Window properties
    // ----------------------------------------------------------------------

    pub fn setTitle(self: *WindowsWebView2Backend, win_id: types.WindowId, title: []const u8) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        const z = win32.toWide(self.allocator, title) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        _ = win32.SetWindowTextW(win.*.hwnd, z.ptr);
    }

    pub fn setSize(self: *WindowsWebView2Backend, win_id: types.WindowId, size: types.LogicalSize) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        const dpi = currentDpi(win.*.hwnd);
        self.resizeClient(win.*, util.logicalToPhysical(size.width.v, dpi), util.logicalToPhysical(size.height.v, dpi));
    }

    fn resizeClient(self: *WindowsWebView2Backend, win: *WinWindow, client_w: i32, client_h: i32) void {
        _ = self;
        var frame: win32.RECT = .{};
        var client: win32.RECT = .{};
        _ = win32.GetWindowRect(win.hwnd, &frame);
        _ = win32.GetClientRect(win.hwnd, &client);
        const extra_w = frame.width() - client.width();
        const extra_h = frame.height() - client.height();
        _ = win32.SetWindowPos(
            win.hwnd,
            null,
            0,
            0,
            @max(client_w + extra_w, 1),
            @max(client_h + extra_h, 1),
            win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        );
    }

    pub fn setMinSize(self: *WindowsWebView2Backend, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        win.*.min_size = size;
    }

    pub fn setMaxSize(self: *WindowsWebView2Backend, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        win.*.max_size = size;
    }

    pub fn setPosition(self: *WindowsWebView2Backend, win_id: types.WindowId, pos: types.LogicalPoint) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        const dpi = currentDpi(win.*.hwnd);
        _ = win32.SetWindowPos(
            win.*.hwnd,
            null,
            util.logicalToPhysical(pos.x.v, dpi),
            util.logicalToPhysical(pos.y.v, dpi),
            0,
            0,
            win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        );
    }

    pub fn setResizable(self: *WindowsWebView2Backend, win_id: types.WindowId, resizable: bool) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        win.*.resizable = resizable;
        self.updateStyle(win.*);
    }

    fn updateStyle(self: *WindowsWebView2Backend, win: *WinWindow) void {
        _ = self;
        if (!win.top_level) return;
        var style = win32.GetWindowLongW(win.hwnd, win32.GWL_STYLE);
        const bits: i32 = @bitCast(@as(u32, win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX));
        if (win.resizable) {
            style |= bits;
        } else {
            style &= ~bits;
        }
        _ = win32.SetWindowLongW(win.hwnd, win32.GWL_STYLE, style);
        _ = win32.SetWindowPos(win.hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED);
    }

    pub fn setMinimized(self: *WindowsWebView2Backend, win_id: types.WindowId, minimized: bool) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        _ = win32.ShowWindow(win.*.hwnd, if (minimized) win32.SW_MINIMIZE else win32.SW_RESTORE);
    }

    pub fn setMaximized(self: *WindowsWebView2Backend, win_id: types.WindowId, maximized: bool) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        _ = win32.ShowWindow(win.*.hwnd, if (maximized) win32.SW_MAXIMIZE else win32.SW_RESTORE);
    }

    pub fn setFullscreen(self: *WindowsWebView2Backend, win_id: types.WindowId, fullscreen: bool) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        _ = win32.ShowWindow(win.*.hwnd, if (fullscreen) win32.SW_MAXIMIZE else win32.SW_RESTORE);
    }

    pub fn setVisible(self: *WindowsWebView2Backend, win_id: types.WindowId, visible: bool) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        win.*.want_visible = visible;
        _ = win32.ShowWindow(win.*.hwnd, if (visible) win32.SW_SHOW else win32.SW_HIDE);
    }

    pub fn setDecorations(self: *WindowsWebView2Backend, win_id: types.WindowId, decorations: bool) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        win.*.decorations = decorations;
        // Style surgery on decorations is not worth the risk on Windows: Tauri itself recreates the
        // window instead. We record the flag so `createWindow`-time behaviour stays consistent.
    }

    pub fn setAlwaysOnTop(self: *WindowsWebView2Backend, win_id: types.WindowId, on_top: bool) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        win.*.always_on_top = on_top;
        _ = win32.SetWindowPos(
            win.*.hwnd,
            if (on_top) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE,
        );
    }

    pub fn setFocus(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        _ = win32.SetForegroundWindow(win.*.hwnd);
        if (win.*.controller) |c| _ = c.vtable.MoveFocus(c, 1); // COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC
    }

    pub fn startDrag(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        // Classical frameless drag: hand the caption hit-test to the window manager, which enters a
        // modal move loop until the mouse is released (identical to `tao`'s implementation).
        _ = win32.ReleaseCapture();
        _ = win32.SendMessageW(win.*.hwnd, win32.WM_NCLBUTTONDOWN, win32.HTCAPTION, 0);
    }

    pub fn addInitScript(self: *WindowsWebView2Backend, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        if (win.*.webview) |wv| {
            self.addDocumentScript(win.*, wv, script);
            return;
        }
        const copy = self.allocator.dupe(u8, script) catch return error.OutOfMemory;
        win.*.queued_scripts.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return error.OutOfMemory;
        };
    }

    pub fn evalJs(self: *WindowsWebView2Backend, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        const wv = win.*.webview orelse return; // silently dropped until ready (same as macOS pre-load)
        const z = win32.toWide(self.allocator, script) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        _ = wv.vtable.ExecuteScript(wv, z.ptr, null);
    }

    pub fn navigate(self: *WindowsWebView2Backend, win_id: types.WindowId, url: []const u8) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        if (win.*.webview) |wv| {
            self.navigateUrl(win.*, wv, url);
            return;
        }
        const copy = self.allocator.dupe(u8, url) catch return error.OutOfMemory;
        if (win.*.queued_url) |old| self.allocator.free(old);
        win.*.queued_url = copy;
    }

    pub fn loadHtml(self: *WindowsWebView2Backend, win_id: types.WindowId, html: []const u8, base_uri: ?[]const u8) types.WebviewError!void {
        _ = base_uri; // `NavigateToString` has no base-URL parameter (documented limitation).
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        if (win.*.webview) |wv| {
            self.navigateHtml(win.*, wv, html);
            return;
        }
        const copy = self.allocator.dupe(u8, html) catch return error.OutOfMemory;
        if (win.*.queued_html) |old| self.allocator.free(old);
        win.*.queued_html = copy;
    }

    pub fn openDevtools(self: *WindowsWebView2Backend, win_id: types.WindowId) types.WebviewError!void {
        const win = self.windows.get(win_id) orelse return error.WindowNotFound;
        const wv = win.*.webview orelse return;
        _ = wv.vtable.OpenDevToolsWindow(wv);
    }
};

const SchemeSlot = struct {
    handler: types.SchemeHandler,
    scheme: []u8,
};

const win32_base_dpi: u32 = 96;

fn currentDpi(hwnd: win32.HWND) u32 {
    const dpi = win32.GetDpiForWindow(hwnd);
    return if (dpi == 0) win32_base_dpi else dpi;
}

fn protocolScheme(uri: []const u8) []const u8 {
    return switch (util.classify(uri) orelse .tauri) {
        .tauri => "tauri",
        .ipc => "ipc",
        .asset => "asset",
    };
}

// ---------------------------------------------------------------------------
// WndProc
// ---------------------------------------------------------------------------

const WM_GETMINMAXINFO = 0x0024;
const MINMAXINFO = extern struct {
    reserved0: win32.POINT = .{},
    reserved1: win32.POINT = .{},
    max_size: win32.POINT = .{},
    max_position: win32.POINT = .{},
    min_track_size: win32.POINT = .{},
};

fn ztsWndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    const raw = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    const win: ?*WinWindow = if (raw == 0) null else @ptrFromInt(@as(usize, @intCast(raw)));

    switch (msg) {
        win32.WM_CLOSE => {
            // Defer the teardown to the event-loop turn so we never free a window record while
            // still inside its own window procedure (no re-entrancy, no use-after-free).
            if (win) |w| w.close_requested = true;
            return 0;
        },
        win32.WM_SIZE => {
            if (win) |w| {
                const client_w = win32.loword(lparam);
                const client_h = win32.hiword(lparam);
                if (w.controller) |c| {
                    _ = c.vtable.put_Bounds(c, .{
                        .left = 0,
                        .top = 0,
                        .right = client_w,
                        .bottom = client_h,
                    });
                }
            }
            return 0;
        },
        win32.WM_DPICHANGED => {
            if (win) |w| {
                const new_dpi: u32 = win32.loword(lparam);
                if (new_dpi > 0) w.dpi = new_dpi;
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_GETMINMAXINFO => {
            if (win) |w| {
                const info: *MINMAXINFO = @ptrFromInt(@as(usize, @intCast(lparam)));
                const dpi = currentDpi(hwnd);
                if (w.min_size) |ms| {
                    info.min_track_size = .{
                        .x = util.logicalToPhysical(ms.width.v, dpi),
                        .y = util.logicalToPhysical(ms.height.v, dpi),
                    };
                }
                if (w.max_size) |ms| {
                    info.max_size = .{
                        .x = util.logicalToPhysical(ms.width.v, dpi),
                        .y = util.logicalToPhysical(ms.height.v, dpi),
                    };
                }
            }
            return 0;
        },
        win32.WM_NCDESTROY => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// `WinWindow` needs the cached event tokens too.
comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows.zig is Windows-only; import it behind `has_native_windows` in mod.zig");
    }
}

// ============================================================================
// Real Native Win32 + WebView2 End-to-End Integration Test (GitHub Actions `windows-latest`)
// ============================================================================

test "WindowsWebView2Backend renders HTML, injects UserScript, streams binary & JSON over `tauri://` + `ipc://`, and shuts down with 0 leaks" {
    const backend = WindowsWebView2Backend.init(testing.allocator, testing.io) catch |err| switch (err) {
        error.DisplayUnavailable => {
            // Loud skip: `.github/workflows/ci.yml` greps for `OK windows-wv2` and FAILS the job
            // when the marker is absent, so the native gate can never silently degrade to a no-op.
            std.debug.print("\n[WindowsWebView2Backend E2E] SKIPPED: WebView2 runtime not found\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer backend.deinit();

    std.debug.print("\n[WindowsWebView2Backend E2E] WebView2 runtime {s} (fixed={})\n", .{
        backend.runtime.versionString(),
        backend.runtime.fixed,
    });

    const E2eCtx = struct {
        backend: *WindowsWebView2Backend,
        allocator: Allocator,
        final_report: ?[]u8 = null,

        fn onTauriScheme(userdata: ?*anyopaque, req: types.SchemeRequest) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const html =
                \\<!doctype html>
                \\<html><body><script>
                \\(async () => {
                \\  try {
                \\    // 1. Large 96 KiB binary round trip over `http://ipc.localhost` POST (exercises the IStream body).
                \\    const tx = new Uint8Array(98304);
                \\    for (let i = 0; i < tx.length; i++) tx[i] = (i * 31 + 7) & 0xff;
                \\    const binRes = await fetch("http://ipc.localhost/xor", {
                \\      method: "POST",
                \\      headers: { "Content-Type": "application/octet-stream", "X-Test-Token": "zts-42" },
                \\      body: tx,
                \\    });
                \\    const rx = new Uint8Array(await binRes.arrayBuffer());
                \\    const binOk = rx.length === tx.length && rx[0] === (tx[0] ^ 0x5a) && rx[98303] === (tx[98303] ^ 0x5a);
                \\
                \\    // 2. JSON RPC completed from a real background OS thread (CompletionQueue).
                \\    const jsonRes = await fetch("http://ipc.localhost/compute", {
                \\      method: "POST",
                \\      headers: { "Content-Type": "application/json" },
                \\      body: JSON.stringify({ a: 20, b: 22 }),
                \\    });
                \\    const data = await jsonRes.json();
                \\
                \\    window.__ztsPostMessage({
                \\      bootInjected: window.__BOOT_TAG__ === "injected-ok",
                \\      binOk,
                \\      tauriHdr: jsonRes.headers.get("tauri-response"),
                \\      cors: binRes.headers.get("access-control-allow-origin"),
                \\      sum: data.sum,
                \\      ua: navigator.userAgent.indexOf("Windows") >= 0,
                \\    });
                \\  } catch (e) {
                \\    window.__ztsPostMessage({ err: String(e) });
                \\  }
                \\})();
                \\</script></body></html>
            ;
            self.backend.completeRequest(req.request_id, .{
                .status_code = 200,
                .content_type = "text/html; charset=utf-8",
                .body = .static(html),
            }) catch unreachable;
        }

        fn onIpcScheme(userdata: ?*anyopaque, req: types.SchemeRequest) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (std.mem.endsWith(u8, req.uri, "/xor")) {
                const tok = req.header("x-test-token") orelse "";
                if (!std.mem.eql(u8, tok, "zts-42")) {
                    self.backend.completeRequest(req.request_id, .{
                        .status_code = 403,
                        .content_type = "text/plain",
                        .body = .static("bad header"),
                    }) catch unreachable;
                    return;
                }
                const out = self.allocator.alloc(u8, req.body.len) catch unreachable;
                for (req.body, 0..) |b, i| out[i] = b ^ 0x5a;
                self.backend.completeRequest(req.request_id, .{
                    .status_code = 200,
                    .content_type = "application/octet-stream",
                    .body = types.OwnedBytes.fromOwnedSlice(self.allocator, out),
                }) catch unreachable;
                return;
            }

            // `/compute`: complete from a detached worker thread — proves cross-thread `completeRequest`.
            const t = std.Thread.spawn(.{}, bgComputeWorker, .{ self.backend, self.allocator, req.request_id }) catch unreachable;
            t.detach();
        }

        fn bgComputeWorker(b: *WindowsWebView2Backend, alloc: Allocator, req_id: types.RequestId) void {
            const payload = alloc.dupe(u8, "{\"sum\":42}") catch unreachable;
            b.completeRequest(req_id, .{
                .status_code = 200,
                .content_type = "application/json",
                .extra_headers = &.{.{ .name = "Tauri-Response", .value = "ok" }},
                .body = types.OwnedBytes.fromOwnedSlice(alloc, payload),
            }) catch unreachable;
        }

        fn onJsMessage(userdata: ?*anyopaque, _: types.WindowId, msg: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.final_report = self.allocator.dupe(u8, msg) catch null;
            self.backend.requestQuit();
        }
    };

    var ctx: E2eCtx = .{ .backend = backend, .allocator = testing.allocator };
    defer if (ctx.final_report) |r| testing.allocator.free(r);

    backend.message_handler = .{ .userdata = &ctx, .onMessage = E2eCtx.onJsMessage };
    try backend.registerScheme("tauri", .{ .userdata = &ctx, .onRequest = E2eCtx.onTauriScheme });
    try backend.registerScheme("ipc", .{ .userdata = &ctx, .onRequest = E2eCtx.onIpcScheme });

    const win = try backend.createWindow(.{
        .title = "Z-Ts Native WebView2 E2E",
        .size = .wh(640, 480),
        .position = .{ .x = .init(24), .y = .init(48) },
        .visible = true,
        .init_scripts = &.{"window.__BOOT_TAG__ = 'injected-ok';"},
        .initial_url = "tauri://localhost/index.html",
    });

    try testing.expect(backend.nativeHandle(win) != null);
    try testing.expect(backend.nativeHandle(types.WindowId.invalid) == null);

    // Property round trip (must not crash and must keep the window alive).
    try backend.setTitle(win, "Z-Ts Native WebView2 E2E (retitled)");
    try backend.setMinSize(win, .wh(320, 240));
    try backend.setMaxSize(win, .wh(1280, 900));
    try backend.setResizable(win, true);
    try backend.setAlwaysOnTop(win, true);
    try backend.setAlwaysOnTop(win, false);
    try backend.setPosition(win, .{ .x = .init(32), .y = .init(64) });
    try backend.setSize(win, .wh(720, 520));

    const Watchdog = struct {
        b: *WindowsWebView2Backend,
        done: std.atomic.Value(bool) = .init(false),
        timed_out: std.atomic.Value(bool) = .init(false),

        fn run(w: *@This(), io: Io) void {
            var ticks: usize = 0;
            while (ticks < 200 and !w.done.load(.acquire)) : (ticks += 1) {
                io.sleep(.fromMilliseconds(100), .awake) catch {};
            }
            if (!w.done.load(.acquire)) {
                w.timed_out.store(true, .release);
                w.b.requestQuit();
            }
        }
    };

    var wd: Watchdog = .{ .b = backend };
    const wd_thread = try std.Thread.spawn(.{}, Watchdog.run, .{ &wd, testing.io });

    while (backend.step(.blocking)) {}

    wd.done.store(true, .release);
    wd_thread.join();

    if (wd.timed_out.load(.acquire)) {
        std.debug.print("\n[WindowsWebView2Backend E2E] Watchdog timed out waiting for WebView2 JS report!\n", .{});
        return error.WebView2E2eTimeout;
    }

    const report = ctx.final_report orelse return error.MissingJsReport;
    const ParsedReport = struct {
        err: ?[]const u8 = null,
        bootInjected: ?bool = null,
        binOk: ?bool = null,
        tauriHdr: ?[]const u8 = null,
        cors: ?[]const u8 = null,
        sum: ?i64 = null,
        ua: ?bool = null,
    };
    var parsed = try std.json.parseFromSlice(ParsedReport, testing.allocator, report, .{});
    defer parsed.deinit();

    if (parsed.value.err) |e| {
        std.debug.print("\n[WindowsWebView2Backend E2E] JS error: {s}\n", .{e});
        return error.WebView2JsError;
    }

    try testing.expect(parsed.value.bootInjected orelse false);
    try testing.expect(parsed.value.binOk orelse false);
    try testing.expectEqualStrings("ok", parsed.value.tauriHdr orelse "");
    try testing.expectEqualStrings("*", parsed.value.cors orelse "");
    try testing.expectEqual(@as(i64, 42), parsed.value.sum orelse -1);
    try testing.expect(parsed.value.ua orelse false);

    try backend.closeWindow(win);
    try testing.expectEqual(@as(u32, 0), backend.windows.count());
    try testing.expect(!backend.step(.poll));

    // CI marker: verified by `.github/workflows/ci.yml` so the native gate can never silently skip.
    std.debug.print(
        "OK windows-wv2 checks=10 binary=98304 sum={d} runtime={s}\n",
        .{ parsed.value.sum.?, backend.runtime.versionString() },
    );
}
