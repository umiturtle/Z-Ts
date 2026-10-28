//! `wasm32-freestanding` Demo Application Spec for the Isomorphic SSG E2E gate (`M2-01`).
//!
//! The *exact same* `DemoCommands` Zig implementation is compiled to:
//!   1. A native `wasm32-freestanding` `.wasm` binary consumed by `tests/ssg/node_wasm_runner.mjs`
//!      (real `@tauri-apps/api` v2 suite over WebAssembly linear-memory IPC — no server at all!)
//!   2. A native host binary test (`zig build test`) verifying zero-leak `Instance(Spec)` lifecycles.
//!
//! `stream_frames`, `open_pack`, `invert_bytes`, and `emit_from_backend` are byte-identical in
//! behavior to `tests/tauri/e2e_live.zig`, proving full 4-mode isomorphism.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");
const tauri = @import("zts_tauri");
const wasm = @import("zts_wasm");

pub const FrameTick = struct {
    seq: u32,
    pts_ms: f64,
    tag: []const u8,
};

pub const ArchiveStats = struct {
    rid: u53,
    magic: []const u8,
};

pub const SuiteSummary = struct {
    ok: bool,
    mode: []const u8,
    checks_run: u32,
    streamed_count: u32,
    once_hits: u32,
    listen_hits: u32,
    drag_triggered: bool,
    error_message: []const u8,
};

const PackResourceEntry = struct {
    closed_counter: *std.atomic.Value(usize),

    pub fn deinit(self: *PackResourceEntry) void {
        _ = self.closed_counter.fetchAdd(1, .acq_rel);
    }
};

pub const WasmDemoState = struct {
    allocator: Allocator,
    plugins: *tauri.CorePluginStates,
    closed_packs: std.atomic.Value(usize) = .init(0),
    suite_ok: bool = false,
    checks_run: u32 = 0,
    streamed_count: u32 = 0,
    once_hits: u32 = 0,
    listen_hits: u32 = 0,
    drag_triggered: bool = false,
    error_detail: ?[]u8 = null,

    pub fn deinit(self: *WasmDemoState) void {
        if (self.error_detail) |msg| self.allocator.free(msg);
    }
};

pub const DemoCommands = struct {
    pub const RpcState = WasmDemoState;

    pub fn open_pack(state: *WasmDemoState, args: struct { magic: []const u8 }) !ArchiveStats {
        const rid = try state.plugins.resources.insertOwned(PackResourceEntry, .{
            .closed_counter = &state.closed_packs,
        });
        return .{ .rid = rid, .magic = args.magic };
    }

    pub fn packet_closed_count(state: *WasmDemoState) u53 {
        return @intCast(state.closed_packs.load(.acquire));
    }

    pub fn stream_frames(
        ctx: *rpc.Ctx,
        args: struct {
            count: u32,
            label_prefix: []const u8,
            on_tick: tauri.Channel(FrameTick),
        },
    ) !u32 {
        var ch = args.on_tick;
        var i: u32 = 0;
        while (i < args.count) : (i += 1) {
            const tag = try std.fmt.allocPrint(ctx.scratch, "{s}:{d}", .{ args.label_prefix, i });
            try ch.sendCtx(ctx, .{
                .seq = i,
                .pts_ms = @as(f64, @floatFromInt(i)) * 16.666,
                .tag = tag,
            });
        }
        try ch.closeCtx(ctx);
        return args.count;
    }

    pub fn invert_bytes(state: *WasmDemoState, args: rpc.Bytes) !core.OwnedBytes {
        const src = args.slice();
        const out = try state.allocator.alloc(u8, src.len);
        for (src, 0..) |b, i| out[i] = ~b;
        return core.OwnedBytes.fromOwnedSlice(state.allocator, out);
    }

    pub fn emit_from_backend(
        ctx: *rpc.Ctx,
        state: *WasmDemoState,
        args: struct { event_name: []const u8, step: u32 },
    ) !void {
        const call_ctx = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;
        try state.plugins.events.emit(call_ctx.host, ctx.scratch, args.event_name, .{ .step = args.step });
    }

    pub fn drag_count(state: *WasmDemoState) u53 {
        return @intCast(state.plugins.windows.dragCount("main"));
    }

    pub fn report_suite_result(state: *WasmDemoState, args: SuiteSummary) !bool {
        state.suite_ok = args.ok;
        state.checks_run = args.checks_run;
        state.streamed_count = args.streamed_count;
        state.once_hits = args.once_hits;
        state.listen_hits = args.listen_hits;
        state.drag_triggered = args.drag_triggered;
        if (!args.ok and args.error_message.len > 0 and state.error_detail == null) {
            state.error_detail = try state.allocator.dupe(u8, args.error_message);
        }
        return true;
    }
};

pub const DemoOnlySchema = rpc.Schema(.{ .app = DemoCommands });

pub const Spec = struct {
    pub const UserSchema = DemoOnlySchema;
    pub const UserState = WasmDemoState;
    pub const app_config: tauri.AppConfig = .{
        .name = "Z-Ts Studio",
        .version = "2.7.0",
        .identifier = "jp.zts.studio",
        .tauri_version = "2.12.4",
    };
    pub const path_config: tauri.PathState = .{
        .app_identifier = "jp.zts.studio",
        .home_dir = "/home/zts",
        .resource_dir = "/app/resources",
        .executable_dir = "/app/bin",
    };
    pub const main_window: core.WindowSpec = .{
        .label = "main",
        .title = "Z-Ts Studio",
        .size = .wh(1024, 576),
        .initial_url = "index.html",
    };

    pub fn initUserState(
        allocator: Allocator,
        plugins: *tauri.CorePluginStates,
        _: *wasm.WasmHost,
    ) Allocator.Error!WasmDemoState {
        return .{ .allocator = allocator, .plugins = plugins };
    }

    pub fn deinitUserState(state: *WasmDemoState) void {
        state.deinit();
    }

    pub fn bindAll(comptime Full: type, user_state: *WasmDemoState, plugins: *tauri.CorePluginStates) Full.Router {
        return Full.bind(.{
            .app = user_state,
            .tauri_window = &plugins.windows,
            .tauri_event = &plugins.events,
            .tauri_path = &plugins.paths,
            .tauri_app = &plugins.app_state,
            .tauri_resources = &plugins.resources,
            .tauri_menu = &plugins.menu_state,
            .tauri_tray = &plugins.tray_state,
        });
    }
};

pub const wasm_exports = wasm.exportApp(Spec);

/// Browser-console panic reporting (`std.debug` cannot print on `wasm32-freestanding`).
pub const panic = std.debug.FullPanic(wasm.host.reportPanic);

comptime {
    // Referencing a declaration forces semantic analysis of the container, which evaluates the
    // `@export` comptime block inside `zts_wasm.exportApp(Spec)`.
    _ = &wasm_exports.init;
    _ = &wasm_exports.invoke;
}

/// Required by `wasm-ld` when building a `wasm32-freestanding` executable without `-fno-entry`.
pub fn main() void {}

test "native Instance(Spec) executes demo commands identically to WebKit/Bridge hosts" {
    const inst = try wasm.Instance(Spec).create(testing.allocator);
    defer inst.destroy();

    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("plugin:app|name", "{}", false));
    try testing.expectEqualStrings("\"Z-Ts Studio\"", inst.last_response.body.slice());

    // Raw `rpc.Bytes` payloads answer with `application/octet-stream`, exactly like `ipc://` / HTTP.
    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("invertBytes", &[_]u8{ 0x00, 0x55, 0xaa, 0xff }, true));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xaa, 0x55, 0x00 }, inst.last_response.body.slice());
    try testing.expectEqual(wasm.ResponseKind.binary, inst.responseKind());

    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("openPack", "{\"magic\":\"ZPACK_V2\"}", false));
    try testing.expect(std.mem.indexOf(u8, inst.last_response.body.slice(), "\"magic\":\"ZPACK_V2\"") != null);

    // Every emitted `Channel<T>` frame is routed through `WasmHost.evalJs` → captured via `eval_hook`.
    const Recorder = struct {
        var frames: usize = 0;
        fn call(_: ?*anyopaque, script: []const u8) void {
            if (std.mem.indexOf(u8, script, "runCallback(") != null) frames += 1;
        }
    };
    Recorder.frames = 0;
    inst.wasm_host.eval_hook = .{ .callFn = Recorder.call };
    defer inst.wasm_host.eval_hook = null;

    try testing.expectEqual(@as(i32, 1), inst.invokeRaw(
        "streamFrames",
        "{\"count\":3,\"labelPrefix\":\"f\",\"onTick\":\"__CHANNEL__:7\"}",
        false,
    ));
    try testing.expect(Recorder.frames >= 4); // 3 frames + 1 end marker
}
