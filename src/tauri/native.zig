//! `zts_tauri_native` — OS implementations of the `dialog` & `clipboard` plugin backends.
//!
//! `zts_tauri` itself stays Pure Zig (`link_libc = false`, zero GTK / Cocoa / Win32), which is what
//! lets the plugin wire layer and its `Mock` backends be unit-tested on every OS. This module is
//! the *only* place that talks to a native toolkit:
//!
//! | OS | Dialogs | Clipboard |
//! |---|---|---|
//! | Linux | GTK3 `GtkFileChooserNative` / `GtkMessageDialog` | `GtkClipboard` (`text/html` target included) |
//! | macOS | `NSOpenPanel` / `NSSavePanel` / `NSAlert` (Objective-C shim) | `NSPasteboard` |
//! | Windows | `IFileOpenDialog` / `IFileSaveDialog` COM + `MessageBoxW` | Win32 clipboard API |
//!
//! Wiring (the host owns the state, the plugin owns the wire):
//!
//! ```zig
//! var dialog_state = tauri.dialog.DialogState.init(alloc, io, native.dialog_backend())
//!     .withScope(&fs_state.scope);
//! var clipboard_state = tauri.clipboard.ClipboardState.init(alloc, native.clipboard_backend());
//!
//! const App = rpc.merge(.{ MySchema, rpc.Schema(.{
//!     .dialog = tauri.dialog.Commands,
//!     .clipboard = tauri.clipboard.Commands,
//! }) });
//! ```
//!
//! `native_options` (a `build.zig` option module) decides which backend is compiled in, so the
//! Windows COM code is never analyzed on Linux and vice versa.

const std = @import("std");
const builtin = @import("builtin");

pub const native_options = @import("native_options");

/// Pure, OS-independent Win32 helpers (option bits, filter specs, UTF-16). Always compiled so they
/// are unit-tested on every OS, like `src/webview/windows_util.zig`.
pub const win32 = @import("native_win32.zig");

pub const dialog = @import("dialog/mod.zig");
pub const clipboard = @import("clipboard/mod.zig");
pub const menu = @import("../tauri/menu/mod.zig");
pub const tray = @import("../tauri/tray/mod.zig");

pub const is_gtk = (builtin.os.tag == .linux) and native_options.enable_gtk;
pub const is_macos = (builtin.os.tag == .macos) and native_options.enable_macos;
pub const is_win32 = (builtin.os.tag == .windows) and native_options.enable_windows;

const dialog_impl = if (is_gtk)
    @import("dialog/native_gtk.zig")
else if (is_macos)
    @import("dialog/native_macos.zig")
else if (is_win32)
    @import("dialog/native_windows.zig")
else
    @import("dialog/native_stub.zig");

const clipboard_impl = if (is_gtk)
    @import("clipboard/native_gtk.zig")
else if (is_macos)
    @import("clipboard/native_macos.zig")
else if (is_win32)
    @import("clipboard/native_windows.zig")
else
    @import("clipboard/native_stub.zig");

/// The dialog backend compiled for this target.
pub fn dialogBackend() dialog.Backend {
    return dialog_impl.backend();
}

/// The clipboard backend compiled for this target.
pub fn clipboardBackend() clipboard.Backend {
    return clipboard_impl.backend();
}

const menu_impl = if (is_gtk)
    @import("menu/native_gtk.zig")
else if (is_macos)
    @import("menu/native_macos.zig")
else if (is_win32)
    @import("menu/native_windows.zig")
else
    @import("menu/native_stub.zig");

const tray_impl = if (is_gtk)
    @import("tray/native_gtk.zig")
else if (is_macos)
    @import("tray/native_macos.zig")
else if (is_win32)
    @import("tray/native_windows.zig")
else
    @import("tray/native_stub.zig");

/// The menu backend compiled for this target.
pub fn menuBackend() menu.Backend {
    return menu_impl.backend();
}

/// The tray backend compiled for this target.
pub fn trayBackend() tray.Backend {
    return tray_impl.backend();
}

/// Registers a toplevel window with the native menu backend.
///
/// Menus are per-window on GTK (`GtkWindow` — the bar is a widget packed into the window) and on
/// Win32 (`HWND` — `SetMenu`), while AppKit installs them on `NSWindow` and on `NSApp` (the menu
/// bar itself). `handle` is therefore the toolkit's own toplevel: `GtkWindow *`, `HWND`, or
/// `NSWindow *`. Returns `false` when the platform has no menu backend at all.
pub fn registerMenuWindow(label: []const u8, handle: ?*anyopaque) bool {
    if (comptime @hasDecl(menu_impl, "registerWindow")) {
        menu_impl.registerWindow(label, handle orelse return false) catch return false;
        return true;
    }
    return false;
}

/// Forgets a window registered with `registerMenuWindow` (call before destroying it).
pub fn unregisterMenuWindow(label: []const u8) void {
    if (comptime @hasDecl(menu_impl, "unregisterWindow")) menu_impl.unregisterWindow(label);
}

/// Human-readable description of the selected backends (surfaced in `OK`/`SKIP` diagnostics).
pub fn describe() []const u8 {
    if (is_gtk) return "gtk3";
    if (is_macos) return "cocoa";
    if (is_win32) return "win32";
    return "stub";
}

/// GTK bindings, compiled only when the Linux backend is active.
pub const gtk = if (is_gtk) @import("native_gtk.zig") else struct {};

test {
    _ = dialog_impl;
    _ = clipboard_impl;
    _ = win32;
    _ = menu;
    _ = tray;
    _ = menu_impl;
    _ = tray_impl;
    // Shared NUL-termination helper (no OS dependency, so its tests run everywhere).
    _ = @import("native_cstr.zig");
}

test "the active backend for this target is reported and constructible" {
    const kind = describe();
    try std.testing.expect(kind.len > 0);
    _ = dialogBackend();
    _ = clipboardBackend();

    // On a build without a native toolkit the stub must be selected, and it must fail closed.
    if (std.mem.eql(u8, kind, "stub")) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.Unavailable, dialogBackend().open(arena.allocator(), .{}));
        try std.testing.expectError(error.Unavailable, clipboardBackend().readText(arena.allocator()));
    }
}

// ---------------------------------------------------------------------------
// One-call provider bundle (task 6) + OS process-id helpers (task 4)
// ---------------------------------------------------------------------------

/// POSIX process-id / liveness helpers. Compiled only for the GTK / Cocoa builds, which link libc.
const posix_proc = if (is_gtk or is_macos) struct {
    extern "c" fn getpid() c_int;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;

    pub fn pid() u32 {
        return @intCast(getpid());
    }
    /// `kill(pid, 0)` performs no signal delivery — it only asks whether the process exists.
    pub fn alive(process_id: u32, _: ?*anyopaque) bool {
        return kill(@intCast(process_id), 0) == 0;
    }
} else struct {
    pub fn pid() u32 {
        return 0;
    }
    /// Unknown host: keep the lock (fail-closed) rather than reclaiming it by accident.
    pub fn alive(_: u32, _: ?*anyopaque) bool {
        return true;
    }
};

const win_proc = if (is_win32) struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) i32;

    pub fn pid() u32 {
        return GetCurrentProcessId();
    }
    /// `PROCESS_QUERY_LIMITED_INFORMATION` (0x1000) is enough to prove the process exists.
    pub fn alive(process_id: u32, _: ?*anyopaque) bool {
        const handle = OpenProcess(0x1000, 0, process_id) orelse return false;
        _ = CloseHandle(handle);
        return true;
    }
} else struct {
    pub fn pid() u32 {
        return posix_proc.pid();
    }
    pub fn alive(process_id: u32, ctx: ?*anyopaque) bool {
        return posix_proc.alive(process_id, ctx);
    }
};

/// This process's id, or `0` on a host without a provider.
pub fn currentPid() u32 {
    return if (is_win32) win_proc.pid() else posix_proc.pid();
}

/// Whether `pid` still names a live process. Always fail-closed when unknown.
pub fn processAlive(process_id: u32, ctx: ?*anyopaque) bool {
    return if (is_win32) win_proc.alive(process_id, ctx) else posix_proc.alive(process_id, ctx);
}

// The four backend accessors above plus `currentPid` / `processAlive` are the complete native set.
// Applications put them into a `tauri.RuntimeProviders` once; `DesktopRuntime.create()` applies
// the whole bundle. `native.zig` deliberately does not `@import("zts_tauri")`: its own subtree
// shares files with that module, and Zig 0.17 rejects a file belonging to two modules at once.
