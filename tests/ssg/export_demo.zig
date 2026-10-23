//! `zts_ssg` Static Export E2E Driver (`tests/ssg/export_demo.zig`).
//!
//! Invoked by `build.zig` after compiling `tests/ssg/wasm_app.zig` to `wasm32-freestanding`.
//! Produces a **real** serverless `dist/` directory:
//!   - pre-rendered `index.html` + `/gallery/index.html`
//!   - `_zts/app.wasm` (the actual compiled WebAssembly module)
//!   - scope-filtered `_zts/assets/audio/voice_clip.bin` (`secret/private.key` MUST be excluded!)
//!   - `.nojekyll`, `_headers`, `404.html`

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const web = @import("zts_web");
const ssg = @import("zts_ssg");

const index_html = @embedFile("fixtures/index.html");
const app_js = @embedFile("fixtures/app.js");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var arg_arena = std.heap.ArenaAllocator.init(allocator);
    defer arg_arena.deinit();
    const args = try init.minimal.args.toSlice(arg_arena.allocator());

    var wasm_path: ?[]const u8 = null;
    var out_dir_path: ?[]const u8 = null;
    var assets_dir_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--wasm") and i + 1 < args.len) {
            i += 1;
            wasm_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_dir_path = args[i];
        } else if (std.mem.eql(u8, arg, "--assets") and i + 1 < args.len) {
            i += 1;
            assets_dir_path = args[i];
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    const out_path = out_dir_path orelse return error.MissingOutDir;
    const wasm_file = wasm_path orelse return error.MissingWasmPath;
    const assets_path = assets_dir_path orelse return error.MissingAssetsDir;

    const wasm_bytes = try Io.Dir.cwd().readFileAlloc(io, wasm_file, allocator, .unlimited);
    defer allocator.free(wasm_bytes);

    try Io.Dir.cwd().createDirPath(io, out_path);
    const dist_dir = try Io.Dir.cwd().openDir(io, out_path, .{});
    defer dist_dir.close(io);

    const asset_source = try Io.Dir.cwd().openDir(io, assets_path, .{ .iterate = true });
    defer asset_source.close(io);

    const report = try ssg.exportStaticSite(allocator, io, dist_dir, .{
        .assets = .{
            .entries = &.{
                .{ .path = "/index.html", .bytes = index_html },
                .{ .path = "/app.js", .bytes = app_js },
            },
        },
        .window_label = "main",
        .wasm_bytes = wasm_bytes,
        .prerender_routes = &.{
            .{
                .route = "/",
                .title = "Z-Ts Studio",
                .description = "Isomorphic Zig + WebAssembly application",
                .initial_json = "{\"route\":\"/\",\"count\":1}",
            },
            .{
                .route = "/gallery",
                .title = "Gallery <Z-Ts>",
                .description = "Pre-rendered gallery page",
                .initial_json = "{\"xss\":\"</script><script>alert(1)</script>\",\"n\":2}",
                .body_html = "<main><h1>Gallery</h1><p>Pre-rendered at build time.</p></main>",
            },
        },
        .asset_source_dir = asset_source,
        .asset_scope_globs = &.{"audio/**"},
        .cross_origin_isolated = true,
    });

    std.debug.print(
        "SSG export OK: pages={d} static={d} assets={d} skipped={d} wasm={d}B\n",
        .{
            report.html_pages_written,
            report.static_files_written,
            report.bundled_assets_written,
            report.skipped_out_of_scope_assets,
            report.wasm_bytes_written,
        },
    );
}
