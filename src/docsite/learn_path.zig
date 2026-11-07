//! The first-run path — the four pages a new reader is walked through, in order.
//!
//! This lives in code rather than in prose because three different surfaces render it: the step
//! rail at the top of every path page, the "what next" card at the bottom, and the landing page.
//! If the order lived in three hand-written copies, the first edit would desynchronise them.
//!
//! Two properties are deliberate:
//! * **Membership is derived from the directory layout.** Anything under
//!   `docs/learn/<lang>/concepts/` is step 2, whatever its filename. Adding a concept page cannot
//!   forget to register it, and the rail can never claim a page is outside the path.
//! * **Every step's landing page is verified at build time.** `main.zig` stats each source before
//!   rendering, so renaming `start.md` fails `zig build docs` instead of shipping a dead first step.

const std = @import("std");
const testing = std.testing;
const paths = @import("paths.zig");

pub const Lang = enum { ja, en };

/// A localised string. Two fields instead of two arrays keeps the step table readable.
pub const Text = struct {
    ja: []const u8,
    en: []const u8,

    pub fn get(self: Text, lang: Lang) []const u8 {
        return switch (lang) {
            .ja => self.ja,
            .en => self.en,
        };
    }
};

pub const Step = struct {
    /// Stable id, also emitted as `data-step` so tests and analytics can address a step.
    id: []const u8,
    /// Directory under `docs/learn/<lang>/`. `""` is the hub itself, `"start.md"` a single page,
    /// `"concepts/"` a whole section whose `index.md` is the landing page.
    slug: []const u8,
    /// Rough read-and-do time. Shown in the rail; deliberately rounded, not precise.
    minutes: u8,
    title: Text,
    /// One sentence: what the reader will be able to do afterwards.
    blurb: Text,
};

/// The order is pedagogical: touch it, then understand it, then build with it, then look things up.
/// Putting the concepts first (the original order) asked the reader to learn a mental model for a
/// system they had not seen yet.
pub const steps = [_]Step{
    .{
        .id = "start",
        .slug = "start.md",
        .minutes = 10,
        .title = .{ .ja = "はじめての Z-Ts", .en = "Your first ten minutes" },
        .blurb = .{
            .ja = "インストールして、プロジェクトを作って、ブラウザで動かす。",
            .en = "Install, create a project, and get it running in a browser.",
        },
    },
    .{
        .id = "concepts",
        .slug = "concepts/",
        .minutes = 15,
        .title = .{ .ja = "仕組みを知る", .en = "How it works" },
        .blurb = .{
            .ja = "3 つの登場人物と、ボタンが Zig の関数に届くまで。",
            .en = "The three moving parts, and how a button reaches a Zig function.",
        },
    },
    .{
        .id = "tutorial",
        .slug = "tutorials/",
        .minutes = 15,
        .title = .{ .ja = "アプリを作る", .en = "Build an app" },
        .blurb = .{
            .ja = "カウンターを 1 本作り、テストして、単一バイナリにする。",
            .en = "Build, test and ship a counter as a single binary.",
        },
    },
    .{
        .id = "guides",
        .slug = "guides/",
        .minutes = 0,
        .title = .{ .ja = "目的から引く", .en = "Look things up" },
        .blurb = .{
            .ja = "ここから先は自由。やりたいことから 1 本だけ読む。",
            .en = "From here it is free-form: read the one guide for your job.",
        },
    },
};

/// Prefix of the translated tree, relative to the repository root.
pub const learn_root = "docs/learn/";

pub fn langSlug(lang: Lang) []const u8 {
    return switch (lang) {
        .ja => "ja",
        .en => "en",
    };
}

/// Total minutes, ignoring steps with no time budget (the guides index is open-ended).
pub fn totalMinutes() u8 {
    var sum: u8 = 0;
    for (steps) |step| sum += step.minutes;
    return sum;
}

/// Markdown source of the page a step starts on (`docs/learn/ja/start.md`,
/// `docs/learn/ja/concepts/index.md`).
pub fn sourcePath(allocator: std.mem.Allocator, lang: Lang, step: Step) std.mem.Allocator.Error![]const u8 {
    const index = if (std.mem.endsWith(u8, step.slug, "/")) "index.md" else "";
    return std.fmt.allocPrint(allocator, "{s}{s}/{s}{s}", .{ learn_root, langSlug(lang), step.slug, index });
}

/// Site-relative `.html` path of the same page (`docs/learn/ja/start.html`).
pub fn pageHref(allocator: std.mem.Allocator, lang: Lang, step: Step) std.mem.Allocator.Error![]const u8 {
    const md = try sourcePath(allocator, lang, step);
    return std.fmt.allocPrint(allocator, "{s}", .{try htmlPath(allocator, md)});
}

fn htmlPath(allocator: std.mem.Allocator, md: []const u8) std.mem.Allocator.Error![]const u8 {
    const stem = if (std.mem.endsWith(u8, md, ".md")) md[0 .. md.len - 3] else md;
    if (std.mem.endsWith(u8, stem, "/index")) {
        return std.fmt.allocPrint(allocator, "{s}/index.html", .{stem[0 .. stem.len - "/index".len]});
    }
    return std.fmt.allocPrint(allocator, "{s}.html", .{stem});
}

/// Which step a Markdown source belongs to, or `null` when it is not on the path (the hub page
/// itself, the glossary, the API reference, the internal notes).
///
/// Derived from the directory, not from a filename list: a new page under `concepts/` is step 2
/// without being registered anywhere.
pub fn indexOf(source: []const u8) ?usize {
    if (!std.mem.startsWith(u8, source, learn_root)) return null;
    const rest = source[learn_root.len..];
    // `ja/…` or `en/…`
    if (rest.len < 4 or rest[2] != '/') return null;
    const tail = rest[3..];
    if (std.mem.eql(u8, tail, "start.md")) return 0;
    if (std.mem.startsWith(u8, tail, "concepts/")) return 1;
    if (std.mem.startsWith(u8, tail, "tutorials/")) return 2;
    if (std.mem.startsWith(u8, tail, "guides/")) return 3;
    return null;
}

/// Site href (`docs/learn/en/tutorials/counter.html`) → step index. Used by the renderer to draw
/// the step rail on every page of the path, including the ones deep inside a section.
pub fn indexOfHref(href: []const u8) ?usize {
    if (!std.mem.startsWith(u8, href, learn_root)) return null;
    const rest = href[learn_root.len..];
    if (rest.len < 4 or rest[2] != '/') return null;
    const tail = rest[3..];
    if (std.mem.startsWith(u8, tail, "start.html") or std.mem.startsWith(u8, tail, "start/index.html")) return 0;
    if (std.mem.startsWith(u8, tail, "concepts/")) return 1;
    if (std.mem.startsWith(u8, tail, "tutorials/")) return 2;
    if (std.mem.startsWith(u8, tail, "guides/")) return 3;
    return null;
}

/// Language of a page href, or `null` when it is not in the translated learning tree.
pub fn langOfHref(href: []const u8) ?Lang {
    if (!std.mem.startsWith(u8, href, learn_root)) return null;
    const rest = href[learn_root.len..];
    if (std.mem.startsWith(u8, rest, "ja/")) return .ja;
    if (std.mem.startsWith(u8, rest, "en/")) return .en;
    return null;
}

/// Markdown block substituted for the `<!-- learn-path -->` marker: the same four steps the rail
/// renders, with relative links so the site's link checker verifies them like any other link.
pub fn markdownList(allocator: std.mem.Allocator, lang: Lang) anyerror![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    const from = try std.fmt.allocPrint(allocator, "{s}{s}/index.html", .{ learn_root, langSlug(lang) });
    for (steps, 0..) |step, i| {
        const href = try pageHref(allocator, lang, step);
        const rel = try paths.relativeHref(allocator, from, href);
        if (step.minutes > 0) {
            const minutes = try std.fmt.allocPrint(allocator, " · {d} {s}", .{
                step.minutes,
                if (lang == .ja) "分" else "min",
            });
            try w.print("{d}. **[{s}]({s})**{s} — {s}\n", .{ i + 1, step.title.get(lang), rel, minutes, step.blurb.get(lang) });
        } else {
            try w.print("{d}. **[{s}]({s})** — {s}\n", .{ i + 1, step.title.get(lang), rel, step.blurb.get(lang) });
        }
    }
    return out.toOwnedSlice();
}

test "every step resolves to its own index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for (steps, 0..) |step, i| {
        const source = try sourcePath(arena_state.allocator(), .ja, step);
        try testing.expectEqual(@as(?usize, i), indexOf(source));
    }
}

test "pages inside a section inherit the section's step" {
    try testing.expectEqual(@as(?usize, 1), indexOf("docs/learn/ja/concepts/commands.md"));
    try testing.expectEqual(@as(?usize, 1), indexOf("docs/learn/en/concepts/security.md"));
    try testing.expectEqual(@as(?usize, 2), indexOf("docs/learn/ja/tutorials/counter.md"));
    try testing.expectEqual(@as(?usize, 3), indexOf("docs/learn/en/guides/rpc.md"));
}

test "the hub, the reference and the internals are not on the path" {
    try testing.expectEqual(@as(?usize, null), indexOf("docs/learn/ja/index.md"));
    try testing.expectEqual(@as(?usize, null), indexOf("docs/glossary.md"));
    try testing.expectEqual(@as(?usize, null), indexOf("docs/reference/cli.md"));
    try testing.expectEqual(@as(?usize, null), indexOf("README.md"));
}

test "step pages exist in both languages under the same name" {
    // The parity lint (`check-docs.py` rule 8) checks the trees match; this pins the four landing
    // pages the rail links to, which is what a broken rename would take out first.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("docs/learn/ja/start.md", try sourcePath(arena, .ja, steps[0]));
    try testing.expectEqualStrings("docs/learn/en/concepts/index.md", try sourcePath(arena, .en, steps[1]));
    try testing.expectEqualStrings("docs/learn/ja/guides/index.html", try pageHref(arena, .ja, steps[3]));
}

test "the markdown list numbers the steps and links them relatively" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const md = try markdownList(arena_state.allocator(), .ja);
    try testing.expect(std.mem.indexOf(u8, md, "1. **[はじめての Z-Ts](start.html)** · 10 分 — ") != null);
    try testing.expect(std.mem.indexOf(u8, md, "2. **[仕組みを知る](concepts/index.html)** · 15 分 — ") != null);
    try testing.expect(std.mem.indexOf(u8, md, "4. **[目的から引く](guides/index.html)** — ") != null);
}

test "hrefs resolve to steps and languages" {
    try testing.expectEqual(@as(?usize, 0), indexOfHref("docs/learn/ja/start.html"));
    try testing.expectEqual(@as(?usize, 2), indexOfHref("docs/learn/en/tutorials/counter.html"));
    try testing.expectEqual(@as(?usize, 3), indexOfHref("docs/learn/en/guides/index.html"));
    try testing.expectEqual(@as(?usize, null), indexOfHref("docs/learn/ja/index.html"));
    try testing.expectEqual(@as(?usize, null), indexOfHref("docs/api/zts_web/index.html"));
    try testing.expectEqual(Lang.ja, langOfHref("docs/learn/ja/index.html").?);
    try testing.expectEqual(Lang.en, langOfHref("docs/learn/en/start.html").?);
    try testing.expectEqual(@as(?Lang, null), langOfHref("docs/glossary.html"));
}

test "the path has a finite time budget" {
    try testing.expectEqual(@as(u8, 40), totalMinutes());
}
