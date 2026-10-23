//! 静的 SSG エクスポータ（`build.zig` の `dist` ステップから実行）。
//!
//! `counter.wasm`（`src/wasm_app.zig`）と埋め込みフロントエンドを受け取り、
//! GitHub Pages / Cloudflare Pages / Netlify / itch.io へ **そのまま** 配置できる
//! サーバ不要の `dist/` を生成します。
//!
//! ```bash
//! zig build dist       # -> zig-out/dist/
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ssg = @import("zts_ssg");
const frontend = @import("counter_frontend");

/// `dist/` のルートページに埋め込むビルド時スナップショット。
/// フロントエンドは `#__ZTS_SSG_DATA__` を読み、JS が動き出す前から同じ値を描画する。
const prerendered_initial_json =
    "{\"count\":0,\"step\":1,\"mutations\":0,\"mode\":\"wasm\"}";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var arg_arena = std.heap.ArenaAllocator.init(allocator);
    defer arg_arena.deinit();
    const args = try init.minimal.args.toSlice(arg_arena.allocator());

    var wasm_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--wasm") and i + 1 < args.len) {
            i += 1;
            wasm_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    const wasm_file = wasm_path orelse return error.MissingWasmPath;
    const out_dir_path = out_path orelse return error.MissingOutDir;

    const wasm_bytes = try Io.Dir.cwd().readFileAlloc(io, wasm_file, allocator, .unlimited);
    defer allocator.free(wasm_bytes);

    try Io.Dir.cwd().createDirPath(io, out_dir_path);
    const dist_dir = try Io.Dir.cwd().openDir(io, out_dir_path, .{});
    defer dist_dir.close(io);

    const report = try ssg.exportStaticSite(allocator, io, dist_dir, .{
        .assets = frontend.assets,
        .window_label = "main",
        .wasm_bytes = wasm_bytes,
        .prerender_routes = &.{
            .{
                .route = "/",
                .title = "Z-Ts Counter — 1 codebase, 3 targets",
                .description = "Desktop binary / Live HTTP bridge / Serverless WebAssembly — generated from one Zig 0.17 project.",
                .initial_json = prerendered_initial_json,
            },
        },
    });

    std.debug.print(
        "OK counter-ssg pages={d} static={d} assets={d} skipped={d} wasm={d}B\n",
        .{
            report.html_pages_written,
            report.static_files_written,
            report.bundled_assets_written,
            report.skipped_out_of_scope_assets,
            report.wasm_bytes_written,
        },
    );
}
