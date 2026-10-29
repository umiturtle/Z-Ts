//! `tauri.conf.json` (Tauri v2) importer — the migration half of `M4-04`.
//!
//! Existing Tauri v2 projects describe themselves in `src-tauri/tauri.conf.json` and
//! `src-tauri/capabilities/*.json`. This module reads those files **without modification** and maps
//! them onto Z-Ts types, so porting an app is:
//!
//! ```zig
//! var imported = try tauri.config_import.load(testing.allocator, io, "src-tauri");
//! defer imported.deinit();
//!
//! const app_cfg = imported.config.toAppConfig();
//! const window_specs = try imported.config.windowSpecs(imported.allocator());
//! ```
//!
//! Design rules (see `docs/architecture/tauri-config-import-acl.md`):
//!
//! 1. **Unknown keys never fail.** Tauri adds config fields every minor release; a migration layer
//!    that rejects them is useless. Unknown keys are reported as [`Diagnostics`] warnings instead.
//! 2. **Wrong types do fail**, with a `field.path` diagnostic (`app.windows[0].width`), because a
//!    silently ignored `width: "800"` produces a窗口 that is wrong in a way nobody can debug.
//! 3. Everything is owned by one arena ([`Config.arena`]), so `deinit` is a single call and the
//!    parsed slices stay valid for as long as the config does (they are handed straight to the
//!    runtime).
//!
//! Only the subset Z-Ts can honour is mapped; the rest is kept as raw JSON (`plugins`, `csp`) so an
//! app can still read it, and reported in `imported.warnings`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const core = @import("zts_core");
const app = @import("app.zig");

pub const Error = error{
    OutOfMemory,
    /// The file is not valid JSON.
    InvalidJson,
    /// A known field had the wrong type (see the `Diagnostics` message).
    InvalidConfig,
};

// ============================================================================
// Diagnostics
// ============================================================================

/// Non-fatal migration notes. Every entry is `path` + human-readable `message`, so a CLI can print
/// `warning: app.windows[0].titleBarStyle: … not supported by Z-Ts` and keep going.
pub const Diagnostics = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged(Item) = .empty,

    pub const Item = struct {
        path: []u8,
        message: []u8,
    };

    pub fn init(allocator: Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.items.items) |item| {
            self.allocator.free(item.path);
            self.allocator.free(item.message);
        }
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *Diagnostics, path: []const u8, message: []const u8) Allocator.Error!void {
        try self.items.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .message = try self.allocator.dupe(u8, message),
        });
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.items.items.len;
    }

    pub fn has(self: *const Diagnostics, path: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.path, path)) return true;
        }
        return false;
    }
};

// ============================================================================
// Model
// ============================================================================

/// `tauri.conf.json` — only the keys Z-Ts acts on, plus raw JSON escape hatches.
pub const Config = struct {
    schema: ?[]const u8 = null,
    product_name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    identifier: []const u8 = "",

    app: App = .{},
    build: Build = .{},
    bundle: Bundle = .{},
    /// `plugins` verbatim (JSON text) — Z-Ts plugin configuration is code, not JSON, so this is
    /// informational only.
    plugins_json: ?[]const u8 = null,

    pub const App = struct {
        windows: []WindowConfig = &.{},
        security: Security = .{},
        with_global_tauri: bool = false,
        tray_icon: ?TrayIcon = null,
        /// `app.macOSPrivateApi` — always reported as unsupported (Z-Ts never links private APIs).
        macos_private_api: bool = false,
    };

    pub const Build = struct {
        dev_url: ?[]const u8 = null,
        frontend_dist: ?[]const u8 = null,
        before_dev_command: ?[]const u8 = null,
        before_build_command: ?[]const u8 = null,
    };

    pub const Bundle = struct {
        active: bool = true,
        targets: []const []const u8 = &.{},
        icon: []const []const u8 = &.{},
    };

    pub const TrayIcon = struct {
        id: ?[]const u8 = null,
        icon_path: ?[]const u8 = null,
        icon_as_template: bool = false,
        menu_on_left_click: bool = false,
        show_menu_on_left_click: bool = false,
        title: ?[]const u8 = null,
        tooltip: ?[]const u8 = null,
    };

    pub const Security = struct {
        /// `security.csp` rendered back to JSON text (`"default-src 'self'"` or an object).
        csp_json: ?[]const u8 = null,
        dev_csp_json: ?[]const u8 = null,
        freeze_prototype: bool = false,
        asset_protocol: AssetProtocol = .{},
        /// `security.capabilities` — either a reference to a capability identifier or an inline
        /// capability object (kept as raw JSON for `acl.zig` to interpret).
        capabilities: []CapabilityEntry = &.{},
        headers_json: ?[]const u8 = null,
    };

    pub const CapabilityEntry = union(enum) {
        /// `"my-capability"` — resolved against `capabilities/*.json` by identifier.
        reference: []const u8,
        /// Inline object — owned JSON, valid for the lifetime of the `Config`
        /// (`inline` is a Zig keyword, hence the `_json` suffix).
        inline_json: std.json.Value,
    };

    pub const AssetProtocol = struct {
        enable: bool = false,
        scope: Scope = .{},
    };

    /// `FsScope`: a single pattern, a list of patterns, or `{ allow, deny, requireLiteralLeadingDot }`.
    pub const Scope = struct {
        allow: []const []const u8 = &.{},
        deny: []const []const u8 = &.{},
        require_literal_leading_dot: bool = true,
    };

    pub const WindowConfig = struct {
        label: []const u8 = "main",
        title: ?[]const u8 = null,
        /// `url` — either a relative path (`"index.html"`), `{"url": "https://…"}` or
        /// `{"app": …}` (Z-Ts only ever serves the embedded app, so `app` maps to `/`).
        url: []const u8 = "",
        width: f64 = 800,
        height: f64 = 600,
        x: ?f64 = null,
        y: ?f64 = null,
        min_width: ?f64 = null,
        min_height: ?f64 = null,
        max_width: ?f64 = null,
        max_height: ?f64 = null,
        resizable: bool = true,
        decorations: bool = true,
        transparent: bool = false,
        always_on_top: bool = false,
        always_on_bottom: bool = false,
        visible: bool = true,
        fullscreen: bool = false,
        maximized: bool = false,
        center: bool = false,
        focus: bool = true,
        skip_taskbar: bool = false,
        devtools: ?bool = null,
        theme: ?[]const u8 = null,
        /// `create: false` windows exist in the config but are created on demand by the app.
        create: bool = true,
        title_bar_style: ?[]const u8 = null,
        hidden_title: bool = false,
        user_agent: ?[]const u8 = null,

        /// Maps onto `zts_core.WindowSpec` (Z-Ts owns the window lifecycle).
        pub fn toWindowSpec(self: WindowConfig) core.WindowSpec {
            return .{
                .label = self.label,
                .title = self.title orelse self.label,
                .size = .wh(self.width, self.height),
                .min_size = if (self.min_width != null and self.min_height != null)
                    .wh(self.min_width.?, self.min_height.?)
                else
                    null,
                .max_size = if (self.max_width != null and self.max_height != null)
                    .wh(self.max_width.?, self.max_height.?)
                else
                    null,
                .position = if (self.x != null and self.y != null)
                    core.LogicalPoint.xy(self.x.?, self.y.?)
                else
                    null,
                .resizable = self.resizable,
                .decorations = self.decorations,
                .transparent = self.transparent,
                .always_on_top = self.always_on_top,
                .visible = self.visible,
                .fullscreen = self.fullscreen,
                .devtools = self.devtools orelse false,
                .theme = themeOf(self.theme),
                .initial_url = self.appUrl(),
            };
        }

        /// The app URL for this window: Tauri serves the frontend under `tauri://localhost/`
        /// (Linux/macOS) and `http://tauri.localhost/` (Windows); Z-Ts keeps the generic form and
        /// rewrites it per OS inside `js_bootstrap`, so the value stays portable.
        pub fn appUrl(self: WindowConfig) []const u8 {
            if (self.url.len == 0) return "tauri://localhost/";
            // Absolute URLs are passed through (dev server / remote content).
            if (std.mem.indexOf(u8, self.url, "://") != null) return self.url;
            return self.url;
        }

        fn themeOf(theme: ?[]const u8) core.WindowTheme {
            const raw = theme orelse return .system;
            if (std.ascii.eqlIgnoreCase(raw, "dark")) return .dark;
            if (std.ascii.eqlIgnoreCase(raw, "light")) return .light;
            return .system;
        }
    };

    /// Maps onto `zts_tauri.app.AppConfig` (`plugin:app|*` answers from it).
    pub fn toAppConfig(self: *const Config) app.AppConfig {
        return .{
            .name = self.product_name orelse (if (self.identifier.len > 0) self.identifier else "z-ts-app"),
            .version = self.version orelse "0.1.0",
            .identifier = if (self.identifier.len > 0) self.identifier else "com.zts.app",
            .bundle_type = if (self.bundle.targets.len > 0) self.bundle.targets[0] else null,
            .supports_multiple_windows = self.app.windows.len > 1,
        };
    }

    /// One `WindowSpec` per `create != false` entry of `app.windows`.
    pub fn windowSpecs(self: *const Config, allocator: Allocator) Allocator.Error![]core.WindowSpec {
        var out: std.ArrayListUnmanaged(core.WindowSpec) = .empty;
        errdefer out.deinit(allocator);
        for (self.app.windows) |window| {
            if (!window.create) continue;
            try out.append(allocator, window.toWindowSpec());
        }
        return out.toOwnedSlice(allocator);
    }

    /// `app.windows[]` label, looked up like upstream (`WindowConfig::label`).
    pub fn windowByLabel(self: *const Config, label: []const u8) ?WindowConfig {
        for (self.app.windows) |window| {
            if (std.mem.eql(u8, window.label, label)) return window;
        }
        return null;
    }
};

/// A `Config` plus the arena that owns every string it points at.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *const Parsed) Allocator {
        return self.arena.allocator();
    }

    pub fn windowSpecs(self: *const Parsed, out_allocator: Allocator) Allocator.Error![]core.WindowSpec {
        return self.config.windowSpecs(out_allocator);
    }
};

/// `src-tauri/` as a whole: the parsed config, the capability files, and migration warnings.
pub const Imported = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,
    /// Capability files found under `<dir>/capabilities/*.json`, with their file name (for
    /// diagnostics). Interpretation lives in `acl.zig`.
    capabilities: []CapabilityFile = &.{},
    warnings: Diagnostics,

    pub const CapabilityFile = struct {
        /// `"main"` for `capabilities/main.json` (used when a capability has no identifier).
        file_name: []const u8,
        json: []const u8,
    };

    pub fn deinit(self: *Imported) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *const Imported) Allocator {
        return self.arena.allocator();
    }

    pub fn windowSpecs(self: *const Imported, out_allocator: Allocator) Allocator.Error![]core.WindowSpec {
        return self.config.windowSpecs(out_allocator);
    }
};

// ============================================================================
// Parsing
// ============================================================================

const Parser = struct {
    allocator: Allocator,
    diags: *Diagnostics,

    fn note(self: *Parser, path: []const u8, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);
        self.diags.add(path, message) catch {};
    }

    fn fail(self: *Parser, path: []const u8, comptime fmt: []const u8, args: anytype) Error {
        self.note(path, fmt, args);
        return error.InvalidConfig;
    }

    fn string(self: *Parser, path: []const u8, value: std.json.Value) Error![]const u8 {
        return switch (value) {
            .string => |s| self.allocator.dupe(u8, s),
            else => self.fail(path, "expected a string, found {s}", .{@tagName(value)}),
        };
    }

    fn optString(self: *Parser, path: []const u8, value: ?std.json.Value) Error!?[]const u8 {
        const v = value orelse return null;
        if (v == .null) return null;
        return try self.string(path, v);
    }

    fn flag(self: *Parser, path: []const u8, value: std.json.Value) Error!bool {
        return switch (value) {
            .bool => |b| b,
            else => self.fail(path, "expected a boolean, found {s}", .{@tagName(value)}),
        };
    }

    fn optBool(self: *Parser, path: []const u8, value: ?std.json.Value) Error!?bool {
        const v = value orelse return null;
        if (v == .null) return null;
        return try self.flag(path, v);
    }

    fn number(self: *Parser, path: []const u8, value: std.json.Value) Error!f64 {
        return switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => self.fail(path, "expected a number, found {s}", .{@tagName(value)}),
        };
    }

    fn optNumber(self: *Parser, path: []const u8, value: ?std.json.Value) Error!?f64 {
        const v = value orelse return null;
        if (v == .null) return null;
        return try self.number(path, v);
    }

    fn stringArray(self: *Parser, path: []const u8, value: std.json.Value) Error![]const []const u8 {
        switch (value) {
            .array => |array| {
                var out = try self.allocator.alloc([]const u8, array.items.len);
                for (array.items, 0..) |item, i| {
                    const item_path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ path, i });
                    defer self.allocator.free(item_path);
                    out[i] = try self.string(item_path, item);
                }
                return out;
            },
            else => return self.fail(path, "expected an array of strings, found {s}", .{@tagName(value)}),
        }
    }

    fn joinPath(self: *Parser, parent: []const u8, key: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ parent, key });
    }

    fn freePath(self: *Parser, path: []const u8) void {
        self.allocator.free(path);
    }
};

/// `beforeDevCommand` / `frontendDist` accept either a string or an object; take the string out.
fn scalarOrObjectString(parser: *Parser, path: []const u8, value: std.json.Value) Error!?[]const u8 {
    switch (value) {
        .string => |s| return try parser.allocator.dupe(u8, s),
        .object => |object| {
            if (object.get("script")) |script| return try parser.string(path, script);
            if (object.get("url")) |url| return try parser.string(path, url);
            if (object.get("cmd")) |cmd| return try parser.string(path, cmd);
            return parser.fail(path, "expected a script or url string inside the object", .{});
        },
        .null => return null,
        else => return parser.fail(path, "expected a string or object, found {s}", .{@tagName(value)}),
    }
}

/// Re-renders any JSON value as text (used for `csp`, `headers`, `plugins`).
fn stringify(allocator: Allocator, value: std.json.Value) Error![]const u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();
    var stringify_ctx: std.json.Stringify = .{
        .writer = &buffer.writer,
        .options = .{},
    };
    stringify_ctx.write(value) catch return error.OutOfMemory;
    return buffer.toOwnedSlice() catch return error.OutOfMemory;
}

fn parseWindows(parser: *Parser, root: []const u8, value: std.json.Value) Error![]Config.WindowConfig {
    if (value != .array) return parser.fail(root, "expected an array", .{});
    const items = value.array.items;
    var out = try parser.allocator.alloc(Config.WindowConfig, items.len);
    for (items, 0..) |item, i| {
        const path = try std.fmt.allocPrint(parser.allocator, "{s}[{d}]", .{ root, i });
        defer parser.freePath(path);
        if (item != .object) return parser.fail(path, "expected an object", .{});
        out[i] = try parseWindow(parser, path, item.object);
    }
    return out;
}

fn parseWindow(parser: *Parser, path: []const u8, object: std.json.ObjectMap) Error!Config.WindowConfig {
    var window: Config.WindowConfig = .{};
    if (object.get("label")) |v| window.label = try parser.string(tryPath(parser, path, "label"), v);
    if (try parser.optString(tryPath(parser, path, "title"), object.get("title"))) |v| window.title = v;
    if (object.get("url")) |v| window.url = (try parseWebviewUrl(parser, tryPath(parser, path, "url"), v)) orelse "";
    if (try parser.optNumber(tryPath(parser, path, "width"), object.get("width"))) |v| window.width = v;
    if (try parser.optNumber(tryPath(parser, path, "height"), object.get("height"))) |v| window.height = v;
    if (try parser.optNumber(tryPath(parser, path, "x"), object.get("x"))) |v| window.x = v;
    if (try parser.optNumber(tryPath(parser, path, "y"), object.get("y"))) |v| window.y = v;
    if (try parser.optNumber(tryPath(parser, path, "minWidth"), object.get("minWidth"))) |v| window.min_width = v;
    if (try parser.optNumber(tryPath(parser, path, "minHeight"), object.get("minHeight"))) |v| window.min_height = v;
    if (try parser.optNumber(tryPath(parser, path, "maxWidth"), object.get("maxWidth"))) |v| window.max_width = v;
    if (try parser.optNumber(tryPath(parser, path, "maxHeight"), object.get("maxHeight"))) |v| window.max_height = v;
    if (try parser.optBool(tryPath(parser, path, "resizable"), object.get("resizable"))) |v| window.resizable = v;
    if (try parser.optBool(tryPath(parser, path, "decorations"), object.get("decorations"))) |v| window.decorations = v;
    if (try parser.optBool(tryPath(parser, path, "transparent"), object.get("transparent"))) |v| window.transparent = v;
    if (try parser.optBool(tryPath(parser, path, "alwaysOnTop"), object.get("alwaysOnTop"))) |v| window.always_on_top = v;
    if (try parser.optBool(tryPath(parser, path, "alwaysOnBottom"), object.get("alwaysOnBottom"))) |v| window.always_on_bottom = v;
    if (try parser.optBool(tryPath(parser, path, "visible"), object.get("visible"))) |v| window.visible = v;
    if (try parser.optBool(tryPath(parser, path, "fullscreen"), object.get("fullscreen"))) |v| window.fullscreen = v;
    if (try parser.optBool(tryPath(parser, path, "maximized"), object.get("maximized"))) |v| window.maximized = v;
    if (try parser.optBool(tryPath(parser, path, "center"), object.get("center"))) |v| window.center = v;
    if (try parser.optBool(tryPath(parser, path, "focus"), object.get("focus"))) |v| window.focus = v;
    if (try parser.optBool(tryPath(parser, path, "skipTaskbar"), object.get("skipTaskbar"))) |v| window.skip_taskbar = v;
    if (try parser.optBool(tryPath(parser, path, "devtools"), object.get("devtools"))) |v| window.devtools = v;
    if (try parser.optBool(tryPath(parser, path, "create"), object.get("create"))) |v| window.create = v;
    if (try parser.optBool(tryPath(parser, path, "hiddenTitle"), object.get("hiddenTitle"))) |v| window.hidden_title = v;
    if (try parser.optString(tryPath(parser, path, "theme"), object.get("theme"))) |v| window.theme = v;
    if (try parser.optString(tryPath(parser, path, "titleBarStyle"), object.get("titleBarStyle"))) |v| window.title_bar_style = v;
    if (try parser.optString(tryPath(parser, path, "userAgent"), object.get("userAgent"))) |v| window.user_agent = v;

    // Keys Z-Ts cannot honour yet: report them instead of silently dropping the intent.
    const unsupported = [_][]const u8{
        "windowEffects",
        "trafficLightPosition",
        "tabbingIdentifier",
        "additionalBrowserArgs",
        "browserExtensionsEnabled",
        "proxyUrl",
        "useHttpsScheme",
        "contentProtected",
        "visibleOnAllWorkspaces",
        "dataStoreIdentifier",
        "scrollBarStyle",
        "backgroundThrottling",
    };
    for (unsupported) |key| {
        if (object.get(key) == null) continue;
        const key_path = tryPath(parser, path, key);
        parser.note(key_path, "not supported by Z-Ts yet (ignored)", .{});
    }
    return window;
}

fn tryPath(parser: *Parser, parent: []const u8, key: []const u8) []const u8 {
    return parser.joinPath(parent, key) catch parent;
}

/// `WebviewUrl` is `"path"` | `{"url": "https://…"}` | `{"app": "path"}`.
fn parseWebviewUrl(parser: *Parser, path: []const u8, value: std.json.Value) Error!?[]const u8 {
    switch (value) {
        .string => |s| return try parser.allocator.dupe(u8, s),
        .object => |object| {
            if (object.get("url")) |url| return try parser.string(tryPath(parser, path, "url"), url);
            if (object.get("app")) |app_url| return try parser.string(tryPath(parser, path, "app"), app_url);
            return parser.fail(path, "expected `url` or `app` inside the object", .{});
        },
        .null => return null,
        else => return parser.fail(path, "expected a string or object, found {s}", .{@tagName(value)}),
    }
}

fn parseScope(parser: *Parser, path: []const u8, value: std.json.Value) Error!Config.Scope {
    switch (value) {
        .string => |s| {
            const allow = try parser.allocator.alloc([]const u8, 1);
            allow[0] = try parser.allocator.dupe(u8, s);
            return .{ .allow = allow };
        },
        .array => return .{ .allow = try parser.stringArray(path, value) },
        .object => |object| {
            var scope: Config.Scope = .{};
            if (object.get("allow")) |allow| scope.allow = try parser.stringArray(tryPath(parser, path, "allow"), allow);
            if (object.get("deny")) |deny| scope.deny = try parser.stringArray(tryPath(parser, path, "deny"), deny);
            if (try parser.optBool(tryPath(parser, path, "requireLiteralLeadingDot"), object.get("requireLiteralLeadingDot"))) |v| {
                scope.require_literal_leading_dot = v;
            }
            return scope;
        },
        .null => return .{},
        else => return parser.fail(path, "expected a string, array or object, found {s}", .{@tagName(value)}),
    }
}

fn parseSecurity(parser: *Parser, path: []const u8, value: std.json.Value) Error!Config.Security {
    if (value != .object) return parser.fail(path, "expected an object", .{});
    const object = value.object;
    var security: Config.Security = .{};

    if (object.get("csp")) |csp| security.csp_json = try stringify(parser.allocator, csp);
    if (object.get("devCsp")) |csp| security.dev_csp_json = try stringify(parser.allocator, csp);
    if (object.get("headers")) |headers| security.headers_json = try stringify(parser.allocator, headers);
    if (try parser.optBool(tryPath(parser, path, "freezePrototype"), object.get("freezePrototype"))) |v| {
        security.freeze_prototype = v;
    }

    if (object.get("assetProtocol")) |asset| {
        const asset_path = tryPath(parser, path, "assetProtocol");
        if (asset != .object) return parser.fail(asset_path, "expected an object", .{});
        if (try parser.optBool(tryPath(parser, asset_path, "enable"), asset.object.get("enable"))) |v| {
            security.asset_protocol.enable = v;
        }
        if (asset.object.get("scope")) |scope| {
            security.asset_protocol.scope = try parseScope(parser, tryPath(parser, asset_path, "scope"), scope);
        }
    }

    if (object.get("capabilities")) |caps| {
        const caps_path = tryPath(parser, path, "capabilities");
        if (caps != .array) return parser.fail(caps_path, "expected an array", .{});
        var out = try parser.allocator.alloc(Config.CapabilityEntry, caps.array.items.len);
        for (caps.array.items, 0..) |entry, i| {
            const entry_path = try std.fmt.allocPrint(parser.allocator, "{s}[{d}]", .{ caps_path, i });
            defer parser.freePath(entry_path);
            out[i] = switch (entry) {
                .string => |s| .{ .reference = try parser.allocator.dupe(u8, s) },
                .object => .{ .inline_json = entry },
                else => return parser.fail(entry_path, "expected a string or object, found {s}", .{@tagName(entry)}),
            };
        }
        security.capabilities = out;
    }

    const unsupported = [_][]const u8{ "pattern", "dangerousDisableAssetCspModification" };
    for (unsupported) |key| {
        if (object.get(key) == null) continue;
        parser.note(tryPath(parser, path, key), "not supported by Z-Ts yet (ignored)", .{});
    }
    return security;
}

fn parseTrayIcon(parser: *Parser, path: []const u8, value: std.json.Value) Error!Config.TrayIcon {
    if (value != .object) return parser.fail(path, "expected an object", .{});
    const object = value.object;
    var tray: Config.TrayIcon = .{};
    if (try parser.optString(tryPath(parser, path, "id"), object.get("id"))) |v| tray.id = v;
    if (try parser.optString(tryPath(parser, path, "iconPath"), object.get("iconPath"))) |v| tray.icon_path = v;
    if (try parser.optBool(tryPath(parser, path, "iconAsTemplate"), object.get("iconAsTemplate"))) |v| tray.icon_as_template = v;
    if (try parser.optBool(tryPath(parser, path, "menuOnLeftClick"), object.get("menuOnLeftClick"))) |v| tray.menu_on_left_click = v;
    if (try parser.optBool(tryPath(parser, path, "showMenuOnLeftClick"), object.get("showMenuOnLeftClick"))) |v| tray.show_menu_on_left_click = v;
    if (try parser.optString(tryPath(parser, path, "title"), object.get("title"))) |v| tray.title = v;
    if (try parser.optString(tryPath(parser, path, "tooltip"), object.get("tooltip"))) |v| tray.tooltip = v;
    return tray;
}

fn parseApp(parser: *Parser, path: []const u8, value: std.json.Value) Error!Config.App {
    if (value != .object) return parser.fail(path, "expected an object", .{});
    const object = value.object;
    var result: Config.App = .{};

    if (object.get("windows")) |windows| result.windows = try parseWindows(parser, tryPath(parser, path, "windows"), windows);
    if (object.get("security")) |security| result.security = try parseSecurity(parser, tryPath(parser, path, "security"), security);
    if (try parser.optBool(tryPath(parser, path, "withGlobalTauri"), object.get("withGlobalTauri"))) |v| result.with_global_tauri = v;
    if (try parser.optBool(tryPath(parser, path, "macOSPrivateApi"), object.get("macOSPrivateApi"))) |v| result.macos_private_api = v;
    if (object.get("trayIcon")) |tray| result.tray_icon = try parseTrayIcon(parser, tryPath(parser, path, "trayIcon"), tray);
    return result;
}

fn parseBuild(parser: *Parser, path: []const u8, value: std.json.Value) Error!Config.Build {
    if (value != .object) return parser.fail(path, "expected an object", .{});
    const object = value.object;
    var build: Config.Build = .{};
    if (object.get("devUrl")) |url| build.dev_url = try scalarOrObjectString(parser, tryPath(parser, path, "devUrl"), url);
    if (object.get("frontendDist")) |dist| build.frontend_dist = try scalarOrObjectString(parser, tryPath(parser, path, "frontendDist"), dist);
    if (object.get("beforeDevCommand")) |cmd| build.before_dev_command = try scalarOrObjectString(parser, tryPath(parser, path, "beforeDevCommand"), cmd);
    if (object.get("beforeBuildCommand")) |cmd| build.before_build_command = try scalarOrObjectString(parser, tryPath(parser, path, "beforeBuildCommand"), cmd);
    return build;
}

fn parseBundle(parser: *Parser, path: []const u8, value: std.json.Value) Error!Config.Bundle {
    if (value != .object) return parser.fail(path, "expected an object", .{});
    const object = value.object;
    var bundle: Config.Bundle = .{};
    if (try parser.optBool(tryPath(parser, path, "active"), object.get("active"))) |v| bundle.active = v;
    if (object.get("targets")) |targets| {
        // `"all"` (a bare string) or an array of target names.
        const targets_path = tryPath(parser, path, "targets");
        bundle.targets = switch (targets) {
            .string => blk: {
                const one = try parser.allocator.alloc([]const u8, 1);
                one[0] = try parser.string(targets_path, targets);
                break :blk one;
            },
            .array => try parser.stringArray(targets_path, targets),
            else => return parser.fail(targets_path, "expected a string or array, found {s}", .{@tagName(targets)}),
        };
    }
    if (object.get("icon")) |icon| bundle.icon = try parser.stringArray(tryPath(parser, path, "icon"), icon);
    return bundle;
}

/// Parses `tauri.conf.json` text. The returned `Parsed` owns every string in the config.
pub fn parse(backing: Allocator, json_text: []const u8, diagnostics: ?*Diagnostics) Error!Parsed {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();

    // A private sink when the caller does not collect notes (they still land in the arena).
    var local_diags: Diagnostics = .init(arena.allocator());
    const diags = diagnostics orelse &local_diags;

    const config = try parseInto(arena.allocator(), json_text, diags);
    return .{ .arena = arena, .config = config };
}

fn parseInto(allocator: Allocator, json_text: []const u8, diags: *Diagnostics) Error!Config {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, json_text, .{}) catch
        return error.InvalidJson;
    if (parsed != .object) {
        try diags.add("$", "the config root must be an object");
        return error.InvalidConfig;
    }
    const object = parsed.object;
    var parser = Parser{ .allocator = allocator, .diags = diags };

    var config: Config = .{};
    if (try parser.optString("$schema", object.get("$schema"))) |v| config.schema = v;
    if (try parser.optString("productName", object.get("productName"))) |v| config.product_name = v;
    if (config.product_name == null) {
        if (try parser.optString("product-name", object.get("product-name"))) |v| config.product_name = v;
    }
    if (try parser.optString("version", object.get("version"))) |v| config.version = v;
    if (object.get("identifier")) |identifier| config.identifier = try parser.string("identifier", identifier);
    if (object.get("app")) |app_value| config.app = try parseApp(&parser, "app", app_value);
    if (object.get("build")) |build| config.build = try parseBuild(&parser, "build", build);
    if (object.get("bundle")) |bundle| config.bundle = try parseBundle(&parser, "bundle", bundle);
    if (object.get("plugins")) |plugins| config.plugins_json = try stringify(allocator, plugins);

    // Unknown top-level keys are a warning, never an error (Tauri adds fields every release).
    for (object.keys()) |key| {
        if (isKnownTopLevel(key)) continue;
        parser.note(key, "unknown top-level config key (ignored)", .{});
    }
    return config;
}

fn isKnownTopLevel(key: []const u8) bool {
    const known = [_][]const u8{
        "$schema",     "productName", "product-name", "version",
        "identifier",  "app",         "build",        "bundle",
        "plugins",     "mainBinaryName",
    };
    for (known) |candidate| {
        if (std.mem.eql(u8, key, candidate)) return true;
    }
    return false;
}

/// Reads `<dir>/tauri.conf.json` plus every `<dir>/capabilities/*.json`.
///
/// A missing `capabilities/` directory is fine (Tauri v1 projects and small v2 projects have none);
/// an unreadable `tauri.conf.json` is an error the caller must surface.
pub fn load(backing: Allocator, io: Io, dir_path: []const u8) !Imported {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    const config_path = try std.fmt.allocPrint(a, "{s}/tauri.conf.json", .{dir_path});
    const config_text = try Io.Dir.cwd().readFileAlloc(io, config_path, a, .limited(8 * 1024 * 1024));

    var warnings = Diagnostics.init(a);
    const config = try parseInto(a, config_text, &warnings);

    var files: std.ArrayListUnmanaged(Imported.CapabilityFile) = .empty;
    const caps_path = try std.fmt.allocPrint(a, "{s}/capabilities", .{dir_path});
    if (Io.Dir.cwd().openDir(io, caps_path, .{ .iterate = true })) |caps_dir| {
        defer caps_dir.close(io);
        var it = caps_dir.iterate();
        while (it.next(io) catch |err| return err) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const bytes = caps_dir.readFileAlloc(io, entry.name, a, .limited(4 * 1024 * 1024)) catch |err| return err;
            // Invalid JSON is reported instead of failing the import: the rest of the project is
            // still migratable, and the CLI prints every warning.
            if (std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{})) |_| {
                try files.append(a, .{
                    .file_name = try a.dupe(u8, entry.name),
                    .json = bytes,
                });
            } else |_| {
                const path = try std.fmt.allocPrint(a, "capabilities/{s}", .{entry.name});
                const message = try std.fmt.allocPrint(a, "not valid JSON (ignored)", .{});
                try warnings.add(path, message);
            }
        }
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    return .{
        .arena = arena,
        .config = config,
        .capabilities = try files.toOwnedSlice(a),
        .warnings = warnings,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// A realistic `tauri.conf.json` (Tauri v2, all keys the upstream template ships).
const sample_config =
    \\{
    \\  "$schema": "https://schema.tauri.app/config/2",
    \\  "productName": "Z-Ts Studio",
    \\  "version": "2.7.0",
    \\  "identifier": "jp.zts.studio",
    \\  "build": {
    \\    "beforeDevCommand": "npm run dev",
    \\    "devUrl": "http://localhost:1420",
    \\    "beforeBuildCommand": { "script": "npm run build", "wait": true },
    \\    "frontendDist": "../dist"
    \\  },
    \\  "app": {
    \\    "withGlobalTauri": true,
    \\    "windows": [
    \\      {
    \\        "label": "main",
    \\        "title": "Z-Ts Studio",
    \\        "width": 1280,
    \\        "height": 720,
    \\        "minWidth": 640,
    \\        "minHeight": 480,
    \\        "x": 32,
    \\        "y": 64,
    \\        "resizable": true,
    \\        "decorations": false,
    \\        "alwaysOnTop": true,
    \\        "theme": "Dark",
    \\        "windowEffects": { "effects": ["blur"] }
    \\      },
    \\      { "label": "splash", "url": "splash.html", "create": false },
    \\      { "label": "remote", "url": { "url": "https://example.com/app" }, "width": 400, "height": 300 }
    \\    ],
    \\    "security": {
    \\      "csp": "default-src 'self'; img-src 'self' asset: http://asset.localhost",
    \\      "freezePrototype": true,
    \\      "assetProtocol": { "enable": true, "scope": ["$APPDATA/**", "$RESOURCE/**"] },
    \\      "capabilities": ["main-window", { "identifier": "inline-cap", "windows": ["main"], "permissions": ["core:default"] }]
    \\    },
    \\    "trayIcon": { "iconPath": "icons/tray.png", "tooltip": "Z-Ts", "menuOnLeftClick": false }
    \\  },
    \\  "bundle": { "active": true, "targets": "all", "icon": ["icons/32x32.png", "icons/icon.icns"] },
    \\  "plugins": { "updater": { "endpoints": ["https://example.com/updates"] } }
    \\}
;

test "tauri.conf.json parses product/app/build/bundle and maps windows to WindowSpec" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var parsed = try parse(testing.allocator, sample_config, &diags);
    defer parsed.deinit();

    const cfg = &parsed.config;
    try testing.expectEqualStrings("Z-Ts Studio", cfg.product_name.?);
    try testing.expectEqualStrings("2.7.0", cfg.version.?);
    try testing.expectEqualStrings("jp.zts.studio", cfg.identifier);
    try testing.expectEqualStrings("http://localhost:1420", cfg.build.dev_url.?);
    try testing.expectEqualStrings("../dist", cfg.build.frontend_dist.?);
    try testing.expectEqualStrings("npm run dev", cfg.build.before_dev_command.?);
    // `beforeBuildCommand` as an object: the `script` key wins.
    try testing.expectEqualStrings("npm run build", cfg.build.before_build_command.?);
    try testing.expectEqual(true, cfg.app.with_global_tauri);
    try testing.expectEqual(true, cfg.app.security.freeze_prototype);
    try testing.expectEqual(true, cfg.app.security.asset_protocol.enable);
    try testing.expectEqual(@as(usize, 2), cfg.app.security.asset_protocol.scope.allow.len);
    try testing.expectEqualStrings("$APPDATA/**", cfg.app.security.asset_protocol.scope.allow[0]);
    try testing.expect(cfg.app.security.csp_json.?.len > 0);
    try testing.expectEqual(@as(usize, 2), cfg.app.security.capabilities.len);
    try testing.expectEqualStrings("main-window", cfg.app.security.capabilities[0].reference);
    switch (cfg.app.security.capabilities[1]) {
        .inline_json => |v| try testing.expect(std.meta.activeTag(v) == .object),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(true, cfg.bundle.active);
    try testing.expectEqualStrings("all", cfg.bundle.targets[0]);
    try testing.expectEqual(@as(usize, 2), cfg.bundle.icon.len);
    try testing.expect(cfg.plugins_json.?.len > 0);
    try testing.expectEqualStrings("icons/tray.png", cfg.app.tray_icon.?.icon_path.?);
    try testing.expectEqualStrings("Z-Ts", cfg.app.tray_icon.?.tooltip.?);

    // Windows → `core.WindowSpec`.
    try testing.expectEqual(@as(usize, 3), cfg.app.windows.len);
    const main = cfg.app.windows[0];
    try testing.expectEqualStrings("main", main.label);
    try testing.expectEqual(@as(f64, 1280), main.width);
    try testing.expectEqual(@as(f64, 720), main.height);
    try testing.expectEqual(false, main.decorations);
    try testing.expectEqual(true, main.always_on_top);
    try testing.expectEqualStrings("Dark", main.theme.?);
    // Absolute URLs pass through untouched.
    try testing.expectEqualStrings("https://example.com/app", cfg.app.windows[2].appUrl());

    const specs = try parsed.windowSpecs(testing.allocator);
    defer testing.allocator.free(specs);
    // `create: false` windows are not created eagerly.
    try testing.expectEqual(@as(usize, 2), specs.len);
    try testing.expectEqualStrings("main", specs[0].label);
    try testing.expectEqual(@as(f64, 1280), specs[0].size.width.v);
    try testing.expectEqual(@as(f64, 640), specs[0].min_size.?.width.v);
    try testing.expectEqual(@as(f64, 32), specs[0].position.?.x.v);
    try testing.expectEqual(core.WindowTheme.dark, specs[0].theme);
    try testing.expectEqualStrings("tauri://localhost/", specs[0].initial_url);
    try testing.expectEqualStrings("https://example.com/app", specs[1].initial_url);

    // `app.plugins` etc. survive as text, and unknown/unsupported keys are warnings only.
    try testing.expect(diags.has("app.windows[0].windowEffects"));
    try testing.expectEqualStrings(
        "Z-Ts Studio",
        (cfg.toAppConfig()).name,
    );
}

test "wrong types fail with a field path and invalid JSON is rejected" {
    {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        try testing.expectError(
            error.InvalidConfig,
            parse(testing.allocator, "{\"app\":{\"windows\":[{\"width\":\"wide\"}]}}", &diags),
        );
        try testing.expect(diags.has("app.windows[0].width"));
    }
    {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        try testing.expectError(error.InvalidJson, parse(testing.allocator, "{ nope", &diags));
    }
    {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        try testing.expectError(error.InvalidConfig, parse(testing.allocator, "[]", &diags));
    }
}

test "unknown top-level keys warn instead of failing, and defaults are sane" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var parsed = try parse(testing.allocator, "{\"identifier\":\"a.b\",\"futureKey\":42}", &diags);
    defer parsed.deinit();

    try testing.expect(diags.has("futureKey"));
    try testing.expectEqualStrings("a.b", parsed.config.identifier);
    // No `app.windows` → no windows, and no crash.
    const specs = try parsed.windowSpecs(testing.allocator);
    defer testing.allocator.free(specs);
    try testing.expectEqual(@as(usize, 0), specs.len);
    const app_cfg = parsed.config.toAppConfig();
    try testing.expectEqualStrings("a.b", app_cfg.name);
    try testing.expectEqualStrings("0.1.0", app_cfg.version);
}

test "scope accepts a string, an array and an object shape" {
    var parsed = try parse(testing.allocator,
        \\{"identifier":"x.y","app":{"security":{"assetProtocol":{
        \\  "enable":true,
        \\  "scope":{"allow":["$HOME/**"],"deny":["$HOME/.ssh/**"],"requireLiteralLeadingDot":false}
        \\}}}}
    , null);
    defer parsed.deinit();
    const scope = parsed.config.app.security.asset_protocol.scope;
    try testing.expectEqualStrings("$HOME/**", scope.allow[0]);
    try testing.expectEqualStrings("$HOME/.ssh/**", scope.deny[0]);
    try testing.expectEqual(false, scope.require_literal_leading_dot);

    var single = try parse(testing.allocator, "{\"identifier\":\"x.y\",\"app\":{\"security\":{\"assetProtocol\":{\"enable\":true,\"scope\":\"$APPDATA/**\"}}}}", null);
    defer single.deinit();
    try testing.expectEqualStrings("$APPDATA/**", single.config.app.security.asset_protocol.scope.allow[0]);
}

test "load reads tauri.conf.json plus capabilities/*.json from a directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "tauri.conf.json",
        .data = "{\"productName\":\"Loaded\",\"identifier\":\"jp.zts.loaded\",\"app\":{\"windows\":[{\"label\":\"main\"}]}}",
    });
    try tmp.dir.createDirPath(testing.io, "capabilities");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "capabilities/main.json",
        .data = "{\"identifier\":\"main-window\",\"windows\":[\"main\"],\"permissions\":[\"core:default\"]}",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "capabilities/broken.json",
        .data = "{ nope",
    });

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var imported = try load(testing.allocator, testing.io, dir_path);
    defer imported.deinit();

    try testing.expectEqualStrings("Loaded", imported.config.product_name.?);
    try testing.expectEqual(@as(usize, 1), imported.capabilities.len);
    try testing.expectEqualStrings("main.json", imported.capabilities[0].file_name);
    // The unreadable capability is a warning, not a hard failure.
    try testing.expect(imported.warnings.has("capabilities/broken.json"));
}
