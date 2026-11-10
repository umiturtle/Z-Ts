//! `zts migrate` — Tauri v2 `src-tauri/` → ziggurats project planner (`src/cli/migrate.zig`).
//!
//! Pure functions only, like the rest of `src/cli/`: no `zts_*` import, no filesystem access, no
//! child processes. `main.zig` reads the existing project into a `Source`, calls `plan()`, and
//! writes the returned files. That keeps the whole migration deterministic and unit-testable.
//!
//! What it copies:
//! * `tauri.conf.json` → `src-tauri/tauri.conf.json` (so `zts_tauri.config_import` can read it)
//! * `build.frontendDist/**` → `web/**` (the embedded asset tree)
//! * `capabilities/*.json` → `capabilities/*.json` (the ACL)
//! * `icons/**` → `icons/**`
//! * a fresh `zts init` template (`build.zig`, `build.zig.zon`, `src/main.zig`, …)
//! * a bilingual `MIGRATION.md` with detected values and the manual steps that remain
//!
//! What it deliberately does NOT do: translate Rust `#[tauri::command]` functions. There is no
//! safe automatic Rust → Zig translation; the report lists them instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const template = @import("template.zig");

pub const ParseError = error{ InvalidJson, OutOfMemory, UnsafePath, WriteFailed };

/// The subset of `tauri.conf.json` a migration can act on. Everything else stays in the copied
/// `src-tauri/tauri.conf.json`; `zts_tauri.config_import` reads it at runtime and reports its own
/// diagnostics for fields ziggurats does not apply.
pub const Config = struct {
    /// `productName` → default package name.
    product_name: ?[]const u8 = null,
    /// `version` → `build.zig.zon` version (informational; Zig wants a semantic version).
    version: ?[]const u8 = null,
    /// `identifier` → reverse-DNS bundle id.
    identifier: ?[]const u8 = null,
    /// `build.frontendDist`, relative to `src-tauri/`.
    frontend_dist: []const u8 = "../dist",
    /// `build.devUrl` (a dev server, not used by `zts dev`).
    dev_url: ?[]const u8 = null,
    /// `build.beforeDevCommand` / `beforeBuildCommand` (kept as-is in the source config).
    before_dev_command: ?[]const u8 = null,
    before_build_command: ?[]const u8 = null,
    /// Number of `app.windows` entries.
    window_count: usize = 0,
    /// Geometry/labels of the first window, so `MIGRATION.md` can spell out what to port.
    first_window_label: ?[]const u8 = null,
    first_window_title: ?[]const u8 = null,
    first_window_width: ?f64 = null,
    first_window_height: ?f64 = null,
    first_window_url: ?[]const u8 = null,
    /// `security.pattern.use == "isolation"`.
    has_isolation_pattern: bool = false,
    /// `security.assetProtocol.enable`.
    asset_protocol_enabled: bool = false,
    /// Whether a CSP was declared.
    csp_present: bool = false,
    /// Inline capability references from `app.security.capabilities`.
    capability_references: []const []const u8 = &.{},
    /// `bundle.targets`.
    bundle_targets: []const []const u8 = &.{},
    /// Top-level keys of `plugins` (ziggurats configures plugins in Zig, not JSON).
    plugin_names: []const []const u8 = &.{},
};

/// One file read from the source project. `path` is POSIX-style and relative to its category root.
pub const SourceFile = struct {
    path: []const u8,
    contents: []const u8,
};

/// Everything `plan()` needs. `main.zig` fills it by walking the source directory.
pub const Source = struct {
    /// Raw `tauri.conf.json` bytes.
    config_json: []const u8,
    /// Files under `build.frontendDist`.
    frontend_files: []const SourceFile = &.{},
    /// Files under `capabilities/`.
    capability_files: []const SourceFile = &.{},
    /// Files under `icons/`.
    icon_files: []const SourceFile = &.{},
    /// Relative paths of `src/*.rs` files (not translated).
    rust_files: []const []const u8 = &.{},
};

pub const PlanOptions = struct {
    /// Validated Zig package name.
    name: []const u8,
    /// Path/URL information for `build.zig.zon`.
    zts_path: []const u8 = "../Z-Ts",
    zts_url: ?[]const u8 = null,
    zts_hash: ?[]const u8 = null,
    /// Source directory (for the report).
    src: []const u8 = "src-tauri",
    /// Output directory (for the report).
    out_dir: []const u8 = ".",
};

pub const Plan = struct {
    /// Files to write, in deterministic order.
    files: []const template.File,
    /// Human-readable findings, printed by the CLI and embedded in `MIGRATION.md`.
    warnings: []const []const u8,
    /// Parsed source config, for the CLI summary.
    config: Config,
    /// Number of files copied from the old frontend / capabilities / icons.
    copied_files: usize,
};

const Json = std.json.Value;

fn field(value: Json, keys: []const []const u8) ?Json {
    if (value != .object) return null;
    for (keys) |key| {
        if (value.object.get(key)) |v| {
            if (v == .null) return null;
            return v;
        }
    }
    return null;
}

fn asString(value: Json) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn asNumber(value: Json) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |n| std.fmt.parseFloat(f64, n) catch null,
        else => null,
    };
}

fn asBool(value: Json) ?bool {
    return if (value == .bool) value.bool else null;
}

fn stringField(allocator: Allocator, root: Json, keys: []const []const u8) ParseError!?[]const u8 {
    const v = field(root, keys) orelse return null;
    const s = asString(v) orelse return null;
    return try allocator.dupe(u8, s);
}

fn stringArray(allocator: Allocator, value: Json) ParseError![]const []const u8 {
    switch (value) {
        .array => |arr| {
            const out = try allocator.alloc([]const u8, arr.items.len);
            for (arr.items, out) |item, *slot| {
                slot.* = try allocator.dupe(u8, asString(item) orelse "");
            }
            return out;
        },
        .string => |s| {
            const out = try allocator.alloc([]const u8, 1);
            out[0] = try allocator.dupe(u8, s);
            return out;
        },
        else => return &.{},
    }
}

/// Parses the subset of `tauri.conf.json` a migration needs. Unknown keys are ignored: the file is
/// copied verbatim and `zts_tauri.config_import` reports anything it cannot apply.
pub fn parseConfig(allocator: Allocator, json_text: []const u8) ParseError!Config {
    const root = std.json.parseFromSliceLeaky(Json, allocator, json_text, .{}) catch
        return error.InvalidJson;
    if (root != .object) return error.InvalidJson;

    var cfg: Config = .{};
    cfg.product_name = try stringField(allocator, root, &.{"productName"});
    cfg.version = try stringField(allocator, root, &.{"version"});
    cfg.identifier = try stringField(allocator, root, &.{"identifier"});

    if (field(root, &.{"build"})) |build| {
        cfg.frontend_dist = try stringField(allocator, build, &.{ "frontendDist", "distDir" }) orelse "../dist";
        cfg.dev_url = try stringField(allocator, build, &.{"devUrl"});
        cfg.before_dev_command = try stringField(allocator, build, &.{"beforeDevCommand"});
        cfg.before_build_command = try stringField(allocator, build, &.{"beforeBuildCommand"});
    }

    if (field(root, &.{"app"})) |app| {
        if (field(app, &.{"windows"})) |windows| {
            if (windows == .array) {
                cfg.window_count = windows.array.items.len;
                if (windows.array.items.len > 0) {
                    const w = windows.array.items[0];
                    cfg.first_window_label = try stringField(allocator, w, &.{"label"});
                    cfg.first_window_title = try stringField(allocator, w, &.{"title"});
                    cfg.first_window_width = if (field(w, &.{"width"})) |v| asNumber(v) else null;
                    cfg.first_window_height = if (field(w, &.{"height"})) |v| asNumber(v) else null;
                    if (field(w, &.{"url"})) |u| {
                        cfg.first_window_url = if (asString(u)) |s| try allocator.dupe(u8, s) else null;
                    }
                }
            }
        }
        if (field(app, &.{"security"})) |security| {
            cfg.csp_present = field(security, &.{ "csp", "devCsp" }) != null;
            if (field(security, &.{"pattern"})) |pattern| {
                switch (pattern) {
                    .string => |s| cfg.has_isolation_pattern = std.mem.eql(u8, s, "isolation"),
                    .object => |obj| {
                        if (obj.get("use")) |use| {
                            if (asString(use)) |s| cfg.has_isolation_pattern = std.mem.eql(u8, s, "isolation");
                        }
                    },
                    else => {},
                }
            }
            if (field(security, &.{"assetProtocol"})) |ap| {
                cfg.asset_protocol_enabled = asBool(field(ap, &.{"enable"}) orelse .null) orelse false;
            }
            if (field(security, &.{"capabilities"})) |caps| {
                if (caps == .array) {
                    var names: std.ArrayList([]const u8) = .empty;
                    for (caps.array.items) |entry| {
                        if (asString(entry)) |s| try names.append(allocator, try allocator.dupe(u8, s));
                    }
                    cfg.capability_references = try names.toOwnedSlice(allocator);
                }
            }
        }
    }

    if (field(root, &.{"bundle"})) |bundle| {
        if (field(bundle, &.{"targets"})) |targets| cfg.bundle_targets = try stringArray(allocator, targets);
    }
    if (field(root, &.{"plugins"})) |plugins| {
        if (plugins == .object) {
            var names: std.ArrayList([]const u8) = .empty;
            var it = plugins.object.iterator();
            while (it.next()) |entry| {
                try names.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            }
            cfg.plugin_names = try names.toOwnedSlice(allocator);
        }
    }
    return cfg;
}

/// Rejects absolute paths, `..`, empty segments, NUL bytes and drive letters. `Dir.walk` uses `\`
/// on Windows, so both separators are treated as path separators here.
pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and path[1] == ':') return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    var segments: usize = 0;
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return false;
        segments += 1;
    }
    return segments > 0;
}

/// Normalises Windows `\` separators to `/` for the generated POSIX-style file list.
pub fn normalizePath(allocator: Allocator, path: []const u8) ParseError![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Default package name: `productName` → `template.normalizeName`, then the source directory name.
pub fn packageNameFrom(allocator: Allocator, cfg: Config, src: []const u8) ParseError![]const u8 {
    const raw = cfg.product_name orelse template.defaultName(src) orelse "app";
    return try template.normalizeName(allocator, raw);
}

/// Default output directory: sibling of the source project's root, `<name>-zts`.
pub fn defaultOutDir(allocator: Allocator, src: []const u8, name: []const u8) ParseError![]const u8 {
    // `src` is the `src-tauri/` directory; the Tauri project root is its parent, and the new
    // ziggurats project is a *sibling* of that root so the original Rust tree stays untouched.
    const project_root = std.fs.path.dirname(src) orelse "";
    const parent = std.fs.path.dirname(project_root) orelse "";
    const leaf = try std.fmt.allocPrint(allocator, "{s}-zts", .{name});
    return if (parent.len == 0) leaf else std.fs.path.join(allocator, &.{ parent, leaf });
}

fn lessThan(_: void, a: SourceFile, b: SourceFile) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

/// Replaces a template file in place when the migrated project ships its own version of that path
/// (`web/index.html` is the common case). The last-write-wins behaviour of the CLI then holds
/// without emitting duplicate paths.
fn upsert(files: *std.ArrayList(template.File), allocator: Allocator, path: []const u8, contents: []const u8) ParseError!void {
    for (files.items) |*existing| {
        if (std.mem.eql(u8, existing.path, path)) {
            existing.contents = contents;
            return;
        }
    }
    try files.append(allocator, .{ .path = path, .contents = contents });
}

fn appendWarnings(allocator: Allocator, list: *std.ArrayList([]const u8), cfg: Config, source: Source) ParseError!void {
    try list.append(allocator, try std.fmt.allocPrint(allocator, "Rust commands are NOT translated. Port {d} `src/*.rs` file(s) to a `zts_rpc.Schema` by hand.", .{source.rust_files.len}));
    if (source.rust_files.len > 0) {
        const joined = try std.mem.join(allocator, ", ", source.rust_files);
        try list.append(allocator, try std.fmt.allocPrint(allocator, "Rust sources found: {s}.", .{joined}));
    }
    if (cfg.window_count > 1) {
        try list.append(allocator, try std.fmt.allocPrint(allocator, "`app.windows` declares {d} windows; the generated `src/main.zig` opens the first one. Add the rest with `DesktopRuntime.openWindow()`.", .{cfg.window_count}));
    }
    if (cfg.has_isolation_pattern) {
        try list.append(allocator, "`security.pattern: isolation` is supported by ziggurats (AES-256-GCM). Check `options.keyHex` and `options.dir` before shipping.");
    }
    if (cfg.asset_protocol_enabled) {
        try list.append(allocator, "`security.assetProtocol` is copied; set `ProtocolConfig.asset_allow_globs` to the same globs at runtime.");
    }
    if (cfg.csp_present) {
        try list.append(allocator, "`security.csp` is preserved in `src-tauri/tauri.conf.json`; pass it as `ProtocolConfig.csp`.");
    }
    if (cfg.dev_url != null) {
        try list.append(allocator, "`build.devUrl` is not used by `zts dev`; the generated project serves `web/` directly.");
    }
    if (cfg.bundle_targets.len > 0) {
        try list.append(allocator, "`bundle.targets` is informational only; use `zts package --format <list>` instead.");
    }
    if (cfg.plugin_names.len > 0) {
        try list.append(allocator, "`plugins.*` is informational only; ziggurats configures plugins in Zig code, not JSON.");
    }
    if (source.capability_files.len == 0) {
        try list.append(allocator, "No `capabilities/*.json` were found. The ACL is deny-by-default; add a capability before calling IPC.");
    }
    if (source.frontend_files.len == 0) {
        try list.append(allocator, "No `frontendDist` files were found; the template's `web/index.html` is kept.");
    }
    if (cfg.capability_references.len > 0) {
        try list.append(allocator, try std.fmt.allocPrint(allocator, "`app.security.capabilities` references {d} identifier(s); make sure the copied JSON files use the same identifiers.", .{cfg.capability_references.len}));
    }
}

/// Renders the bilingual `MIGRATION.md` that ships with the generated project.
pub fn report(
    allocator: Allocator,
    cfg: Config,
    options: PlanOptions,
    source: Source,
    warnings: []const []const u8,
    file_count: usize,
) ParseError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    {
        try w.print("# {s} — Tauri v2 → ziggurats 移行レポート\n\n", .{options.name});
        try w.print("生成元: `{s}`  \n生成先: `{s}`  \n生成ファイル数: {d}\n\n", .{ options.src, options.out_dir, file_count });
        try w.writeAll("## 検出した設定\n\n| 項目 | 値 |\n|---|---|\n");
        try w.print("| productName | `{s}` |\n", .{cfg.product_name orelse "(なし)"});
        try w.print("| version | `{s}` |\n", .{cfg.version orelse "(なし)"});
        try w.print("| identifier | `{s}` |\n", .{cfg.identifier orelse "(なし)"});
        try w.print("| frontendDist | `{s}` |\n", .{cfg.frontend_dist});
        try w.print("| app.windows | {d} |\n", .{cfg.window_count});
        try w.print("| 最初のウィンドウ | `{s}` / `{s}` / {d}×{d} |\n", .{
            cfg.first_window_label orelse "main",
            cfg.first_window_title orelse cfg.product_name orelse "app",
            @as(i64, @intFromFloat(cfg.first_window_width orelse 800)),
            @as(i64, @intFromFloat(cfg.first_window_height orelse 600)),
        });
        try w.print("| isolation pattern | {s} |\n", .{if (cfg.has_isolation_pattern) "yes" else "no"});
        try w.print("| コピーしたファイル | frontend {d} / capabilities {d} / icons {d} |\n\n", .{
            source.frontend_files.len, source.capability_files.len, source.icon_files.len,
        });

        try w.writeAll("## 自動で移行したもの\n\n");
        try w.writeAll("- `tauri.conf.json` → `src-tauri/tauri.conf.json`（`zts_tauri.config_import` がそのまま読む）\n");
        try w.writeAll("- `frontendDist/**` → `web/**`（`embedFrontend` がバイナリに埋め込む）\n");
        try w.writeAll("- `capabilities/*.json` → `capabilities/*.json`（ACL は既定拒否）\n");
        try w.writeAll("- `icons/**` → `icons/**`\n");
        try w.writeAll("- `zts init` と同じ `build.zig` / `build.zig.zon` / `src/main.zig` / `web/`\n\n");

        try w.writeAll("## 手作業で残ること\n\n");
        for (warnings) |warning| try w.print("- {s}\n", .{warning});
        try w.writeAll("\n```bash\ncd ");
        try w.writeAll(options.out_dir);
        try w.writeAll("\nzts dev      # まずフロントエンドが表示されるか確認\n");
        try w.writeAll("zts build    # 単一実行ファイルを作る\n```\n\n");

        try w.writeAll("---\n\n# Migration report (English)\n\n");
        try w.print("Generated **{d} files** from `{s}` into `{s}`.\n\n", .{ file_count, options.src, options.out_dir });
        try w.writeAll("Automatically carried over: `tauri.conf.json` (verbatim, under `src-tauri/`), the frontend\n");
        try w.writeAll("`frontendDist/**` into `web/**`, `capabilities/*.json`, `icons/**`, plus a fresh `zts init`\n");
        try w.writeAll("scaffold. The Rust sources are **never modified or translated**.\n\n");
        try w.writeAll("Remaining manual work:\n\n");
        for (warnings) |warning| try w.print("- {s}\n", .{warning});
        try w.writeAll("\nDetected config:\n\n| Field | Value |\n|---|---|\n");
        try w.print("| productName | `{s}` |\n", .{cfg.product_name orelse "(none)"});
        try w.print("| version | `{s}` |\n", .{cfg.version orelse "(none)"});
        try w.print("| identifier | `{s}` |\n", .{cfg.identifier orelse "(none)"});
        try w.print("| frontendDist | `{s}` |\n", .{cfg.frontend_dist});
        try w.print("| app.windows | {d} |\n", .{cfg.window_count});
        try w.print("| isolation pattern | {s} |\n", .{if (cfg.has_isolation_pattern) "yes" else "no"});
        try w.print("| copied files | frontend {d} / capabilities {d} / icons {d} |\n", .{
            source.frontend_files.len, source.capability_files.len, source.icon_files.len,
        });
    }
    return try aw.toOwnedSlice();
}

/// Builds the complete, deterministic file list for `zts migrate`.
pub fn plan(allocator: Allocator, source: Source, options: PlanOptions) ParseError!Plan {
    const cfg = try parseConfig(allocator, source.config_json);
    var files: std.ArrayList(template.File) = .empty;

    try files.appendSlice(allocator, try template.scaffold(allocator, .{
        .name = options.name,
        .zts_path = options.zts_path,
        .zts_url = options.zts_url,
        .zts_hash = options.zts_hash,
    }));

    // Original config, so `zts_tauri.config_import.load(allocator, io, "src-tauri")` keeps working.
    try files.append(allocator, .{ .path = "src-tauri/tauri.conf.json", .contents = source.config_json });

    var copied: usize = 0;
    for (source.frontend_files) |file| {
        if (!isSafeRelativePath(file.path)) return error.UnsafePath;
        const path = try normalizePath(allocator, file.path);
        try upsert(&files, allocator, try std.fmt.allocPrint(allocator, "web/{s}", .{path}), file.contents);
        copied += 1;
    }
    for (source.capability_files) |file| {
        if (!isSafeRelativePath(file.path)) return error.UnsafePath;
        const path = try normalizePath(allocator, file.path);
        try upsert(&files, allocator, try std.fmt.allocPrint(allocator, "capabilities/{s}", .{basename(path)}), file.contents);
        copied += 1;
    }
    for (source.icon_files) |file| {
        if (!isSafeRelativePath(file.path)) return error.UnsafePath;
        const path = try normalizePath(allocator, file.path);
        try upsert(&files, allocator, try std.fmt.allocPrint(allocator, "icons/{s}", .{path}), file.contents);
        copied += 1;
    }

    var warnings: std.ArrayList([]const u8) = .empty;
    try appendWarnings(allocator, &warnings, cfg, source);
    const warning_slice = try warnings.toOwnedSlice(allocator);

    try files.append(allocator, .{
        .path = "MIGRATION.md",
        .contents = try report(allocator, cfg, options, source, warning_slice, files.items.len + 1),
    });

    return .{
        .files = try files.toOwnedSlice(allocator),
        .warnings = warning_slice,
        .config = cfg,
        .copied_files = copied,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const sample_config =
    \\{
    \\  "$schema": "https://schema.tauri.app/config/2",
    \\  "productName": "Legacy Notes",
    \\  "version": "1.4.2",
    \\  "identifier": "com.example.legacy",
    \\  "build": {
    \\    "frontendDist": "../dist",
    \\    "devUrl": "http://localhost:1420",
    \\    "beforeDevCommand": "npm run dev"
    \\  },
    \\  "app": {
    \\    "windows": [
    \\      { "label": "main", "title": "Legacy Notes", "width": 1024, "height": 768 },
    \\      { "label": "settings", "width": 640, "height": 480 }
    \\    ],
    \\    "security": {
    \\      "csp": "default-src 'self'",
    \\      "pattern": { "use": "isolation", "options": { "dir": "../isolation" } },
    \\      "assetProtocol": { "enable": true, "scope": ["$APPDATA/**"] },
    \\      "capabilities": ["main-capability"]
    \\    }
    \\  },
    \\  "bundle": { "active": true, "targets": ["deb", "nsis"] },
    \\  "plugins": { "updater": {}, "shell": {} }
    \\}
;

test "P0-5: parseConfig reads every field a migration acts on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseConfig(arena.allocator(), sample_config);
    try testing.expectEqualStrings("Legacy Notes", cfg.product_name.?);
    try testing.expectEqualStrings("1.4.2", cfg.version.?);
    try testing.expectEqualStrings("com.example.legacy", cfg.identifier.?);
    try testing.expectEqualStrings("../dist", cfg.frontend_dist);
    try testing.expectEqualStrings("http://localhost:1420", cfg.dev_url.?);
    try testing.expectEqual(@as(usize, 2), cfg.window_count);
    try testing.expectEqualStrings("main", cfg.first_window_label.?);
    try testing.expectEqual(@as(f64, 1024), cfg.first_window_width.?);
    try testing.expect(cfg.has_isolation_pattern);
    try testing.expect(cfg.asset_protocol_enabled);
    try testing.expect(cfg.csp_present);
    try testing.expectEqual(@as(usize, 1), cfg.capability_references.len);
    try testing.expectEqual(@as(usize, 2), cfg.bundle_targets.len);
    try testing.expectEqual(@as(usize, 2), cfg.plugin_names.len);
}

test "P0-5: parseConfig tolerates a minimal config and rejects broken JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseConfig(arena.allocator(), "{\"productName\":\"x\"}");
    try testing.expectEqualStrings("x", cfg.product_name.?);
    try testing.expectEqualStrings("../dist", cfg.frontend_dist);
    try testing.expectEqual(@as(usize, 0), cfg.window_count);
    try testing.expect(!cfg.has_isolation_pattern);
    try testing.expectError(error.InvalidJson, parseConfig(arena.allocator(), "not json"));
    try testing.expectError(error.InvalidJson, parseConfig(arena.allocator(), "[]"));
}

test "P0-5: path safety, name derivation and default output directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(isSafeRelativePath("index.html"));
    try testing.expect(isSafeRelativePath("assets\\app.js"));
    try testing.expect(isSafeRelativePath("nested/deep/logo.svg"));
    try testing.expect(!isSafeRelativePath(""));
    try testing.expect(!isSafeRelativePath("/etc/passwd"));
    try testing.expect(!isSafeRelativePath("../secret"));
    try testing.expect(!isSafeRelativePath("a/../b"));
    try testing.expect(!isSafeRelativePath("C:\\Windows"));
    try testing.expect(!isSafeRelativePath("a\x00b"));
    try testing.expectEqualStrings("assets/app.js", try normalizePath(a, "assets\\app.js"));

    const cfg = try parseConfig(a, sample_config);
    try testing.expectEqualStrings("legacy_notes", try packageNameFrom(a, cfg, "src-tauri"));
    const minimal = try parseConfig(a, "{}");
    try testing.expectEqualStrings("legacy_app", try packageNameFrom(a, minimal, "Legacy-App"));
    try testing.expectEqualStrings("legacy_app-zts", try defaultOutDir(a, "Legacy-App", "legacy_app"));
    try testing.expectEqualStrings("projects/legacy_app-zts", try defaultOutDir(a, "projects/legacy/src-tauri", "legacy_app"));
}

test "P0-5: plan is deterministic, copies the frontend and reports the manual work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = Source{
        .config_json = sample_config,
        .frontend_files = &.{
            .{ .path = "index.html", .contents = "<h1>legacy</h1>" },
            .{ .path = "assets\\app.js", .contents = "console.log(1)" },
        },
        .capability_files = &.{.{ .path = "main-capability.json", .contents = "{\"identifier\":\"main-capability\"}" }},
        .icon_files = &.{.{ .path = "icon.png", .contents = "PNG" }},
        .rust_files = &.{ "src/lib.rs", "src/main.rs" },
    };
    const options = PlanOptions{ .name = "legacy_notes", .src = "src-tauri", .out_dir = "legacy_notes-zts" };

    const first = try plan(a, source, options);
    const second = try plan(a, source, options);
    try testing.expectEqual(first.files.len, second.files.len);
    for (first.files, second.files) |l, r| {
        try testing.expectEqualStrings(l.path, r.path);
        try testing.expectEqualStrings(l.contents, r.contents);
    }
    try testing.expectEqual(@as(usize, 4), first.copied_files);
    try testing.expect(first.warnings.len >= 8);

    var saw_index = false;
    var saw_conf = false;
    var saw_report = false;
    var saw_cap = false;
    for (first.files) |f| {
        if (std.mem.eql(u8, f.path, "web/index.html")) {
            saw_index = true;
            try testing.expectEqualStrings("<h1>legacy</h1>", f.contents);
        }
        if (std.mem.eql(u8, f.path, "web/assets/app.js")) try testing.expectEqualStrings("console.log(1)", f.contents);
        if (std.mem.eql(u8, f.path, "src-tauri/tauri.conf.json")) saw_conf = true;
        if (std.mem.eql(u8, f.path, "capabilities/main-capability.json")) saw_cap = true;
        if (std.mem.eql(u8, f.path, "MIGRATION.md")) {
            saw_report = true;
            try testing.expect(std.mem.indexOf(u8, f.contents, "移行レポート") != null);
            try testing.expect(std.mem.indexOf(u8, f.contents, "Migration report (English)") != null);
            try testing.expect(std.mem.indexOf(u8, f.contents, "src/lib.rs") != null);
            try testing.expect(std.mem.indexOf(u8, f.contents, "app.windows") != null);
        }
    }
    try testing.expect(saw_index and saw_conf and saw_report and saw_cap);

    // Unsafe frontend paths are refused rather than writing outside `web/`.
    const evil = Source{ .config_json = "{}", .frontend_files = &.{.{ .path = "../outside.txt", .contents = "x" }} };
    try testing.expectError(error.UnsafePath, plan(a, evil, .{ .name = "app" }));
}
