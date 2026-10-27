//! Screenshot capture contract tests (`M5-04`).
//!
//! The real encoders are platform code (cairo on GTK, `NSBitmapImageRep` on macOS, WebView2
//! `CapturePreview` on Windows), so the *contract* every backend must satisfy is pinned here and
//! runs on Linux, macOS and Windows:
//!
//! 1. `captureWindow()` succeeds for a live window and `takeCapture()` moves the bytes out exactly once.
//! 2. The bytes are a valid PNG whose IHDR size matches what the caller asked for.
//! 3. `captureWindow()` twice without collecting replaces the pending image (no leak, no double free).
//! 4. Closing a window drops its pending capture; unknown windows are `WindowNotFound`.
//!
//! Native backends add their own real-render assertions in `examples/gallery` (CI) — these tests
//! cover the ownership rules that a crash or a leak would otherwise hide.

const std = @import("std");
const testing = std.testing;

const root = @import("mod.zig");
const types = @import("types.zig");
const png = @import("png.zig");
const mock_mod = @import("mock.zig");

test "capture: a mock capture round-trips once and reports the requested size" {
    var m = mock_mod.HeadlessMock.init(testing.allocator, testing.io);
    defer m.deinit();

    const win = try m.createWindow(.{ .title = "shot", .size = .wh(120, 90) });

    // Nothing pending before the first request…
    try testing.expect(try m.takeCapture(win) == null);

    try m.captureWindow(win);
    var shot = (try m.takeCapture(win)) orelse return error.CaptureMissing;
    defer shot.deinit();

    try testing.expectEqual(@as(u32, 120), shot.width);
    try testing.expectEqual(@as(u32, 90), shot.height);
    try testing.expect(png.isPng(shot.bytes));
    try testing.expectEqual(@as(u64, 120), @as(u64, shot.width));

    // …and it is gone once taken.
    try testing.expect(try m.takeCapture(win) == null);
}

test "capture: re-requesting before collection replaces the pending image" {
    var m = mock_mod.HeadlessMock.init(testing.allocator, testing.io);
    defer m.deinit();

    const win = try m.createWindow(.{ .title = "shot", .size = .wh(64, 48) });
    try m.captureWindow(win);
    try m.setSize(win, .wh(32, 24));
    try m.captureWindow(win); // must free the 64x48 image instead of leaking it

    var shot = (try m.takeCapture(win)) orelse return error.CaptureMissing;
    defer shot.deinit();
    try testing.expectEqual(@as(u32, 32), shot.width);
    try testing.expectEqual(@as(u32, 24), shot.height);
    try testing.expect(try m.takeCapture(win) == null);
}

test "capture: closing a window drops its uncollected screenshot without leaking" {
    var m = mock_mod.HeadlessMock.init(testing.allocator, testing.io);
    defer m.deinit();

    const win = try m.createWindow(.{ .size = .wh(40, 30) });
    try m.captureWindow(win);
    try m.closeWindow(win);

    try testing.expectError(error.WindowNotFound, m.takeCapture(win));
    try testing.expectError(error.WindowNotFound, m.captureWindow(win));
}

test "capture: a zero-sized window still yields a 1x1 image instead of an encoder error" {
    var m = mock_mod.HeadlessMock.init(testing.allocator, testing.io);
    defer m.deinit();

    const win = try m.createWindow(.{ .size = .wh(0, 0) });
    try m.captureWindow(win);

    var shot = (try m.takeCapture(win)) orelse return error.CaptureMissing;
    defer shot.deinit();
    try testing.expectEqual(@as(u32, 1), shot.width);
    try testing.expectEqual(@as(u32, 1), shot.height);
}

test "capture: Engine forwards capture/take to the mock backend" {
    var engine = try root.Engine.init(testing.allocator, testing.io, .headless_mock);
    defer engine.deinit();

    const win = try engine.createWindow(.{ .size = .wh(50, 40) });
    try engine.captureWindow(win);

    var shot = (try engine.takeCapture(win)) orelse return error.CaptureMissing;
    defer shot.deinit();
    try testing.expectEqual(@as(u32, 50), shot.width);

    const unknown: types.WindowId = .{ .index = 999, .generation = 3 };
    try testing.expectError(error.WindowNotFound, engine.captureWindow(unknown));
}

test "capture: Capture.initOwned rejects non-PNG bytes and frees them" {
    const junk = try testing.allocator.alloc(u8, 32);
    @memset(junk, 0xAB);
    try testing.expectError(error.PlatformFailure, types.Capture.initOwned(testing.allocator, junk));
}
