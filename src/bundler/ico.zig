//! `.ico` reader and Windows resource blobs (`M5-03`).
//!
//! A Windows executable's icon is not a PNG: it is two resource types that reference each other.
//!
//! ```text
//! RT_ICON       (3)  id 1..N   one DIB (or PNG) per size, exactly as stored in the .ico file
//! RT_GROUP_ICON (14) id 1      the .ico's directory, with each entry pointing at an RT_ICON id
//! ```
//!
//! [`Icon.parse`] reads the directory and keeps every image; [`Icon.groupBlob`] renders the group
//! header (`GRPICONDIR`) that ties them together. `pe.zig` embeds both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const ParseError = error{
    Truncated,
    NotAnIcon,
    NoImages,
    TooManyImages,
    BadEntry,
    OutOfMemory,
};

/// ICONDIR: 6-byte header followed by `count` 16-byte ICONDIRENTRY records.
pub const header_size = 6;
pub const entry_size = 16;
/// Windows resource IDs are 16-bit, and 64 images in one `.ico` is already absurd.
pub const max_images = 64;

pub const Image = struct {
    /// 0 means 256 (the `.ico` format stores 256 as a single zero byte).
    width: u8,
    height: u8,
    color_count: u8,
    planes: u16,
    bit_count: u16,
    bytes: []const u8,

    pub fn pixelWidth(self: Image) u16 {
        return if (self.width == 0) 256 else self.width;
    }

    pub fn pixelHeight(self: Image) u16 {
        return if (self.height == 0) 256 else self.height;
    }
};

pub const Icon = struct {
    allocator: Allocator,
    images: []Image,

    pub fn deinit(self: Icon) void {
        for (self.images) |image| self.allocator.free(image.bytes);
        self.allocator.free(self.images);
    }

    pub fn imageCount(self: Icon) usize {
        return self.images.len;
    }

    /// The `GRPICONDIR` payload for `RT_GROUP_ICON`. `nID` is the image index + 1, matching the
    /// `RT_ICON` ids `pe.zig` assigns.
    pub fn groupBlob(self: Icon, allocator: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendU16(&out, allocator, 0); // reserved
        try appendU16(&out, allocator, 1); // type: icon
        try appendU16(&out, allocator, @intCast(self.images.len));
        for (self.images, 0..) |image, index| {
            try out.append(allocator, image.width);
            try out.append(allocator, image.height);
            try out.append(allocator, image.color_count);
            try out.append(allocator, 0); // reserved
            try appendU16(&out, allocator, image.planes);
            try appendU16(&out, allocator, image.bit_count);
            try appendU32(&out, allocator, @intCast(image.bytes.len));
            try appendU16(&out, allocator, @intCast(index + 1));
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Parses an `.ico` file. Every image is copied, so the caller may free `bytes` immediately.
pub fn parse(allocator: Allocator, bytes: []const u8) ParseError!Icon {
    if (bytes.len < header_size) return error.Truncated;
    const reserved = readU16(bytes, 0);
    const kind = readU16(bytes, 2);
    const count = readU16(bytes, 4);
    if (reserved != 0 or kind != 1) return error.NotAnIcon;
    if (count == 0) return error.NoImages;
    if (count > max_images) return error.TooManyImages;
    if (bytes.len < header_size + @as(usize, count) * entry_size) return error.Truncated;

    var images = try allocator.alloc(Image, count);
    var built: usize = 0;
    errdefer {
        for (images[0..built]) |image| allocator.free(image.bytes);
        allocator.free(images);
    }

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const base = header_size + index * entry_size;
        const size = readU32(bytes, base + 8);
        const offset = readU32(bytes, base + 12);
        if (size == 0 or offset > bytes.len or size > bytes.len - offset) return error.BadEntry;
        images[index] = .{
            .width = bytes[base + 0],
            .height = bytes[base + 1],
            .color_count = bytes[base + 2],
            .planes = readU16(bytes, base + 4),
            .bit_count = readU16(bytes, base + 6),
            .bytes = try allocator.dupe(u8, bytes[offset .. offset + size]),
        };
        built += 1;
    }
    return .{ .allocator = allocator, .images = images };
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn appendU16(list: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: u16) Allocator.Error!void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try list.appendSlice(allocator, &buf);
}

fn appendU32(list: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: u32) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try list.appendSlice(allocator, &buf);
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

/// Builds a two-image `.ico` in memory: a 16×16 32bpp and a 256×256 (width byte 0) one.
fn sampleIco(allocator: Allocator) ![]u8 {
    const first = "\x01\x02\x03\x04";
    const second = "\x05\x06\x07\x08\x09";
    const total = header_size + 2 * entry_size + first.len + second.len;
    var bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    std.mem.writeInt(u16, bytes[0..2], 0, .little);
    std.mem.writeInt(u16, bytes[2..4], 1, .little);
    std.mem.writeInt(u16, bytes[4..6], 2, .little);

    // Entry 0: 16x16, 32bpp, 4 bytes at the first data offset.
    const first_data = header_size + 2 * entry_size;
    bytes[header_size + 0] = 16;
    bytes[header_size + 1] = 16;
    std.mem.writeInt(u16, bytes[header_size + 4 ..][0..2], 1, .little); // planes
    std.mem.writeInt(u16, bytes[header_size + 6 ..][0..2], 32, .little); // bpp
    std.mem.writeInt(u32, bytes[header_size + 8 ..][0..4], first.len, .little);
    std.mem.writeInt(u32, bytes[header_size + 12 ..][0..4], first_data, .little);
    @memcpy(bytes[first_data .. first_data + first.len], first);

    // Entry 1: 256x256 (width byte 0), 5 bytes after the first payload.
    const second_entry = header_size + entry_size;
    bytes[second_entry + 0] = 0;
    bytes[second_entry + 1] = 0;
    std.mem.writeInt(u16, bytes[second_entry + 4 ..][0..2], 1, .little);
    std.mem.writeInt(u16, bytes[second_entry + 6 ..][0..2], 32, .little);
    const second_data = first_data + first.len;
    std.mem.writeInt(u32, bytes[second_entry + 8 ..][0..4], second.len, .little);
    std.mem.writeInt(u32, bytes[second_entry + 12 ..][0..4], second_data, .little);
    @memcpy(bytes[second_data .. second_data + second.len], second);

    return bytes;
}

test "parse keeps every image and resolves the 256-byte zero" {
    const alloc = testing.allocator;
    const bytes = try sampleIco(alloc);
    defer alloc.free(bytes);

    const icon = try parse(alloc, bytes);
    defer icon.deinit();

    try testing.expectEqual(@as(usize, 2), icon.imageCount());
    try testing.expectEqual(@as(u16, 16), icon.images[0].pixelWidth());
    try testing.expectEqual(@as(u16, 256), icon.images[1].pixelWidth());
    try testing.expectEqual(@as(u16, 32), icon.images[0].bit_count);
    try testing.expectEqualStrings("\x01\x02\x03\x04", icon.images[0].bytes);
    try testing.expectEqualStrings("\x05\x06\x07\x08\x09", icon.images[1].bytes);
}

test "groupBlob is a GRPICONDIR whose ids are 1-based" {
    const alloc = testing.allocator;
    const bytes = try sampleIco(alloc);
    defer alloc.free(bytes);
    const icon = try parse(alloc, bytes);
    defer icon.deinit();

    const group = try icon.groupBlob(alloc);
    defer alloc.free(group);

    // 6-byte header + 14 bytes per image.
    try testing.expectEqual(@as(usize, 6 + 2 * 14), group.len);
    try testing.expectEqual(@as(u16, 1), readU16(group, 2));
    try testing.expectEqual(@as(u16, 2), readU16(group, 4));
    try testing.expectEqual(@as(u8, 16), group[6]); // width
    try testing.expectEqual(@as(u8, 16), group[7]); // height
    try testing.expectEqual(@as(u32, 4), readU32(group, 6 + 8));
    try testing.expectEqual(@as(u16, 1), readU16(group, 6 + 12));
    try testing.expectEqual(@as(u16, 2), readU16(group, 6 + 14 + 12));
}

test "parse rejects truncated, empty and misaligned files" {
    const alloc = testing.allocator;

    try testing.expectError(error.Truncated, parse(alloc, "\x00\x00\x01"));
    try testing.expectError(error.NotAnIcon, parse(alloc, "\x00\x00\x02\x00\x01\x00"));

    var empty: [6]u8 = undefined;
    @memset(&empty, 0);
    std.mem.writeInt(u16, empty[2..4], 1, .little);
    try testing.expectError(error.NoImages, parse(alloc, &empty));

    const bytes = try sampleIco(alloc);
    defer alloc.free(bytes);
    // Truncate the directory: the header promises two entries but only one fits.
    try testing.expectError(error.Truncated, parse(alloc, bytes[0 .. header_size + entry_size]));
    // Point an entry past the end of the file.
    var broken = try alloc.dupe(u8, bytes);
    defer alloc.free(broken);
    std.mem.writeInt(u32, broken[header_size + 12 ..][0..4], 0xffff, .little);
    try testing.expectError(error.BadEntry, parse(alloc, broken));
}
