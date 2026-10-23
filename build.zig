const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Standalone `zts_core` module (`link_libc = false` invariant)
    const core_mod = b.addModule("zts_core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    // Top-level `z_ts` umbrella module exposing `.core`, `.rpc` (`Schema`, `bind`, `tsgen`, `codec`), etc.
    const root_mod = b.addModule("z_ts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run Z-Ts unit & integration tests (including tsc + live Node <-> Zig RPC roundtrip)");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_unit_tests.step);
}
