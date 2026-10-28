//! NUL-terminated heap copies shared by every native backend.
//!
//! Zig 0.17 removed `Allocator.dupeZ`, and each backend (GTK `char*`, Cocoa `NSString*`,
//! Win32 `LPCWSTR`/`LPCSTR`) needs the same three-line dance, so it lives here once.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Copies `s` into a fresh `[:0]u8` sentinel-terminated buffer owned by `allocator`.
pub fn allocZ(allocator: Allocator, s: []const u8) Allocator.Error![:0]u8 {
    const buf = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf;
}

test "allocZ appends exactly one NUL and copies the payload verbatim" {
    const z = try allocZ(std.testing.allocator, "ダイアログ");
    defer std.testing.allocator.free(z);
    try std.testing.expectEqualStrings("ダイアログ", z);
    try std.testing.expectEqual(@as(u8, 0), z.ptr[z.len]);
    try std.testing.expectEqual(@as(usize, 15), z.len);
}

test "allocZ accepts the empty string" {
    const z = try allocZ(std.testing.allocator, "");
    defer std.testing.allocator.free(z);
    try std.testing.expectEqual(@as(usize, 0), z.len);
    try std.testing.expectEqual(@as(u8, 0), z.ptr[0]);
}
