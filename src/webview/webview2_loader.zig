//! Pure-Zig replacement for Microsoft's `WebView2Loader.dll` (`src/webview/webview2_loader.zig`, `M3-02`).
//!
//! The official WebView2 SDK ships a per-architecture `WebView2Loader.dll` that must sit next to
//! the `.exe`. Z-Ts refuses to ship a second binary: this module locates the already-installed
//! Evergreen runtime through the same registry layout Microsoft's loader uses and calls the export
//! `CreateWebViewEnvironmentWithOptionsInternal` inside
//! `<runtime>\EBWebView\<arch>\EmbeddedBrowserWebView.dll` directly.
//!
//! Search order (mirrors `WebView2Loader`):
//!   1. `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` environment override (fixed-version deployments).
//!   2. `HKCU/HKLM\SOFTWARE\Microsoft\EdgeUpdate\ClientState\{GUID}` → `EBWebView` (authoritative
//!      install path, written by the installer).
//!   3. `HKCU/HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\{GUID}` → `location` + `pv` (legacy).
//!   4. Channel fallback Stable → Beta → Dev → Canary.
//!
//! Everything OS-independent (path shapes, GUIDs, version floor, arch folder) lives in
//! [`windows_util.zig`](windows_util.zig) and is unit-tested on every OS.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const win32 = @import("win32.zig");
const com = @import("webview2_com.zig");
const util = @import("windows_util.zig");

const BOOL = win32.BOOL;
const HMODULE = win32.HMODULE;
const W = win32.W;
const HResult = com.HResult;

/// Signature of `EmbeddedBrowserWebView.dll!CreateWebViewEnvironmentWithOptionsInternal`.
pub const CreateEnvironmentInternalFn = *const fn (
    from_client_dll: BOOL,
    runtime_type: i32,
    user_data_folder: ?W,
    environment_options: ?*anyopaque,
    handler: ?*anyopaque,
) callconv(.winapi) HResult;

pub const RUNTIME_TYPE_INSTALLED: i32 = 0;
pub const RUNTIME_TYPE_FIXED: i32 = 1;

pub const LoadError = error{
    RuntimeNotFound,
    LoadFailed,
    ExportMissing,
    OutOfMemory,
};

pub const Runtime = struct {
    module: HMODULE,
    create: CreateEnvironmentInternalFn,
    /// Human-readable runtime version (`"130.0.2849.68"`), empty when unknown.
    version: [64]u8 = @splat(0),
    version_len: usize = 0,
    /// `true` when the runtime came from a fixed-version folder / env override.
    fixed: bool = false,

    pub fn versionString(self: *const Runtime) []const u8 {
        return self.version[0..self.version_len];
    }

    pub fn deinit(self: *Runtime) void {
        // The client DLL may be unloaded only when it says so (same rule as Microsoft's loader).
        if (win32.GetProcAddress(self.module, "DllCanUnloadNow") == null) return;
        _ = win32.FreeLibrary(self.module);
    }
};

/// Locates, loads and resolves the WebView2 runtime. `allocator` only backs temporary UTF-16
/// conversions; nothing survives the call except the module handle.
pub fn load(allocator: Allocator) LoadError!Runtime {
    var dll_path: [1024]u8 = undefined;
    const resolved = try resolveClientDll(allocator, &dll_path);
    const path = resolved.path;

    const wide = win32.toWide(allocator, path) catch return error.OutOfMemory;
    defer allocator.free(wide);

    const module = win32.LoadLibraryExW(wide.ptr, null, win32.LOAD_WITH_ALTERED_SEARCH_PATH) orelse
        return error.LoadFailed;
    errdefer _ = win32.FreeLibrary(module);

    const proc = win32.GetProcAddress(module, "CreateWebViewEnvironmentWithOptionsInternal") orelse
        return error.ExportMissing;

    var rt: Runtime = .{
        .module = module,
        .create = @ptrCast(@alignCast(proc)),
        .fixed = resolved.fixed,
    };
    if (lastVersionComponent(path, &rt.version)) |n| rt.version_len = n;
    return rt;
}

const Resolved = struct {
    path: []const u8,
    fixed: bool,
};

fn resolveClientDll(allocator: Allocator, out: *[1024]u8) LoadError!Resolved {
    const arch = util.archFolder(builtin.cpu.arch);

    // 1. Fixed-version deployments point straight at the folder that CONTAINS `EBWebView`.
    if (envUtf8(allocator, "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER")) |folder| {
        defer allocator.free(folder);
        if (util.composeClientDll(out, folder, arch) catch null) |path| {
            if (fileExists(allocator, path)) return .{ .path = path, .fixed = true };
        }
    }

    for (util.RuntimeChannel.all) |channel| {
        // 2. ClientState\{GUID}\EBWebView == the install folder itself (written by the installer).
        for ([_]Root{ .current_user, .local_machine }) |root| {
            if (clientStateCandidate(allocator, root, channel, arch, out)) |path| {
                return .{ .path = path, .fixed = false };
            }
            if (clientsCandidate(allocator, root, channel, arch, out)) |path| {
                return .{ .path = path, .fixed = false };
            }
        }
    }
    return error.RuntimeNotFound;
}

fn clientStateCandidate(
    allocator: Allocator,
    root: Root,
    channel: util.RuntimeChannel,
    arch: []const u8,
    out: *[1024]u8,
) ?[]const u8 {
    var key_buf: [256]u8 = undefined;
    const key = util.clientStateKey(&key_buf, channel) catch return null;
    const folder = readRegString(allocator, root, key, "EBWebView") orelse return null;
    defer allocator.free(folder);
    const path = util.composeClientDll(out, folder, arch) catch return null;
    return if (fileExists(allocator, path)) path else null;
}

fn clientsCandidate(
    allocator: Allocator,
    root: Root,
    channel: util.RuntimeChannel,
    arch: []const u8,
    out: *[1024]u8,
) ?[]const u8 {
    var key_buf: [256]u8 = undefined;
    const key = util.clientsKey(&key_buf, channel) catch return null;
    const location = readRegString(allocator, root, key, "location") orelse return null;
    defer allocator.free(location);
    const version = readRegString(allocator, root, key, "pv") orelse return null;
    defer allocator.free(version);
    if (!util.isCompatibleRuntime(version)) return null;
    const path = util.composeVersionedClientDll(out, location, version, arch) catch return null;
    return if (fileExists(allocator, path)) path else null;
}

fn lastVersionComponent(path: []const u8, out: *[64]u8) ?usize {
    // path = ...\<version>\EBWebView\<arch>\EmbeddedBrowserWebView.dll
    var end = path.len;
    var seen: usize = 0;
    while (seen < 3) : (seen += 1) {
        end = std.mem.lastIndexOfScalar(u8, path[0..end], '\\') orelse return null;
    }
    const start = end + 1;
    const seg_end = std.mem.indexOfScalarPos(u8, path, start, '\\') orelse return null;
    const seg = path[start..seg_end];
    if (seg.len == 0 or seg.len > out.len) return null;
    @memcpy(out[0..seg.len], seg);
    return seg.len;
}

const Root = enum {
    current_user,
    local_machine,

    fn hkey(self: Root) win32.HKEY {
        return switch (self) {
            .current_user => win32.HKEY_CURRENT_USER,
            .local_machine => win32.HKEY_LOCAL_MACHINE,
        };
    }
};

fn fileExists(allocator: Allocator, path: []const u8) bool {
    const wide = win32.toWide(allocator, path) catch return false;
    defer allocator.free(wide);
    return win32.GetFileAttributesW(wide.ptr) != win32.INVALID_FILE_ATTRIBUTES;
}

fn envUtf8(allocator: Allocator, name: []const u8) ?[]u8 {
    const name_z = win32.toWide(allocator, name) catch return null;
    defer allocator.free(name_z);

    var buf: [1024]u16 = undefined;
    const len = win32.GetEnvironmentVariableW(name_z.ptr, &buf, buf.len);
    if (len == 0 or len >= buf.len) return null;
    buf[len] = 0;
    return win32.fromWide(allocator, @ptrCast(&buf), false) catch null;
}

/// Reads a `REG_SZ`/`REG_EXPAND_SZ` value as UTF-8. Returns `null` for any failure — the loader
/// treats "missing" and "unreadable" identically, exactly like Microsoft's loader.
fn readRegString(allocator: Allocator, root: Root, key_path: []const u8, value_name: []const u8) ?[]u8 {
    const key_z = win32.toWide(allocator, key_path) catch return null;
    defer allocator.free(key_z);
    const value_z = win32.toWide(allocator, value_name) catch return null;
    defer allocator.free(value_z);

    var key: ?win32.HKEY = null;
    if (win32.RegOpenKeyExW(root.hkey(), key_z.ptr, 0, win32.KEY_QUERY_VALUE, &key) != win32.ERROR_SUCCESS) {
        return null;
    }
    defer _ = win32.RegCloseKey(key.?);

    var buf: [2048]u8 align(@alignOf(u16)) = undefined;
    var size: u32 = buf.len;
    var kind: u32 = 0;
    if (win32.RegQueryValueExW(key.?, value_z.ptr, null, &kind, &buf, &size) != win32.ERROR_SUCCESS) return null;
    if (kind != win32.REG_SZ and kind != win32.REG_EXPAND_SZ) return null;
    if (size < 2) return null;

    const units: [*:0]const u16 = @ptrCast(@alignCast(&buf));
    const utf8 = win32.fromWide(allocator, units, false) catch return null;
    defer allocator.free(utf8);

    // Trim trailing separators so path composition never produces `\\` or `\`.
    var end = utf8.len;
    while (end > 0 and (utf8[end - 1] == '\\' or utf8[end - 1] == '/')) end -= 1;
    return allocator.dupe(u8, utf8[0..end]) catch null;
}

test "lastVersionComponent extracts <version> from a runtime DLL path" {
    var out: [64]u8 = undefined;
    const n = lastVersionComponent(
        "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\130.0.2849.68\\EBWebView\\x64\\EmbeddedBrowserWebView.dll",
        &out,
    ).?;
    try std.testing.expectEqualStrings("130.0.2849.68", out[0..n]);

    try std.testing.expect(lastVersionComponent("short.dll", &out) == null);
    // A <version> segment longer than the 64-byte buffer must be rejected, not truncated.
    var huge: [64]u8 = undefined;
    try std.testing.expect(lastVersionComponent("a\\b\\c\\" ++ "999999999999999999999999999999999999999999999999999999999999999999" ++ "\\x\\y.dll", &huge) == null);
}

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("webview2_loader.zig is Windows-only");
    }
}
