//! CSS ⇔ Cocoa Coordinate Conversion (`src/webview/coords.zig`, `M3-01`).
//!
//! Z-Ts' public geometry (`zts_foundation.geometry.LogicalPoint`) uses the **CSS / Win32 / GTK
//! convention**: the origin is the TOP-LEFT of the screen with Y growing downwards.
//! AppKit (`NSWindow`, `NSView`, `NSScreen`) instead uses the **Cocoa convention**: the origin is the
//! BOTTOM-LEFT with Y growing upwards (and multi-monitor origins can be negative).
//!
//! This module is deliberately pure (`link_libc = false`, zero externs) so the conversion is
//! unit-testable on **every** OS — including Linux CI, where the macOS backend cannot be linked.

const std = @import("std");
const testing = std.testing;

/// Visible frame of an `NSScreen` in Cocoa coordinates (`visibleFrame` excludes the menu bar/dock).
pub const ScreenFrame = struct {
    /// Left edge in Cocoa points.
    x: f64 = 0,
    /// Cocoa bottom-left Y (can be negative on secondary displays placed below the main one).
    y: f64 = 0,
    /// Visible width in points.
    width: f64 = 1280,
    /// Visible height in points.
    height: f64 = 800,

    /// Y coordinate of the TOP edge of the screen in Cocoa space.
    pub fn top(self: ScreenFrame) f64 {
        return self.y + self.height;
    }
};

/// Converts a CSS top-left `css_y` (window top edge) into a Cocoa bottom-left window origin.
///
/// `cocoa_y = screen_top - css_y - window_height`
pub fn cssToCocoaY(screen_top: f64, css_y: f64, window_height: f64) f64 {
    return screen_top - css_y - window_height;
}

/// Inverse of `cssToCocoaY` (used for round-trip assertions and drag-delta handling).
pub fn cocoaToCssY(screen_top: f64, cocoa_y: f64, window_height: f64) f64 {
    return screen_top - cocoa_y - window_height;
}

/// Converts a CSS top-left point into an absolute Cocoa window origin on `screen`.
pub fn cssToCocoaOrigin(screen: ScreenFrame, css_x: f64, css_y: f64, window_height: f64) struct { x: f64, y: f64 } {
    return .{
        .x = screen.x + css_x,
        .y = cssToCocoaY(screen.top(), css_y, window_height),
    };
}

/// Converts a Cocoa window origin back into a CSS top-left point.
pub fn cocoaToCssOrigin(screen: ScreenFrame, cocoa_x: f64, cocoa_y: f64, window_height: f64) struct { x: f64, y: f64 } {
    return .{
        .x = cocoa_x - screen.x,
        .y = cocoaToCssY(screen.top(), cocoa_y, window_height),
    };
}

// ============================================================================
// Tests (run on Linux / macOS / Windows)
// ============================================================================

test "cssToCocoaY: top-left origin maps to the top edge, bottom edge maps to 0" {
    const screen = ScreenFrame{ .x = 0, .y = 0, .width = 1440, .height = 900 };

    // Window fully at the very top of the screen.
    try testing.expectEqual(@as(f64, 300), cssToCocoaY(screen.top(), 0, 600));
    // Window flush with the bottom edge.
    try testing.expectEqual(@as(f64, 0), cssToCocoaY(screen.top(), 300, 600));
    // Window taller than the remaining space goes negative (partially off-screen) — no clamping.
    try testing.expectEqual(@as(f64, -100), cssToCocoaY(screen.top(), 400, 600));
}

test "cssToCocoaY honours a non-zero / negative screen origin (secondary display)" {
    // A second display placed BELOW the main one: Cocoa y = -1080, height 1080.
    const below = ScreenFrame{ .x = 0, .y = -1080, .width = 1920, .height = 1080 };
    try testing.expectEqual(@as(f64, 0), below.top());
    try testing.expectEqual(@as(f64, -400), cssToCocoaY(below.top(), 0, 400));

    // A display placed to the RIGHT of the main one keeps y = 0.
    const right = ScreenFrame{ .x = 1440, .y = 0, .width = 1920, .height = 1080 };
    const origin = cssToCocoaOrigin(right, 100, 50, 720);
    try testing.expectEqual(@as(f64, 1540), origin.x);
    try testing.expectEqual(@as(f64, 310), origin.y);
}

test "cssToCocoaOrigin ⇔ cocoaToCssOrigin round-trips exactly" {
    const screen = ScreenFrame{ .x = -200, .y = -150, .width = 2560, .height = 1440 };
    const cases = [_]struct { x: f64, y: f64, h: f64 }{
        .{ .x = 0, .y = 0, .h = 600 },
        .{ .x = 100, .y = 220, .h = 480 },
        .{ .x = -50, .y = 900, .h = 120 },
        .{ .x = 1280, .y = 1400, .h = 40 },
    };

    for (cases) |cse| {
        const cocoa = cssToCocoaOrigin(screen, cse.x, cse.y, cse.h);
        const back = cocoaToCssOrigin(screen, cocoa.x, cocoa.y, cse.h);
        try testing.expectApproxEqAbs(cse.x, back.x, 1e-9);
        try testing.expectApproxEqAbs(cse.y, back.y, 1e-9);
    }
}

test "cocoaToCssY is the exact inverse of cssToCocoaY" {
    var css_y: f64 = 0;
    while (css_y <= 2000) : (css_y += 37.5) {
        const h: f64 = 640;
        const cocoa = cssToCocoaY(1080, css_y, h);
        try testing.expectApproxEqAbs(css_y, cocoaToCssY(1080, cocoa, h), 1e-9);
    }
}
