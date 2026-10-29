//! `M5-01` TypeScript binding generator CLI (`src/build_tools/tsgen_main.zig`).
//!
//! The schema lives in the **app**, so the app hands over a tiny module (`--schema`, imported as
//! `app_schema`) that exposes `pub const Schema = zts_rpc.Schema(...)`. `zts_rpc.tsgen` already
//! materialises the whole `.ts` module at `comptime` (`Schema.ts_bindings`), so this binary only
//! has to move bytes around:
//!
//! ```text
//! tsgen_main <output.ts>            -> writes the bindings to stdout (captured by the build step)
//! tsgen_main <output.ts> --check    -> compares against the file on disk, exit 1 when stale
//! ```
//!
//! `--check` is what CI runs, so a schema change that was not regenerated fails the build instead
//! of silently shipping stale typings.

const std = @import("std");
const Io = std.Io;

const schema = @import("app_schema");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var check = false;
    var out_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (out_path == null) {
            out_path = arg;
        } else {
            std.debug.print("tsgen: unexpected argument '{s}'\n", .{arg});
            return error.InvalidArgument;
        }
    }
    const target = out_path orelse return error.MissingOutputPath;

    const bindings = schema.Schema.ts_bindings;

    if (!check) {
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        try stdout.interface.writeAll(bindings);
        try stdout.interface.flush();
        return 0;
    }

    const cwd = Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, target, arena, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("tsgen: {s} does not exist; run `zig build tsgen`\n", .{target});
            return 1;
        },
        else => return err,
    };

    if (std.mem.eql(u8, existing, bindings)) return 0;

    std.debug.print(
        "tsgen: {s} is stale ({d} bytes on disk, {d} generated); run `zig build tsgen`\n",
        .{ target, existing.len, bindings.len },
    );
    return 1;
}
