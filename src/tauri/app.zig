//! `plugin:app|*` Metadata & Lifecycle Commands (`src/tauri/app.zig`).
//!
//! Wire-compatible with `@tauri-apps/api/app` (`vendor/tauri/packages/api/src/app.ts`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");

pub const Theme = enum {
    light,
    dark,
};

pub const AppConfig = struct {
    name: []const u8 = "z-ts-app",
    version: []const u8 = "0.1.0",
    identifier: []const u8 = "com.zts.app",
    tauri_version: []const u8 = "2.12.4",
    bundle_type: ?[]const u8 = null,
    supports_multiple_windows: bool = true,
};

pub const AppState = struct {
    io: Io,
    mu: Io.Mutex = .init,
    config: AppConfig = .{},
    theme: ?Theme = null,
    dock_visible: bool = true,
    app_visible: bool = true,
    last_exit_code: ?i32 = null,

    pub fn init(io: Io, config: AppConfig) AppState {
        return .{ .io = io, .config = config };
    }
};

/// `plugin:app|*` RPC command namespace (`Schema` key: `.app`).
pub const Commands = struct {
    pub const rpc_prefix = "plugin:app|";
    pub const RpcState = AppState;

    pub fn version(state: *AppState) []const u8 {
        return state.config.version;
    }

    pub fn name(state: *AppState) []const u8 {
        return state.config.name;
    }

    pub fn tauri_version(state: *AppState) []const u8 {
        return state.config.tauri_version;
    }

    pub fn identifier(state: *AppState) []const u8 {
        return state.config.identifier;
    }

    pub fn bundle_type(state: *AppState) ?[]const u8 {
        if (state.config.bundle_type) |b| return b;
        return switch (builtin.os.tag) {
            .macos => "app",
            .windows => "nsis",
            else => "appimage",
        };
    }

    pub fn supports_multiple_windows(state: *AppState) bool {
        return state.config.supports_multiple_windows;
    }

    pub fn default_window_icon(_: *AppState) ?u53 {
        return null;
    }

    pub fn set_app_theme(state: *AppState, args: struct { theme: ?Theme = null }) void {
        state.mu.lockUncancelable(state.io);
        defer state.mu.unlock(state.io);
        state.theme = args.theme;
    }

    pub fn app_show(state: *AppState) void {
        state.mu.lockUncancelable(state.io);
        defer state.mu.unlock(state.io);
        state.app_visible = true;
    }

    pub fn app_hide(state: *AppState) void {
        state.mu.lockUncancelable(state.io);
        defer state.mu.unlock(state.io);
        state.app_visible = false;
    }

    pub fn set_dock_visibility(state: *AppState, args: struct { visible: bool }) void {
        state.mu.lockUncancelable(state.io);
        defer state.mu.unlock(state.io);
        state.dock_visible = args.visible;
    }

    pub fn fetch_data_store_identifiers(_: *AppState) []const [16]u8 {
        return &.{};
    }

    pub fn remove_data_store(_: *AppState, _: struct { uuid: [16]u8 }) void {}

    pub fn exit(ctx: *rpc.Ctx, state: *AppState, args: struct { code: i32 = 0 }) void {
        state.mu.lockUncancelable(state.io);
        state.last_exit_code = args.code;
        state.mu.unlock(state.io);

        if (ctx.getEnv(core.CallContext)) |call_ctx| {
            call_ctx.host.requestQuit();
        }
    }
};

test "plugin:app commands report metadata and request host quit on exit" {
    var rec = core.RecordingHost.init(testing.allocator);
    defer rec.deinit();

    var app_state = AppState.init(testing.io, .{
        .name = "Studio Deck",
        .version = "2.4.0",
        .identifier = "io.zts.studio",
    });

    const S = rpc.Schema(.{ .app = Commands });
    var router = S.bind(.{ .app = &app_state });
    const h = router.handler();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var call_ctx: core.CallContext = .{ .host = rec.host() };
    var ctx = rpc.Ctx.init(testing.io, arena.allocator()).withEnv(&call_ctx);

    var v_resp = h.dispatch(arena.allocator(), &ctx, "plugin:app|version", "");
    defer v_resp.deinit();
    try testing.expectEqualStrings("\"2.4.0\"", v_resp.body.slice());

    var ex_resp = h.dispatch(arena.allocator(), &ctx, "plugin:app|exit", "{\"code\":7}");
    defer ex_resp.deinit();
    try testing.expectEqual(@as(?i32, 7), app_state.last_exit_code);
    try testing.expect(rec.quit_requested);
}
