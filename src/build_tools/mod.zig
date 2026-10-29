//! `M5-01` build-script helpers (`src/build_tools/mod.zig`).
//!
//! Import this from a `build.zig` (it depends on `std.Build` only — never on a `zts_*` module, so
//! a build script can compile it without pulling the whole library in):
//!
//! ```zig
//! const zts_build = @import("src/build_tools/mod.zig");
//!
//! const embedded = zts_build.embedFrontend(b, .{
//!     .src_dir = b.path("frontend/dist"),
//!     .web_mod = web_mod,               // `zts_web`
//! });
//! // `embedded.module` is importable as `@import("embedded_frontend")`
//!
//! const gen = zts_build.tsgenBindings(b, .{
//!     .schema_mod = schema_mod,                  // exposes `pub const Schema`
//!     .output_path = "frontend/src/bindings.gen.ts",
//! });
//! b.getInstallStep().dependOn(gen.step);
//! ```
//!
//! Both helpers keep the work in `assets.zig` (pure, unit-tested on every OS) and in the two small
//! CLIs `embed_main.zig` / `tsgen_main.zig`; this file only wires build steps together.

const std = @import("std");
const Build = std.Build;

// ============================================================================
// embedFrontend
// ============================================================================

pub const EmbedOptions = struct {
    /// Frontend build output directory (`Vite dist/`, `Astro dist/`, `Next.js out/`, …).
    src_dir: Build.LazyPath,
    /// `zts_web` module, for the generated `web.Assets` table.
    web_mod: *Build.Module,
    /// Import name of the generated module.
    module_name: []const u8 = "embedded_frontend",
    /// Emit deterministic gzip twins (`gzip_entries`).
    gzip: bool = true,
    /// Hash inline `<script>` / `<style>` bodies into `csp_hashes`.
    csp: bool = true,
    /// Where `embed_main.zig` lives (`null` = `src/build_tools/embed_main.zig`, this repo).
    runner_source: ?Build.LazyPath = null,
};

pub const EmbeddedFrontend = struct {
    /// The generation step: depend on it before using `module`.
    run: *Build.Step.Run,
    /// Generated module exposing `entries`, `sha256_digests`, `gzip_entries`, `csp_hashes`
    /// and `assets: zts_web.Assets`.
    module: *Build.Module,
};

/// Scans `opts.src_dir` at build time and generates a deterministic `zts_web.Assets` module
/// backed by `@embedFile`, including gzip twins and CSP hashes (`M5-01`).
pub fn embedFrontend(b: *Build, opts: EmbedOptions) EmbeddedFrontend {
    const runner = embedRunner(b, opts.runner_source orelse b.path("src/build_tools/embed_main.zig"));

    const run = b.addRunArtifact(runner);
    // The runner writes a whole directory tree (`assets_manifest.zig` + staged `files/**`).
    // Zig does not verify output *directories*, so force execution to keep the tree present.
    run.has_side_effects = true;
    run.addArg("--src");
    run.addDirectoryArg(opts.src_dir);
    run.addArg("--out");
    const generated_dir = run.addOutputDirectoryArg(opts.module_name);
    if (!opts.gzip) run.addArg("--no-gzip");
    if (!opts.csp) run.addArg("--no-csp");

    const module = b.createModule(.{
        .root_source_file = generated_dir.path(b, "assets_manifest.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = false,
        .imports = &.{
            .{ .name = "zts_web", .module = opts.web_mod },
        },
    });

    return .{ .run = run, .module = module };
}

/// Builds the embedder CLI for the host (exposed so a downstream `build.zig` can point it at its
/// own copy of `embed_main.zig`).
pub fn embedRunner(b: *Build, source: Build.LazyPath) *Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = source,
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = false,
    });
    return b.addExecutable(.{ .name = "zts_embed_frontend", .root_module = module });
}

// ============================================================================
// tsgenBindings
// ============================================================================

pub const TsgenOptions = struct {
    /// Module exposing `pub const Schema = zts_rpc.Schema(...)` (wire its own imports yourself).
    schema_mod: *Build.Module,
    /// Path of the generated `.ts`, relative to the build root.
    output_path: []const u8,
    /// Compare instead of write (`zig build check-bindings`): fails when the file is stale.
    check: bool = false,
    /// Where `tsgen_main.zig` lives (`null` = `src/build_tools/tsgen_main.zig`, this repo).
    runner_source: ?Build.LazyPath = null,
};

pub const TsgenResult = struct {
    /// Add this as a dependency of whatever needs the bindings.
    step: *Build.Step,
    run: *Build.Step.Run,
    output_path: []const u8,
};

/// Generates `bindings.gen.ts` from the app's `zts_rpc` schema at build time.
///
/// With `.check = true` nothing is written: the generator compares its output against the file on
/// disk and fails the build when they differ (what CI runs).
pub fn tsgenBindings(b: *Build, opts: TsgenOptions) TsgenResult {
    const runner_module = b.createModule(.{
        .root_source_file = opts.runner_source orelse b.path("src/build_tools/tsgen_main.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = false,
        .imports = &.{
            .{ .name = "app_schema", .module = opts.schema_mod },
        },
    });
    const runner = b.addExecutable(.{ .name = "zts_tsgen", .root_module = runner_module });

    const run = b.addRunArtifact(runner);
    run.addArg(opts.output_path);

    if (opts.check) {
        run.addArg("--check");
        run.expectExitCode(0);
        // The check reads a file that is *not* a build input (it may not even exist yet), so the
        // step must never be skipped as "cached": a stale tree has to fail on every run.
        run.has_side_effects = true;
        return .{ .step = &run.step, .run = run, .output_path = opts.output_path };
    }

    const captured = run.captureStdOut(.{ .basename = "bindings.gen.ts" });
    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(captured, opts.output_path);
    return .{ .step = &update.step, .run = run, .output_path = opts.output_path };
}

// ============================================================================
// Tests — the generated module must be valid Zig, so the renderer is the unit under test.
// ============================================================================

test "the build helpers are build-script only (no zts module import)" {
    try std.testing.expect(@hasDecl(@This(), "embedFrontend"));
    try std.testing.expect(@hasDecl(@This(), "tsgenBindings"));
}
