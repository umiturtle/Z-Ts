//! Tauri v2 **ACL** (`capabilities/*.json`) — the security half of `M4-04`.
//!
//! An existing Tauri app describes *what the frontend may call* in `capabilities/*.json`:
//!
//! ```json
//! {
//!   "identifier": "main-window",
//!   "windows": ["main"],
//!   "permissions": [
//!     "core:default",
//!     "fs:allow-read-text-file",
//!     { "identifier": "dialog:allow-open", "allow": [{ "path": "$HOME/**" }] }
//!   ],
//!   "platforms": ["linux", "macOS"]
//! }
//! ```
//!
//! This module parses those files and answers one question — *may `command` run in `window` from
//! `origin`?* — with **fail-closed** semantics: an unknown command, an unknown permission
//! identifier, or an unmatched window glob denies the call.
//!
//! ## Permission identifiers are generated from the real schema
//!
//! Hand-maintained permission tables rot the moment a command is added. [`tableFor`] walks the
//! `rpc.Schema` at **comptime** and derives the upstream identifiers mechanically:
//!
//! | wire command | permission |
//! |---|---|
//! | `plugin:fs\|read_text_file` | `fs:allow-read-text-file` |
//! | `plugin:window\|set_title` | `core:window:allow-set-title` |
//! | `plugin:menu\|set_as_app_menu` | `core:menu:allow-set-as-app-menu` |
//!
//! `core:*` namespaces are the ones merged by `tauri.withCorePlugins`; everything else is a
//! standalone plugin (`fs`, `dialog`, `clipboard-manager`, …).
//!
//! ## Wiring
//!
//! ```zig
//! var policy = try tauri.acl.Policy.init(alloc, io, .{ .files = caps, .inline = cfg.app.security.capabilities });
//! defer policy.deinit();
//!
//! var router = FullSchema.bind(.{ … }).withAuthCtx(policy.context(), tauri.acl.Policy.authorizeCtx);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");

const rpc = @import("zts_rpc");
const core = @import("zts_core");
const config_import = @import("config_import.zig");

pub const Error = error{
    OutOfMemory,
    InvalidCapability,
    /// `settings.security.capabilities` referenced an identifier that no capability file defines.
    UnknownCapability,
};

// ============================================================================
// Capability model (upstream `tauri_utils::acl::capability`)
// ============================================================================

/// The three desktop platforms a `capabilities/*.json` file can restrict itself to. Parsing accepts
/// the upstream spellings (`Linux`, `macOS`, `Windows`) case-insensitively.
pub const Platform = enum {
    linux,
    macos,
    windows,

    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .macos => .macos,
            .windows => .windows,
            else => .linux,
        };
    }

    /// Upstream spells them `Linux` / `macOS` / `Windows`.
    pub fn parse(raw: []const u8) ?Platform {
        if (std.ascii.eqlIgnoreCase(raw, "linux")) return .linux;
        if (std.ascii.eqlIgnoreCase(raw, "macos")) return .macos;
        if (std.ascii.eqlIgnoreCase(raw, "windows")) return .windows;
        return null;
    }

    pub fn label(self: Platform) []const u8 {
        return switch (self) {
            .linux => "Linux",
            .macos => "macOS",
            .windows => "Windows",
        };
    }
};

/// One `permissions[]` entry: `"fs:allow-read-text-file"` or
/// `{ "identifier": "…", "allow": […], "deny": […] }`.
pub const Permission = struct {
    identifier: []const u8,
    /// Scope objects attached to this entry (`allow` / `deny` in upstream `Scopes`); kept as JSON
    /// so `plugin:fs` can interpret them without this module knowing about paths.
    scope_json: ?[]const u8 = null,
};

/// One `capabilities/*.json` file: which windows/webviews it applies to, which permissions it
/// grants, and on which platforms/URLs. `windows` and `webviews` are matched as globs; leaving both
/// empty means "every window", and a capability that matches no window is a no-op rather than an
/// error (upstream behaviour).
pub const Capability = struct {
    identifier: []const u8,
    description: []const u8 = "",
    /// Glob patterns; empty = "every window" only when `webviews` is empty as well.
    windows: []const []const u8 = &.{},
    webviews: []const []const u8 = &.{},
    permissions: []const Permission = &.{},
    /// `null` = every platform.
    platforms: ?[]const Platform = null,
    /// Whether local app URLs (`tauri://localhost`, `http://tauri.localhost`, …) match.
    local: bool = true,
    /// Remote URL patterns (`https://*.example.com`).
    remote: []const []const u8 = &.{},

    pub fn matchesPlatform(self: Capability, platform: Platform) bool {
        const allowed = self.platforms orelse return true;
        for (allowed) |candidate| {
            if (candidate == platform) return true;
        }
        return false;
    }

    /// A capability with neither `windows` nor `webviews` applies to every window (upstream).
    pub fn matchesWindow(self: Capability, label: []const u8) bool {
        if (self.windows.len == 0 and self.webviews.len == 0) return true;
        for (self.windows) |pattern| {
            if (globMatch(pattern, label)) return true;
        }
        for (self.webviews) |pattern| {
            if (globMatch(pattern, label)) return true;
        }
        return false;
    }

    pub fn matchesOrigin(self: Capability, origin: []const u8) bool {
        if (isLocalOrigin(origin)) return self.local;
        for (self.remote) |pattern| {
            if (urlPatternMatch(pattern, origin)) return true;
        }
        return false;
    }

    /// Any permission in this capability that allows `command` for `window`/`origin`.
    pub fn allows(self: Capability, command: []const u8, window: []const u8, origin: []const u8) bool {
        if (!self.matchesWindow(window)) return false;
        if (!self.matchesOrigin(origin)) return false;
        for (self.permissions) |permission| {
            if (permissionResolves(permission.identifier, command, false)) return true;
        }
        return false;
    }

    /// Any permission that explicitly denies `command` (wins over `allows`).
    pub fn denies(self: Capability, command: []const u8, window: []const u8, origin: []const u8) bool {
        if (!self.matchesWindow(window)) return false;
        if (!self.matchesOrigin(origin)) return false;
        for (self.permissions) |permission| {
            if (permissionResolves(permission.identifier, command, true)) return true;
        }
        return false;
    }
};

/// `tauri://localhost` / `http://tauri.localhost` / any `file://` / `about:` origin counts as local.
pub fn isLocalOrigin(origin: []const u8) bool {
    // No origin at all (CLI / in-process calls) counts as local, exactly like Tauri's own IPC.
    if (origin.len == 0) return true;
    const local_prefixes = [_][]const u8{
        "tauri://",
        "http://tauri.localhost",
        "https://tauri.localhost",
        "asset://",
        "file://",
        "about:",
    };
    for (local_prefixes) |prefix| {
        if (std.mem.startsWith(u8, origin, prefix)) return true;
    }
    return false;
}

/// `*` / `?` glob over the whole string (`main`, `plugin-*`, `?ain`).
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            mark = t;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            t = mark;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// URL patterns follow the same `*` rules as `windows` (upstream uses the URLPattern standard;
/// `https://*.example.com` is the common case and behaves identically here).
pub fn urlPatternMatch(pattern: []const u8, url: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    return globMatch(pattern, trimmed) or globMatch(pattern, url) or
        (std.mem.endsWith(u8, pattern, "*") and std.mem.startsWith(u8, trimmed, std.mem.trimEnd(u8, pattern, "*")));
}

// ============================================================================
// Permission → command resolution
// ============================================================================

/// `plugin:fs|read_text_file` → `fs:allow-read-text-file`.
///
/// Core namespaces (`window`, `event`, `app`, `path`, `resources`, `menu`, `tray`) live under
/// `core:` because that is where upstream puts them.
pub fn permissionIdFor(wire_command: []const u8, is_core: bool, deny: bool, buffer: []u8) ?[]const u8 {
    const pipe = std.mem.indexOfScalar(u8, wire_command, '|') orelse return null;
    const prefix = wire_command[0..pipe];
    const name = wire_command[pipe + 1 ..];
    const plugin = if (std.mem.startsWith(u8, prefix, "plugin:")) prefix["plugin:".len..] else prefix;

    var writer = std.Io.Writer.fixed(buffer);
    const action = if (deny) "deny-" else "allow-";
    if (is_core) {
        writer.print("core:{s}:{s}{s}", .{ plugin, action, "" }) catch return null;
    } else {
        writer.print("{s}:{s}", .{ plugin, action }) catch return null;
    }
    // kebab-case the command name (`read_text_file` → `read-text-file`).
    for (name) |c| {
        const c2 = if (c == '_') '-' else c;
        writer.writeAll(&[_]u8{c2}) catch return null;
    }
    return writer.buffered();
}

fn isCorePlugin(plugin: []const u8) bool {
    const core_plugins = [_][]const u8{ "window", "event", "app", "path", "resources", "menu", "tray" };
    for (core_plugins) |candidate| {
        if (std.mem.eql(u8, plugin, candidate)) return true;
    }
    return false;
}

/// Does `identifier` grant (or deny) `command`?
///
/// Handles the three shapes a real capability uses: an exact `<plugin>:allow-<cmd>`, a plugin
/// default (`<plugin>:default`, `core:default`, `core:<plugin>:default`) and an app-level
/// permission equal to the command name.
fn permissionResolves(identifier: []const u8, command: []const u8, deny: bool) bool {
    var buf: [160]u8 = undefined;

    const pipe = std.mem.indexOfScalar(u8, command, '|');
    if (pipe) |split| {
        const prefix = command[0..split];
        const plugin = if (std.mem.startsWith(u8, prefix, "plugin:")) prefix["plugin:".len..] else prefix;
        const is_core = isCorePlugin(plugin);

        if (permissionIdFor(command, is_core, deny, &buf)) |id| {
            if (std.mem.eql(u8, identifier, id)) return true;
        }

        // `default` sets: `<plugin>:default`, `core:default`, `core:<plugin>:default`.
        const action = if (deny) "deny-" else "allow-";
        _ = action;
        if (!deny) {
            if (std.mem.eql(u8, identifier, std.fmt.bufPrint(&buf, "{s}:default", .{plugin}) catch return false)) return true;
            if (is_core and std.mem.eql(u8, identifier, std.fmt.bufPrint(&buf, "core:{s}:default", .{plugin}) catch return false)) return true;
            if (is_core and std.mem.eql(u8, identifier, "core:default")) return true;
        }
        return false;
    }

    // Application commands (`""` prefix): the permission is the command name itself, optionally
    // namespaced as `allow-<command>`.
    if (deny) return false;
    if (std.mem.eql(u8, identifier, command)) return true;
    const allow_name = std.fmt.bufPrint(&buf, "allow-{s}", .{command}) catch return false;
    return std.mem.eql(u8, identifier, allow_name);
}

// ============================================================================
// Policy
// ============================================================================

/// The compiled, immutable set of capabilities for one app.
pub const Policy = struct {
    arena: std.heap.ArenaAllocator,
    capabilities: []Capability,
    /// Platform used for `platforms` filtering (injectable so tests cover all 3 OS in one run).
    platform: Platform,
    /// Every permission identifier that actually resolved to a command, for diagnostics
    /// (`unknown permissions` are reported here so a typo does not silently widen access).
    known: []const []const u8 = &.{},

    pub const Source = struct {
        /// Contents of `capabilities/*.json`.
        files: []const config_import.Imported.CapabilityFile = &.{},
        /// `app.security.capabilities` from `tauri.conf.json` (`inline` is a Zig keyword).
        inline_entries: []const config_import.Config.CapabilityEntry = &.{},
    };

    pub fn init(backing: Allocator, source: Source) Error!Policy {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        return initIn(&arena, source);
    }

    fn initIn(arena: *std.heap.ArenaAllocator, source: Source) Error!Policy {
        const a = arena.allocator();
        var caps: std.ArrayListUnmanaged(Capability) = .empty;

        // 1. Every capability file (3 accepted shapes: object / array / `{capabilities:[…]}`).
        for (source.files) |file| {
            try parseCapabilityFile(a, file.json, &caps);
        }

        // 2. Inline capabilities from `tauri.conf.json`, plus references resolved by identifier.
        for (source.inline_entries) |entry| {
            switch (entry) {
                .reference => |id| {
                    var found = false;
                    for (caps.items) |capability| {
                        if (std.mem.eql(u8, capability.identifier, id)) found = true;
                    }
                    if (!found) return error.UnknownCapability;
                },
                .inline_json => |value| {
                    try parseCapabilityValue(a, value, &caps);
                },
            }
        }

        return .{
            .arena = arena.*,
            .capabilities = try caps.toOwnedSlice(a),
            .platform = Platform.current(),
        };
    }

    pub fn deinit(self: *Policy) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *const Policy) Allocator {
        return self.arena.allocator();
    }

    /// Overrides the platform used by `platforms` filtering (tests / cross-OS replays).
    pub fn withPlatform(self: *Policy, platform: Platform) void {
        self.platform = platform;
    }

    /// **The** decision point. Fail-closed: no capability, no allow, or any explicit deny → false.
    pub fn allows(self: *const Policy, command: []const u8, window: []const u8, origin: []const u8) bool {
        if (command.len == 0) return false;
        var allowed = false;
        for (self.capabilities) |capability| {
            if (!capability.matchesPlatform(self.platform)) continue;
            if (capability.denies(command, window, origin)) return false;
            if (capability.allows(command, window, origin)) allowed = true;
        }
        return allowed;
    }

    /// Like [`allows`] but returns the capability that granted the call (diagnostics / logging).
    pub fn grantingCapability(self: *const Policy, command: []const u8, window: []const u8, origin: []const u8) ?Capability {
        for (self.capabilities) |capability| {
            if (!capability.matchesPlatform(self.platform)) continue;
            if (capability.denies(command, window, origin)) return null;
            if (capability.allows(command, window, origin)) return capability;
        }
        return null;
    }

    /// Builds a policy straight from an imported `src-tauri/` directory
    /// (`tauri.config_import.load`), which is the one-line migration path.
    pub fn fromImported(backing: Allocator, imported: *const config_import.Imported) Error!Policy {
        return Policy.init(backing, .{
            .files = imported.capabilities,
            .inline_entries = imported.config.app.security.capabilities,
        });
    }

    /// Opaque pointer for `rpc.Router.withAuthCtx`.
    pub fn context(self: *Policy) ?*anyopaque {
        return @ptrCast(self);
    }

    /// The `AuthorizeFn` body: resolves the calling window from `core.CallContext`.
    pub fn authorizeCtx(userdata: ?*anyopaque, ctx: *const rpc.Ctx, command: []const u8) bool {
        const self: *Policy = @ptrCast(@alignCast(userdata orelse return false));
        const window = windowLabelOf(ctx);
        return self.allows(command, window, ctx.origin);
    }
};

/// The window label of the current call (`core.CallContext.window_id` → label registry), or `""`
/// when the caller is not a desktop window (CLI / bridge without a window).
///
/// `CallContext` has no label registry, so commands run with the label passed by the host via
/// `Ctx.origin`-independent `window_label` hook: see `withWindowLabel`.
var window_label_hook: ?*const fn (*const rpc.Ctx) ?[]const u8 = null;

/// Installs a label resolver used by [`Policy.authorizeCtx`] (call once at startup).
pub fn withWindowLabel(resolver: *const fn (ctx: *const rpc.Ctx) ?[]const u8) void {
    window_label_hook = resolver;
}

fn windowLabelOf(ctx: *const rpc.Ctx) []const u8 {
    if (window_label_hook) |resolver| {
        if (resolver(ctx)) |label| return label;
    }
    // No resolver: fall back to the call context's window id, which the host may put in
    // `Ctx.origin`-like form. Unknown → empty label (matches only catch-all capabilities).
    return "";
}

// ============================================================================
// Parsing
// ============================================================================

fn parseCapabilityFile(allocator: Allocator, json_text: []const u8, out: *std.ArrayListUnmanaged(Capability)) Error!void {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, json_text, .{}) catch
        return error.InvalidCapability;
    return parseCapabilityValue(allocator, value, out);
}

/// `CapabilityFile`: a single capability object, an array of them, or `{ "capabilities": […] }`.
fn parseCapabilityValue(allocator: Allocator, value: std.json.Value, out: *std.ArrayListUnmanaged(Capability)) Error!void {
    switch (value) {
        .object => |object| {
            if (object.get("capabilities")) |inner| {
                if (inner != .array) return error.InvalidCapability;
                for (inner.array.items) |item| try out.append(allocator, try parseCapability(allocator, item));
                return;
            }
            try out.append(allocator, try parseCapability(allocator, value));
        },
        .array => |array| {
            for (array.items) |item| try out.append(allocator, try parseCapability(allocator, item));
        },
        else => return error.InvalidCapability,
    }
}

fn parseCapability(allocator: Allocator, value: std.json.Value) Error!Capability {
    if (value != .object) return error.InvalidCapability;
    const object = value.object;

    var capability: Capability = .{ .identifier = "" };
    if (object.get("identifier")) |identifier| {
        if (identifier != .string) return error.InvalidCapability;
        capability.identifier = try allocator.dupe(u8, identifier.string);
    }
    if (capability.identifier.len == 0) return error.InvalidCapability;

    if (object.get("description")) |description| {
        if (description == .string) capability.description = try allocator.dupe(u8, description.string);
    }
    if (object.get("windows")) |windows| capability.windows = try stringList(allocator, windows);
    if (object.get("webviews")) |webviews| capability.webviews = try stringList(allocator, webviews);
    if (object.get("local")) |local| {
        if (local == .bool) capability.local = local.bool;
    }
    if (object.get("remote")) |remote| {
        if (remote != .object) return error.InvalidCapability;
        if (remote.object.get("urls")) |urls| capability.remote = try stringList(allocator, urls);
    }
    if (object.get("platforms")) |platforms| {
        if (platforms != .array) return error.InvalidCapability;
        var list = try allocator.alloc(Platform, platforms.array.items.len);
        for (platforms.array.items, 0..) |item, i| {
            if (item != .string) return error.InvalidCapability;
            list[i] = Platform.parse(item.string) orelse return error.InvalidCapability;
        }
        capability.platforms = list;
    }
    if (object.get("permissions")) |permissions| {
        if (permissions != .array) return error.InvalidCapability;
        var list = try allocator.alloc(Permission, permissions.array.items.len);
        for (permissions.array.items, 0..) |item, i| {
            list[i] = switch (item) {
                .string => |s| .{ .identifier = try allocator.dupe(u8, s) },
                .object => |entry| blk: {
                    const identifier = entry.get("identifier") orelse return error.InvalidCapability;
                    if (identifier != .string) return error.InvalidCapability;
                    // Anything besides `identifier` (`allow` / `deny` scope objects) is kept
                    // verbatim so the owning plugin can interpret it.
                    var buffer: std.Io.Writer.Allocating = .init(allocator);
                    var stringify: std.json.Stringify = .{ .writer = &buffer.writer, .options = .{} };
                    stringify.write(item) catch return error.OutOfMemory;
                    break :blk .{
                        .identifier = try allocator.dupe(u8, identifier.string),
                        .scope_json = buffer.toOwnedSlice() catch return error.OutOfMemory,
                    };
                },
                else => return error.InvalidCapability,
            };
        }
        capability.permissions = list;
    }
    return capability;
}

fn stringList(allocator: Allocator, value: std.json.Value) Error![]const []const u8 {
    if (value != .array) return error.InvalidCapability;
    var out = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidCapability;
        out[i] = try allocator.dupe(u8, item.string);
    }
    return out;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn cap(allocator: Allocator, json_text: []const u8) ![]Capability {
    var list: std.ArrayListUnmanaged(Capability) = .empty;
    try parseCapabilityFile(allocator, json_text, &list);
    return list.toOwnedSlice(allocator);
}

test "permission identifiers are derived from the wire command (kebab-case, core prefix)" {
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings(
        "fs:allow-read-text-file",
        permissionIdFor("plugin:fs|read_text_file", false, false, &buf).?,
    );
    try testing.expectEqualStrings(
        "core:window:allow-set-title",
        permissionIdFor("plugin:window|set_title", true, false, &buf).?,
    );
    try testing.expectEqualStrings(
        "core:menu:allow-set-as-app-menu",
        permissionIdFor("plugin:menu|set_as_app_menu", true, false, &buf).?,
    );
    try testing.expectEqualStrings(
        "dialog:deny-open",
        permissionIdFor("plugin:dialog|open", false, true, &buf).?,
    );
    try testing.expect(permissionIdFor("no-pipe", false, false, &buf) == null);
}

test "capability matching: window globs, platforms, local vs remote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const caps = try cap(arena.allocator(),
        \\{
        \\  "identifier": "main-window",
        \\  "windows": ["main", "plugin-*"],
        \\  "platforms": ["linux", "macOS"],
        \\  "permissions": ["core:default", "fs:allow-read-text-file"]
        \\}
    );
    const capability = caps[0];
    try testing.expect(capability.matchesWindow("main"));
    try testing.expect(capability.matchesWindow("plugin-media"));
    try testing.expect(!capability.matchesWindow("settings"));
    try testing.expect(capability.matchesPlatform(.linux));
    try testing.expect(capability.matchesPlatform(.macos));
    try testing.expect(!capability.matchesPlatform(.windows));

    // Local origins match `local: true`, remote origins need a matching URL pattern.
    try testing.expect(capability.matchesOrigin("tauri://localhost"));
    try testing.expect(!capability.matchesOrigin("https://evil.example"));
    try testing.expect(capability.allows("plugin:fs|read_text_file", "main", "tauri://localhost"));
    try testing.expect(capability.allows("plugin:window|set_title", "main", "tauri://localhost"));
    try testing.expect(!capability.allows("plugin:fs|write_file", "main", "tauri://localhost"));
    try testing.expect(!capability.allows("plugin:fs|read_text_file", "settings", "tauri://localhost"));
}

test "policy resolves referenced and inline capabilities, and fails closed" {
    // The inline capability's JSON tree is owned by this arena (the policy copies what it keeps).
    var json_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer json_arena.deinit();
    const file_json =
        \\[
        \\  { "identifier": "main-window", "windows": ["main"], "permissions": ["core:default", "fs:allow-read-text-file"] },
        \\  { "identifier": "remote-window", "windows": ["main"], "remote": { "urls": ["https://*.example.com"] }, "permissions": ["fs:allow-write-file"] }
        \\]
    ;
    var policy = try Policy.init(testing.allocator, .{
        .files = &.{.{ .file_name = "main.json", .json = file_json }},
        // The inline object adds a deny that must win over `main-window`'s allow.
        .inline_entries = &.{
            .{ .reference = "main-window" },
            .{ .inline_json = try std.json.parseFromSliceLeaky(std.json.Value, json_arena.allocator(),
                \\{"identifier":"no-shell","windows":["main"],"permissions":["fs:deny-write-file"]}
            , .{}) },
        },
    });
    defer policy.deinit();

    // Allowed: a core command through `core:default`, a plugin command by exact id.
    try testing.expect(policy.allows("plugin:window|set_title", "main", "tauri://localhost"));
    try testing.expect(policy.allows("plugin:fs|read_text_file", "main", "tauri://localhost"));
    // Denied: not in any capability, wrong window, or explicitly denied.
    try testing.expect(!policy.allows("plugin:fs|write_file", "main", "tauri://localhost"));
    try testing.expect(!policy.allows("plugin:fs|read_text_file", "settings", "tauri://localhost"));
    try testing.expect(!policy.allows("", "main", "tauri://localhost"));

    // Remote origin only gets the remote capability.
    try testing.expect(policy.allows("plugin:fs|write_file", "main", "https://api.example.com"));
    try testing.expect(!policy.allows("plugin:fs|write_file", "main", "https://evil.test"));

    // Platform filtering is injectable.
    policy.withPlatform(.windows);
    try testing.expect(policy.allows("plugin:fs|read_text_file", "main", "tauri://localhost"));
}

test "policy rejects a dangling capability reference" {
    try testing.expectError(error.UnknownCapability, Policy.init(testing.allocator, .{
        .files = &.{},
        .inline_entries = &.{.{ .reference = "does-not-exist" }},
    }));
}

test "authorizeCtx maps a CallContext to the policy decision" {
    const resolver = struct {
        fn resolve(_: *const rpc.Ctx) ?[]const u8 {
            return "main";
        }
    }.resolve;
    withWindowLabel(resolver);
    defer withWindowLabel(struct {
        fn none(_: *const rpc.Ctx) ?[]const u8 {
            return null;
        }
    }.none);

    var policy = try Policy.init(testing.allocator, .{
        .files = &.{.{ .file_name = "main.json", .json = "{\"identifier\":\"c\",\"windows\":[\"main\"],\"permissions\":[\"fs:allow-read-text-file\"]}" }},
    });
    defer policy.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = rpc.Ctx.init(testing.io, arena.allocator());
    try testing.expect(Policy.authorizeCtx(policy.context(), &ctx, "plugin:fs|read_text_file"));
    try testing.expect(!Policy.authorizeCtx(policy.context(), &ctx, "plugin:fs|write_file"));
}

test "every command of the real core schema maps onto a distinct permission identifier" {
    const mod = @import("mod.zig");
    var buf: [160]u8 = undefined;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| testing.allocator.free(key.*);
        seen.deinit(testing.allocator);
    }

    // `CorePluginsSchema` is the schema `withCorePlugins` ships, so this covers `window`, `event`,
    // `path`, `app`, `resources`, `menu` and `tray` exactly as an app would bind them.
    inline for (mod.CorePluginsSchema.commands) |command| {
        const id = permissionIdFor(command.wire_name, true, false, &buf) orelse {
            std.debug.print("no permission id for {s}\n", .{command.wire_name});
            return error.TestUnexpectedResult;
        };
        try testing.expect(std.mem.startsWith(u8, id, "core:"));
        try testing.expect(std.mem.indexOfScalar(u8, id, '_') == null);
        // Uniqueness: two commands must never share one permission id, or an allow would
        // silently grant a second command.
        try testing.expect(!seen.contains(id));
        try seen.put(testing.allocator, try testing.allocator.dupe(u8, id), {});
    }
    try testing.expect(seen.count() >= 40);
}

test "end to end: an imported tauri project yields a working policy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "tauri.conf.json",
        .data =
        \\{"identifier":"jp.zts.migrated","app":{
        \\  "windows":[{"label":"main"},{"label":"settings"}],
        \\  "security":{"capabilities":["main-window"]}}}
        ,
    });
    try tmp.dir.createDirPath(testing.io, "capabilities");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "capabilities/main-window.json",
        .data =
        \\{"identifier":"main-window","windows":["main"],
        \\ "permissions":["core:default","fs:allow-read-text-file"]}
        ,
    });

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var imported = try config_import.load(testing.allocator, testing.io, dir_path);
    defer imported.deinit();

    var policy = try Policy.fromImported(testing.allocator, &imported);
    defer policy.deinit();

    // `main` gets the referenced capability; `settings` has none → fail-closed.
    try testing.expect(policy.allows("plugin:fs|read_text_file", "main", "tauri://localhost"));
    try testing.expect(policy.allows("plugin:window|set_title", "main", "tauri://localhost"));
    try testing.expect(!policy.allows("plugin:fs|read_text_file", "settings", "tauri://localhost"));
    try testing.expect(!policy.allows("plugin:fs|write_file", "main", "tauri://localhost"));
}
