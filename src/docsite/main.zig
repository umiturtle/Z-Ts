//! `M5-06` documentation site generator (`zig build docs`).
//!
//! Walks the Markdown corpus (`README.md`, `AGENTS.md`, `docs/**/*.md`, `examples/*/README.md`),
//! renders every page with the in-tree renderer and writes a static site that GitHub Pages can
//! serve without a build step on the host side:
//!
//! ```text
//! dist/
//!   index.html                 landing page (hero, quick start, links)
//!   AGENTS.html                one page per Markdown file, same relative layout as the repo
//!   docs/…/*.html              (so the repository's own relative links keep working)
//!   examples/…/README.html
//!   assets/{site.css,site.js,search-index.js}
//!   .nojekyll                  GitHub Pages must not run Jekyll over the output
//! ```
//!
//! Everything is verified here, not in the browser: every relative link is resolved against the
//! pages that were actually written, and a single broken link fails the build. Marker for CI:
//! `OK docsite pages=N links=M words=W`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const markdown = @import("markdown.zig");
const site = @import("site.zig");
const demos = @import("demos.zig");
const apidoc = @import("apidoc.zig");

/// One Markdown file of the corpus plus the sidebar group it belongs to.
const Source = struct {
    path: []const u8,
    group: []const u8,
};

pub const SiteReport = struct {
    pages: usize = 0,
    links: usize = 0,
    words: usize = 0,
    bytes: usize = 0,
    /// Files copied from `examples/gallery/src/web/fw` (+ the shared fonts).
    demo_files: usize = 0,
    /// Asset URLs (`src=` / `href=`) verified to exist in the output tree.
    assets: usize = 0,
    /// Pages of the generated API reference (`M5-07`).
    api_pages: usize = 0,
    /// Public declarations that the API reference documented.
    api_decls: usize = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var out_path: []const u8 = "zig-out/docs";
    var publish_demos = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--no-demos")) {
            publish_demos = false;
        } else {
            std.debug.print("docsite: unknown argument '{s}'\n", .{args[i]});
            return 1;
        }
    }

    const report = generate(arena, io, out_path, publish_demos) catch |err| {
        std.debug.print("docsite: {t}\n", .{err});
        return 1;
    };

    std.debug.print(
        "OK docsite pages={d} links={d} assets={d} words={d} bytes={d} demos={d} api_pages={d} api_decls={d}\n",
        .{ report.pages, report.links, report.assets, report.words, report.bytes, report.demo_files, report.api_pages, report.api_decls },
    );
    return 0;
}

pub fn generate(arena: Allocator, io: Io, out_path: []const u8, publish_demos: bool) !SiteReport {
    const cwd = Io.Dir.cwd();

    const sources = try collectSources(arena, io);
    if (sources.len == 0) return error.NoDocuments;

    // 1. Render every document once: the sidebar and the search index need all titles first.
    const Rendered = struct {
        href: []const u8,
        source: []const u8,
        title: []const u8,
        group: []const u8,
        document: markdown.Document,
        toc: []const markdown.Heading,
    };
    const rendered = try arena.alloc(Rendered, sources.len);

    var report: SiteReport = .{};
    for (sources, rendered) |source, *out| {
        out.* = .{
            .href = try htmlPath(arena, source.path),
            .source = source.path,
            .title = "",
            .group = source.group,
            .document = undefined,
            .toc = &.{},
        };
        try renderInto(arena, cwd, io, out);
        report.words += countWords(out.document.plain);
    }

    // 1b. API reference, generated from the Zig sources themselves (`M5-07`). It is built before
    //     the sidebar because the sidebar lists one entry per package.
    const api = try buildApiPages(arena, io);

    // 2. Sidebar: fixed group order, entries sorted by source path.
    const groups = try buildGroups(arena, rendered, api.packages);

    // 2b. Section landing pages: `docs/tasks/index.html` lists every task with a one-line teaser,
    //     so a link to `docs/tasks/` (a directory) still works on the published site.
    const sections = try buildSectionIndexes(arena, rendered);

    // 3. Link verification. The site mirrors the repository layout, so a page's relative links
    //    keep working unchanged; the only exceptions are links to files that are *not* part of the
    //    site (`.zig` sources, workflows, C files) — those are pointed at GitHub instead.
    var written: std.ArrayListUnmanaged([]const u8) = .empty;
    try written.append(arena, "index.html");
    try written.append(arena, internals_href);
    for (rendered) |page| try written.append(arena, page.href);
    for (sections) |section| try written.append(arena, try std.fmt.allocPrint(arena, "{s}/index.html", .{section.dir}));
    for (api.pages) |page| try written.append(arena, page.href);

    var refs: std.ArrayListUnmanaged(site.LinkRef) = .empty;
    for (rendered) |page| {
        for (page.document.links) |link| try refs.append(arena, .{ .from = page.href, .href = link.href });
    }
    for (api.pages) |page| {
        for (page.links) |link| try refs.append(arena, .{ .from = page.href, .href = link.href });
    }
    const first_pass = try site.checkLinks(arena, written.items, refs.items);

    if (first_pass.broken.len > 0) {
        var rewrites: std.ArrayListUnmanaged(markdown.Rewrite) = .empty;
        var still_broken: std.ArrayListUnmanaged(site.BrokenLink) = .empty;

        for (first_pass.broken) |broken| {
            // Repository paths that the site does not publish are linked on GitHub (blob for a
            // file, tree for a directory such as `src/tauri/menu/`).
            const to = switch (repoPathKind(io, broken.resolved)) {
                .missing => {
                    try still_broken.append(arena, broken);
                    continue;
                },
                .file => try std.fmt.allocPrint(arena, "{s}{s}", .{ repo_blob_base, broken.resolved }),
                .directory => try std.fmt.allocPrint(arena, "{s}{s}", .{ repo_tree_base, broken.resolved }),
            };
            try rewrites.append(arena, .{ .page = broken.from, .href = broken.href, .to = to });
        }

        if (still_broken.items.len > 0) {
            std.debug.print("docsite: {d} broken link(s)\n", .{still_broken.items.len});
            for (still_broken.items) |broken| {
                std.debug.print("  {s}: {s} -> {s}\n", .{ broken.from, broken.href, broken.resolved });
            }
            return error.BrokenLinks;
        }

        // Re-render only the pages that needed a rewrite.
        for (rendered) |*page| {
            var relevant = false;
            for (rewrites.items) |rule| {
                if (std.mem.eql(u8, rule.page, page.href)) relevant = true;
            }
            if (!relevant) continue;
            try renderIntoWithRewrites(arena, cwd, io, page, rewrites.items);
        }

        refs.clearRetainingCapacity();
        for (rendered) |page| {
            for (page.document.links) |link| try refs.append(arena, .{ .from = page.href, .href = link.href });
        }
        for (api.pages) |page| {
            for (page.links) |link| try refs.append(arena, .{ .from = page.href, .href = link.href });
        }
        const second_pass = try site.checkLinks(arena, written.items, refs.items);
        if (second_pass.broken.len > 0) {
            std.debug.print("docsite: {d} broken link(s) after rewriting\n", .{second_pass.broken.len});
            for (second_pass.broken) |broken| {
                std.debug.print("  {s}: {s} -> {s}\n", .{ broken.from, broken.href, broken.resolved });
            }
            return error.BrokenLinks;
        }
        report.links = second_pass.checked;
    } else {
        report.links = first_pass.checked;
    }

    // 4. Write the pages.
    try cwd.createDirPath(io, out_path);
    const out_dir = try cwd.openDir(io, out_path, .{ .iterate = true });
    defer out_dir.close(io);

    for (rendered) |page| {
        const body = if (std.mem.eql(u8, page.group, internals_group))
            try std.fmt.allocPrint(arena, "{s}{s}", .{ try internalsBanner(arena, page.href), page.document.html })
        else
            page.document.html;
        const html = try site.renderPage(arena, .{
            .title = page.title,
            .active_href = page.href,
            .groups = groups,
            .body = body,
            .toc = page.toc,
            .plain = page.document.plain,
        }, page.href);
        try writeInDir(io, arena, out_dir, page.href, html);
        report.pages += 1;
        report.bytes += html.len;
    }

    for (sections) |section| {
        const body = try site.renderDirectoryBody(arena, section.dir, section.entries);
        const html = try site.renderPage(arena, .{
            .active_href = "",
            .groups = groups,
            .body = body,
        }, try std.fmt.allocPrint(arena, "{s}/index.html", .{section.dir}));
        try writeInDir(io, arena, out_dir, try std.fmt.allocPrint(arena, "{s}/index.html", .{section.dir}), html);
        report.pages += 1;
        report.bytes += html.len;
    }

    // 4b. The API reference pages (`docs/api/…`).
    for (api.pages) |page| {
        const html = try site.renderPage(arena, .{
            .title = page.title,
            .active_href = page.href,
            .groups = groups,
            .body = page.body,
        }, page.href);
        try writeInDir(io, arena, out_dir, page.href, html);
        report.pages += 1;
        report.bytes += html.len;
    }
    report.api_pages = api.pages.len;
    report.api_decls = api.decl_count;

    // 4c. The one page that lists everything the sidebar deliberately no longer shows.
    {
        const body = try renderInternalsBody(arena, rendered);
        const html = try site.renderPage(arena, .{
            .title = "内部資料（設計・ADR・タスク）",
            .active_href = internals_href,
            .groups = groups,
            .body = body,
        }, internals_href);
        try writeInDir(io, arena, out_dir, internals_href, html);
        report.pages += 1;
        report.bytes += html.len;
    }

    // 5. Landing page, assets, `.nojekyll` and the search index.
    const landing = try renderLanding(arena, groups, api);
    try writeInDir(io, arena, out_dir, "index.html", landing);
    report.bytes += landing.len;
    report.pages += 1;

    try writeInDir(io, arena, out_dir, ".nojekyll", "");

    const assets = [_][]const u8{ "site.css", "site.js" };
    for (assets) |name| {
        const source_path = try std.fmt.allocPrint(arena, "src/docsite/assets/{s}", .{name});
        const bytes = cwd.readFileAlloc(io, source_path, arena, .limited(1024 * 1024)) catch |err| {
            std.debug.print("docsite: cannot read {s}: {t}\n", .{ source_path, err });
            return err;
        };
        const target = try std.fmt.allocPrint(arena, "assets/{s}", .{name});
        try writeInDir(io, arena, out_dir, target, bytes);
        report.bytes += bytes.len;
    }

    // Search is for readers: the internals (design notes, ADRs, task sheets) are deliberately not
    // indexed, and the API reference is indexed down to the individual declaration.
    var search_list: std.ArrayListUnmanaged(site.SearchEntry) = .empty;
    for (rendered) |page| {
        if (std.mem.eql(u8, page.group, internals_group)) continue;
        try search_list.append(arena, .{ .href = page.href, .title = page.title, .group = page.group, .text = page.document.plain });
    }
    for (api.pages) |page| {
        try search_list.append(arena, .{ .href = page.href, .title = page.title, .group = "API", .text = page.plain });
    }
    for (api.packages) |pkg| {
        for (pkg.modules) |module| {
            for (module.decls) |decl| {
                try search_list.append(arena, .{
                    .href = try std.fmt.allocPrint(arena, "docs/api/{s}/{s}.html#{s}", .{ pkg.spec.name, module.slug, decl.name }),
                    .title = try std.fmt.allocPrint(arena, "{s}.{s}", .{ module.slug, decl.name }),
                    .group = "API",
                    .text = try apidoc.firstParagraph(arena, decl.doc),
                });
            }
        }
    }
    const search_entries = search_list.items;
    const index_js = try site.renderSearchIndex(arena, search_entries);
    try writeInDir(io, arena, out_dir, "assets/search-index.js", index_js);
    report.bytes += index_js.len;

    // 6. The nine framework demos, published under `examples/frameworks/<name>/`.
    if (publish_demos) {
        report.demo_files += try publishDemos(arena, io, out_dir);
        if (report.demo_files > 0) report.bytes += 1; // the generated index page
    }

    // 5b. The demos and the templates reference assets that the Markdown link check cannot see
    //     (`<link href>`, `<script src>`, `url(…)`), so every emitted page is verified against the
    //     files that were actually written. A 404 on Pages is a build failure, not a surprise.
    report.assets = try verifyAssets(arena, io, out_dir);

    return report;
}

const repo_blob_base = "https://github.com/umiturtle/Z-Ts/blob/main/";
const repo_tree_base = "https://github.com/umiturtle/Z-Ts/tree/main/";

/// A path that exists in the working tree, as a file (`blob`) or a directory (`tree`).
const RepoPath = enum { missing, file, directory };

fn repoPathKind(io: Io, path: []const u8) RepoPath {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return .missing;
    return if (stat.kind == .directory) .directory else .file;
}

/// Renders one source file into `out` (no link rewrites).
fn renderInto(arena: Allocator, cwd: Io.Dir, io: Io, out: anytype) !void {
    try renderIntoWithRewrites(arena, cwd, io, out, &.{});
}

fn renderIntoWithRewrites(arena: Allocator, cwd: Io.Dir, io: Io, out: anytype, rewrites: []const markdown.Rewrite) !void {
    const bytes = cwd.readFileAlloc(io, out.source, arena, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("docsite: cannot read {s}: {t}\n", .{ out.source, err });
        return err;
    };

    const document = try markdown.render(arena, bytes, .{
        .page = out.href,
        .rewrites = rewrites,
    });

    var toc_list: std.ArrayListUnmanaged(markdown.Heading) = .empty;
    for (document.headings) |heading| {
        if (heading.level == 2 or heading.level == 3) try toc_list.append(arena, heading);
    }

    out.title = try pageTitle(arena, document.headings, out.source);
    out.document = document;
    out.toc = try toc_list.toOwnedSlice(arena);
}

const demo_root = "examples/gallery/src/web/fw";
const demo_fonts = "examples/gallery/src/web/fonts";
const demo_prefix = "examples/frameworks/";

/// Copies every committed framework build into the site (with absolute URLs rewritten) and writes
/// the demo index. Returns the number of files written; `0` when the gallery is not checked out.
fn publishDemos(arena: Allocator, io: Io, out_dir: Io.Dir) !usize {
    const cwd = Io.Dir.cwd();
    const root = cwd.openDir(io, demo_root, .{ .iterate = true }) catch return 0;
    defer root.close(io);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        // Only the top-level directories are demos (`react/`, `sveltekit/`, …).
        if (entry.kind != .directory) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
        try names.append(arena, try arena.dupe(u8, entry.path));
    }
    if (names.items.len == 0) return 0;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var files: usize = 0;
    for (names.items) |name| {
        const source = try std.fmt.allocPrint(arena, "{s}/{s}", .{ demo_root, name });
        const copied = demos.copyDemo(arena, io, source, name, out_dir, demo_prefix, .{}) catch |err| {
            std.debug.print("docsite: cannot publish demo {s}: {t}\n", .{ name, err });
            return err;
        };
        files += copied.files;
    }

    const fonts = demos.copyFonts(arena, io, demo_fonts, out_dir, demo_prefix) catch |err| {
        std.debug.print("docsite: cannot publish the demo fonts: {t}\n", .{err});
        return err;
    };
    files += fonts.files;

    const index_html = try demos.renderIndex(arena, names.items);
    try writeInDir(io, arena, out_dir, demo_prefix ++ "index.html", index_html);
    files += 1;
    return files;
}

const Section = struct { dir: []const u8, entries: []const site.DirectoryEntry };

/// Groups rendered pages by their directory and builds the teaser list for each section page.
fn buildSectionIndexes(arena: Allocator, rendered: anytype) ![]const Section {
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    for (rendered) |page| {
        const dir = page.href[0 .. std.mem.lastIndexOfScalar(u8, page.href, '/') orelse 0];
        if (dir.len == 0) continue;
        var known = false;
        for (dirs.items) |existing| if (std.mem.eql(u8, existing, dir)) {
            known = true;
        };
        if (!known) try dirs.append(arena, dir);
    }
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    const sections = try arena.alloc(Section, dirs.items.len);
    for (dirs.items, sections) |dir, *section| {
        var entries: std.ArrayListUnmanaged(site.DirectoryEntry) = .empty;
        for (rendered) |page| {
            const page_dir = page.href[0 .. std.mem.lastIndexOfScalar(u8, page.href, '/') orelse 0];
            if (!std.mem.eql(u8, page_dir, dir)) continue;
            try entries.append(arena, .{
                .href = page.href,
                .title = page.title,
                .summary = teaser(page.document.plain, page.title),
            });
        }
        section.* = .{ .dir = dir, .entries = try entries.toOwnedSlice(arena) };
    }
    return sections;
}

/// The first paragraph of a page, minus the repeated title (the H1 is already the link text).
fn teaser(plain: []const u8, title: []const u8) []const u8 {
    var text = plain;
    if (std.mem.startsWith(u8, text, title)) text = std.mem.trimStart(u8, text[title.len..], " ");
    return truncateChars(text, 120);
}

/// First `max` characters of `text`, cut on a UTF-8 boundary and without newlines.
fn truncateChars(text: []const u8, max: usize) []const u8 {
    var out: usize = 0;
    var count: usize = 0;
    while (out < text.len and count < max) : (count += 1) {
        out += 1;
        while (out < text.len and (text[out] & 0xC0) == 0x80) out += 1;
    }
    const slice = text[0..out];
    return if (slice.len == text.len) slice else std.mem.trimEnd(u8, slice, " ");
}

/// Walks the produced tree and checks that every relative `src=`/`href=` target exists.
fn verifyAssets(arena: Allocator, io: Io, out_dir: Io.Dir) !usize {
    var checked: usize = 0;
    var missing: std.ArrayListUnmanaged([]const u8) = .empty;

    // Collect first, then read: a directory iterator and file reads on the same handle do not mix
    // (the walker seeks its descriptor to 0 on every `next`).
    var pages: std.ArrayListUnmanaged([]const u8) = .empty;
    var walker = try out_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".html")) continue;
        try pages.append(arena, try arena.dupe(u8, entry.path));
    }

    for (pages.items) |page| {
        const html = try out_dir.readFileAlloc(io, page, arena, .limited(4 * 1024 * 1024));

        var cursor: usize = 0;
        while (nextAssetUrl(html, &cursor)) |url| {
            if (url.len == 0 or url[0] == '#') continue;
            if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://") or
                std.mem.startsWith(u8, url, "mailto:") or std.mem.startsWith(u8, url, "data:") or
                std.mem.startsWith(u8, url, "//")) continue;

            // Nuxt's static export preloads `/_payload.json`, which `nuxt generate` does not emit;
            // the page still renders from the SSR'd HTML (documented in examples/frameworks).
            if (std.mem.endsWith(u8, url, "_payload.json") or std.mem.indexOf(u8, url, "_payload.json?") != null) continue;

            checked += 1;
            const resolved = try site.resolveRelative(arena, page, url);
            if (out_dir.statFile(io, resolved, .{})) |_| {} else |_| {
                try missing.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ page, url }));
            }
        }
    }

    if (missing.items.len > 0) {
        std.debug.print("docsite: {d} asset URL(s) point nowhere\n", .{missing.items.len});
        for (missing.items[0..@min(missing.items.len, 20)]) |line| {
            std.debug.print("  {s}\n", .{line});
        }
        return error.BrokenAssets;
    }
    return checked;
}

/// Yields the value of the next `src="…"` / `href="…"` attribute in `html`.
fn nextAssetUrl(html: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < html.len) {
        const rest = html[cursor.*..];
        const at_src = std.mem.indexOf(u8, rest, "src=\"");
        const at_href = std.mem.indexOf(u8, rest, "href=\"");
        var found: ?usize = null;
        var consume: usize = 0;
        if (at_src) |offset| {
            found = offset;
            consume = "src=\"".len;
        }
        if (at_href) |offset| {
            if (found == null or offset < found.?) {
                found = offset;
                consume = "href=\"".len;
            }
        }
        const start = found orelse return null;
        const value_start = cursor.* + start + consume;
        const end = std.mem.findScalarPos(u8, html, value_start, '"') orelse return null;
        cursor.* = end + 1;
        return html[value_start..end];
    }
    return null;
}

fn collectSources(arena: Allocator, io: Io) ![]const Source {
    var list: std.ArrayListUnmanaged(Source) = .empty;
    try list.append(arena, .{ .path = "README.md", .group = "はじめに" });
    try list.append(arena, .{ .path = "AGENTS.md", .group = "はじめに" });

    const cwd = Io.Dir.cwd();
    const docs_dir = cwd.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        std.debug.print("docsite: cannot open docs/: {t}\n", .{err});
        return err;
    };
    defer docs_dir.close(io);

    var walker = try docs_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const full = try std.fmt.allocPrint(arena, "docs/{s}", .{entry.path});
        try list.append(arena, .{ .path = full, .group = groupFor(full) });
    }

    // Example READMEs are part of the public documentation surface.
    for ([_][]const u8{ "counter", "gallery", "c_embed", "frameworks" }) |example| {
        const path = try std.fmt.allocPrint(arena, "examples/{s}/README.md", .{example});
        // Missing examples are simply not part of the sidebar (no error: the corpus evolves).
        const bytes = cwd.readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch continue;
        _ = bytes;
        try list.append(arena, .{ .path = path, .group = "サンプル" });
    }

    std.mem.sort(Source, list.items, {}, struct {
        fn lessThan(_: void, a: Source, b: Source) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    return list.toOwnedSlice(arena);
}

/// Design notes, ADRs, task sheets, the roadmap and the CI/environment notes. They are the
/// project's memory, not the reader's manual: they stay published (other pages link to them) but
/// they are collapsed into a single sidebar entry, served behind an "内部資料" banner, and kept out
/// of the search index. The landing point is [`internals_href`].
const internals_group = "内部資料";
const internals_href = "docs/internals/index.html";

fn groupFor(path: []const u8) []const u8 {
    // `tauri-internals.md` is an implementation autopsy — it belongs with the design notes even
    // though it lives in `docs/reference/`.
    if (std.mem.eql(u8, path, "docs/reference/tauri-internals.md")) return internals_group;
    if (std.mem.eql(u8, path, "AGENTS.md")) return internals_group;
    if (std.mem.startsWith(u8, path, "docs/tasks/")) return internals_group;
    if (std.mem.startsWith(u8, path, "docs/decisions/")) return internals_group;
    if (std.mem.startsWith(u8, path, "docs/architecture/")) return internals_group;
    if (std.mem.startsWith(u8, path, "docs/roadmap/")) return internals_group;
    if (std.mem.startsWith(u8, path, "docs/environment/")) return internals_group;
    if (std.mem.startsWith(u8, path, "docs/reference/")) return "ガイド";
    if (std.mem.startsWith(u8, path, "docs/guides/")) return "ガイド";
    if (std.mem.startsWith(u8, path, "docs/INDEX.md")) return "はじめに";
    if (std.mem.startsWith(u8, path, "examples/")) return "サンプル";
    return "はじめに";
}

const group_order = [_][]const u8{ "はじめに", "ガイド", "API", "サンプル", internals_group };

fn buildGroups(arena: Allocator, rendered: anytype, packages: []const apidoc.Package) ![]const site.Group {
    var groups: std.ArrayListUnmanaged(site.Group) = .empty;
    for (group_order) |heading| {
        var entries: std.ArrayListUnmanaged(site.NavEntry) = .empty;

        if (std.mem.eql(u8, heading, "API")) {
            try entries.append(arena, .{ .href = "docs/api/index.html", .title = "全体索引（A–Z）", .source = "src/" });
            for (packages) |pkg| {
                try entries.append(arena, .{
                    .href = try std.fmt.allocPrint(arena, "docs/api/{s}/index.html", .{pkg.spec.name}),
                    .title = pkg.spec.name,
                    .source = pkg.spec.root,
                });
            }
        } else if (std.mem.eql(u8, heading, internals_group)) {
            // One entry, not thirty: the whole point is that the sidebar stays reader-facing.
            try entries.append(arena, .{
                .href = internals_href,
                .title = "設計メモ・ADR・タスク",
                .source = "docs/",
            });
        } else {
            for (rendered) |page| {
                if (!std.mem.eql(u8, page.group, heading)) continue;
                try entries.append(arena, .{
                    .href = page.href,
                    .title = page.title,
                    .source = page.source,
                });
            }
        }

        if (entries.items.len == 0) continue;
        try groups.append(arena, .{ .heading = heading, .entries = try entries.toOwnedSlice(arena) });
    }
    return groups.toOwnedSlice(arena);
}

fn htmlPath(arena: Allocator, source_path: []const u8) ![]const u8 {
    const stem = source_path[0 .. source_path.len - 3]; // strip `.md`
    return std.fmt.allocPrint(arena, "{s}.html", .{stem});
}

fn pageTitle(arena: Allocator, headings: []const markdown.Heading, source_path: []const u8) ![]const u8 {
    for (headings) |heading| {
        if (heading.level == 1) return heading.text;
    }
    // Fall back to the file name so the sidebar always has something readable.
    const base = std.fs.path.basename(source_path);
    return arena.dupe(u8, base[0 .. base.len - 3]);
}

const ApiSite = struct {
    pages: []const apidoc.Page,
    packages: []const apidoc.Package,
    decl_count: usize,
};

/// Scans every package's import graph and renders the reference. A failure here fails the build:
/// an API page that silently disappears is worse than a red CI run.
fn buildApiPages(arena: Allocator, io: Io) !ApiSite {
    const packages = try arena.alloc(apidoc.Package, apidoc.packages.len);
    for (apidoc.packages, 0..) |spec, i| packages[i] = try apidoc.collectPackage(arena, io, spec);

    var decl_count: usize = 0;
    for (packages) |pkg| decl_count += apidoc.coverageOf(pkg).total;

    return .{
        .pages = try apidoc.buildPages(arena, packages),
        .packages = packages,
        .decl_count = decl_count,
    };
}

const InternalsSection = struct { heading: []const u8, prefix: []const u8 };

const internals_sections = [_]InternalsSection{
    .{ .heading = "アーキテクチャ（設計メモ）", .prefix = "docs/architecture/" },
    .{ .heading = "設計判断（ADR）", .prefix = "docs/decisions/" },
    .{ .heading = "ロードマップ", .prefix = "docs/roadmap/" },
    .{ .heading = "タスクシート", .prefix = "docs/tasks/" },
    .{ .heading = "環境・CI", .prefix = "docs/environment/" },
};

/// The one page that lists everything the sidebar deliberately stopped showing, with teasers so it
/// stays navigable. Every entry keeps working — this de-emphasises the internals, it does not hide
/// them.
/// Shown at the top of every internal page: keeps the "this is not the manual" signal visible even
/// when the page is reached from an old link or a search engine.
fn internalsBanner(arena: Allocator, href: []const u8) ![]const u8 {
    const root = try site.rootPrefix(arena, href);
    return std.fmt.allocPrint(
        arena,
        "<p class=\"internal-banner\"><span>内部資料</span> 実装の意図と経緯の記録です。使うためのドキュメントは " ++
            "<a href=\"{s}docs/INDEX.html\">ドキュメント索引</a> / <a href=\"{s}docs/api/index.html\">API リファレンス</a> にあります。</p>\n",
        .{ root, root },
    );
}

fn renderInternalsBody(arena: Allocator, rendered: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("<h1>内部資料</h1>\n<p class=\"api-blurb\">実装の<strong>意図・経緯・作業記録</strong>です。");
    try w.writeAll("「どう使うか」は <a href=\"../INDEX.html\">ドキュメント索引</a> と ");
    try w.writeAll("<a href=\"../api/index.html\">API リファレンス</a> にあります。ここは「なぜそうなっているか」を");
    try w.writeAll("知りたいときだけ読む場所で、サイトのナビゲーションと検索からは意図的に外しています。</p>\n");

    for (internals_sections) |section| {
        var count: usize = 0;
        for (rendered) |page| {
            if (std.mem.startsWith(u8, page.source, section.prefix)) count += 1;
        }
        if (count == 0) continue;

        try w.writeAll("<h2>");
        try writeEscaped(w, section.heading);
        try w.print(" <span class=\"api-count\">{d}</span></h2>\n<ul class=\"internals-list\">\n", .{count});
        for (rendered) |page| {
            if (!std.mem.startsWith(u8, page.source, section.prefix)) continue;
            try w.writeAll("<li><a href=\"");
            try writeEscaped(w, try site.relativeHref(arena, internals_href, page.href));
            try w.writeAll("\">");
            try writeEscaped(w, page.title);
            try w.writeAll("</a>");
            const text = teaser(page.document.plain, page.title);
            if (text.len > 0) {
                try w.writeAll("<p>");
                try writeEscaped(w, text);
                try w.writeAll("</p>");
            }
            try w.writeAll("</li>\n");
        }
        try w.writeAll("</ul>\n");
    }

    // `AGENTS.md` sits at the repository root but is agent-facing like the rest of this page.
    for (rendered) |page| {
        if (!std.mem.eql(u8, page.source, "AGENTS.md")) continue;
        try w.writeAll("<h2>エージェント運用</h2>\n<ul class=\"internals-list\">\n<li><a href=\"");
        try writeEscaped(w, try site.relativeHref(arena, internals_href, page.href));
        try w.writeAll("\">");
        try writeEscaped(w, page.title);
        try w.writeAll("</a><p>新規チャット・記憶リセット直後に読む運用ハブ（開発憲法）。</p></li>\n</ul>\n");
    }

    return out.toOwnedSlice();
}

fn countWords(plain: []const u8) usize {
    var words: usize = 0;
    var in_word = false;
    for (plain) |ch| {
        if (ch < 0x80 and std.ascii.isWhitespace(ch)) {
            if (in_word) words += 1;
            in_word = false;
            continue;
        }
        if (ch >= 0x80) {
            // CJK: every multi-byte character counts as one word.
            if (in_word) words += 1;
            in_word = false;
            words += 1;
            continue;
        }
        in_word = true;
    }
    if (in_word) words += 1;
    return words;
}

fn writeInDir(io: Io, arena: Allocator, dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, sub_path, '/')) |slash| {
        if (slash > 0) try dir.createDirPath(io, sub_path[0..slash]);
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    _ = arena;
}

fn renderLanding(arena: Allocator, groups: []const site.Group, api: ApiSite) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll(
        \\<!doctype html>
        \\<html lang="ja" data-theme="light">
        \\<head>
        \\<meta charset="utf-8" />
        \\<meta name="viewport" content="width=device-width, initial-scale=1" />
        \\<title>Z-Ts — Tauri in Zig</title>
        \\<meta name="description" content="Z-Ts は Tauri v2 の思想を Zig 0.17 で再実装した、6 つの直交パッケージからなるデスクトップ / WebAssembly / SSG ツールキットです。" />
        \\<link rel="stylesheet" href="assets/site.css" />
        \\<script>try{const t=localStorage.getItem("zts-theme");if(t)document.documentElement.dataset.theme=t}catch(e){}</script>
        \\</head>
        \\<body class="landing">
        \\<header class="topbar">
        \\  <a class="brand" href="index.html"><span class="brand-mark">Z</span> Z-Ts <span class="brand-sub">Tauri in Zig</span></a>
        \\  <div class="topbar-actions">
        \\    <a class="gh" href="https://github.com/umiturtle/Z-Ts" target="_blank" rel="noopener">GitHub</a>
        \\    <a class="gh" href="docs/INDEX.html">Docs</a>
        \\    <button class="theme-toggle" type="button" aria-label="テーマ切替" data-theme-toggle>◐</button>
        \\  </div>
        \\</header>
        \\<main class="hero">
        \\  <p class="eyebrow">Zig 0.17 · Tauri v2 互換 · ゼロ C 依存のコア</p>
        \\  <h1>デスクトップも、WebAssembly も、<br />静的サイトも。<span class="accent">1 言語で。</span></h1>
        \\  <p class="lede">Z-Ts は Tauri v2 のプロトコルとプラグインを Zig で再実装したツールキットです。同じアプリコードからネイティブ WebView・ブラウザ Live Preview・静的 SSG の 3 つの成果物を生成し、3 OS で同じピクセルを描きます。</p>
        \\  <div class="cta">
        \\    <a class="button primary" href="docs/guides/getting-started.html">はじめかた（5 分）</a>
        \\    <a class="button" href="docs/api/index.html">API リファレンス</a>
        \\    <a class="button" href="examples/counter/README.html">サンプル</a>
        \\    <a class="button" href="https://github.com/umiturtle/Z-Ts" target="_blank" rel="noopener">ソース</a>
        \\  </div>
        \\  <pre class="code"><code>zig build            # デスクトップ / Live / SSG をまとめて zig-out/ へ
        \\zig build test       # 単体 + 実 TCP E2E + 実 WebAssembly E2E
        \\zig build docs       # このサイト（Markdown → 静的 HTML）</code></pre>
        \\  <section class="cards">
        \\    <article><h2>6 つの直交パッケージ</h2><p><code>zts_foundation</code> / <code>zts_web</code> / <code>zts_rpc</code> / <code>zts_bridge</code> / <code>zts_webview</code> / <code>zts_tauri</code>。使うものだけリンクできます。</p></article>
        \\    <article><h2>3 つの成果物、1 つのコード</h2><p>ネイティブ WebView、SSE 付き Live Preview、サーバ不要の静的サイトを同じソースから。</p></article>
        \\    <article><h2>OS 間で同じピクセル</h2><p>同梱フォントとレイアウト指紋で、Linux / macOS / Windows のスクリーンショットを CI が相互比較します。</p></article>
        \\  </section>
        \\</main>
        \\
    );

    try w.print(
        "<section class=\"cards\"><article><h2>API リファレンス</h2><p><code>src/</code> の公開宣言 {d} 件を、" ++
            "シグネチャ・<code>///</code> ドキュメント・ソース行へのリンクつきで生成しています。</p>" ++
            "<p><a href=\"docs/api/index.html\">全体索引を開く →</a></p></article></section>\n",
        .{api.decl_count},
    );

    try w.writeAll("<footer class=\"landing-footer\"><nav class=\"landing-nav\">");
    for (groups) |group| {
        try w.writeAll("<div><h3>");
        try writeEscaped(w, group.heading);
        try w.writeAll("</h3><ul>");
        const limit = @min(group.entries.len, 8);
        for (group.entries[0..limit]) |entry| {
            try w.writeAll("<li><a href=\"");
            try writeEscaped(w, entry.href);
            try w.writeAll("\">");
            try writeEscaped(w, entry.title);
            try w.writeAll("</a></li>");
        }
        if (group.entries.len > limit) {
            try w.print("<li class=\"more\">ほか {d} 件</li>", .{group.entries.len - limit});
        }
        try w.writeAll("</ul></div>");
    }
    try w.writeAll("</nav></footer>\n");
    try w.writeAll("<script src=\"assets/site.js\"></script>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(ch),
        }
    }
}
