//! Live Preview 成果物の統合テスト (`M2-02`)。
//!
//! `BridgeServer` を **実 TCP ポート** で起動し、`tests/live_probe.mjs`（Node 22 の実 `fetch`）から
//! 「埋め込み HTML 配信 → app.js 配信 → Cookie + Invoke-Key + Origin 付き RPC → 三重 CSRF 拒否
//! → SSE `counter:changed` 配送」を検証します。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const tauri = @import("zts_tauri");
const bridge = @import("zts_bridge");
const zts = @import("z_ts");
const frontend = @import("counter_frontend");
/// `build.zig` が `tests/live_probe.mjs` をモジュール化したもの（cwd 非依存で実行するため埋め込む）。
const probe_source = @embedFile("live_probe_js");

const app = @import("app.zig");

test "Live Preview: embedded frontend + counter RPC + SSE over real TCP" {
    const Impl = app.App(.bridge);
    const io = testing.io;
    const allocator = testing.allocator;

    const plugins = try tauri.CorePluginStates.create(allocator, io, app.app_config, app.path_config);
    defer plugins.destroy();

    var state = Impl.State.init(allocator, plugins);
    defer state.deinit();

    var bound = Impl.Spec.bindAll(tauri.withCorePlugins(Impl.Schema), &state, plugins);

    const srv = try bridge.BridgeServer.start(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0, // OS 割り当ての空きポート
        .assets = frontend.assets,
        .rpc_handler = bound.handler(),
    });
    defer srv.stopAndDeinit();

    var bh = zts.BridgeHost.init(allocator, io, srv);
    defer bh.deinit();

    const window_spec: core.WindowSpec = .{
        .label = "main",
        .title = "Z-Ts Counter",
        .size = .wh(560, 640),
    };
    const win = try bh.host().createWindow(window_spec);
    try plugins.windows.registerWindow(win, window_spec);

    var call_ctx: core.CallContext = .{ .host = bh.host(), .window_id = win };
    srv.setEnv(&call_ctx);

    try testing.expect(srv.port() > 0);
    var url_buf: [64]u8 = undefined;
    const base_url = srv.baseUrl(&url_buf);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "live_probe.mjs", .data = probe_source });
    const probe_path = try tmp.dir.realPathFileAlloc(io, "live_probe.mjs", allocator);
    defer allocator.free(probe_path);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "node", probe_path, base_url },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "\n=== Live Preview probe FAILED ===\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ result.stdout, result.stderr },
        );
        return error.LivePreviewProbeFailed;
    }
    std.debug.print("{s}", .{result.stdout});

    // プローブ内の increment / reset / SSE ループが同じ Zig 状態を動かしている。
    try testing.expect(state.count > 0);
    try testing.expect(state.mutations > 0);
}
