//! The framework catalog behind the branched tutorials (`src/docsite/frameworks.zig`).
//!
//! `frameworks.json` is the **single source of truth** for the nine committed examples under
//! `examples/frameworks/`. Three consumers read it, so a new library cannot be added to one place
//! and forgotten in the others:
//!
//!  * this module — expands `<!-- framework-picker -->` into the bilingual chooser table;
//!  * `scripts/gen-framework-tutorials.py` — writes the nine per-library tutorial variants;
//!  * `scripts/check-docs.py` (rule 15) — verifies catalog ↔ example directory ↔ tutorial ↔
//!    embedded source snippet stay byte-for-byte consistent.
//!
//! The picker is emitted as **Markdown**, not raw HTML: the renderer escapes `<`, and a plain
//! table keeps working with JavaScript disabled. `assets/site.js` progressively enhances that
//! table into a `<select>`; the labels come from the same links, so JavaScript never owns a second
//! copy of the list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const i18n = @import("i18n.zig");

/// One committed example, plus the two localised sentences the tutorial pages need.
pub const Framework = struct {
    /// Directory name under `examples/frameworks/` and suffix of `counter-<id>.md`.
    id: []const u8,
    /// Reader-facing name (`React`, `Next.js`, …).
    label: []const u8,
    /// Version shown in the demo badge; documentation-only, never parsed as a version.
    version: []const u8,
    /// The framework's build command (`vite build`, `next build`, …).
    build: []const u8,
    /// Build output directory relative to the example.
    dist: []const u8,
    /// Repository path of the component that holds the counter.
    source: []const u8,
    note_ja: []const u8,
    note_en: []const u8,
    state_ja: []const u8,
    state_en: []const u8,

    pub fn note(self: Framework, lang: i18n.Lang) []const u8 {
        return if (lang == .ja) self.note_ja else self.note_en;
    }

    pub fn state(self: Framework, lang: i18n.Lang) []const u8 {
        return if (lang == .ja) self.state_ja else self.state_en;
    }

    /// Relative Markdown link to this library's tutorial from any page in `tutorials/`.
    pub fn tutorialHref(self: Framework, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "counter-{s}.md", .{self.id});
    }

    /// Live demo published by `zig build docs` next to the documentation.
    pub fn demoUrl(self: Framework, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "https://umiturtle.github.io/ZigguraTs/examples/frameworks/{s}/index.html", .{self.id});
    }

    /// Source tree on GitHub. External links are skipped by the Markdown link checker, which is
    /// exactly right: the site does not publish `.tsx` / `.vue` sources as pages.
    pub fn treeUrl(self: Framework, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/{s}", .{self.id});
    }
};

const catalog_json = @embedFile("frameworks.json");

/// Parses the embedded catalog. `parseFromSliceLeaky` is fine here: the docsite generator owns one
/// arena for the whole run, and the strings all point into `catalog_json` (static data).
pub fn all(allocator: Allocator) ![]const Framework {
    return try std.json.parseFromSliceLeaky([]const Framework, allocator, catalog_json, .{
        .ignore_unknown_fields = true,
    });
}

pub fn byId(allocator: Allocator, id: []const u8) !?Framework {
    for (try all(allocator)) |fw| {
        if (std.mem.eql(u8, fw.id, id)) return fw;
    }
    return null;
}

/// Markdown substituted for a line that is only `<!-- framework-picker -->`.
///
/// The first row is the framework-free base tutorial: a reader who does not want a library must be
/// able to reach the original path without hunting for it. The first column is always a real link,
/// so with JavaScript off the whole chooser still works.
pub fn pickerMarkdown(arena: Allocator, lang: i18n.Lang) ![]const u8 {
    const t = struct {
        fn tr(l: i18n.Lang) Text {
            return switch (l) {
                .ja => .{
                    .lead = "**好きなライブラリを選んでください（Zig 側はどれも同じです）:**",
                    .library = "ライブラリ",
                    .version = "バージョン",
                    .build = "ビルド",
                    .state = "状態の持ち方",
                    .plain = "フレームワーク無し（素の JS）",
                    .no_build = "なし",
                    .plain_state = "`let count`",
                },
                .en => .{
                    .lead = "**Pick a library — the Zig side is identical for all of them:**",
                    .library = "Library",
                    .version = "Version",
                    .build = "Build",
                    .state = "State",
                    .plain = "No framework (plain JS)",
                    .no_build = "none",
                    .plain_state = "`let count`",
                },
            };
        }
        const Text = struct {
            lead: []const u8,
            library: []const u8,
            version: []const u8,
            build: []const u8,
            state: []const u8,
            plain: []const u8,
            no_build: []const u8,
            plain_state: []const u8,
        };
    }.tr(lang);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.print("{s}\n\n", .{t.lead});
    try w.print("| {s} | {s} | {s} | {s} |\n", .{ t.library, t.version, t.build, t.state });
    try w.writeAll("|---|---|---|---|\n");
    try w.print("| [{s}](counter.md) | — | {s} | {s} |\n", .{ t.plain, t.no_build, t.plain_state });
    for (try all(arena)) |fw| {
        try w.print("| [{s}](counter-{s}.md) | {s} | `{s}` | {s} |\n", .{
            fw.label, fw.id, fw.version, fw.build, fw.state(lang),
        });
    }
    return try out.toOwnedSlice();
}

test "framework catalog matches the nine committed example directories" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try all(arena);
    try testing.expectEqual(@as(usize, 9), list.len);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    for (list) |fw| {
        try testing.expect(!seen.contains(fw.id));
        try seen.put(testing.allocator, fw.id, {});
        try testing.expect(fw.label.len > 0);
        try testing.expect(fw.version.len > 0);
        try testing.expect(fw.build.len > 0);
        try testing.expect(fw.dist.len > 0);
        try testing.expect(fw.note_ja.len > 0 and fw.note_en.len > 0);
        try testing.expect(fw.state_ja.len > 0 and fw.state_en.len > 0);

        const dir = try std.fmt.allocPrint(arena, "examples/frameworks/{s}", .{fw.id});
        const stat = Io.Dir.cwd().statFile(testing.io, dir, .{}) catch |err| {
            std.debug.print("missing example directory: {s} ({t})\n", .{ dir, err });
            return err;
        };
        try testing.expectEqual(std.Io.File.Kind.directory, stat.kind);

        const src = Io.Dir.cwd().statFile(testing.io, fw.source, .{}) catch |err| {
            std.debug.print("missing example source: {s} ({t})\n", .{ fw.source, err });
            return err;
        };
        try testing.expectEqual(std.Io.File.Kind.file, src.kind);
    }
    try testing.expect((try byId(arena, "react")) != null);
    try testing.expect((try byId(arena, "not-a-library")) == null);
}

test "picker is bilingual and links the base tutorial plus all nine variants" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ja = try pickerMarkdown(arena, .ja);
    const en = try pickerMarkdown(arena, .en);

    try testing.expect(std.mem.indexOf(u8, ja, "ライブラリ") != null);
    try testing.expect(std.mem.indexOf(u8, ja, "フレームワーク無し（素の JS）") != null);
    try testing.expect(std.mem.indexOf(u8, en, "| Library | Version | Build | State |") != null);
    try testing.expect(std.mem.indexOf(u8, en, "No framework (plain JS)") != null);
    for ([_][]const u8{ "counter.md", "counter-react.md", "counter-next.md", "counter-solidstart.md" }) |href| {
        try testing.expect(std.mem.indexOf(u8, ja, href) != null);
        try testing.expect(std.mem.indexOf(u8, en, href) != null);
    }
    // 10 rows: the plain-JS base plus nine libraries.
    try testing.expectEqual(@as(usize, 10), std.mem.count(u8, ja, "]("));
    try testing.expectEqual(@as(usize, 10), std.mem.count(u8, en, "]("));
    // Deterministic: the same table every run, in both languages.
    try testing.expectEqualStrings(ja, try pickerMarkdown(arena, .ja));
}

const Io = std.Io;
