//! Z-Ts: Modular Zig 0.17 Application & Engine Foundation Packages.
//!
//! Exposes strictly layered, orthogonal Zig modules so downstream consumers (desktop apps,
//! engines, media/streaming tools, servers, and CLIs) only compile and link what they use:
//! - `zts_foundation`: Zero-dep data structures (`OwnedBytes`, `HandlePool`, `RingQueue`, `geometry`, `glob`).
//! - `zts_web`: Standalone embedded asset delivery, HTTP `206` Range seeking, MIME, URL & CSP.
//! - `zts_rpc`: Standalone `comptime` JSON/Binary RPC router, codec & strict TypeScript generator (`tsgen`).
//! - `zts_core`: Desktop `Host` VTable + re-exports of `zts_foundation` and `zts_web`.

const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub const foundation = @import("zts_foundation");
pub const web = @import("zts_web");
pub const core = @import("zts_core");
pub const rpc = @import("zts_rpc");

test "z_ts scaffold version & unified nominal Handle identity across standalone modules" {
    try std.testing.expectEqual(@as(usize, 0), version.major);
    try std.testing.expectEqual(@as(usize, 1), version.minor);
    comptime {
        std.debug.assert(foundation.Handle(.window) == core.WindowId);
        std.debug.assert(foundation.Handle(.window) == rpc.Handle(.window));
        std.debug.assert(foundation.OwnedBytes == web.OwnedBytes);
        std.debug.assert(foundation.OwnedBytes == core.OwnedBytes);
    }
}

test "Desktop Host VTable plugins cleanly compose atop standalone `zts_rpc` via `Ctx.withEnv`" {
    const WindowPlugin = struct {
        pub const rpc_prefix = "plugin:window|";

        pub fn set_title(ctx: *rpc.Ctx, args: struct {
            window: core.WindowId,
            title: []const u8,
        }) (core.HostError || error{MissingContext})!void {
            const call = try ctx.requireEnv(core.CallContext);
            try call.host.setWindowTitle(args.window, args.title);
        }
    };

    const DesktopRpc = rpc.Schema(.{ .window = WindowPlugin });
    var router = DesktopRpc.bind(.{});
    const handler = router.handler();

    var spy = core.RecordingHost.init(std.testing.allocator);
    defer spy.deinit();
    const win_id = try spy.host().createWindow(.{ .title = "Initial" });

    var req_buf: [128]u8 = undefined;
    const req_json = try std.fmt.bufPrint(&req_buf, "{{\"window\":{d},\"title\":\"Updated via CallContext!\"}}", .{win_id.toU53()});

    const call_ctx: core.CallContext = .{ .host = spy.host(), .window_id = win_id };
    var ctx = rpc.Ctx.init(std.testing.io, std.testing.failing_allocator).withEnv(&call_ctx);

    var resp = handler.dispatch(std.testing.failing_allocator, &ctx, "plugin:window|set_title", req_json);
    defer resp.deinit();

    try std.testing.expectEqual(core.IpcStatus.ok, resp.status);
    try std.testing.expectEqualStrings("Updated via CallContext!", spy.windows.get(win_id).?.title);
}

test {
    _ = foundation;
    _ = web;
    _ = core;
    _ = rpc;
}
