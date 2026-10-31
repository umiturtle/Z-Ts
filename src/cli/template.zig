//! `M5-02` `zts init` — the scaffolded project template.
//!
//! Everything here is a pure string transformation so the generated files can be asserted in unit
//! tests (`scaffold` never touches the disk; `main.zig` writes the files). The template is written
//! against the *same* pieces the library ships:
//!
//! * `build.zig` drives the shared `M5-01` embedder (`dep.builder.path("src/build_tools/…")`),
//!   exactly like `examples/counter`, so the generated project has no copy of the scanning logic.
//! * `web/index.html` carries an inline `<style>` **and** an inline `<script>` so the very first
//!   build exercises the CSP-hash path (`csp=2` in the embedder's summary line).
//! * `src/main.zig` imports the generated `embedded_frontend` module, so a plain `zts build`
//!   proves the whole front end → binary pipeline works.
//!
//! Zig 0.17 requires a package fingerprint (`build.zig.zon` refuses to load without one) whose high
//! 32 bits are derived from the package name and whose low 32 bits act as a fork discriminator.
//! We cannot compute that hash portably, so the template emits a zero placeholder and
//! [`fingerprintSuggestion`] recovers the value Zig itself prints the first time the project is
//! built.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longest package name accepted by `zts init` (Zig has no hard limit; this keeps paths sane).
pub const max_name_len = 64;

pub const Options = struct {
    /// Package name: `[a-z][a-z0-9_]*`, at most [`max_name_len`] characters.
    name: []const u8,
    /// Path to the Z-Ts checkout that `build.zig.zon` depends on.
    zts_path: []const u8 = "../Z-Ts",
    /// Value written for `.fingerprint`; `0` means "patch it after the first build".
    fingerprint: u64 = 0,
};

pub const File = struct {
    /// POSIX-style relative path of the generated file.
    path: []const u8,
    contents: []const u8,
};

pub const NameError = error{
    EmptyName,
    NameTooLong,
    InvalidNameStart,
    InvalidNameChar,
};

/// Zig package names become `.{ .name = .<name> }`, i.e. an enum literal, so the alphabet is
/// restricted to what an enum literal may contain. Hyphens and dots are rejected rather than
/// escaped with `@""` — a project name that needs quoting breaks every `-Dname=` style tool later.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > max_name_len) return error.NameTooLong;

    switch (name[0]) {
        'a'...'z' => {},
        else => return error.InvalidNameStart,
    }
    for (name[1..]) |ch| {
        switch (ch) {
            'a'...'z', '0'...'9', '_' => {},
            else => return error.InvalidNameChar,
        }
    }
}

/// Derives the default package name from a target directory (`apps/my-app` → `my_app`).
/// Returns `null` when the directory has no usable component (`.`, `/`, `..`).
pub fn defaultName(dir: []const u8) ?[]const u8 {
    var trimmed = dir;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0) return null;
    const base = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| trimmed[slash + 1 ..] else trimmed;
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return null;
    return base;
}

/// `dir` → a name that passes [`validateName`]: lowercase, and every `-`/`.` folded to `_`.
pub fn normalizeName(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    const out = try alloc.alloc(u8, raw.len);
    for (raw, out) |ch, *dest| {
        dest.* = switch (ch) {
            'A'...'Z' => ch + ('a' - 'A'),
            'a'...'z', '0'...'9', '_' => ch,
            else => '_',
        };
    }
    // A name must not start with a digit or an underscore.
    if (out.len > 0 and !(out[0] >= 'a' and out[0] <= 'z')) out[0] = 'a';
    return out;
}

/// Renders every file of the template. The returned slice and all contents live in `alloc`; the
/// order is fixed (and asserted by the tests) so `zts init` is reproducible byte for byte.
pub fn scaffold(alloc: Allocator, options: Options) Allocator.Error![]File {
    const files = try alloc.alloc(File, sources.len);
    for (sources, files) |source, *dest| {
        dest.* = .{
            .path = source.path,
            .contents = try render(alloc, source.body, options),
        };
    }
    return files;
}

/// Replaces the three `{{…}}` placeholders. Written as a manual scan (not `std.fmt`) because the
/// payload is Zig source full of braces — `{{` means something completely different to `std.fmt`.
pub fn render(alloc: Allocator, body: []const u8, options: Options) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, body, open + 2, "}}") orelse break;
        out.writer.writeAll(body[cursor..open]) catch return error.OutOfMemory;
        const token = body[open + 2 .. close];
        if (std.mem.eql(u8, token, "NAME")) {
            out.writer.writeAll(options.name) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, token, "ZTS_PATH")) {
            out.writer.writeAll(options.zts_path) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, token, "FINGERPRINT")) {
            out.writer.print("0x{x:0>16}", .{options.fingerprint}) catch return error.OutOfMemory;
        } else {
            // Unknown tokens are echoed verbatim so a typo shows up in the tests instead of
            // silently deleting a chunk of the template.
            out.writer.writeAll(body[open .. close + 2]) catch return error.OutOfMemory;
        }
        cursor = close + 2;
    }
    out.writer.writeAll(body[cursor..]) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub const fingerprint_error_text = "invalid fingerprint";

/// Recovers the fingerprint Zig suggests when `build.zig.zon` carries a wrong one:
///
/// ```text
/// build.zig.zon:1:2: error: invalid fingerprint: 0x0; if this is a new or forked package,
/// use this value: 0xe244585b08949903
/// ```
///
/// Only the high 32 bits are validated against the package name; the low half is a fork id, so the
/// value Zig prints can be written back verbatim.
pub fn fingerprintSuggestion(text: []const u8) ?u64 {
    const marker = "use this value: ";
    const at = std.mem.indexOf(u8, text, marker) orelse return null;
    if (std.mem.indexOf(u8, text, fingerprint_error_text) == null) return null;

    var rest = text[at + marker.len ..];
    if (rest.len > 0 and rest[0] == '0' and rest.len > 1 and rest[1] == 'x') rest = rest[2..];
    var len: usize = 0;
    while (len < rest.len and std.ascii.isHex(rest[len])) : (len += 1) {}
    if (len == 0) return null;
    return std.fmt.parseInt(u64, rest[0..len], 16) catch null;
}

/// Rewrites the `.fingerprint` line of a generated `build.zig.zon` in place (textually).
pub fn patchFingerprint(alloc: Allocator, zon: []const u8, fingerprint: u64) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var cursor: usize = 0;
    var patched = false;
    while (std.mem.indexOfPos(u8, zon, cursor, ".fingerprint = ")) |at| {
        out.writer.writeAll(zon[cursor..at]) catch return error.OutOfMemory;
        out.writer.print(".fingerprint = 0x{x:0>16},", .{fingerprint}) catch return error.OutOfMemory;
        const line_end = std.mem.indexOfScalarPos(u8, zon, at, '\n') orelse zon.len;
        cursor = line_end;
        patched = true;
        break;
    }
    if (!patched) return alloc.dupe(u8, zon);
    out.writer.writeAll(zon[cursor..]) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// The template itself
// ---------------------------------------------------------------------------

const Source = struct { path: []const u8, body: []const u8 };

const sources = [_]Source{
    .{ .path = ".gitignore", .body = gitignore },
    .{ .path = "README.md", .body = readme },
    .{ .path = "build.zig", .body = build_zig },
    .{ .path = "build.zig.zon", .body = build_zon },
    .{ .path = "src/main.zig", .body = main_zig },
    .{ .path = "web/index.html", .body = index_html },
};

const gitignore =
    \\.zig-cache/
    \\zig-out/
    \\dist/
    \\
;

const readme =
    \\# {{NAME}}
    \\
    \\A [Z-Ts](https://github.com/umiturtle/Z-Ts) desktop app.
    \\
    \\```bash
    \\zts dev            # serve web/ with rebuild-on-change
    \\zts build          # single executable in zig-out/bin/
    \\zts build --target aarch64-macos
    \\```
    \\
    \\The front end in `web/` is embedded into the binary at build time by the shared
    \\`M5-01` embedder (gzip twins + CSP hashes for inline scripts/styles), so `zts build`
    \\produces one self-contained executable with no asset directory next to it.
    \\
;

const build_zig =
    \\//! Generated by `zts init` (M5-02).
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const dep = b.dependency("z_ts", .{ .target = target, .optimize = optimize });
    \\
    \\    // `M5-01`: the front end embedder is shared, so drive it through its source file
    \\    // (a build script cannot `@import` a module that lives in another build root).
    \\    const embed_mod = b.createModule(.{
    \\        .root_source_file = dep.builder.path("src/build_tools/embed_main.zig"),
    \\        .target = b.graph.host,
    \\        .optimize = .debug,
    \\    });
    \\    const embed_exe = b.addExecutable(.{ .name = "{{NAME}}_embed", .root_module = embed_mod });
    \\    const embed_run = b.addRunArtifact(embed_exe);
    \\    embed_run.has_side_effects = true;
    \\    embed_run.addArg("--src");
    \\    embed_run.addDirectoryArg(b.path("web"));
    \\    embed_run.addArg("--out");
    \\    const assets_dir = embed_run.addOutputDirectoryArg("frontend");
    \\
    \\    const frontend = b.createModule(.{
    \\        .root_source_file = assets_dir.path(b, "assets_manifest.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .imports = &.{.{ .name = "zts_web", .module = dep.module("zts_web") }},
    \\    });
    \\
    \\    const app = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .imports = &.{.{ .name = "embedded_frontend", .module = frontend }},
    \\    });
    \\    const exe = b.addExecutable(.{ .name = "{{NAME}}", .root_module = app });
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.addPassthruArgs();
    \\    b.step("run", "Run the app").dependOn(&run_cmd.step);
    \\
    \\    // `zts build --frontend-only` rebuilds just the embedded front end.
    \\    const frontend_step = b.step("frontend", "Re-embed web/ without compiling the app");
    \\    frontend_step.dependOn(&embed_run.step);
    \\}
    \\
;

const build_zon =
    \\.{
    \\    .name = .{{NAME}},
    \\    .version = "0.1.0",
    \\    .fingerprint = {{FINGERPRINT}},
    \\    .minimum_zig_version = "0.17.0",
    \\    .dependencies = .{
    \\        .z_ts = .{ .path = "{{ZTS_PATH}}" },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\        "web",
    \\    },
    \\}
    \\
;

const main_zig =
    \\//! {{NAME}} — generated by `zts init` (M5-02).
    \\//!
    \\//! `embedded_frontend` is produced at build time by the shared embedder, so the asset table
    \\//! below is a compile-time constant: no runtime file IO, no asset directory next to the binary.
    \\const std = @import("std");
    \\const embedded = @import("embedded_frontend");
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    var buffer: [4096]u8 = undefined;
    \\    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    \\
    \\    try stdout.interface.print("{{NAME}}: {d} embedded assets\n", .{embedded.assets.entries.len});
    \\    for (embedded.assets.entries) |entry| {
    \\        try stdout.interface.print("  {s} ({d} bytes)\n", .{ entry.path, entry.bytes.len });
    \\    }
    \\    try stdout.interface.flush();
    \\}
    \\
;

const index_html =
    \\<!doctype html>
    \\<html lang="en">
    \\  <head>
    \\    <meta charset="utf-8" />
    \\    <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\    <title>{{NAME}}</title>
    \\    <style>
    \\      body { font-family: system-ui, sans-serif; margin: 4rem; }
    \\      code { background: #eee; padding: 0.1rem 0.3rem; border-radius: 4px; }
    \\    </style>
    \\  </head>
    \\  <body>
    \\    <h1>{{NAME}}</h1>
    \\    <p>Edit <code>web/index.html</code>, then run <code>zts dev</code>.</p>
    \\    <script>
    \\      // Inline scripts (and the <style> above) are CSP-hashed by the M5-01 embedder.
    \\      console.log("{{NAME}} booted");
    \\    </script>
    \\  </body>
    \\</html>
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validateName accepts the documented alphabet and rejects everything else" {
    for ([_][]const u8{ "app", "demo_app", "a1", "x_9" }) |name| try validateName(name);
    try testing.expectError(error.EmptyName, validateName(""));
    try testing.expectError(error.InvalidNameStart, validateName("Demo"));
    try testing.expectError(error.InvalidNameStart, validateName("1app"));
    try testing.expectError(error.InvalidNameStart, validateName("_app"));
    try testing.expectError(error.InvalidNameChar, validateName("my-app"));
    try testing.expectError(error.InvalidNameChar, validateName("my.app"));
    try testing.expectError(error.InvalidNameChar, validateName("appé"));

    const too_long: [max_name_len + 1]u8 = @splat('a');
    try testing.expectError(error.NameTooLong, validateName(&too_long));
    try validateName(too_long[0..max_name_len]);
}

test "defaultName takes the last directory component and normalizes it" {
    try testing.expectEqualStrings("demo", defaultName("apps/demo").?);
    try testing.expectEqualStrings("demo", defaultName("apps/demo/").?);
    try testing.expectEqualStrings("demo", defaultName("demo").?);
    try testing.expect(defaultName(".") == null);
    try testing.expect(defaultName("./") == null);
    try testing.expect(defaultName("..") == null);
    try testing.expect(defaultName("") == null);
    try testing.expect(defaultName("/") == null);
}

test "normalizeName folds case and separators into a valid package name" {
    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "MyApp", .expected = "myapp" },
        .{ .raw = "my-app", .expected = "my_app" },
        .{ .raw = "1cool", .expected = "acool" },
        .{ .raw = "ok_name", .expected = "ok_name" },
    };
    for (cases) |case| {
        const name = try normalizeName(testing.allocator, case.raw);
        defer testing.allocator.free(name);
        try testing.expectEqualStrings(case.expected, name);
        try validateName(name);
    }
}

test "scaffold is deterministic and every placeholder is substituted" {
    const options: Options = .{ .name = "demo_app", .zts_path = "/src/Z-Ts" };
    const files = try scaffold(testing.allocator, options);
    defer {
        for (files) |file| testing.allocator.free(file.contents);
        testing.allocator.free(files);
    }

    const expected_paths = [_][]const u8{ ".gitignore", "README.md", "build.zig", "build.zig.zon", "src/main.zig", "web/index.html" };
    try testing.expectEqual(expected_paths.len, files.len);
    for (files, expected_paths) |file, expected| try testing.expectEqualStrings(expected, file.path);

    for (files) |file| {
        try testing.expect(std.mem.indexOf(u8, file.contents, "{{") == null);
        try testing.expect(file.contents.len > 0);
    }

    // Spot-check the substitutions that actually build the project.
    const zon = files[3].contents;
    try testing.expect(std.mem.indexOf(u8, zon, ".name = .demo_app,") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".path = \"/src/Z-Ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, zon, ".fingerprint = 0x0000000000000000,") != null);

    const build_zig_source = files[2].contents;
    try testing.expect(std.mem.indexOf(u8, build_zig_source, "embed_main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, build_zig_source, "embedded_frontend") != null);
    try testing.expect(std.mem.indexOf(u8, build_zig_source, ".name = \"demo_app_embed\"") != null);

    try testing.expect(std.mem.indexOf(u8, files[5].contents, "demo_app booted") != null);
}

test "scaffold output is byte-identical across runs" {
    const options: Options = .{ .name = "app" };
    const first = try scaffold(testing.allocator, options);
    const second = try scaffold(testing.allocator, options);
    defer for ([_]@TypeOf(first){ first, second }) |files| {
        for (files) |file| testing.allocator.free(file.contents);
        testing.allocator.free(files);
    };

    for (first, second) |a, b| try testing.expectEqualStrings(a.contents, b.contents);
}

test "fingerprintSuggestion extracts the value Zig prints for a wrong fingerprint" {
    const sample =
        \\build.zig.zon:1:2: error: invalid fingerprint: 0x0; if this is a new or forked package, use this value: 0xe244585b08949903
        \\.{
        \\ ^
        \\
    ;
    try testing.expectEqual(@as(u64, 0xe244585b08949903), fingerprintSuggestion(sample).?);

    // Zig prints the same sentence without the `0x` prefix in some versions.
    try testing.expectEqual(@as(u64, 0xdeadbeef), fingerprintSuggestion("invalid fingerprint: 0x1; use this value: deadbeef\n").?);

    // Unrelated errors must never be mistaken for a fingerprint.
    try testing.expect(fingerprintSuggestion("error: file not found\n") == null);
    try testing.expect(fingerprintSuggestion("invalid fingerprint: 0x0\n") == null);
    try testing.expect(fingerprintSuggestion("invalid fingerprint; use this value: nonsense\n") == null);
}

test "patchFingerprint rewrites only the fingerprint line" {
    const zon = try scaffold(testing.allocator, .{ .name = "app" });
    defer {
        for (zon) |file| testing.allocator.free(file.contents);
        testing.allocator.free(zon);
    }

    const patched = try patchFingerprint(testing.allocator, zon[3].contents, 0xe244585b08949903);
    defer testing.allocator.free(patched);

    try testing.expect(std.mem.indexOf(u8, patched, ".fingerprint = 0xe244585b08949903,") != null);
    try testing.expect(std.mem.indexOf(u8, patched, "0x0000000000000000") == null);
    // Everything else is untouched.
    try testing.expect(std.mem.indexOf(u8, patched, ".name = .app,") != null);
    try testing.expectEqual(zon[3].contents.len, patched.len);
}

test "patchFingerprint leaves a zon without a fingerprint line alone" {
    const zon = "pub const x = 1;\n";
    const patched = try patchFingerprint(testing.allocator, zon, 42);
    defer testing.allocator.free(patched);
    try testing.expectEqualStrings(zon, patched);
}

test "render echoes unknown tokens instead of dropping them" {
    const rendered = try render(testing.allocator, "a {{nope}} b {{NAME}}", .{ .name = "app" });
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("a {{nope}} b app", rendered);
}
