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
