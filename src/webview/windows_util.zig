//! Pure (OS-independent) Windows-backend helpers (`src/webview/windows_util.zig`, `M3-02`).
//!
//! Everything in this file is plain Zig with **zero** Win32 imports, so the rules that are easiest
//! to get subtly wrong — WebView2 runtime discovery paths, `tauri://` ↔ `http://*.localhost`
//! translation, percent-free URL classification, DPI scaling — are unit-tested on Linux and macOS
//! CI as well. `windows.zig` / `webview2_loader.zig` are thin shells around these functions.
//!
//! Why the URL rewrite exists at all: WebView2 (Chromium) refuses to load documents from arbitrary
//! custom schemes, so Tauri — and therefore Z-Ts — serve the app from
//! `http://tauri.localhost/` / `http://ipc.localhost/` / `http://asset.localhost/` on Windows and
//! intercept those requests in `WebResourceRequested`. `zts_tauri.ProtocolRouter.classifyUri`
//! already understands both spellings, so nothing above this layer is Windows-aware.

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Runtime discovery
// ---------------------------------------------------------------------------

/// Edge/WebView2 release channels, most stable first (`WebView2Loader` iterates 0..n).
pub const RuntimeChannel = struct {
    /// `{GUID}` under `SOFTWARE\Microsoft\EdgeUpdate\Clients\` and `...\ClientState\`.
    id: []const u8,
    /// Suffix appended to the reported version (`""` for Stable).
    name: []const u8,
    /// MSIX package family name (packaged runtimes).
    package_family: []const u8,

    pub const all = [_]RuntimeChannel{
        .{ .id = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", .name = "", .package_family = "Microsoft.WebView2Runtime.Stable_8wekyb3d8bbwe" },
        .{ .id = "{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}", .name = "beta", .package_family = "Microsoft.WebView2Runtime.Beta_8wekyb3d8bbwe" },
        .{ .id = "{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}", .name = "dev", .package_family = "Microsoft.WebView2Runtime.Dev_8wekyb3d8bbwe" },
        .{ .id = "{65C35B14-6C1D-4122-AC46-7148CC9D6497}", .name = "canary", .package_family = "Microsoft.WebView2Runtime.Canary_8wekyb3d8bbwe" },
    };
};

/// Oldest WebView2 runtime this backend is willing to drive (`WebView2Loader` uses the same floor).
pub const min_runtime_version: [4]u32 = .{ 86, 0, 616, 0 };

/// `x64` / `arm64` / `x86` — the folder name inside `<runtime>\EBWebView\`.
pub fn archFolder(cpu: std.Target.Cpu.Arch) []const u8 {
    return switch (cpu) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "x86",
        else => "x64", // unreachable in practice; keeps the loader total
    };
}

/// `SOFTWARE\Microsoft\EdgeUpdate\ClientState\{GUID}` (the value `EBWebView` is authoritative).
pub fn clientStateKey(buf: []u8, channel: RuntimeChannel) ![]const u8 {
    return std.fmt.bufPrint(buf, "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{s}", .{channel.id});
}

/// `SOFTWARE\Microsoft\EdgeUpdate\Clients\{GUID}` (values `pv` + `location`).
pub fn clientsKey(buf: []u8, channel: RuntimeChannel) ![]const u8 {
    return std.fmt.bufPrint(buf, "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{s}", .{channel.id});
}

/// `<folder>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`
pub fn composeClientDll(buf: []u8, folder: []const u8, arch: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}\\EBWebView\\{s}\\EmbeddedBrowserWebView.dll", .{ folder, arch });
}

/// `<location>\<version>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`
pub fn composeVersionedClientDll(
    buf: []u8,
    location: []const u8,
    version: []const u8,
    arch: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s}\\{s}\\EBWebView\\{s}\\EmbeddedBrowserWebView.dll",
        .{ location, version, arch },
    );
}

/// Default user-data folder: `<exe path>.WebView2` (identical to Microsoft's loader default).
pub fn defaultUserDataFolder(buf: []u8, exe_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.WebView2", .{exe_path});
}

/// Parses `a.b.c.d` (trailing components optional, non-numeric stops parsing).
pub fn parseVersion(text: []const u8) ?[4]u32 {
    var out: [4]u32 = .{ 0, 0, 0, 0 };
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part_raw| {
        if (idx >= 4) break;
        var digits: usize = 0;
        var value: u32 = 0;
        for (part_raw) |c| {
            if (c < '0' or c > '9') break;
            value = value *| 10 +| (c - '0');
            digits += 1;
        }
        if (digits == 0) break;
        out[idx] = value;
        idx += 1;
    }
    if (idx == 0) return null;
    return out;
}

/// `version >= 86.0.616.0`
pub fn isCompatibleRuntime(version_text: []const u8) bool {
    const v = parseVersion(version_text) orelse return false;
    for (v, min_runtime_version) |got, min| {
        if (got != min) return got > min;
    }
    return true;
}

// ---------------------------------------------------------------------------
// `tauri://` <-> `http://*.localhost` (WebView2 custom-scheme workaround)
// ---------------------------------------------------------------------------

pub const Protocol = enum { tauri, ipc, asset };

fn matchProtocol(scheme: []const u8) ?Protocol {
    if (std.ascii.eqlIgnoreCase(scheme, "tauri")) return .tauri;
    if (std.ascii.eqlIgnoreCase(scheme, "ipc")) return .ipc;
    if (std.ascii.eqlIgnoreCase(scheme, "asset")) return .asset;
    return null;
}

/// Returns the protocol when `uri` targets one of Z-Ts' built-in origins, in **either** spelling
/// (`tauri://localhost/...` or `http://tauri.localhost/...`).
pub fn classify(uri: []const u8) ?Protocol {
    const sep = std.mem.indexOf(u8, uri, "://") orelse return null;
    const scheme = uri[0..sep];
    const rest = uri[sep + 3 ..];
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..host_end];

    if (matchProtocol(scheme)) |p| {
        if (std.ascii.eqlIgnoreCase(host, "localhost") or host.len == 0) return p;
        return null;
    }
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        if (std.ascii.eqlIgnoreCase(host, "tauri.localhost")) return .tauri;
        if (std.ascii.eqlIgnoreCase(host, "ipc.localhost")) return .ipc;
        if (std.ascii.eqlIgnoreCase(host, "asset.localhost")) return .asset;
    }
    return null;
}

/// Rewrites a Z-Ts URL into the WebView2-loadable form. Non-Z-Ts URLs (https://…, about:blank,
/// data:) are copied verbatim so `navigate()` keeps working for external sites.
pub fn toWebView2Url(buf: []u8, url: []const u8) ![]const u8 {
    const split = splitOrigin(url);
    const p = split.protocol orelse {
        if (url.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..url.len], url);
        return buf[0..url.len];
    };
    const tail = if (split.rest.len == 0) "/" else split.rest;
    return std.fmt.bufPrint(buf, "http://{s}.localhost{s}", .{ @tagName(p), tail });
}

const UrlSplit = struct {
    protocol: ?Protocol,
    /// Everything after `scheme://host`, starting at `/` (empty when the URL has no path).
    rest: []const u8,
};

fn splitOrigin(url: []const u8) UrlSplit {
    const p = classify(url) orelse return .{ .protocol = null, .rest = url };
    const sep = std.mem.indexOf(u8, url, "://").?;
    const after = url[sep + 3 ..];
    const host_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    return .{ .protocol = p, .rest = after[host_end..] };
}

/// `http://<protocol>.localhost/*` filter string for `AddWebResourceRequestedFilter`.
pub fn filterPattern(buf: []u8, p: Protocol) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://{s}.localhost/*", .{@tagName(p)});
}

// ---------------------------------------------------------------------------
// DPI (Per-Monitor v2): CSS logical pixels <-> physical device pixels
// ---------------------------------------------------------------------------

pub const base_dpi: u32 = 96;

/// `dpi` is `GetDpiForWindow(hwnd)` (96 = 100 %, 144 = 150 %, 192 = 200 %).
pub fn scaleFactor(dpi: u32) f64 {
    const d = if (dpi == 0) base_dpi else dpi;
    return @as(f64, @floatFromInt(d)) / @as(f64, @floatFromInt(base_dpi));
}

/// CSS `WxH` -> device pixels (what `CreateWindowExW` / `put_Bounds` expect).
pub fn logicalToPhysical(px: f64, dpi: u32) i32 {
    if (!std.math.isFinite(px)) return 0;
    const scaled = px * scaleFactor(dpi);
    if (scaled > 1_000_000.0) return 1_000_000;
    if (scaled < -1_000_000.0) return -1_000_000;
    return @intFromFloat(@round(scaled));
}

/// Device pixels -> CSS logical pixels (what `setSize` / `screenVisibleFrame` report).
pub fn physicalToLogical(px: i32, dpi: u32) f64 {
    return @as(f64, @floatFromInt(px)) / scaleFactor(dpi);
}

// ---------------------------------------------------------------------------
// Tests (run on Linux AND Windows CI)
// ---------------------------------------------------------------------------

test "archFolder maps the three runtime layouts" {
    try testing.expectEqualStrings("x64", archFolder(.x86_64));
    try testing.expectEqualStrings("arm64", archFolder(.aarch64));
    try testing.expectEqualStrings("x86", archFolder(.x86));
}

test "runtime paths match WebView2Loader's layout" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68\\EBWebView\\x64\\EmbeddedBrowserWebView.dll",
        try composeClientDll(
            &buf,
            "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68",
            "x64",
        ),
    );
    try testing.expectEqualStrings(
        "D:\\runtime\\EBWebView\\arm64\\EmbeddedBrowserWebView.dll",
        try composeClientDll(&buf, "D:\\runtime", "arm64"),
    );
    try testing.expectEqualStrings(
        "C:\\loc\\1.2.3\\EBWebView\\x64\\EmbeddedBrowserWebView.dll",
        try composeVersionedClientDll(&buf, "C:\\loc", "1.2.3", "x64"),
    );
    try testing.expectEqualStrings(
        "C:\\app\\counter.exe.WebView2",
        try defaultUserDataFolder(&buf, "C:\\app\\counter.exe"),
    );
}

test "registry keys carry the channel GUIDs verbatim" {
    var buf: [256]u8 = undefined;
    const stable = RuntimeChannel.all[0];
    try testing.expectEqualStrings(
        "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        try clientStateKey(&buf, stable),
    );
    try testing.expectEqualStrings(
        "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        try clientsKey(&buf, stable),
    );
    try testing.expectEqualStrings("beta", RuntimeChannel.all[1].name);
    try testing.expectEqualStrings("canary", RuntimeChannel.all[3].name);
}

test "version parsing & compatibility floor" {
    try testing.expectEqual([4]u32{ 130, 0, 2849, 68 }, parseVersion("130.0.2849.68").?);
    try testing.expectEqual([4]u32{ 130, 0, 0, 0 }, parseVersion("130").?);
    try testing.expectEqual([4]u32{ 130, 0, 2849, 68 }, parseVersion("130.0.2849.68 beta").?);
    try testing.expect(parseVersion("") == null);
    try testing.expect(parseVersion("beta") == null);

    try testing.expect(!isCompatibleRuntime("85.0.999.99"));
    try testing.expect(isCompatibleRuntime("86.0.616.0"));
    try testing.expect(isCompatibleRuntime("86.0.617.0"));
    try testing.expect(isCompatibleRuntime("130.0.2849.68"));
    try testing.expect(!isCompatibleRuntime("0.0.0.0"));
    try testing.expect(!isCompatibleRuntime("garbage"));
}

test "classify recognises both Z-Ts URL spellings and rejects look-alikes" {
    try testing.expectEqual(Protocol.tauri, classify("tauri://localhost/index.html").?);
    try testing.expectEqual(Protocol.tauri, classify("http://tauri.localhost/index.html").?);
    try testing.expectEqual(Protocol.tauri, classify("https://TAURI.localhost/").?);
    try testing.expectEqual(Protocol.ipc, classify("ipc://localhost/plugin%3Awindow%7Cset_title").?);
    try testing.expectEqual(Protocol.ipc, classify("http://ipc.localhost/plugin%3Aapp%7Cversion").?);
    try testing.expectEqual(Protocol.asset, classify("asset://localhost/C%3A%5Cfoo.png").?);
    try testing.expectEqual(Protocol.asset, classify("http://asset.localhost/C%3A%5Cfoo.png").?);

    try testing.expect(classify("https://example.com/") == null);
    try testing.expect(classify("tauri://evil.example/") == null);
    try testing.expect(classify("http://ipc.localhost.evil.example/") == null);
    try testing.expect(classify("about:blank") == null);
    try testing.expect(classify("data:text/html,hi") == null);
    try testing.expect(classify("") == null);
}

test "toWebView2Url rewrites Z-Ts origins and keeps everything else byte-identical" {
    var buf: [512]u8 = undefined;

    try testing.expectEqualStrings(
        "http://tauri.localhost/",
        try toWebView2Url(&buf, "tauri://localhost/"),
    );
    try testing.expectEqualStrings(
        "http://tauri.localhost/",
        try toWebView2Url(&buf, "tauri://localhost"),
    );
    try testing.expectEqualStrings(
        "http://tauri.localhost/deep/route?x=1",
        try toWebView2Url(&buf, "tauri://localhost/deep/route?x=1"),
    );
    try testing.expectEqualStrings(
        "http://ipc.localhost/plugin%3Aevent%7Clisten",
        try toWebView2Url(&buf, "ipc://localhost/plugin%3Aevent%7Clisten"),
    );
    try testing.expectEqualStrings(
        "http://asset.localhost/C%3A%5Ctmp%5Ca.png",
        try toWebView2Url(&buf, "asset://localhost/C%3A%5Ctmp%5Ca.png"),
    );
    // Already-rewritten URLs must stay untouched (idempotent).
    try testing.expectEqualStrings(
        "http://tauri.localhost/index.html",
        try toWebView2Url(&buf, "http://tauri.localhost/index.html"),
    );
    for ([_][]const u8{
        "https://example.com/a?b=c",
        "about:blank",
        "data:text/html,<b>hi</b>",
        "file:///C:/app/index.html",
    }) |url| {
        try testing.expectEqualStrings(url, try toWebView2Url(&buf, url));
    }
}

test "filterPattern builds the wildcard WebResourceRequested filters" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("http://tauri.localhost/*", try filterPattern(&buf, .tauri));
    try testing.expectEqualStrings("http://ipc.localhost/*", try filterPattern(&buf, .ipc));
    try testing.expectEqualStrings("http://asset.localhost/*", try filterPattern(&buf, .asset));
}

test "DPI scaling: 100/125/150/200 % and negative coordinates" {
    try testing.expectEqual(@as(f64, 1.0), scaleFactor(96));
    try testing.expectEqual(@as(f64, 1.25), scaleFactor(120));
    try testing.expectEqual(@as(f64, 1.5), scaleFactor(144));
    try testing.expectEqual(@as(f64, 2.0), scaleFactor(192));
    try testing.expectEqual(@as(f64, 1.0), scaleFactor(0)); // defensive: 0 DPI == 100 %

    try testing.expectEqual(@as(i32, 800), logicalToPhysical(800, 96));
    try testing.expectEqual(@as(i32, 1000), logicalToPhysical(800, 120));
    try testing.expectEqual(@as(i32, 1200), logicalToPhysical(800, 144));
    try testing.expectEqual(@as(i32, 1600), logicalToPhysical(800, 192));
    try testing.expectEqual(@as(i32, -160), logicalToPhysical(-80, 192));
    try testing.expectEqual(@as(i32, 0), logicalToPhysical(std.math.nan(f64), 96));

    try testing.expectEqual(@as(f64, 800.0), physicalToLogical(1600, 192));
    try testing.expectEqual(@as(f64, 800.0), physicalToLogical(1200, 144));
    // Round trip at every supported scale.
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        const phys = logicalToPhysical(123.0, dpi);
        try testing.expect(@abs(physicalToLogical(phys, dpi) - 123.0) < 0.5);
    }
}
