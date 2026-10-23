//! Z-Ts ショーケースサンプル「Counter」ビルドグラフ (`M2-02`)。
//!
//! **1 つのプロジェクトから 3 つの成果物** を生成します:
//!
//! ```bash
//! zig build                 # 既定: desktop / live / wasm / dist を zig-out/ へ
//! zig build desktop         # 単一バイナリ (zig-out/bin/counter)
//! zig build live            # Live Preview サーバ (zig-out/bin/counter-live)
//! zig build dist            # サーバ不要の静的サイト (zig-out/dist/, counter.wasm 同梱)
//! zig build preview         # Live Preview を 0.0.0.0:8788 で起動 (Arena Live Preview 用)
//! zig build test            # 単体テスト + 実 TCP E2E + 実 WebAssembly E2E
//! ```
//!
//! 本パッケージはルート `Z-Ts` を **path dependency** (`b.dependency("z_ts")`) として消費します。
//! つまり外部プロジェクトが同じモジュール群をそのまま利用できることの実証も兼ねています。

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wasm_optimize = b.option(
        std.builtin.Optimize,
        "wasm-optimize",
        "Optimize mode for counter.wasm (debug/safe/fast/small; default small)",
    ) orelse .small;

    const dep = b.dependency("z_ts", .{ .target = target, .optimize = optimize });

    const zts_foundation = dep.module("zts_foundation");
    const zts_web = dep.module("zts_web");
    const zts_core = dep.module("zts_core");
    const zts_rpc = dep.module("zts_rpc");
    const zts_tauri = dep.module("zts_tauri");
    const zts_wasm = dep.module("zts_wasm");
    const zts_bridge = dep.module("zts_bridge");
    const zts_ssg = dep.module("zts_ssg");
    const z_ts = dep.module("z_ts");

    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zts_foundation", .module = zts_foundation },
        .{ .name = "zts_web", .module = zts_web },
        .{ .name = "zts_core", .module = zts_core },
        .{ .name = "zts_rpc", .module = zts_rpc },
        .{ .name = "zts_tauri", .module = zts_tauri },
        .{ .name = "zts_wasm", .module = zts_wasm },
    };

    // -------------------------------------------------------------------------
    // 1. フロントエンド: `web/main.ts` → esbuild(IIFE) → `embedFrontendDir`
    // -------------------------------------------------------------------------
    const build_web = b.addSystemCommand(&.{ "node", "scripts/build-web.mjs" });
    build_web.addFileInput(b.path("scripts/build-web.mjs"));
    build_web.addFileInput(b.path("web/main.ts"));
    build_web.addFileInput(b.path("web/index.html"));
    build_web.addFileInput(b.path("web/styles.css"));
    build_web.addFileInput(b.path("web/tsconfig.json"));
    const web_dir = build_web.addOutputDirectoryArg("counter-web");

    const frontend = embedFrontendDir(b, dep, .{
        .src_dir = web_dir,
        .module_name = "counter_frontend",
    });

    const desktop_imports: []const std.Build.Module.Import = &.{
        .{ .name = "counter_frontend", .module = frontend.module },
        .{ .name = "z_ts", .module = z_ts },
        .{ .name = "zts_foundation", .module = zts_foundation },
        .{ .name = "zts_web", .module = zts_web },
        .{ .name = "zts_core", .module = zts_core },
        .{ .name = "zts_rpc", .module = zts_rpc },
        .{ .name = "zts_tauri", .module = zts_tauri },
        .{ .name = "zts_wasm", .module = zts_wasm },
    };

    const live_imports: []const std.Build.Module.Import = &.{
        .{ .name = "counter_frontend", .module = frontend.module },
        .{ .name = "z_ts", .module = z_ts },
        .{ .name = "zts_bridge", .module = zts_bridge },
        .{ .name = "zts_foundation", .module = zts_foundation },
        .{ .name = "zts_web", .module = zts_web },
        .{ .name = "zts_core", .module = zts_core },
        .{ .name = "zts_rpc", .module = zts_rpc },
        .{ .name = "zts_tauri", .module = zts_tauri },
        .{ .name = "zts_wasm", .module = zts_wasm },
    };

    // -------------------------------------------------------------------------
    // 2. 成果物 ①: デスクトップ単一バイナリ
    // -------------------------------------------------------------------------
    const desktop_mod = b.createModule(.{
        .root_source_file = b.path("src/desktop.zig"),
        .target = target,
        .optimize = optimize,
        .imports = desktop_imports,
    });
    const desktop_exe = b.addExecutable(.{ .name = "counter", .root_module = desktop_mod });
    b.installArtifact(desktop_exe);

    const desktop_step = b.step("desktop", "Build the desktop single binary (zig-out/bin/counter)");
    const install_desktop = b.addInstallArtifact(desktop_exe, .{});
    desktop_step.dependOn(&install_desktop.step);

    // -------------------------------------------------------------------------
    // 3. 成果物 ②: Live Preview（HTTP Bridge）サーバ
    // -------------------------------------------------------------------------
    const live_mod = b.createModule(.{
        .root_source_file = b.path("src/live.zig"),
        .target = target,
        .optimize = optimize,
        .imports = live_imports,
    });
    const live_exe = b.addExecutable(.{ .name = "counter-live", .root_module = live_mod });
    b.installArtifact(live_exe);

    const live_step = b.step("live", "Build the Live Preview HTTP bridge server (zig-out/bin/counter-live)");
    const install_live = b.addInstallArtifact(live_exe, .{});
    live_step.dependOn(&install_live.step);

    // Zig 0.17 の `std.Build` には `-- ` 引数転送フィールドが無いため、既定ポートで起動する。
    // ポートを変える場合は `zig-out/bin/counter-live --port <n>` を直接実行する。
    const run_live = b.addRunArtifact(live_exe);
    const preview_step = b.step("preview", "Run the Live Preview server (0.0.0.0:8788)");
    preview_step.dependOn(&run_live.step);

    // -------------------------------------------------------------------------
    // 4. 成果物 ③: `wasm32-freestanding` + 静的 SSG サイト
    // -------------------------------------------------------------------------
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.generic },
    });
    const wasm_app_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_app.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .imports = app_imports,
    });
    const wasm_exe = b.addExecutable(.{ .name = "counter", .root_module = wasm_app_mod });
    // Zig 0.17 は `-rdynamic` なしでは `memory` / `_start` 以外をエクスポートしない。
    wasm_exe.rdynamic = true;
    b.installArtifact(wasm_exe);

    const ssg_export_mod = b.createModule(.{
        .root_source_file = b.path("src/ssg_export.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "counter_frontend", .module = frontend.module },
            .{ .name = "zts_ssg", .module = zts_ssg },
            .{ .name = "zts_web", .module = zts_web },
            .{ .name = "zts_foundation", .module = zts_foundation },
        },
    });
    const ssg_export_exe = b.addExecutable(.{ .name = "counter-ssg-export", .root_module = ssg_export_mod });

    const run_export = b.addRunArtifact(ssg_export_exe);
    run_export.addArg("--wasm");
    run_export.addFileArg(wasm_exe.getEmittedBin());
    run_export.addArg("--out");
    const dist_dir = run_export.addOutputDirectoryArg("dist");

    const install_dist = b.addInstallDirectory(.{
        .source_dir = dist_dir,
        .install_dir = .prefix,
        .install_subdir = "dist",
    });
    const dist_step = b.step("dist", "Export the serverless static site (zig-out/dist/)");
    dist_step.dependOn(&install_dist.step);
    b.getInstallStep().dependOn(&install_dist.step);

    const run_wasm_probe = b.addSystemCommand(&.{ "node", "tests/ssg_probe.mjs" });
    run_wasm_probe.addDirectoryArg(dist_dir);

    // -------------------------------------------------------------------------
    // 5. テスト: 単体（zero-leak）+ 実 TCP/SSE + 実 WebAssembly + デスクトップ自己診断
    // -------------------------------------------------------------------------
    const app_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = app_imports,
    });
    const app_tests = b.addTest(.{ .root_module = app_tests_mod });

    const live_test_mod = b.createModule(.{
        .root_source_file = b.path("src/live_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "counter_frontend", .module = frontend.module },
            .{ .name = "z_ts", .module = z_ts },
            .{ .name = "zts_bridge", .module = zts_bridge },
            .{ .name = "zts_foundation", .module = zts_foundation },
            .{ .name = "zts_web", .module = zts_web },
            .{ .name = "zts_core", .module = zts_core },
            .{ .name = "zts_rpc", .module = zts_rpc },
            .{ .name = "zts_tauri", .module = zts_tauri },
            .{ .name = "zts_wasm", .module = zts_wasm },
            .{ .name = "live_probe_js", .module = b.createModule(.{ .root_source_file = b.path("tests/live_probe.mjs") }) },
        },
    });
    const live_tests = b.addTest(.{ .root_module = live_test_mod });

    const run_desktop_selftest = b.addRunArtifact(desktop_exe);
    run_desktop_selftest.addArg("--selftest");

    const test_step = b.step("test", "Run unit + live bridge E2E + static WebAssembly E2E");
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    test_step.dependOn(&b.addRunArtifact(live_tests).step);
    test_step.dependOn(&run_wasm_probe.step);
    test_step.dependOn(&run_desktop_selftest.step);
}

// ---------------------------------------------------------------------------
// `embedFrontendDir` — ルート `build.zig` と同等の暫定実装。
//
// `M5-01` で `src/build_tools/` へ抽出され、依存パッケージから直接呼べる公開 API に昇格する
// 予定です。それまでは「外部パッケージから `dep.module("zts_ssg")` を再利用して同じスキャナを
// 起動できる」ことを示すため、このサンプル内に同型の実装を置いています。
// ---------------------------------------------------------------------------
const EmbedFrontendDirOptions = struct {
    src_dir: std.Build.LazyPath,
    module_name: []const u8,
};

const EmbeddedFrontend = struct {
    run: *std.Build.Step.Run,
    module: *std.Build.Module,
};

fn embedFrontendDir(
    b: *std.Build,
    dep: *std.Build.Dependency,
    opts: EmbedFrontendDirOptions,
) EmbeddedFrontend {
    const scan_mod = b.createModule(.{
        .root_source_file = dep.builder.path("src/ssg/mod.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = dep.module("zts_foundation") },
            .{ .name = "zts_web", .module = dep.module("zts_web") },
            .{ .name = "zts_wasm", .module = dep.module("zts_wasm") },
        },
    });
    const scan_exe = b.addExecutable(.{ .name = "counter_embed_frontend", .root_module = scan_mod });
    const run = b.addRunArtifact(scan_exe);
    // 出力はディレクトリ（`assets_manifest.zig` + `files/**`）なので Zig は存在検証しない。
    run.has_side_effects = true;
    run.addArg("--src");
    run.addDirectoryArg(opts.src_dir);
    run.addArg("--out");
    const generated_dir = run.addOutputDirectoryArg(opts.module_name);

    const module = b.createModule(.{
        .root_source_file = generated_dir.path(b, "assets_manifest.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = false,
        .imports = &.{.{ .name = "zts_web", .module = dep.module("zts_web") }},
    });

    return .{ .run = run, .module = module };
}
