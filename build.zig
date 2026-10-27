const std = @import("std");

fn detectSystemGtkWebkit(b: *std.Build) bool {
    var code: u8 = 0;
    _ = b.runAllowFail(&.{ "pkg-config", "--exists", "webkit2gtk-4.1", "gtk+-3.0" }, &code, .ignore) catch return false;
    return code == 0;
}

// ---------------------------------------------------------------------------
// Public Build Helper: `embedFrontendDir`
// ---------------------------------------------------------------------------

pub const EmbedFrontendDirOptions = struct {
    /// Frontend static build output directory (Astro `dist/`, Next.js `out/`, Vite `dist/`, ...).
    src_dir: std.Build.LazyPath,
    /// Import name of the generated `zts_web.Assets` module.
    module_name: []const u8 = "embedded_frontend",
};

pub const EmbeddedFrontendDir = struct {
    /// The generation step (add it as a dependency of anything consuming the module).
    run: *std.Build.Step.Run,
    /// Generated module exposing `entries`, `sha256_digests` and `assets: zts_web.Assets`.
    module: *std.Build.Module,
};

/// Scans `opts.src_dir` at build time and generates a deterministic `zts_web.Assets` module
/// backed by `@embedFile`, ready for `embedFrontendDir`-based static serving / SSG export.
///
/// ```zig
/// const embedded = embedFrontendDir(b, web_mod, .{ .src_dir = b.path("frontend/dist") });
/// // -> `embedded.module` is importable as `@import("embedded_frontend")`
/// ```
pub fn embedFrontendDir(
    b: *std.Build,
    web_mod: *std.Build.Module,
    opts: EmbedFrontendDirOptions,
) EmbeddedFrontendDir {
    const scan_mod = b.createModule(.{
        .root_source_file = b.path("src/ssg/mod.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = b.modules.get("zts_foundation").? },
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "zts_wasm", .module = b.modules.get("zts_wasm").? },
        },
    });
    const scan_exe = b.addExecutable(.{
        .name = "zts_embed_frontend_dir",
        .root_module = scan_mod,
    });
    const run = b.addRunArtifact(scan_exe);
    // The scanner writes a directory tree (`assets_manifest.zig` + staged `files/**`).
    // Zig does not verify output *directories*, so force execution to keep the tree present.
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
        .imports = &.{
            .{ .name = "zts_web", .module = web_mod },
        },
    });

    return .{ .run = run, .module = module };
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

    // macOS native backend (`Cocoa` + `WKWebView`, `M3-01`). Auto-enabled for macOS targets;
    // the Objective-C shim is NEVER compiled on Linux/Windows (`-Dmacos=false` keeps it out).
    const is_macos = target.result.os.tag == .macos;
    const enable_macos = b.option(
        bool,
        "macos",
        "Enable native macOS Cocoa + WKWebView backend (default: auto-detected from the target OS)",
    ) orelse is_macos;

    // Windows native backend (`Win32` + Direct `WebView2`, `M3-02`). Auto-enabled for Windows
    // targets; the Win32/COM declarations are never analyzed on other OSes.
    const is_windows = target.result.os.tag == .windows;
    const enable_windows = b.option(
        bool,
        "windows",
        "Enable native Windows Win32 + Direct WebView2 backend (default: auto-detected from the target OS)",
    ) orelse is_windows;

    const webview_opts = b.addOptions();
    webview_opts.addOption(bool, "enable_gtk", is_linux and enable_gtk);
    webview_opts.addOption(bool, "enable_macos", is_macos and enable_macos);
    webview_opts.addOption(bool, "enable_windows", is_windows and enable_windows);

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
    const native_macos = is_macos and enable_macos;
    const native_windows = is_windows and enable_windows;
    const webview_mod = b.addModule("zts_webview", .{
        .root_source_file = b.path("src/webview/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = (is_linux and enable_gtk) or native_macos or native_windows,
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
    if (native_macos) {
        // Pure C ABI Objective-C shim: no `@cImport`, no `addTranslateC`, ~2s cold link.
        webview_mod.addCSourceFile(.{
            .file = b.path("src/webview/macos_shim.m"),
            .flags = &.{ "-fobjc-arc", "-fno-objc-arc-exceptions", "-Wall", "-Wextra" },
        });
        webview_mod.linkFramework("Cocoa", .{});
        webview_mod.linkFramework("WebKit", .{});
        webview_mod.linkFramework("Foundation", .{});
    }
    if (native_windows) {
        // Same import libraries Microsoft's `WebView2Loader.lib` declares — resolved from the
        // Zig 0.17 toolchain's bundled `x86_64-windows-gnu` import libs (no SDK / MSVC needed).
        // `use_pkg_config = .no` is mandatory: the GitHub-hosted Windows runners have no
        // `pkg-config` executable, and Zig's default (`.yes`) turns every `kernel32` lookup into a
        // hard configure error before the linker ever runs.
        for ([_][]const u8{
            "user32", "kernel32", "ole32", "oleaut32", "shlwapi",
            "dwmapi", "advapi32", "gdi32", "shell32",  "comdlg32",
        }) |lib| webview_mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
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

    // Level 1g: `zts_wasm` — Isomorphic `wasm32-freestanding` runtime (`WasmHost`, `Instance`, C ABI exports).
    // Zero libc / OS GUI / socket dependencies; compiles identically for native unit tests & `.wasm`.
    const wasm_mod = b.addModule("zts_wasm", .{
        .root_source_file = b.path("src/wasm/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "zts_core", .module = core_mod },
            .{ .name = "zts_rpc", .module = rpc_mod },
            .{ .name = "zts_tauri", .module = tauri_mod },
        },
    });

    // Level 1h: `zts_ssg` — Bidirectional SSG toolkit (`embedFrontendDir` manifest generation +
    // subpath-safe static `dist/` exporter with pre-rendering & scoped asset bundling).
    const ssg_mod = b.addModule("zts_ssg", .{
        .root_source_file = b.path("src/ssg/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_foundation", .module = foundation_mod },
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "zts_wasm", .module = wasm_mod },
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
            .{ .name = "zts_wasm", .module = wasm_mod },
            .{ .name = "zts_ssg", .module = ssg_mod },
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

    // -------------------------------------------------------------------------
    // 2b. Isomorphic SSG / WebAssembly E2E Gate (`M2-01`)
    //     Compiles the SAME app spec to `wasm32-freestanding`, exports a real
    //     serverless `dist/` tree, and drives the unmodified `@tauri-apps/api` v2
    //     suite over WebAssembly with Node 22 (Linux / macOS / Windows).
    // -------------------------------------------------------------------------
    const wasm_optimize = b.option(
        std.builtin.Optimize,
        "wasm-optimize",
        "Optimize mode for the wasm32-freestanding SSG demo bundle (debug/safe/fast/small; default small)",
    ) orelse .small;

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.generic },
    });

    const wasm_app_mod = b.createModule(.{
        .root_source_file = b.path("tests/ssg/wasm_app.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_core", .module = core_mod },
            .{ .name = "zts_rpc", .module = rpc_mod },
            .{ .name = "zts_tauri", .module = tauri_mod },
            .{ .name = "zts_wasm", .module = wasm_mod },
        },
    });
    const wasm_app_exe = b.addExecutable(.{
        .name = "zts_ssg_app",
        .root_module = wasm_app_mod,
    });
    // Zig 0.17 only forwards `export` / `@export` symbols into the wasm export section under
    // `-rdynamic`; without it the linker keeps just `memory` + `_start`.
    wasm_app_exe.rdynamic = true;

    // Native copy of the very same spec (`std.testing.allocator` zero-leak lifecycle proof).
    const wasm_app_native_mod = b.createModule(.{
        .root_source_file = b.path("tests/ssg/wasm_app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_core", .module = core_mod },
            .{ .name = "zts_rpc", .module = rpc_mod },
            .{ .name = "zts_tauri", .module = tauri_mod },
            .{ .name = "zts_wasm", .module = wasm_mod },
        },
    });
    const wasm_app_native_tests = b.addTest(.{ .root_module = wasm_app_native_mod });

    // Inbound SSG: generate an `zts_web.Assets` module from a multi-page frontend build tree.
    const embedded_frontend = embedFrontendDir(b, web_mod, .{
        .src_dir = b.path("tests/ssg/fixtures/site"),
        .module_name = "embedded_frontend",
    });
    const embedded_consumer_mod = b.createModule(.{
        .root_source_file = b.path("tests/ssg/embedded_consumer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "embedded_frontend", .module = embedded_frontend.module },
        },
    });
    const embedded_consumer_tests = b.addTest(.{ .root_module = embedded_consumer_mod });

    // Native SSG exporter CLI (reads the compiled `.wasm`, writes `dist/`).
    const export_demo_mod = b.createModule(.{
        .root_source_file = b.path("tests/ssg/export_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_web", .module = web_mod },
            .{ .name = "zts_ssg", .module = ssg_mod },
        },
    });
    const export_demo_exe = b.addExecutable(.{
        .name = "zts_ssg_export_demo",
        .root_module = export_demo_mod,
    });

    const run_export = b.addRunArtifact(export_demo_exe);
    run_export.addArg("--wasm");
    run_export.addFileArg(wasm_app_exe.getEmittedBin());
    run_export.addArg("--assets");
    run_export.addArg("tests/ssg/fixtures/assets");
    run_export.addArg("--out");
    const dist_dir = run_export.addOutputDirectoryArg("dist");

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
    if (native_macos) {
        // A static archive does not propagate the frameworks its objects need, so the strict C99
        // ABI consumer declares them itself (`M3-01`).
        c_abi_mod.linkFramework("Cocoa", .{});
        c_abi_mod.linkFramework("WebKit", .{});
        c_abi_mod.linkFramework("Foundation", .{});
    }
    const c_abi_exe = b.addExecutable(.{
        .name = "verify_webview_c_abi",
        .root_module = c_abi_mod,
    });

    // `M3-02` deployment proof: a **single** self-contained `.exe` (no `WebView2Loader.dll`).
    // Built for every Windows target — including Linux -> `-Dtarget=x86_64-windows-gnu` — and
    // installed so `ci-windows` can execute the exact shipped binary.
    if (native_windows) {
        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("tests/webview/windows_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zts_webview", .module = webview_mod },
            },
        });
        const smoke_exe = b.addExecutable(.{
            .name = "zts_webview2_smoke",
            .root_module = smoke_mod,
        });
        b.installArtifact(smoke_exe);
    }

    const foundation_tests = b.addTest(.{ .root_module = foundation_mod });
    const web_tests = b.addTest(.{ .root_module = web_mod });
    const rpc_tests = b.addTest(.{ .root_module = rpc_mod });
    const bridge_tests = b.addTest(.{ .root_module = bridge_mod });
    const webview_tests = b.addTest(.{ .root_module = webview_mod });
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const tauri_tests = b.addTest(.{ .root_module = tauri_mod });
    const wasm_tests = b.addTest(.{ .root_module = wasm_mod });
    const ssg_tests = b.addTest(.{ .root_module = ssg_mod });
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
    // 4-mode isomorphism gate: run the SAME `@tauri-apps/api` v2 bundle against the
    // serverless `wasm32-freestanding` build over a static-file host (static CDN semantics).
    const run_wasm_e2e = b.addSystemCommand(&.{ "node", "tests/ssg/node_wasm_runner.mjs" });
    run_wasm_e2e.addDirectoryArg(dist_dir);
    run_wasm_e2e.addFileArg(bundled_tauri_js);

    const tauri_e2e_tests = b.addTest(.{ .root_module = tauri_e2e_mod });

    const test_step = b.step("test", "Run isolated standalone package tests + C99 ABI check + full Z-Ts & Tauri v2 E2E suite");
    test_step.dependOn(&b.addRunArtifact(foundation_tests).step);
    test_step.dependOn(&b.addRunArtifact(web_tests).step);
    test_step.dependOn(&b.addRunArtifact(rpc_tests).step);
    test_step.dependOn(&b.addRunArtifact(bridge_tests).step);
    test_step.dependOn(&b.addRunArtifact(webview_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(tauri_tests).step);
    test_step.dependOn(&b.addRunArtifact(wasm_tests).step);
    test_step.dependOn(&b.addRunArtifact(ssg_tests).step);
    test_step.dependOn(&b.addRunArtifact(standalone_tests).step);
    test_step.dependOn(&b.addRunArtifact(c_abi_exe).step);
    test_step.dependOn(&b.addRunArtifact(umbrella_tests).step);
    test_step.dependOn(&b.addRunArtifact(tauri_e2e_tests).step);
    test_step.dependOn(&b.addRunArtifact(wasm_app_native_tests).step);
    test_step.dependOn(&b.addRunArtifact(embedded_consumer_tests).step);
    test_step.dependOn(&run_wasm_e2e.step);
}
