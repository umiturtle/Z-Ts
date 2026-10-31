//! `M5-02` `zts` CLI — argument parsing.
//!
//! Pure functions only: `parse` never touches the filesystem or the process table, so the whole
//! command surface is unit-tested without spawning anything. The caller passes `argv[1..]` (the
//! program name is already stripped) and gets a tagged `Command` back.

const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub const Command = union(enum) {
    /// `zts init` — scaffold a project.
    init: Init,
    /// `zts dev` — static server + rebuild-on-change.
    dev: Dev,
    /// `zts build` — front end bundle + single executable.
    build: Build,
    /// `zts doctor` — check the toolchain and the project layout.
    doctor: Doctor,
    /// `zts package` — turn the built executable into an installable artifact.
    package: Package,
    /// `zts help` / `--help` / no arguments.
    help,
    /// `zts version` / `--version`.
    version,
};

pub const Init = struct {
    /// Directory to scaffold into. `.` means "right here".
    dir: []const u8 = ".",
    /// Package name; `null` means "derive from the directory base name".
    name: ?[]const u8 = null,
    /// Path to the Z-Ts checkout the generated `build.zig.zon` depends on. `null` means "the
    /// checkout that built this `zts` binary" — correct no matter where the project is created.
    zts_path: ?[]const u8 = null,
    /// Write even when the target directory already has files.
    force: bool = false,
};

pub const Dev = struct {
    dir: []const u8 = ".",
    host: []const u8 = "127.0.0.1",
    port: u16 = 5173,
    /// Open the system browser once the server is listening (`--browser`).
    browser: bool = false,
};

pub const Build = struct {
    dir: []const u8 = ".",
    target: ?[]const u8 = null,
    /// `ReleaseSmall` by default: these are desktop apps, size matters more than peak FLOPS.
    optimize: Optimize = .release_small,
    /// Skip `zig build` and only bundle the front end.
    frontend_only: bool = false,
};

pub const Doctor = struct {
    dir: []const u8 = ".",
};

/// `zts package` options. Formats stay a raw string here; `main.zig` resolves them through
/// `bundler.Format.parse`, which keeps this file free of any library import.
pub const Package = struct {
    dir: []const u8 = ".",
    /// Comma-separated list (`deb,appdir`). `null` = the host's default format.
    format: ?[]const u8 = null,
    /// Executable to package. `null` = `zig-out/bin/<name>` (plus `.exe` on Windows).
    binary: ?[]const u8 = null,
    /// Output directory. `null` = `<dir>/zig-out/package`.
    out: ?[]const u8 = null,
    version: ?[]const u8 = null,
    identifier: ?[]const u8 = null,
    maintainer: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// 256×256 PNG for the `.deb` / AppDir / `.app`.
    icon: ?[]const u8 = null,
    /// Multi-size `.ico` for the Windows executable.
    icon_ico: ?[]const u8 = null,
    /// Application manifest XML for the Windows executable.
    manifest: ?[]const u8 = null,
};

pub const Optimize = enum {
    debug,
    release_small,

    pub fn zigName(self: Optimize) []const u8 {
        return switch (self) {
            .debug => "Debug",
            .release_small => "ReleaseSmall",
        };
    }
};

pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    InvalidPort,
    UnexpectedArgument,
};

/// Parses `argv[1..]`.
///
/// `zts` with no arguments prints the help (exit code 0) instead of guessing at a default action,
/// because every sub-command writes to the filesystem or binds a socket.
pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .help;

    const head = args[0];
    if (isHelp(head)) return .help;
    if (isVersion(head)) return .version;

    if (std.mem.eql(u8, head, "init")) return .{ .init = try parseInit(args[1..]) };
    if (std.mem.eql(u8, head, "dev")) return .{ .dev = try parseDev(args[1..]) };
    if (std.mem.eql(u8, head, "build")) return .{ .build = try parseBuild(args[1..]) };
    if (std.mem.eql(u8, head, "doctor")) return .{ .doctor = try parseDoctor(args[1..]) };
    if (std.mem.eql(u8, head, "package")) return .{ .package = try parsePackage(args[1..]) };

    return error.UnknownCommand;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isVersion(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
}

fn parseInit(rest: []const []const u8) ParseError!Init {
    var out: Init = .{};
    var positional: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--force")) {
            out.force = true;
        } else if (try flagValue(rest, &i, arg, "--dir")) |value| {
            out.dir = value;
        } else if (try flagValue(rest, &i, arg, "--name")) |value| {
            out.name = value;
        } else if (try flagValue(rest, &i, arg, "--zts-path")) |value| {
            out.zts_path = value;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        } else {
            if (positional != null) return error.UnexpectedArgument;
            positional = arg;
        }
    }

    if (positional) |dir| out.dir = dir;
    return out;
}

fn parseDev(rest: []const []const u8) ParseError!Dev {
    var out: Dev = .{};

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--browser") or std.mem.eql(u8, arg, "--open")) {
            out.browser = true;
        } else if (try flagValue(rest, &i, arg, "--dir")) |value| {
            out.dir = value;
        } else if (try flagValue(rest, &i, arg, "--host")) |value| {
            out.host = value;
        } else if (try flagValue(rest, &i, arg, "--port")) |value| {
            out.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else {
            return error.UnknownFlag;
        }
    }
    return out;
}

fn parseBuild(rest: []const []const u8) ParseError!Build {
    var out: Build = .{};

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--debug")) {
            out.optimize = .debug;
        } else if (std.mem.eql(u8, arg, "--release")) {
            out.optimize = .release_small;
        } else if (std.mem.eql(u8, arg, "--frontend-only")) {
            out.frontend_only = true;
        } else if (try flagValue(rest, &i, arg, "--dir")) |value| {
            out.dir = value;
        } else if (try flagValue(rest, &i, arg, "--target")) |value| {
            out.target = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return out;
}

fn parseDoctor(rest: []const []const u8) ParseError!Doctor {
    var out: Doctor = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (try flagValue(rest, &i, arg, "--dir")) |value| {
            out.dir = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return out;
}

fn parsePackage(rest: []const []const u8) ParseError!Package {
    var out: Package = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (try flagValue(rest, &i, arg, "--dir")) |value| {
            out.dir = value;
        } else if (try flagValue(rest, &i, arg, "--format")) |value| {
            out.format = value;
        } else if (try flagValue(rest, &i, arg, "--binary")) |value| {
            out.binary = value;
        } else if (try flagValue(rest, &i, arg, "--out")) |value| {
            out.out = value;
        } else if (try flagValue(rest, &i, arg, "--version")) |value| {
            out.version = value;
        } else if (try flagValue(rest, &i, arg, "--identifier")) |value| {
            out.identifier = value;
        } else if (try flagValue(rest, &i, arg, "--maintainer")) |value| {
            out.maintainer = value;
        } else if (try flagValue(rest, &i, arg, "--description")) |value| {
            out.description = value;
        } else if (try flagValue(rest, &i, arg, "--icon")) |value| {
            out.icon = value;
        } else if (try flagValue(rest, &i, arg, "--icon-ico")) |value| {
            out.icon_ico = value;
        } else if (try flagValue(rest, &i, arg, "--manifest")) |value| {
            out.manifest = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return out;
}

/// Matches `--flag value` **only** when the flag name is exactly `name`; returns `null` otherwise so
/// the caller can fall through to the next flag (or to the unknown-flag error). A flag at the very
/// end of the command line is `error.MissingValue` — never an empty string that silently becomes a
/// directory or a bind address.
fn flagValue(rest: []const []const u8, i: *usize, arg: []const u8, name: []const u8) ParseError!?[]const u8 {
    if (!std.mem.eql(u8, arg, name)) return null;
    if (i.* + 1 >= rest.len) return error.MissingValue;
    i.* += 1;
    return rest[i.*];
}

pub const usage_text =
    \\Usage: zts <command> [options]
    \\
    \\Commands:
    \\  init [dir]          Scaffold a new Z-Ts project (default: the current directory)
    \\  dev                 Serve `web/` with rebuild-on-change (`--browser` for Live Preview)
    \\  build               Bundle the front end and produce a single executable
    \\  package             Wrap the executable into .deb / AppDir / .app / .exe / .tar.gz
    \\  doctor              Check the toolchain, the project layout and the z_ts dependency
    \\  help                Show this help
    \\  version             Print the CLI version
    \\
    \\init options:
    \\  --dir <path>        Target directory                  (default ".")
    \\  --name <name>       Package name                      (default: directory base name)
    \\  --zts-path <path>   Path to the Z-Ts checkout         (default: the one that built `zts`)
    \\  --force             Allow scaffolding into a non-empty directory
    \\
    \\dev options:
    \\  --dir <path>        Project directory                 (default ".")
    \\  --host <addr>       Bind address                      (default "127.0.0.1")
    \\  --port <n>          HTTP port                         (default 5173)
    \\  --browser           Open the system browser once the server is up
    \\
    \\build options:
    \\  --dir <path>        Project directory                 (default ".")
    \\  --target <triple>   Cross-compile target (e.g. aarch64-macos)
    \\  --debug             Build with Debug instead of ReleaseSmall
    \\  --frontend-only     Only rebuild `web/` into the embedded asset module
    \\
    \\package options:
    \\  --dir <path>        Project directory                 (default ".")
    \\  --format <list>     deb,appdir,app,dmg,exe,tar.gz      (default: host default)
    \\  --binary <path>     Executable to package             (default zig-out/bin/<name>)
    \\  --out <path>        Output directory                  (default zig-out/package)
    \\  --version <semver>  Package version                   (default: build.zig.zon)
    \\  --identifier <id>   Reverse-DNS id                    (default com.example.<name>)
    \\  --maintainer <who>  "Name <email>"                    (default: from the environment)
    \\  --description <s>   One-line description
    \\  --icon <png>        Icon for .deb / AppDir / .app
    \\  --icon-ico <ico>    Icon for the Windows .exe
    \\  --manifest <xml>    Application manifest for the Windows .exe
    \\
    \\doctor options:
    \\  --dir <path>        Project directory                 (default ".")
    \\
;

pub fn usage() []const u8 {
    return usage_text;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "no arguments, --help and `help` all return the help command" {
    try testing.expectEqual(Command.help, try parse(&.{}));
    try testing.expectEqual(Command.help, try parse(&.{"--help"}));
    try testing.expectEqual(Command.help, try parse(&.{"-h"}));
    try testing.expectEqual(Command.help, try parse(&.{"help"}));
}

test "`--version` and friends are distinct from help" {
    try testing.expectEqual(Command.version, try parse(&.{"--version"}));
    try testing.expectEqual(Command.version, try parse(&.{"-V"}));
    try testing.expectEqual(Command.version, try parse(&.{"version"}));
}

test "`init` defaults are the current directory with no forced overwrite" {
    const cmd = try parse(&.{"init"});
    try testing.expectEqualStrings(".", cmd.init.dir);
    try testing.expect(cmd.init.name == null);
    try testing.expect(cmd.init.zts_path == null); // the checkout that built this binary
    try testing.expect(!cmd.init.force);
}

test "`init <dir>` takes the directory positionally and `--name` overrides the package name" {
    const cmd = try parse(&.{ "init", "apps/demo", "--name", "demo_app", "--force" });
    try testing.expectEqualStrings("apps/demo", cmd.init.dir);
    try testing.expectEqualStrings("demo_app", cmd.init.name.?);
    try testing.expect(cmd.init.force);
}

test "`init --dir` and `--zts-path` are independent of the positional form" {
    const cmd = try parse(&.{ "init", "--dir", "/tmp/x", "--zts-path", "/src/Z-Ts" });
    try testing.expectEqualStrings("/tmp/x", cmd.init.dir);
    try testing.expectEqualStrings("/src/Z-Ts", cmd.init.zts_path.?);
}

test "`init` rejects two positional directories" {
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "init", "a", "b" }));
}

test "`dev` parses the port, the bind address and the browser flag" {
    const cmd = try parse(&.{ "dev", "--port", "8080", "--host", "0.0.0.0", "--browser" });
    try testing.expectEqual(@as(u16, 8080), cmd.dev.port);
    try testing.expectEqualStrings("0.0.0.0", cmd.dev.host);
    try testing.expect(cmd.dev.browser);
    // The default must stay loopback-only: the preview proxy forwards `Host`, it does not need a
    // world-reachable dev server.
    try testing.expectEqual(@as(u16, 5173), (try parse(&.{"dev"})).dev.port);
    try testing.expectEqualStrings("127.0.0.1", (try parse(&.{"dev"})).dev.host);
}

test "`dev --port` rejects non-numbers, out-of-range values and a missing value" {
    try testing.expectError(error.InvalidPort, parse(&.{ "dev", "--port", "abc" }));
    try testing.expectError(error.InvalidPort, parse(&.{ "dev", "--port", "70000" }));
    try testing.expectError(error.InvalidPort, parse(&.{ "dev", "--port", "-1" }));
}

test "a flag at the end of the command line is a missing value, not an empty string" {
    try testing.expectError(error.MissingValue, parse(&.{ "dev", "--port" }));
    try testing.expectError(error.MissingValue, parse(&.{ "dev", "--dir" }));
    try testing.expectError(error.MissingValue, parse(&.{ "init", "--name" }));
    try testing.expectError(error.MissingValue, parse(&.{ "build", "--target" }));
}

test "`build` defaults to ReleaseSmall and accepts a cross-compile target" {
    const cmd = try parse(&.{ "build", "--target", "aarch64-macos" });
    try testing.expectEqual(Optimize.release_small, cmd.build.optimize);
    try testing.expectEqualStrings("aarch64-macos", cmd.build.target.?);
    try testing.expect(!cmd.build.frontend_only);

    const debug = try parse(&.{ "build", "--debug", "--frontend-only" });
    try testing.expectEqual(Optimize.debug, debug.build.optimize);
    try testing.expect(debug.build.frontend_only);
}

test "`optimize.zigName` matches the `-Doptimize=` spelling the build accepts" {
    try testing.expectEqualStrings("Debug", Optimize.debug.zigName());
    try testing.expectEqualStrings("ReleaseSmall", Optimize.release_small.zigName());
}

test "unknown commands and unknown flags are reported, never silently ignored" {
    try testing.expectError(error.UnknownCommand, parse(&.{"frobnicate"}));
    try testing.expectError(error.UnknownCommand, parse(&.{"--nope"}));
    try testing.expectError(error.UnknownFlag, parse(&.{ "dev", "--nope" }));
    try testing.expectError(error.UnknownFlag, parse(&.{ "build", "--nope" }));
    try testing.expectError(error.UnknownFlag, parse(&.{ "init", "--nope" }));
}

test "the usage text documents every command and every documented flag is accepted" {
    const text = usage();
    for ([_][]const u8{ "init", "dev", "build", "package", "doctor", "help", "version" }) |word| {
        try testing.expect(std.mem.indexOf(u8, text, word) != null);
    }
    for ([_][]const u8{
        "--dir",     "--name",       "--zts-path", "--force",    "--host",     "--port",
        "--browser", "--target",     "--debug",    "--format",   "--binary",   "--out",
        "--version", "--identifier", "--icon",     "--icon-ico", "--manifest", "--frontend-only",
    }) |flag| {
        try testing.expect(std.mem.indexOf(u8, text, flag) != null);
    }
    // Every flag in the help must round-trip through the parser.
    _ = try parse(&.{ "init", "--dir", "d", "--name", "n", "--zts-path", "z", "--force" });
    _ = try parse(&.{ "dev", "--dir", "d", "--host", "h", "--port", "1", "--browser" });
    _ = try parse(&.{ "build", "--dir", "d", "--target", "t", "--debug", "--frontend-only" });
    _ = try parse(&.{ "doctor", "--dir", "d" });
    _ = try parse(&.{
        "package",       "--dir",        "d",       "--format",     "deb,appdir",
        "--binary",      "b",            "--out",   "o",            "--version",
        "1.0.0",         "--identifier", "com.a.b", "--maintainer", "M <m@e>",
        "--description", "x",            "--icon",  "i.png",        "--icon-ico",
        "i.ico",         "--manifest",   "m.xml",
    });
}

test "`package` parses its own flag set and rejects the rest" {
    const cmd = try parse(&.{ "package", "--format", "deb", "--out", "dist", "--version", "2.0.0" });
    const options = cmd.package;
    try testing.expectEqualStrings(".", options.dir);
    try testing.expectEqualStrings("deb", options.format.?);
    try testing.expectEqualStrings("dist", options.out.?);
    try testing.expectEqualStrings("2.0.0", options.version.?);
    try testing.expect(options.icon == null);

    try testing.expectError(error.UnknownFlag, parse(&.{ "package", "--nope" }));
    try testing.expectError(error.UnknownFlag, parse(&.{ "package", "--force" }));
    try testing.expectError(error.MissingValue, parse(&.{ "package", "--format" }));
}

test "`doctor` only accepts `--dir`" {
    const cmd = try parse(&.{ "doctor", "--dir", "apps/demo" });
    try testing.expectEqualStrings("apps/demo", cmd.doctor.dir);
    try testing.expectEqualStrings(".", (try parse(&.{"doctor"})).doctor.dir);
    try testing.expectError(error.UnknownFlag, parse(&.{ "doctor", "--fix" }));
}
