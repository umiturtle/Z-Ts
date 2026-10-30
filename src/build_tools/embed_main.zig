//! `M5-01` frontend embedder CLI (`src/build_tools/embed_main.zig`).
//!
//! Invoked by the `build.zig` helper `embedFrontend(...)`. Walks a frontend build output directory
//! (`Vite dist/`, `Astro dist/`, `Next.js out/`, `SvelteKit build/`, …), stages every file into
//! `<out>/files/**` (so `@embedFile` never escapes the generated module's root), writes the
//! deterministic gzip twins, and emits `<out>/assets_manifest.zig` with the `zts_web` asset table,
//! the SHA-256 digests, the gzip twins and the CSP hashes of inline scripts/styles.
//!
//! Prints one machine-readable summary line so CI can assert the step actually ran:
//! `OK build-tools embed files=N raw=B gzip=G csp=H`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const assets = @import("assets.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var src_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var gzip = true;
    var csp = true;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--src") and i + 1 < args.len) {
            i += 1;
            src_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--gzip")) {
            gzip = true;
        } else if (std.mem.eql(u8, arg, "--no-gzip")) {
            gzip = false;
        } else if (std.mem.eql(u8, arg, "--csp")) {
            csp = true;
        } else if (std.mem.eql(u8, arg, "--no-csp")) {
            csp = false;
        } else {
            std.debug.print("embedFrontend: unknown argument '{s}'\n", .{arg});
            return error.InvalidArgument;
        }
    }

    const src_dir_path = src_path orelse return error.MissingSrcDir;
    const out_dir_path = out_path orelse return error.MissingOutDir;

    const cwd = Io.Dir.cwd();
    const src_dir = cwd.openDir(io, src_dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("embedFrontend: cannot open frontend directory '{s}': {t}\n", .{ src_dir_path, err });
        return err;
    };
    defer src_dir.close(io);

    var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var byte_list: std.ArrayListUnmanaged([]const u8) = .empty;

    var walker = try src_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // POSIX-normalized so Windows drive letters / backslashes never leak into generated code.
        const normalized = try arena.dupe(u8, entry.path);
        for (normalized) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        const bytes = try src_dir.readFileAlloc(io, entry.path, arena, .unlimited);
        try path_list.append(arena, normalized);
        try byte_list.append(arena, bytes);
    }

    const inputs = try arena.alloc(assets.Input, path_list.items.len);
    for (inputs, path_list.items, byte_list.items) |*input, path, bytes| {
        input.* = .{ .path = path, .bytes = bytes };
    }

    var bundle = assets.build(arena, inputs, .{ .gzip = gzip, .csp = csp }) catch |err| {
        std.debug.print("embedFrontend: cannot build the asset bundle: {t}\n", .{err});
        return err;
    };
    defer bundle.deinit(arena);

    try cwd.createDirPath(io, out_dir_path);
    const out_dir = try cwd.openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    var raw_bytes: u64 = 0;
    var gzip_bytes: u64 = 0;
    var gzip_count: usize = 0;

    for (inputs, 0..) |input, index| {
        raw_bytes += input.bytes.len;
        try writeStaged(io, out_dir, arena, input.path, input.bytes);
        if (bundle.gzip[index]) |compressed| {
            gzip_bytes += compressed.len;
            gzip_count += 1;
            const gz_path = try std.fmt.allocPrint(arena, "{s}.gz", .{input.path});
            try writeStaged(io, out_dir, arena, gz_path, compressed);
        }
    }

    try out_dir.writeFile(io, .{ .sub_path = "assets_manifest.zig", .data = bundle.manifest });

    std.debug.print(
        "OK build-tools embed files={d} raw={d} gzip={d} csp={d} gz={d}\n",
        .{ inputs.len, raw_bytes, gzip_count, bundle.csp_hashes.len, gzip_bytes },
    );
}

fn writeStaged(io: Io, out_dir: Io.Dir, arena: Allocator, path: []const u8, bytes: []const u8) !void {
    const staged = try std.fmt.allocPrint(arena, "files/{s}", .{path});
    if (std.mem.lastIndexOfScalar(u8, staged, '/')) |slash| {
        if (slash > 0) try out_dir.createDirPath(io, staged[0..slash]);
    }
    try out_dir.writeFile(io, .{ .sub_path = staged, .data = bytes });
}
