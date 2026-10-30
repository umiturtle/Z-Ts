//! `plugin:app|*` Metadata & Lifecycle Commands (`src/tauri/app.zig`).
//!
//! Wire-compatible with `@tauri-apps/api/app` (`vendor/tauri/packages/api/src/app.ts`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");

/// Application-level theme, as returned by `app.theme()` and accepted by `app.setTheme()`.
/// `null` in `AppState.theme` means "follow the OS", which is the Tauri default.
pub const Theme = enum {
    /// Force the light palette.
    light,
    /// Force the dark palette.
    dark,
};

/// Identity of the running app, surfaced to `@tauri-apps/api/app` (`getName()`, `getVersion()`,
/// `getIdentifier()`, `getTauriVersion()`). These values are only ever read back — nothing in the
/// engine keys behaviour off them.
pub const AppConfig = struct {
    /// `app.getName()`.
    name: []const u8 = "z-ts-app",
    /// `app.getVersion()`.
    version: []const u8 = "0.1.0",
    /// `app.getIdentifier()` — the reverse-DNS bundle id.
    identifier: []const u8 = "com.zts.app",
    /// `app.getTauriVersion()` — the Tauri version this API surface mirrors.
    tauri_version: []const u8 = "2.12.4",
    /// `app.getBundleType()` (`deb`, `app`, …); `null` in development.
    bundle_type: ?[]const u8 = null,
    /// `app.supportsMultipleWindows()`.
    supports_multiple_windows: bool = true,
};

/// Mutable application state behind `plugin:app` / `plugin:webview` / `plugin:window`-independent
/// calls. Every mutation takes `mu`, because commands can be dispatched from the event loop while a
/// worker thread reads.
pub const AppState = struct {
    /// IO reactor used by `mu`.
    io: Io,
    /// Guards every field below; commands may arrive on any thread.
    mu: Io.Mutex = .init,
    /// Identity reported by the `plugin:app` getters.
    config: AppConfig = .{},
    /// Forced theme, or `null` to follow the OS.
    theme: ?Theme = null,
    /// macOS dock visibility (recorded; the host applies it).
    dock_visible: bool = true,
    /// Whether the app is shown (`app.show()` / `app.hide()`).
    app_visible: bool = true,
    /// Code passed to `app.exit()`, for the test loop to assert on.
    last_exit_code: ?i32 = null,

    /// Creates state with `config` and the default theme (follow the OS).
    pub fn init(io: Io, config: AppConfig) AppState {
        return .{ .io = io, .config = config };
    }
};

/// `plugin:app|*` RPC command namespace (`Schema` key: `.app`).
pub const Commands = struct {
    /// Every command in this namespace starts with this prefix.
    pub const rpc_prefix = "plugin:app|";
    /// The state type `zts_rpc` resolves per app; identical to `AppState` here.
    pub const RpcState = AppState;

    /// `plugin:app|version` — the app version string.
    pub fn version(state: *AppState) []const u8 {
        return state.config.version;
    }

    /// `plugin:app|name` — the app name.
    pub fn name(state: *AppState) []const u8 {
        return state.config.name;
    }

    /// `plugin:app|tauri_version` — the Tauri version this build mirrors.
    pub fn tauri_version(state: *AppState) []const u8 {
        return state.config.tauri_version;
    }

    /// `plugin:app|identifier` — the bundle identifier.
    pub fn identifier(state: *AppState) []const u8 {
        return state.config.identifier;
    }

    /// `plugin:app|bundle_type` — the active bundle format, or `null`.
    pub fn bundle_type(state: *AppState) ?[]const u8 {
        if (state.config.bundle_type) |b| return b;
        return switch (builtin.os.tag) {
            .macos => "app",
            .windows => "nsis",
            else => "appimage",
        };
    }

    /// `plugin:app|supports_multiple_windows` — always `true` here.
    pub fn supports_multiple_windows(state: *AppState) bool {
        return state.config.supports_multiple_windows;
    }

    /// `plugin:app|default_window_icon` — `null`: no app icon resource is registered.
    pub fn default_window_icon(_: *AppState) ?u53 {
        return null;
    }

    /// `plugin:app|set_app_theme` — forces light/dark, or `null` to follow the OS.
    pub fn set_app_theme(state: *AppState, args: struct { theme: ?Theme = null }) void {
        state.mu.lockUncancelable(state.io);
        defer state.mu.unlock(state.io);
        state.theme = args.theme;
    }

    /// `plugin:app|app_show` — marks the app visible.
    pub fn app_show(state: *AppState) void {
        state.mu.lockUncancelable(state.io);
        defer state.mu.unlock(state.io);
        state.app_visible = true;
    }

    /// `plugin:app|app_hide` — marks the app hidden.
    pub fn app_hide(state: *AppState) void {
        state.mu.lockUncancelable(state.io);
        defer state.mu.unlock(state.io);
        state.app_visible = false;
    }

    /// `plugin:app|set_dock_visibility` — macOS dock show/hide.
    pub fn set_dock_visibility(state: *AppState, args: struct { visible: bool }) void {
        state.mu.lockUncancelable(state.io);
        defer state.mu.unlock(state.io);
        state.dock_visible = args.visible;
    }

    /// `plugin:app|fetch_data_store_identifiers` — always empty: Z-Ts keeps no data stores.
    pub fn fetch_data_store_identifiers(_: *AppState) []const [16]u8 {
        return &.{};
    }

    /// `plugin:app|remove_data_store` — accepted and ignored.
    pub fn remove_data_store(_: *AppState, _: struct { uuid: [16]u8 }) void {}

    /// `plugin:app|exit` — records the code and asks the host to quit.
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
