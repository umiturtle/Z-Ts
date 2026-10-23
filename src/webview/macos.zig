//! Native macOS Backend — `Cocoa` (`NSApplication` / `NSWindow`) + `WKWebView` (`src/webview/macos.zig`, `M3-01`).
//!
//! Public Zig wrapper around the Objective-C shim in [`macos_shim.m`](macos_shim.m). The entire
//! Objective-C / AppKit surface is flattened into a handful of `zts_macos_*` C functions so this
//! module stays pure Zig (no `@cImport`, no `addTranslateC`, no Objective-C runtime calls) and
//! mirrors [`linux.zig`](linux.zig) one-for-one.
//!
//! Architecture & Safety Guarantees:
//! 1. **Step-driven event loop**: `step(.blocking / .poll)` pumps exactly one AppKit run-loop
//!    iteration; `wakeup()` posts an `NSEventTypeApplicationDefined` event so a blocked
//!    `nextEventMatchingMask:untilDate:distantFuture` returns immediately (no threads, no timers).
//! 2. **`WKURLSchemeTask` isolation**: the raw task object is retained by the shim only. Zig sees a
//!    53-bit generational [`types.RequestId`] plus an opaque `u64` token.
//! 3. **`stopURLSchemeTask:` race immunity**: the shim drops the token the instant WebKit stops a
//!    task, and [`pending.PendingTable`] independently validates the generation counter — a late
//!    worker completion can therefore never resurrect a dead task (zero ABA, zero crash).
//! 4. **CSS top-left ⇔ Cocoa bottom-left** conversion lives in [`coords.zig`](coords.zig) and is
//!    unit-tested on every OS.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const foundation = @import("zts_foundation");
const types = @import("types.zig");
const pending_mod = @import("pending.zig");
pub const coords = @import("coords.zig");

/// Upper bound of request headers forwarded across the C ABI (mirrors real-world browser limits).
const max_headers: usize = 48;

// ---------------------------------------------------------------------------
// Objective-C shim C ABI (`src/webview/macos_shim.m`)
// ---------------------------------------------------------------------------

const shim = struct {
    const SchemeCb = *const fn (
        userdata: ?*anyopaque,
        win: u64,
        token: u64,
        scheme: [*:0]const u8,
        method: [*:0]const u8,
        uri: [*:0]const u8,
        names: [*]const ?[*:0]const u8,
        values: [*]const ?[*:0]const u8,
        count: usize,
        body: ?[*]const u8,
        body_len: usize,
    ) callconv(.c) void;

    const MessageCb = *const fn (userdata: ?*anyopaque, win: u64, json: [*:0]const u8) callconv(.c) void;
    const CloseCb = *const fn (userdata: ?*anyopaque, win: u64) callconv(.c) void;

    extern fn zts_macos_backend_new(regular: c_int) ?*anyopaque;
    extern fn zts_macos_backend_free(h: ?*anyopaque) void;
    extern fn zts_macos_step(h: ?*anyopaque, block: c_int) c_int;
    extern fn zts_macos_wakeup(h: ?*anyopaque) void;
    extern fn zts_macos_request_quit(h: ?*anyopaque) void;
    extern fn zts_macos_quit_requested(h: ?*anyopaque) c_int;
    extern fn zts_macos_preflight_count(h: ?*anyopaque) u64;
    extern fn zts_macos_set_callbacks(
        h: ?*anyopaque,
        msg_userdata: ?*anyopaque,
        msg_cb: MessageCb,
        close_userdata: ?*anyopaque,
        close_cb: CloseCb,
    ) void;
    extern fn zts_macos_screen_visible_frame(h: ?*anyopaque, x: ?*f64, y: ?*f64, w: ?*f64, ht: ?*f64) void;

    extern fn zts_macos_register_scheme(h: ?*anyopaque, scheme: [*:0]const u8, userdata: ?*anyopaque, cb: SchemeCb) void;
    extern fn zts_macos_scheme_respond(
        h: ?*anyopaque,
        token: u64,
        status: c_int,
        content_type: [*:0]const u8,
        names: [*]const ?[*:0]const u8,
        values: [*]const ?[*:0]const u8,
        count: usize,
        body: ?[*]const u8,
        body_len: usize,
    ) void;
    extern fn zts_macos_scheme_fail(h: ?*anyopaque, token: u64) void;

    extern fn zts_macos_window_new(
        h: ?*anyopaque,
        title: [*:0]const u8,
        width: f64,
        height: f64,
        resizable: c_int,
        decorations: c_int,
        transparent: c_int,
        always_on_top: c_int,
        visible: c_int,
        fullscreen: c_int,
        devtools: c_int,
        has_pos: c_int,
        pos_x: f64,
        pos_y: f64,
        parent_nsview: ?*anyopaque,
        url: ?[*:0]const u8,
        html: ?[*:0]const u8,
    ) u64;
    extern fn zts_macos_window_close(h: ?*anyopaque, ident: u64) c_int;
    extern fn zts_macos_window_native(h: ?*anyopaque, ident: u64) ?*anyopaque;
    extern fn zts_macos_window_frame(h: ?*anyopaque, ident: u64, x: ?*f64, y: ?*f64, w: ?*f64, ht: ?*f64) void;
    extern fn zts_macos_window_set_title(h: ?*anyopaque, ident: u64, title: [*:0]const u8) void;
    extern fn zts_macos_window_set_size(h: ?*anyopaque, ident: u64, width: f64, height: f64) void;
    extern fn zts_macos_window_set_min_size(h: ?*anyopaque, ident: u64, enabled: c_int, width: f64, height: f64) void;
    extern fn zts_macos_window_set_max_size(h: ?*anyopaque, ident: u64, enabled: c_int, width: f64, height: f64) void;
    extern fn zts_macos_window_set_position(h: ?*anyopaque, ident: u64, x: f64, y: f64) void;
    extern fn zts_macos_window_set_resizable(h: ?*anyopaque, ident: u64, value: c_int) void;
    extern fn zts_macos_window_set_minimized(h: ?*anyopaque, ident: u64, value: c_int) void;
    extern fn zts_macos_window_set_maximized(h: ?*anyopaque, ident: u64, value: c_int) void;
    extern fn zts_macos_window_set_fullscreen(h: ?*anyopaque, ident: u64, value: c_int) void;
    extern fn zts_macos_window_set_visible(h: ?*anyopaque, ident: u64, value: c_int) void;
    extern fn zts_macos_window_set_decorations(h: ?*anyopaque, ident: u64, value: c_int) void;
    extern fn zts_macos_window_set_always_on_top(h: ?*anyopaque, ident: u64, value: c_int) void;
    extern fn zts_macos_window_set_focus(h: ?*anyopaque, ident: u64) void;
    extern fn zts_macos_window_start_drag(h: ?*anyopaque, ident: u64) void;
    extern fn zts_macos_window_add_init_script(h: ?*anyopaque, ident: u64, script: [*:0]const u8) void;
    extern fn zts_macos_window_eval_js(h: ?*anyopaque, ident: u64, script: [*:0]const u8) void;
    extern fn zts_macos_window_navigate(h: ?*anyopaque, ident: u64, url: [*:0]const u8) void;
    extern fn zts_macos_window_load_html(h: ?*anyopaque, ident: u64, html: [*:0]const u8, base_url: ?[*:0]const u8) void;
    extern fn zts_macos_window_open_devtools(h: ?*anyopaque, ident: u64) void;
};

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

const MacWindow = struct {
    /// Opaque `unsigned long long` identity minted by the shim (1-based).
    native: u64,
    min_size: ?types.LogicalSize,
    max_size: ?types.LogicalSize,
};

const SchemeSlot = struct {
    backend: *MacOsBackend,
    handler: types.SchemeHandler,
    scheme_z: [:0]u8,
};

/// A scheme request parked in the shim's token table; only `(backend, token)` crosses threads.
const PendingToken = struct {
    backend: *MacOsBackend,
    token: u64,

    fn cancel(self: PendingToken) void {
        shim.zts_macos_scheme_fail(self.backend.handle, self.token);
    }
};

/// Native `NSWindow` frame in Cocoa coordinates (origin = bottom-left, Y grows upwards).
pub const CocoaFrame = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
};

pub const MacOsBackend = struct {
    allocator: Allocator,
    io: Io,
    handle: *anyopaque,
    windows: foundation.HandlePool(MacWindow, .window) = .empty,
    scheme_slots: std.ArrayList(*SchemeSlot) = .empty,
    pending: pending_mod.PendingTable(PendingToken) = .{},
    completions: pending_mod.CompletionQueue,

    message_handler: ?types.MessageHandler = null,
    close_handler: ?types.CloseHandler = null,

    /// Creates the shared `NSApplication` + `WKWebViewConfiguration` (Dock icon / menu bar enabled).
    pub fn init(allocator: Allocator, io: Io) types.WebviewError!*MacOsBackend {
        return initWithPolicy(allocator, io, true);
    }

    /// Creates the backend without a Dock icon / app menu — used by headless E2E tests so CI never
    /// steals focus or depends on `LSUIElement` bundle metadata.
    pub fn initAccessory(allocator: Allocator, io: Io) types.WebviewError!*MacOsBackend {
        return initWithPolicy(allocator, io, false);
    }

    fn initWithPolicy(allocator: Allocator, io: Io, regular: bool) types.WebviewError!*MacOsBackend {
        const handle = shim.zts_macos_backend_new(if (regular) 1 else 0) orelse return error.DisplayUnavailable;

        const self = allocator.create(MacOsBackend) catch {
            shim.zts_macos_backend_free(handle);
            return error.OutOfMemory;
        };
        self.* = .{
            .allocator = allocator,
            .io = io,
            .handle = handle,
            .completions = pending_mod.CompletionQueue.init(allocator, io),
        };

        shim.zts_macos_set_callbacks(handle, self, onJsMessage, self, onWindowClosed);
        return self;
    }

    pub fn deinit(self: *MacOsBackend) void {
        const alloc = self.allocator;

        // 1. Detach app callbacks FIRST so closing windows cannot re-enter a torn-down Zig backend.
        self.close_handler = null;
        self.message_handler = null;
        shim.zts_macos_set_callbacks(self.handle, null, onJsMessage, null, onWindowClosed);

        // 2. Cancel every in-flight request (fires `zts_macos_scheme_fail`, a no-op if already dead).
        self.pending.deinitWith(alloc, PendingToken.cancel);
        self.completions.deinit();

        // 3. Close all windows before releasing the shim (the shim owns the NSWindow objects).
        while (true) {
            var it = self.windows.iterator();
            const first = it.next() orelse break;
            _ = shim.zts_macos_window_close(self.handle, first.value_ptr.native);
            _ = self.windows.release(first.handle) catch {};
        }
        self.windows.deinit(alloc);

        for (self.scheme_slots.items) |slot| {
            alloc.free(slot.scheme_z);
            alloc.destroy(slot);
        }
        self.scheme_slots.deinit(alloc);

        shim.zts_macos_backend_free(self.handle);
        alloc.destroy(self);
    }

    // -----------------------------------------------------------------------
    // Event loop
    // -----------------------------------------------------------------------

    pub fn step(self: *MacOsBackend, mode: types.StepMode) bool {
        self.drainCompletions();
        if (shim.zts_macos_quit_requested(self.handle) != 0) return false;

        const rc = shim.zts_macos_step(self.handle, if (mode == .blocking) 1 else 0);
        self.drainCompletions();
        return rc != 0;
    }

    pub fn wakeup(self: *MacOsBackend) void {
        shim.zts_macos_wakeup(self.handle);
    }

    pub fn requestQuit(self: *MacOsBackend) void {
        shim.zts_macos_request_quit(self.handle);
    }

    pub fn quitRequested(self: *MacOsBackend) bool {
        return shim.zts_macos_quit_requested(self.handle) != 0;
    }

    /// Number of CORS preflights (`OPTIONS`) answered inside the shim instead of reaching Zig.
    /// Exposed for the E2E report + CI marker so preflight coverage is visible in the logs.
    pub fn preflightCount(self: *MacOsBackend) u64 {
        return shim.zts_macos_preflight_count(self.handle);
    }

    // -----------------------------------------------------------------------
    // Screen geometry
    // -----------------------------------------------------------------------

    pub fn screenVisibleFrame(self: *MacOsBackend) coords.ScreenFrame {
        var frame = coords.ScreenFrame{};
        shim.zts_macos_screen_visible_frame(self.handle, &frame.x, &frame.y, &frame.width, &frame.height);
        return frame;
    }

    // -----------------------------------------------------------------------
    // Custom URI schemes
    // -----------------------------------------------------------------------

    pub fn registerScheme(self: *MacOsBackend, scheme: []const u8, handler: types.SchemeHandler) types.WebviewError!void {
        if (scheme.len == 0) return error.InvalidArgument;

        const scheme_z = self.allocator.dupeSentinel(u8, scheme, 0) catch return error.OutOfMemory;
        errdefer self.allocator.free(scheme_z);

        const slot = self.allocator.create(SchemeSlot) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(slot);
        slot.* = .{ .backend = self, .handler = handler, .scheme_z = scheme_z };

        self.scheme_slots.append(self.allocator, slot) catch return error.OutOfMemory;
        shim.zts_macos_register_scheme(self.handle, scheme_z.ptr, slot, onSchemeRequest);
    }

    fn onSchemeRequest(
        userdata: ?*anyopaque,
        native_win: u64,
        token: u64,
        scheme: [*:0]const u8,
        method: [*:0]const u8,
        uri: [*:0]const u8,
        names: [*]const ?[*:0]const u8,
        values: [*]const ?[*:0]const u8,
        count: usize,
        body: ?[*]const u8,
        body_len: usize,
    ) callconv(.c) void {
        const slot: *SchemeSlot = @ptrCast(@alignCast(userdata orelse return));
        const self = slot.backend;

        const win_id = self.windowIdFor(native_win);
        if (!win_id.isValid()) {
            shim.zts_macos_scheme_fail(self.handle, token);
            return;
        }

        var header_buf: [max_headers]types.HeaderPair = undefined;
        const n = @min(count, max_headers);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const name_ptr = names[i] orelse continue;
            const value_ptr = values[i];
            header_buf[i] = .{
                .name = std.mem.span(name_ptr),
                .value = if (value_ptr) |v| std.mem.span(v) else "",
            };
        }

        const body_slice: []const u8 = if (body) |ptr| (if (body_len > 0) ptr[0..body_len] else &.{}) else &.{};

        const req_id = self.pending.insert(
            self.allocator,
            win_id,
            .{ .backend = self, .token = token },
        ) catch {
            shim.zts_macos_scheme_fail(self.handle, token);
            return;
        };

        slot.handler.call(.{
            .request_id = req_id,
            .window_id = win_id,
            .scheme = std.mem.span(scheme),
            .method = std.mem.span(method),
            .uri = std.mem.span(uri),
            .headers = header_buf[0..n],
            .body = body_slice,
        });
    }

    fn onJsMessage(userdata: ?*anyopaque, native_win: u64, json: [*:0]const u8) callconv(.c) void {
        const self: *MacOsBackend = @ptrCast(@alignCast(userdata orelse return));
        const mh = self.message_handler orelse return;
        const win_id = self.windowIdFor(native_win);
        mh.call(win_id, std.mem.span(json));
    }

    fn onWindowClosed(userdata: ?*anyopaque, native_win: u64) callconv(.c) void {
        const self: *MacOsBackend = @ptrCast(@alignCast(userdata orelse return));
        const win_id = self.windowIdFor(native_win);
        if (!win_id.isValid()) return;

        _ = self.pending.cancelForWindow(self.allocator, win_id, PendingToken.cancel);
        _ = self.windows.release(win_id) catch {};
        if (self.close_handler) |ch| ch.call(win_id);
    }

    /// Queues `resp` for the main thread (safe from ANY thread) and wakes the AppKit run loop.
    pub fn completeRequest(self: *MacOsBackend, req_id: types.RequestId, resp: types.SchemeResponse) types.WebviewError!void {
        self.completions.push(req_id, resp) catch return error.OutOfMemory;
        self.wakeup();
    }

    fn drainCompletions(self: *MacOsBackend) void {
        while (self.completions.tryPop()) |item_val| {
            var item = item_val;
            defer item.deinit(self.allocator);

            const entry = self.pending.take(item.request_id) orelse continue; // canceled / stale
            self.respondToShim(entry.payload.token, &item) catch {
                shim.zts_macos_scheme_fail(self.handle, entry.payload.token);
            };
        }
    }

    fn respondToShim(self: *MacOsBackend, token: u64, resp: *const types.QueuedCompletion) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const content_type = try arena.dupeSentinel(u8, resp.content_type, 0);

        const names = try arena.alloc(?[*:0]const u8, resp.extra_headers.len);
        const values = try arena.alloc(?[*:0]const u8, resp.extra_headers.len);
        for (resp.extra_headers, 0..) |h, idx| {
            const nz = try arena.dupeSentinel(u8, h.name, 0);
            const vz = try arena.dupeSentinel(u8, h.value, 0);
            names[idx] = nz.ptr;
            values[idx] = vz.ptr;
        }

        const bytes = resp.body.slice();
        shim.zts_macos_scheme_respond(
            self.handle,
            token,
            @intCast(resp.status_code),
            content_type.ptr,
            names.ptr,
            values.ptr,
            resp.extra_headers.len,
            if (bytes.len > 0) bytes.ptr else null,
            bytes.len,
        );
    }

    fn windowIdFor(self: *MacOsBackend, native_win: u64) types.WindowId {
        var it = self.windows.iterator();
        while (it.next()) |slot| {
            if (slot.value_ptr.native == native_win) return slot.handle;
        }
        return .invalid;
    }

    fn requireWindow(self: *MacOsBackend, win_id: types.WindowId) types.WebviewError!*MacWindow {
        return self.windows.getPtr(win_id) orelse error.WindowNotFound;
    }

    // -----------------------------------------------------------------------
    // Window lifecycle
    // -----------------------------------------------------------------------

    pub fn createWindow(self: *MacOsBackend, cfg: types.WindowConfig) types.WebviewError!types.WindowId {
        const alloc = self.allocator;

        // `initial_url` / `initial_html` are loaded AFTER user scripts are installed so that
        // `@documentStart` injection applies to the very first document (same as `linux.zig`).
        const title_z = alloc.dupeSentinel(u8, cfg.title, 0) catch return error.OutOfMemory;
        defer alloc.free(title_z);

        var pos_x: f64 = 0;
        var pos_y: f64 = 0;
        var has_pos: c_int = 0;
        if (cfg.position) |p| {
            has_pos = 1;
            const origin = coords.cssToCocoaOrigin(
                self.screenVisibleFrame(),
                p.x.v,
                p.y.v,
                cfg.size.height.v,
            );
            pos_x = origin.x;
            pos_y = origin.y;
        }

        const native = shim.zts_macos_window_new(
            self.handle,
            title_z.ptr,
            cfg.size.width.v,
            cfg.size.height.v,
            @intFromBool(cfg.resizable),
            @intFromBool(cfg.decorations),
            @intFromBool(cfg.transparent),
            @intFromBool(cfg.always_on_top),
            @intFromBool(cfg.visible),
            @intFromBool(cfg.fullscreen),
            @intFromBool(cfg.devtools),
            has_pos,
            pos_x,
            pos_y,
            cfg.parent_native_handle,
            null,
            null,
        );
        if (native == 0) return error.PlatformFailure;

        const win_id = self.windows.acquire(alloc, .{
            .native = native,
            .min_size = cfg.min_size,
            .max_size = cfg.max_size,
        }) catch {
            _ = shim.zts_macos_window_close(self.handle, native);
            return error.OutOfMemory;
        };

        if (cfg.min_size) |ms| {
            shim.zts_macos_window_set_min_size(self.handle, native, 1, ms.width.v, ms.height.v);
        }
        if (cfg.max_size) |xs| {
            shim.zts_macos_window_set_max_size(self.handle, native, 1, xs.width.v, xs.height.v);
        }

        for (cfg.init_scripts) |script| {
            self.addInitScript(win_id, script) catch {};
        }

        if (cfg.initial_html) |html| {
            try self.loadHtml(win_id, html, cfg.initial_url);
        } else if (cfg.initial_url) |url| {
            try self.navigate(win_id, url);
        }

        return win_id;
    }

    pub fn closeWindow(self: *MacOsBackend, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const native = w.native;

        _ = self.pending.cancelForWindow(self.allocator, win_id, PendingToken.cancel);
        _ = self.windows.release(win_id) catch {};
        if (shim.zts_macos_window_close(self.handle, native) == 0) return error.WindowNotFound;
    }

    pub fn nativeHandle(self: *MacOsBackend, win_id: types.WindowId) ?*anyopaque {
        const w = self.windows.getPtr(win_id) orelse return null;
        return shim.zts_macos_window_native(self.handle, w.native);
    }

    // -----------------------------------------------------------------------
    // Window properties
    // -----------------------------------------------------------------------

    pub fn setTitle(self: *MacOsBackend, win_id: types.WindowId, title: []const u8) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const z = self.allocator.dupeSentinel(u8, title, 0) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        shim.zts_macos_window_set_title(self.handle, w.native, z.ptr);
    }

    pub fn setSize(self: *MacOsBackend, win_id: types.WindowId, size: types.LogicalSize) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_size(self.handle, w.native, size.width.v, size.height.v);
    }

    pub fn setMinSize(self: *MacOsBackend, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.min_size = size;
        if (size) |ms| {
            shim.zts_macos_window_set_min_size(self.handle, w.native, 1, ms.width.v, ms.height.v);
        } else {
            shim.zts_macos_window_set_min_size(self.handle, w.native, 0, 0, 0);
        }
    }

    pub fn setMaxSize(self: *MacOsBackend, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        w.max_size = size;
        if (size) |xs| {
            shim.zts_macos_window_set_max_size(self.handle, w.native, 1, xs.width.v, xs.height.v);
        } else {
            shim.zts_macos_window_set_max_size(self.handle, w.native, 0, 0, 0);
        }
    }

    /// `pos` is CSS top-left; converted to Cocoa bottom-left using the window's CURRENT height.
    pub fn setPosition(self: *MacOsBackend, win_id: types.WindowId, pos: types.LogicalPoint) types.WebviewError!void {
        const w = try self.requireWindow(win_id);

        var ch: f64 = 0;
        shim.zts_macos_window_frame(self.handle, w.native, null, null, null, &ch);

        const screen = self.screenVisibleFrame();
        const target = coords.cssToCocoaOrigin(screen, pos.x.v, pos.y.v, ch);
        shim.zts_macos_window_set_position(self.handle, w.native, target.x, target.y);
    }

    /// Native Cocoa origin/size of `win_id` (Y grows upwards). Exposed for round-trip verification.
    pub fn cocoaFrame(self: *MacOsBackend, win_id: types.WindowId) ?CocoaFrame {
        const w = self.windows.getPtr(win_id) orelse return null;
        var out = CocoaFrame{};
        shim.zts_macos_window_frame(self.handle, w.native, &out.x, &out.y, &out.width, &out.height);
        return out;
    }

    pub fn setResizable(self: *MacOsBackend, win_id: types.WindowId, resizable: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_resizable(self.handle, w.native, @intFromBool(resizable));
    }

    pub fn setMinimized(self: *MacOsBackend, win_id: types.WindowId, minimized: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_minimized(self.handle, w.native, @intFromBool(minimized));
    }

    pub fn setMaximized(self: *MacOsBackend, win_id: types.WindowId, maximized: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_maximized(self.handle, w.native, @intFromBool(maximized));
    }

    pub fn setFullscreen(self: *MacOsBackend, win_id: types.WindowId, fullscreen: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_fullscreen(self.handle, w.native, @intFromBool(fullscreen));
    }

    pub fn setVisible(self: *MacOsBackend, win_id: types.WindowId, visible: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_visible(self.handle, w.native, @intFromBool(visible));
    }

    pub fn setDecorations(self: *MacOsBackend, win_id: types.WindowId, decorations: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_decorations(self.handle, w.native, @intFromBool(decorations));
    }

    pub fn setAlwaysOnTop(self: *MacOsBackend, win_id: types.WindowId, on_top: bool) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_always_on_top(self.handle, w.native, @intFromBool(on_top));
    }

    pub fn setFocus(self: *MacOsBackend, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_set_focus(self.handle, w.native);
    }

    pub fn startDrag(self: *MacOsBackend, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_start_drag(self.handle, w.native);
    }

    // -----------------------------------------------------------------------
    // Web content
    // -----------------------------------------------------------------------

    pub fn addInitScript(self: *MacOsBackend, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const z = self.allocator.dupeSentinel(u8, script, 0) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        shim.zts_macos_window_add_init_script(self.handle, w.native, z.ptr);
    }

    pub fn evalJs(self: *MacOsBackend, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        if (script.len == 0) return;
        const w = try self.requireWindow(win_id);
        const z = self.allocator.dupeSentinel(u8, script, 0) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        shim.zts_macos_window_eval_js(self.handle, w.native, z.ptr);
    }

    pub fn navigate(self: *MacOsBackend, win_id: types.WindowId, url: []const u8) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const z = self.allocator.dupeSentinel(u8, url, 0) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        shim.zts_macos_window_navigate(self.handle, w.native, z.ptr);
    }

    pub fn loadHtml(self: *MacOsBackend, win_id: types.WindowId, html: []const u8, base_uri: ?[]const u8) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        const hz = self.allocator.dupeSentinel(u8, html, 0) catch return error.OutOfMemory;
        defer self.allocator.free(hz);
        const bz = if (base_uri) |b| (self.allocator.dupeSentinel(u8, b, 0) catch return error.OutOfMemory) else null;
        defer if (bz) |s| self.allocator.free(s);
        shim.zts_macos_window_load_html(self.handle, w.native, hz.ptr, if (bz) |s| s.ptr else null);
    }

    pub fn openDevtools(self: *MacOsBackend, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWindow(win_id);
        shim.zts_macos_window_open_devtools(self.handle, w.native);
    }
};

// ============================================================================
// Real Native Cocoa + WKWebView End-to-End Integration Test (GitHub Actions `macos-latest`)
// ============================================================================

test "MacOsBackend renders HTML, injects UserScript, streams binary & JSON over `tauri://` + `ipc://`, and shuts down with 0 leaks" {
    // Accessory activation policy: real window + real WKWebView, but no Dock icon / focus stealing
    // so this runs unattended on CI runners.
    const backend = MacOsBackend.initAccessory(testing.allocator, testing.io) catch |err| switch (err) {
        error.DisplayUnavailable => {
            // Loud skip: `.github/workflows/ci.yml` greps for `OK macos-wk` and FAILS the job when
            // this marker is absent, so the native gate can never silently degrade to a no-op.
            std.debug.print("\n[MacOsBackend E2E] SKIPPED: no Aqua session (DisplayUnavailable)\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer backend.deinit();

    const E2eCtx = struct {
        backend: *MacOsBackend,
        allocator: Allocator,
        final_report: ?[]u8 = null,

        fn onTauriScheme(userdata: ?*anyopaque, req: types.SchemeRequest) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const html =
                \\<!doctype html>
                \\<html><body><script>
                \\(async () => {
                \\  try {
                \\    // 1. Large 96 KiB binary round trip over `ipc://` POST (exercises HTTPBodyStream).
                \\    const tx = new Uint8Array(98304);
                \\    for (let i = 0; i < tx.length; i++) tx[i] = (i * 31 + 7) & 0xff;
                \\    const binRes = await fetch("ipc://localhost/xor", {
                \\      method: "POST",
                \\      headers: { "Content-Type": "application/octet-stream", "X-Test-Token": "zts-42" },
                \\      body: tx,
                \\    });
                \\    const rx = new Uint8Array(await binRes.arrayBuffer());
                \\    const binOk = rx.length === tx.length && rx[0] === (tx[0] ^ 0x5a) && rx[98303] === (tx[98303] ^ 0x5a);
                \\
                \\    // 2. JSON RPC completed from a real background OS worker thread (CompletionQueue).
                \\    const jsonRes = await fetch("ipc://localhost/compute", {
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
                \\      ua: navigator.userAgent.indexOf("Mac") >= 0,
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

        fn bgComputeWorker(b: *MacOsBackend, alloc: Allocator, req_id: types.RequestId) void {
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

    // CSS top-left origin → Cocoa bottom-left conversion on the REAL screen.
    const screen = backend.screenVisibleFrame();
    try testing.expect(screen.height > 0);

    const win = try backend.createWindow(.{
        .title = "Z-Ts Native WKWebView E2E",
        .size = .wh(640, 480),
        .position = .{ .x = .init(24), .y = .init(48) },
        .visible = true,
        .init_scripts = &.{"window.__BOOT_TAG__ = 'injected-ok';"},
        .initial_url = "tauri://localhost/index.html",
    });

    // Native window geometry: CSS (24, 48) with a 480px-tall window must land at
    // cocoa_y = screen.top - 48 - 480 (within the frame/title-bar fudge of a decorated window).
    if (backend.cocoaFrame(win)) |frame| {
        const expected = coords.cssToCocoaY(screen.top(), 48, 480);
        try testing.expect(@abs(frame.y - expected) < 96);
        try testing.expect(frame.width >= 640);
        try testing.expect(frame.height >= 480);
    }

    // Property round trip (must not crash and must keep the window alive).
    try backend.setTitle(win, "Z-Ts Native WKWebView E2E (retitled)");
    try backend.setMinSize(win, .wh(320, 240));
    try backend.setMaxSize(win, .wh(1280, 900));
    try backend.setResizable(win, true);
    try backend.setAlwaysOnTop(win, true);
    try backend.setAlwaysOnTop(win, false);
    try backend.setPosition(win, .{ .x = .init(32), .y = .init(64) });
    try backend.setSize(win, .wh(720, 520));
    try testing.expect(backend.nativeHandle(win) != null);
    try testing.expect(backend.nativeHandle(types.WindowId.invalid) == null);

    const Watchdog = struct {
        b: *MacOsBackend,
        done: std.atomic.Value(bool) = .init(false),
        timed_out: std.atomic.Value(bool) = .init(false),

        fn run(w: *@This(), io: Io) void {
            var ticks: usize = 0;
            while (ticks < 120 and !w.done.load(.acquire)) : (ticks += 1) {
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

    try backend.closeWindow(win);

    if (wd.timed_out.load(.acquire)) {
        std.debug.print("\n[MacOsBackend E2E] Watchdog timed out waiting for WKWebView JS report!\n", .{});
        return error.WKWebViewE2eTimeout;
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
        std.debug.print("\n[MacOsBackend E2E] JS error: {s}\n", .{e});
        return error.WKWebViewJsError;
    }

    try testing.expect(parsed.value.bootInjected orelse false);
    try testing.expect(parsed.value.binOk orelse false);
    try testing.expectEqualStrings("ok", parsed.value.tauriHdr orelse "");
    try testing.expectEqualStrings("*", parsed.value.cors orelse "");
    try testing.expectEqual(@as(i64, 42), parsed.value.sum orelse -1);
    try testing.expect(parsed.value.ua orelse false);

    // Closing the last window ends `step()` — assert the loop actually terminates.
    try testing.expectEqual(@as(u32, 0), backend.windows.count());
    try testing.expect(!backend.step(.poll));

    // CI marker: verified by `.github/workflows/ci.yml` so the native gate can never silently skip.
    std.debug.print(
        "OK macos-wk checks=10 binary=98304 sum={d} screen={d:.0}x{d:.0} preflights={d}\n",
        .{ parsed.value.sum.?, screen.width, screen.height, backend.preflightCount() },
    );
}
