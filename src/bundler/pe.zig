//! Windows `.exe` resources (`M5-03`).
//!
//! Zig has no `windres`, and `std.Build` in 0.17 cannot attach an `.rc`. Rather than depend on a
//! Windows toolchain, this module appends an `.rsrc` section to an already-linked PE file:
//!
//! ```text
//! .rsrc ─┬─ IMAGE_RESOURCE_DIRECTORY (type 3 = RT_ICON)  ─ id 1..N ─ lang ─ data
//!        ├─ type 14 = RT_GROUP_ICON                        ─ id 1
//!        └─ type 24 = RT_MANIFEST                           ─ id 1
//! ```
//!
//! It is pure Zig and runs on any host, so `zts package --format exe` can brand a cross-compiled
//! binary from Linux. Only a section is added — no existing byte moves, so code, relocations and
//! the entry point stay exactly where the linker put them.
//!
//! The `PE32` / `PE32+` optional headers share the offsets used here (`SectionAlignment` at +32,
//! `SizeOfImage` at +56, `NumberOfRvaAndSizes` at +92/+108, data directories at +96/+112), which is
//! why one parser covers both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ico = @import("ico.zig");

pub const InjectError = error{
    NotAPe,
    UnsupportedPe,
    NoHeaderRoom,
    ResourceSectionExists,
    TooManyResources,
    OutOfMemory,
};

/// `RT_ICON`, `RT_GROUP_ICON`, `RT_MANIFEST` — the three resource types a branded app needs.
pub const rt_icon: u16 = 3;
pub const rt_group_icon: u16 = 14;
pub const rt_manifest: u16 = 24;
/// `0x0409` = en-US. Windows falls back to any language if the exact one is missing.
pub const default_language: u16 = 0x0409;

pub const IconResources = struct {
    /// `GRPICONDIR` from `ico.Icon.groupBlob`.
    group: []const u8,
    /// `RT_ICON` payloads, index `i` is resource id `i + 1`.
    images: []const []const u8,
};

pub const Resources = struct {
    icon: ?IconResources = null,
    /// Application manifest XML (DPI awareness, supported OS list, …).
    manifest: ?[]const u8 = null,

    fn isEmpty(self: Resources) bool {
        return self.icon == null and self.manifest == null;
    }
};

/// Returns a copy of `bytes` with an `.rsrc` section appended.
pub fn injectAlloc(allocator: Allocator, bytes: []const u8, resources: Resources) InjectError![]u8 {
    if (resources.isEmpty()) return allocator.dupe(u8, bytes) catch unreachable;
    if (resources.icon) |icon| {
        if (icon.images.len > ico.max_images) return error.TooManyResources;
    }

    const view = try View.parse(bytes);

    // An existing `.rsrc` (a resource-carrying linker script) cannot be merged safely, and
    // duplicating the type ids would make Windows pick one at random.
    var index: usize = 0;
    while (index < view.section_count) : (index += 1) {
        const name = view.sectionHeader(index)[0..8];
        if (std.mem.eql(u8, std.mem.trimEnd(u8, name, "\x00"), ".rsrc")) return error.ResourceSectionExists;
    }

    const new_va = std.mem.alignForward(u32, view.image_end(), view.section_alignment);
    const blob = try buildResourceSection(allocator, resources, new_va);
    errdefer allocator.free(blob);

    const raw_size = std.mem.alignForward(u32, @intCast(blob.len), view.file_alignment);
    const raw_offset = std.mem.alignForward(u32, @intCast(bytes.len), view.file_alignment);
    const header_slot = view.section_table + 40 * @as(usize, view.section_count);
    if (header_slot + 40 > view.size_of_headers) return error.NoHeaderRoom;
    if (header_slot + 40 > raw_offset) return error.NoHeaderRoom;

    const new_len = @as(usize, raw_offset) + raw_size;
    const out = try allocator.alloc(u8, new_len);
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
    @memcpy(out[raw_offset .. raw_offset + blob.len], blob);

    // Section header: ".rsrc", virtual size, RVA, raw size, raw offset, read-only data.
    const header = out[header_slot .. header_slot + 40];
    @memset(header, 0);
    @memcpy(header[0..5], ".rsrc");
    writeU32(header, 8, @intCast(blob.len));
    writeU32(header, 12, new_va);
    writeU32(header, 16, raw_size);
    writeU32(header, 20, raw_offset);
    writeU32(header, 36, 0x4000_0040); // IMAGE_SCN_CNT_INITIALIZED_DATA | MEM_READ

    // COFF: one more section.
    writeU16(out, view.pe_offset + 6, view.section_count + 1);
    // Optional header: SizeOfInitializedData, SizeOfImage, data directory entry 2.
    writeU32(out, view.optional + 8, view.size_of_initialized_data + raw_size);
    writeU32(out, view.optional + 56, new_va + std.mem.alignForward(u32, @intCast(blob.len), view.section_alignment));
    writeU32(out, view.data_directory + 2 * 8, new_va);
    writeU32(out, view.data_directory + 2 * 8 + 4, @intCast(blob.len));
    updateChecksum(out, view.optional + 64);

    allocator.free(blob);
    return out;
}

/// Everything `injectAlloc` needs to know about the input file.
const View = struct {
    bytes: []const u8,
    pe_offset: usize,
    optional: usize,
    section_table: usize,
    section_count: u16,
    size_of_optional: u16,
    data_directory: usize,
    section_alignment: u32,
    file_alignment: u32,
    size_of_initialized_data: u32,
    size_of_headers: usize,

    fn parse(bytes: []const u8) InjectError!View {
        if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..2], "MZ")) return error.NotAPe;
        const pe_offset: usize = readU32(bytes, 0x3c);
        if (pe_offset + 24 > bytes.len) return error.NotAPe;
        if (!std.mem.eql(u8, bytes[pe_offset .. pe_offset + 4], "PE\x00\x00")) return error.NotAPe;

        const section_count = readU16(bytes, pe_offset + 6);
        const size_of_optional = readU16(bytes, pe_offset + 20);
        const optional = pe_offset + 24;
        if (optional + size_of_optional > bytes.len) return error.NotAPe;
        if (section_count > 64) return error.UnsupportedPe;

        const magic = readU16(bytes, optional);
        const data_directory = switch (magic) {
            0x10b => optional + 96, // PE32
            0x20b => optional + 112, // PE32+
            else => return error.UnsupportedPe,
        };
        if (data_directory + 16 * 8 > optional + size_of_optional) return error.UnsupportedPe;

        const section_table = optional + size_of_optional;
        if (section_table + 40 * @as(usize, section_count) > bytes.len) return error.NotAPe;

        return .{
            .bytes = bytes,
            .pe_offset = pe_offset,
            .optional = optional,
            .section_table = section_table,
            .section_count = section_count,
            .size_of_optional = size_of_optional,
            .data_directory = data_directory,
            .section_alignment = readU32(bytes, optional + 32),
            .file_alignment = readU32(bytes, optional + 36),
            .size_of_initialized_data = readU32(bytes, optional + 8),
            .size_of_headers = readU32(bytes, optional + 60),
        };
    }

    fn sectionHeader(self: *const View, index: usize) []const u8 {
        const offset = self.section_table + 40 * index;
        return self.bytes[offset .. offset + 40];
    }

    /// One past the highest `VirtualAddress + max(VirtualSize, SizeOfRawData)`.
    fn image_end(self: *const View) u32 {
        var end: u32 = 0;
        var index: usize = 0;
        while (index < self.section_count) : (index += 1) {
            const header = self.sectionHeader(index);
            const virtual_size = readU32(header, 8);
            const virtual_address = readU32(header, 12);
            const raw_size = readU32(header, 16);
            const size = @max(virtual_size, raw_size);
            end = @max(end, virtual_address + std.mem.alignForward(u32, size, self.section_alignment));
        }
        return end;
    }
};

/// Renders the `.rsrc` payload: a three-level directory tree plus the data blobs.
///
/// Offsets inside the tree are relative to the section's RVA, so the caller must know `base_rva`
/// first — it only depends on the sections already in the file.
const Leaf = struct { kind: u16, id: u16, bytes: []const u8 };

fn buildResourceSection(allocator: Allocator, resources: Resources, base_rva: u32) InjectError![]u8 {
    var leaves: std.ArrayListUnmanaged(Leaf) = .empty;
    defer leaves.deinit(allocator);
    if (resources.icon) |icon| {
        for (icon.images, 0..) |image, index| {
            leaves.append(allocator, .{ .kind = rt_icon, .id = @intCast(index + 1), .bytes = image }) catch return error.OutOfMemory;
        }
        leaves.append(allocator, .{ .kind = rt_group_icon, .id = 1, .bytes = icon.group }) catch return error.OutOfMemory;
    }
    if (resources.manifest) |manifest| {
        leaves.append(allocator, .{ .kind = rt_manifest, .id = 1, .bytes = manifest }) catch return error.OutOfMemory;
    }
    if (leaves.items.len == 0) return error.TooManyResources;

    // Leaves are appended icon-first; sort by (kind, id) so the directory order is deterministic.
    std.mem.sort(Leaf, leaves.items, {}, struct {
        fn lessThan(_: void, a: Leaf, b: Leaf) bool {
            if (a.kind != b.kind) return a.kind < b.kind;
            return a.id < b.id;
        }
    }.lessThan);

    const types = try collectTypes(allocator, leaves.items);
    defer allocator.free(types);

    // Layout: root dir, one dir per type, one language dir per leaf (a directory with exactly one
    // entry is 16 + 8 bytes), the data entries, then the blobs.
    var total: usize = 16 + 8 * types.len;
    for (types) |entry| total += 16 + 8 * entry.count;
    total += (16 + 8) * leaves.items.len;
    total += 16 * leaves.items.len;
    var offset = total;
    var data_offsets = try allocator.alloc(u32, leaves.items.len);
    defer allocator.free(data_offsets);
    for (leaves.items, 0..) |leaf, index| {
        offset = std.mem.alignForward(usize, offset, 4);
        data_offsets[index] = @intCast(offset);
        offset += leaf.bytes.len;
    }

    const blob = try allocator.alloc(u8, offset);
    @memset(blob, 0);

    // Root directory: one entry per type.
    var cursor: usize = 16 + 8 * types.len;
    writeU16(blob, 14, @intCast(types.len));
    for (types, 0..) |entry, index| {
        const dir_offset = cursor;
        writeU32(blob, 16 + 8 * index, entry.kind);
        writeU32(blob, 16 + 8 * index + 4, @as(u32, @intCast(dir_offset)) | 0x8000_0000);
        cursor += 16 + 8 * entry.count;
    }

    // Per-type directories, then per-id directories, then data entries.
    var leaf_index: usize = 0;
    var type_cursor: usize = 16 + 8 * types.len;
    var leaf_dir_cursor = type_cursor;
    for (types) |entry| leaf_dir_cursor += 16 + 8 * entry.count;
    var data_entry_cursor = leaf_dir_cursor;
    for (types) |entry| data_entry_cursor += (16 + 8) * entry.count;

    for (types) |entry| {
        writeU16(blob, type_cursor + 14, @intCast(entry.count));
        var name_index: usize = 0;
        while (name_index < entry.count) : (name_index += 1) {
            const leaf = leaves.items[leaf_index];
            writeU32(blob, type_cursor + 16 + 8 * name_index, leaf.id);
            writeU32(blob, type_cursor + 16 + 8 * name_index + 4, @as(u32, @intCast(leaf_dir_cursor)) | 0x8000_0000);

            // Language directory: one entry, en-US, pointing straight at the data entry.
            writeU16(blob, leaf_dir_cursor + 14, 1);
            writeU32(blob, leaf_dir_cursor + 16, default_language);
            writeU32(blob, leaf_dir_cursor + 20, @intCast(data_entry_cursor));

            // Data entry: RVA, size, codepage, reserved.
            writeU32(blob, data_entry_cursor, base_rva + data_offsets[leaf_index]);
            writeU32(blob, data_entry_cursor + 4, @intCast(leaf.bytes.len));
            writeU32(blob, data_entry_cursor + 8, 0);
            writeU32(blob, data_entry_cursor + 12, 0);
            @memcpy(blob[data_offsets[leaf_index] .. data_offsets[leaf_index] + leaf.bytes.len], leaf.bytes);

            leaf_dir_cursor += 16 + 8;
            data_entry_cursor += 16;
            leaf_index += 1;
        }
        type_cursor += 16 + 8 * entry.count;
    }

    return blob;
}

const TypeEntry = struct { kind: u16, count: usize };

/// Groups the sorted leaves into one entry per resource type, counting ids per type.
fn collectTypes(allocator: Allocator, leaves: []const Leaf) InjectError![]TypeEntry {
    var list: std.ArrayListUnmanaged(TypeEntry) = .empty;
    errdefer list.deinit(allocator);
    for (leaves) |leaf| {
        if (list.items.len > 0 and list.items[list.items.len - 1].kind == leaf.kind) {
            list.items[list.items.len - 1].count += 1;
        } else {
            list.append(allocator, .{ .kind = leaf.kind, .count = 1 }) catch return error.OutOfMemory;
        }
    }
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

/// Standard PE checksum: 16-bit ones' complement sum of every word, folded, plus the file length.
fn updateChecksum(bytes: []u8, checksum_offset: usize) void {
    writeU32(bytes, checksum_offset, 0);
    var sum: u64 = 0;
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) {
        sum += readU16(bytes, index);
        sum = (sum & 0xffff) + (sum >> 16);
    }
    if (index < bytes.len) {
        sum += bytes[index];
        sum = (sum & 0xffff) + (sum >> 16);
    }
    sum = (sum & 0xffff) + (sum >> 16);
    const checksum = @as(u32, @truncate(sum)) +% @as(u32, @intCast(bytes.len));
    writeU32(bytes, checksum_offset, checksum);
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

/// A minimal but structurally valid PE32+ image with one `.text` section.
fn samplePe(allocator: Allocator) ![]u8 {
    const file_alignment = 0x200;
    const size_of_headers = 0x200;
    const text_offset = 0x200;
    const total = 0x400;
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);

    @memcpy(bytes[0..2], "MZ");
    writeU32(bytes, 0x3c, 0x40);

    @memcpy(bytes[0x40..0x44], "PE\x00\x00");
    writeU16(bytes, 0x44, 0x8664); // machine: x86-64
    writeU16(bytes, 0x46, 1); // one section
    writeU16(bytes, 0x54, 0xf0); // SizeOfOptionalHeader (PE32+ with 16 directories)
    writeU16(bytes, 0x56, 0x22); // executable | large address aware

    const optional = 0x58;
    writeU16(bytes, optional, 0x20b); // PE32+
    writeU32(bytes, optional + 8, file_alignment); // SizeOfInitializedData
    writeU32(bytes, optional + 32, 0x1000); // SectionAlignment
    writeU32(bytes, optional + 36, file_alignment); // FileAlignment
    writeU32(bytes, optional + 56, 0x2000); // SizeOfImage
    writeU32(bytes, optional + 60, size_of_headers); // SizeOfHeaders
    writeU16(bytes, optional + 68, 3); // Subsystem: console
    writeU32(bytes, optional + 108, 16); // NumberOfRvaAndSizes

    const section = optional + 0xf0;
    @memcpy(bytes[section..][0..8], ".text\x00\x00\x00");
    writeU32(bytes, section + 8, 0x10); // VirtualSize
    writeU32(bytes, section + 12, 0x1000); // VirtualAddress
    writeU32(bytes, section + 16, file_alignment); // SizeOfRawData
    writeU32(bytes, section + 20, text_offset); // PointerToRawData
    writeU32(bytes, section + 36, 0x6000_0020); // code | execute | read

    // A recognizable code byte so the test can prove it survived.
    bytes[text_offset] = 0xc3; // ret
    return bytes;
}

fn sampleResources(allocator: Allocator) !struct { icon: IconResources, manifest: []const u8 } {
    const first = "\xaa\xbb\xcc\xdd";
    const second = "\x01\x02\x03";
    const images = try allocator.alloc([]const u8, 2);
    images[0] = first;
    images[1] = second;
    const group = try allocator.alloc(u8, 6 + 2 * 14);
    @memset(group, 0);
    writeU16(group, 2, 1);
    writeU16(group, 4, 2);
    return .{ .icon = .{ .group = group, .images = images }, .manifest = "<assembly/>" };
}

test "a PE without resources gains a .rsrc section and keeps its code" {
    const alloc = testing.allocator;
    const pe_bytes = try samplePe(alloc);
    defer alloc.free(pe_bytes);
    const res = try sampleResources(alloc);
    defer {
        alloc.free(res.icon.group);
        alloc.free(res.icon.images);
    }

    const out = try injectAlloc(alloc, pe_bytes, .{ .icon = res.icon, .manifest = res.manifest });
    defer alloc.free(out);

    try testing.expectEqualStrings("MZ", out[0..2]);
    // Two sections now.
    try testing.expectEqual(@as(u16, 2), readU16(out, 0x40 + 6));
    const second_section = 0x58 + 0xf0 + 40;
    try testing.expectEqualStrings(".rsrc", std.mem.trimEnd(u8, out[second_section..][0..8], "\x00"));

    const resource_rva = readU32(out, second_section + 12);
    const raw_offset = readU32(out, second_section + 20);
    const raw_size = readU32(out, second_section + 16);
    try testing.expectEqual(@as(u32, 0x2000), resource_rva); // after .text (0x1000 + 0x1000)
    try testing.expectEqual(@as(u32, 0x400), raw_offset);
    try testing.expect(raw_size > 0);

    // The data directory now points at the new section.
    try testing.expectEqual(resource_rva, readU32(out, 0x58 + 112 + 2 * 8));
    // Code survived.
    try testing.expectEqual(@as(u8, 0xc3), out[0x200]);
    // SizeOfImage covers the new section.
    try testing.expectEqual(@as(u32, 0x3000), readU32(out, 0x58 + 56));
    // Checksum is non-zero after the update.
    try testing.expect(readU32(out, 0x58 + 64) != 0);
}

test "the resource tree is walkable: types, ids, language and payloads" {
    const alloc = testing.allocator;
    const pe_bytes = try samplePe(alloc);
    defer alloc.free(pe_bytes);
    const res = try sampleResources(alloc);
    defer {
        alloc.free(res.icon.group);
        alloc.free(res.icon.images);
    }

    const out = try injectAlloc(alloc, pe_bytes, .{ .icon = res.icon, .manifest = res.manifest });
    defer alloc.free(out);

    const section = 0x58 + 0xf0 + 40;
    const base = readU32(out, section + 20);
    const rva_base = readU32(out, section + 12);
    const root = out[base..];

    const type_count = readU16(root, 14);
    try testing.expectEqual(@as(u16, 3), type_count);
    try testing.expectEqual(rt_icon, readU32(root, 16));
    try testing.expectEqual(rt_group_icon, readU32(root, 24));
    try testing.expectEqual(rt_manifest, readU32(root, 32));

    // Walk the first type (RT_ICON): two images with ids 1 and 2.
    const icon_dir_offset = readU32(root, 20) & 0x7fff_ffff;
    try testing.expectEqual(@as(u16, 2), readU16(root, icon_dir_offset + 14));

    var found_ids: [2]u16 = undefined;
    var index: usize = 0;
    while (index < 2) : (index += 1) {
        found_ids[index] = @intCast(readU32(root, icon_dir_offset + 16 + 8 * index));
        const lang_dir = readU32(root, icon_dir_offset + 20 + 8 * index) & 0x7fff_ffff;
        try testing.expectEqual(@as(u16, 1), readU16(root, lang_dir + 14));
        try testing.expectEqual(default_language, readU32(root, lang_dir + 16));

        const data_entry = readU32(root, lang_dir + 20);
        const payload_rva = readU32(root, data_entry);
        const payload_size = readU32(root, data_entry + 4);
        try testing.expect(payload_rva >= base);
        const payload = root[payload_rva - rva_base ..][0..payload_size];
        try testing.expectEqualStrings(res.icon.images[index], payload);
    }
    try testing.expectEqualSlices(u16, &.{ 1, 2 }, &found_ids);

    // The manifest is the last type, id 1, and carries the XML verbatim.
    const manifest_dir = readU32(root, 36) & 0x7fff_ffff;
    const manifest_id = readU32(root, manifest_dir + 16);
    try testing.expectEqual(@as(u32, 1), manifest_id);
    const manifest_lang = readU32(root, manifest_dir + 20) & 0x7fff_ffff;
    const manifest_entry = readU32(root, manifest_lang + 20);
    const manifest_rva = readU32(root, manifest_entry);
    const manifest_size = readU32(root, manifest_entry + 4);
    try testing.expectEqualStrings(
        "<assembly/>",
        root[manifest_rva - rva_base ..][0..manifest_size],
    );
}

test "injecting twice is refused instead of duplicating resource ids" {
    const alloc = testing.allocator;
    const pe_bytes = try samplePe(alloc);
    defer alloc.free(pe_bytes);
    const res = try sampleResources(alloc);
    defer {
        alloc.free(res.icon.group);
        alloc.free(res.icon.images);
    }

    const once = try injectAlloc(alloc, pe_bytes, .{ .manifest = res.manifest });
    defer alloc.free(once);
    try testing.expectError(error.ResourceSectionExists, injectAlloc(alloc, once, .{ .manifest = res.manifest }));
}

test "non-PE inputs and empty resource sets are handled" {
    const alloc = testing.allocator;
    try testing.expectError(error.NotAPe, injectAlloc(alloc, "not a pe at all", .{ .manifest = "<a/>" }));

    const pe_bytes = try samplePe(alloc);
    defer alloc.free(pe_bytes);
    const copy = try injectAlloc(alloc, pe_bytes, .{});
    defer alloc.free(copy);
    try testing.expectEqualSlices(u8, pe_bytes, copy);
}
