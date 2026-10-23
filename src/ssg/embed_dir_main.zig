//! `embedFrontendDir` CLI driver (`src/ssg/embed_dir_main.zig`).
//!
//! Invoked by the `build.zig` helper `embedFrontendDir(...)`. Scans a frontend static build
//! output directory (`Astro dist/`, `Next.js out/`, `SvelteKit build/`, `Vite dist/`) and writes
//! a deterministic `assets_manifest.zig` + staged `files/**` tree that `@embedFile` can consume.

const std = @import("std");
const Io = std.Io;

const manifest_gen = @import("manifest_gen.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arg_arena = std.heap.ArenaAllocator.init(gpa);
    defer arg_arena.deinit();
    const args = try init.minimal.args.toSlice(arg_arena.allocator());

    var src_dir_path: ?[]const u8 = null;
    var out_dir_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--src") and i + 1 < args.len) {
            i += 1;
            src_dir_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_dir_path = args[i];
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    const src_path = src_dir_path orelse return error.MissingSrcDir;
    const out_path = out_dir_path orelse return error.MissingOutDir;

    const cwd = Io.Dir.cwd();
    const src_dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch |err| {
        std.debug.print("embedFrontendDir: cannot open frontend directory '{s}': {t}\n", .{ src_path, err });
        return err;
    };
    defer src_dir.close(io);

    try cwd.createDirPath(io, out_path);
    const out_dir = try cwd.openDir(io, out_path, .{});
    defer out_dir.close(io);

    const stats = try manifest_gen.buildEmbeddedFrontendDir(gpa, io, src_dir, out_dir);

    std.debug.print(
        "embedFrontendDir: embedded {d} files ({d} bytes) from '{s}'\n",
        .{ stats.file_count, stats.total_bytes, src_path },
    );
}
