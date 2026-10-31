//! The virtual package (`M5-03`).
//!
//! A layout (AppDir, `.app`, `.deb` payload, portable tarball) is described as a sorted list of
//! [`Entry`] values before anything touches the filesystem. That is what makes packaging testable:
//! the `.deb` writer and the directory writer must agree on the same plan, and a missing
//! `.desktop` file is `expect(find(".desktop") != null)` rather than an inspection of a tarball.
//!
//! Every builder is deterministic — entries are sorted by path, mtimes are fixed at zero by the
//! writers — so packaging the same binary twice produces the same bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const app_mod = @import("app.zig");
const App = app_mod.App;

/// One file in a package. Paths are POSIX and relative to the package root; writers add whatever
/// prefix their format needs (`./` for tar, `Contents/` for the macOS bundle, …).
pub const Entry = struct {
    path: []const u8,
    bytes: []const u8,
    /// POSIX permission bits. `0o755` for executables, `0o644` for everything else. Windows hosts
    /// ignore the executable bit; `tree.write` maps it onto the platform's permission type.
    mode: u32 = 0o644,

    pub fn isExecutable(self: Entry) bool {
        return self.mode & 0o111 != 0;
    }
};

/// A whole package. Owns every byte and path in `entries`.
pub const Package = struct {
    entries: []Entry,

    pub fn deinit(self: Package, allocator: Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.bytes);
        }
        allocator.free(self.entries);
    }

    /// Payload size in bytes (uncompressed).
    pub fn totalBytes(self: Package) u64 {
        var sum: u64 = 0;
        for (self.entries) |entry| sum += entry.bytes.len;
        return sum;
    }

    /// What Debian's `Installed-Size:` field wants: KiB, rounded up, with one 4 KiB block of
    /// headroom per file for filesystem metadata (dpkg's own `du`-based estimate does the same).
    pub fn installedSizeKib(self: Package) u64 {
        var sum: u64 = 0;
        for (self.entries) |entry| {
            sum += std.math.divCeil(u64, entry.bytes.len, 4096) catch 1;
        }
        return sum * 4 + @as(u64, @intCast(self.entries.len)) * 4;
    }

    pub fn find(self: Package, path: []const u8) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    /// The first icon-like entry (`.png` or the AppDir's `.DirIcon`).
    pub fn findIcon(self: Package) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.endsWith(u8, entry.path, ".png") or std.mem.endsWith(u8, entry.path, ".DirIcon")) return entry;
        }
        return null;
    }

    /// The first `.desktop` entry.
    pub fn findDesktop(self: Package) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.endsWith(u8, entry.path, ".desktop")) return entry;
        }
        return null;
    }
};

/// The executable and optional icons every layout needs.
pub const Payload = struct {
    /// File name under `usr/bin` / `Contents/MacOS`. Defaults to `app.name`.
    binary_name: []const u8 = "",
    /// The executable itself.
    binary: []const u8,
    /// 256×256 (or any square) PNG used by the AppDir, the `.deb` and the dock.
    icon_png: ?[]const u8 = null,
    /// Multi-size `.ico` for the Windows executable.
    icon_ico: ?[]const u8 = null,
    /// Files to append verbatim (`web/dist` payloads, licences, …). Paths are package-relative.
    extra: []const Entry = &.{},
};

fn effectiveName(payload: Payload, app: App) []const u8 {
    return if (payload.binary_name.len > 0) payload.binary_name else app.name;
}

/// Linux AppDir: the layout AppImage tooling consumes (`AppRun`, root `.desktop`, `.DirIcon`).
pub fn appDir(allocator: Allocator, app: App, payload: Payload) Allocator.Error!Package {
    var builder = Builder.init(allocator);
    errdefer builder.deinit();

    const name = effectiveName(payload, app);
    const bin_path = try std.fmt.allocPrint(allocator, "usr/bin/{s}", .{name});
    defer allocator.free(bin_path);
    try builder.add(bin_path, payload.binary, 0o755);

    const desktop = try app.desktopEntry(allocator);
    defer allocator.free(desktop);
    const desktop_path = try std.fmt.allocPrint(allocator, "usr/share/applications/{s}.desktop", .{name});
    defer allocator.free(desktop_path);
    try builder.add(desktop_path, desktop, 0o644);
    // The AppImage spec wants a copy at the root and a `.DirIcon` beside it.
    const root_desktop = try std.fmt.allocPrint(allocator, "{s}.desktop", .{name});
    defer allocator.free(root_desktop);
    try builder.add(root_desktop, desktop, 0o644);

    const app_run = try app.appRunScript(allocator);
    defer allocator.free(app_run);
    try builder.add("AppRun", app_run, 0o755);

    if (payload.icon_png) |png| {
        const icon_path = try std.fmt.allocPrint(allocator, "usr/share/icons/hicolor/128x128/apps/{s}.png", .{name});
        defer allocator.free(icon_path);
        try builder.add(icon_path, png, 0o644);
        try builder.add(".DirIcon", png, 0o644);
    }

    for (payload.extra) |entry| try builder.add(entry.path, entry.bytes, entry.mode);
    return builder.finish();
}

/// macOS `.app` bundle (without the `.dmg` wrapper, which needs `hdiutil` and is a CLI concern).
pub fn macApp(allocator: Allocator, app: App, payload: Payload) Allocator.Error!Package {
    var builder = Builder.init(allocator);
    errdefer builder.deinit();

    const name = effectiveName(payload, app);
    const plist = try app.infoPlist(allocator);
    defer allocator.free(plist);
    try builder.add("Contents/Info.plist", plist, 0o644);
    try builder.add("Contents/PkgInfo", "APPL????", 0o644);

    const bin_path = try std.fmt.allocPrint(allocator, "Contents/MacOS/{s}", .{name});
    defer allocator.free(bin_path);
    try builder.add(bin_path, payload.binary, 0o755);

    if (payload.icon_png) |png| {
        // `.icns` conversion needs Apple's `iconutil`, so a PNG is placed under the name macOS
        // reads for non-retina development builds; `--icon` documentation says so.
        const icon_path = try std.fmt.allocPrint(allocator, "Contents/Resources/{s}.png", .{name});
        defer allocator.free(icon_path);
        try builder.add(icon_path, png, 0o644);
    }

    for (payload.extra) |entry| try builder.add(entry.path, entry.bytes, entry.mode);
    return builder.finish();
}

/// The files a `.deb`'s `data.tar` carries. `usr/share/doc/<pkg>/copyright` is the only file
/// Debian policy requires beyond the payload itself.
pub fn debPayload(allocator: Allocator, app: App, payload: Payload) Allocator.Error!Package {
    var builder = Builder.init(allocator);
    errdefer builder.deinit();

    const name = effectiveName(payload, app);
    const bin_path = try std.fmt.allocPrint(allocator, "usr/bin/{s}", .{name});
    defer allocator.free(bin_path);
    try builder.add(bin_path, payload.binary, 0o755);

    const desktop = try app.desktopEntry(allocator);
    defer allocator.free(desktop);
    const desktop_path = try std.fmt.allocPrint(allocator, "usr/share/applications/{s}.desktop", .{name});
    defer allocator.free(desktop_path);
    try builder.add(desktop_path, desktop, 0o644);

    if (payload.icon_png) |png| {
        const icon_path = try std.fmt.allocPrint(allocator, "usr/share/icons/hicolor/128x128/apps/{s}.png", .{name});
        defer allocator.free(icon_path);
        try builder.add(icon_path, png, 0o644);
    }

    const deb_name = try app.debName(allocator);
    defer allocator.free(deb_name);
    const copyright = try app.copyrightFile(allocator);
    defer allocator.free(copyright);
    const copyright_path = try std.fmt.allocPrint(allocator, "usr/share/doc/{s}/copyright", .{deb_name});
    defer allocator.free(copyright_path);
    try builder.add(copyright_path, copyright, 0o644);

    for (payload.extra) |entry| try builder.add(entry.path, entry.bytes, entry.mode);
    return builder.finish();
}

/// Portable `<name>-<version>/` tree for hosts that cannot build the platform package (and for
/// users who just want an archive).
pub fn portable(allocator: Allocator, app: App, payload: Payload) Allocator.Error!Package {
    var builder = Builder.init(allocator);
    errdefer builder.deinit();

    const name = effectiveName(payload, app);
    const bin_path = try std.fmt.allocPrint(allocator, "{s}-{s}/{s}", .{ name, app.version, name });
    defer allocator.free(bin_path);
    try builder.add(bin_path, payload.binary, 0o755);

    const desktop = try app.desktopEntry(allocator);
    defer allocator.free(desktop);
    const desktop_path = try std.fmt.allocPrint(allocator, "{s}-{s}/{s}.desktop", .{ name, app.version, name });
    defer allocator.free(desktop_path);
    try builder.add(desktop_path, desktop, 0o644);

    if (payload.icon_png) |png| {
        const icon_path = try std.fmt.allocPrint(allocator, "{s}-{s}/{s}.png", .{ name, app.version, name });
        defer allocator.free(icon_path);
        try builder.add(icon_path, png, 0o644);
    }

    for (payload.extra) |entry| try builder.add(entry.path, entry.bytes, entry.mode);
    return builder.finish();
}

/// Collects entries and keeps them sorted. Internal: callers get a [`Package`].
const Builder = struct {
    allocator: Allocator,
    list: std.ArrayListUnmanaged(Entry) = .empty,

    fn init(allocator: Allocator) Builder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Builder) void {
        for (self.list.items) |entry| {
            self.allocator.free(entry.path);
            self.allocator.free(entry.bytes);
        }
        self.list.deinit(self.allocator);
    }

    fn add(self: *Builder, path: []const u8, bytes: []const u8, mode: u32) Allocator.Error!void {
        if (self.find(path)) |existing| {
            // Two sources claiming one path is a packaging bug, not something to paper over.
            std.debug.assert(existing.mode == mode);
            return;
        }
        try self.list.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .bytes = try self.allocator.dupe(u8, bytes),
            .mode = mode,
        });
    }

    fn find(self: *Builder, path: []const u8) ?Entry {
        for (self.list.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    fn finish(self: *Builder) Allocator.Error!Package {
        std.mem.sort(Entry, self.list.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.lessThan);
        return .{ .entries = try self.list.toOwnedSlice(self.allocator) };
    }
};

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

const fake_binary = "\x7fELF fake executable payload";

test "every layout is sorted, executable where it matters and carries the payload" {
    const alloc = testing.allocator;
    const app = sampleApp();
    const png = "\x89PNG fake";

    const layouts = .{
        .{ .plan = try appDir(alloc, app, .{ .binary = fake_binary, .icon_png = png }), .bin = "usr/bin/demo_app", .apprun = true, .desktop = true },
        .{ .plan = try macApp(alloc, app, .{ .binary = fake_binary, .icon_png = png }), .bin = "Contents/MacOS/demo_app", .apprun = false, .desktop = false },
        .{ .plan = try debPayload(alloc, app, .{ .binary = fake_binary, .icon_png = png }), .bin = "usr/bin/demo_app", .apprun = false, .desktop = true },
        .{ .plan = try portable(alloc, app, .{ .binary = fake_binary, .icon_png = png }), .bin = "demo_app-1.2.3/demo_app", .apprun = false, .desktop = true },
    };

    inline for (layouts) |layout| {
        var package = layout.plan;
        defer package.deinit(alloc);

        try testing.expect(package.entries.len >= 3);
        // Sorted by path.
        var index: usize = 1;
        while (index < package.entries.len) : (index += 1) {
            try testing.expect(std.mem.order(u8, package.entries[index - 1].path, package.entries[index].path) == .lt);
        }
        // The binary is executable and byte-identical.
        const bin = package.find(layout.bin) orelse return error.TestUnexpectedResult;
        try testing.expect(bin.isExecutable());
        try testing.expectEqualStrings(fake_binary, bin.bytes);
        // The icon travelled along.
        try testing.expect(package.findIcon() != null);

        // A `.desktop` entry is a Linux concept: the macOS bundle must not have one.
        if (layout.desktop) {
            const desktop = package.findDesktop() orelse return error.TestUnexpectedResult;
            try testing.expect(std.mem.find(u8, desktop.bytes, "Exec=demo_app %U\n") != null);
        } else {
            try testing.expect(package.findDesktop() == null);
            try testing.expect(package.find("Contents/Info.plist") != null);
            try testing.expect(package.find("Contents/PkgInfo") != null);
        }

        if (layout.apprun) {
            const app_run = package.find("AppRun") orelse return error.TestUnexpectedResult;
            try testing.expect(app_run.isExecutable());
        }
    }
}

test "debPayload ships the Debian copyright file under the package name" {
    const alloc = testing.allocator;
    var package = try debPayload(alloc, sampleApp(), .{ .binary = fake_binary });
    defer package.deinit(alloc);

    try testing.expect(package.find("usr/share/doc/demo-app/copyright") != null);
    try testing.expect(package.findDesktop() != null);
    try testing.expect(package.findIcon() == null);
}

test "installedSizeKib rounds up per file" {
    const alloc = testing.allocator;
    var package = try appDir(alloc, sampleApp(), .{ .binary = fake_binary });
    defer package.deinit(alloc);
    // Every entry is smaller than one 4 KiB block, so the estimate is 4 KiB per file.
    try testing.expectEqual(@as(u64, 4 * package.entries.len * 2), package.installedSizeKib());
}

test "extra entries are carried verbatim and never duplicated" {
    const alloc = testing.allocator;
    const extra = [_]Entry{.{ .path = "usr/share/demo/data.json", .bytes = "{}", .mode = 0o600 }};
    var package = try debPayload(alloc, sampleApp(), .{ .binary = fake_binary, .extra = &extra });
    defer package.deinit(alloc);
    const data = package.find("usr/share/demo/data.json") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0o600), data.mode);
}
