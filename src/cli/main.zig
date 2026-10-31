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

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const args_mod = @import("args.zig");
const template = @import("template.zig");
const project = @import("project.zig");
const devserver = @import("devserver.zig");

/// Absolute path of the Z-Ts checkout that built this binary, injected by `build.zig`. `zts init`
/// writes it into the generated `build.zig.zon`, so a project created anywhere keeps working without
/// the author having to work out a relative path.
const build_options = @import("zts_cli_options");

/// Exit codes: 0 success, 1 "the project or toolchain refused", 2 "the command line was wrong".
const exit_failure = 1;
const exit_usage = 2;

/// `ZTS_ZIG`, read once at startup. `null` means "find the toolchain the usual way".
var env_zig: ?[]const u8 = null;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    env_zig = init.environ_map.get("ZTS_ZIG");
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
    const zts_path = opts.zts_path orelse try relativeZtsPath(io, arena, env, opts.dir);

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
    const wrapper = std.fmt.allocPrint(arena, "{s}/zigw", .{zts_root}) catch return "zig";
    if (Io.Dir.cwd().access(io, wrapper, .{})) |_| return wrapper else |_| {}
    return "zig";
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

/// The path a generated `build.zig.zon` should carry: relative to the new project, because Zig
/// rejects absolute local dependencies.
fn relativeZtsPath(io: Io, arena: Allocator, env: *std.process.Environ.Map, target_dir: []const u8) ![]const u8 {
    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try Io.Dir.cwd().realPath(io, &cwd_buf);
    const cwd_path = cwd_buf[0..cwd_len];

    const from = try std.fs.path.resolve(arena, &.{ cwd_path, target_dir });
    const rel = try std.fs.path.relativeAlloc(arena, cwd_path, env, from, build_options.zts_root);
    const out = try arena.dupe(u8, if (rel.len == 0) "." else rel);
    // `relativeAlloc` uses the native separator; `build.zig.zon` paths are written POSIX-style in
    // every document, and a backslash in a Zig string literal is an escape.
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return out;
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
