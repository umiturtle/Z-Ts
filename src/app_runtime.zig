//! High-Level Desktop & Headless Integration Runtime (`src/app_runtime.zig`).
//!
//! Wires together:
//! - `zts_webview.Engine` (`LinuxGtkBackend`, `HeadlessMock`, future macOS/Windows backends)
//! - `WebviewHost` (`zts_core.Host` VTable implementation)
//! - `zts_tauri.ProtocolRouter` (`tauri://`, `ipc://`, `asset://`, and `postMessage` fallback)
//! - `zts_tauri.js_bootstrap` (`AT_DOCUMENT_START` injection of `window.__TAURI_INTERNALS__`)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const web = @import("zts_web");
const rpc = @import("zts_rpc");
const webview = @import("zts_webview");
const tauri = @import("zts_tauri");
const webview_host = @import("webview_host.zig");

/// Everything `DesktopRuntime.init()` needs: which backend to build, the app identity, the embedded
/// asset bundle, and the protocol knobs. `.{}` is a runnable app (headless-capable, no assets).
pub const DesktopConfig = struct {
    /// Which WebView engine to create.
    backend: webview.BackendKind = .auto,
    /// Identity reported by `plugin:app`.
    app: tauri.AppConfig = .{},
    /// Base directories used by `plugin:path`.
    paths: tauri.PathState = .{},
    /// Frontend to serve over `asset://`.
    assets: ?*const web.Assets = null,
    /// CSP applied to served HTML.
    csp: ?[]const u8 = null,
    /// Extra globs the `asset://` route may serve.
    asset_allow_globs: []const []const u8 = &.{},
    /// Origins allowed to call IPC on top of the defaults.
    extra_allowed_origins: []const []const u8 = &.{},
    /// Fixed invoke key (tests / embedded hosts); random when `null`.
    invoke_key_override: ?[]const u8 = null,
    /// `app.security.pattern: "isolation"` key. `null` = brownfield (plaintext IPC bodies).
    /// Build it with `tauri.isolation.keyFor(app.identifier, pattern.isolation.key_hex)`.
    isolation_key: ?tauri.IsolationKey = null,
    /// Asset path prefix backing `isolation://localhost/`.
    isolation_asset_prefix: []const u8 = "/isolation/",
};

fn noopRpcDispatch(
    _: ?*anyopaque,
    _: Allocator,
    _: *rpc.Ctx,
    _: []const u8,
    _: []const u8,
) core.OutgoingResponse {
    return rpc.Responses.unknown_command;
}

/// The whole desktop app in one struct: a WebView engine, the Tauri protocol router, the plugin
/// registry and the per-window state. `run()` is `init` → `step` loop → `deinit`; tests can drive
/// `step(.poll)` by hand against `HeadlessMock` and never touch a window.
pub const DesktopRuntime = struct {
    /// Allocator that owns the runtime and everything it creates.
    allocator: Allocator,
    /// IO reactor shared by the engine, the plugins and the router.
    io: Io,
    /// The WebView engine (native or headless).
    engine: webview.Engine,
    /// Bridges `zts_core.Host` onto the engine.
    host_adapter: webview_host.WebviewHost,
    /// State of every core plugin (`window`, `menu`, `fs`, …).
    plugins: *tauri.CorePluginStates,
    /// Backing buffer for `invoke_key`, so the key never moves.
    invoke_key_storage: [64]u8,
    /// Secret that every `ipc://` request must present.
    invoke_key: []const u8,
    /// Serves `tauri://` / `ipc://` / `asset://` and owns the RPC handler.
    router: tauri.ProtocolRouter,

    /// Builds the engine, plugins and router, and wires the callbacks between them.
    pub fn create(allocator: Allocator, io: Io, cfg: DesktopConfig) !*DesktopRuntime {
        const self = try allocator.create(DesktopRuntime);
        errdefer allocator.destroy(self);

        var eng = try webview.Engine.init(allocator, io, cfg.backend);
        errdefer eng.deinit();

        const plugins = try tauri.CorePluginStates.create(allocator, io, cfg.app, cfg.paths);
        errdefer plugins.destroy();

        const key_buf = tauri.ProtocolRouter.generateInvokeKeyHex(io);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .engine = eng,
            .host_adapter = undefined,
            .plugins = plugins,
            .invoke_key_storage = key_buf,
            .invoke_key = &.{},
            .router = undefined,
        };
        self.host_adapter = webview_host.WebviewHost.init(&self.engine);
        self.invoke_key = cfg.invoke_key_override orelse self.invoke_key_storage[0..];
        // JS-created windows must receive the same per-label bootstrap as startup windows, so
        // commands go through `DesktopRuntime.openWindow` instead of the bare Host vtable.
        _ = self.plugins.windows.withWindowFactory(self, onOpenWindow);
        self.router = tauri.ProtocolRouter.init(allocator, io, .{
            .invoke_key = self.invoke_key,
            .assets = cfg.assets,
            .inject_bootstrap_into_html = false,
            .csp = cfg.csp,
            .asset_root_dir = cfg.paths.resource_dir,
            .asset_allow_globs = cfg.asset_allow_globs,
            .extra_allowed_origins = cfg.extra_allowed_origins,
            .isolation_key = cfg.isolation_key,
            .isolation_asset_prefix = cfg.isolation_asset_prefix,
        }, .{ .userdata = null, .dispatchFn = noopRpcDispatch });

        const scheme_handler: webview.SchemeHandler = .{
            .userdata = self,
            .onRequest = onSchemeRequest,
        };
        try self.engine.registerScheme("tauri", scheme_handler);
        try self.engine.registerScheme("ipc", scheme_handler);
        try self.engine.registerScheme("asset", scheme_handler);
        try self.engine.registerScheme("isolation", scheme_handler);
        self.engine.setMessageHandler(.{ .userdata = self, .onMessage = onJsMessage });
        self.engine.setCloseHandler(.{ .userdata = self, .onClose = onWindowClosed });

        return self;
    }

    /// Detaches callbacks, then tears the engine and plugins down in order.
    pub fn destroy(self: *DesktopRuntime) void {
        const alloc = self.allocator;
        // Detach callbacks BEFORE destroying GTK/OS windows so synchronous GObject `"destroy"`
        // signals emitted inside `engine.deinit()` never touch torn-down plugin registries!
        self.engine.setCloseHandler(null);
        self.engine.setMessageHandler(null);
        self.engine.deinit();
        self.plugins.destroy();
        alloc.destroy(self);
    }

    /// Installs the RPC handler the router calls for `ipc://` requests.
    pub inline fn setRpcHandler(self: *DesktopRuntime, handler: rpc.Handler) void {
        self.router.rpc_handler = handler;
    }

    /// The `core.Host` plugins use to reach the window backend.
    pub inline fn host(self: *DesktopRuntime) core.Host {
        return self.host_adapter.host();
    }

    /// Creates a window, injects `window.__TAURI_INTERNALS__` at `AT_DOCUMENT_START` with the
    /// window's exact `label` and `invoke_key`, registers it in `WindowRegistry`, and navigates to `initial_url`.
    pub fn openWindow(self: *DesktopRuntime, spec: core.WindowSpec) !core.WindowId {
        var iso_hex_buf: [64]u8 = undefined;
        const iso_hex: []const u8 = if (self.router.config.isolation_key) |key| blk: {
            iso_hex_buf = tauri.isolation.keyHex(key);
            break :blk &iso_hex_buf;
        } else "";
        const boot_js = try tauri.js_bootstrap.renderScriptAlloc(self.allocator, .{
            .label = spec.label,
            .invoke_key = self.invoke_key,
            .isolation_key_hex = iso_hex,
        });
        defer self.allocator.free(boot_js);

        const scripts = [_][]const u8{boot_js};
        const win_id = try self.engine.createWindow(.{
            .title = spec.title,
            .size = spec.size,
            .min_size = spec.min_size,
            .max_size = spec.max_size,
            .position = spec.position,
            .resizable = spec.resizable,
            .decorations = spec.decorations,
            .transparent = spec.transparent,
            .always_on_top = spec.always_on_top,
            .visible = spec.visible,
            .fullscreen = spec.fullscreen,
            .devtools = spec.devtools,
            .background_color = spec.background_color,
            .initial_url = spec.initial_url,
            .center = spec.center,
            .maximized = spec.maximized,
            .skip_taskbar = spec.skip_taskbar,
            .always_on_bottom = spec.always_on_bottom,
            .focus = spec.focus,
            .content_protected = spec.content_protected,
            .drag_drop_enabled = spec.drag_drop_enabled,
            .zoom_hotkeys_enabled = spec.zoom_hotkeys_enabled,
            .hidden_title = spec.hidden_title,
            .title_bar_style = spec.title_bar_style,
            .user_agent = spec.user_agent,
            .tabbing_identifier = spec.tabbing_identifier,
            .visible_on_all_workspaces = spec.visible_on_all_workspaces,
            .window_effects_json = spec.window_effects_json,
            .init_scripts = &scripts,
        });
        try self.plugins.windows.registerWindow(win_id, spec);
        return win_id;
    }

    /// Pumps one turn of the event loop; `false` once the app asked to quit.
    pub inline fn step(self: *DesktopRuntime, mode: webview.StepMode) bool {
        return self.engine.step(mode);
    }

    /// Runs the loop until the app quits.
    pub fn run(self: *DesktopRuntime) void {
        while (self.engine.step(.blocking)) {}
    }

    fn onWindowClosed(ud: ?*anyopaque, win_id: webview.WindowId) void {
        const self: *DesktopRuntime = @ptrCast(@alignCast(ud.?));
        self.plugins.webviews.unregisterWindow(win_id);
        self.plugins.windows.unregisterWindow(win_id);
    }

    /// `WindowRegistry` factory used by `plugin:window|create` / `create_webview_window`.
    fn onOpenWindow(ud: ?*anyopaque, spec: core.WindowSpec) core.HostError!core.WindowId {
        const self: *DesktopRuntime = @ptrCast(@alignCast(ud.?));
        return self.openWindow(spec) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.PlatformFailure,
        };
    }

    fn onSchemeRequest(ud: ?*anyopaque, req: webview.SchemeRequest) void {
        const self: *DesktopRuntime = @ptrCast(@alignCast(ud.?));

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const hdrs = scratch.alloc(tauri.HeaderPair, req.headers.len) catch {
            self.engine.completeRequest(req.request_id, .{ .status_code = 500, .body = .empty }) catch {};
            return;
        };
        for (req.headers, 0..) |h, i| {
            hdrs[i] = .{ .name = h.name, .value = h.value };
        }

        var routed = self.router.handleRequest(self.host(), .{
            .window_id = req.window_id,
            .method = req.method,
            .uri = req.uri,
            .headers = hdrs,
            .body = req.body,
        });

        const out_pairs = routed.intoHeaderSlice(scratch) catch {
            routed.body.deinit();
            self.engine.completeRequest(req.request_id, .{ .status_code = 500, .body = .empty }) catch {};
            return;
        };
        const wv_hdrs = scratch.alloc(webview.HeaderPair, out_pairs.len) catch {
            routed.body.deinit();
            self.engine.completeRequest(req.request_id, .{ .status_code = 500, .body = .empty }) catch {};
            return;
        };
        for (out_pairs, 0..) |p, i| {
            wv_hdrs[i] = .{ .name = p.name, .value = p.value };
        }

        const moved_body = routed.body;
        routed.body = .empty;
        self.engine.completeRequest(req.request_id, .{
            .status_code = routed.status_code,
            .content_type = routed.content_type,
            .extra_headers = wv_hdrs,
            .body = moved_body,
        }) catch {};
    }

    fn onJsMessage(ud: ?*anyopaque, win_id: webview.WindowId, message: []const u8) void {
        const self: *DesktopRuntime = @ptrCast(@alignCast(ud.?));
        self.router.handlePostMessage(self.host(), win_id, message);
    }
};

test "DesktopRuntime + HeadlessMock runs end-to-end Tauri v2 custom commands, Channel<T>, and core plugins" {
    const FrameTick = struct {
        frame: u32,
        fps: f64,
    };

    const UserCmds = struct {
        pub fn stream_frames(ctx: *rpc.Ctx, args: struct { count: u32, on_tick: tauri.Channel(FrameTick) }) !u32 {
            var ch = args.on_tick;
            var i: u32 = 0;
            while (i < args.count) : (i += 1) {
                try ch.sendCtx(ctx, .{ .frame = i, .fps = 60.0 });
            }
            try ch.closeCtx(ctx);
            return args.count;
        }
    };

    const FullSchema = tauri.withCorePlugins(rpc.Schema(.{ .main_app = UserCmds }));
    const assets: web.Assets = .{
        .entries = &.{
            .{ .path = "/index.html", .bytes = "<!doctype html><h1>Z-Ts</h1>" },
        },
    };

    const rt = try DesktopRuntime.create(testing.allocator, testing.io, .{
        .backend = .headless_mock,
        .app = .{ .name = "VN Engine", .version = "1.2.3", .identifier = "jp.zts.vn" },
        .assets = &assets,
    });
    defer rt.destroy();

    var bound = FullSchema.bind(.{
        .tauri_window = &rt.plugins.windows,
        .tauri_webview = &rt.plugins.webviews,
        .tauri_event = &rt.plugins.events,
        .tauri_path = &rt.plugins.paths,
        .tauri_app = &rt.plugins.app_state,
        .tauri_resources = &rt.plugins.resources,
        .tauri_menu = &rt.plugins.menu_state,
        .tauri_tray = &rt.plugins.tray_state,
    });
    rt.setRpcHandler(bound.handler());

    const win_id = try rt.openWindow(.{
        .label = "main",
        .title = "Initial Title",
        .size = .wh(1280, 720),
    });

    const mock = rt.engine.headless_mock;
    const auth_hdrs = [_]webview.HeaderPair{
        .{ .name = "Tauri-Invoke-Key", .value = rt.invoke_key },
        .{ .name = "Origin", .value = "tauri://localhost" },
    };

    // 1. Update window title via percent-encoded `ipc://localhost/plugin%3Awindow%7Cset_title`
    _ = try mock.simulateSchemeRequest(
        win_id,
        "POST",
        "ipc://localhost/plugin%3Awindow%7Cset_title",
        &auth_hdrs,
        "{\"label\":\"main\",\"value\":\"Chapter 1: Dawn\"}",
    );
    _ = rt.step(.poll);
    try testing.expectEqual(@as(u16, 200), mock.completed_records.items[0].status_code);
    try testing.expectEqualStrings("Chapter 1: Dawn", mock.windows.getPtr(win_id).?.title);

    // 2. Stream 3 frames over `Channel<FrameTick>` (`"__CHANNEL__:777"`)
    const evals_before = mock.windows.getPtr(win_id).?.evaluated_scripts.items.len;
    _ = try mock.simulateSchemeRequest(
        win_id,
        "POST",
        "ipc://localhost/streamFrames",
        &auth_hdrs,
        "{\"count\":3,\"onTick\":\"__CHANNEL__:777\"}",
    );
    _ = rt.step(.poll);
    try testing.expectEqual(@as(u16, 200), mock.completed_records.items[1].status_code);
    try testing.expectEqualStrings("3", mock.completed_records.items[1].body);
    // 3 indexed message frames + 1 end marker = 4 `evalJs` dispatches!
    try testing.expectEqual(evals_before + 4, mock.windows.getPtr(win_id).?.evaluated_scripts.items.len);
}

test "P0-1: JS WebviewWindow creation goes through the runtime factory and injects its own bootstrap" {
    const rt = try DesktopRuntime.create(testing.allocator, testing.io, .{ .backend = .headless_mock });
    defer rt.destroy();

    var bound = tauri.CorePluginsSchema.bind(.{
        .tauri_window = &rt.plugins.windows,
        .tauri_webview = &rt.plugins.webviews,
        .tauri_event = &rt.plugins.events,
        .tauri_path = &rt.plugins.paths,
        .tauri_app = &rt.plugins.app_state,
        .tauri_resources = &rt.plugins.resources,
        .tauri_menu = &rt.plugins.menu_state,
        .tauri_tray = &rt.plugins.tray_state,
    });
    rt.setRpcHandler(bound.handler());
    const main = try rt.openWindow(.{ .label = "main" });
    const mock = rt.engine.headless_mock;
    const auth_hdrs = [_]webview.HeaderPair{
        .{ .name = "Tauri-Invoke-Key", .value = rt.invoke_key },
    };

    // `new WebviewWindow('settings', { width: 640, height: 480, url: 'settings.html' })`
    _ = try mock.simulateSchemeRequest(main, "POST", "ipc://localhost/plugin%3Awebview%7Ccreate_webview_window", &auth_hdrs,
        \\{"options":{"label":"settings","width":640,"height":480,"url":"settings.html"}}
    );
    _ = rt.step(.poll);
    try testing.expectEqual(@as(u16, 200), mock.completed_records.items[0].status_code);
    try testing.expectEqual(@as(usize, 2), rt.plugins.windows.entries.items.len);

    // The second window really exists in the engine and got a bootstrap with ITS OWN label.
    const second = rt.plugins.windows.resolveId("settings", core.WindowId.invalid).?;
    const mock_window = mock.windows.getPtr(second).?;
    try testing.expect(mock_window.init_scripts.items.len > 0);
    const boot = mock_window.init_scripts.items[0];
    try testing.expect(std.mem.indexOf(u8, boot, "LABEL=\"settings\"") != null);
    try testing.expect(std.mem.indexOf(u8, boot, "LABEL=\"main\"") == null);
    try testing.expectEqualStrings("tauri://localhost/settings.html", mock_window.current_url);

    // getAllWebviews() reports both the startup window and the JS-created one.
    _ = try mock.simulateSchemeRequest(main, "POST", "ipc://localhost/plugin%3Awebview%7Cget_all_webviews", &auth_hdrs, "{}");
    _ = rt.step(.poll);
    const list = mock.completed_records.items[1].body;
    try testing.expect(std.mem.indexOf(u8, list, "{\"label\":\"main\",\"windowLabel\":\"main\"}") != null);
    try testing.expect(std.mem.indexOf(u8, list, "{\"label\":\"settings\",\"windowLabel\":\"settings\"}") != null);
}
