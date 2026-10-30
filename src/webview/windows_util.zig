//! OS-independent WebView2 helpers (`src/webview/windows_util.zig`, `M3-02`).
//!
//! Everything in this file is **pure Zig with zero Win32 imports**, so the tricky parts of the
//! Windows backend — runtime discovery paths, version floors, `http://<proto>.localhost` URL
//! rewriting, DPI math — are unit-tested on Linux and macOS CI as well as on Windows.
//!
//! The rules encoded here mirror Microsoft's `WebView2Loader` (see `webview2_loader.zig`) and
//! `vendor/wry/src/webview2/mod.rs`.

const std = @import("std");
const builtin = @import("builtin");

/// Microsoft's Evergreen channel ids, from `WebView2Loader.cpp` / wry.
pub const RuntimeChannel = struct {
    /// Channel name as Microsoft spells it (`stable`, `beta`, `dev`, `canary`).
    name: []const u8,
    /// Registry key under `…\EdgeUpdate\Clients` that holds the version.
    guid: []const u8,
    /// MSIX package family name, used when the runtime came from the Store.
    package_family: []const u8,

    /// Every channel, in the order the loader probes them.
    pub const all = [_]RuntimeChannel{
        .{
            .name = "stable",
            .guid = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
            .package_family = "Microsoft.WebView2Runtime.Stable_8wekyb3d8bbwe",
        },
        .{
            .name = "beta",
            .guid = "{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}",
            .package_family = "Microsoft.WebView2Runtime.Beta_8wekyb3d8bbwe",
        },
        .{
            .name = "dev",
            .guid = "{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}",
            .package_family = "Microsoft.WebView2Runtime.Dev_8wekyb3d8bbwe",
        },
        .{
            .name = "canary",
            .guid = "{65C35B14-6C1D-4122-AC46-7148CC9D6497}",
            .package_family = "Microsoft.WebView2Runtime.Canary_8wekyb3d8bbwe",
        },
    };
};

/// Oldest runtime that is still supported by Microsoft and implements every interface we use.
pub const min_runtime_version = Version{ .major = 86, .minor = 0, .build = 616, .patch = 0 };

pub const Version = struct {
    /// Major version.
    major: u32 = 0,
    /// Minor version.
    minor: u32 = 0,
    /// Build number.
    build: u32 = 0,
    /// Patch number.
    patch: u32 = 0,

    /// Lexicographic comparison, most significant field first.
    pub fn order(a: Version, b: Version) std.math.Order {
        const keys = [_][2]u32{
            .{ a.major, b.major }, .{ a.minor, b.minor },
            .{ a.build, b.build }, .{ a.patch, b.patch },
        };
        for (keys) |pair| {
            if (pair[0] < pair[1]) return .lt;
            if (pair[0] > pair[1]) return .gt;
        }
        return .eq;
    }

    /// Whether this version is `floor` or newer.
    pub fn atLeast(self: Version, floor: Version) bool {
        return self.order(floor) != .lt;
    }
};

/// `"130.0.2849.68"` → `Version`. Extra components are ignored, missing ones become 0.
pub fn parseVersion(text: []const u8) ?Version {
    var out = Version{};
    var fields = std.mem.splitScalar(u8, text, '.');
    var index: usize = 0;
    while (fields.next()) |field| {
        if (index >= 4) break;
        if (field.len == 0) return null;
        const value = std.fmt.parseUnsigned(u32, field, 10) catch return null;
        switch (index) {
            0 => out.major = value,
            1 => out.minor = value,
            2 => out.build = value,
            else => out.patch = value,
        }
        index += 1;
    }
    if (index == 0) return null;
    return out;
}

pub fn isCompatibleRuntime(version_text: []const u8) bool {
    const v = parseVersion(version_text) orelse return false;
    return v.atLeast(min_runtime_version);
}

/// `EBWebView\<arch>\EmbeddedBrowserWebView.dll` — the only file we ever load.
pub const client_dll_leaf = "EmbeddedBrowserWebView.dll";

pub fn archFolder(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => "x64",
    };
}

/// `SOFTWARE\Microsoft\EdgeUpdate\ClientState\{GUID}` — the installer writes `EBWebView` here.
pub fn clientStateKey(buf: []u8, channel: RuntimeChannel) ![]const u8 {
    return std.fmt.bufPrint(buf, "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{s}", .{channel.guid});
}

/// `SOFTWARE\Microsoft\EdgeUpdate\Clients\{GUID}` — `location` + `pv` fallback for older installs.
pub fn clientsKey(buf: []u8, channel: RuntimeChannel) ![]const u8 {
    return std.fmt.bufPrint(buf, "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{s}", .{channel.guid});
}

/// `<application_folder>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`
pub fn composeClientDll(buf: []u8, application_folder: []const u8, arch: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}\\EBWebView\\{s}\\{s}", .{ application_folder, arch, client_dll_leaf });
}

/// `<staging_folder>\<arch>\EmbeddedBrowserWebView.dll` — the shape used when the `ClientState`
/// value already names the `EBWebView` staging folder (`…\Application\130.0.2849.68\EBWebView`).
pub fn composeStagedClientDll(buf: []u8, staging_folder: []const u8, arch: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}\\{s}\\{s}", .{ staging_folder, arch, client_dll_leaf });
}

/// `<location>\<version>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`
pub fn composeVersionedClientDll(
    buf: []u8,
    location: []const u8,
    version: []const u8,
    arch: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}\\{s}\\EBWebView\\{s}\\{s}", .{ location, version, arch, client_dll_leaf });
}

/// Scans up to four trailing components of an install path for one that parses as a compatible
/// runtime version. Both `ClientState` shapes are covered:
/// `…\Application\130.0.2849.68` → `130.0.2849.68`, and
/// `…\Application\130.0.2849.68\EBWebView` → `130.0.2849.68`.
pub fn versionFromPath(path: []const u8) ?[]const u8 {
    var rest = path;
    var depth: usize = 0;
    while (depth < 4) : (depth += 1) {
        const component = lastPathComponent(rest);
        if (component.len == 0) return null;
        if (isCompatibleRuntime(component)) return component;
        const slash = std.mem.lastIndexOfAny(u8, rest, "\\/") orelse return null;
        if (slash == 0) return null;
        rest = rest[0..slash];
    }
    return null;
}

/// Last component of a Windows path (`...\Application\130.0.2849.68` → `130.0.2849.68`).
pub fn lastPathComponent(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    const start = std.mem.lastIndexOfAny(u8, path[0..end], "\\/") orelse 0;
    const begin = if (start == 0 and (path.len == 0 or (path[0] != '\\' and path[0] != '/'))) 0 else start + 1;
    return path[begin..end];
}

/// Default user-data folder: `<exe_dir>\.WebView2` (wry uses the same shape).
pub fn defaultUserDataFolder(buf: []u8, exe_dir: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}\\.WebView2", .{exe_dir});
}

// ---------------------------------------------------------------------------
// Custom protocol → http(s) origin mapping
// ---------------------------------------------------------------------------

/// The three virtual origins Z-Ts serves through `WebResourceRequested`.
pub const Protocol = enum { tauri, ipc, asset };

pub fn protocolFromScheme(scheme: []const u8) ?Protocol {
    if (std.ascii.eqlIgnoreCase(scheme, "tauri")) return .tauri;
    if (std.ascii.eqlIgnoreCase(scheme, "ipc")) return .ipc;
    if (std.ascii.eqlIgnoreCase(scheme, "asset")) return .asset;
    return null;
}

/// WebView2 has no custom-scheme API, so `tauri://localhost/x` is served as
/// `http://tauri.localhost/x` (the same workaround wry/Tauri use). Non-Z-Ts URLs
/// (`https://…`, `about:blank`, `data:`) are copied byte-for-byte.
pub fn toWebView2Url(buf: []u8, url: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return copy(buf, url);
    const scheme = url[0..scheme_end];
    const protocol = protocolFromScheme(scheme) orelse return copy(buf, url);

    const rest = url[scheme_end + 3 ..];
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..host_end];
    if (!std.ascii.eqlIgnoreCase(host, "localhost") and host.len != 0) return copy(buf, url);

    const path = rest[host_end..];
    return std.fmt.bufPrint(buf, "http://{s}.localhost{s}", .{
        @tagName(protocol),
        if (path.len == 0) "/" else path,
    });
}

fn copy(buf: []u8, text: []const u8) ![]const u8 {
    if (text.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

/// `http://<protocol>.localhost/*` — the wildcard passed to `AddWebResourceRequestedFilter`.
pub fn filterPattern(buf: []u8, protocol: Protocol) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://{s}.localhost/*", .{@tagName(protocol)});
}

/// The `Origin` a page loaded from `url` will report (`tauri://localhost/` → `http://tauri.localhost`).
pub fn originOf(buf: []u8, url: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return copy(buf, url);
    const protocol = protocolFromScheme(url[0..scheme_end]) orelse return copy(buf, url);
    return std.fmt.bufPrint(buf, "http://{s}.localhost", .{@tagName(protocol)});
}

// ---------------------------------------------------------------------------
// DPI (Per-Monitor v2): CSS logical pixels ↔ physical device pixels
// ---------------------------------------------------------------------------

pub const base_dpi: u32 = 96;

/// `GetDpiForWindow` returns 96 / 120 / 144 / 192 for 100 % / 125 % / 150 % / 200 %.
pub fn scaleFactor(dpi: u32) f64 {
    const d = if (dpi == 0) base_dpi else dpi;
    return @as(f64, @floatFromInt(d)) / @as(f64, @floatFromInt(base_dpi));
}

pub fn logicalToPhysical(px: f64, dpi: u32) i32 {
    if (!std.math.isFinite(px)) return 0;
    const scaled = px * scaleFactor(dpi);
    if (scaled > 1_000_000.0) return 1_000_000;
    if (scaled < -1_000_000.0) return -1_000_000;
    return @intFromFloat(@round(scaled));
}

pub fn physicalToLogical(px: i32, dpi: u32) f64 {
    return @as(f64, @floatFromInt(px)) / scaleFactor(dpi);
}

// ---------------------------------------------------------------------------
// Tests (these run on every OS — that is the whole point of this module)
// ---------------------------------------------------------------------------

test "channel table matches Microsoft's loader" {
    try std.testing.expectEqual(@as(usize, 4), RuntimeChannel.all.len);
    try std.testing.expectEqualStrings("{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", RuntimeChannel.all[0].guid);
    try std.testing.expectEqualStrings("{65C35B14-6C1D-4122-AC46-7148CC9D6497}", RuntimeChannel.all[3].guid);
}

test "registry keys and client DLL composition" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        try clientStateKey(&buf, RuntimeChannel.all[0]),
    );
    try std.testing.expectEqualStrings(
        "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        try clientsKey(&buf, RuntimeChannel.all[0]),
    );
    try std.testing.expectEqualStrings(
        "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68" ++
            "\\EBWebView\\x64\\EmbeddedBrowserWebView.dll",
        try composeClientDll(
            &buf,
            "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68",
            archFolder(.x86_64),
        ),
    );
    try std.testing.expectEqualStrings(
        "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68" ++
            "\\EBWebView\\x64\\EmbeddedBrowserWebView.dll",
        try composeStagedClientDll(
            &buf,
            "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68\\EBWebView",
            archFolder(.x86_64),
        ),
    );
    try std.testing.expectEqualStrings("arm64", archFolder(.aarch64));
    try std.testing.expectEqualStrings("x86", archFolder(.x86));
}

test "versionFromPath finds the version through both ClientState folder shapes" {
    // The installer writes `EBWebView` (a staging folder) on some channels and the plain
    // application folder on others; both must yield the same version.
    try std.testing.expectEqualStrings(
        "130.0.2849.68",
        versionFromPath("C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68\\EBWebView").?,
    );
    try std.testing.expectEqualStrings(
        "130.0.2849.68",
        versionFromPath("C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68").?,
    );
    try std.testing.expectEqualStrings(
        "130.0.2849.68",
        versionFromPath("C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68\\EBWebView\\").?,
    );
    // Too old (below the 86.0.616.0 floor) or not a path with a version at all.
    try std.testing.expect(versionFromPath("C:\\EdgeWebView\\Application\\80.0.361.66") == null);
    try std.testing.expect(versionFromPath("C:\\EdgeWebView\\Application\\EBWebView") == null);
}

test "version parsing and the 86.0.616.0 floor" {
    const v = parseVersion("130.0.2849.68").?;
    try std.testing.expectEqual(@as(u32, 130), v.major);
    try std.testing.expectEqual(@as(u32, 68), v.patch);
    try std.testing.expect(v.atLeast(min_runtime_version));

    try std.testing.expect(!isCompatibleRuntime("85.0.564.0"));
    try std.testing.expect(isCompatibleRuntime("86.0.616.0"));
    try std.testing.expect(!isCompatibleRuntime("garbage"));
    try std.testing.expect(parseVersion("1").?.atLeast(min_runtime_version) == false);
}

test "lastPathComponent handles trailing separators and drive roots" {
    try std.testing.expectEqualStrings(
        "130.0.2849.68",
        lastPathComponent("C:\\Program Files\\EdgeWebView\\Application\\130.0.2849.68\\"),
    );
    try std.testing.expectEqualStrings("x64", lastPathComponent("C:/a/b/x64"));
    try std.testing.expectEqualStrings("a", lastPathComponent("a"));
    try std.testing.expectEqualStrings("", lastPathComponent(""));
}

test "toWebView2Url rewrites the three virtual origins and leaves everything else alone" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("http://tauri.localhost/index.html", try toWebView2Url(&buf, "tauri://localhost/index.html"));
    try std.testing.expectEqualStrings("http://ipc.localhost/invoke", try toWebView2Url(&buf, "ipc://localhost/invoke"));
    try std.testing.expectEqualStrings("http://asset.localhost/a/b.png", try toWebView2Url(&buf, "asset://localhost/a/b.png"));
    try std.testing.expectEqualStrings("http://tauri.localhost/", try toWebView2Url(&buf, "tauri://localhost"));
    try std.testing.expectEqualStrings("https://example.com/x", try toWebView2Url(&buf, "https://example.com/x"));
    try std.testing.expectEqualStrings("about:blank", try toWebView2Url(&buf, "about:blank"));
    try std.testing.expectEqualStrings("tauri://evil.example/x", try toWebView2Url(&buf, "tauri://evil.example/x"));
    try std.testing.expectEqualStrings("http://tauri.localhost/x", try toWebView2Url(&buf, "http://tauri.localhost/x"));
}

test "originOf and filterPattern use the same host spelling as the JS bootstrap" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("http://tauri.localhost", try originOf(&buf, "tauri://localhost/index.html"));
    try std.testing.expectEqualStrings("http://ipc.localhost/*", try filterPattern(&buf, .ipc));
    try std.testing.expectEqualStrings("http://asset.localhost/*", try filterPattern(&buf, .asset));
}

test "DPI scaling at 100/125/150/200 % and negative coordinates" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), scaleFactor(96), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), scaleFactor(120), 1e-9);
    try std.testing.expectEqual(@as(i32, 250), logicalToPhysical(200, 120));
    try std.testing.expectEqual(@as(i32, -120), logicalToPhysical(-80, 144));
    try std.testing.expectApproxEqAbs(@as(f64, 200.0), physicalToLogical(300, 144), 1e-9);
    try std.testing.expectEqual(@as(f64, 1.0), scaleFactor(0));
}

comptime {
    _ = builtin;
}
