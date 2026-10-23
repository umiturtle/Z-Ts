const std = @import("std");

fn detectSystemGtkWebkit(b: *std.Build) bool {
    var code: u8 = 0;
    _ = b.runAllowFail(&.{ "pkg-config", "--exists", "webkit2gtk-4.1", "gtk+-3.0" }, &code, .ignore) catch return false;
    return code == 0;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_linux = target.result.os.tag == .linux;
    const enable_gtk = b.option(
        bool,
        "gtk",
        "Enable native Linux GTK3 + WebKit2GTK 4.1 backend (default: auto-detected via pkg-config)",
    ) orelse (is_linux and target.query.isNative() and detectSystemGtkWebkit(b));

    const webview_opts = b.addOptions();
    webview_opts.addOption(bool, "enable_gtk", is_linux and enable_gtk);

    // -------------------------------------------------------------------------
    // 1. Standalone Public Modules (independently importable via `b.dependency`)
    //    Every `.zig` source file belongs to strictly ONE module (disjoint DAG).
    // -------------------------------------------------------------------------

    // Level 0: `zts_foundation` — Zero-dependency runtime primitives (`OwnedBytes`,
    // `HandlePool`, `RingQueue`, `geometry`, `url`, `glob`, `html_escape`, `OutgoingResponse`).
    const foundation_mod = b.addModule("zts_foundation", .{
        .root_source_file = b.path("src/core/foundation.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    // Level 1a: `zts_web` — Standalone embedded asset server, RFC 9110 `206` HTTP Range
    // seeking, MIME sniffer & CSP builder. Zero windowing / RPC coupling.
    const web_mod = b.addModule("zts_web", .{
        .root_source_file = b.path("src/core/web.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
        },
    });

    // Level 1b: `zts_rpc` — Standalone `comptime` JSON/Binary RPC router, codec & `tsgen`.
    // Depends ONLY on `zts_foundation` (zero dependency on desktop Window `Host` or Tauri).
    const rpc_mod = b.addModule("zts_rpc", .{
        .root_source_file = b.path("src/rpc/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
        },
    });

    // Level 1c: `zts_bridge` — Standalone pure-Zig HTTP/1.1 + `206` Range + triple-CSRF RPC + SSE server.
    // Zero OS GUI / WebView dependencies (consumable standalone by engines, streaming tools & servers).
    const bridge_mod = b.addModule("zts_bridge", .{
        .root_source_file = b.path("src/bridge/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "zts_rpc", .module = rpc_mod },
        },
    });

    // Level 1d: `zts_webview` — Standalone minimal native WebView (`GTK3 + WebKit2GTK 4.1`),
    // `HeadlessMock`, and flat C ABI (`include/zts_webview.h`). Zero JSON / RPC / Tauri coupling!
    const webview_mod = b.addModule("zts_webview", .{
        .root_source_file = b.path("src/webview/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = is_linux and enable_gtk,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
            .{ .name = "webview_options", .module = webview_opts.createModule() },
        },
    });
    if (is_linux and enable_gtk) {
        webview_mod.linkSystemLibrary("gtk+-3.0", .{});
        webview_mod.linkSystemLibrary("webkit2gtk-4.1", .{});
        webview_mod.linkSystemLibrary("libsoup-3.0", .{});
        webview_mod.linkSystemLibrary("javascriptcoregtk-4.1", .{});
    }

    // Level 1e: `zts_core` — Desktop framework core (`zts_foundation` + `zts_web` + Window `Host` VTable).
    const core_mod = b.addModule("zts_core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
            .{ .name = "zts_web", .module = web_mod },
        },
    });

    // Level 1f: `zts_tauri` — Pure-Zig Tauri v2 wire protocol, `Channel(T)`, JS bootstrap & core plugins.
    // Zero OS GUI / socket dependencies (`link_libc = false`) — runs identically over `WebviewHost` or `BridgeHost`.
    const tauri_mod = b.addModule("zts_tauri", .{
        .root_source_file = b.path("src/tauri/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "zts_core", .module = core_mod },
            .{ .name = "zts_rpc", .module = rpc_mod },
        },
    });

    // Level 2: `z_ts` — Full umbrella module re-exporting all orthogonal layers + `BridgeHost`, `WebviewHost` & `DesktopRuntime`.
    const root_mod = b.addModule("z_ts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "zts_core", .module = core_mod },
            .{ .name = "zts_rpc", .module = rpc_mod },
            .{ .name = "zts_bridge", .module = bridge_mod },
            .{ .name = "zts_webview", .module = webview_mod },
            .{ .name = "zts_tauri", .module = tauri_mod },
        },
    });

    // -------------------------------------------------------------------------
    // 2. Test Targets (strictly enforces standalone extractability & C ABI in CI!)
    // -------------------------------------------------------------------------

    // Standalone external-consumer simulation: links ONLY standalone foundation modules
    // WITHOUT `zts_core` or `z_ts`!
    const standalone_consumer_mod = b.createModule(.{
        .root_source_file = b.path("tests/standalone_modules.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "zts_rpc", .module = rpc_mod },
            .{ .name = "zts_bridge", .module = bridge_mod },
            .{ .name = "zts_webview", .module = webview_mod },
        },
    });

    // Strict C99 ABI consumer executable verifying `include/zts_webview.h` layout & exported symbols!
    const c_abi_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_abi_mod.addIncludePath(b.path("include"));
    c_abi_mod.addCSourceFile(.{
        .file = b.path("tests/webview/verify_c_abi.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" },
    });
    const c_abi_lib = b.addLibrary(.{
        .name = "zts_webview_static",
        .linkage = .static,
        .root_module = webview_mod,
    });
    c_abi_mod.linkLibrary(c_abi_lib);
    const c_abi_exe = b.addExecutable(.{
        .name = "verify_webview_c_abi",
        .root_module = c_abi_mod,
    });

    const foundation_tests = b.addTest(.{ .root_module = foundation_mod });
    const web_tests = b.addTest(.{ .root_module = web_mod });
    const rpc_tests = b.addTest(.{ .root_module = rpc_mod });
    const bridge_tests = b.addTest(.{ .root_module = bridge_mod });
    const webview_tests = b.addTest(.{ .root_module = webview_mod });
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const tauri_tests = b.addTest(.{ .root_module = tauri_mod });
    const standalone_tests = b.addTest(.{ .root_module = standalone_consumer_mod });
    const umbrella_tests = b.addTest(.{ .root_module = root_mod });

    // Bundle unmodified upstream `@tauri-apps/api` v2 (`tsc --noEmit --strict` + `esbuild`) and
    // run full live E2E tests against BOTH `BridgeServer`+Node22 (all 3 OSes) AND `WebKit2GTK 4.1`!
    const prepare_tauri_js = b.addSystemCommand(&.{ "node", "scripts/prepare-tauri-e2e.mjs" });
    const bundled_tauri_js = prepare_tauri_js.addOutputFileArg("e2e_suite.bundle.js");
    // Invalidate bundle whenever TS sources or lockfile change
    prepare_tauri_js.addFileInput(b.path("tests/tauri/src/e2e_suite.ts"));
    prepare_tauri_js.addFileInput(b.path("tests/tauri/src/generated_api.ts"));
    prepare_tauri_js.addFileInput(b.path("tests/tauri/package.json"));

    const tauri_e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/tauri/e2e_live.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "z_ts", .module = root_mod },
            .{ .name = "e2e_bundle", .module = b.createModule(.{ .root_source_file = bundled_tauri_js }) },
        },
    });
    const tauri_e2e_tests = b.addTest(.{ .root_module = tauri_e2e_mod });

    const test_step = b.step("test", "Run isolated standalone package tests + C99 ABI check + full Z-Ts & Tauri v2 E2E suite");
    test_step.dependOn(&b.addRunArtifact(foundation_tests).step);
    test_step.dependOn(&b.addRunArtifact(web_tests).step);
    test_step.dependOn(&b.addRunArtifact(rpc_tests).step);
    test_step.dependOn(&b.addRunArtifact(bridge_tests).step);
    test_step.dependOn(&b.addRunArtifact(webview_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(tauri_tests).step);
    test_step.dependOn(&b.addRunArtifact(standalone_tests).step);
    test_step.dependOn(&b.addRunArtifact(c_abi_exe).step);
    test_step.dependOn(&b.addRunArtifact(umbrella_tests).step);
    test_step.dependOn(&b.addRunArtifact(tauri_e2e_tests).step);
}
