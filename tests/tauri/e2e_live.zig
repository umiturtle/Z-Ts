//! Full End-to-End Verification of Unmodified Upstream `@tauri-apps/api` v2 (`M1-07`).
//!
//! Proves zero-compromise wire compatibility across THREE independent verification gates:
//!   1. `tsgen` Exact Snapshot Gate — verifies `tests/tauri/src/generated_api.ts` (checked under
//!      `tsc --strict`) matches `DemoOnlySchema.ts_bindings` byte-for-byte.
//!   2. Cross-OS Live HTTP + Cookie + SSE Gate (`BridgeServer` + `BridgeHost` + Node 22) — runs
//!      the unmodified npm `@tauri-apps/api` v2 bundle (`core`, `window`, `dpi`, `event`, `path`,
//!      `app`, `Channel<T>`, `Resource`, binary `Uint8Array` IPC) on Linux, macOS, and Windows.
//!   3. Real Native Engine Gate (`DesktopRuntime(.native)` + `WebKit2GTK 4.1` under `Xvfb`) —
//!      loads `tauri://localhost/index.html` inside a real WebKit browser process with
//!      `AT_DOCUMENT_START` `js_bootstrap` injection, `ipc://` scheme dispatch, `asset://` `206`
//!      byte-range streaming + `403` scope enforcement, and DOM `[data-tauri-drag-region]`
//!      mouse-delegation (including interactive `<button>` exclusion & double-click maximize).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const zts = @import("z_ts");
const core = zts.core;
const web = zts.web;
const rpc = zts.rpc;
const bridge = zts.bridge;
const webview = zts.webview;
const tauri = zts.tauri;

const bundled_suite_js = @embedFile("e2e_bundle");

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

pub const DemoAppState = struct {
    allocator: Allocator,
    plugins: *tauri.CorePluginStates,
    closed_packs: std.atomic.Value(usize) = .init(0),
    suite_done: std.atomic.Value(bool) = .init(false),
    suite_ok: bool = false,
    checks_run: u32 = 0,
    streamed_count: u32 = 0,
    once_hits: u32 = 0,
    listen_hits: u32 = 0,
    drag_triggered: bool = false,
    error_detail: ?[]u8 = null,
    wakeup_host: ?core.Host = null,

    pub fn deinit(self: *DemoAppState) void {
        if (self.error_detail) |msg| self.allocator.free(msg);
    }
};

pub const DemoCommands = struct {
    pub const RpcState = DemoAppState;

    pub fn open_pack(state: *DemoAppState, args: struct { magic: []const u8 }) !ArchiveStats {
        const rid = try state.plugins.resources.insertOwned(PackResourceEntry, .{
            .closed_counter = &state.closed_packs,
        });
        return .{ .rid = rid, .magic = args.magic };
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

    pub fn invert_bytes(state: *DemoAppState, args: rpc.Bytes) !core.OwnedBytes {
        const src = args.slice();
        const out = try state.allocator.alloc(u8, src.len);
        for (src, 0..) |b, i| out[i] = ~b;
        return core.OwnedBytes.fromOwnedSlice(state.allocator, out);
    }

    pub fn emit_from_backend(
        ctx: *rpc.Ctx,
        state: *DemoAppState,
        args: struct { event_name: []const u8, step: u32 },
    ) !void {
        const call_ctx = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;
        try state.plugins.events.emit(call_ctx.host, ctx.scratch, args.event_name, .{ .step = args.step });
    }

    pub fn drag_count(state: *DemoAppState) u53 {
        return @intCast(state.plugins.windows.dragCount("main"));
    }

    pub fn report_suite_result(state: *DemoAppState, args: SuiteSummary) !bool {
        state.suite_ok = args.ok;
        state.checks_run = args.checks_run;
        state.streamed_count = args.streamed_count;
        state.once_hits = args.once_hits;
        state.listen_hits = args.listen_hits;
        state.drag_triggered = args.drag_triggered;
        if (!args.ok and args.error_message.len > 0 and state.error_detail == null) {
            state.error_detail = try state.allocator.dupe(u8, args.error_message);
        }
        state.suite_done.store(true, .release);
        if (state.wakeup_host) |h| h.wakeup();
        return true;
    }
};

pub const DemoOnlySchema = rpc.Schema(.{ .app = DemoCommands });
pub const FullE2eSchema = tauri.withCorePlugins(DemoOnlySchema);

test "1. Generated TypeScript client snapshot matches DemoOnlySchema.ts_bindings byte-for-byte" {
    const checked_ts = @embedFile("src/generated_api.ts");
    const normalized = try std.mem.replaceOwned(u8, testing.allocator, checked_ts, "\r\n", "\n");
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings(DemoOnlySchema.ts_bindings, normalized);
}

test "2. Live BridgeServer + BridgeHost + Node 22 runs unmodified @tauri-apps/api v2 suite end-to-end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "e2e_suite.bundle.js",
        .data = bundled_suite_js,
    });
    const bundle_abs = try tmp.dir.realPathFileAlloc(testing.io, "e2e_suite.bundle.js", testing.allocator);
    defer testing.allocator.free(bundle_abs);

    const assets: web.Assets = .{
        .entries = &.{
            .{
                .path = "/index.html",
                .bytes = "<!doctype html><html><head><title>Z-Ts Bridge E2E</title></head><body></body></html>",
            },
        },
    };

    const plugins = try tauri.CorePluginStates.create(
        testing.allocator,
        testing.io,
        .{ .name = "Z-Ts Studio", .version = "2.7.0", .identifier = "jp.zts.studio" },
        .{ .resource_dir = "/opt/zts/resources", .data_dir = "/var/tmp/zts-data" },
    );
    defer plugins.destroy();

    var app_state: DemoAppState = .{
        .allocator = testing.allocator,
        .plugins = plugins,
    };
    defer app_state.deinit();

    var bound = FullE2eSchema.bind(.{
        .app = &app_state,
        .tauri_window = &plugins.windows,
        .tauri_event = &plugins.events,
        .tauri_path = &plugins.paths,
        .tauri_app = &plugins.app_state,
        .tauri_resources = &plugins.resources,
    });

    const srv = try bridge.BridgeServer.start(testing.allocator, testing.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .assets = assets,
        .rpc_handler = bound.handler(),
    });
    defer srv.stopAndDeinit();

    var bh = zts.BridgeHost.init(testing.allocator, testing.io, srv);
    defer bh.deinit();

    const main_spec: core.WindowSpec = .{
        .label = "main",
        .title = "Boot Window",
        .size = .wh(800, 600),
    };
    const main_win = try bh.host().createWindow(main_spec);
    try plugins.windows.registerWindow(main_win, main_spec);

    var call_ctx: core.CallContext = .{
        .host = bh.host(),
        .window_id = main_win,
    };
    srv.setEnv(&call_ctx);

    var url_buf: [64]u8 = undefined;
    const base_url = srv.baseUrl(&url_buf);

    const res = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "node", "tests/tauri/node_runner.mjs", base_url, bundle_abs },
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("\n=== Tauri Bridge E2E FAILED ===\nstdout:\n{s}\nstderr:\n{s}\n", .{ res.stdout, res.stderr });
        return error.TauriBridgeE2eFailed;
    }

    try testing.expect(app_state.suite_done.load(.acquire));
    try testing.expect(app_state.suite_ok);
    try testing.expectEqual(@as(u32, 8), app_state.streamed_count);
    try testing.expectEqual(@as(u32, 1), app_state.once_hits);
    try testing.expectEqual(@as(u32, 2), app_state.listen_hits);
    try testing.expectEqual(@as(usize, 1), app_state.closed_packs.load(.acquire));
    try testing.expectEqualStrings("Z-Ts Verified Window", bh.backing.windows.get(main_win).?.title);
}

test "3. Native WebKit2GTK 4.1 DesktopRuntime runs unmodified @tauri-apps/api v2 over tauri://, ipc://, and asset://" {
    if (!webview.has_native_gtk) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Seed scoped filesystem files for `asset://localhost/...` (`206` Range + `403` scope rejection)
    try tmp.dir.createDirPath(testing.io, "audio");
    try tmp.dir.createDirPath(testing.io, "secret");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "audio/voice_clip.bin",
        .data = "HDR_CLIPDATA_TAIL",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "secret/private.key",
        .data = "DO_NOT_SERVE",
    });
    const asset_root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(asset_root);

    const page_html =
        \\<!doctype html>
        \\<html>
        \\<head><meta charset="utf-8"><title>Z-Ts WebKit E2E</title></head>
        \\<body>
        \\  <div id="status">running</div>
        \\  <script src="/e2e_suite.bundle.js"></script>
        \\  <script>
        \\    window.addEventListener("DOMContentLoaded", () => {
        \\      window.ZtsTauriSuite.runSuite({ mode: "webkit" });
        \\    });
        \\  </script>
        \\</body>
        \\</html>
    ;

    const assets: web.Assets = .{
        .entries = &.{
            .{ .path = "/index.html", .bytes = page_html },
            .{ .path = "/e2e_suite.bundle.js", .bytes = bundled_suite_js },
        },
    };

    const rt = zts.DesktopRuntime.create(testing.allocator, testing.io, .{
        .backend = .native,
        .app = .{ .name = "Z-Ts Studio", .version = "2.7.0", .identifier = "jp.zts.studio" },
        .paths = .{
            .resource_dir = asset_root,
            .data_dir = "/var/tmp/zts-data",
        },
        .assets = &assets,
        .asset_allow_globs = &.{"audio/**"},
    }) catch |err| switch (err) {
        error.DisplayUnavailable => return,
        else => return err,
    };
    defer rt.destroy();

    var app_state: DemoAppState = .{
        .allocator = testing.allocator,
        .plugins = rt.plugins,
        .wakeup_host = rt.host(),
    };
    defer app_state.deinit();

    var bound = FullE2eSchema.bind(.{
        .app = &app_state,
        .tauri_window = &rt.plugins.windows,
        .tauri_event = &rt.plugins.events,
        .tauri_path = &rt.plugins.paths,
        .tauri_app = &rt.plugins.app_state,
        .tauri_resources = &rt.plugins.resources,
    });
    rt.setRpcHandler(bound.handler());

    _ = try rt.openWindow(.{
        .label = "main",
        .title = "Boot Native",
        .size = .wh(900, 620),
        .initial_url = "tauri://localhost/index.html",
    });

    // Pump native GTK + WebKit2GTK event loop until suite reports completion (with hard 15s watchdog)
    var spin: usize = 0;
    while (!app_state.suite_done.load(.acquire) and spin < 1500) : (spin += 1) {
        _ = rt.step(.poll);
        try Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, testing.io);
    }

    if (!app_state.suite_done.load(.acquire)) {
        return error.WebKitSuiteTimedOut;
    }
    if (!app_state.suite_ok) {
        std.debug.print("\n=== Native WebKit2GTK Tauri v2 Suite FAILED ===\n{s}\n", .{
            app_state.error_detail orelse "(no message)",
        });
        return error.WebKitSuiteFailed;
    }

    try testing.expect(app_state.checks_run >= 22);
    try testing.expectEqual(@as(u32, 8), app_state.streamed_count);
    try testing.expectEqual(@as(u32, 1), app_state.once_hits);
    try testing.expectEqual(@as(u32, 2), app_state.listen_hits);
    try testing.expect(app_state.drag_triggered);
    try testing.expectEqual(@as(usize, 1), app_state.closed_packs.load(.acquire));
}
