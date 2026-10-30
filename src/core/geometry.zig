//! Type-Safe Coordinate Spaces (`LogicalPx` vs `PhysicalPx`), DPI Scaling,
//! macOS Y-Axis Flipping, and CSS <-> Native Color Space Conversion.
//!
//! Enforces rule #6 of `docs/architecture/web-zig-boundary.md`:
//! - HTML/CSS always speaks **Top-Left Origin, Logical Pixels (DIP), Straight RGBA**.
//! - Win32 speaks Physical Pixels; macOS AppKit (`NSScreen` / `NSWindow`) speaks Bottom-Left Y-up;
//!   native compositors require Premultiplied BGRA / ARGB.
//! - Making `LogicalPx` and `PhysicalPx` distinct structs turns accidental unit mixing into a
//!   compile-time type error instead of a subtle 4K/Retina layout bug.

const std = @import("std");

pub const GeometryError = error{
    InvalidScaleFactor,
    InvalidDimension,
    InvalidCssColor,
};

/// Device-independent CSS logical pixel value (`f64`, e.g. `800.0` matching CSS `800px`).
pub const LogicalPx = struct {
    /// The value in CSS pixels.
    v: f64,

    /// Wraps a raw value.
    pub inline fn init(val: f64) LogicalPx {
        return .{ .v = val };
    }

    /// Scales up and rounds to whole device pixels.
    pub fn toPhysical(self: LogicalPx, scale: ScaleFactor) PhysicalPx {
        return .{ .v = @intFromFloat(@round(self.v * scale.v)) };
    }
};

/// Raw hardware framebuffer pixel coordinate (`i32`, e.g. `1600` at 200% Windows DPI).
pub const PhysicalPx = struct {
    /// The value in device pixels.
    v: i32,

    /// Wraps a raw value.
    pub inline fn init(val: i32) PhysicalPx {
        return .{ .v = val };
    }

    /// Divides by the scale factor, back to CSS pixels.
    pub fn toLogical(self: PhysicalPx, scale: ScaleFactor) LogicalPx {
        return .{ .v = @as(f64, @floatFromInt(self.v)) / scale.v };
    }
};

/// Validated positive finite HiDPI scale factor (`window.devicePixelRatio`, e.g. `1.0`, `2.0`).
pub const ScaleFactor = struct {
    /// The multiplier (`window.devicePixelRatio`).
    v: f64 = 1.0,

    /// The `1.0` factor of a non-HiDPI display.
    pub const standard: ScaleFactor = .{ .v = 1.0 };

    /// Validates that the factor is finite and positive.
    pub fn init(factor: f64) GeometryError!ScaleFactor {
        if (!std.math.isFinite(factor) or factor <= 0.0) return error.InvalidScaleFactor;
        return .{ .v = factor };
    }
};

/// A point in **logical (CSS) pixels**, Y-down from the top-left corner — the coordinate system the
/// page itself uses. Multiply by a `ScaleFactor` to reach device pixels.
pub const LogicalPoint = struct {
    /// X in CSS pixels, from the left edge.
    x: LogicalPx,
    /// Y in CSS pixels, from the top edge (Y-down, like the page).
    y: LogicalPx,

    /// Builds a point from two raw values.
    pub inline fn xy(x: f64, y: f64) LogicalPoint {
        return .{ .x = .init(x), .y = .init(y) };
    }

    /// Converts both axes to device pixels.
    pub fn toPhysical(self: LogicalPoint, scale: ScaleFactor) PhysicalPoint {
        return .{
            .x = self.x.toPhysical(scale),
            .y = self.y.toPhysical(scale),
        };
    }

    /// Converts between Top-Left Y-down (CSS) and Bottom-Left Y-up (macOS Cocoa point).
    pub inline fn flipY(self: LogicalPoint, container_height: LogicalPx) LogicalPoint {
        return .{
            .x = self.x,
            .y = .init(container_height.v - self.y.v),
        };
    }
};

/// A point in **physical (device) pixels**, Y-down. This is what Win32 and X11 report, and what a
/// screenshot's pixel coordinates mean.
pub const PhysicalPoint = struct {
    /// X in device pixels.
    x: PhysicalPx,
    /// Y in device pixels.
    y: PhysicalPx,

    /// Builds a point from two raw values.
    pub inline fn xy(x: i32, y: i32) PhysicalPoint {
        return .{ .x = .init(x), .y = .init(y) };
    }

    /// Converts both axes to CSS pixels.
    pub fn toLogical(self: PhysicalPoint, scale: ScaleFactor) LogicalPoint {
        return .{
            .x = self.x.toLogical(scale),
            .y = self.y.toLogical(scale),
        };
    }
};

/// Width/height in logical (CSS) pixels — the unit `WindowConfig.size` and CSS `px` share, so the
/// same number produces the same layout on a 1x and a 2x screen.
pub const LogicalSize = struct {
    /// Width in CSS pixels.
    width: LogicalPx,
    /// Height in CSS pixels.
    height: LogicalPx,

    /// Builds a size from two raw values.
    pub inline fn wh(w: f64, h: f64) LogicalSize {
        return .{ .width = .init(w), .height = .init(h) };
    }

    /// Converts both axes to device pixels.
    pub fn toPhysical(self: LogicalSize, scale: ScaleFactor) PhysicalSize {
        return .{
            .width = self.width.toPhysical(scale),
            .height = self.height.toPhysical(scale),
        };
    }
};

/// Width/height in physical (device) pixels, as reported by the OS window manager.
pub const PhysicalSize = struct {
    /// Width in device pixels.
    width: PhysicalPx,
    /// Height in device pixels.
    height: PhysicalPx,

    /// Builds a size from two raw values.
    pub inline fn wh(w: i32, h: i32) PhysicalSize {
        return .{ .width = .init(w), .height = .init(h) };
    }

    /// Converts both axes to CSS pixels.
    pub fn toLogical(self: PhysicalSize, scale: ScaleFactor) LogicalSize {
        return .{
            .width = self.width.toLogical(scale),
            .height = self.height.toLogical(scale),
        };
    }
};

/// A rectangle in logical pixels: origin is the top-left corner. `flipY` converts to and from the
/// Bottom-Left Y-up system AppKit uses (the mapping is its own inverse).
pub const LogicalRect = struct {
    /// Top-left corner in CSS pixels.
    origin: LogicalPoint,
    /// Extent in CSS pixels.
    size: LogicalSize,

    /// Builds a rect from four raw values.
    pub inline fn xywh(x: f64, y: f64, w: f64, h: f64) LogicalRect {
        return .{ .origin = .xy(x, y), .size = .wh(w, h) };
    }

    /// Involution mapping a rectangle between Top-Left Y-down (CSS / GTK / Win32) and
    /// Bottom-Left Y-up (`NSRect` in macOS AppKit): `new_y = container_h - (y + rect_h)`.
    /// Applying `flipY` twice returns the exact original rectangle.
    pub inline fn flipY(self: LogicalRect, container_height: LogicalPx) LogicalRect {
        return .{
            .origin = .{
                .x = self.origin.x,
                .y = .init(container_height.v - self.origin.y.v - self.size.height.v),
            },
            .size = self.size,
        };
    }

    /// Converts the corner and the extent to device pixels.
    pub fn toPhysical(self: LogicalRect, scale: ScaleFactor) PhysicalRect {
        return .{
            .origin = self.origin.toPhysical(scale),
            .size = self.size.toPhysical(scale),
        };
    }
};

/// A rectangle in physical pixels, used for capture regions and hit testing.
pub const PhysicalRect = struct {
    /// Top-left corner in device pixels.
    origin: PhysicalPoint,
    /// Extent in device pixels.
    size: PhysicalSize,

    /// Converts the corner and the extent back to CSS pixels.
    pub fn toLogical(self: PhysicalRect, scale: ScaleFactor) LogicalRect {
        return .{
            .origin = self.origin.toLogical(scale),
            .size = self.size.toLogical(scale),
        };
    }
};

/// Straight (unpremultiplied) sRGB color matching CSS `rgba(r, g, b, a)` / `#RRGGBBAA`.
pub const Color = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    pub inline fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Parses CSS hex strings: `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA` (leading `#` optional).
    pub fn parseCssHex(input: []const u8) GeometryError!Color {
        const hex = if (std.mem.startsWith(u8, input, "#")) input[1..] else input;
        return switch (hex.len) {
            3 => .{
                .r = (try nibble(hex[0])) * 17,
                .g = (try nibble(hex[1])) * 17,
                .b = (try nibble(hex[2])) * 17,
                .a = 255,
            },
            4 => .{
                .r = (try nibble(hex[0])) * 17,
                .g = (try nibble(hex[1])) * 17,
                .b = (try nibble(hex[2])) * 17,
                .a = (try nibble(hex[3])) * 17,
            },
            6 => .{
                .r = try byteHex(hex[0..2]),
                .g = try byteHex(hex[2..4]),
                .b = try byteHex(hex[4..6]),
                .a = 255,
            },
            8 => .{
                .r = try byteHex(hex[0..2]),
                .g = try byteHex(hex[2..4]),
                .b = try byteHex(hex[4..6]),
                .a = try byteHex(hex[6..8]),
            },
            else => error.InvalidCssColor,
        };
    }

    /// Converts Straight RGBA to exact rounded Premultiplied `[4]u8` in `[B, G, R, A]` byte order
    /// required by Cairo (`CAIRO_FORMAT_ARGB32` little-endian) and Win32 DWM / DirectComposition.
    pub inline fn toPremultipliedBgra(self: Color) [4]u8 {
        return .{
            premulChannel(self.b, self.a),
            premulChannel(self.g, self.a),
            premulChannel(self.r, self.a),
            self.a,
        };
    }

    /// Converts Straight RGBA to Premultiplied `[R, G, B, A]`.
    pub inline fn toPremultipliedRgba(self: Color) [4]u8 {
        return .{
            premulChannel(self.r, self.a),
            premulChannel(self.g, self.a),
            premulChannel(self.b, self.a),
            self.a,
        };
    }

    inline fn premulChannel(c: u8, a: u8) u8 {
        return @intCast((@as(u16, c) * @as(u16, a) + 127) / 255);
    }

    inline fn nibble(ch: u8) GeometryError!u8 {
        return std.fmt.charToDigit(ch, 16) catch error.InvalidCssColor;
    }

    inline fn byteHex(pair: *const [2]u8) GeometryError!u8 {
        return (@as(u8, try nibble(pair[0])) << 4) | (try nibble(pair[1]));
    }
};

// ============================================================================
// Unit & Property Tests
// ============================================================================

test "Geometry: HiDPI scaling, macOS Y-axis flip involution, and CSS color conversion" {
    try std.testing.expectError(error.InvalidScaleFactor, ScaleFactor.init(0.0));
    try std.testing.expectError(error.InvalidScaleFactor, ScaleFactor.init(-2.0));
    try std.testing.expectError(error.InvalidScaleFactor, ScaleFactor.init(std.math.nan(f64)));

    const retina = try ScaleFactor.init(2.0);
    const logical = LogicalSize.wh(1024, 768);
    const physical = logical.toPhysical(retina);
    try std.testing.expectEqual(@as(i32, 2048), physical.width.v);
    try std.testing.expectEqual(@as(i32, 1536), physical.height.v);

    const back = physical.toLogical(retina);
    try std.testing.expectEqual(@as(f64, 1024.0), back.width.v);
    try std.testing.expectEqual(@as(f64, 768.0), back.height.v);

    // Top-left window `(100, 50, 800x600)` on a `1080p` screen -> Cocoa bottom-left y = 1080 - 50 - 600 = 430
    const screen_h = LogicalPx.init(1080.0);
    const css_rect = LogicalRect.xywh(100.0, 50.0, 800.0, 600.0);
    const cocoa_rect = css_rect.flipY(screen_h);
    try std.testing.expectEqual(@as(f64, 430.0), cocoa_rect.origin.y.v);
    // Double flip must be an exact identity
    const roundtrip_rect = cocoa_rect.flipY(screen_h);
    try std.testing.expectEqual(css_rect.origin.x.v, roundtrip_rect.origin.x.v);
    try std.testing.expectEqual(css_rect.origin.y.v, roundtrip_rect.origin.y.v);

    // CSS Hex parser + premultiplied BGRA accuracy
    try std.testing.expectEqual(Color.rgba(0x11, 0x22, 0x33, 0xff), try Color.parseCssHex("#123"));
    try std.testing.expectEqual(Color.rgba(0xaa, 0xbb, 0xcc, 0xdd), try Color.parseCssHex("#abcd"));
    try std.testing.expectEqual(Color.rgba(0x1e, 0x29, 0x3b, 0xff), try Color.parseCssHex("#1E293B"));
    const semi = try Color.parseCssHex("#ff800080");
    const bgra = semi.toPremultipliedBgra();
    try std.testing.expectEqual([4]u8{ 0, 64, 128, 128 }, bgra);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, Color.transparent.toPremultipliedBgra());
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, Color.white.toPremultipliedBgra());
    try std.testing.expectError(error.InvalidCssColor, Color.parseCssHex("#12345"));
    try std.testing.expectError(error.InvalidCssColor, Color.parseCssHex("#zzzzzz"));
}
