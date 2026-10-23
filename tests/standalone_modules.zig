//! External Standalone Consumer Verification (`tests/standalone_modules.zig`).
//!
//! Compiled as an isolated target that ONLY has access to `zts_foundation`, `zts_web`,
//! and `zts_rpc` (`zts_core` and `z_ts` are intentionally NOT imported!).
//!
//! If any future change accidentally introduces desktop/WebView/Tauri coupling into
//! `zts_foundation`, `zts_web`, or `zts_rpc`, this target immediately fails CI compilation.

const std = @import("std");
const testing = std.testing;

const foundation = @import("zts_foundation");
const web = @import("zts_web");
const rpc = @import("zts_rpc");
const bridge = @import("zts_bridge");
const webview = @import("zts_webview");

test "Standalone modules (`zts_foundation`, `zts_web`, `zts_rpc`) operate completely independently of desktop host layers" {
    // 1. `zts_foundation`: Generational handles + slot pool + MPSC ring queue
    const ResourceId = foundation.Handle(.resource);
    var pool: foundation.HandlePool([]const u8, .resource) = .empty;
    defer pool.deinit(testing.allocator);

    const h1: ResourceId = try pool.acquire(testing.allocator, "pack://scene_01.bin");
    try testing.expectEqualStrings("pack://scene_01.bin", pool.getPtr(h1).?.*);

    var queue: foundation.RingQueue(ResourceId) = .empty;
    defer queue.deinit(testing.allocator);
    _ = try queue.push(testing.allocator, testing.io, h1);
    try testing.expectEqual(h1, queue.tryPop(testing.io).?);

    // 2. `zts_web`: Embedded binary/media asset delivery with HTTP `206 Partial Content` byte-range seeking
    const assets = web.Assets{
        .entries = &.{
            .{ .path = "/media/track.ogg", .bytes = "OggS\x00\x02\x00\x00\x00\x00SEEKABLE_AUDIO_STREAM_PAYLOAD" },
        },
    };
    var seek_resp = try assets.resolve(testing.allocator, "/media/track.ogg", .{
        .range_header = "bytes=10-23",
    });
    defer seek_resp.deinit();
    try testing.expectEqual(web.AssetStatus.partial_content, seek_resp.status);
    try testing.expectEqualStrings("SEEKABLE_AUDIO", seek_resp.body.slice());

    // 3. `zts_rpc`: Custom runtime environment injected via `Ctx.withEnv` + strict TS client generation
    const CustomRuntime = struct {
        active_resource: ResourceId,
    };

    const ControlCmds = struct {
        pub fn active_item(ctx: *rpc.Ctx) error{MissingContext}!ResourceId {
            const rt = try ctx.requireEnv(CustomRuntime);
            return rt.active_resource;
        }
    };

    const StandaloneApi = rpc.Schema(.{ .ctrl = ControlCmds });
    try testing.expect(std.mem.indexOf(u8, StandaloneApi.ts_bindings, "createIpcTransport") != null);
    try testing.expect(std.mem.indexOf(u8, StandaloneApi.ts_bindings, "createFetchTransport") != null);

    var router = StandaloneApi.bind(.{});
    const handler = router.handler();

    const rt: CustomRuntime = .{ .active_resource = h1 };
    var ctx = rpc.Ctx.init(testing.io, testing.failing_allocator).withEnv(&rt);

    var res = handler.dispatch(testing.allocator, &ctx, "activeItem", "");
    defer res.deinit();
    try testing.expectEqual(foundation.IpcStatus.ok, res.status);

    const decoded = try rpc.decode(ResourceId, testing.allocator, res.body.slice());
    defer decoded.deinit();
    try testing.expectEqual(h1, decoded.value);

    // 4. `zts_bridge`: Live HTTP/1.1 + `206` Range + triple-CSRF RPC + SSE server with ZERO windowing coupling!
    const srv = try bridge.BridgeServer.start(testing.allocator, testing.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .assets = assets,
        .rpc_handler = handler,
    });
    defer srv.stopAndDeinit();
    try testing.expect(srv.port() > 0);

    // 5. `zts_webview`: Standalone step-driven WebView engine with ZERO JSON / RPC / Tauri coupling!
    var wv_engine = try webview.Engine.init(testing.allocator, testing.io, .headless_mock);
    defer wv_engine.deinit();
    const wv_win = try wv_engine.createWindow(.{ .title = "Standalone Engine Overlay" });
    try wv_engine.evalJs(wv_win, "window.__overlay = 1;");
    wv_engine.requestQuit();
    try testing.expect(!wv_engine.step(.poll));
}
