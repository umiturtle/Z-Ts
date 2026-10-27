//! Z-Ts スクリーンショット・ギャラリーのビルドグラフ (`M5-04`)。
//!
//! ```bash
//! zig build screenshots                      # zig-out/screenshots/*.png + manifest.json
//! ./zig-out/bin/zts_gallery --only hero-light  # 1 パターンだけ (直接実行)
//! zig build test                             # パターン定義の整合性チェック
//! ```
//!
//! ルート `Z-Ts` を path dependency として消費するので、`zts_webview` の C バックエンド
//! (GTK3 / WKWebView / WebView2) のリンク設定もそのまま継承されます。

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("z_ts", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zts_webview", .module = dep.module("zts_webview") },
            .{ .name = "zts_foundation", .module = dep.module("zts_foundation") },
        },
    });

    const exe = b.addExecutable(.{ .name = "zts_gallery", .root_module = mod });
    b.installArtifact(exe);

    // `zig build screenshots` — opens real windows, so it only succeeds on a machine with a
    // display (CI: Xvfb on Linux, the runner's window server on macOS/Windows).
    const shots = b.addRunArtifact(exe);
    shots.addArg("--out");
    // Relative to the package root (the run step's cwd), i.e. `examples/gallery/zig-out/screenshots`.
    shots.addArg("zig-out/screenshots");
    const shots_step = b.step("screenshots", "Render every gallery pattern and save PNGs + manifest.json");
    shots_step.dependOn(&shots.step);

    // Unit tests: pattern table integrity + URL routing (no window needed).
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run gallery pattern/routing unit tests");
    test_step.dependOn(&run_tests.step);
}
