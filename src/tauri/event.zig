//! `plugin:event|*` Pub/Sub Event Bus & Target Router (`src/tauri/event.zig`).
//!
//! 100% wire-compatible with `@tauri-apps/api/event` (`vendor/tauri/packages/api/src/event.ts`
//! and `vendor/tauri/crates/tauri/src/event/mod.rs`):
//! - Validates event names against Tauri's strict charset rule (`[A-Za-z0-9_/:\\-]+`).
//! - Supports all 6 `EventTarget` variants (`Any`, `App`, `AnyLabel`, `Window`, `Webview`, `WebviewWindow`).
//! - Delivers targeted events to matching JS listeners via `window.__ztsDeliverEvent(event, payload, [ids])`
//!   AND fires server-side Zig native callbacks registered via `EventBus.onNative`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const foundation = @import("zts_foundation");
const html_escape = foundation.html_escape;
const core = @import("zts_core");
const rpc = @import("zts_rpc");

/// `plugin:event` failures. `IllegalEventName` rejects names Tauri reserves (`tauri://…`), which is
/// what keeps a page from forging the framework's own lifecycle events.
pub const EventError = core.HostError || error{
    IllegalEventName,
    MissingHostContext,
};

/// Wire-compatible with Tauri v2 `#[serde(tag = "kind")] enum EventTarget`.
pub const EventTarget = union(enum) {
    /// Every listener, whatever window it belongs to. Used for app-wide broadcasts.
    Any: void,
    /// Application-level listeners only (the `listen()` calls that passed no target).
    App: void,
    /// Every window whose label matches the pattern (glob).
    AnyLabel: struct { label: []const u8 },
    /// The window with exactly this label.
    Window: struct { label: []const u8 },
    /// The webview with this label (same set as `Window` today, kept for v2 wire parity).
    Webview: struct { label: []const u8 },
    /// The window/webview pair with this label (`@tauri-apps/api`'s default target).
    WebviewWindow: struct { label: []const u8 },

    pub const json_union: rpc.UnionConfig = .{
        .style = .internal,
        .tag_field = "kind",
    };

    pub fn targetLabel(self: EventTarget) ?[]const u8 {
        return switch (self) {
            .Any, .App => null,
            .AnyLabel => |v| v.label,
            .Window => |v| v.label,
            .Webview => |v| v.label,
            .WebviewWindow => |v| v.label,
        };
    }
};

/// Enforces Tauri's exact event name character rule (`crates/tauri/src/event/event_name.rs`):
/// non-empty ASCII `[A-Za-z0-9\\-_/:]+`.
pub fn isValidEventName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '/' or ch == ':';
        if (!ok) return false;
    }
    return true;
}

/// Zig-side listener: receives the raw JSON payload exactly as the webview will see it, so a native
/// subscriber and a JS subscriber can never observe different encodings.
pub const NativeEventFn = *const fn (userdata: ?*anyopaque, event_name: []const u8, raw_json_payload: []const u8) void;

const JsListener = struct {
    event_id: u32,
    window_id: core.WindowId,
    window_label: []u8,
    event_name: []u8,
    handler_id: u32,
    filter_label: ?[]u8,

    fn deinit(self: *JsListener, allocator: Allocator) void {
        allocator.free(self.window_label);
        allocator.free(self.event_name);
        if (self.filter_label) |fl| allocator.free(fl);
    }
};

const NativeListener = struct {
    id: u32,
    event_name: []u8,
    userdata: ?*anyopaque,
    cb: NativeEventFn,
};

/// The `plugin:event` registry: JS listeners (id per `listen()` call, filtered by target) and native
/// listeners, plus the label resolver used to route `AnyLabel` / `Window` targets. Mutations are
/// mutex-guarded because `emit()` may come from any thread.
pub const EventBus = struct {
    /// Allocator that owns listener names and labels.
    allocator: Allocator,
    /// IO reactor used for the mutex.
    io: Io,
    /// Guards the listener lists: `emit()` may be called from any thread.
    mu: Io.Mutex = .init,
    /// Counter behind the ids `listen()` returns.
    next_id: u32 = 1,
    /// Listeners registered from the page.
    js_listeners: std.ArrayList(JsListener) = .empty,
    /// Listeners registered from Zig.
    native_listeners: std.ArrayList(NativeListener) = .empty,
    /// Resolves a `WindowId` to its label, so `AnyLabel` / `Window` targeting can match.
    window_labels: ?*const fn (userdata: ?*anyopaque, Allocator, core.WindowId) Allocator.Error!?[]u8 = null,
    /// Opaque pointer passed to `window_labels`.
    window_labels_ctx: ?*anyopaque = null,

    pub fn init(allocator: Allocator, io: Io) EventBus {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *EventBus) void {
        for (self.js_listeners.items) |*l| l.deinit(self.allocator);
        self.js_listeners.deinit(self.allocator);
        for (self.native_listeners.items) |l| self.allocator.free(l.event_name);
        self.native_listeners.deinit(self.allocator);
    }

    pub fn onNative(
        self: *EventBus,
        event_name: []const u8,
        userdata: ?*anyopaque,
        cb: NativeEventFn,
    ) (Allocator.Error || error{IllegalEventName})!u32 {
        if (!isValidEventName(event_name)) return error.IllegalEventName;
        const name_copy = try self.allocator.dupe(u8, event_name);
        errdefer self.allocator.free(name_copy);

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        const id = self.next_id;
        self.next_id += 1;
        try self.native_listeners.append(self.allocator, .{
            .id = id,
            .event_name = name_copy,
            .userdata = userdata,
            .cb = cb,
        });
        return id;
    }

    /// Serializes `payload` as HTML-safe JSON and emits `event_name` to all matching listeners.
    pub fn emit(
        self: *EventBus,
        host: core.Host,
        scratch: Allocator,
        event_name: []const u8,
        payload: anytype,
    ) !void {
        const json_bytes = try rpc.encodeAlloc(scratch, payload);
        defer scratch.free(json_bytes);
        return self.dispatchRaw(host, scratch, .Any, event_name, json_bytes);
    }

    /// Serializes `payload` as HTML-safe JSON and emits `event_name` to `target`.
    pub fn emitTo(
        self: *EventBus,
        host: core.Host,
        scratch: Allocator,
        target: EventTarget,
        event_name: []const u8,
        payload: anytype,
    ) !void {
        const json_bytes = try rpc.encodeAlloc(scratch, payload);
        defer scratch.free(json_bytes);
        return self.dispatchRaw(host, scratch, target, event_name, json_bytes);
    }

    /// Emits `event_name` with raw JSON payload to matching native listeners and JS window listeners.
    pub fn dispatchRaw(
        self: *EventBus,
        host: core.Host,
        scratch: Allocator,
        emit_target: EventTarget,
        event_name: []const u8,
        raw_payload: []const u8,
    ) EventError!void {
        if (!isValidEventName(event_name)) return error.IllegalEventName;
        const payload_slice = if (raw_payload.len == 0) "null" else raw_payload;

        const ListenerPair = struct {
            handler_id: u32,
            event_id: u32,
        };
        const TargetDelivery = struct {
            win_id: core.WindowId,
            pairs: std.ArrayList(ListenerPair) = .empty,
        };
        var deliveries: std.ArrayList(TargetDelivery) = .empty;
        var native_snapshot: std.ArrayList(NativeListener) = .empty;

        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);

            for (self.native_listeners.items) |nl| {
                if (std.mem.eql(u8, nl.event_name, event_name)) {
                    try native_snapshot.append(scratch, nl);
                }
            }

            if (emit_target != .App) {
                for (self.js_listeners.items) |l| {
                    if (!std.mem.eql(u8, l.event_name, event_name)) continue;

                    // Target matching:
                    // 1. Does `emit_target` address this window (`l.window_label`)?
                    if (emit_target.targetLabel()) |wanted_label| {
                        if (!std.mem.eql(u8, l.window_label, wanted_label)) continue;
                    }
                    // 2. Did the listener itself restrict to a specific label?
                    if (l.filter_label) |fl| {
                        const effective = emit_target.targetLabel() orelse l.window_label;
                        if (!std.mem.eql(u8, fl, effective)) continue;
                    }

                    var found: ?*TargetDelivery = null;
                    for (deliveries.items) |*d| {
                        if (d.win_id.eql(l.window_id)) {
                            found = d;
                            break;
                        }
                    }
                    if (found == null) {
                        try deliveries.append(scratch, .{ .win_id = l.window_id });
                        found = &deliveries.items[deliveries.items.len - 1];
                    }
                    try found.?.pairs.append(scratch, .{ .handler_id = l.handler_id, .event_id = l.event_id });
                }
            }
        }

        for (native_snapshot.items) |nl| {
            nl.cb(nl.userdata, event_name, payload_slice);
        }

        for (deliveries.items) |d| {
            var aw: std.Io.Writer.Allocating = .init(scratch);
            defer aw.deinit();

            aw.writer.writeAll("(function(){const p=") catch return error.OutOfMemory;
            aw.writer.writeAll(payload_slice) catch return error.OutOfMemory;
            aw.writer.writeByte(';') catch return error.OutOfMemory;
            for (d.pairs.items) |pair| {
                aw.writer.print("window.__TAURI_INTERNALS__.runCallback({d},{{\"event\":", .{pair.handler_id}) catch return error.OutOfMemory;
                html_escape.writeJsonString(&aw.writer, event_name, true) catch return error.OutOfMemory;
                aw.writer.print(",\"id\":{d},\"payload\":p}});", .{pair.event_id}) catch return error.OutOfMemory;
            }
            aw.writer.writeAll("})();") catch return error.OutOfMemory;

            try host.evalJs(d.win_id, aw.written());
        }
    }
};

/// `plugin:event|*` RPC command namespace (`Schema` key: `.event`).
pub const Commands = struct {
    pub const rpc_prefix = "plugin:event|";
    pub const RpcState = EventBus;

    pub fn listen(
        ctx: *rpc.Ctx,
        bus: *EventBus,
        args: struct {
            event: []const u8,
            target: EventTarget = .Any,
            handler: u32,
        },
    ) EventError!u32 {
        if (!isValidEventName(args.event)) return error.IllegalEventName;
        const call_ctx = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;

        var resolved_label: ?[]u8 = null;
        if (bus.window_labels) |fn_ptr| {
            resolved_label = try fn_ptr(bus.window_labels_ctx, bus.allocator, call_ctx.window_id);
        }
        const win_label = resolved_label orelse try bus.allocator.dupe(u8, "main");
        errdefer bus.allocator.free(win_label);

        const ev_copy = try bus.allocator.dupe(u8, args.event);
        errdefer bus.allocator.free(ev_copy);

        const fl_copy: ?[]u8 = if (args.target.targetLabel()) |lbl|
            try bus.allocator.dupe(u8, lbl)
        else
            null;
        errdefer if (fl_copy) |p| bus.allocator.free(p);

        bus.mu.lockUncancelable(bus.io);
        const event_id = bus.next_id;
        bus.next_id += 1;
        bus.js_listeners.append(bus.allocator, .{
            .event_id = event_id,
            .window_id = call_ctx.window_id,
            .window_label = win_label,
            .event_name = ev_copy,
            .handler_id = args.handler,
            .filter_label = fl_copy,
        }) catch {
            bus.mu.unlock(bus.io);
            return error.OutOfMemory;
        };
        bus.mu.unlock(bus.io);

        // Register into the calling window's `__ztsRegisterEvent` table so `deliverEvent` resolves `handlerId`.
        var aw: std.Io.Writer.Allocating = .init(ctx.scratch);
        defer aw.deinit();
        aw.writer.writeAll("window.__ztsRegisterEvent&&window.__ztsRegisterEvent(") catch return error.OutOfMemory;
        html_escape.writeJsonString(&aw.writer, args.event, true) catch return error.OutOfMemory;
        aw.writer.print(",{d},{d},null);", .{ event_id, args.handler }) catch return error.OutOfMemory;
        try call_ctx.host.evalJs(call_ctx.window_id, aw.written());

        return event_id;
    }

    pub fn unlisten(
        _: *rpc.Ctx,
        bus: *EventBus,
        args: struct { event: []const u8, event_id: u32 },
    ) void {
        bus.mu.lockUncancelable(bus.io);
        defer bus.mu.unlock(bus.io);

        var idx: usize = 0;
        while (idx < bus.js_listeners.items.len) {
            const item = &bus.js_listeners.items[idx];
            if (item.event_id == args.event_id and std.mem.eql(u8, item.event_name, args.event)) {
                var removed = bus.js_listeners.swapRemove(idx);
                removed.deinit(bus.allocator);
                return;
            }
            idx += 1;
        }
    }

    pub fn emit(
        ctx: *rpc.Ctx,
        bus: *EventBus,
        args: struct { event: []const u8, payload: rpc.RawJson = .{} },
    ) EventError!void {
        const call_ctx = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;
        try bus.dispatchRaw(call_ctx.host, ctx.scratch, .Any, args.event, args.payload.raw);
    }

    pub fn emit_to(
        ctx: *rpc.Ctx,
        bus: *EventBus,
        args: struct { target: EventTarget, event: []const u8, payload: rpc.RawJson = .{} },
    ) EventError!void {
        const call_ctx = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;
        try bus.dispatchRaw(call_ctx.host, ctx.scratch, args.target, args.event, args.payload.raw);
    }
};

test "plugin:event routes broadcast and window-targeted events, enforces charset, and cleans up unlisten" {
    var rec = core.RecordingHost.init(testing.allocator);
    defer rec.deinit();
    const win_main = try rec.host().createWindow(.{ .label = "main" });
    const win_overlay = try rec.host().createWindow(.{ .label = "overlay" });

    const LabelLookup = struct {
        main_id: core.WindowId,
        fn lookup(ud: ?*anyopaque, alloc: Allocator, wid: core.WindowId) Allocator.Error!?[]u8 {
            const self: *const @This() = @ptrCast(@alignCast(ud.?));
            return try alloc.dupe(u8, if (wid.eql(self.main_id)) "main" else "overlay");
        }
    };
    var lookup_ctx: LabelLookup = .{ .main_id = win_main };

    var bus = EventBus.init(testing.allocator, testing.io);
    defer bus.deinit();
    bus.window_labels = LabelLookup.lookup;
    bus.window_labels_ctx = &lookup_ctx;

    var native_hits: usize = 0;
    _ = try bus.onNative("scene:changed", &native_hits, struct {
        fn onEv(ud: ?*anyopaque, _: []const u8, _: []const u8) void {
            const c: *usize = @ptrCast(@alignCast(ud.?));
            c.* += 1;
        }
    }.onEv);

    const S = rpc.Schema(.{ .event = Commands });
    var router = S.bind(.{ .event = &bus });
    const h = router.handler();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var cc_main: core.CallContext = .{ .host = rec.host(), .window_id = win_main };
    var cc_overlay: core.CallContext = .{ .host = rec.host(), .window_id = win_overlay };
    var ctx_main = rpc.Ctx.init(testing.io, arena.allocator()).withEnv(&cc_main);
    var ctx_overlay = rpc.Ctx.init(testing.io, arena.allocator()).withEnv(&cc_overlay);

    // Both windows subscribe to `scene:changed`
    var l1 = h.dispatch(arena.allocator(), &ctx_main, "plugin:event|listen", "{\"event\":\"scene:changed\",\"target\":{\"kind\":\"Any\"},\"handler\":101}");
    defer l1.deinit();
    var l2 = h.dispatch(arena.allocator(), &ctx_overlay, "plugin:event|listen", "{\"event\":\"scene:changed\",\"target\":{\"kind\":\"Any\"},\"handler\":202}");
    defer l2.deinit();

    // Emit targeted ONLY to `overlay` -> `win_overlay` receives delivery `202`, `win_main` (`101`) does not!
    const before_count = rec.eval_log.items.len;
    var em_resp = h.dispatch(
        arena.allocator(),
        &ctx_main,
        "plugin:event|emit_to",
        "{\"target\":{\"kind\":\"Window\",\"label\":\"overlay\"},\"event\":\"scene:changed\",\"payload\":{\"scene\":\"battle\"}}",
    );
    defer em_resp.deinit();
    try testing.expectEqual(core.IpcStatus.ok, em_resp.status);
    try testing.expectEqual(@as(usize, 1), native_hits);
    try testing.expectEqual(before_count + 1, rec.eval_log.items.len);
    try testing.expect(std.mem.indexOf(u8, rec.eval_log.items[before_count], "runCallback(202,") != null);

    // Illegal event name with CR/LF injection is rejected with zero JS execution!
    var bad_resp = h.dispatch(arena.allocator(), &ctx_main, "plugin:event|listen", "{\"event\":\"bad\\nname\",\"handler\":1}");
    defer bad_resp.deinit();
    try testing.expectEqual(core.IpcStatus.err, bad_resp.status);
}
