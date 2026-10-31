//! Application metadata for the distributable artifacts (`M5-03`).
//!
//! Every platform wants the same six facts — a machine name, a human name, a version, a
//! reverse-DNS identifier, a one-line description and a maintainer — spelled differently:
//!
//! | Platform | File it lands in | Where |
//! |---|---|---|
//! | Debian / AppDir | `control`, `<name>.desktop`, `AppRun` | `deb.zig`, `plan.zig` |
//! | macOS | `Contents/Info.plist` | `plan.zig` |
//! | Windows | `<name>.exe` resources | `pe.zig` |
//!
//! This module owns the facts *and* the validation, plus the pure string rendering of those four
//! files, so a packaging bug is a unit test rather than a `dpkg-deb` error twenty minutes later.
//! Nothing here touches the filesystem.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Longest name the templates accept. Debian allows 32 for the *package* field and macOS is
/// happiest under 16 for the bundle executable; the tighter bound keeps all platforms aligned.
pub const max_name_len = 32;

/// Longest identifier component (Apple's limit for `CFBundleIdentifier`).
const max_identifier_component_len = 63;

pub const InitError = error{
    EmptyName,
    InvalidName,
    NameTooLong,
    InvalidVersion,
    InvalidIdentifier,
    EmptyMaintainer,
    EmptyDescription,
    OutOfMemory,
};

/// Everything a bundle needs to know about the app.
///
/// `name` is the machine name: it is the executable file name, the Debian package name (with `_`
/// rewritten to `-`) and the `StartupWMClass`. `display_name` is what a human sees in the dock,
/// the application menu and `/usr/share/applications`.
pub const App = struct {
    /// `[a-z][a-z0-9_-]*`, at most [`max_name_len`] characters.
    name: []const u8,
    /// Human name shown by the launcher (`Demo App`). Defaults to `name`.
    display_name: []const u8,
    /// Semantic version (`1.2.3`, `0.1.0-beta.1`). Debian additionally wants a leading digit.
    version: []const u8,
    /// Reverse-DNS identifier (`com.example.demo`). macOS uses it as `CFBundleIdentifier`.
    identifier: []const u8,
    /// One line. Becomes the desktop `Comment` and the first line of the Debian description.
    description: []const u8,
    /// `Name <email>`; dpkg and the `.desktop` spec both want the email.
    maintainer: []const u8,
    /// `MIT`, `Apache-2.0`, … Written to `copyright` and `Info.plist`.
    license: []const u8 = "MIT",
    /// Optional project URL.
    homepage: ?[]const u8 = null,
    /// Desktop-category keyword list item used for `Categories=` (`Utility`, `Development`, …).
    category: []const u8 = "Utility",
    /// Debian `Depends:` line. Derived from the executable's own `DT_NEEDED` entries by
    /// [`runtimeDependencies`], because a headless build must not pull GTK onto the user's machine.
    depends: ?[]const u8 = null,

    /// Validates every field and returns the metadata. `display_name` empty means "same as name".
    pub fn init(
        name: []const u8,
        display_name: []const u8,
        version: []const u8,
        identifier: []const u8,
        description: []const u8,
        maintainer: []const u8,
    ) InitError!App {
        try validateName(name);
        const shown = if (display_name.len == 0) name else display_name;
        if (shown.len == 0) return error.EmptyName;
        if (maintainer.len == 0) return error.EmptyMaintainer;
        if (description.len == 0) return error.EmptyDescription;
        if (std.SemanticVersion.parse(version)) |_| {} else |_| return error.InvalidVersion;
        try validateIdentifier(identifier);
        return .{
            .name = name,
            .display_name = shown,
            .version = version,
            .identifier = identifier,
            .description = description,
            .maintainer = maintainer,
        };
    }

    /// The same metadata with a different category (builder-style).
    pub fn withCategory(self: App, category: []const u8) App {
        var copy = self;
        copy.category = category;
        return copy;
    }

    /// The same metadata with a licence string (builder-style).
    pub fn withLicense(self: App, license: []const u8) App {
        var copy = self;
        copy.license = license;
        return copy;
    }

    /// The same metadata with a homepage (builder-style).
    pub fn withHomepage(self: App, homepage: ?[]const u8) App {
        var copy = self;
        copy.homepage = homepage;
        return copy;
    }

    /// The same metadata with a Debian `Depends:` line (builder-style).
    pub fn withDepends(self: App, depends: ?[]const u8) App {
        var copy = self;
        copy.depends = depends;
        return copy;
    }

    /// Debian package names allow `[a-z0-9+.-]` only, so `demo_app` becomes `demo-app`.
    /// The rest of the platforms keep the executable spelling.
    pub fn debName(self: App, allocator: Allocator) Allocator.Error![]u8 {
        const out = try allocator.dupe(u8, self.name);
        for (out) |*ch| {
            if (ch.* == '_') ch.* = '-';
        }
        return out;
    }

    /// `/usr/share/applications/<name>.desktop`. The `Exec` line is the bare binary name because the
    /// launcher resolves it through `PATH`, and our `.deb` installs to `/usr/bin`.
    pub fn desktopEntry(self: App, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "[Desktop Entry]\n" ++
                "Type=Application\n" ++
                "Name={s}\n" ++
                "Comment={s}\n" ++
                "Exec={s} %U\n" ++
                "Icon={s}\n" ++
                "Terminal=false\n" ++
                "Categories={s};\n" ++
                "StartupWMClass={s}\n",
            .{ self.display_name, self.description, self.name, self.name, self.category, self.display_name },
        );
    }

    /// `DEBIAN/control`. `installed_size_kib` is what `du -sk` would report; dpkg only uses it for
    /// its progress estimate, but an absent field makes `dpkg-deb --info` look broken.
    pub fn controlFile(self: App, allocator: Allocator, installed_size_kib: u64, architecture: []const u8) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;

        const deb_name = try self.debName(allocator);
        defer allocator.free(deb_name);

        w.print(
            "Package: {s}\n" ++
                "Version: {s}\n" ++
                "Section: utils\n" ++
                "Priority: optional\n" ++
                "Architecture: {s}\n" ++
                "Maintainer: {s}\n" ++
                "Installed-Size: {d}\n",
            .{ deb_name, self.version, architecture, self.maintainer, installed_size_kib },
        ) catch return error.OutOfMemory;
        if (self.homepage) |homepage| {
            w.print("Homepage: {s}\n", .{homepage}) catch return error.OutOfMemory;
        }
        // `License` is deliberately absent: Debian policy has no such binary field (the licence
        // lives in `usr/share/doc/<pkg>/copyright`), and `lintian` warns about unknown fields.
        if (self.depends) |deps| {
            if (deps.len > 0) w.print("Depends: {s}\n", .{deps}) catch return error.OutOfMemory;
        }
        w.print("Description: {s}\n", .{firstLine(self.description)}) catch return error.OutOfMemory;
        // Debian continuation lines each start with a space; a blank line is a lone " .".
        var it = std.mem.splitScalar(u8, self.description, '\n');
        _ = it.next();
        while (it.next()) |line| {
            if (line.len == 0) {
                w.writeAll(" .\n") catch return error.OutOfMemory;
            } else {
                w.print(" {s}\n", .{line}) catch return error.OutOfMemory;
            }
        }
        return out.toOwnedSlice() catch error.OutOfMemory;
    }

    /// `Contents/Info.plist`. `CFBundleExecutable` must match the file name under `Contents/MacOS`.
    pub fn infoPlist(self: App, allocator: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;

        w.writeAll(plist_header()) catch return error.OutOfMemory;
        w.print(
            "{s}" ++
                "  <key>CFBundleExecutable</key><string>{s}</string>\n" ++
                "  <key>CFBundleIdentifier</key><string>{s}</string>\n" ++
                "  <key>CFBundleName</key><string>{s}</string>\n" ++
                "  <key>CFBundleDisplayName</key><string>{s}</string>\n" ++
                "  <key>CFBundlePackageType</key><string>APPL</string>\n" ++
                "  <key>CFBundleSignature</key><string>????</string>\n" ++
                "  <key>CFBundleShortVersionString</key><string>{s}</string>\n" ++
                "  <key>CFBundleVersion</key><string>{s}</string>\n" ++
                "  <key>LSMinimumSystemVersion</key><string>11.0</string>\n" ++
                "  <key>NSHighResolutionCapable</key><true/>\n" ++
                "  <key>NSHumanReadableCopyright</key><string>{s}</string>\n",
            .{
                plist_info(),
                self.name,
                self.identifier,
                self.display_name,
                self.display_name,
                self.version,
                self.version,
                self.maintainer,
            },
        ) catch return error.OutOfMemory;
        w.writeAll(plist_footer()) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }

    /// `AppRun` for the Linux AppDir. `readlink -f` is GNU/busybox but not POSIX, so the script
    /// falls back to `$0` when the tool is missing (AppDirs are Linux-only).
    pub fn appRunScript(self: App, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\n" ++
                "# Generated by `zts package` (M5-03).\n" ++
                "here=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n" ++
                "exec \"$here/usr/bin/{s}\" \"$@\"\n",
            .{self.name},
        );
    }

    /// `usr/share/doc/<deb>/copyright` — the only file Debian requires beyond the payload.
    pub fn copyrightFile(self: App, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n" ++
                "Upstream-Name: {s}\n" ++
                "Source: {s}\n" ++
                "\n" ++
                "Files: *\n" ++
                "Copyright: {s}\n" ++
                "License: {s}\n",
            .{ self.display_name, self.homepage orelse "local", self.maintainer, self.license },
        );
    }

    /// `demo_0.1.0_amd64.deb`, `Demo-0.1.0.AppDir`, `Demo.app`, `Demo-0.1.0.dmg`, `demo.exe`.
    pub fn artifactName(self: App, allocator: Allocator, format: Format, architecture: []const u8) Allocator.Error![]u8 {
        const deb_name = try self.debName(allocator);
        defer allocator.free(deb_name);
        return switch (format) {
            .deb => std.fmt.allocPrint(allocator, "{s}_{s}_{s}.deb", .{ deb_name, self.version, architecture }),
            .appdir => std.fmt.allocPrint(allocator, "{s}-{s}-{s}.AppDir", .{ deb_name, self.version, architecture }),
            .app => std.fmt.allocPrint(allocator, "{s}.app", .{self.display_name}),
            .dmg => std.fmt.allocPrint(allocator, "{s}-{s}.dmg", .{ self.display_name, self.version }),
            .exe => std.fmt.allocPrint(allocator, "{s}.exe", .{self.name}),
            .tar_gz => std.fmt.allocPrint(allocator, "{s}-{s}-{s}.tar.gz", .{ deb_name, self.version, architecture }),
        };
    }
};

/// Output format of `zts package`. `auto` is resolved by the CLI from the host OS.
pub const Format = enum {
    deb,
    appdir,
    app,
    dmg,
    exe,
    /// Portable tarball — the only format that works for every target from every host.
    tar_gz,

    /// Parses the `--format` spelling. Accepts `tar.gz` as an alias of `tar_gz`.
    pub fn parse(text: []const u8) ?Format {
        const table = .{
            .{ "deb", Format.deb },
            .{ "appdir", Format.appdir },
            .{ "app", Format.app },
            .{ "dmg", Format.dmg },
            .{ "exe", Format.exe },
            .{ "tar.gz", Format.tar_gz },
            .{ "tar_gz", Format.tar_gz },
        };
        inline for (table) |row| {
            if (std.mem.eql(u8, text, row[0])) return row[1];
        }
        return null;
    }

    /// The format a host can produce without extra tooling.
    pub fn hostDefault(os: std.Target.Os.Tag) Format {
        return switch (os) {
            .macos => .app,
            .windows => .exe,
            else => .deb,
        };
    }

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .deb => ".deb",
            .appdir => ".AppDir",
            .app => ".app",
            .dmg => ".dmg",
            .exe => ".exe",
            .tar_gz => ".tar.gz",
        };
    }
};

/// Debian's `Architecture:` value for a Zig target. Unrecognised architectures fall back to the
/// Debian name for the CPU, which keeps a cross-build honest instead of silently saying `amd64`.
pub fn debArchitecture(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .x86 => "i386",
        .arm, .armeb, .thumb, .thumbeb => "armhf",
        .riscv64 => "riscv64",
        .powerpc64le => "ppc64el",
        .s390x => "s390x",
        else => "all",
    };
}

/// The arch token used in AppDir / tarball names (`x86_64`, `aarch64`, …).
pub fn machineName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .arm, .armeb, .thumb, .thumbeb => "armv7",
        .riscv64 => "riscv64",
        else => @tagName(arch),
    };
}

/// Maps the shared objects an ELF binary actually links against onto Debian package names.
///
/// A Z-Ts app that never opens a window does not link GTK, so hard-coding `Depends: libgtk-3-0`
/// would install 100 MB of toolkit for a headless program. Searching the binary's string table for
/// the sonames is enough: `DT_NEEDED` entries are plain NUL-terminated strings inside the file.
///
/// Returns `null` when nothing matches, so `controlFile` omits the field instead of writing
/// `Depends: ` with an empty value.
pub fn runtimeDependencies(allocator: Allocator, binary: []const u8) Allocator.Error!?[]const u8 {
    const table = .{
        .{ .soname = "libgtk-3.so", .package = "libgtk-3-0" },
        .{ .soname = "libwebkit2gtk-4.1.so", .package = "libwebkit2gtk-4.1-0" },
        .{ .soname = "libwebkit2gtk-4.0.so", .package = "libwebkit2gtk-4.0-37" },
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    var found = false;
    inline for (table) |row| {
        if (std.mem.indexOf(u8, binary, row.soname) != null) {
            if (found) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(row.package) catch return error.OutOfMemory;
            found = true;
        }
    }
    if (!found) {
        out.deinit();
        return null;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

fn plist_header() []const u8 {
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
        "<plist version=\"1.0\">\n" ++
        "<dict>\n";
}

fn plist_info() []const u8 {
    return "  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n";
}

fn plist_footer() []const u8 {
    return "</dict>\n</plist>\n";
}

/// `[a-z][a-z0-9_-]*` — the same alphabet `zts init` accepts, so a generated project never needs
/// renaming before it can be packaged. Debian is looser (a leading digit is legal there), but a
/// name that starts with a letter is legal everywhere, including as a C identifier and a file name.
pub fn validateName(name: []const u8) InitError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > max_name_len) return error.NameTooLong;
    const first = name[0];
    if (!std.ascii.isLower(first)) return error.InvalidName;
    for (name[1..]) |ch| {
        if (std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-') continue;
        return error.InvalidName;
    }
}

/// Reverse DNS: at least two dot-separated components of `[A-Za-z0-9-]`, each starting with a
/// letter or digit. This is what `CFBundleIdentifier` and AppImage tooling both expect.
pub fn validateIdentifier(identifier: []const u8) InitError!void {
    if (identifier.len == 0) return error.InvalidIdentifier;
    var components: usize = 0;
    var it = std.mem.splitScalar(u8, identifier, '.');
    while (it.next()) |component| {
        components += 1;
        if (component.len == 0 or component.len > max_identifier_component_len) return error.InvalidIdentifier;
        for (component, 0..) |ch, index| {
            const ok = std.ascii.isAlphanumeric(ch) or (ch == '-' and index != 0);
            if (!ok) return error.InvalidIdentifier;
        }
    }
    if (components < 2) return error.InvalidIdentifier;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

fn sample() App {
    return App.init(
        "demo_app",
        "Demo App",
        "1.2.3",
        "com.example.demo",
        "A demo application\nwith a second line.",
        "Dev <dev@example.com>",
    ) catch unreachable;
}

test "init rejects every field a package manager would reject" {
    try testing.expectError(error.EmptyName, App.init("", "", "1.0.0", "com.a.b", "d", "m <m@e>"));
    try testing.expectError(error.InvalidName, App.init("Demo", "", "1.0.0", "com.a.b", "d", "m <m@e>"));
    try testing.expectError(error.InvalidName, App.init("1-demo", "", "1.0.0", "com.a.b", "d", "m <m@e>"));
    try testing.expectError(error.NameTooLong, App.init("abcdefghijklmnopqrstuvwxyz0123456789", "", "1.0.0", "com.a.b", "d", "m <m@e>"));
    try testing.expectError(error.InvalidVersion, App.init("demo", "", "not-a-version", "com.a.b", "d", "m <m@e>"));
    try testing.expectError(error.InvalidIdentifier, App.init("demo", "", "1.0.0", "demo", "d", "m <m@e>"));
    try testing.expectError(error.InvalidIdentifier, App.init("demo", "", "1.0.0", "com..demo", "d", "m <m@e>"));
    try testing.expectError(error.EmptyMaintainer, App.init("demo", "", "1.0.0", "com.a.b", "d", ""));
    try testing.expectError(error.EmptyDescription, App.init("demo", "", "1.0.0", "com.a.b", "", "m <m@e>"));

    // A valid one, and the empty display name default.
    const app = try App.init("demo", "", "0.1.0-beta.2", "com.example.demo", "Demo", "Dev <dev@example.com>");
    try testing.expectEqualStrings("demo", app.display_name);
}

test "identifier validation accepts real reverse-DNS spellings" {
    for ([_][]const u8{ "com.example.demo", "io.github.umiturtle.z-ts", "a.b", "com.example.2demo" }) |id| {
        try validateIdentifier(id);
    }
    for ([_][]const u8{ "", "demo", ".demo", "demo.", "com.-demo", "com.example demo", "com..demo" }) |id| {
        try testing.expectError(error.InvalidIdentifier, validateIdentifier(id));
    }
}

test "debName rewrites underscores, artifactName spells every format" {
    const alloc = testing.allocator;
    const app = sample();

    const deb_name = try app.debName(alloc);
    defer alloc.free(deb_name);
    try testing.expectEqualStrings("demo-app", deb_name);

    const deb = try app.artifactName(alloc, .deb, "amd64");
    defer alloc.free(deb);
    try testing.expectEqualStrings("demo-app_1.2.3_amd64.deb", deb);

    const appdir = try app.artifactName(alloc, .appdir, "x86_64");
    defer alloc.free(appdir);
    try testing.expectEqualStrings("demo-app-1.2.3-x86_64.AppDir", appdir);

    const app_bundle = try app.artifactName(alloc, .app, "");
    defer alloc.free(app_bundle);
    try testing.expectEqualStrings("Demo App.app", app_bundle);

    const dmg = try app.artifactName(alloc, .dmg, "");
    defer alloc.free(dmg);
    try testing.expectEqualStrings("Demo App-1.2.3.dmg", dmg);

    const exe = try app.artifactName(alloc, .exe, "");
    defer alloc.free(exe);
    try testing.expectEqualStrings("demo_app.exe", exe);
}

test "desktopEntry follows the freedesktop spelling" {
    const alloc = testing.allocator;
    const entry = try sample().desktopEntry(alloc);
    defer alloc.free(entry);

    try testing.expect(std.mem.startsWith(u8, entry, "[Desktop Entry]\n"));
    try testing.expect(std.mem.find(u8, entry, "Type=Application\n") != null);
    try testing.expect(std.mem.find(u8, entry, "Name=Demo App\n") != null);
    try testing.expect(std.mem.find(u8, entry, "Exec=demo_app %U\n") != null);
    try testing.expect(std.mem.find(u8, entry, "Icon=demo_app\n") != null);
    try testing.expect(std.mem.find(u8, entry, "Categories=Utility;\n") != null);
    try testing.expect(std.mem.endsWith(u8, entry, "StartupWMClass=Demo App\n"));
}

test "controlFile puts the long description in padded continuation lines" {
    const alloc = testing.allocator;
    const control = try sample().controlFile(alloc, 4096, "amd64");
    defer alloc.free(control);

    try testing.expect(std.mem.find(u8, control, "Package: demo-app\n") != null);
    try testing.expect(std.mem.find(u8, control, "Version: 1.2.3\n") != null);
    try testing.expect(std.mem.find(u8, control, "Architecture: amd64\n") != null);
    try testing.expect(std.mem.find(u8, control, "Maintainer: Dev <dev@example.com>\n") != null);
    try testing.expect(std.mem.find(u8, control, "Installed-Size: 4096\n") != null);
    try testing.expect(std.mem.find(u8, control, "Description: A demo application\n") != null);
    try testing.expect(std.mem.find(u8, control, " with a second line.\n") != null);
    try testing.expect(std.mem.endsWith(u8, control, " with a second line.\n"));
}

test "controlFile writes Depends only when the binary actually links a toolkit" {
    const alloc = testing.allocator;
    const plain = try sample().controlFile(alloc, 1024, "arm64");
    defer alloc.free(plain);
    try testing.expect(std.mem.find(u8, plain, "Depends:") == null);
    try testing.expect(std.mem.find(u8, plain, "License:") == null);

    const linked = try sample().withDepends("libgtk-3-0, libwebkit2gtk-4.1-0").controlFile(alloc, 1024, "amd64");
    defer alloc.free(linked);
    try testing.expect(std.mem.find(u8, linked, "Depends: libgtk-3-0, libwebkit2gtk-4.1-0\n") != null);
}

test "runtimeDependencies reads DT_NEEDED sonames instead of assuming a toolkit" {
    const alloc = testing.allocator;

    const headless = try runtimeDependencies(alloc, "ELF\x00/usr/lib/libc.so.6\x00");
    try testing.expect(headless == null);

    const both = try runtimeDependencies(alloc, "\x00libgtk-3.so.0\x00libwebkit2gtk-4.1.so.0\x00");
    defer if (both) |text| alloc.free(text);
    try testing.expectEqualStrings("libgtk-3-0, libwebkit2gtk-4.1-0", both.?);

    const older = try runtimeDependencies(alloc, "\x00libwebkit2gtk-4.0.so.37\x00");
    defer if (older) |text| alloc.free(text);
    try testing.expectEqualStrings("libwebkit2gtk-4.0-37", older.?);
}

test "controlFile marks blank description lines as a lone dot" {
    const alloc = testing.allocator;
    const app = try App.init("demo", "", "0.1.0", "com.example.demo", "short\n\nlast", "Dev <dev@example.com>");
    const control = try app.controlFile(alloc, 1, "amd64");
    defer alloc.free(control);
    try testing.expect(std.mem.find(u8, control, "Description: short\n .\n last\n") != null);
}

test "infoPlist is a well-formed plist carrying the executable and identifier" {
    const alloc = testing.allocator;
    const plist = try sample().infoPlist(alloc);
    defer alloc.free(plist);

    try testing.expect(std.mem.startsWith(u8, plist, "<?xml version=\"1.0\""));
    try testing.expect(std.mem.find(u8, plist, "<key>CFBundleExecutable</key><string>demo_app</string>") != null);
    try testing.expect(std.mem.find(u8, plist, "<key>CFBundleIdentifier</key><string>com.example.demo</string>") != null);
    try testing.expect(std.mem.find(u8, plist, "<key>CFBundleShortVersionString</key><string>1.2.3</string>") != null);
    try testing.expect(std.mem.find(u8, plist, "<key>CFBundlePackageType</key><string>APPL</string>") != null);
    try testing.expect(std.mem.endsWith(u8, plist, "</dict>\n</plist>\n"));
    // Balanced dict tags: one open, one close.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, plist, "<dict>"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, plist, "</dict>"));
}

test "appRunScript execs the bundled binary relative to itself" {
    const alloc = testing.allocator;
    const script = try sample().appRunScript(alloc);
    defer alloc.free(script);
    try testing.expect(std.mem.startsWith(u8, script, "#!/bin/sh\n"));
    try testing.expect(std.mem.find(u8, script, "exec \"$here/usr/bin/demo_app\" \"$@\"\n") != null);
}

test "debArchitecture and machineName cover the architectures CI builds" {
    const cases = .{
        .{ std.Target.Cpu.Arch.x86_64, "amd64", "x86_64" },
        .{ std.Target.Cpu.Arch.aarch64, "arm64", "aarch64" },
        .{ std.Target.Cpu.Arch.x86, "i386", "i686" },
        .{ std.Target.Cpu.Arch.riscv64, "riscv64", "riscv64" },
    };
    inline for (cases) |case| {
        try testing.expectEqualStrings(case[1], debArchitecture(case[0]));
        try testing.expectEqualStrings(case[2], machineName(case[0]));
    }
}

test "Format.parse and hostDefault agree with the CLI spelling" {
    try testing.expectEqual(Format.deb, Format.parse("deb").?);
    try testing.expectEqual(Format.appdir, Format.parse("appdir").?);
    try testing.expectEqual(Format.tar_gz, Format.parse("tar.gz").?);
    try testing.expectEqual(Format.tar_gz, Format.parse("tar_gz").?);
    try testing.expectEqual(@as(?Format, null), Format.parse("msi"));

    try testing.expectEqual(Format.app, Format.hostDefault(.macos));
    try testing.expectEqual(Format.exe, Format.hostDefault(.windows));
    try testing.expectEqual(Format.deb, Format.hostDefault(.linux));
    try testing.expectEqual(Format.deb, Format.hostDefault(.freebsd));
}
