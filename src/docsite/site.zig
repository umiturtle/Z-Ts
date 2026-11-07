//! `M5-06` documentation site — the page shell, the sidebar and the search index.
//!
//! The site is generated *by the project itself* (dogfooding): `./zigw build docs` runs
//! `src/docsite/main.zig`, which walks `docs/**.md` (+ `AGENTS.md`, `README.md`, the example
//! READMEs), renders every page with [`markdown`], writes `dist/docs/*.html`, copies the static
//! CSS/JS and emits `search-index.js` (+ `sitemap.xml`, `llms.txt`, `llms-full.txt` and `404.html`
//! from `main.zig`).
//!
//! Two things make this a real gate rather than a nice-to-have:
//! * **link verification** — every relative link in the corpus is resolved against the set of pages
//!   we actually wrote; a broken link fails the build (`error.BrokenLinks`).
//! * **determinism** — the file list is sorted and the HTML is a pure function of the Markdown, so
//!   the CI diff of `zig-out/docs` is meaningful.

const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown = @import("markdown.zig");
const paths = @import("paths.zig");
const learn_path = @import("learn_path.zig");
const i18n = @import("i18n.zig");

/// Re-exported from `paths.zig` so existing callers (`main.zig`, the API generator) keep using
/// `site.relativeHref`; the renderer imports `paths.zig` directly to avoid an import cycle.
pub const relativeHref = paths.relativeHref;

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

/// One step of the breadcrumb trail. The last crumb has no `href`.
pub const Crumb = struct { label: []const u8, href: []const u8 = "" };

/// A previous/next page in the reader's order (the sidebar order, which is the learning order).
pub const NavLink = struct { title: []const u8, href: []const u8 };

pub const Layout = struct {
    site_title: []const u8 = "Z-Ts",
    /// Currently rendered page; `""` for the landing page.
    active_href: []const u8 = "",
    /// Explicit `<title>`. Pages that are not listed in the sidebar (the generated API reference,
    /// the internals index, every page while the sidebar collapses its group) would otherwise fall
    /// back to the site title; passing it keeps the browser tab meaningful.
    title: []const u8 = "",
    /// Sidebar groups, already sorted.
    groups: []const Group = &.{},
    /// Page body HTML.
    body: []const u8,
    /// `<h2>`/`<h3>` entries for the in-page table of contents.
    toc: []const markdown.Heading = &.{},
    /// Plain-text page content, used for the word count in the footer.
    plain: []const u8 = "",
    /// `guide` / `tutorial` / `concept` / `reference` / `recipe` / `migration` / `errors` / `api`.
    /// Rendered as a badge next to the breadcrumbs and reused by the search result list.
    kind: []const u8 = "",
    /// Repository path of the Markdown source, for the "edit this page" link. `""` on generated
    /// pages, which have no single source file.
    source: []const u8 = "",
    /// Breadcrumb trail (`Z-Ts › ガイド › RPC`). Rendered above the body.
    crumbs: []const Crumb = &.{},
    /// Reading order neighbours. `null` at the ends of a group.
    prev: ?NavLink = null,
    next: ?NavLink = null,
    /// Language of the page. Drives `<html lang>`, every chrome string and the switcher.
    lang: i18n.Lang = .ja,
    /// Site-relative path of the same page in the other language. `null` on untranslated pages
    /// (the Japanese deep dives, the API reference), which then render without a switcher.
    alt_href: ?[]const u8 = null,
};

pub const layout_error = Error;
pub const Heading = markdown.Heading;

/// The page shell. `{root}` is the relative prefix back to the site root, `{title}` the escaped
/// document title; every other string is supplied by [`i18n.Strings`] so no user-facing literal
/// lives in this file.
const head_template =
    \\<!doctype html>
    \\<html lang="{lang}" data-theme="light">
    \\<head>
    \\<meta charset="utf-8" />
    \\<meta name="viewport" content="width=device-width, initial-scale=1" />
    \\<title>{title}</title>
    \\<meta name="description" content="{description}" />
    \\<meta name="color-scheme" content="light dark" />
    \\<link rel="stylesheet" href="{root}assets/site.css" />
    \\{alt_link}
    \\<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml" />
    \\<script>document.documentElement.dataset.js="1";try{var t=localStorage.getItem("zts-theme");if(t==="light"||t==="dark"){document.documentElement.dataset.theme=t}else if(window.matchMedia&&matchMedia("(prefers-color-scheme: dark)").matches){document.documentElement.dataset.theme="dark"}}catch(e){}</script>
    \\</head>
    \\<body data-root="{root}" data-lang="{lang}">
    \\<a class="skip" href="#main">{skip}</a>
    \\<header class="topbar">
    \\  <button class="icon-btn menu-toggle" type="button" aria-label="{menu}" aria-expanded="false" data-menu-toggle>
    \\    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16" /></svg>
    \\  </button>
    \\  <a class="brand" href="{root}{home_href}"><span class="brand-mark">Z</span><span class="brand-name">Z-Ts</span></a>
    \\  <span class="topbar-sep" aria-hidden="true"></span>
    \\  <span class="brand-tagline">Tauri in Zig</span>
    \\  <div class="topbar-actions">
    \\    <div class="search" role="search">
    \\      <svg class="search-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7" /><path d="M16.5 16.5 21 21" /></svg>
    \\      <input type="search" id="search" placeholder="{search_placeholder}" aria-label="{search_placeholder}" autocomplete="off" spellcheck="false" />
    \\      <kbd class="search-kbd">/</kbd>
    \\      <ul id="search-results" class="search-results" hidden></ul>
    \\    </div>
    \\    <nav class="langs" aria-label="{language}">{lang_links}</nav>
    \\    <button class="icon-btn" type="button" aria-label="{theme}" data-theme-toggle>
    \\      <svg class="i-sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.2" /><path d="M12 2v2.6M12 19.4V22M2 12h2.6M19.4 12H22M4.9 4.9l1.9 1.9M17.2 17.2l1.9 1.9M19.1 4.9l-1.9 1.9M6.8 17.2l-1.9 1.9" /></svg>
    \\      <svg class="i-moon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5Z" /></svg>
    \\    </button>
    \\    <a class="icon-btn gh" href="https://github.com/umiturtle/Z-Ts" target="_blank" rel="noopener" aria-label="{github}">
    \\      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48v-1.7c-2.78.6-3.37-1.34-3.37-1.34-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.89 1.53 2.34 1.09 2.91.83.09-.65.35-1.09.63-1.34-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.5 9.5 0 0 1 5 0c1.91-1.29 2.75-1.02 2.75-1.02.55 1.38.2 2.4.1 2.65.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.68-4.57 4.93.36.31.68.92.68 1.85v2.75c0 .27.18.58.69.48A10 10 0 0 0 12 2Z" /></svg>
    \\    </a>
    \\  </div>
    \\</header>
    \\<div class="layout">
    \\<aside class="sidebar" aria-label="{nav_label}">
    \\  <nav class="nav-groups">{nav}</nav>
    \\  <div class="sidebar-foot"><a href="{github_url}" target="_blank" rel="noopener">{github}</a><span aria-hidden="true">·</span><a href="{root}{index_href}">Docs index</a></div>
    \\</aside>
    \\<main id="main" class="content" tabindex="-1">
    \\<div class="page-head">{page_head}</div>
    \\{path_rail}
    \\<div class="doc">
    \\  <article class="prose">{body}</article>
    \\  <aside class="rail" aria-label="{toc}">{rail}</aside>
    \\</div>
    \\</main>
    \\</div>
    \\<footer class="footer">
    \\  <span>© Z-Ts — {footer_note}</span>
    \\  <span class="footer-meta">{words}</span>
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
    const s = i18n.strings(layout.lang);
    const root = try rootPrefix(arena, href);
    const title = try pageTitle(arena, layout, href);

    // ---------------------------------------------------------------- sidebar
    var nav: std.Io.Writer.Allocating = .init(arena);
    defer nav.deinit();
    for (layout.groups) |group| {
        if (group.entries.len == 0) continue;
        try nav.writer.writeAll("<section class=\"nav-group\"><h2 class=\"nav-heading\">");
        try writeEscaped(&nav.writer, group.heading);
        try nav.writer.writeAll("</h2><ul>");
        for (group.entries) |entry| {
            const active = std.mem.eql(u8, entry.href, href);
            try nav.writer.writeAll("<li><a");
            if (active) try nav.writer.writeAll(" class=\"active\" aria-current=\"page\"");
            try nav.writer.writeAll(" href=\"");
            try writeEscaped(&nav.writer, try relativeHref(arena, href, entry.href));
            try nav.writer.writeAll("\"><span>");
            try writeEscaped(&nav.writer, entry.title);
            try nav.writer.writeAll("</span></a></li>");
        }
        try nav.writer.writeAll("</ul></section>");
    }

    // ------------------------------------------------------------- page head
    var head: std.Io.Writer.Allocating = .init(arena);
    defer head.deinit();
    if (layout.crumbs.len > 0) {
        try head.writer.writeAll("<nav class=\"crumbs\" aria-label=\"");
        try writeEscaped(&head.writer, s.crumbs_label);
        try head.writer.writeAll("\">");
        for (layout.crumbs, 0..) |crumb, idx| {
            if (idx > 0) try head.writer.writeAll("<span class=\"sep\" aria-hidden=\"true\">›</span>");
            if (crumb.href.len > 0) {
                try head.writer.writeAll("<a href=\"");
                try writeEscaped(&head.writer, try relativeHref(arena, href, crumb.href));
                try head.writer.writeAll("\">");
                try writeEscaped(&head.writer, crumb.label);
                try head.writer.writeAll("</a>");
            } else {
                try head.writer.writeAll("<span aria-current=\"page\">");
                try writeEscaped(&head.writer, crumb.label);
                try head.writer.writeAll("</span>");
            }
        }
        try head.writer.writeAll("</nav>");
    }
    if (layout.kind.len > 0) {
        try head.writer.writeAll("<span class=\"kind-badge\" data-kind=\"");
        try writeEscaped(&head.writer, layout.kind);
        try head.writer.writeAll("\">");
        try writeEscaped(&head.writer, i18n.kindLabel(layout.lang, layout.kind));
        try head.writer.writeAll("</span>");
    }
    if (layout.lang.code().len > 0) {
        try head.writer.writeAll("<span class=\"lang-badge\">");
        try writeEscaped(&head.writer, layout.lang.code());
        try head.writer.writeAll("</span>");
    }

    // ------------------------------------------------------------------- rail
    var rail: std.Io.Writer.Allocating = .init(arena);
    defer rail.deinit();
    if (layout.toc.len > 0) {
        try rail.writer.writeAll("<nav class=\"toc\"><p class=\"toc-title\">");
        try writeEscaped(&rail.writer, s.toc);
        try rail.writer.writeAll("</p><ul>");
        for (layout.toc) |heading| {
            try rail.writer.print("<li class=\"lvl{d}\"><a href=\"#", .{heading.level});
            try writeEscaped(&rail.writer, heading.id);
            try rail.writer.writeAll("\">");
            try writeEscaped(&rail.writer, heading.text);
            try rail.writer.writeAll("</a></li>");
        }
        try rail.writer.writeAll("</ul></nav>");
    }

    // ------------------------------------------------------- learning-path rail
    // Every page that belongs to the beginner path carries the same four steps, with the current
    // one marked. It answers "where am I / what is left" without a trip to the hub, and it makes
    // the concept pages reachable *from* the hands-on pages rather than before them.
    var step_rail: std.Io.Writer.Allocating = .init(arena);
    defer step_rail.deinit();
    if (learn_path.indexOfHref(href)) |current| {
        const lang: learn_path.Lang = switch (learn_path.langOfHref(href) orelse .ja) {
            .ja => if (layout.lang == .ja) .ja else .en,
            .en => .en,
        };
        try step_rail.writer.writeAll("<nav class=\"path-rail\" aria-label=\"");
        try writeEscaped(&step_rail.writer, s.path_label);
        try step_rail.writer.print("\" data-step=\"{d}\"><ol>", .{current + 1});
        for (learn_path.steps, 0..) |step, i| {
            const target = learn_path.pageHref(arena, lang, step) catch return error.OutOfMemory;
            const state: []const u8 = if (i == current)
                " class=\"current\""
            else if (i < current)
                " class=\"done\""
            else
                "";
            // `aria-current` goes on the link, which is the element a screen reader announces as
            // the current item of a navigation landmark.
            try step_rail.writer.print("<li{s}><a{s} href=\"{s}\">", .{
                state,
                if (i == current) " aria-current=\"step\"" else "",
                try relativeHref(arena, href, target),
            });
            try step_rail.writer.print("<span class=\"path-num\" aria-hidden=\"true\">{d}</span><span class=\"path-title\">{s}</span>", .{ i + 1, step.title.get(lang) });
            if (step.minutes > 0) {
                try step_rail.writer.print("<span class=\"path-min\">{d} {s}</span>", .{ step.minutes, if (lang == .ja) "分" else "min" });
            }
            try step_rail.writer.writeAll("</a></li>");
        }
        try step_rail.writer.writeAll("</ol></nav>");
    }

    // ------------------------------------------------------------------- body
    var body: std.Io.Writer.Allocating = .init(arena);
    defer body.deinit();
    try body.writer.writeAll(layout.body);
    if (layout.prev != null or layout.next != null) {
        try body.writer.writeAll("<nav class=\"pager\" aria-label=\"");
        try writeEscaped(&body.writer, s.next);
        try body.writer.writeAll("\">");
        if (layout.prev) |link| {
            try body.writer.writeAll("<a class=\"pager-prev\" rel=\"prev\" href=\"");
            try writeEscaped(&body.writer, try relativeHref(arena, href, link.href));
            try body.writer.writeAll("\"><span>← ");
            try writeEscaped(&body.writer, s.previous);
            try body.writer.writeAll("</span><strong>");
            try writeEscaped(&body.writer, link.title);
            try body.writer.writeAll("</strong></a>");
        }
        if (layout.next) |link| {
            try body.writer.writeAll("<a class=\"pager-next\" rel=\"next\" href=\"");
            try writeEscaped(&body.writer, try relativeHref(arena, href, link.href));
            try body.writer.writeAll("\"><span>");
            try writeEscaped(&body.writer, s.next);
            try body.writer.writeAll(" →</span><strong>");
            try writeEscaped(&body.writer, link.title);
            try body.writer.writeAll("</strong></a>");
        }
        try body.writer.writeAll("</nav>");
    }
    if (layout.source.len > 0) {
        try body.writer.writeAll("<p class=\"edit-link\"><a href=\"https://github.com/umiturtle/Z-Ts/blob/main/");
        try writeEscaped(&body.writer, layout.source);
        try body.writer.writeAll("\" target=\"_blank\" rel=\"noopener\">");
        try writeEscaped(&body.writer, s.edit);
        try body.writer.writeAll("</a></p>");
    }

    // ------------------------------------------------------- language switcher
    var langs: std.Io.Writer.Allocating = .init(arena);
    defer langs.deinit();
    inline for (.{ i18n.Lang.ja, i18n.Lang.en }) |lang| {
        const current = lang == layout.lang;
        const target = if (current)
            ""
        else if (layout.alt_href) |alt|
            try relativeHref(arena, href, alt)
        else
            try relativeHref(arena, href, if (lang == .ja) "docs/learn/ja/index.html" else "docs/learn/en/index.html");
        if (current) {
            try langs.writer.print("<span class=\"active\" aria-current=\"true\" lang=\"{s}\">{s}</span>", .{ lang.code(), lang.nativeName() });
        } else {
            try langs.writer.print("<a href=\"{s}\" hreflang=\"{s}\" lang=\"{s}\">{s}</a>", .{ target, lang.code(), lang.code(), lang.nativeName() });
        }
    }

    const alt_lang = layout.lang.other();
    // `hreflang` is only truthful when a translation exists: pages outside the translated tree
    // still get the visible switcher (pointing at the other language's hub), but not a machine
    // claim that this exact URL has an English twin.
    const alt_link = if (layout.alt_href) |alt|
        try std.fmt.allocPrint(arena, "<link rel=\"alternate\" hreflang=\"{s}\" href=\"{s}\" />", .{
            alt_lang.code(),
            try relativeHref(arena, href, alt),
        })
    else
        "";

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const esc = struct {
        fn e(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
            var buf: std.Io.Writer.Allocating = .init(a);
            errdefer buf.deinit();
            writeEscaped(&buf.writer, text) catch return error.OutOfMemory;
            return buf.toOwnedSlice();
        }
    };
    try writeTemplate(&out.writer, head_template, .{
        .lang = layout.lang.code(),
        .alt_link = alt_link,
        .title = try esc.e(arena, title),
        .root = root,
        .home_href = if (layout.lang == .en) "en/index.html" else "index.html",
        .description = if (layout.lang == .en)
            "Z-Ts — Tauri v2 reimplemented in Zig 0.17: six orthogonal packages for desktop, WebAssembly and static sites."
        else
            "Z-Ts — Tauri の思想を Zig 0.17 で。6 つの直交パッケージでデスクトップ / WebAssembly / SSG を 1 言語で。",
        .skip = try esc.e(arena, s.skip_to_content),
        .menu = try esc.e(arena, s.menu),
        .search_placeholder = try esc.e(arena, s.search_placeholder),
        .theme = try esc.e(arena, s.theme),
        .github = try esc.e(arena, s.github),
        .language = try esc.e(arena, s.language),
        .nav_label = try esc.e(arena, s.nav_label),
        .toc = try esc.e(arena, s.toc),
        .footer_note = try esc.e(arena, s.footer_note),
        .github_url = "https://github.com/umiturtle/Z-Ts",
        .index_href = "docs/INDEX.html",
        .lang_links = langs.written(),
        .nav = nav.written(),
        .page_head = head.written(),
        .path_rail = step_rail.written(),
        .rail = rail.written(),
        .body = body.written(),
        // The word-count template is runtime data (`{d} 語` / `{d} words`), so the number is
        // substituted rather than formatted.
        // A page with no prose (the 404, generated listings) gets no word count: "0 語" in the
        // footer is noise that reads like a bug.
        .words = if (hasProse(layout.plain))
            try replaceAll(arena, s.words_fmt, "{d}", try std.fmt.allocPrint(arena, "{d}", .{countWords(layout.plain)}))
        else
            "",
    });
    return out.toOwnedSlice();
}

/// `<title>`: explicit title first, then the sidebar entry that matches this page, then the site
/// name. Keeping the fallback chain here (instead of at every call site) is what lets generated
/// pages — which are not in the sidebar — still get a meaningful tab title.
fn pageTitle(arena: Allocator, layout: Layout, href: []const u8) Allocator.Error![]const u8 {
    if (layout.title.len > 0) {
        return std.fmt.allocPrint(arena, "{s} — {s}", .{ layout.title, layout.site_title });
    }
    if (href.len == 0) return arena.dupe(u8, layout.site_title);
    for (layout.groups) |group| for (group.entries) |entry| {
        if (std.mem.eql(u8, entry.href, href)) {
            return std.fmt.allocPrint(arena, "{s} — {s}", .{ entry.title, layout.site_title });
        }
    };
    return arena.dupe(u8, layout.site_title);
}

fn hasProse(plain: []const u8) bool {
    for (plain) |ch| if (!std.ascii.isWhitespace(ch)) return true;
    return false;
}

fn countWords(plain: []const u8) usize {
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
    return words;
}

/// Substitutes `{root}` and `{title}`. Every other brace is literal — the head template contains
/// real JavaScript, so this must not behave like `std.fmt`.
fn writeTemplate(writer: *std.Io.Writer, template: []const u8, values: anytype) !void {
    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const token_end = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
        const token = rest[open + 1 .. token_end];

        var substituted = false;
        inline for (@typeInfo(@TypeOf(values)).@"struct".field_names) |name| {
            if (std.mem.eql(u8, token, name)) {
                try writer.writeAll(rest[0..open]);
                // Values are inserted verbatim. Text that comes from the corpus is escaped by
                // the caller (`escape` below) so that the few deliberately-raw HTML fragments
                // (navigation, body, table of contents) survive.
                try writer.writeAll(@field(values, name));
                substituted = true;
            }
        }
        if (!substituted) {
            // Emit the opening brace literally and keep scanning after it.
            try writer.writeAll(rest[0 .. open + 1]);
            rest = rest[open + 1 ..];
            continue;
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
        .{ .dir = "docs/learn/ja/guides", .label = "ガイド" },
        .{ .dir = "docs/learn/en/guides", .label = "Guides" },
        .{ .dir = "docs/learn/ja/concepts", .label = "概念" },
        .{ .dir = "docs/learn/en/concepts", .label = "Concepts" },
        .{ .dir = "docs/learn/ja/tutorials", .label = "チュートリアル" },
        .{ .dir = "docs/learn/en/tutorials", .label = "Tutorials" },
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
    /// `ja` / `en`. The client sorts same-language hits first; without it, an English query
    /// would be buried under Japanese pages that happen to contain the same Latin word.
    lang: []const u8 = "ja",
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
        try out.writer.writeAll("\",\"l\":\"");
        try writeJsString(&out.writer, entry.lang);
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

    // Same directory: no `../` at all.
    try testing.expectEqualStrings("y.html", try relativeHref(arena, "docs/tasks/x.html", "docs/tasks/y.html"));
    try testing.expectEqualStrings("mime.html", try relativeHref(arena, "docs/api/zts_web/index.html", "docs/api/zts_web/mime.html"));

    // A directory whose name is a prefix of a sibling directory must not be treated as shared:
    // `zts_web` is a prefix of `zts_webview` as a *string*, not as a path segment.
    try testing.expectEqualStrings("../zts_webview/index.html", try relativeHref(arena, "docs/api/zts_web/mime.html", "docs/api/zts_webview/index.html"));
    try testing.expectEqualStrings("../zts_web/index.html", try relativeHref(arena, "docs/api/zts_webview/mod.html", "docs/api/zts_web/index.html"));
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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
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
        .kind = "guide",
        .crumbs = &.{.{ .label = "Z-Ts", .href = "index.html" }},
        .lang = .ja,
    }, "docs/tasks/a.html");

    try testing.expect(std.mem.startsWith(u8, html, "<!doctype html>"));
    try testing.expect(std.mem.indexOf(u8, html, "<html lang=\"ja\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<title>タスク A — Z-Ts</title>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"../../assets/site.css\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "class=\"active\" aria-current=\"page\" href=\"a.html\"><span>タスク A") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"../index.html\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<a href=\"#目的\">目的</a>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<p>body</p>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"footer-meta\">3 語</span>") != null);
    // Japanese chrome, plus a switcher whose target is the English hub (this page has no
    // translation, so the link must not dead-end).
    try testing.expect(std.mem.indexOf(u8, html, "このページの目次") != null);
    try testing.expect(std.mem.indexOf(u8, html, "hreflang=\"en\" lang=\"en\" href=\"../learn/en/index.html\"") != null or
        std.mem.indexOf(u8, html, "href=\"../learn/en/index.html\" hreflang=\"en\"") != null);
    try testing.expect(std.mem.endsWith(u8, html, "</html>\n"));
}

test "an English page renders English chrome and links back to its translation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html = try renderPage(arena, .{
        .active_href = "docs/learn/en/index.html",
        .title = "Learn",
        .body = "<p>body</p>\n",
        .plain = "one two three",
        .lang = .en,
        .alt_href = "docs/learn/ja/index.html",
    }, "docs/learn/en/index.html");

    try testing.expect(std.mem.indexOf(u8, html, "<html lang=\"en\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Search…") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Skip to content") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"footer-meta\">3 words</span>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "hreflang=\"ja\" href=\"../ja/index.html\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"../../../en/index.html\"") != null);
}
