//! One bundle for every provider an application may need. It lives in `zts_tauri` (Pure Zig),
//! so both `z_ts` (`DesktopRuntime`) and `zts_tauri_native` can name the same type without adding
//! a dependency between them. `DesktopRuntime.create()` applies it in one place; the app can
//! obtain a fully populated bundle with a single `zts_tauri_native.providers()` call.

const std = @import("std");
const Allocator = std.mem.Allocator;

const path = @import("path.zig");
const monitor = @import("monitor.zig");
const menu = @import("menu/mod.zig");
const tray = @import("tray/mod.zig");
const dialog = @import("dialog/mod.zig");
const clipboard = @import("clipboard/mod.zig");
const plugins = @import("plugins.zig");

/// Everything that used to require scattered wiring. Every field is optional: a `null` keeps the
/// deterministic / fail-closed default so headless tests, CI and browsers behave identically.
pub const RuntimeProviders = struct {
    /// Real user directories; `null` lets `detectPath` build them from the environment.
    path: ?path.PathState = null,
    /// Live monitor / cursor source; `null` keeps the deterministic single 1920x1080 display.
    monitor: ?monitor.Provider = null,
    /// Native menu backend.
    menu: ?menu.Backend = null,
    /// Native tray backend.
    tray: ?tray.Backend = null,
    /// Native file-dialog backend.
    dialog: ?dialog.Backend = null,
    /// Native clipboard backend.
    clipboard: ?clipboard.Backend = null,
    /// Returns this process id (stale-lock recovery).
    current_pid: ?*const fn () u32 = null,
    /// Whether a pid is still alive. `null` = fail-closed, keep the lock.
    process_alive: ?*const fn (u32, ?*anyopaque) bool = null,
    /// Opaque pointer for `process_alive`.
    process_alive_ctx: ?*anyopaque = null,
    /// Store autosave override.
    autosave: ?bool = null,
    /// Where startup restore diagnostics are recorded.
    restore_diagnostics: ?*plugins.RestoreDiagnostics = null,

    /// Fills in `path` from the real environment exactly once. A missing `environ` map leaves the
    /// deterministic defaults, which keeps headless/CI builds reproducible.
    pub fn detectPath(
        self: *RuntimeProviders,
        allocator: Allocator,
        environ: ?*const std.process.Environ.Map,
        exe_dir: ?[]const u8,
        cwd: ?[]const u8,
        identifier: []const u8,
    ) Allocator.Error!void {
        if (self.path != null) return;
        self.path = try path.PathState.fromEnvironment(allocator, identifier, .{
            .environ = environ,
            .exe_dir = exe_dir,
            .cwd = cwd,
        });
    }

    /// Applies the P2-relevant fields to `PluginState.Options` in one call.
    pub fn applyToPluginOptions(self: RuntimeProviders, options: *plugins.Options) void {
        if (self.current_pid) |f| options.current_pid = f;
        if (self.process_alive) |f| {
            options.process_alive = f;
            options.process_alive_ctx = self.process_alive_ctx;
        }
        if (self.autosave) |value| options.autosave = value;
        if (self.restore_diagnostics) |d| options.restore_diagnostics = d;
    }
};

test "M6-04: detectPath reads the real environment and applyToPluginOptions fills one call" {
    const testing = std.testing;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/alice");
    try env.put("XDG_CONFIG_HOME", "/home/alice/cfg");
    try env.put("XDG_CACHE_HOME", "/home/alice/cache");

    var bundle: RuntimeProviders = .{};
    try bundle.detectPath(testing.allocator, &env, "/opt/app/bin", "/work", "com.example.app");
    defer bundle.path.?.deinit(testing.allocator);

    const state = bundle.path.?;
    try testing.expect(!state.auto_detect);
    try testing.expectEqualStrings("com.example.app", state.app_identifier);
    try testing.expectEqualStrings("/home/alice", state.home_dir);
    try testing.expectEqualStrings("/home/alice/cfg", state.config_dir.?);
    try testing.expectEqualStrings("/home/alice/cache", state.cache_dir.?);
    try testing.expectEqualStrings("/opt/app/bin", state.executable_dir);
    try testing.expectEqualStrings("/work", state.cwd);
    try testing.expect(state.owned_strings.len > 0);

    // A second call is a no-op, and a missing environ keeps the deterministic fallback.
    try bundle.detectPath(testing.allocator, null, null, null, "com.example.app");
    var fallback: RuntimeProviders = .{};
    try fallback.detectPath(testing.allocator, null, null, null, "com.example.app");
    defer fallback.path.?.deinit(testing.allocator);
    try testing.expectEqualStrings("/home/user", fallback.path.?.home_dir);

    const Helpers = struct {
        fn pid() u32 {
            return 111;
        }
        fn alive(process_id: u32, _: ?*anyopaque) bool {
            return process_id == 111;
        }
    };
    var diagnostics = plugins.RestoreDiagnostics{};
    bundle.current_pid = Helpers.pid;
    bundle.process_alive = Helpers.alive;
    bundle.autosave = false;
    bundle.restore_diagnostics = &diagnostics;
    var options: plugins.Options = .{};
    bundle.applyToPluginOptions(&options);
    try testing.expectEqual(false, options.autosave);
    try testing.expect(options.current_pid != null);
    try testing.expect(options.process_alive != null);
    try testing.expectEqual(@as(?*plugins.RestoreDiagnostics, &diagnostics), options.restore_diagnostics);
}
