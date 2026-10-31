//! `zts` — the app-author CLI (`M5-02`).
//!
//! This is the only file in `src/cli/` that touches the filesystem, the network or a child process.
//! Every rule it applies (argument grammar, template bytes, URL → file mapping, reload snippet) has
//! a unit test in a sibling module, because a CLI that is tested only by running it is a CLI that
//! nobody dares change.
//!
//! Commands:
//!
//! * `zts init [dir]` — write the project template and patch the Zig 0.17 `.fingerprint`.
//! * `zts dev` — serve `web/`, rebuild on change, reload the page.
//! * `zts build` — `zig build` with the project's optimisation and target.
//! * `zts doctor` — check that the toolchain and the generated project agree with each other.
//! * `zts package` — wrap the built executable into `.deb` / AppDir / `.app` / `.dmg` / `.exe` /
//!   `.tar.gz` (`M5-03`). The bytes are produced by `src/bundler/`; this file only moves them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const args_mod = @import("args.zig");
const template = @import("template.zig");
const project = @import("project.zig");
const devserver = @import("devserver.zig");
const bundler = @import("zts_bundler");

/// Absolute path of the Z-Ts checkout that built this binary, injected by `build.zig`. `zts init`
/// writes it into the generated `build.zig.zon`, so a project created anywhere keeps working without
/// the author having to work out a relative path.
const build_options = @import("zts_cli_options");

/// Exit codes: 0 success, 1 "the project or toolchain refused", 2 "the command line was wrong".
const exit_failure = 1;
const exit_usage = 2;

/// `ZTS_ZIG`, read once at startup. `null` means "find the toolchain the usual way".
var env_zig: ?[]const u8 = null;

/// `PATH`, read once at startup, used only to prefer a real `zig` over the `zigw` wrapper.
var env_path: ?[]const u8 = null;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    env_zig = init.environ_map.get("ZTS_ZIG");
    env_path = init.environ_map.get("PATH");
    const argv = try init.minimal.args.toSlice(arena);
    const command = args_mod.parse(argv[1..]) catch |err| {
        printErr(io, "zts: {s}\n", .{describeParseError(err)});
        printErr(io, "{s}\n", .{args_mod.usage()});
        return exit_usage;
    };

    return switch (command) {
        .help => blk: {
            printOut(io, "{s}\n", .{args_mod.usage()});
            break :blk 0;
        },
        .version => blk: {
            printOut(io, "zts {f}\n", .{args_mod.version});
            break :blk 0;
        },
        .init => |opts| runInit(io, gpa, arena, init.environ_map, opts),
        .dev => |opts| runDev(io, gpa, arena, opts),
        .build => |opts| runBuild(io, gpa, arena, opts),
        .doctor => |opts| runDoctor(io, arena, opts.dir),
        .package => |opts| runPackage(io, arena, init.environ_map, opts),
    };
}

fn describeParseError(err: args_mod.ParseError) []const u8 {
    return switch (err) {
        error.UnknownCommand => "unknown command (try `zts help`)",
        error.UnknownFlag => "unknown flag for that command (try `zts help`)",
        error.MissingValue => "a flag is missing its value",
        error.InvalidPort => "`--port` must be a number between 0 and 65535",
        error.UnexpectedArgument => "too many arguments",
    };
}

// ---------------------------------------------------------------------------------------------
// zts init
// ---------------------------------------------------------------------------------------------

fn runInit(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    env: *std.process.Environ.Map,
    opts: args_mod.Init,
) !u8 {
    const name = opts.name orelse blk: {
        const derived = template.defaultName(opts.dir) orelse {
            printErr(io, "zts init: cannot derive a package name from '{s}' — pass --name <name>\n", .{opts.dir});
            return exit_usage;
        };
        break :blk try template.normalizeName(arena, derived);
    };
    template.validateName(name) catch |err| {
        printErr(io, "zts init: '{s}' is not a usable package name ({s})\n", .{ name, @errorName(err) });
        printErr(io, "          names are [a-z][a-z0-9_]* and at most {d} characters\n", .{template.max_name_len});
        return exit_usage;
    };

    // `build.zig.zon` refuses absolute local paths (`expected path relative to build root`), so
    // the checkout is written the way a human would: `../Z-Ts`, `../../Z-Ts`, ….
    const zts_path = if (opts.zts_path) |explicit|
        try relativePath(io, arena, env, opts.dir, explicit)
    else
        try relativePath(io, arena, env, opts.dir, build_options.zts_root);

    const cwd = Io.Dir.cwd();
    if (cwd.access(io, opts.dir, .{})) |_| {
        if (!opts.force and !try dirIsScaffoldable(io, cwd, opts.dir)) {
            printErr(io, "zts init: '{s}' already has files — pass --force to write into it anyway\n", .{opts.dir});
            return exit_failure;
        }
    } else |_| {}

    const files = try template.scaffold(arena, .{ .name = name, .zts_path = zts_path });
    for (files) |file| {
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ opts.dir, file.path });
        if (std.fs.path.dirname(full)) |parent| {
            if (parent.len > 0) try cwd.createDirPath(io, parent);
        }
        try cwd.writeFile(io, .{ .sub_path = full, .data = file.contents });
    }

    printOut(io, "zts: created {s} ({d} files)\n", .{ opts.dir, files.len });
    // The `.fingerprint` is the one value the template cannot compute (see template.zig): ask Zig
    // once, on the freshly written project, and write back the value it prints.
    const patched = try patchFingerprintViaBuild(io, gpa, arena, opts.dir);
    if (patched) {
        printOut(io, "zts: patched build.zig.zon with the fingerprint Zig suggested\n", .{});
    } else {
        printErr(io, "zts: warning — could not read the fingerprint Zig suggested; the first\n", .{});
        printErr(io, "     `zig build` will print it and `zts build` will write it back.\n", .{});
    }

    printOut(io, "\nNext:\n  cd {s}\n  zts dev        # preview web/ in a browser\n  zts build      # single executable in zig-out/bin/\n", .{opts.dir});
    return 0;
}

/// A directory is safe to scaffold into when it has no entries at all, or when every entry is one
/// the template would overwrite anyway. `.gitignore` counts as ours: `git init` writes it and the
/// template replaces it.
fn dirIsScaffoldable(io: Io, cwd: Io.Dir, dir_path: []const u8) !bool {
    const dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);

    var walker = dir.walk(std.heap.page_allocator) catch return false;
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, ".gitignore")) continue;
        return false;
    }
    return true;
}

/// Runs `zig build` once and, if Zig complains about the zero fingerprint, writes the suggested
/// value into `build.zig.zon`. Zig validates the high 32 bits against the package name, which is why
/// the template cannot invent the value itself.
fn patchFingerprintViaBuild(io: Io, gpa: Allocator, arena: Allocator, dir: []const u8) !bool {
    const zon_path = try std.fmt.allocPrint(arena, "{s}/build.zig.zon", .{dir});
    const zon = Io.Dir.cwd().readFileAlloc(io, zon_path, arena, .limited(1024 * 1024)) catch return false;

    const result = runZig(io, gpa, arena, dir) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const suggestion = template.fingerprintSuggestion(result.stderr) orelse
        template.fingerprintSuggestion(result.stdout) orelse return false;

    const patched = try template.patchFingerprint(arena, zon, suggestion);
    if (std.mem.eql(u8, patched, zon)) return false;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zon_path, .data = patched });
    return true;
}

// ---------------------------------------------------------------------------------------------
// zts build
// ---------------------------------------------------------------------------------------------

fn runBuild(io: Io, gpa: Allocator, arena: Allocator, opts: args_mod.Build) !u8 {
    const zon = readZon(io, arena, opts.dir) catch |err| {
        printErr(io, "zts build: cannot read {s}/build.zig.zon ({t}) — is this a Z-Ts project?\n", .{ opts.dir, err });
        return exit_failure;
    };
    const name = project.packageName(zon) orelse template.defaultName(opts.dir) orelse "app";

    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv_list.appendSlice(arena, &.{ "build", "--summary", "failures" });
    if (opts.frontend_only) {
        try argv_list.append(arena, "frontend");
    } else {
        try argv_list.append(arena, try std.fmt.allocPrint(arena, "-Doptimize={s}", .{opts.optimize.zigName()}));
        if (opts.target) |target| {
            try argv_list.append(arena, try std.fmt.allocPrint(arena, "-Dtarget={s}", .{target}));
        }
    }

    printOut(io, "zts: building {s} ({s})\n", .{ name, if (opts.frontend_only) "frontend only" else opts.optimize.zigName() });
    const result = runZigArgv(io, gpa, arena, opts.dir, argv_list.items) catch |err| {
        printErr(io, "zts build: could not run zig ({t})\n", .{err});
        printErr(io, "           set ZTS_ZIG to the zig binary if it is not on PATH\n", .{});
        return exit_failure;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.stderr.len > 0) printErr(io, "{s}", .{result.stderr});
    if (result.stdout.len > 0) printOut(io, "{s}", .{result.stdout});

    if (!result.term.success()) {
        printErr(io, "zts build: zig build failed\n", .{});
        return exit_failure;
    }

    if (opts.frontend_only) {
        printOut(io, "zts: front end re-embedded\n", .{});
        return 0;
    }

    const exe = try project.executablePath(arena, name, project.isWindowsTarget(opts.target));
    const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ opts.dir, exe });
    if (Io.Dir.cwd().access(io, full, .{})) |_| {
        printOut(io, "zts: built {s}\n", .{full});
    } else |_| {
        printOut(io, "zts: build succeeded (expected executable at {s} — not found)\n", .{full});
    }
    return 0;
}

// ---------------------------------------------------------------------------------------------
// zts dev
// ---------------------------------------------------------------------------------------------

fn runDev(io: Io, gpa: Allocator, arena: Allocator, opts: args_mod.Dev) !u8 {
    const zon = readZon(io, arena, opts.dir) catch |err| {
        printErr(io, "zts dev: cannot read {s}/build.zig.zon ({t}) — is this a Z-Ts project?\n", .{ opts.dir, err });
        return exit_failure;
    };
    const name = project.packageName(zon) orelse template.defaultName(opts.dir) orelse "app";

    const web_dir = try std.fmt.allocPrint(arena, "{s}/web", .{opts.dir});
    if (Io.Dir.cwd().access(io, web_dir, .{})) |_| {} else |_| {
        printErr(io, "zts dev: {s} does not exist — `zts init` puts the front end there\n", .{web_dir});
        return exit_failure;
    }

    const server = devserver.DevServer.start(gpa, io, web_dir, opts.host, opts.port) catch |err| {
        printErr(io, "zts dev: cannot listen on {s}:{d} ({t})\n", .{ opts.host, opts.port, err });
        return exit_failure;
    };

    const url = try std.fmt.allocPrint(arena, "http://{s}:{d}/", .{ displayHost(opts.host), server.port() });
    printOut(io, "zts: {s} — serving {s} at {s}\n", .{ name, web_dir, url });
    printOut(io, "     watching src/ and web/ — Ctrl+C to stop\n", .{});
    if (opts.browser) try openBrowser(io, arena, url);

    // Build once so the first page load matches what `zts build` would produce.
    server.recordBuild(try rebuild(io, gpa, arena, opts.dir, true));

    var previous = try watchFingerprint(io, gpa, opts.dir);
    while (true) {
        io.sleep(.fromMilliseconds(400), .awake) catch return 0;
        const current = try watchFingerprint(io, gpa, opts.dir);
        if (current == previous) continue;
        previous = current;
        // A save often arrives as several writes (editor temp rename, formatter, fsync); waiting a
        // beat turns three rebuilds into one.
        io.sleep(.fromMilliseconds(200), .awake) catch return 0;
        previous = try watchFingerprint(io, gpa, opts.dir);

        server.recordBuild(try rebuild(io, gpa, arena, opts.dir, false));
    }
}

fn displayHost(host: []const u8) []const u8 {
    // `0.0.0.0` is not an address a browser can open, but it is the right bind address in a
    // container. The URL line is meant to be clicked, so print loopback in that case.
    if (std.mem.eql(u8, host, "0.0.0.0")) return "127.0.0.1";
    return host;
}

fn watchFingerprint(io: Io, gpa: Allocator, dir: []const u8) !u64 {
    const cwd = Io.Dir.cwd();
    var hash: u64 = 0;
    for ([_][]const u8{ "src", "web" }) |sub| {
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, sub });
        defer gpa.free(full);
        const handle = cwd.openDir(io, full, .{ .iterate = true }) catch continue;
        defer handle.close(io);
        hash ^= try devserver.fingerprint(io, gpa, handle);
    }
    return hash;
}

fn rebuild(io: Io, gpa: Allocator, arena: Allocator, dir: []const u8, first: bool) !bool {
    if (!first) printOut(io, "zts: change detected, rebuilding…\n", .{});
    const result = runZig(io, gpa, arena, dir) catch |err| {
        printErr(io, "zts dev: could not run zig ({t})\n", .{err});
        return false;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.stderr.len > 0) printErr(io, "{s}", .{result.stderr});
    if (result.stdout.len > 0) printOut(io, "{s}", .{result.stdout});

    const ok = result.term.success();
    if (ok) {
        printOut(io, "zts: build ok\n", .{});
    } else {
        printErr(io, "zts: build failed — the page keeps the last good build\n", .{});
    }
    return ok;
}

/// Opens the system browser. Best effort: a missing opener is not an error the author can act on.
fn openBrowser(io: Io, arena: Allocator, url: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };
    const result = std.process.run(arena, io, .{ .argv = argv }) catch return;
    _ = result;
}

// ---------------------------------------------------------------------------------------------
// zts package
// ---------------------------------------------------------------------------------------------

/// Upper bound on the executable `zts package` will read. A Z-Ts app is a few megabytes; 1 GiB
/// means a mistyped `--binary` is a clean error instead of an out-of-memory.
const max_binary_bytes = 1024 * 1024 * 1024;

fn runPackage(
    io: Io,
    arena: Allocator,
    env: *std.process.Environ.Map,
    opts: args_mod.Package,
) !u8 {
    packageAll(io, arena, env, opts) catch |err| switch (err) {
        error.Reported => return exit_failure,
        else => {
            printErr(io, "zts package: {s}\n", .{@errorName(err)});
            return exit_failure;
        },
    };
    return 0;
}

/// Everything `zts package` needs, resolved once and shared by every format.
const PackageContext = struct {
    app: bundler.App,
    binary: []const u8,
    icon_png: ?[]const u8,
    icon_ico: ?[]const u8,
    manifest: ?[]const u8,
    arch: std.Target.Cpu.Arch,
    formats: []const bundler.Format,
    out_dir: []const u8,
};

fn packageAll(
    io: Io,
    arena: Allocator,
    env: *std.process.Environ.Map,
    opts: args_mod.Package,
) !void {
    const cwd = Io.Dir.cwd();
    const zon = readZon(io, arena, opts.dir) catch |err| {
        printErr(io, "zts package: cannot read {s}/build.zig.zon ({t}) — is this a Z-Ts project?\n", .{ opts.dir, err });
        return error.Reported;
    };
    const name = project.packageName(zon) orelse {
        printErr(io, "zts package: {s}/build.zig.zon has no `.name` — run `zts init` or add one\n", .{opts.dir});
        return error.Reported;
    };

    const display = try project.displayName(arena, name);
    const dashed = try project.dashed(arena, name);
    const description = opts.description orelse try std.fmt.allocPrint(arena, "{s} desktop application", .{display});
    const version = opts.version orelse project.versionOf(zon) orelse "0.1.0";
    const identifier = opts.identifier orelse try std.fmt.allocPrint(arena, "com.example.{s}", .{dashed});
    const maintainer = opts.maintainer orelse blk: {
        if (env.get("ZTS_MAINTAINER")) |from_env| break :blk from_env;
        printErr(io, "zts package: no --maintainer (or ZTS_MAINTAINER) — using a placeholder\n", .{});
        break :blk "Z-Ts <maintainer@example.com>";
    };

    var app = bundler.App.init(name, display, version, identifier, description, maintainer) catch |err| {
        printErr(io, "zts package: {s}: {s}\n", .{ @errorName(err), describeAppError(err) });
        return error.Reported;
    };

    const formats = try parseFormats(io, arena, opts.format);
    if (formats.len == 0) return error.Reported;

    const binary = readExecutable(io, arena, opts) catch |err| switch (err) {
        error.Reported => return error.Reported,
        else => return err,
    };
    const detected = bundler.binary.detect(binary) catch |err| {
        printErr(io, "zts package: the executable is not an ELF, Mach-O or PE image ({s})\n", .{@errorName(err)});
        return error.Reported;
    };

    // Depends is derived from the executable, so it is set after the binary has been read.
    app = app.withDepends(try bundler.app.runtimeDependencies(arena, binary));

    const icon_png = try readOptional(io, arena, opts.icon);
    const icon_ico = try readOptional(io, arena, opts.icon_ico);
    const manifest = try readOptional(io, arena, opts.manifest);

    for (formats) |format| {
        if ((format == .deb or format == .appdir or format == .app or format == .dmg) and detected.format == .pe) {
            printErr(io, "zts package: --format {s} needs a POSIX executable, got a PE image\n", .{@tagName(format)});
            return error.Reported;
        }
        if (format == .exe and detected.format != .pe) {
            printErr(io, "zts package: --format exe needs a Windows PE image (build with --target x86_64-windows)\n", .{});
            return error.Reported;
        }
        if (format == .dmg and builtin.os.tag != .macos) {
            printErr(io, "zts package: --format dmg needs macOS (hdiutil); use app on this host\n", .{});
            return error.Reported;
        }
    }

    const out_dir = if (opts.out) |explicit|
        explicit
    else
        try std.fmt.allocPrint(arena, "{s}/zig-out/package", .{opts.dir});
    try cwd.createDirPath(io, out_dir);
    var out_handle = try cwd.openDir(io, out_dir, .{});
    defer out_handle.close(io);

    const context = PackageContext{
        .app = app,
        .binary = binary,
        .icon_png = icon_png,
        .icon_ico = icon_ico,
        .manifest = manifest,
        .arch = detected.arch,
        .formats = formats,
        .out_dir = out_dir,
    };
    _ = &context;

    for (formats) |format| {
        try writeFormat(io, arena, cwd, out_handle, out_dir, format, context, detected);
    }

    printOut(io, "zts: packaged {d} artifact(s) into {s}\n", .{ formats.len, out_dir });
}

fn describeAppError(err: bundler.app.InitError) []const u8 {
    return switch (err) {
        error.EmptyName => "the name is empty",
        error.InvalidName => "names are [a-z][a-z0-9_-]*",
        error.NameTooLong => "the name is longer than 32 characters",
        error.InvalidVersion => "the version is not a semantic version (1.2.3)",
        error.InvalidIdentifier => "the identifier must be reverse-DNS (com.example.demo)",
        error.EmptyMaintainer => "pass --maintainer \"Name <email>\"",
        error.EmptyDescription => "pass --description",
        error.OutOfMemory => "out of memory",
    };
}

/// `--format deb,appdir` → a deduplicated list. An unknown word is a usage error that names the
/// accepted spellings, because a packaging typo discovered after `zig build` is expensive.
fn parseFormats(io: Io, arena: Allocator, text: ?[]const u8) ![]const bundler.Format {
    const raw = text orelse return try arena.dupe(bundler.Format, &.{bundler.Format.hostDefault(builtin.os.tag)});

    var list: std.ArrayListUnmanaged(bundler.Format) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |word| {
        const trimmed = std.mem.trim(u8, word, " \t");
        if (trimmed.len == 0) continue;
        const format = bundler.Format.parse(trimmed) orelse {
            printErr(io, "zts package: unknown format '{s}' (choose deb, appdir, app, dmg, exe or tar.gz)\n", .{trimmed});
            return error.Reported;
        };
        if (std.mem.indexOfScalar(bundler.Format, list.items, format) == null) {
            try list.append(arena, format);
        }
    }
    if (list.items.len == 0) {
        printErr(io, "zts package: --format is empty\n", .{});
        return error.Reported;
    }
    return list.items;
}

fn readOptional(io: Io, arena: Allocator, path: ?[]const u8) !?[]const u8 {
    const given = path orelse return null;
    return Io.Dir.cwd().readFileAlloc(io, given, arena, .limited(max_binary_bytes)) catch |err| {
        printErr(io, "zts package: cannot read {s} ({t})\n", .{ given, err });
        return error.Reported;
    };
}

/// The executable to package: `--binary`, else `zig-out/bin/<name>` with or without `.exe`.
fn readExecutable(io: Io, arena: Allocator, opts: args_mod.Package) ![]const u8 {
    const cwd = Io.Dir.cwd();
    if (opts.binary) |given| {
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ opts.dir, given });
        return cwd.readFileAlloc(io, full, arena, .limited(max_binary_bytes)) catch |err| {
            printErr(io, "zts package: cannot read {s} ({t})\n", .{ full, err });
            return error.Reported;
        };
    }

    const name = project.packageName(try readZon(io, arena, opts.dir)) orelse "app";
    for ([_]bool{ false, true }) |windows| {
        const relative = try project.executablePath(arena, name, windows);
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ opts.dir, relative });
        if (cwd.readFileAlloc(io, full, arena, .limited(max_binary_bytes))) |bytes| {
            return bytes;
        } else |_| {}
    }
    printErr(io, "zts package: {s}/zig-out/bin/{s} not found — run `zts build` first, or pass --binary\n", .{ opts.dir, name });
    return error.Reported;
}

fn payloadFor(context: PackageContext) bundler.plan.Payload {
    return .{
        .binary = context.binary,
        .icon_png = context.icon_png,
        .icon_ico = context.icon_ico,
    };
}

fn writeFormat(
    io: Io,
    arena: Allocator,
    cwd: Io.Dir,
    out_handle: Io.Dir,
    out_dir: []const u8,
    format: bundler.Format,
    context: PackageContext,
    detected: bundler.binary.Binary,
) !void {
    const app = context.app;
    const payload = payloadFor(context);

    switch (format) {
        .deb => {
            const entries = try bundler.plan.debPayload(arena, app, payload);
            const architecture = bundler.app.debArchitecture(detected.arch);
            const bytes = try bundler.deb.buildAlloc(arena, app, entries, architecture);
            const artifact = try app.artifactName(arena, .deb, architecture);
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, artifact }), .data = bytes });
            printArtifact(io, out_dir, artifact, bytes.len);
        },
        .appdir => {
            const entries = try bundler.plan.appDir(arena, app, payload);
            const artifact = try app.artifactName(arena, .appdir, bundler.app.debArchitecture(detected.arch));
            try bundler.tree.writeNamed(io, out_handle, artifact, entries);
            printOut(io, "zts: wrote {s}/{s}/ ({d} files)\n", .{ out_dir, artifact, entries.entries.len });
        },
        .app => {
            const entries = try bundler.plan.macApp(arena, app, payload);
            const artifact = try app.artifactName(arena, .app, bundler.app.debArchitecture(detected.arch));
            try bundler.tree.writeNamed(io, out_handle, artifact, entries);
            printOut(io, "zts: wrote {s}/{s}/ ({d} files)\n", .{ out_dir, artifact, entries.entries.len });
        },
        .dmg => {
            // A `.dmg` is a disk image around the `.app`, so the bundle is built first and only then
            // handed to `hdiutil` — the same step a Xcode project's "Archive" runs.
            const entries = try bundler.plan.macApp(arena, app, payload);
            const bundle = try app.artifactName(arena, .app, bundler.app.debArchitecture(detected.arch));
            try bundler.tree.writeNamed(io, out_handle, bundle, entries);
            const bundle_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, bundle });
            const artifact = try app.artifactName(arena, .dmg, bundler.app.debArchitecture(detected.arch));
            const dmg_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, artifact });
            const result = try std.process.run(arena, io, .{ .argv = &.{
                "hdiutil", "create", "-volname", app.display_name, "-srcfolder", bundle_path, "-ov", "-format", "UDZO", dmg_path,
            } });
            if (!result.term.success()) {
                printErr(io, "zts package: hdiutil failed\n{s}", .{result.stderr});
                return error.Reported;
            }
            printOut(io, "zts: wrote {s}/{s}\n", .{ out_dir, artifact });
        },
        .exe => {
            var group: ?[]const u8 = null;
            var image_list: []const []const u8 = &.{};
            if (context.icon_ico) |ico_bytes| {
                // Arena-allocated: the parsed images live as long as the process, and the CLI's
                // `gpa` is a leak-checking allocator that would flag them at exit.
                const icon = bundler.ico.parse(arena, ico_bytes) catch |err| {
                    printErr(io, "zts package: --icon-ico is not a readable .ico ({s})\n", .{@errorName(err)});
                    return error.Reported;
                };
                group = try icon.groupBlob(arena);
                const allocated = try arena.alloc([]const u8, icon.images.len);
                for (icon.images, 0..) |image, index| allocated[index] = image.bytes;
                image_list = allocated;
            }

            const resources = bundler.pe.Resources{
                .icon = if (group) |g| .{ .group = g, .images = image_list } else null,
                .manifest = context.manifest,
            };
            const bytes = bundler.pe.injectAlloc(arena, context.binary, resources) catch |err| {
                printErr(io, "zts package: cannot embed resources ({s})\n", .{@errorName(err)});
                return error.Reported;
            };
            const artifact = try app.artifactName(arena, .exe, bundler.app.debArchitecture(detected.arch));
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, artifact }), .data = bytes });
            printArtifact(io, out_dir, artifact, bytes.len);
        },
        .tar_gz => {
            const entries = try bundler.plan.portable(arena, app, payload);
            const bytes = try bundler.deb.tarGzAlloc(arena, entries.entries);
            const artifact = try app.artifactName(arena, .tar_gz, bundler.app.debArchitecture(detected.arch));
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, artifact }), .data = bytes });
            printArtifact(io, out_dir, artifact, bytes.len);
        },
    }
}

fn printArtifact(io: Io, out_dir: []const u8, artifact: []const u8, size: usize) void {
    printOut(io, "zts: wrote {s}/{s} ({d} bytes)\n", .{ out_dir, artifact, size });
}

// ---------------------------------------------------------------------------------------------
// zts doctor
// ---------------------------------------------------------------------------------------------

fn runDoctor(io: Io, arena: Allocator, dir: []const u8) !u8 {
    const cwd = Io.Dir.cwd();
    var problems: usize = 0;

    printOut(io, "zts {f}\n", .{args_mod.version});
    printOut(io, "  checkout     {s}\n", .{build_options.zts_root});
    if (cwd.access(io, build_options.zts_root, .{})) |_| {
        printOut(io, "  z_ts         present\n", .{});
    } else |_| {
        printErr(io, "  z_ts         MISSING at {s} — rebuild zts or pass --zts-path\n", .{build_options.zts_root});
        problems += 1;
    }

    const zig = resolveZig(io, arena, build_options.zts_root);
    printOut(io, "  zig          {s}\n", .{zig});

    const zon = readZon(io, arena, dir) catch |err| {
        printErr(io, "\n{s}/build.zig.zon: {t}\n", .{ dir, err });
        printErr(io, "run `zts init` to create a project here\n", .{});
        return exit_failure;
    };

    const name = project.packageName(zon) orelse blk: {
        printErr(io, "  package      MISSING `.name` in build.zig.zon\n", .{});
        problems += 1;
        break :blk "(unknown)";
    };
    printOut(io, "  package      {s}\n", .{name});

    const dep = project.dependencyPath(zon, ".z_ts");
    if (dep) |path| {
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, path });
        if (cwd.access(io, full, .{})) |_| {
            printOut(io, "  dependency   {s}\n", .{path});
        } else |_| {
            printErr(io, "  dependency   {s} does not exist (resolved from {s})\n", .{ full, dir });
            problems += 1;
        }
    } else {
        printErr(io, "  dependency   MISSING `.z_ts` in build.zig.zon\n", .{});
        problems += 1;
    }

    const web = try std.fmt.allocPrint(arena, "{s}/web", .{dir});
    if (cwd.access(io, web, .{})) |_| {
        printOut(io, "  web/         present\n", .{});
    } else |_| {
        printErr(io, "  web/         missing — the embedder needs a front end\n", .{});
        problems += 1;
    }

    if (problems == 0) {
        printOut(io, "\nall checks passed\n", .{});
        return 0;
    }
    printErr(io, "\n{d} problem(s)\n", .{problems});
    return exit_failure;
}

// ---------------------------------------------------------------------------------------------
// Shared IO
// ---------------------------------------------------------------------------------------------

fn readZon(io: Io, arena: Allocator, dir: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/build.zig.zon", .{dir});
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
}

/// `ZTS_ZIG` when set (CI pins a specific compiler), otherwise the checkout's `zigw` wrapper, so a
/// machine with no `zig` on PATH still builds a generated project.
fn resolveZig(io: Io, arena: Allocator, zts_root: []const u8) []const u8 {
    if (env_zig) |value| return value;

    // A real `zig` binary beats the `zigw` wrapper that lives in the checkout: on Windows that
    // wrapper is a shell script, and spawning it fails with `InvalidExe`. The wrapper stays as the
    // last resort for a POSIX checkout where nothing else bootstrapped the toolchain.
    if (findOnPath(io, arena, "zig")) |found| return found;

    const checkout_zig = std.fmt.allocPrint(arena, "{s}/zig", .{zts_root}) catch null;
    if (checkout_zig) |path| {
        if (Io.Dir.cwd().access(io, path, .{})) |_| return path else |_| {}
    }

    if (builtin.os.tag != .windows) {
        const wrapper = std.fmt.allocPrint(arena, "{s}/zigw", .{zts_root}) catch return "zig";
        if (Io.Dir.cwd().access(io, wrapper, .{})) |_| return wrapper else |_| {}
    }
    return "zig";
}

/// The first executable named `name` (or `name.exe` on Windows) on `PATH`, or `null`.
fn findOnPath(io: Io, arena: Allocator, name: []const u8) ?[]const u8 {
    const path = env_path orelse return null;
    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = if (builtin.os.tag == .windows)
            std.fmt.allocPrint(arena, "{s}\\{s}.exe", .{ dir, name }) catch return null
        else
            std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch return null;
        if (Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
    }
    return null;
}

/// `zig build` in `dir`, with `--summary failures` so a successful build prints nothing at all.
fn runZig(io: Io, gpa: Allocator, arena: Allocator, dir: []const u8) !std.process.RunResult {
    return runZigArgv(io, gpa, arena, dir, &.{ "build", "--summary", "failures" });
}

fn runZigArgv(io: Io, gpa: Allocator, arena: Allocator, dir: []const u8, extra: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, resolveZig(io, arena, build_options.zts_root));
    try argv.appendSlice(arena, extra);
    return std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .path = dir } });
}

/// The path a generated `build.zig.zon` should carry: relative to the new project and POSIX-style,
/// because Zig rejects absolute local dependencies. `to` may itself be relative (resolved against
/// the current directory), which is what `--zts-path ../other-checkout` means.
fn relativePath(
    io: Io,
    arena: Allocator,
    env: *std.process.Environ.Map,
    target_dir: []const u8,
    to: []const u8,
) ![]const u8 {
    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try Io.Dir.cwd().realPath(io, &cwd_buf);
    const cwd_path = cwd_buf[0..cwd_len];

    const from = try std.fs.path.resolve(arena, &.{ cwd_path, target_dir });
    const to_abs = try std.fs.path.resolve(arena, &.{ cwd_path, to });
    const rel = try std.fs.path.relativeAlloc(arena, cwd_path, env, from, to_abs);
    const out = try arena.dupe(u8, if (rel.len == 0) "." else rel);
    return project.toPosix(out);
}

fn printOut(io: Io, comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [4096]u8 = undefined;
    // `writer` is *positional* (pwrite): a fresh one starts at offset 0 and would overwrite the
    // previous line. `writerStreaming` uses the shared file offset, which is what a CLI wants.
    var writer = std.Io.File.stdout().writerStreaming(io, &buf);
    writer.interface.print(fmt, fmt_args) catch return;
    writer.interface.flush() catch return;
}

fn printErr(io: Io, comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buf);
    writer.interface.print(fmt, fmt_args) catch return;
    writer.interface.flush() catch return;
}
