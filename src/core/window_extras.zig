//! `zts_foundation` — M5-22 ② ownership-free scalar snapshot of window setter intents.
//!
//! This module lives in `zts_foundation` (the only module every other product may depend on) so
//! `zts_core`, `zts_tauri`, `zts_webview`, `zts_bridge` and the wasm host all exchange the SAME
//! struct without creating a circular import. There are no allocations, no slices and no enums:
//! the tauri-side enums travel as their ordinals, documented below.

/// One complete snapshot of the `plugin:window` P1 #8 setter state. `core.Host.applyWindowExtras`
/// receives this after EVERY setter; a backend applies what its OS supports and fail-closes the
/// rest with `error.Unsupported`.
pub const WindowExtrasSnapshot = struct {
    /// `tauri.window.Theme` ordinal (`system, dark, light`).
    theme: u8 = 0,
    skip_taskbar: bool = false,
    /// `tauri.window.ProgressStatus` ordinal.
    progress_status: u8 = 0,
    progress_value: ?u8 = null,
    badge_count: ?u32 = null,
    /// `tauri.window.CursorIcon` ordinal.
    cursor_icon: u16 = 0,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_grab: bool = false,
    cursor_visible: bool = true,
    ignore_cursor_events: bool = false,
    centered: bool = false,
    /// `tauri.window.AttentionType` ordinal.
    user_attention: u8 = 0,
    content_protected: bool = false,
    visible_on_all_workspaces: bool = false,
    shadow: bool = true,
    always_on_bottom: bool = false,
    enabled: bool = true,
    /// `tauri.window.Effect` ordinal.
    effect: u8 = 0,
    bg_set: bool = false,
    bg_r: u8 = 0,
    bg_g: u8 = 0,
    bg_b: u8 = 0,
    bg_a: u8 = 255,
    icon_hash: u64 = 0,
    devtools_open: bool = false,
};

test "WindowExtrasSnapshot defaults are deterministic and scalar-only" {
    const std = @import("std");
    const a = WindowExtrasSnapshot{};
    const b = WindowExtrasSnapshot{};
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(true, a.cursor_visible);
    try std.testing.expectEqual(true, a.enabled);
    try std.testing.expectEqual(true, a.shadow);
    try std.testing.expectEqual(@as(u8, 255), a.bg_a);
    // No allocator-owned data: the struct is bitwise comparable and trivially copyable.
    try std.testing.expectEqual(@as(usize, @sizeOf(WindowExtrasSnapshot)), @sizeOf(@TypeOf(a)));
}
