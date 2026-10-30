//! Pure-Zig In-Memory WebView Engine (`HeadlessMock`) (`src/webview/mock.zig`).
//!
//! Runs with `link_libc = false` and ZERO OS window / display / GPU dependencies in <1ms across
//! Linux, macOS, and Windows:
//! - Full multi-window state machine (`title`, `size`, `min/max_size`, `position`, flags, scripts).
//! - Real `step(.poll / .blocking)` + cross-thread `wakeup` & background-worker `completeRequest`!
//! - Custom URI scheme dispatch (`simulateSchemeRequest`) with synchronous OR background-thread
//!   asynchronous completion + automatic `OwnedBytes` release accounting.
//! - Simulated JS -> Zig `postMessage` (`simulateScriptMessage`) and user window close (`simulateUserClose`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const foundation = @import("zts_foundation");
const types = @import("types.zig");
const pending_mod = @import("pending.zig");
const png = @import("png.zig");

/// Record of one answered scheme request, kept so a test can assert on the status, headers and body
/// the engine would have handed the WebView.
pub const CompletedSchemeRecord = struct {
    /// Window the request came from.
    window_id: types.WindowId,
    /// Requested URI, owned copy.
    uri: []u8,
    /// Status the handler answered with.
    status_code: u16,
    /// `Content-Type` the handler answered with.
    content_type: []u8,
    headers: []types.QueuedCompletion.OwnedHeader,
    body: []u8,

    pub fn header(self: CompletedSchemeRecord, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn deinit(self: *CompletedSchemeRecord, allocator: Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.content_type);
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.headers);
        allocator.free(self.body);
    }
};

/// The in-memory window a `HeadlessMock` manages: title, geometry and flags, with no OS object
/// behind it. Screenshot capture returns a deterministic PNG so parity tests stay reproducible.
pub const MockWindow = struct {
    /// Current title (what `title()` returns).
    title: []u8,
    /// Client-area size in logical pixels.
    size: types.LogicalSize,
    min_size: ?types.LogicalSize,
    max_size: ?types.LogicalSize,
    position: types.LogicalPoint,
    resizable: bool,
    minimized: bool = false,
    maximized: bool = false,
    fullscreen: bool,
    visible: bool,
    decorations: bool,
    always_on_top: bool,
    focused: bool = false,
    drag_count: usize = 0,
    devtools_open: bool,
    background_color: ?types.Color,
    parent_native_handle: ?*anyopaque,
    /// Number of `fitParent()` calls that targeted this window (`M3-03` embedding contract).
    fit_count: usize = 0,
    current_url: []u8,
    last_html: ?[]u8 = null,
    init_scripts: std.ArrayList([]u8) = .empty,
    evaluated_scripts: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *MockWindow, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.current_url);
        if (self.last_html) |h| allocator.free(h);
        for (self.init_scripts.items) |s| allocator.free(s);
        self.init_scripts.deinit(allocator);
        for (self.evaluated_scripts.items) |s| allocator.free(s);
        self.evaluated_scripts.deinit(allocator);
    }
};

const MockPendingPayload = struct {
    allocator: Allocator,
    uri: []u8,

    fn cancel(self: MockPendingPayload) void {
        self.allocator.free(self.uri);
    }
};

/// The pure-Zig backend used by CI and by every unit test that needs a window. It implements the same
/// contract as the native backends (scheme routing, IPC, capture, close) but paints nothing, so it
/// runs without a display server.
pub const HeadlessMock = struct {
    /// Allocator that owns windows, captures and the scheme table.
    allocator: Allocator,
    /// IO reactor behind the mutex and the condition variable.
    io: Io,
    /// Guards the window pool, pending table and capture list.
    mu: Io.Mutex = .init,
    /// Signalled by `wakeup()`, waited on by `step(.blocking)`.
    cond: Io.Condition = .init,
    /// Set by `wakeup()` so a parked `step(.blocking)` returns immediately.
    woken: bool = false,
    /// Set by `requestQuit()`; cleared by `deinit()`.
    quit_requested: std.atomic.Value(bool) = .init(false),

    /// Live mock windows.
    windows: foundation.HandlePool(MockWindow, .window) = .empty,
    /// Registered scheme handlers (`tauri`, `ipc`, `asset`, …).
    schemes: std.StringHashMapUnmanaged(types.SchemeHandler) = .empty,
    /// Scheme requests waiting for `completeRequest()`.
    pending: pending_mod.PendingTable(MockPendingPayload) = .{},
    /// Completions queued from worker threads, drained by `step()`.
    completions: pending_mod.CompletionQueue,
    /// Every answered request, so a test can assert on the response.
    completed_records: std.ArrayList(CompletedSchemeRecord) = .empty,

    /// `window.__zts.postMessage(…)` receiver, if registered.
    message_handler: ?types.MessageHandler = null,
    /// Window-closed notification, if registered.
    close_handler: ?types.CloseHandler = null,

    /// Screenshots produced by `captureWindow()` and not yet collected by `takeCapture()`.
    /// A plain list (not a hash map) because a process has a handful of windows at most and this
    /// keeps `Handle` hashing out of the mock's hot path.
    captures: std.ArrayList(CaptureSlot) = .empty,

    pub const CaptureSlot = struct {
        window_id: types.WindowId,
        capture: types.Capture,
    };

    pub fn init(allocator: Allocator, io: Io) HeadlessMock {
        return .{
            .allocator = allocator,
            .io = io,
            .completions = pending_mod.CompletionQueue.init(allocator, io),
        };
    }

    pub fn deinit(self: *HeadlessMock) void {
        self.pending.deinitWith(self.allocator, MockPendingPayload.cancel);
        self.completions.deinit();

        for (self.completed_records.items) |*rec| {
            rec.deinit(self.allocator);
        }
        self.completed_records.deinit(self.allocator);

        var scheme_it = self.schemes.keyIterator();
        while (scheme_it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.schemes.deinit(self.allocator);

        // Uncollected screenshots are owned by the backend until `takeCapture()` moves them out.
        for (self.captures.items) |*slot| slot.capture.deinit();
        self.captures.deinit(self.allocator);

        var win_it = self.windows.iterator();
        while (win_it.next()) |slot| {
            slot.value_ptr.deinit(self.allocator);
        }
        self.windows.deinit(self.allocator);
    }

    pub fn step(self: *HeadlessMock, mode: types.StepMode) bool {
        if (self.quit_requested.load(.acquire)) {
            self.drainCompletions();
            return false;
        }

        if (mode == .blocking) {
            self.mu.lockUncancelable(self.io);
            while (!self.woken and !self.quit_requested.load(.acquire)) {
                self.cond.waitUncancelable(self.io, &self.mu);
            }
            self.woken = false;
            self.mu.unlock(self.io);
        } else {
            self.mu.lockUncancelable(self.io);
            self.woken = false;
            self.mu.unlock(self.io);
        }

        self.drainCompletions();
        return !self.quit_requested.load(.acquire);
    }

    pub fn wakeup(self: *HeadlessMock) void {
        self.mu.lockUncancelable(self.io);
        self.woken = true;
        self.cond.signal(self.io);
        self.mu.unlock(self.io);
    }

    pub fn requestQuit(self: *HeadlessMock) void {
        self.quit_requested.store(true, .release);
        self.mu.lockUncancelable(self.io);
        self.woken = true;
        self.cond.broadcast(self.io);
        self.mu.unlock(self.io);
    }

    fn drainCompletions(self: *HeadlessMock) void {
        while (self.completions.tryPop()) |item_val| {
            var item = item_val;
            defer item.deinit(self.allocator);

            const entry = self.pending.take(item.request_id) orelse continue;
            errdefer entry.payload.cancel();

            // Transfer ownership into observable `completed_records` for test inspection!
            const body_copy = self.allocator.dupe(u8, item.body.slice()) catch {
                entry.payload.cancel();
                continue;
            };
            errdefer self.allocator.free(body_copy);

            const ct_copy = self.allocator.dupe(u8, item.content_type) catch {
                self.allocator.free(body_copy);
                entry.payload.cancel();
                continue;
            };
            errdefer self.allocator.free(ct_copy);

            const hdrs_copy = self.allocator.alloc(types.QueuedCompletion.OwnedHeader, item.extra_headers.len) catch {
                self.allocator.free(ct_copy);
                self.allocator.free(body_copy);
                entry.payload.cancel();
                continue;
            };
            var copied_n: usize = 0;
            for (item.extra_headers, 0..) |src_h, idx| {
                const n = self.allocator.dupe(u8, src_h.name) catch break;
                const v = self.allocator.dupe(u8, src_h.value) catch {
                    self.allocator.free(n);
                    break;
                };
                hdrs_copy[idx] = .{ .name = n, .value = v };
                copied_n += 1;
            }

            self.completed_records.append(self.allocator, .{
                .window_id = entry.window_id,
                .uri = entry.payload.uri,
                .status_code = item.status_code,
                .content_type = ct_copy,
                .headers = hdrs_copy[0..copied_n],
                .body = body_copy,
            }) catch {
                for (hdrs_copy[0..copied_n]) |h| {
                    self.allocator.free(h.name);
                    self.allocator.free(h.value);
                }
                self.allocator.free(hdrs_copy);
                self.allocator.free(ct_copy);
                self.allocator.free(body_copy);
                entry.payload.cancel();
                continue;
            };
        }
    }

    pub fn registerScheme(self: *HeadlessMock, scheme: []const u8, handler: types.SchemeHandler) types.WebviewError!void {
        if (scheme.len == 0) return error.InvalidArgument;
        const gop = self.schemes.getOrPut(self.allocator, scheme) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, scheme) catch {
                _ = self.schemes.remove(scheme);
                return error.OutOfMemory;
            };
        }
        gop.value_ptr.* = handler;
    }

    pub fn completeRequest(self: *HeadlessMock, req_id: types.RequestId, resp: types.SchemeResponse) types.WebviewError!void {
        self.completions.push(req_id, resp) catch return error.OutOfMemory;
        self.wakeup();
    }

    /// Simulates a WebView firing a custom-scheme `fetch` / navigation (`tauri://`, `ipc://`, `asset://`).
    pub fn simulateSchemeRequest(
        self: *HeadlessMock,
        window_id: types.WindowId,
        method: []const u8,
        uri: []const u8,
        headers: []const types.HeaderPair,
        body: []const u8,
    ) types.WebviewError!types.RequestId {
        if (self.windows.getPtr(window_id) == null) return error.WindowNotFound;
        const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return error.InvalidArgument;
        const scheme = uri[0..colon];
        const handler = self.schemes.get(scheme) orelse return error.Unsupported;

        const uri_copy = self.allocator.dupe(u8, uri) catch return error.OutOfMemory;
        const req_id = self.pending.insert(self.allocator, window_id, .{
            .allocator = self.allocator,
            .uri = uri_copy,
        }) catch {
            self.allocator.free(uri_copy);
            return error.OutOfMemory;
        };

        handler.call(.{
            .request_id = req_id,
            .window_id = window_id,
            .scheme = scheme,
            .method = method,
            .uri = uri,
            .headers = headers,
            .body = body,
        });
        return req_id;
    }

    /// Simulates `window.webkit.messageHandlers.__zts.postMessage(...)` from page JS.
    pub fn simulateScriptMessage(self: *HeadlessMock, window_id: types.WindowId, message: []const u8) types.WebviewError!void {
        if (self.windows.getPtr(window_id) == null) return error.WindowNotFound;
        if (self.message_handler) |mh| {
            mh.call(window_id, message);
        }
    }

    pub fn createWindow(self: *HeadlessMock, cfg: types.WindowConfig) types.WebviewError!types.WindowId {
        const title = self.allocator.dupe(u8, cfg.title) catch return error.OutOfMemory;
        errdefer self.allocator.free(title);

        const url = self.allocator.dupe(u8, cfg.initial_url orelse "about:blank") catch return error.OutOfMemory;
        errdefer self.allocator.free(url);

        const html = if (cfg.initial_html) |h| (self.allocator.dupe(u8, h) catch return error.OutOfMemory) else null;
        errdefer if (html) |h| self.allocator.free(h);

        var win: MockWindow = .{
            .title = title,
            .size = cfg.size,
            .min_size = cfg.min_size,
            .max_size = cfg.max_size,
            .position = cfg.position orelse .xy(0, 0),
            .resizable = cfg.resizable,
            .fullscreen = cfg.fullscreen,
            .visible = cfg.visible,
            .decorations = cfg.decorations,
            .always_on_top = cfg.always_on_top,
            .devtools_open = cfg.devtools,
            .background_color = cfg.background_color,
            .parent_native_handle = cfg.parent_native_handle,
            .current_url = url,
            .last_html = html,
        };
        errdefer win.deinit(self.allocator);

        for (cfg.init_scripts) |src| {
            const copy = self.allocator.dupe(u8, src) catch return error.OutOfMemory;
            win.init_scripts.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                return error.OutOfMemory;
            };
        }

        return self.windows.acquire(self.allocator, win) catch return error.OutOfMemory;
    }

    // -----------------------------------------------------------------------
    // Screenshot capture (`M5-04`) — synchronous on the mock: no renderer to wait for.
    // -----------------------------------------------------------------------

    /// Produces a deterministic PNG of the requested window (a diagonal gradient + corner marker).
    /// Calling it again before `takeCapture()` replaces the previous image instead of leaking it.
    pub fn captureWindow(self: *HeadlessMock, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWin(win_id);
        const width: u32 = @intFromFloat(@max(1.0, w.size.width.v));
        const height: u32 = @intFromFloat(@max(1.0, w.size.height.v));

        const bytes = png.testImage(self.allocator, width, height) catch return error.OutOfMemory;
        const capture = try types.Capture.initOwned(self.allocator, bytes);

        self.dropCaptures(win_id);
        self.captures.append(self.allocator, .{ .window_id = win_id, .capture = capture }) catch {
            var c = capture;
            c.deinit();
            return error.OutOfMemory;
        };
    }

    /// Moves a finished capture to the caller (`null` while none is pending / already collected).
    pub fn takeCapture(self: *HeadlessMock, win_id: types.WindowId) types.WebviewError!?types.Capture {
        _ = try self.requireWin(win_id);
        for (self.captures.items, 0..) |slot, idx| {
            if (slot.window_id.index != win_id.index or slot.window_id.generation != win_id.generation) continue;
            return self.captures.swapRemove(idx).capture;
        }
        return null;
    }

    fn dropCaptures(self: *HeadlessMock, win_id: types.WindowId) void {
        var idx: usize = 0;
        while (idx < self.captures.items.len) {
            const slot = &self.captures.items[idx];
            if (slot.window_id.index == win_id.index and slot.window_id.generation == win_id.generation) {
                var removed = self.captures.swapRemove(idx);
                removed.capture.deinit();
                continue;
            }
            idx += 1;
        }
    }

    pub fn closeWindow(self: *HeadlessMock, win_id: types.WindowId) types.WebviewError!void {
        _ = self.pending.cancelForWindow(self.allocator, win_id, MockPendingPayload.cancel);
        var win = self.windows.release(win_id) catch return error.WindowNotFound;
        self.dropCaptures(win_id);
        win.deinit(self.allocator);
        if (self.close_handler) |ch| ch.call(win_id);
    }

    fn requireWin(self: *HeadlessMock, win_id: types.WindowId) types.WebviewError!*MockWindow {
        return self.windows.getPtr(win_id) orelse error.WindowNotFound;
    }

    pub fn setTitle(self: *HeadlessMock, win_id: types.WindowId, title: []const u8) types.WebviewError!void {
        const w = try self.requireWin(win_id);
        const copy = self.allocator.dupe(u8, title) catch return error.OutOfMemory;
        self.allocator.free(w.title);
        w.title = copy;
    }

    pub fn setSize(self: *HeadlessMock, win_id: types.WindowId, size: types.LogicalSize) types.WebviewError!void {
        (try self.requireWin(win_id)).size = size;
    }

    /// Overlay embedding (`M3-03`): a mock has no real parent to measure, so it only records the
    /// request — the *contract* (embedded windows support it, toplevel windows do not) is what the
    /// cross-platform unit tests assert.
    pub fn fitParent(self: *HeadlessMock, win_id: types.WindowId) types.WebviewError!void {
        const w = try self.requireWin(win_id);
        if (w.parent_native_handle == null) return error.Unsupported;
        w.fit_count += 1;
    }

    pub fn setMinSize(self: *HeadlessMock, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        (try self.requireWin(win_id)).min_size = size;
    }

    pub fn setMaxSize(self: *HeadlessMock, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        (try self.requireWin(win_id)).max_size = size;
    }

    pub fn setPosition(self: *HeadlessMock, win_id: types.WindowId, pos: types.LogicalPoint) types.WebviewError!void {
        (try self.requireWin(win_id)).position = pos;
    }

    pub fn setResizable(self: *HeadlessMock, win_id: types.WindowId, resizable: bool) types.WebviewError!void {
        (try self.requireWin(win_id)).resizable = resizable;
    }

    pub fn setMinimized(self: *HeadlessMock, win_id: types.WindowId, minimized: bool) types.WebviewError!void {
        (try self.requireWin(win_id)).minimized = minimized;
    }

    pub fn setMaximized(self: *HeadlessMock, win_id: types.WindowId, maximized: bool) types.WebviewError!void {
        (try self.requireWin(win_id)).maximized = maximized;
    }

    pub fn setFullscreen(self: *HeadlessMock, win_id: types.WindowId, fullscreen: bool) types.WebviewError!void {
        (try self.requireWin(win_id)).fullscreen = fullscreen;
    }

    pub fn setVisible(self: *HeadlessMock, win_id: types.WindowId, visible: bool) types.WebviewError!void {
        (try self.requireWin(win_id)).visible = visible;
    }

    pub fn setDecorations(self: *HeadlessMock, win_id: types.WindowId, decorations: bool) types.WebviewError!void {
        (try self.requireWin(win_id)).decorations = decorations;
    }

    pub fn setAlwaysOnTop(self: *HeadlessMock, win_id: types.WindowId, on_top: bool) types.WebviewError!void {
        (try self.requireWin(win_id)).always_on_top = on_top;
    }

    pub fn setFocus(self: *HeadlessMock, win_id: types.WindowId) types.WebviewError!void {
        (try self.requireWin(win_id)).focused = true;
    }

    pub fn startDrag(self: *HeadlessMock, win_id: types.WindowId) types.WebviewError!void {
        (try self.requireWin(win_id)).drag_count += 1;
    }

    pub fn addInitScript(self: *HeadlessMock, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const w = try self.requireWin(win_id);
        const copy = self.allocator.dupe(u8, script) catch return error.OutOfMemory;
        w.init_scripts.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return error.OutOfMemory;
        };
    }

    pub fn evalJs(self: *HeadlessMock, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const w = try self.requireWin(win_id);
        const copy = self.allocator.dupe(u8, script) catch return error.OutOfMemory;
        w.evaluated_scripts.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return error.OutOfMemory;
        };
    }

    pub fn navigate(self: *HeadlessMock, win_id: types.WindowId, url: []const u8) types.WebviewError!void {
        const w = try self.requireWin(win_id);
        const copy = self.allocator.dupe(u8, url) catch return error.OutOfMemory;
        self.allocator.free(w.current_url);
        w.current_url = copy;
    }

    pub fn loadHtml(self: *HeadlessMock, win_id: types.WindowId, html: []const u8, base_uri: ?[]const u8) types.WebviewError!void {
        const w = try self.requireWin(win_id);
        const html_copy = self.allocator.dupe(u8, html) catch return error.OutOfMemory;
        if (w.last_html) |old| self.allocator.free(old);
        w.last_html = html_copy;
        if (base_uri) |b| {
            const b_copy = self.allocator.dupe(u8, b) catch return error.OutOfMemory;
            self.allocator.free(w.current_url);
            w.current_url = b_copy;
        }
    }

    pub fn openDevtools(self: *HeadlessMock, win_id: types.WindowId) types.WebviewError!void {
        (try self.requireWin(win_id)).devtools_open = true;
    }
};

test "HeadlessMock executes cross-thread async scheme requests, `step(.blocking)` wakeup, and window lifecycle cleanly" {
    var mock = HeadlessMock.init(testing.allocator, testing.io);
    defer mock.deinit();

    const AsyncCtx = struct {
        mock: *HeadlessMock,

        fn onIpc(userdata: ?*anyopaque, req: types.SchemeRequest) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const req_id = req.request_id;
            const body_copy = self.mock.allocator.dupe(u8, req.body) catch unreachable;
            // Complete asynchronously from a genuine background OS thread!
            const worker = std.Thread.spawn(.{}, completeWorker, .{ self.mock, req_id, body_copy }) catch unreachable;
            worker.detach();
        }

        fn completeWorker(m: *HeadlessMock, id: types.RequestId, echoed: []u8) void {
            m.completeRequest(id, .{
                .status_code = 200,
                .content_type = "application/octet-stream",
                .extra_headers = &.{.{ .name = "Tauri-Response", .value = "ok" }},
                .body = types.OwnedBytes.fromOwnedSlice(m.allocator, echoed),
            }) catch unreachable;
        }
    };

    var async_ctx: AsyncCtx = .{ .mock = &mock };
    try mock.registerScheme("ipc", .{ .userdata = &async_ctx, .onRequest = AsyncCtx.onIpc });

    const win = try mock.createWindow(.{
        .title = "Mock App",
        .size = .wh(1280, 720),
        .init_scripts = &.{"window.__READY__ = true;"},
    });

    _ = try mock.simulateSchemeRequest(win, "POST", "ipc://localhost/echo", &.{}, "\x01\x02\x03\x04");

    // Block on main thread until background worker calls `completeRequest` -> `wakeup`!
    while (mock.completed_records.items.len == 0) {
        try testing.expect(mock.step(.blocking));
    }

    const rec = mock.completed_records.items[0];
    try testing.expectEqual(@as(u16, 200), rec.status_code);
    try testing.expectEqualStrings("ok", rec.header("tauri-response").?);
    try testing.expectEqualSlices(u8, "\x01\x02\x03\x04", rec.body);

    mock.requestQuit();
    try testing.expect(!mock.step(.blocking));
}
