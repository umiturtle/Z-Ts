//! Materialise a [`plan.Package`] into a directory (`M5-03`).
//!
//! This is the only bundler module that writes to disk, and it is deliberately dumb: create the
//! parents, write the bytes, set the mode. The AppDir and the macOS `.app` are both "a directory
//! with files in it", so one writer serves both, and `zts package --format appdir` produces exactly
//! what the `.deb` payload would contain.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const plan = @import("plan.zig");
const Package = plan.Package;

/// Writes `package` under `root` (created if missing). Existing files are overwritten, so packing
/// into `zig-out/package` twice does not accumulate stale icons.
pub fn write(io: Io, root: Io.Dir, package: Package) !void {
    for (package.entries) |entry| {
        if (std.fs.path.dirname(entry.path)) |parent| {
            if (parent.len > 0) try root.createDirPath(io, parent);
        }
        var file = try root.createFile(io, entry.path, .{ .permissions = permissionsFor(entry.mode) });
        defer file.close(io);
        try file.writeStreamingAll(io, entry.bytes);
    }
}

/// Creates `<parent>/<name>/` and writes `package` into it. Used for `.AppDir` and `.app` because
/// both formats are a named directory that the user double-clicks.
pub fn writeNamed(io: Io, parent: Io.Dir, name: []const u8, package: Package) !void {
    try parent.createDirPath(io, name);
    var dir = try parent.openDir(io, name, .{});
    defer dir.close(io);
    try write(io, dir, package);
}

/// Maps POSIX permission bits onto `Io.File.Permissions`, which is a bit set on POSIX and an
/// attribute word on Windows (where the executable bit does not exist and is ignored).
fn permissionsFor(mode: u32) Io.File.Permissions {
    if (comptime Io.File.Permissions.has_executable_bit) {
        return .fromMode(@intCast(mode));
    } else {
        return .default_file;
    }
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

test "write creates parents, sets the executable bit and overwrites stale files" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const entries = [_]plan.Entry{
        .{ .path = "usr/bin/demo", .bytes = "binary", .mode = 0o755 },
        .{ .path = "usr/share/applications/demo.desktop", .bytes = "[Desktop Entry]\n", .mode = 0o644 },
    };
    const package: Package = .{ .entries = @constCast(&entries) };
    try write(io, tmp.dir, package);

    const bin = try tmp.dir.readFileAlloc(io, "usr/bin/demo", alloc, .limited(1024));
    defer alloc.free(bin);
    try testing.expectEqualStrings("binary", bin);

    const desktop = try tmp.dir.readFileAlloc(io, "usr/share/applications/demo.desktop", alloc, .limited(1024));
    defer alloc.free(desktop);
    try testing.expectEqualStrings("[Desktop Entry]\n", desktop);

    if (comptime @import("builtin").os.tag != .windows) {
        const stat = try tmp.dir.statFile(io, "usr/bin/demo", .{});
        try testing.expect(stat.permissions.readOnly() == false);
        try testing.expect(@as(u32, @intCast(stat.permissions.toMode())) & 0o111 != 0);

        const plain = try tmp.dir.statFile(io, "usr/share/applications/demo.desktop", .{});
        try testing.expect(@as(u32, @intCast(plain.permissions.toMode())) & 0o111 == 0);
    }

    // Overwriting replaces the payload instead of appending.
    const replacement = [_]plan.Entry{.{ .path = "usr/bin/demo", .bytes = "new", .mode = 0o755 }};
    try write(io, tmp.dir, .{ .entries = @constCast(&replacement) });
    const again = try tmp.dir.readFileAlloc(io, "usr/bin/demo", alloc, .limited(1024));
    defer alloc.free(again);
    try testing.expectEqualStrings("new", again);
}

test "writeNamed creates a package directory (the AppDir shape)" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const entries = [_]plan.Entry{.{ .path = "AppRun", .bytes = "#!/bin/sh\n", .mode = 0o755 }};
    try writeNamed(io, tmp.dir, "Demo.AppDir", .{ .entries = @constCast(&entries) });

    const app_run = try tmp.dir.readFileAlloc(io, "Demo.AppDir/AppRun", alloc, .limited(1024));
    defer alloc.free(app_run);
    try testing.expectEqualStrings("#!/bin/sh\n", app_run);
}
