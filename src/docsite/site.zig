//! `M5-06` documentation site — the page shell, the sidebar and the search index.
//!
//! The site is generated *by the project itself* (dogfooding): `./zigw build docs` runs
//! `src/docsite/main.zig`, which walks `docs/**.md` (+ `AGENTS.md`, `README.md`, the example
//! READMEs), renders every page with [`markdown`], writes `dist/docs/*.html`, copies the static
//! CSS/JS and emits `search-index.js` + `sitemap.txt`.
//!
//! Two things make this a real gate rather than a nice-to-have:
//! * **link verification** — every relative link in the corpus is resolved against the set of pages
//!   we actually wrote; a broken link fails the build (`error.BrokenLinks`).
//! * **determinism** — the file list is sorted and the HTML is a pure function of the Markdown, so
//!   the CI diff of `zig-out/docs` is meaningful.

const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown = @import("markdown.zig");

/// `std.Io.Writer.Allocating` reports allocation failure as `error.WriteFailed`; the internal
/// helpers accept both and the public entry points narrow it to `OutOfMemory` (see `markdown.zig`).
const Error = Allocator.Error || error{WriteFailed};

pub const NavEntry = struct {
    /// Site-relative path of the generated page (`docs/tasks/M5-01-build-tools.html`).
    href: []const u8,
    /// Human title (the page's first `#` heading).
    title: []const u8,
    /// Source path relative to the repository root (`docs/tasks/M5-01-build-tools.md`).
    source: []const u8,
};

pub const Group = struct {
    heading: []const u8,
    entries: []const NavEntry,
};

pub const Layout = struct {
    site_title: []const u8 = "Z-Ts",
    /// Currently rendered page; `""` for the landing page.
    active_href: []const u8 = "",
    /// Sidebar groups, already sorted.
    groups: []const Group = &.{},
    /// Page body HTML.
    body: []const u8,
    /// `<h2>`/`<h3>` entries for the in-page table of contents.
    toc: []const markdown.Heading = &.{},
    /// Plain-text page content, used for the word count in the footer.
    plain: []const u8 = "",
};

pub const layout_error = Error;

const head_template =
    \\<!doctype html>
    \\<html lang="ja" data-theme="light">
    \\<head>
    \\<meta charset="utf-8" />
    \\<meta name="viewport" content="width=device-width, initial-scale=1" />
    \\<title>{title}</title>
    \\<meta name="description" content="Z-Ts — Tauri in Zig 0.17: 6 つの直交パッケージでデスクトップ / WebAssembly / SSG を 1 言語で。" />
    \\<link rel="stylesheet" href="{root}assets/site.css" />
    \\<script>try{const t=localStorage.getItem("zts-theme");if(t)document.documentElement.dataset.theme=t}catch(e){}</script>
    \\</head>
    \\<body>
    \\<a class="skip" href="#main">本文へスキップ</a>
    \\<header class="topbar">
    \\  <button class="menu-toggle" type="button" aria-label="メニュー" data-menu-toggle>☰</button>
    \\  <a class="brand" href="{root}index.html"><span class="brand-mark">Z</span> Z-Ts <span class="brand-sub">Tauri in Zig</span></a>
    \\  <div class="topbar-actions">
    \\    <a class="gh" href="https://github.com/umiturtle/Z-Ts" target="_blank" rel="noopener">GitHub</a>
    \\    <button class="theme-toggle" type="button" aria-label="テーマ切替" data-theme-toggle>◐</button>
    \\  </div>
    \\</header>
    \\<div class="shell">
    \\<nav class="sidebar" aria-label="ドキュメント">
    \\<div class="search">
    \\  <input type="search" id="search" placeholder="検索…  ( / )" autocomplete="off" spellcheck="false" />
    \\  <ul id="search-results" class="search-results" hidden></ul>
    \\</div>
    \\
;

const tail_template =
    \\</main>
    \\</div>
    \\<footer class="footer">
    \\  <span>Z-Ts — Tauri v2 の思想を Zig 0.17 で再実装（<a href="https://github.com/umiturtle/Z-Ts">umiturtle/Z-Ts</a>）</span>
    \\  <span>{words} 語</span>
    \\</footer>
    \\<script src="{root}assets/search-index.js"></script>
    \\<script src="{root}assets/site.js"></script>
    \\</body>
    \\</html>
    \\
;

/// `../` repeated as needed so the page at `href` can reach the site root (`docs/assets/…`).
pub fn rootPrefix(arena: Allocator, href: []const u8) Allocator.Error![]const u8 {
    var depth: usize = 0;
    for (href) |ch| if (ch == '/') {
        depth += 1;
    };
    if (depth == 0) return "";
    const out = try arena.alloc(u8, depth * 3);
    for (0..depth) |i| @memcpy(out[i * 3 ..][0..3], "../");
    return out;
}

/// Renders one page. `href` is the site-relative path of the page itself.
pub fn renderPage(arena: Allocator, layout: Layout, href: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const writer = &out.writer;

    const root = try rootPrefix(arena, href);
    const title = if (href.len == 0) layout.site_title else try std.fmt.allocPrint(arena, "{s} — {s}", .{
        blk: {
            // The first nav entry that matches this page supplies the title.
            for (layout.groups) |group| for (group.entries) |entry| {
                if (std.mem.eql(u8, entry.href, href)) break :blk entry.title;
            };
            break :blk layout.site_title;
        },
        layout.site_title,
    });

    try writeTemplate(writer, head_template, title, root);

    try writer.writeAll("<div class=\"nav-groups\">\n");
    for (layout.groups) |group| {
        try writer.writeAll("<section class=\"nav-group\">\n<h2>");
        try writeEscaped(writer, group.heading);
        try writer.writeAll("</h2>\n<ul>\n");
        for (group.entries) |entry| {
            const active = std.mem.eql(u8, entry.href, href);
            try writer.writeAll("<li");
            if (active) try writer.writeAll(" class=\"active\"");
            try writer.writeAll("><a href=\"");
            try writeEscaped(writer, try relativeHref(arena, href, entry.href));
            try writer.writeAll("\">");
            try writeEscaped(writer, entry.title);
            try writer.writeAll("</a></li>\n");
        }
        try writer.writeAll("</ul>\n</section>\n");
    }
    try writer.writeAll("</div>\n</nav>\n<main id=\"main\" class=\"content\">\n");

    if (layout.toc.len > 0) {
        try writer.writeAll("<details class=\"toc\"");
        if (layout.toc.len <= 8) try writer.writeAll(" open");
        try writer.writeAll("><summary>このページの目次</summary>\n<ul>\n");
        for (layout.toc) |heading| {
            try writer.print("<li class=\"lvl{d}\"><a href=\"#", .{heading.level});
            try writeEscaped(writer, heading.id);
            try writer.writeAll("\">");
            try writeEscaped(writer, heading.text);
            try writer.writeAll("</a></li>\n");
        }
        try writer.writeAll("</ul></details>\n");
    }

    try writer.writeAll(layout.body);
    try writeTemplate(writer, tail_template, "", root);

    // The footer needs the word count, so patch the placeholder after the fact.
    const rendered = try out.toOwnedSlice();
    return replaceAll(arena, rendered, "{words}", try wordCount(arena, layout.plain));
}

/// Relative link from the page at `from` to the page at `to` (both site-relative).
///
/// The directories the two pages share are dropped, so `docs/tasks/a.html` → `docs/index.html`
/// becomes `../index.html` rather than `../../docs/index.html`.
pub fn relativeHref(arena: Allocator, from: []const u8, to: []const u8) Allocator.Error![]const u8 {
    const from_dir = from[0 .. std.mem.lastIndexOfScalar(u8, from, '/') orelse 0];

    // Longest shared directory prefix (on segment boundaries).
    var shared: usize = 0;
    var probe: usize = 0;
    while (probe < from_dir.len and probe < to.len) : (probe += 1) {
        if (from_dir[probe] != to[probe]) break;
        if (to[probe] == '/') shared = probe + 1;
    }
    // `from_dir` entirely consumed means the target sits in the same directory (or below it).
    if (from_dir.len > 0 and probe == from_dir.len) {
        shared = if (to.len == from_dir.len) to.len else from_dir.len + 1;
    }

    // `shared` indexes both strings; when the whole directory is shared it overshoots by one.
    const rest_up = from_dir[@min(shared, from_dir.len)..];
    var depth: usize = 0;
    if (rest_up.len > 0) depth = std.mem.count(u8, rest_up, "/") + 1;

    const up = try arena.alloc(u8, depth * 3);
    for (0..depth) |i| @memcpy(up[i * 3 ..][0..3], "../");
    return std.fmt.allocPrint(arena, "{s}{s}", .{ up, to[shared..] });
}

fn wordCount(arena: Allocator, plain: []const u8) Allocator.Error![]const u8 {
    var words: usize = 0;
    var in_word = false;
    for (plain) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == 0xE3 or ch == 0xE4 or ch == 0xE5) {
            // CJK text has no spaces; count every character run as a word instead.
            if (in_word) words += 1;
            in_word = ch >= 0x80;
            if (in_word) {
                words += 1;
                in_word = false;
            }
            continue;
        }
        in_word = true;
    }
    if (in_word) words += 1;
    if (words == 0) return "0";
    return std.fmt.allocPrint(arena, "{d}", .{words});
}

/// Substitutes `{root}` and `{title}`. Every other brace is literal — the head template contains
/// real JavaScript, so this must not behave like `std.fmt`.
fn writeTemplate(writer: *std.Io.Writer, template: []const u8, title: []const u8, root: []const u8) !void {
    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const token_end = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
        const token = rest[open + 1 .. token_end];
        const known = std.mem.eql(u8, token, "root") or std.mem.eql(u8, token, "title");
        if (!known) {
            // Emit the opening brace literally and keep scanning after it.
            try writer.writeAll(rest[0 .. open + 1]);
            rest = rest[open + 1 ..];
            continue;
        }
        try writer.writeAll(rest[0..open]);
        if (std.mem.eql(u8, token, "root")) {
            try writer.writeAll(root);
        } else {
            try writeEscaped(writer, title);
        }
        rest = rest[token_end + 1 ..];
    }
    try writer.writeAll(rest);
}

fn replaceAll(arena: Allocator, text: []const u8, needle: []const u8, replacement: []const u8) Allocator.Error![]u8 {
    if (std.mem.indexOf(u8, text, needle) == null) return arena.dupe(u8, text);
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, needle)) |at| {
        out.writer.writeAll(text[cursor..at]) catch return error.OutOfMemory;
        out.writer.writeAll(replacement) catch return error.OutOfMemory;
        cursor = at + needle.len;
    }
    out.writer.writeAll(text[cursor..]) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(ch),
        }
    }
}

// ---------------------------------------------------------------------------
// Link verification
// ---------------------------------------------------------------------------

pub const BrokenLink = struct {
    from: []const u8,
    href: []const u8,
    resolved: []const u8,
};

/// One `[text](href)` occurrence found on the page at `from`.
pub const LinkRef = struct { from: []const u8, href: []const u8 };

pub const LinkCheck = struct {
    checked: usize = 0,
    broken: []const BrokenLink = &.{},
};

/// Verifies that every relative link in `pages` points at a page we generated (or at a directory
/// that has an `index.html`). Absolute URLs, `mailto:` and pure `#anchor` links are ignored; the
/// caller has already rewritten `.md` → `.html`.
pub fn checkLinks(
    arena: Allocator,
    pages: []const []const u8,
    links: []const LinkRef,
) Allocator.Error!LinkCheck {
    var broken: std.ArrayListUnmanaged(BrokenLink) = .empty;
    var checked: usize = 0;

    for (links) |link| {
        if (isExternal(link.href) or link.href.len == 0 or link.href[0] == '#') continue;
        checked += 1;

        const resolved = try resolveRelative(arena, link.from, link.href);
        if (contains(pages, resolved)) continue;
        // `../tasks/` (a link to a directory) resolves to that directory's generated index page.
        if (contains(pages, try std.fmt.allocPrint(arena, "{s}/index.html", .{trimTrailingSlash(resolved)}))) continue;
        try broken.append(arena, .{ .from = link.from, .href = link.href, .resolved = resolved });
    }

    return .{ .checked = checked, .broken = try broken.toOwnedSlice(arena) };
}

fn trimTrailingSlash(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    if (path.len == 1 and path[0] == '/') return "";
    return path;
}

/// One entry of a generated section index (`docs/tasks/index.html`, …).
pub const DirectoryEntry = struct {
    href: []const u8,
    title: []const u8,
    summary: []const u8 = "",
};

/// Body of a section landing page: every page in that directory, with its first paragraph as a
/// teaser. Rendered with the same shell as normal pages so the sidebar/TOC keep working.
pub fn renderDirectoryBody(arena: Allocator, dir: []const u8, entries: []const DirectoryEntry) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;

    const heading = try std.fmt.allocPrint(arena, "{s} の一覧（{d} 件）", .{ displayDir(dir), entries.len });
    try w.writeAll("<h1>");
    try writeEscaped(w, heading);
    try w.writeAll("</h1>\n<ul class=\"dir-list\">\n");
    for (entries) |entry| {
        const file = entry.href[(std.mem.lastIndexOfScalar(u8, entry.href, '/') orelse 0) + 1 ..];
        try w.writeAll("<li><a href=\"");
        try writeEscaped(w, file);
        try w.writeAll("\">");
        try writeEscaped(w, entry.title);
        try w.writeAll("</a>");
        if (entry.summary.len > 0) {
            try w.writeAll("<span class=\"dir-summary\">");
            try writeEscaped(w, entry.summary);
            try w.writeAll("</span>");
        }
        try w.writeAll("</li>\n");
    }
    try w.writeAll("</ul>\n");
    return out.toOwnedSlice();
}

fn displayDir(dir: []const u8) []const u8 {
    const names = [_]struct { dir: []const u8, label: []const u8 }{
        .{ .dir = "docs/tasks", .label = "タスク" },
        .{ .dir = "docs/decisions", .label = "設計判断（ADR）" },
        .{ .dir = "docs/architecture", .label = "アーキテクチャ" },
        .{ .dir = "docs/roadmap", .label = "ロードマップ" },
        .{ .dir = "docs/reference", .label = "リファレンス" },
        .{ .dir = "docs/environment", .label = "実行環境" },
        .{ .dir = "docs", .label = "ドキュメント" },
        .{ .dir = "examples/frameworks", .label = "フレームワーク" },
        .{ .dir = "examples/counter", .label = "カウンター" },
        .{ .dir = "examples/gallery", .label = "ギャラリー" },
        .{ .dir = "examples/c_embed", .label = "C 埋め込み" },
    };
    for (names) |entry| if (std.mem.eql(u8, dir, entry.dir)) return entry.label;
    if (std.mem.lastIndexOfScalar(u8, dir, '/')) |slash| return dir[slash + 1 ..];
    return dir;
}

fn isExternal(href: []const u8) bool {
    return std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://") or
        std.mem.startsWith(u8, href, "mailto:") or std.mem.startsWith(u8, href, "//");
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

/// Resolves `href` (without its `#fragment`) against the directory of the page at `from`.
pub fn resolveRelative(arena: Allocator, from: []const u8, href: []const u8) Allocator.Error![]const u8 {
    var path = href;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash| path = path[0..hash];

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    const base_end = std.mem.lastIndexOfScalar(u8, from, '/') orelse 0;
    if (base_end > 0) {
        var it = std.mem.splitScalar(u8, from[0..base_end], '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            try segments.append(arena, segment);
        }
    }
    if (base_end == 0 and from.len > 0 and from[0] != '/') {
        // The page lives at the site root.
    }

    if (std.mem.startsWith(u8, path, "/")) segments.clearRetainingCapacity();

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(arena, segment);
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    for (segments.items, 0..) |segment, index| {
        if (index > 0) out.writer.writeByte('/') catch return error.OutOfMemory;
        out.writer.writeAll(segment) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Search index
// ---------------------------------------------------------------------------

pub const SearchEntry = struct {
    href: []const u8,
    title: []const u8,
    group: []const u8,
    text: []const u8,
};

/// A tiny client-side index: `window.ZTS_SEARCH = [...]`. No server, no dependency, ~1 byte per
/// character and it works from `file://` as well (see `docs/` previews).
pub fn renderSearchIndex(arena: Allocator, entries: []const SearchEntry) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    try out.writer.writeAll("window.ZTS_SEARCH=");
    try out.writer.writeAll("[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"u\":\"");
        try writeJsString(&out.writer, entry.href);
        try out.writer.writeAll("\",\"t\":\"");
        try writeJsString(&out.writer, entry.title);
        try out.writer.writeAll("\",\"g\":\"");
        try writeJsString(&out.writer, entry.group);
        try out.writer.writeAll("\",\"x\":\"");
        // Cap the body: the index is shipped to every visitor.
        try writeJsString(&out.writer, truncate(entry.text, 4000));
        try out.writer.writeAll("\"}");
    }
    try out.writer.writeAll("];");
    return out.toOwnedSlice();
}

fn truncate(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var cut = max;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1; // do not split a UTF-8 sequence
    return text[0..cut];
}

fn writeJsString(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => {},
            '\t' => try writer.writeAll("\\t"),
            '<' => try writer.writeAll("\\u003c"),
            '>' => try writer.writeAll("\\u003e"),
            '&' => try writer.writeAll("\\u0026"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "relativeHref walks up from the page directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("tasks/M5-01-build-tools.html", try relativeHref(arena, "index.html", "tasks/M5-01-build-tools.html"));
    try testing.expectEqualStrings("../../index.html", try relativeHref(arena, "docs/tasks/x.html", "index.html"));
    try testing.expectEqualStrings("../decisions/0017.html", try relativeHref(arena, "docs/tasks/x.html", "docs/decisions/0017.html"));
}

test "rootPrefix counts directories for asset URLs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("", try rootPrefix(arena, "index.html"));
    try testing.expectEqualStrings("../", try rootPrefix(arena, "docs/index.html"));
    try testing.expectEqualStrings("../../", try rootPrefix(arena, "docs/tasks/x.html"));
}

test "resolveRelative resolves dot segments against the page directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { from: []const u8, href: []const u8, expected: []const u8 }{
        .{ .from = "docs/tasks/M5-01.html", .href = "../architecture/build-tools.html", .expected = "docs/architecture/build-tools.html" },
        .{ .from = "docs/tasks/M5-01.html", .href = "./M5-02.html", .expected = "docs/tasks/M5-02.html" },
        .{ .from = "docs/tasks/M5-01.html", .href = "M5-02.html#3-設計", .expected = "docs/tasks/M5-02.html" },
        .{ .from = "docs/tasks/M5-01.html", .href = "../../AGENTS.html", .expected = "AGENTS.html" },
        .{ .from = "AGENTS.html", .href = "docs/INDEX.html", .expected = "docs/INDEX.html" },
        .{ .from = "docs/INDEX.html", .href = "../examples/counter/README.html", .expected = "examples/counter/README.html" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case.expected, try resolveRelative(arena, case.from, case.href));
    }
}

test "checkLinks reports only real breakage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pages = [_][]const u8{ "index.html", "docs/index.html", "docs/tasks/a.html", "docs/assets/site.css" };
    const links = [_]LinkRef{
        .{ .from = "docs/index.html", .href = "tasks/a.html" },
        .{ .from = "docs/tasks/a.html", .href = "../index.html" },
        .{ .from = "docs/index.html", .href = "https://tauri.app" },
        .{ .from = "docs/tasks/a.html", .href = "../assets/site.css" },
        .{ .from = "docs/tasks/a.html", .href = "#anchor" },
    };
    const ok = try checkLinks(arena, &pages, &links);
    try testing.expectEqual(@as(usize, 3), ok.checked);
    try testing.expectEqual(@as(usize, 0), ok.broken.len);

    const bad_links = [_]LinkRef{
        .{ .from = "docs/tasks/a.html", .href = "../nope.html" },
    };
    const bad = try checkLinks(arena, &pages, &bad_links);
    try testing.expectEqual(@as(usize, 1), bad.broken.len);
    try testing.expectEqualStrings("docs/nope.html", bad.broken[0].resolved);
}

test "search index is valid-ish JSON with escaped payloads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]SearchEntry{
        .{ .href = "docs/a.html", .title = "A \"quoted\" title", .group = "Tasks", .text = "line one\nline <two> & three" },
    };
    const json = try renderSearchIndex(arena, &entries);
    try testing.expect(std.mem.startsWith(u8, json, "window.ZTS_SEARCH=[{\"u\":\"docs/a.html\",\"t\":\"A \\\"quoted\\\" title\""));
    try testing.expect(std.mem.indexOf(u8, json, "line one\\nline \\u003ctwo\\u003e \\u0026 three") != null);
    try testing.expect(std.mem.endsWith(u8, json, "];"));
}

test "truncate never splits a UTF-8 sequence" {
    const text = "あああ"; // 9 bytes
    const cut = truncate(text, 5);
    try testing.expectEqual(@as(usize, 3), cut.len);
    try testing.expectEqualStrings("あ", cut);
    try testing.expectEqualStrings("ああ", truncate(text, 6));
}

test "renderPage produces a full document with nav, toc and assets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try arena.alloc(NavEntry, 2);
    entries[0] = .{ .href = "docs/index.html", .title = "索引", .source = "docs/INDEX.md" };
    entries[1] = .{ .href = "docs/tasks/a.html", .title = "タスク A", .source = "docs/tasks/a.md" };
    const groups = try arena.alloc(Group, 1);
    groups[0] = .{ .heading = "ドキュメント", .entries = entries };
    const toc = try arena.alloc(markdown.Heading, 1);
    toc[0] = .{ .level = 2, .id = "目的", .text = "目的" };

    const html = try renderPage(arena, .{
        .active_href = "docs/tasks/a.html",
        .groups = groups,
        .body = "<p>body</p>\n",
        .toc = toc,
        .plain = "one two three",
    }, "docs/tasks/a.html");

    try testing.expect(std.mem.startsWith(u8, html, "<!doctype html>"));
    try testing.expect(std.mem.indexOf(u8, html, "<title>タスク A — Z-Ts</title>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"../../assets/site.css\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "class=\"active\"><a href=\"a.html\">タスク A") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"../index.html\">索引") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<a href=\"#目的\">目的</a>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<p>body</p>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span>3 語</span>") != null);
    try testing.expect(std.mem.endsWith(u8, html, "</html>\n"));
}
