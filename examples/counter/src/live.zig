//! Live Preview（ブラウザ）エントリポイント（`RuntimeMode.bridge`）。
//!
//! `zts_bridge.BridgeServer`（HTTP/1.1 + `206` Range + 三重 CSRF + SSE）で **同じ**
//! `zts_web.Assets` を配信し、`zts_core.Host` を `BridgeHost` に差し替えるだけで、デスクトップと
//! 完全に同一のコマンド実装・同一フロントエンドがブラウザ上で動きます。
//!
//! ```bash
//! zig build live
//! ./zig-out/bin/counter-live --port 8788 --host 0.0.0.0
//! # -> http://localhost:8788/
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const core = @import("zts_core");
const tauri = @import("zts_tauri");
const bridge = @import("zts_bridge");
const zts = @import("z_ts");
const frontend = @import("counter_frontend");

const app = @import("app.zig");

const Impl = app.App(.bridge);

const default_port: u16 = 8788;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arg_arena = std.heap.ArenaAllocator.init(gpa);
    defer arg_arena.deinit();
    const args = try init.minimal.args.toSlice(arg_arena.allocator());

    var host: []const u8 = init.environ_map.get("ZTS_HOST") orelse "0.0.0.0";
    var port: u16 = if (init.environ_map.get("PORT")) |raw| std.fmt.parseInt(u16, raw, 10) catch default_port else default_port;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 >= args.len) return error.MissingPort;
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (i + 1 >= args.len) return error.MissingHost;
            i += 1;
            host = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Z-Ts Counter — Live Preview (HTTP Bridge)
                \\
                \\  -p, --port <u16>   待受ポート (default: {d}, env PORT)
                \\      --host <addr>  待受アドレス (default: 0.0.0.0, env ZTS_HOST)
                \\
            , .{default_port});
            return;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    const plugins = try tauri.CorePluginStates.create(gpa, io, app.app_config, app.path_config);
    // `plugins` / `state` / `bound` / `srv` / `bh` はプロセス終了まで生存させる（サーバ常駐）。
    var state = Impl.State.init(gpa, plugins);
    var bound = Impl.Spec.bindAll(tauri.withCorePlugins(Impl.Schema), &state, plugins);

    const srv = try bridge.BridgeServer.start(gpa, io, .{
        .host = host,
        .port = port,
        .assets = frontend.assets,
        .rpc_handler = bound.handler(),
    });
    errdefer srv.stopAndDeinit();

    var bh = zts.BridgeHost.init(gpa, io, srv);
    const window_spec: core.WindowSpec = .{
        .label = "main",
        .title = "Z-Ts Counter",
        .size = .wh(560, 640),
    };
    const win = try bh.host().createWindow(window_spec);
    try plugins.windows.registerWindow(win, window_spec);

    var call_ctx: core.CallContext = .{ .host = bh.host(), .window_id = win };
    srv.setEnv(&call_ctx);

    std.debug.print(
        \\Z-Ts Counter — Live Preview
        \\  mode : {s}
        \\  bind : {s}:{d}
        \\  url  : http://localhost:{d}/
        \\
    , .{ Impl.mode_name, host, srv.port(), srv.port() });

    // 常駐ループ（`accept` / SSE / RPC は BridgeServer の専用スレッドで処理される）。
    while (true) {
        try Io.Clock.Duration.sleep(.{ .raw = .fromSeconds(3600), .clock = .awake }, io);
    }
}
