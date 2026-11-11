//! Smallest possible project that consumes ziggurats as a *library* rather than through `zts`.
//!
//! `scripts/verify-library-consumer.sh` swaps the `.path` dependency below for a `.url` + `.hash`
//! pointing at the release archive, then builds and runs this with a cold global cache. If a
//! module stops being exported from `build.zig`, this fails before a release is published.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zts = b.dependency("z_ts", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "library-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zts_foundation", .module = zts.module("zts_foundation") },
                .{ .name = "zts_core", .module = zts.module("zts_core") },
                .{ .name = "zts_rpc", .module = zts.module("zts_rpc") },
                .{ .name = "zts_web", .module = zts.module("zts_web") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const verify = b.step("verify", "Build and run the external library consumer");
    verify.dependOn(&run.step);
}
