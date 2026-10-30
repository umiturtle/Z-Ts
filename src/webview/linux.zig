//! Native Linux GTK3 + WebKit2GTK 4.1 Backend (`src/webview/linux.zig`).
//!
//! Architecture & Safety Guarantees:
//! 1. **Non-blocking `step(.blocking / .poll)`** atop `g_main_context_iteration` + lock-free
//!    cross-thread wakeup via `g_idle_add_full(G_PRIORITY_HIGH, ...)`.
//! 2. **Deadlock-free Custom URI Scheme POST Body Reader**: Streams large request bodies across
//!    the WebKit NetworkProcess pipe asynchronously in 64 KiB chunks (`g_input_stream_read_bytes_async`),
//!    NEVER blocking the GTK main thread!
//! 3. **Zero-Copy `OwnedBytes` Stream Completion**: Wraps response slices directly in
//!    `g_bytes_new_with_free_func` + `g_memory_input_stream_new_from_bytes` so WebKit reads directly
//!    from Zig memory and invokes `OwnedBytes.deinit()` automatically upon stream completion.
//! 4. **Standalone Child Embedding**: Supports both top-level `GtkWindow` AND embedding directly
//!    inside an existing host `GtkContainer*` (`WindowConfig.parent_native_handle`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const foundation = @import("zts_foundation");
const c = @import("gtk_bindings.zig");
const types = @import("types.zig");
const pending_mod = @import("pending.zig");

const body_chunk_size: usize = 64 * 1024;

const LinuxWindow = struct {
    toplevel: ?*c.GtkWidget, // `null` when embedded inside external `parent_native_handle`
    /// Host container we were embedded into (`M3-03`); `null` for toplevel windows.
    parent: ?*c.GtkWidget = null,
    webview: *c.WebKitWebView,
    ucm: *c.WebKitUserContentManager,
    min_size: ?types.LogicalSize,
    max_size: ?types.LogicalSize,
    destroyed_by_signal: bool = false,
};

const SignalSlot = struct {
    backend: *LinuxGtkBackend,
    win_id: types.WindowId,
};

const SchemeSlot = struct {
    backend: *LinuxGtkBackend,
    handler: types.SchemeHandler,
    scheme_z: [:0]u8,
};

const AsyncBodyReader = struct {
    backend: *LinuxGtkBackend,
    handler: types.SchemeHandler,
    req_id: types.RequestId,
    win_id: types.WindowId,
    webkit_req: *c.WebKitURISchemeRequest,
    stream: *c.GInputStream,
    buf: std.ArrayList(u8) = .empty,

    fn destroy(self: *AsyncBodyReader) void {
        const alloc = self.backend.allocator;
        self.buf.deinit(alloc);
        alloc.destroy(self);
    }
};

const OwnedBodyHolder = struct {
    backend: *LinuxGtkBackend,
    body: types.OwnedBytes,
};

/// In-flight (or finished, uncollected) `webkit_web_view_get_snapshot()` render (`M5-04`).
///
/// The completion callback owns the slot: it either frees it (discarded / failed) or leaves it in
/// `LinuxGtkBackend.snapshots` with `done = true` for `takeCapture()`. The struct is heap-allocated
/// because WebKit may deliver the callback after the window has been closed.
const SnapshotSlot = struct {
    backend: *LinuxGtkBackend,
    win_id: types.WindowId,
    buf: std.ArrayList(u8) = .empty,
    done: bool = false,
    failed: bool = false,
    /// Set when the window was closed (or a newer capture was requested) before completion.
    discard: bool = false,

    fn destroy(self: *SnapshotSlot) void {
        const backend = self.backend;
        for (backend.snapshots.items, 0..) |candidate, idx| {
            if (candidate == self) {
                _ = backend.snapshots.swapRemove(idx);
                break;
            }
        }
        self.buf.deinit(backend.allocator);
        backend.allocator.destroy(self);
    }
};

fn sameWindow(a: types.WindowId, b: types.WindowId) bool {
    return a.index == b.index and a.generation == b.generation;
}

fn cancelWebKitRequest(req_ptr: *c.WebKitURISchemeRequest) void {
    const quark = c.g_quark_from_static_string("zts-webview-quark");
    const gerr = c.g_error_new_literal(quark, 1, "Request canceled");
    c.webkit_uri_scheme_request_finish_error(req_ptr, gerr);
    c.g_error_free(gerr);
    c.g_object_unref(req_ptr);
}

pub const LinuxGtkBackend = struct {
    allocator: Allocator,
    io: Io,
    web_context: *c.WebKitWebContext,
    quit_requested: std.atomic.Value(bool) = .init(false),
    wakeup_scheduled: std.atomic.Value(bool) = .init(false),
    active_streams: std.atomic.Value(usize) = .init(0),

    windows: foundation.HandlePool(LinuxWindow, .window) = .empty,
    signal_slots: std.ArrayList(*SignalSlot) = .empty,
    scheme_slots: std.ArrayList(*SchemeSlot) = .empty,
    pending: pending_mod.PendingTable(*c.WebKitURISchemeRequest) = .{},
    completions: pending_mod.CompletionQueue,

    message_handler: ?types.MessageHandler = null,
    close_handler: ?types.CloseHandler = null,
    force_software_render: bool = false,

    /// Screenshot slots that WebKit still owes us a callback for, plus finished-but-uncollected
    /// images. Freed by `deinit()` in every path, so `std.testing.allocator` proves no leak.
    snapshots: std.ArrayList(*SnapshotSlot) = .empty,

    pub fn init(allocator: Allocator, io: Io) types.WebviewError!*LinuxGtkBackend {
        if (c.gtk_init_check(null, null) == 0) {
            return error.DisplayUnavailable;
        }

        const self = allocator.create(LinuxGtkBackend) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        const web_ctx = c.webkit_web_context_new();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .web_context = web_ctx,
            .completions = pending_mod.CompletionQueue.init(allocator, io),
            .force_software_render = detectSoftwareRenderEnv(),
        };
        return self;
    }

    fn detectSoftwareRenderEnv() bool {
        if (std.c.getenv("ZTS_WEBVIEW_SOFTWARE_RENDER") != null) return true;
        if (std.c.getenv("WEBKIT_DISABLE_COMPOSITING_MODE") != null) return true;
        return false;
    }

    pub fn deinit(self: *LinuxGtkBackend) void {
        const alloc = self.allocator;

        // 1. Cancel any uncompleted custom scheme requests cleanly.
        self.pending.deinitWith(alloc, cancelWebKitRequest);
        self.completions.deinit();

        // 2. Detach callbacks and close all still-open GTK windows via `closeWindow` so
        // synchronous GObject `"destroy"` signals cannot double-unref `ucm` or mutate an active iterator.
        self.close_handler = null;
        self.message_handler = null;
        while (true) {
            var win_it = self.windows.iterator();
            const first = win_it.next() orelse break;
            self.closeWindow(first.handle) catch break;
        }
        self.windows.deinit(alloc);

        c.g_object_unref(self.web_context);

        // 3. Pump pending GLib idle / GBytes release callbacks so zero `OwnedBytes` remain live!
        var spins: usize = 0;
        while ((c.g_main_context_iteration(null, 0) != 0 or self.active_streams.load(.acquire) > 0 or self.wakeup_scheduled.load(.acquire)) and spins < 1000) : (spins += 1) {
            _ = c.g_main_context_iteration(null, 0);
        }

        // 4. Screenshots: give WebKit a bounded window to deliver outstanding snapshot callbacks,
        //    then free whatever is left (the slot is heap-owned, so a late callback cannot dangle
        //    onto a freed backend field).
        var snapshot_pumps: usize = 0;
        while (self.snapshots.items.len > 0 and snapshot_pumps < 1000) : (snapshot_pumps += 1) {
            var all_settled = true;
            for (self.snapshots.items) |slot| {
                if (!slot.done and !slot.failed) all_settled = false;
            }
            if (all_settled) break;
            _ = c.g_main_context_iteration(null, 0);
        }
        while (self.snapshots.items.len > 0) {
            self.snapshots.items[self.snapshots.items.len - 1].destroy();
        }
        self.snapshots.deinit(alloc);

        for (self.signal_slots.items) |s| alloc.destroy(s);
        self.signal_slots.deinit(alloc);

        for (self.scheme_slots.items) |s| {
            alloc.free(s.scheme_z);
            alloc.destroy(s);
        }
        self.scheme_slots.deinit(alloc);

        alloc.destroy(self);
    }

    pub fn step(self: *LinuxGtkBackend, mode: types.StepMode) bool {
        self.drainCompletions();
        if (self.quit_requested.load(.acquire)) return false;

        const may_block: c.gboolean = if (mode == .blocking) 1 else 0;
        _ = c.g_main_context_iteration(null, may_block);

        self.drainCompletions();
        return !self.quit_requested.load(.acquire);
    }

    fn onIdleWakeup(user_data: c.gpointer) callconv(.c) c.gboolean {
        const self: *LinuxGtkBackend = @ptrCast(@alignCast(user_data.?));
        self.wakeup_scheduled.store(false, .release);
        self.drainCompletions();
        return c.G_SOURCE_REMOVE;
    }

    pub fn wakeup(self: *LinuxGtkBackend) void {
        if (!self.wakeup_scheduled.swap(true, .acq_rel)) {
            _ = c.g_idle_add_full(c.G_PRIORITY_HIGH, onIdleWakeup, self, null);
        }
    }

    pub fn requestQuit(self: *LinuxGtkBackend) void {
        self.quit_requested.store(true, .release);
        self.wakeup();
    }

    pub fn registerScheme(self: *LinuxGtkBackend, scheme: []const u8, handler: types.SchemeHandler) types.WebviewError!void {
        if (scheme.len == 0) return error.InvalidArgument;
        const scheme_z = self.allocator.dupeSentinel(u8, scheme, 0) catch return error.OutOfMemory;
        errdefer self.allocator.free(scheme_z);

        const slot = self.allocator.create(SchemeSlot) catch return error.OutOfMemory;
        slot.* = .{
            .backend = self,
            .handler = handler,
            .scheme_z = scheme_z,
        };
        self.scheme_slots.append(self.allocator, slot) catch {
            self.allocator.destroy(slot);
            return error.OutOfMemory;
        };

        const sec = c.webkit_web_context_get_security_manager(self.web_context);
        c.webkit_security_manager_register_uri_scheme_as_secure(sec, scheme_z.ptr);
        c.webkit_security_manager_register_uri_scheme_as_cors_enabled(sec, scheme_z.ptr);
        c.webkit_web_context_register_uri_scheme(
            self.web_context,
            scheme_z.ptr,
            onUriSchemeRequest,
            slot,
            null,
        );
    }

    fn findWindowIdByWebView(self: *LinuxGtkBackend, target_wv: ?*c.WebKitWebView) types.WindowId {
        const wv = target_wv orelse return .invalid;
        var it = self.windows.iterator();
        while (it.next()) |slot| {
            if (slot.value_ptr.webview == wv) return slot.handle;
        }
        return .invalid;
    }

    fn onUriSchemeRequest(webkit_req: *c.WebKitURISchemeRequest, user_data: c.gpointer) callconv(.c) void {
        const slot: *SchemeSlot = @ptrCast(@alignCast(user_data.?));
        const self = slot.backend;

        // Retain `WebKitURISchemeRequest` until `finish_with_response` / `finish_error`!
        _ = c.g_object_ref(webkit_req);

        const win_id = self.findWindowIdByWebView(c.webkit_uri_scheme_request_get_web_view(webkit_req));
        const req_id = self.pending.insert(self.allocator, win_id, webkit_req) catch {
            cancelWebKitRequest(webkit_req);
            return;
        };

        // Check for preflight `OPTIONS` on custom CORS schemes and answer immediately!
        const raw_method_z = c.webkit_uri_scheme_request_get_http_method(webkit_req);
        const method = if (raw_method_z) |m| std.mem.span(m) else "GET";
        if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
            self.completeRequest(req_id, .{
                .status_code = 200,
                .content_type = "text/plain",
                .body = .empty,
            }) catch {};
            return;
        }

        if (c.webkit_uri_scheme_request_get_http_body(webkit_req)) |body_stream| {
            const reader = self.allocator.create(AsyncBodyReader) catch {
                if (self.pending.take(req_id)) |e| cancelWebKitRequest(e.payload);
                return;
            };
            reader.* = .{
                .backend = self,
                .handler = slot.handler,
                .req_id = req_id,
                .win_id = win_id,
                .webkit_req = webkit_req,
                .stream = body_stream,
            };
            c.g_input_stream_read_bytes_async(
                body_stream,
                body_chunk_size,
                c.G_PRIORITY_DEFAULT,
                null,
                onBodyChunkRead,
                reader,
            );
            return;
        }

        self.dispatchSchemeRequestReady(slot.handler, req_id, win_id, webkit_req, "");
    }

    fn onBodyChunkRead(_: c.gpointer, async_res: *c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
        const reader: *AsyncBodyReader = @ptrCast(@alignCast(user_data.?));
        const self = reader.backend;

        var gerr: ?*c.GError = null;
        const maybe_gbytes = c.g_input_stream_read_bytes_finish(reader.stream, async_res, &gerr);
        if (gerr) |e| {
            c.g_error_free(e);
            if (self.pending.take(reader.req_id)) |entry| cancelWebKitRequest(entry.payload);
            reader.destroy();
            return;
        }

        if (maybe_gbytes) |gb| {
            defer c.g_bytes_unref(gb);
            var n: usize = 0;
            const ptr = c.g_bytes_get_data(gb, &n);
            if (n > 0 and ptr != null) {
                reader.buf.appendSlice(self.allocator, ptr.?[0..n]) catch {
                    if (self.pending.take(reader.req_id)) |entry| cancelWebKitRequest(entry.payload);
                    reader.destroy();
                    return;
                };
                // Keep streaming chunks asynchronously until EOF (`n == 0`)!
                c.g_input_stream_read_bytes_async(
                    reader.stream,
                    body_chunk_size,
                    c.G_PRIORITY_DEFAULT,
                    null,
                    onBodyChunkRead,
                    reader,
                );
                return;
            }
        }

        // EOF reached: invoke user `SchemeHandler` with full contiguous payload!
        const handler = reader.handler;
        const req_id = reader.req_id;
        const win_id = reader.win_id;
        const webkit_req = reader.webkit_req;
        self.dispatchSchemeRequestReady(handler, req_id, win_id, webkit_req, reader.buf.items);
        reader.destroy();
    }

    const HeaderCollector = struct {
        arena: Allocator,
        list: std.ArrayList(types.HeaderPair) = .empty,
    };

    fn onCollectHeader(name: [*:0]const c.gchar, value: [*:0]const c.gchar, user_data: c.gpointer) callconv(.c) void {
        const col: *HeaderCollector = @ptrCast(@alignCast(user_data.?));
        col.list.append(col.arena, .{
            .name = std.mem.span(name),
            .value = std.mem.span(value),
        }) catch {};
    }

    fn dispatchSchemeRequestReady(
        self: *LinuxGtkBackend,
        handler: types.SchemeHandler,
        req_id: types.RequestId,
        win_id: types.WindowId,
        webkit_req: *c.WebKitURISchemeRequest,
        body: []const u8,
    ) void {
        var hdr_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer hdr_arena.deinit();

        var collector: HeaderCollector = .{ .arena = hdr_arena.allocator() };
        if (c.webkit_uri_scheme_request_get_http_headers(webkit_req)) |soup_hdrs| {
            c.soup_message_headers_foreach(soup_hdrs, onCollectHeader, &collector);
        }

        const raw_method = c.webkit_uri_scheme_request_get_http_method(webkit_req);
        handler.call(.{
            .request_id = req_id,
            .window_id = win_id,
            .scheme = std.mem.span(c.webkit_uri_scheme_request_get_scheme(webkit_req)),
            .method = if (raw_method) |m| std.mem.span(m) else "GET",
            .uri = std.mem.span(c.webkit_uri_scheme_request_get_uri(webkit_req)),
            .headers = collector.list.items,
            .body = body,
        });

        // If handler called `completeRequest` synchronously inside `handler.call`, flush immediately!
        self.drainCompletions();
    }

    pub fn completeRequest(self: *LinuxGtkBackend, req_id: types.RequestId, resp: types.SchemeResponse) types.WebviewError!void {
        self.completions.push(req_id, resp) catch return error.OutOfMemory;
        self.wakeup();
    }

    fn onFreeOwnedHolder(data: c.gpointer) callconv(.c) void {
        const holder: *OwnedBodyHolder = @ptrCast(@alignCast(data.?));
        const backend = holder.backend;
        const alloc = backend.allocator;
        holder.body.deinit();
        alloc.destroy(holder);
        _ = backend.active_streams.fetchSub(1, .acq_rel);
    }

    fn drainCompletions(self: *LinuxGtkBackend) void {
        while (self.completions.tryPop()) |item_val| {
            var item = item_val;

            const entry = self.pending.take(item.request_id) orelse {
                item.deinit(self.allocator);
                continue;
            };
            const webkit_req = entry.payload;

            var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch_arena.deinit();
            const scratch = scratch_arena.allocator();

            const ct_z = scratch.dupeSentinel(u8, item.content_type, 0) catch {
                cancelWebKitRequest(webkit_req);
                item.deinit(self.allocator);
                continue;
            };

            const slice = item.body.slice();
            const gbytes: *c.GBytes = if (slice.len == 0) blk: {
                item.body.deinit();
                break :blk c.g_bytes_new_static("", 0);
            } else blk: {
                const holder = self.allocator.create(OwnedBodyHolder) catch {
                    cancelWebKitRequest(webkit_req);
                    item.deinit(self.allocator);
                    continue;
                };
                holder.* = .{
                    .backend = self,
                    .body = item.body.move(),
                };
                _ = self.active_streams.fetchAdd(1, .acq_rel);
                break :blk c.g_bytes_new_with_free_func(slice.ptr, slice.len, onFreeOwnedHolder, holder);
            };

            const mem_stream = c.g_memory_input_stream_new_from_bytes(gbytes);
            c.g_bytes_unref(gbytes);

            const wk_resp = c.webkit_uri_scheme_response_new(mem_stream, @intCast(slice.len));
            c.g_object_unref(mem_stream);

            c.webkit_uri_scheme_response_set_status(wk_resp, item.status_code, null);
            c.webkit_uri_scheme_response_set_content_type(wk_resp, ct_z.ptr);

            const soup_hdrs = c.soup_message_headers_new(c.SOUP_MESSAGE_HEADERS_RESPONSE);
            c.soup_message_headers_append(soup_hdrs, "Content-Type", ct_z.ptr);
            c.soup_message_headers_append(soup_hdrs, "Access-Control-Allow-Origin", "*");
            c.soup_message_headers_append(soup_hdrs, "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
            c.soup_message_headers_append(soup_hdrs, "Access-Control-Allow-Headers", "*");
            c.soup_message_headers_append(soup_hdrs, "Access-Control-Expose-Headers", "*");
            for (item.extra_headers) |h| {
                const nz = scratch.dupeSentinel(u8, h.name, 0) catch continue;
                const vz = scratch.dupeSentinel(u8, h.value, 0) catch continue;
                c.soup_message_headers_append(soup_hdrs, nz.ptr, vz.ptr);
            }
            // Verified via `objdump -d` against `libwebkit2gtk-4.1.so.0`:
            // `webkit_uri_scheme_response_set_http_headers` is `[transfer full]` — it moves
            // `soup_hdrs` directly without `soup_message_headers_ref` and unrefs on finalize.
            c.webkit_uri_scheme_response_set_http_headers(wk_resp, soup_hdrs);

            c.webkit_uri_scheme_request_finish_with_response(webkit_req, wk_resp);
            c.g_object_unref(wk_resp);
            c.g_object_unref(webkit_req);

            item.deinit(self.allocator);
        }
    }

    fn onScriptMessage(
        _: *c.WebKitUserContentManager,
        js_result: *c.WebKitJavascriptResult,
        user_data: c.gpointer,
    ) callconv(.c) void {
        const slot: *SignalSlot = @ptrCast(@alignCast(user_data.?));
        const self = slot.backend;
        const mh = self.message_handler orelse return;

        const jsc_val = c.webkit_javascript_result_get_js_value(js_result);
        const c_str_opt: ?[*:0]c.gchar = if (c.jsc_value_is_string(jsc_val) != 0)
            c.jsc_value_to_string(jsc_val)
        else
            c.jsc_value_to_json(jsc_val, 0);

        if (c_str_opt) |c_str| {
            defer c.g_free(c_str);
            mh.call(slot.win_id, std.mem.span(c_str));
        }
    }

    fn onWindowDestroyed(_: *c.GtkWidget, user_data: c.gpointer) callconv(.c) void {
        const slot: *SignalSlot = @ptrCast(@alignCast(user_data.?));
        const self = slot.backend;

        if (self.windows.getPtr(slot.win_id)) |w| {
            w.destroyed_by_signal = true;
            _ = self.pending.cancelForWindow(self.allocator, slot.win_id, cancelWebKitRequest);
            if (self.windows.release(slot.win_id)) |released| {
                c.g_object_unref(released.ucm);
            } else |_| {}
            if (self.close_handler) |ch| ch.call(slot.win_id);
        }
    }

    pub fn createWindow(self: *LinuxGtkBackend, cfg: types.WindowConfig) types.WebviewError!types.WindowId {
        const ucm = c.webkit_user_content_manager_new();
        errdefer c.g_object_unref(ucm);

        const raw_wv = c.g_object_new(
            c.webkit_web_view_get_type(),
            @as([*:0]const u8, "web-context"),
            self.web_context,
            @as([*:0]const u8, "user-content-manager"),
            ucm,
            @as(?*anyopaque, null),
        );
        const wv: *c.WebKitWebView = @ptrCast(raw_wv);

        const settings = c.webkit_web_view_get_settings(wv);
        c.webkit_settings_set_enable_developer_extras(settings, if (cfg.devtools) 1 else 0);
        if (self.force_software_render) {
            c.webkit_settings_set_hardware_acceleration_policy(settings, c.WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
        }

        if (cfg.transparent or cfg.background_color != null) {
            const col = cfg.background_color orelse types.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
            const rgba: c.GdkRGBA = .{
                .red = @as(f64, @floatFromInt(col.r)) / 255.0,
                .green = @as(f64, @floatFromInt(col.g)) / 255.0,
                .blue = @as(f64, @floatFromInt(col.b)) / 255.0,
                .alpha = @as(f64, @floatFromInt(col.a)) / 255.0,
            };
            c.webkit_web_view_set_background_color(wv, &rgba);
        }

        var toplevel: ?*c.GtkWidget = null;
        var host_parent: ?*c.GtkWidget = null;
        if (cfg.parent_native_handle) |parent_ptr| {
            const container: *c.GtkContainer = @ptrCast(parent_ptr);
            host_parent = @ptrCast(parent_ptr);
            // `gtk_container_add` on a `GtkBox` packs with `expand = TRUE`, but a plain container
            // (`GtkWindow`, `GtkFixed`, …) needs the expand flags to follow a host resize.
            c.gtk_widget_set_hexpand(@ptrCast(wv), 1);
            c.gtk_widget_set_vexpand(@ptrCast(wv), 1);
            c.gtk_container_add(container, @ptrCast(wv));
        } else {
            const win_widget = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
            toplevel = win_widget;
            const gtk_win: *c.GtkWindow = @ptrCast(win_widget);

            const title_z = self.allocator.dupeSentinel(u8, cfg.title, 0) catch {
                c.gtk_widget_destroy(win_widget);
                return error.OutOfMemory;
            };
            defer self.allocator.free(title_z);

            c.gtk_window_set_title(gtk_win, title_z.ptr);
            c.gtk_window_set_default_size(
                gtk_win,
                @intFromFloat(@max(1.0, cfg.size.width.v)),
                @intFromFloat(@max(1.0, cfg.size.height.v)),
            );
            c.gtk_window_set_resizable(gtk_win, if (cfg.resizable) 1 else 0);
            c.gtk_window_set_decorated(gtk_win, if (cfg.decorations) 1 else 0);
            c.gtk_window_set_keep_above(gtk_win, if (cfg.always_on_top) 1 else 0);
            if (cfg.position) |p| {
                c.gtk_window_move(gtk_win, @intFromFloat(p.x.v), @intFromFloat(p.y.v));
            }
            if (cfg.fullscreen) {
                c.gtk_window_fullscreen(gtk_win);
            }
            if (cfg.transparent) {
                c.gtk_widget_set_app_paintable(win_widget, 1);
                if (c.gtk_widget_get_screen(win_widget)) |screen| {
                    if (c.gdk_screen_get_rgba_visual(screen)) |visual| {
                        c.gtk_widget_set_visual(win_widget, visual);
                    }
                }
            }
            c.gtk_container_add(@ptrCast(win_widget), @ptrCast(wv));
        }

        const win_id = self.windows.acquire(self.allocator, .{
            .toplevel = toplevel,
            .parent = host_parent,
            .webview = wv,
            .ucm = ucm,
            .min_size = cfg.min_size,
            .max_size = cfg.max_size,
        }) catch {
            if (toplevel) |t| c.gtk_widget_destroy(t) else c.gtk_widget_destroy(@ptrCast(wv));
            return error.OutOfMemory;
        };

        if (cfg.min_size != null or cfg.max_size != null) {
            self.applyGeometryHints(win_id) catch {};
        }

        const sig_slot = self.allocator.create(SignalSlot) catch return error.OutOfMemory;
        sig_slot.* = .{ .backend = self, .win_id = win_id };
        self.signal_slots.append(self.allocator, sig_slot) catch {
            self.allocator.destroy(sig_slot);
            return error.OutOfMemory;
        };

        _ = c.g_signal_connect_data(
            ucm,
            "script-message-received::__zts",
            @ptrCast(&onScriptMessage),
            sig_slot,
            null,
            0,
        );
        _ = c.webkit_user_content_manager_register_script_message_handler(ucm, "__zts");

        // Install lightweight helper alias `window.__ztsPostMessage(msg)` alongside raw WebKit handler!
        try self.addInitScript(
            win_id,
            "window.__ztsPostMessage = (m) => window.webkit.messageHandlers.__zts.postMessage(m);",
        );

        for (cfg.init_scripts) |src| {
            try self.addInitScript(win_id, src);
        }

        if (toplevel) |top| {
            _ = c.g_signal_connect_data(
                top,
                "destroy",
                @ptrCast(&onWindowDestroyed),
                sig_slot,
                null,
                0,
            );
            c.gtk_widget_show(@ptrCast(wv));
            if (cfg.visible) {
                c.gtk_widget_show_all(top);
            }
        } else {
            if (cfg.visible) c.gtk_widget_show(@ptrCast(wv));
        }

        if (cfg.initial_html) |html| {
            try self.loadHtml(win_id, html, cfg.initial_url);
        } else if (cfg.initial_url) |url| {
            try self.navigate(win_id, url);
        }

        return win_id;
    }

    pub fn closeWindow(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!void {
        const w_ptr = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        self.dropSnapshots(win_id);
        const top = w_ptr.toplevel;
        const wv = w_ptr.webview;
        const ucm = w_ptr.ucm;
        const already_destroyed = w_ptr.destroyed_by_signal;

        _ = self.pending.cancelForWindow(self.allocator, win_id, cancelWebKitRequest);
        _ = self.windows.release(win_id) catch {};

        if (!already_destroyed) {
            if (top) |t| c.gtk_widget_destroy(t) else c.gtk_widget_destroy(@ptrCast(wv));
        }
        c.g_object_unref(ucm);
    }

    pub fn nativeHandle(self: *LinuxGtkBackend, win_id: types.WindowId) ?*anyopaque {
        const w = self.windows.getPtr(win_id) orelse return null;
        // Embedded windows have no `GtkWindow` of their own: hand back the widget the host actually
        // owns, so `gtk_widget_get_parent()` from host code proves the overlay is really mounted.
        return if (w.toplevel) |t| @ptrCast(t) else @ptrCast(w.webview);
    }

    // -----------------------------------------------------------------------
    // Screenshot capture (`M5-04`) — asynchronous, completed by `step(.poll)`
    // -----------------------------------------------------------------------

    /// Queues an offscreen render of the window's visible viewport.
    ///
    /// WebKit renders through the network process, so the image is only ready after at least one
    /// main-context iteration; `takeCapture()` returns `null` until then. A second request for the
    /// same window while one is in flight supersedes it (the older result is discarded).
    pub fn captureWindow(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;

        self.dropSnapshots(win_id);
        for (self.snapshots.items) |slot| {
            if (sameWindow(slot.win_id, win_id) and !slot.done) slot.discard = true;
        }

        const slot = self.allocator.create(SnapshotSlot) catch return error.OutOfMemory;
        slot.* = .{ .backend = self, .win_id = win_id };
        self.snapshots.append(self.allocator, slot) catch {
            self.allocator.destroy(slot);
            return error.OutOfMemory;
        };

        c.webkit_web_view_get_snapshot(
            w.webview,
            c.WEBKIT_SNAPSHOT_REGION_VISIBLE,
            c.WEBKIT_SNAPSHOT_OPTIONS_NONE,
            null,
            &onSnapshotReady,
            slot,
        );
    }

    /// Collects a finished render, or `null` while WebKit is still rasterising.
    pub fn takeCapture(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!?types.Capture {
        _ = self.windows.getPtr(win_id) orelse return error.WindowNotFound;

        for (self.snapshots.items) |slot| {
            if (!sameWindow(slot.win_id, win_id) or slot.discard) continue;
            if (!slot.done and !slot.failed) return null;

            const failed = slot.failed;
            const bytes = if (failed) null else (slot.buf.toOwnedSlice(self.allocator) catch {
                slot.destroy();
                return error.OutOfMemory;
            });
            slot.destroy();
            if (failed) return error.PlatformFailure;
            return try types.Capture.initOwned(self.allocator, bytes.?);
        }
        return null;
    }

    fn dropSnapshots(self: *LinuxGtkBackend, win_id: types.WindowId) void {
        var idx: usize = 0;
        while (idx < self.snapshots.items.len) {
            const slot = self.snapshots.items[idx];
            if (sameWindow(slot.win_id, win_id)) {
                slot.destroy();
                continue;
            }
            idx += 1;
        }
    }

    fn onSnapshotReady(source_object: ?*anyopaque, result: ?*c.GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
        const slot: *SnapshotSlot = @ptrCast(@alignCast(user_data orelse return));
        const res = result orelse {
            slot.failed = true;
            return;
        };
        // `source_object` is the `WebKitWebView` that started the request (WebKit keeps it alive
        // until the callback runs), so it can be handed straight back to `..._finish`.
        const web_view: *c.WebKitWebView = @ptrCast(@alignCast(source_object orelse {
            slot.failed = true;
            return;
        }));

        var gerr: ?*c.GError = null;
        const surface = c.webkit_web_view_get_snapshot_finish(web_view, res, &gerr);
        if (gerr) |err| c.g_error_free(err);
        if (surface == null) {
            slot.failed = true;
            return;
        }
        defer c.cairo_surface_destroy(surface.?);

        if (slot.discard) {
            slot.buf.clearRetainingCapacity();
            slot.failed = true;
            slot.done = true;
            return;
        }

        const status = c.cairo_surface_write_to_png_stream(surface.?, &writeToSlot, slot);
        if (status != c.CAIRO_STATUS_SUCCESS) {
            slot.failed = true;
            return;
        }
        slot.done = true;
    }

    fn writeToSlot(closure: ?*anyopaque, data: [*]const u8, length: c_uint) callconv(.c) c.cairo_status_t {
        const slot: *SnapshotSlot = @ptrCast(@alignCast(closure orelse return 1));
        slot.buf.appendSlice(slot.backend.allocator, data[0..length]) catch return 1;
        return c.CAIRO_STATUS_SUCCESS;
    }

    /// Overlay embedding (`M3-03`): resize the child WebView to the host container's client area.
    ///
    /// A `GtkBox` already re-packs expanding children on resize, but hosts that use a fixed/overlay
    /// container (`GtkFixed`, `GtkOverlay`, a raw `GtkContainer`) need this explicit sync — and a
    /// host that resizes in its own loop can call it once per frame next to `step(.poll)`.
    pub fn fitParent(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const parent = w.parent orelse return error.Unsupported;
        const width = c.gtk_widget_get_allocated_width(parent);
        const height = c.gtk_widget_get_allocated_height(parent);
        if (width <= 0 or height <= 0) return error.Unsupported;
        c.gtk_widget_set_size_request(@ptrCast(w.webview), width, height);
        c.gtk_widget_queue_resize(parent);
    }

    fn requireGtkWindow(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!*c.GtkWindow {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const top = w.toplevel orelse return error.Unsupported;
        return @ptrCast(top);
    }

    fn applyGeometryHints(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const top = w.toplevel orelse return error.Unsupported;
        var geom: c.GdkGeometry = .{};
        var mask: c_uint = 0;
        if (w.min_size) |ms| {
            geom.min_width = @intFromFloat(@max(0.0, ms.width.v));
            geom.min_height = @intFromFloat(@max(0.0, ms.height.v));
            mask |= c.GDK_HINT_MIN_SIZE;
        }
        if (w.max_size) |xs| {
            geom.max_width = @intFromFloat(@max(1.0, xs.width.v));
            geom.max_height = @intFromFloat(@max(1.0, xs.height.v));
            mask |= c.GDK_HINT_MAX_SIZE;
        }
        c.gtk_window_set_geometry_hints(@ptrCast(top), null, if (mask != 0) &geom else null, mask);
    }

    pub fn setTitle(self: *LinuxGtkBackend, win_id: types.WindowId, title: []const u8) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        const z = self.allocator.dupeSentinel(u8, title, 0) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        c.gtk_window_set_title(gtk_win, z.ptr);
    }

    pub fn setSize(self: *LinuxGtkBackend, win_id: types.WindowId, size: types.LogicalSize) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        c.gtk_window_resize(
            gtk_win,
            @intFromFloat(@max(1.0, size.width.v)),
            @intFromFloat(@max(1.0, size.height.v)),
        );
    }

    pub fn setMinSize(self: *LinuxGtkBackend, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        w.min_size = size;
        try self.applyGeometryHints(win_id);
    }

    pub fn setMaxSize(self: *LinuxGtkBackend, win_id: types.WindowId, size: ?types.LogicalSize) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        w.max_size = size;
        try self.applyGeometryHints(win_id);
    }

    pub fn setPosition(self: *LinuxGtkBackend, win_id: types.WindowId, pos: types.LogicalPoint) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        c.gtk_window_move(gtk_win, @intFromFloat(pos.x.v), @intFromFloat(pos.y.v));
    }

    pub fn setResizable(self: *LinuxGtkBackend, win_id: types.WindowId, resizable: bool) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        c.gtk_window_set_resizable(gtk_win, if (resizable) 1 else 0);
    }

    pub fn setMinimized(self: *LinuxGtkBackend, win_id: types.WindowId, minimized: bool) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        if (minimized) c.gtk_window_iconify(gtk_win) else c.gtk_window_deiconify(gtk_win);
    }

    pub fn setMaximized(self: *LinuxGtkBackend, win_id: types.WindowId, maximized: bool) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        if (maximized) c.gtk_window_maximize(gtk_win) else c.gtk_window_unmaximize(gtk_win);
    }

    pub fn setFullscreen(self: *LinuxGtkBackend, win_id: types.WindowId, fullscreen: bool) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        if (fullscreen) c.gtk_window_fullscreen(gtk_win) else c.gtk_window_unfullscreen(gtk_win);
    }

    pub fn setVisible(self: *LinuxGtkBackend, win_id: types.WindowId, visible: bool) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const target = w.toplevel orelse @as(*c.GtkWidget, @ptrCast(w.webview));
        if (visible) c.gtk_widget_show_all(target) else c.gtk_widget_hide(target);
    }

    pub fn setDecorations(self: *LinuxGtkBackend, win_id: types.WindowId, decorations: bool) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        c.gtk_window_set_decorated(gtk_win, if (decorations) 1 else 0);
    }

    pub fn setAlwaysOnTop(self: *LinuxGtkBackend, win_id: types.WindowId, on_top: bool) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        c.gtk_window_set_keep_above(gtk_win, if (on_top) 1 else 0);
    }

    pub fn setFocus(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        c.gtk_window_present(gtk_win);
    }

    pub fn startDrag(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!void {
        const gtk_win = try self.requireGtkWindow(win_id);
        c.gtk_window_begin_move_drag(gtk_win, 1, 0, 0, 0);
    }

    pub fn addInitScript(self: *LinuxGtkBackend, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const z = self.allocator.dupeSentinel(u8, script, 0) catch return error.OutOfMemory;
        defer self.allocator.free(z);

        const user_script = c.webkit_user_script_new(
            z.ptr,
            c.WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
            c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
            null,
            null,
        );
        defer c.webkit_user_script_unref(user_script);
        c.webkit_user_content_manager_add_script(w.ucm, user_script);
    }

    pub fn evalJs(self: *LinuxGtkBackend, win_id: types.WindowId, script: []const u8) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        if (script.len == 0) return;
        c.webkit_web_view_evaluate_javascript(
            w.webview,
            script.ptr,
            @intCast(script.len),
            null,
            null,
            null,
            null,
            null,
        );
    }

    pub fn navigate(self: *LinuxGtkBackend, win_id: types.WindowId, url: []const u8) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const z = self.allocator.dupeSentinel(u8, url, 0) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        c.webkit_web_view_load_uri(w.webview, z.ptr);
    }

    pub fn loadHtml(self: *LinuxGtkBackend, win_id: types.WindowId, html: []const u8, base_uri: ?[]const u8) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const hz = self.allocator.dupeSentinel(u8, html, 0) catch return error.OutOfMemory;
        defer self.allocator.free(hz);

        const bz = if (base_uri) |b| (self.allocator.dupeSentinel(u8, b, 0) catch return error.OutOfMemory) else null;
        defer if (bz) |s| self.allocator.free(s);

        c.webkit_web_view_load_html(w.webview, hz.ptr, if (bz) |s| s.ptr else null);
    }

    pub fn openDevtools(self: *LinuxGtkBackend, win_id: types.WindowId) types.WebviewError!void {
        const w = self.windows.getPtr(win_id) orelse return error.WindowNotFound;
        const settings = c.webkit_web_view_get_settings(w.webview);
        c.webkit_settings_set_enable_developer_extras(settings, 1);
        const inspector = c.webkit_web_view_get_inspector(w.webview);
        c.webkit_web_inspector_show(inspector);
    }
};

// ============================================================================
// Real Native GTK3 + WebKit2GTK 4.1 End-to-End Integration Test (Xvfb / Desktop)
// ============================================================================

test "LinuxGtkBackend renders HTML, injects UserScript, streams bidirectional binary & JSON over `tauri://` + `ipc://`, and shuts down with 0 leaks" {
    // Runs on real GTK3 + WebKit2GTK 4.1 whenever an X11/Wayland display (`xvfb-run` in CI!) is active;
    // gracefully verifies clean `error.DisplayUnavailable` when invoked without `$DISPLAY`.
    const has_display = (std.c.getenv("DISPLAY") != null) or (std.c.getenv("WAYLAND_DISPLAY") != null);
    const backend = LinuxGtkBackend.init(testing.allocator, testing.io) catch |err| {
        if (!has_display and err == error.DisplayUnavailable) return;
        return err;
    };
    defer backend.deinit();

    const E2eCtx = struct {
        backend: *LinuxGtkBackend,
        allocator: Allocator,
        final_report: ?[]u8 = null,

        fn onTauriScheme(userdata: ?*anyopaque, req: types.SchemeRequest) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const html =
                \\<!doctype html>
                \\<html><body><script>
                \\(async () => {
                \\  try {
                \\    // 1. Send large 96 KiB binary payload over `ipc://` POST (exercises multi-chunk async reader!)
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
                \\    // 2. Send JSON RPC request over `ipc://` POST (completed from a background OS worker thread!)
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
                \\      sum: data.sum,
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
                // Verify custom request header roundtrip AND allocate dynamic heap response (`OwnedBytes` -> `GDestroyNotify`)!
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

            // `/compute`: Dispatch onto a real background worker thread and wake GTK main loop asynchronously!
            const t = std.Thread.spawn(.{}, bgComputeWorker, .{ self.backend, self.allocator, req.request_id }) catch unreachable;
            t.detach();
        }

        fn bgComputeWorker(b: *LinuxGtkBackend, alloc: Allocator, req_id: types.RequestId) void {
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

    var ctx: E2eCtx = .{
        .backend = backend,
        .allocator = testing.allocator,
    };
    defer if (ctx.final_report) |r| testing.allocator.free(r);

    backend.force_software_render = true;
    backend.message_handler = .{ .userdata = &ctx, .onMessage = E2eCtx.onJsMessage };
    try backend.registerScheme("tauri", .{ .userdata = &ctx, .onRequest = E2eCtx.onTauriScheme });
    try backend.registerScheme("ipc", .{ .userdata = &ctx, .onRequest = E2eCtx.onIpcScheme });

    const win = try backend.createWindow(.{
        .title = "Z-Ts Native GTK3 E2E",
        .size = .wh(640, 480),
        .visible = true,
        .init_scripts = &.{"window.__BOOT_TAG__ = 'injected-ok';"},
        .initial_url = "tauri://localhost/index.html",
    });

    const Watchdog = struct {
        b: *LinuxGtkBackend,
        done: std.atomic.Value(bool) = .init(false),
        timed_out: std.atomic.Value(bool) = .init(false),

        fn run(w: *@This(), io: Io) void {
            var ticks: usize = 0;
            while (ticks < 100 and !w.done.load(.acquire)) : (ticks += 1) {
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
        std.debug.print("\n[LinuxGtkBackend E2E] Watchdog timed out waiting for WebKit JS report!\n", .{});
        return error.WebKitE2eTimeout;
    }

    const report = ctx.final_report orelse return error.MissingJsReport;
    const ParsedReport = struct {
        bootInjected: bool,
        binOk: bool,
        tauriHdr: []const u8,
        sum: i64,
    };
    var parsed = try std.json.parseFromSlice(ParsedReport, testing.allocator, report, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value.bootInjected);
    try testing.expect(parsed.value.binOk);
    try testing.expectEqualStrings("ok", parsed.value.tauriHdr);
    try testing.expectEqual(@as(i64, 42), parsed.value.sum);
}
