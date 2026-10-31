//! `.deb` writer (`M5-03`).
//!
//! A Debian package is an `ar` archive with exactly three members:
//!
//! ```text
//! !<arch>\n
//! debian-binary      "2.0\n"
//! control.tar.gz     ./control, ./md5sums
//! data.tar.gz        ./usr/bin/<name>, ./usr/share/… (the plan)
//! ```
//!
//! Everything is generated in memory with `std.tar.Writer` and `std.compress.flate`, so the same
//! bytes come out on Linux, macOS and Windows — `dpkg-deb` is not needed to build a package, and
//! the tests can inspect the archive without shelling out.
//!
//! Determinism: tar mtimes are 0, the gzip header carries no timestamp and no file name, and the
//! `ar` headers use a fixed uid/gid/mode. Two builds of the same binary are byte-identical, which
//! is what makes "did packaging change?" a diff instead of a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;
const tar = std.tar;
const testing = std.testing;

const app_mod = @import("app.zig");
const plan_mod = @import("plan.zig");
const App = app_mod.App;
const Package = plan_mod.Package;

/// Fixed timestamp for every `ar` member and tar entry (1980-01-01, the ZIP epoch, is a common
/// reproducible-build choice; 0 keeps it obvious that nothing here is "now").
pub const fixed_mtime: u64 = 0;

/// Builds a complete `.deb` for `payload`. `architecture` is the Debian spelling
/// (`amd64`, `arm64`, …) — see `app.debArchitecture`.
pub fn buildAlloc(allocator: Allocator, app: App, payload: Package, architecture: []const u8) ![]u8 {
    const control = try app.controlFile(allocator, payload.installedSizeKib(), architecture);
    defer allocator.free(control);

    const md5sums = try renderMd5sums(allocator, payload);
    defer allocator.free(md5sums);

    const control_tar = try tarGzAlloc(allocator, &.{
        .{ .path = "control", .bytes = control, .mode = 0o644 },
        .{ .path = "md5sums", .bytes = md5sums, .mode = 0o644 },
    });
    defer allocator.free(control_tar);

    const data_tar = try tarGzAlloc(allocator, payload.entries);
    defer allocator.free(data_tar);

    return arAlloc(allocator, &.{
        .{ .name = "debian-binary", .bytes = "2.0\n" },
        .{ .name = "control.tar.gz", .bytes = control_tar },
        .{ .name = "data.tar.gz", .bytes = data_tar },
    });
}

/// `md5sums` lines are `<hash>  <path>` with the path exactly as `dpkg -c` prints it (no `./`).
pub fn renderMd5sums(allocator: Allocator, payload: Package) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    for (payload.entries) |entry| {
        if (std.mem.endsWith(u8, entry.path, "/")) continue;
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(entry.bytes, &digest, .{});
        w.print("{s}  {s}\n", .{ std.fmt.bytesToHex(digest, .lower), entry.path }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Tar entries use `./`-prefixed paths and a fixed mtime, matching what `dpkg-deb` writes.
pub fn tarGzAlloc(allocator: Allocator, entries: []const plan_mod.Entry) ![]u8 {
    var window: [flate.max_window_len]u8 = undefined;
    var buffer: Io.Writer.Allocating = try .initCapacity(allocator, 8192);
    errdefer buffer.deinit();

    var compress = try flate.Compress.init(&buffer.writer, &window, .gzip, .default);
    var writer = tar.Writer{ .underlying_writer = &compress.writer };

    try writer.writeDir("./", .{ .mode = 0o755, .mtime = fixed_mtime });
    for (entries) |entry| {
        // Freed at the end of every iteration: `writeFileBytes` copies the path into the header.
        const path = try std.fmt.allocPrint(allocator, "./{s}", .{entry.path});
        defer allocator.free(path);
        try writer.writeFileBytes(path, entry.bytes, .{ .mode = entry.mode, .mtime = fixed_mtime });
    }
    try writer.finishPedantically();
    try compress.finish();

    return buffer.toOwnedSlice();
}

pub const Member = struct { name: []const u8, bytes: []const u8 };

/// `ar` archive with the deterministic header Debian expects (uid/gid 0, mode 100644, mtime 0).
pub fn arAlloc(allocator: Allocator, members: []const Member) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("!<arch>\n");
    for (members) |member| {
        var header: [60]u8 = @splat(' ');
        if (member.name.len > 16) return error.NameTooLong;
        @memcpy(header[0..member.name.len], member.name);
        writeField(header[16..28], "0"); // mtime
        writeField(header[28..34], "0"); // uid
        writeField(header[34..40], "0"); // gid
        writeField(header[40..48], "100644"); // mode (octal)
        var size_buf: [20]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{d}", .{member.bytes.len});
        writeField(header[48..58], size);
        header[58] = '`';
        header[59] = '\n';

        try w.writeAll(&header);
        try w.writeAll(member.bytes);
        // Members are aligned to two bytes with a newline.
        if (member.bytes.len % 2 == 1) try w.writeAll("\n");
    }
    return out.toOwnedSlice();
}

fn writeField(field: []u8, text: []const u8) void {
    @memset(field, ' ');
    @memcpy(field[0..text.len], text);
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

fn sampleApp() App {
    return App.init(
        "demo_app",
        "Demo App",
        "1.2.3",
        "com.example.demo",
        "A demo application",
        "Dev <dev@example.com>",
    ) catch unreachable;
}

/// Reads back the members of an `ar` archive: names and payloads, in order.
fn parseAr(allocator: Allocator, bytes: []const u8) ![]Member {
    if (!std.mem.startsWith(u8, bytes, "!<arch>\n")) return error.NotAnArchive;
    var list: std.ArrayListUnmanaged(Member) = .empty;
    errdefer {
        for (list.items) |m| {
            allocator.free(m.name);
            allocator.free(m.bytes);
        }
        list.deinit(allocator);
    }
    var offset: usize = 8;
    while (offset + 60 <= bytes.len) {
        const header = bytes[offset .. offset + 60];
        const raw_name = std.mem.trimEnd(u8, header[0..16], " ");
        const size_text = std.mem.trim(u8, header[48..58], " ");
        const size = try std.fmt.parseInt(usize, size_text, 10);
        offset += 60;
        if (offset + size > bytes.len) return error.TruncatedArchive;
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, raw_name),
            .bytes = try allocator.dupe(u8, bytes[offset .. offset + size]),
        });
        offset += size + (size % 2);
    }
    return list.toOwnedSlice(allocator);
}

fn gunzip(allocator: Allocator, bytes: []const u8) ![]u8 {
    var source: Io.Reader = .fixed(bytes);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(&source, .gzip, &window);
    return decompress.reader.allocRemaining(allocator, .unlimited);
}

test "buildAlloc produces the three ar members Debian requires, in order" {
    const alloc = testing.allocator;
    const app = sampleApp();
    var payload = try plan_mod.debPayload(alloc, app, .{ .binary = "MZ fake binary" });
    defer payload.deinit(alloc);

    const deb = try buildAlloc(alloc, app, payload, "amd64");
    defer alloc.free(deb);

    const members = try parseAr(alloc, deb);
    defer {
        for (members) |m| {
            alloc.free(m.name);
            alloc.free(m.bytes);
        }
        alloc.free(members);
    }

    try testing.expectEqual(@as(usize, 3), members.len);
    try testing.expectEqualStrings("debian-binary", members[0].name);
    try testing.expectEqualStrings("2.0\n", members[0].bytes);
    try testing.expectEqualStrings("control.tar.gz", members[1].name);
    try testing.expectEqualStrings("data.tar.gz", members[2].name);

    // gzip magic.
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, members[1].bytes[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, members[2].bytes[0..2]);
}

test "control.tar.gz carries a control file dpkg would accept" {
    const alloc = testing.allocator;
    const app = sampleApp();
    var payload = try plan_mod.debPayload(alloc, app, .{ .binary = "MZ fake binary" });
    defer payload.deinit(alloc);

    const deb = try buildAlloc(alloc, app, payload, "arm64");
    defer alloc.free(deb);
    const members = try parseAr(alloc, deb);
    defer {
        for (members) |m| {
            alloc.free(m.name);
            alloc.free(m.bytes);
        }
        alloc.free(members);
    }

    const control_tar = try gunzip(alloc, members[1].bytes);
    defer alloc.free(control_tar);

    // tar entries start with the 512-byte header whose first field is the name.
    try testing.expect(std.mem.startsWith(u8, control_tar, "./"));
    try testing.expect(std.mem.find(u8, control_tar, "Package: demo-app\n") != null);
    try testing.expect(std.mem.find(u8, control_tar, "Architecture: arm64\n") != null);
    try testing.expect(std.mem.find(u8, control_tar, "Maintainer: Dev <dev@example.com>\n") != null);
    try testing.expect(std.mem.find(u8, control_tar, "md5sums") != null);
    // The md5 of the fake binary is right there.
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("MZ fake binary", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try testing.expect(std.mem.find(u8, control_tar, &hex) != null);
}

test "data.tar.gz carries the executable with its mode" {
    const alloc = testing.allocator;
    const app = sampleApp();
    var payload = try plan_mod.debPayload(alloc, app, .{ .binary = "MZ fake binary" });
    defer payload.deinit(alloc);

    const deb = try buildAlloc(alloc, app, payload, "amd64");
    defer alloc.free(deb);
    const members = try parseAr(alloc, deb);
    defer {
        for (members) |m| {
            alloc.free(m.name);
            alloc.free(m.bytes);
        }
        alloc.free(members);
    }

    const data_tar = try gunzip(alloc, members[2].bytes);
    defer alloc.free(data_tar);

    try testing.expect(std.mem.find(u8, data_tar, "./usr/bin/demo_app") != null);
    // The tar mode field is octal ASCII at offset 100 of the executable's header.
    const header_offset = std.mem.find(u8, data_tar, "./usr/bin/demo_app").? - @as(usize, 0);
    // The name lives at the start of a 512-byte header; rewind to it.
    const block = header_offset - (header_offset % 512);
    const mode_field = data_tar[block + 100 .. block + 100 + 7];
    try testing.expectEqualStrings("0000755", mode_field);
}

test "packaging the same payload twice is byte-identical" {
    const alloc = testing.allocator;
    const app = sampleApp();
    var payload = try plan_mod.debPayload(alloc, app, .{ .binary = "MZ fake binary" });
    defer payload.deinit(alloc);

    const first = try buildAlloc(alloc, app, payload, "amd64");
    defer alloc.free(first);
    const second = try buildAlloc(alloc, app, payload, "amd64");
    defer alloc.free(second);
    try testing.expectEqualSlices(u8, first, second);

    // The gzip header timestamp (bytes 4..8) is zero, so the output does not depend on the clock.
    const members = try parseAr(alloc, first);
    defer {
        for (members) |m| {
            alloc.free(m.name);
            alloc.free(m.bytes);
        }
        alloc.free(members);
    }
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, members[2].bytes[4..8]);
}

test "ar rejects a name that cannot fit its 16-byte field" {
    const alloc = testing.allocator;
    try testing.expectError(error.NameTooLong, arAlloc(alloc, &.{.{
        .name = "this-name-is-way-too-long",
        .bytes = "x",
    }}));
}
