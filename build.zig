const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // Level 1d: `zts_core` — Desktop framework core (`zts_foundation` + `zts_web` + Window `Host` VTable).
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

    // Level 2: `z_ts` — Full umbrella module re-exporting all orthogonal layers + `BridgeHost`.
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
        },
    });

    // -------------------------------------------------------------------------
    // 2. Test Targets (strictly enforces standalone extractability in CI!)
    // -------------------------------------------------------------------------

    // Standalone external-consumer simulation: links ONLY `zts_foundation`, `zts_web`,
    // `zts_rpc`, and `zts_bridge` WITHOUT `zts_core` or `z_ts`!
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
        },
    });

    const foundation_tests = b.addTest(.{ .root_module = foundation_mod });
    const web_tests = b.addTest(.{ .root_module = web_mod });
    const rpc_tests = b.addTest(.{ .root_module = rpc_mod });
    const bridge_tests = b.addTest(.{ .root_module = bridge_mod });
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const standalone_tests = b.addTest(.{ .root_module = standalone_consumer_mod });
    const umbrella_tests = b.addTest(.{ .root_module = root_mod });

    const test_step = b.step("test", "Run isolated standalone package tests + full Z-Ts integration suite");
    test_step.dependOn(&b.addRunArtifact(foundation_tests).step);
    test_step.dependOn(&b.addRunArtifact(web_tests).step);
    test_step.dependOn(&b.addRunArtifact(rpc_tests).step);
    test_step.dependOn(&b.addRunArtifact(bridge_tests).step);
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(standalone_tests).step);
    test_step.dependOn(&b.addRunArtifact(umbrella_tests).step);
}
