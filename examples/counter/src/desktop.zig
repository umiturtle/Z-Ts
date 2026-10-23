//! デスクトップ単一バイナリ・エントリポイント（`RuntimeMode.desktop`）。
//!
//! ```bash
//! zig build desktop            # -> zig-out/bin/counter
//! ./zig-out/bin/counter        # ネイティブ WebView (Linux: GTK3 + WebKit2GTK 4.1)
//! ./zig-out/bin/counter --selftest   # ヘッドレス自己診断 (CI / SSH 環境)
//! ```
//!
//! フロントエンドは `build.zig` の `embedFrontendDir` 相当ステップで `@embedFile` 済みのため、
//! 実行時に `dist/` や dev server は不要（単一バイナリで完結）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("zts_core");
const tauri = @import("zts_tauri");
const zts = @import("z_ts");
const frontend = @import("counter_frontend");

const app = @import("app.zig");

const Impl = app.App(.desktop);

const window_spec: core.WindowSpec = .{
    .label = "main",
    .title = "Z-Ts Counter",
    .size = .wh(560, 640),
    .min_size = .wh(380, 520),
    .initial_url = "tauri://localhost/",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arg_arena = std.heap.ArenaAllocator.init(gpa);
    defer arg_arena.deinit();
    const args = try init.minimal.args.toSlice(arg_arena.allocator());

    var selftest = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--selftest")) {
            selftest = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Z-Ts Counter (desktop) — {s} のネイティブ WebView 実行
                \\
                \\  --selftest   ウィンドウを開かず HeadlessMock で IPC を自己診断
                \\  --help       このメッセージ
                \\
            , .{Impl.mode_name});
            return;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    const backend: zts.webview.BackendKind = if (selftest) .headless_mock else .auto;

    const rt = try zts.DesktopRuntime.create(gpa, io, .{
        .backend = backend,
        .app = app.app_config,
        .paths = app.path_config,
        .assets = &frontend.assets,
    });
    defer rt.destroy();

    var state = Impl.State.init(gpa, rt.plugins);
    defer state.deinit();

    var bound = Impl.Spec.bindAll(tauri.withCorePlugins(Impl.Schema), &state, rt.plugins);
    rt.setRpcHandler(bound.handler());

    const win = try rt.openWindow(window_spec);

    if (selftest) {
        try runSelftest(rt, win, &state);
        return;
    }

    std.debug.print("Z-Ts Counter (desktop) — mode={s}\n", .{Impl.mode_name});
    rt.run();
}

/// ネイティブ WebView を開かず、`HeadlessMock` 上で `tauri://` / `ipc://` を実走させる自己診断。
fn runSelftest(rt: *zts.DesktopRuntime, win: core.WindowId, state: *Impl.State) !void {
    const mock = rt.engine.headless_mock;
    const auth = [_]zts.webview.HeaderPair{
        .{ .name = "Tauri-Invoke-Key", .value = rt.invoke_key },
        .{ .name = "Origin", .value = "tauri://localhost" },
    };

    // 1. `tauri://localhost/` が埋め込みフロントエンド + `__TAURI_INTERNALS__` を返す。
    _ = try mock.simulateSchemeRequest(win, "GET", "tauri://localhost/", &auth, "");
    _ = rt.step(.poll);
    if (mock.completed_records.items.len != 1) return error.SelftestMissingResponse;
    const page = mock.completed_records.items[0];
    if (page.status_code != 200) return error.SelftestBadStatus;
    // デスクトップでは `__TAURI_INTERNALS__` は HTML ではなく `init_scripts` で注入される
    // (`inject_bootstrap_into_html = false`) ため、ここでは埋め込みアセットだけを検証する。
    if (std.mem.indexOf(u8, page.body, "app.js") == null) return error.SelftestMissingBundle;
    if (std.mem.indexOf(u8, page.body, "id=\"count\"") == null) return error.SelftestMissingMarkup;

    // 2. 実コマンド 2 回（`increment` ×2）→ Zig 状態と応答が一致する。
    var n: usize = 0;
    while (n < 2) : (n += 1) {
        _ = try mock.simulateSchemeRequest(win, "POST", "ipc://localhost/increment", &auth, "{}");
        _ = rt.step(.poll);
    }
    const last = mock.completed_records.items[mock.completed_records.items.len - 1];
    if (last.status_code != 200) return error.SelftestRpcFailed;
    if (state.count != 2) return error.SelftestStateMismatch;
    if (std.mem.indexOf(u8, last.body, "\"mode\":\"desktop\"") == null) return error.SelftestModeMismatch;

    std.debug.print(
        "OK desktop mode={s} count={d} step={d} mutations={d} html={d}B rpc={s}\n",
        .{ Impl.mode_name, state.count, state.step, state.mutations, page.body.len, last.body },
    );
}
