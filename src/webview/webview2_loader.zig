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
//!      install path, written by the installer; read with `KEY_WOW64_32KEY`, like the SDK).
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

/// Signature of `EmbeddedBrowserWebView.dll!CreateWebViewEnvironmentWithOptionsInternal`.
pub const CreateEnvironmentInternalFn = *const fn (
    from_client_dll: BOOL,
    runtime_type: i32,
    user_data_folder: ?W,
    environment_options: ?*anyopaque,
    handler: ?*anyopaque,
) callconv(win32.CC) com.HResult;

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
    version: []u8,
    fixed: bool,

    pub fn versionString(self: *const Runtime) []const u8 {
        return self.version;
    }

    pub fn deinit(self: *Runtime, allocator: Allocator) void {
        if (self.version.len > 0) allocator.free(self.version);
        // The client DLL may be unloaded only when it says so (same rule as Microsoft's loader).
        if (win32.GetProcAddress(self.module, "DllCanUnloadNow") == null) return;
        _ = win32.FreeLibrary(self.module);
    }
};

/// Locates, loads and resolves the WebView2 runtime. `allocator` backs the returned version string.
pub fn load(allocator: Allocator) LoadError!Runtime {
    const found = try findClientDll(allocator);

    const wide = win32.toWide(allocator, found.path) catch return error.OutOfMemory;
    defer allocator.free(wide);

    const module = win32.LoadLibraryExW(wide.ptr, null, win32.LOAD_WITH_ALTERED_SEARCH_PATH) orelse {
        std.debug.print("zts: LoadLibraryExW failed ({d}) for {s}\n", .{ win32.GetLastError(), found.path });
        return error.LoadFailed;
    };
    errdefer _ = win32.FreeLibrary(module);

    const proc = win32.GetProcAddress(module, "CreateWebViewEnvironmentWithOptionsInternal") orelse {
        std.debug.print("zts: {s} has no CreateWebViewEnvironmentWithOptionsInternal\n", .{found.path});
        return error.ExportMissing;
    };

    return .{
        .module = module,
        .create = @ptrCast(@alignCast(proc)),
        .version = found.version,
        .fixed = found.fixed,
    };
}

const Found = struct {
    /// Owned by the caller (arena-allocated inside `findClientDll`).
    path: []const u8,
    version: []u8,
    fixed: bool,
};

/// Result of a single registry probe, kept for diagnostics.
const Probe = struct {
    root_name: []const u8,
    key: []const u8,
    value: []const u8,
    wow64: bool,
};

fn findClientDll(allocator: Allocator) LoadError!Found {
    const arch = util.archFolder(builtin.cpu.arch);
    var path_buf: [1024]u8 = undefined;
    var key_buf: [256]u8 = undefined;

    // 1. Fixed-version deployment / explicit override.
    if (getEnv(allocator, "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER")) |folder| {
        defer allocator.free(folder);
        const path = util.composeClientDll(&path_buf, folder, arch) catch return error.RuntimeNotFound;
        if (fileExists(allocator, path)) {
            return .{
                .path = allocator.dupe(u8, path) catch return error.OutOfMemory,
                .version = allocator.dupe(u8, util.lastPathComponent(folder)) catch return error.OutOfMemory,
                .fixed = true,
            };
        }
        std.debug.print("zts: WEBVIEW2_BROWSER_EXECUTABLE_FOLDER set but {s} is missing\n", .{path});
    }

    for (util.RuntimeChannel.all) |channel| {
        // 2. ClientState\{GUID}\EBWebView == the install folder, ending in the runtime version.
        const state_key = util.clientStateKey(&key_buf, channel) catch continue;
        for ([_]Root{ .local_machine, .current_user }) |root| {
            // The installer writes this key from a 32-bit installer, so the SDK always reads it
            // through the WOW64 32-bit view; we try that view first and fall back to the native one.
            for ([_]bool{ true, false }) |wow64| {
                const folder = readRegString(allocator, root, state_key, "EBWebView", wow64) orelse continue;
                defer allocator.free(folder);

                // The installer is inconsistent about this value: on most channels it names the
                // `...\Application\<version>` folder, but some builds write the `EBWebView` staging
                // folder itself. Probe both layouts instead of guessing (the version is then read
                // back out of whichever path actually exists).
                const version_text = util.versionFromPath(folder) orelse continue;

                var staged_buf: [1024]u8 = undefined;
                const candidates = [_][]const u8{
                    // `…\Application\<version>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`
                    util.composeClientDll(&path_buf, folder, arch) catch continue,
                    // `…\Application\<version>\EBWebView` → `…\<arch>\EmbeddedBrowserWebView.dll`
                    util.composeStagedClientDll(&staged_buf, folder, arch) catch continue,
                };
                for (candidates) |path| {
                    if (!fileExists(allocator, path)) continue;
                    return .{
                        .path = allocator.dupe(u8, path) catch return error.OutOfMemory,
                        .version = allocator.dupe(u8, version_text) catch return error.OutOfMemory,
                        .fixed = false,
                    };
                }
            }
        }

        // 3. Clients\{GUID} → location + pv (pre-Edge-100 installers).
        const clients_key = util.clientsKey(&key_buf, channel) catch continue;
        for ([_]Root{ .local_machine, .current_user }) |root| {
            for ([_]bool{ true, false }) |wow64| {
                const pv = readRegString(allocator, root, clients_key, "pv", wow64) orelse continue;
                defer allocator.free(pv);
                if (!util.isCompatibleRuntime(pv)) continue;

                const location = readRegString(allocator, root, clients_key, "location", wow64) orelse continue;
                defer allocator.free(location);

                const path = util.composeVersionedClientDll(&path_buf, location, pv, arch) catch continue;
                if (!fileExists(allocator, path)) continue;
                return .{
                    .path = allocator.dupe(u8, path) catch return error.OutOfMemory,
                    .version = allocator.dupe(u8, pv) catch return error.OutOfMemory,
                    .fixed = false,
                };
            }
        }
    }

    std.debug.print(
        "zts: WebView2 runtime not found (arch={s}); checked WEBVIEW2_BROWSER_EXECUTABLE_FOLDER, " ++
            "EdgeUpdate\\ClientState and EdgeUpdate\\Clients for stable/beta/dev/canary\n",
        .{arch},
    );
    return error.RuntimeNotFound;
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

    fn name(self: Root) []const u8 {
        return switch (self) {
            .current_user => "HKCU",
            .local_machine => "HKLM",
        };
    }
};

/// Reads a `REG_SZ`/`REG_EXPAND_SZ` value as UTF-8. Returns `null` for any failure — the loader
/// treats "missing" and "unreadable" identically, exactly like Microsoft's loader.
fn readRegString(allocator: Allocator, root: Root, key_path: []const u8, value_name: []const u8, wow64: bool) ?[]u8 {
    const key_z = win32.toWide(allocator, key_path) catch return null;
    defer allocator.free(key_z);
    const value_z = win32.toWide(allocator, value_name) catch return null;
    defer allocator.free(value_z);

    var key: ?win32.HKEY = null;
    const sam = win32.KEY_QUERY_VALUE | (if (wow64) win32.KEY_WOW64_32KEY else win32.KEY_WOW64_64KEY);
    if (win32.RegOpenKeyExW(root.hkey(), key_z.ptr, 0, sam, &key) != win32.ERROR_SUCCESS) return null;
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
    if (end == 0) return null;
    return allocator.dupe(u8, utf8[0..end]) catch null;
}

fn fileExists(allocator: Allocator, path: []const u8) bool {
    const wide = win32.toWide(allocator, path) catch return false;
    defer allocator.free(wide);
    return win32.GetFileAttributesW(wide.ptr) != win32.INVALID_FILE_ATTRIBUTES;
}

fn getEnv(allocator: Allocator, name: []const u8) ?[]u8 {
    const name_z = win32.toWide(allocator, name) catch return null;
    defer allocator.free(name_z);

    var buf: [1024]u16 = undefined;
    const len = win32.GetEnvironmentVariableW(name_z.ptr, &buf, buf.len);
    if (len == 0 or len >= buf.len) return null;
    buf[len] = 0;
    return win32.fromWide(allocator, @ptrCast(&buf), false) catch null;
}

test "readRegString degrades to null for a key that does not exist" {
    // Only meaningful on Windows; on any other host the file is still *analyzed* so the pure-Zig
    // search logic above stays compilable (and testable) everywhere.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // The loader must never crash on a machine without WebView2 — every probe is best-effort.
    try std.testing.expect(readRegString(std.testing.allocator, .current_user, "SOFTWARE\\Z-Ts\\NotInstalled", "x", true) == null);
}
