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
//! `OK docsite pages=N links=M assets=A api_undoc=0 xref_targets=T xrefs=X errors=E`.
//!
//! The `xref_*` numbers are the anti-drift signal for the cross-reference index: `xref_targets`
//! counts the names the index can resolve (it drops when a rename makes two `Ctx` ambiguous) and
//! `xrefs` counts the links the corpus actually produced (it drops when a guide stops mentioning
//! the API). Both are printed so CI can refuse a regression instead of trusting a review.`

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const markdown = @import("markdown.zig");
const site = @import("site.zig");
const demos = @import("demos.zig");
const apidoc = @import("apidoc.zig");
const xref_index = @import("links.zig");
const paths = @import("paths.zig");
const i18n = @import("i18n.zig");
const learn_path = @import("learn_path.zig");

/// Where a page sits in the sidebar. The enum (rather than a label string) is what lets the same
/// corpus produce a Japanese and an English sidebar without duplicating the file walk.
pub const GroupKey = enum {
    /// Landing spot of the reader's learning path (`docs/learn/<lang>/index.md`).
    learn,
    concepts,
    tutorials,
    /// After the tutorial and before the examples: how to shape commands, state and errors.
    patterns,
    guides,
    /// Hand-written lookup pages (`docs/reference/`, the glossary, the error index).
    reference,
    api,
    samples,
    /// The pre-rewrite Japanese guides, kept as deep dives.
    deep,
    /// Operating the repository itself.
    dev,
    internals,
    /// Published but not listed (the repository README, the docs map).
    hidden,

    pub fn heading(self: GroupKey, lang: i18n.Lang) []const u8 {
        return switch (self) {
            // `buildGroups` overrides this with `path_label`; the fallback keeps `heading()`
            // total for callers that have no allocator (the `llms.txt` writer).
            .learn => switch (lang) {
                .ja => "学習パス",
                .en => "Learning path",
            },
            .concepts => switch (lang) {
                .ja => "概念",
                .en => "Concepts",
            },
            .tutorials => switch (lang) {
                .ja => "チュートリアル",
                .en => "Tutorials",
            },
            .patterns => switch (lang) {
                .ja => "実用パターン",
                .en => "Patterns",
            },
            .guides => switch (lang) {
                .ja => "ガイド",
                .en => "Guides",
            },
            .reference => switch (lang) {
                .ja => "リファレンス",
                .en => "Reference",
            },
            .api => "API",
            .samples => switch (lang) {
                .ja => "サンプル",
                .en => "Examples",
            },
            .deep => switch (lang) {
                .ja => "詳細ガイド（日本語）",
                .en => "Deep dives",
            },
            .dev => switch (lang) {
                .ja => "リポジトリ開発",
                .en => "Repository",
            },
            .internals => switch (lang) {
                .ja => "内部資料",
                .en => "Internals",
            },
            .hidden => "",
        };
    }

    /// The reading order. The English sidebar stops after the guides: everything below is
    /// Japanese-only content that would be noise for an English reader.
    fn order(lang: i18n.Lang) []const GroupKey {
        return switch (lang) {
            .ja => &.{ .learn, .concepts, .tutorials, .patterns, .guides, .reference, .api, .samples, .deep, .dev, .internals },
            .en => &.{ .learn, .concepts, .tutorials, .patterns, .guides, .api },
        };
    }
};

/// One Markdown file of the corpus plus the sidebar group it belongs to.
const Source = struct {
    path: []const u8,
    key: GroupKey,
    lang: i18n.Lang,
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
    /// Public declarations the API reference lists (types and functions, not their members).
    api_decls: usize = 0,
    /// Struct fields and enum cases listed underneath those declarations.
    api_members: usize = 0,
    /// Reader-facing declarations and members with no `///` at all. Reported so CI can refuse a
    /// regression instead of trusting a percentage that a huge internal module could dilute.
    api_undoc: usize = 0,
    /// Declarations inside FFI tables and contract tests (excluded from `api_undoc`).
    api_internal: usize = 0,
    /// Names the cross-reference index can turn into a link (`Engine`, `zts dev`, `error.X`).
    /// Printed so a regression in the index shows up as a number, not as "the docs feel plain".
    xref_targets: usize = 0,
    /// `` `Code` `` spans that were promoted to links across the whole corpus.
    xrefs: usize = 0,
    /// Distinct error names harvested from `error{…}` declarations and `error.Name` uses.
    errors: usize = 0,
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
        "OK docsite pages={d} links={d} assets={d} words={d} bytes={d} demos={d} api_pages={d} api_decls={d} api_members={d} api_undoc={d} api_internal={d} xref_targets={d} xrefs={d} errors={d}\n",
        .{
            report.pages,       report.links,      report.assets,       report.words,
            report.bytes,       report.demo_files, report.api_pages,    report.api_decls,
            report.api_members, report.api_undoc,  report.api_internal, report.xref_targets,
            report.xrefs,       report.errors,
        },
    );
    return 0;
}

pub fn generate(arena: Allocator, io: Io, out_path: []const u8, publish_demos: bool) !SiteReport {
    const cwd = Io.Dir.cwd();

    const sources = try collectSources(arena, io);
    if (sources.len == 0) return error.NoDocuments;

    // 0. The API reference is parsed *first* even though it is written last: it is the source of
    //    truth for the cross-reference index, and every Markdown page links into it while it is
    //    being rendered. Parsing is cheap (no code generation), so the reorder costs nothing.
    const packages = try collectPackages(arena, io);
    const errors = try collectErrors(arena, io);
    var index = try buildLinkIndex(arena, io, packages, errors);

    // 1. Render every document once: the sidebar and the search index need all titles first.
    const Rendered = struct {
        href: []const u8,
        source: []const u8,
        title: []const u8,
        key: GroupKey,
        lang: i18n.Lang,
        /// Site-relative `.html` path of the same page in the other language, when the corpus has
        /// one. `null` for the Japanese-only deep dives and the reference pages.
        alt_href: ?[]const u8,
        document: markdown.Document,
        toc: []const markdown.Heading,
        xrefs: []const markdown.Xref,
    };
    const rendered = try arena.alloc(Rendered, sources.len);

    var report: SiteReport = .{};
    for (sources, rendered) |source, *out| {
        out.* = .{
            .href = try htmlPath(arena, source.path),
            .source = source.path,
            .title = "",
            .key = source.key,
            .lang = source.lang,
            .alt_href = try altHref(arena, io, source.path, source.lang),
            .document = undefined,
            .toc = &.{},
            .xrefs = &.{},
        };
        try renderInto(arena, cwd, io, out, &index);
        report.words += countWords(out.document.plain);
        report.xrefs += out.xrefs.len;
    }

    // 1b. API reference, generated from the Zig sources themselves (`M5-07`). It is built before
    //     the sidebar because the sidebar lists one entry per package.
    const api = try buildApiPages(arena, packages, &index);
    report.xref_targets = index.count();
    report.errors = index.errors;

    // 2. Sidebars: one per language, same corpus. A page always renders inside the sidebar of its
    //    own language, so the English reader never sees a Japanese page title.
    const groups_ja = try buildGroups(arena, .ja, rendered, api.packages);
    const groups_en = try buildGroups(arena, .en, rendered, api.packages);
    const groups = groups_ja;

    // 2b. Section landing pages: `docs/tasks/index.html` lists every task with a one-line teaser,
    //     so a link to `docs/tasks/` (a directory) still works on the published site.
    const sections = try buildSectionIndexes(arena, rendered);

    // 3. Link verification. The site mirrors the repository layout, so a page's relative links
    //    keep working unchanged; the only exceptions are links to files that are *not* part of the
    //    site (`.zig` sources, workflows, C files) — those are pointed at GitHub instead.
    var written: std.ArrayListUnmanaged([]const u8) = .empty;
    try written.append(arena, "index.html");
    try written.append(arena, "en/index.html");
    try written.append(arena, internals_href);
    try written.append(arena, errors_href);
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
            try renderIntoWithRewrites(arena, cwd, io, page, rewrites.items, &index);
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

    // 4. Write the pages. The output tree is rebuilt from scratch: `verifyAssets` walks whatever is
    //    on disk, so a stale page from an earlier generation would either mask a broken link (its
    //    own links are never checked) or invent one (a page pointing at a file that has since been
    //    renamed). Deleting first makes the tree a pure function of the corpus.
    cwd.deleteTree(io, out_path) catch {};
    try cwd.createDirPath(io, out_path);
    const out_dir = try cwd.openDir(io, out_path, .{ .iterate = true });
    defer out_dir.close(io);

    for (rendered) |page| {
        const sidebar = if (page.lang == .en) groups_en else groups_ja;
        const related = if (page.key == .internals) "" else try renderRelatedApi(arena, page.href, page.lang, page.xrefs);
        const body = if (page.key == .internals)
            try std.fmt.allocPrint(arena, "{s}{s}", .{ try internalsBanner(arena, page.href), page.document.html })
        else
            try std.fmt.allocPrint(arena, "{s}{s}", .{ page.document.html, related });
        const nav = neighbors(sidebar, page.href);
        const html = try site.renderPage(arena, .{
            .title = page.title,
            .active_href = page.href,
            .groups = sidebar,
            .body = body,
            .toc = page.toc,
            .plain = page.document.plain,
            .kind = pageKind(page.source),
            .source = page.source,
            .crumbs = try buildCrumbs(arena, page.lang, page.key, page.href, page.title),
            .prev = nav.prev,
            .next = nav.next,
            .lang = page.lang,
            .alt_href = page.alt_href,
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
    for (api.pages, 0..) |page, page_index| {
        const html = try site.renderPage(arena, .{
            .title = page.title,
            .active_href = page.href,
            .groups = groups,
            .body = page.body,
            .toc = page.toc,
            .kind = "api",
            .crumbs = try apiCrumbs(arena, page.href),
            .prev = if (page_index > 0) .{ .title = api.pages[page_index - 1].title, .href = api.pages[page_index - 1].href } else null,
            .next = if (page_index + 1 < api.pages.len) .{ .title = api.pages[page_index + 1].title, .href = api.pages[page_index + 1].href } else null,
        }, page.href);
        try writeInDir(io, arena, out_dir, page.href, html);
        report.pages += 1;
        report.bytes += html.len;
    }
    report.api_pages = api.pages.len;
    report.api_decls = api.decl_count;
    report.api_members = api.member_count;
    report.api_undoc = api.undoc_count;
    report.api_internal = api.internal_count;

    // 4b-bis. The error index: generated from `error{…}` sets, so it cannot list an error the
    // library does not declare. No prose is invented; each entry shows where it is raised.
    {
        const body = try renderErrorsBody(arena, errors);
        const html = try site.renderPage(arena, .{
            .title = "エラー索引",
            .active_href = errors_href,
            .groups = groups,
            .body = body,
            .kind = "errors",
            .crumbs = &.{
                .{ .label = "Z-Ts", .href = "index.html" },
                .{ .label = "リファレンス" },
            },
            .plain = try errorIndexPlain(arena, errors),
        }, errors_href);
        try writeInDir(io, arena, out_dir, errors_href, html);
        report.pages += 1;
        report.bytes += html.len;
    }

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

    // 5. Two landing pages (ja at `/`, en at `/en/`), same generator, same content map.
    for ([_]i18n.Lang{ .ja, .en }) |lang| {
        const landing = try renderLanding(arena, lang, if (lang == .en) groups_en else groups_ja, api, errors.len);
        const path = if (lang == .en) "en/index.html" else "index.html";
        try writeInDir(io, arena, out_dir, path, landing);
        report.bytes += landing.len;
        report.pages += 1;
    }

    try writeInDir(io, arena, out_dir, ".nojekyll", "");

    const assets = [_][]const u8{ "site.css", "site.js", "favicon.svg" };
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

    // 5a. Machine-readable companions (P11 in docs/architecture/docs-as-a-product.md):
    // `llms.txt` is the table of contents an agent can read in one request, `llms-full.txt` is the
    // concatenated prose, and `sitemap.xml` is what crawlers expect. All three are generated from
    // the same page list as the sidebar, so they cannot disagree with it.
    try writeInDir(io, arena, out_dir, "llms.txt", try renderLlmsTxt(arena, groups_ja, groups_en, rendered));
    try writeInDir(io, arena, out_dir, "llms-full.txt", try renderLlmsFull(arena, rendered));
    try writeInDir(io, arena, out_dir, "sitemap.xml", try renderSitemap(arena, written.items));

    // 5a-bis. GitHub Pages serves `404.html` for anything that does not exist. Without it a
    // renamed page loses the reader at a blank screen with no way back.
    {
        const html = try site.renderPage(arena, .{
            .title = i18n.strings(.ja).not_found_title,
            .active_href = "",
            .groups = groups_ja,
            .body = try renderNotFoundBody(arena, .ja),
            .kind = "home",
            .lang = .ja,
        }, "404.html");
        try writeInDir(io, arena, out_dir, "404.html", html);
        report.bytes += html.len;
    }

    // Search is for readers: the internals (design notes, ADRs, task sheets) are deliberately not
    // indexed, and the API reference is indexed down to the individual declaration.
    var search_list: std.ArrayListUnmanaged(site.SearchEntry) = .empty;
    for (rendered) |page| {
        if (page.key == .internals or page.key == .hidden) continue;
        try search_list.append(arena, .{
            .href = page.href,
            .title = page.title,
            .group = page.key.heading(page.lang),
            .text = page.document.plain,
            .lang = page.lang.code(),
        });
    }
    for (api.pages) |page| {
        // An internal module page (FFI table, contract test) is generated so old links keep
        // working, but it is not part of the learning surface: indexing it would put
        // `gtk_bindings` in the same result list as `Engine`, which is exactly what the
        // 公開/内部 split exists to prevent.
        if (page.audience == .internal) continue;
        try search_list.append(arena, .{ .href = page.href, .title = page.title, .group = "API", .text = page.plain, .lang = "ja" });
    }
    for (api.packages) |pkg| {
        for (pkg.modules) |module| {
            // Internal modules (FFI tables, contract tests) stay out of the reader's search results,
            // exactly like the 内部資料 pages: the index is the learning surface.
            if (module.audience == .internal) continue;
            for (module.decls) |decl| {
                // `mod.webview2_com` is a re-export of an FFI table: the page is hidden, so the
                // declaration must be too, or the search offers a door that the sidebar locked.
                if (apidoc.reexportsInternal(module, pkg, decl)) continue;
                try search_list.append(arena, .{
                    .href = try std.fmt.allocPrint(arena, "docs/api/{s}/{s}.html#{s}", .{ pkg.spec.name, module.slug, decl.name }),
                    .title = try std.fmt.allocPrint(arena, "{s}.{s}", .{ module.slug, decl.name }),
                    .group = "API",
                    .text = try apidoc.firstParagraph(arena, decl.doc),
                    .lang = "ja",
                });
                // Members are searchable in their own right: `title` or `size` has to find
                // `WindowConfig.title`, otherwise the only way in is to already know the type.
                for (decl.members) |member| {
                    if (!isIdent(member.name)) continue;
                    try search_list.append(arena, .{
                        .href = try std.fmt.allocPrint(arena, "docs/api/{s}/{s}.html#{s}.{s}", .{ pkg.spec.name, module.slug, decl.name, member.name }),
                        .title = try std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ module.slug, decl.name, member.name }),
                        .group = "API",
                        .text = try std.fmt.allocPrint(arena, "{s} · {s} のメンバ", .{ member.signature, decl.name }),
                        .lang = "ja",
                    });
                }
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
/// Expands the `<!-- learn-path -->` directive. A line that is *only* the marker is replaced by
/// the step list; the marker mentioned inline (inside backticks, in prose) is left alone, so
/// the docs that describe this mechanism do not expand it. Pages without a marker line are
/// returned untouched (no copy), so the hot path is unchanged.
fn expandDirectives(arena: Allocator, bytes: []const u8, lang: i18n.Lang) ![]const u8 {
    const marker = "<!-- learn-path -->";
    var found = false;
    var probe = std.mem.splitScalar(u8, bytes, '\n');
    while (probe.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), marker)) {
            found = true;
            break;
        }
    }
    if (!found) return bytes;

    const list = try learn_path.markdownList(arena, switch (lang) {
        .ja => .ja,
        .en => .en,
    });

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.writer.writeAll("\n");
        first = false;
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), marker)) {
            // `markdownList` ends each item with a newline; keep the blank line that preceded the
            // marker so the list stays a separate block.
            try out.writer.writeAll(list);
        } else {
            try out.writer.writeAll(line);
        }
    }
    return out.toOwnedSlice();
}

fn renderInto(arena: Allocator, cwd: Io.Dir, io: Io, out: anytype, index: *const xref_index.Index) !void {
    try renderIntoWithRewrites(arena, cwd, io, out, &.{}, index);
}

fn renderIntoWithRewrites(arena: Allocator, cwd: Io.Dir, io: Io, out: anytype, rewrites: []const markdown.Rewrite, index: *const xref_index.Index) !void {
    const bytes = cwd.readFileAlloc(io, out.source, arena, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("docsite: cannot read {s}: {t}\n", .{ out.source, err });
        return err;
    };

    // `<!-- learn-path -->` is the one directive a page may contain: the four beginner steps are
    // expanded from `learn_path.zig`, the same table the step rail renders. One edit to that table
    // moves both, and the links stay relative so the link checker verifies them like any other.
    const content = try expandDirectives(arena, bytes, out.lang);

    var xrefs: std.ArrayListUnmanaged(markdown.Xref) = .empty;
    const document = try markdown.render(arena, content, .{
        .page = out.href,
        .lang = out.lang,
        .rewrites = rewrites,
        .linker = index,
        .xrefs = &xrefs,
    });

    var toc_list: std.ArrayListUnmanaged(markdown.Heading) = .empty;
    for (document.headings) |heading| {
        if (heading.level == 2 or heading.level == 3) try toc_list.append(arena, heading);
    }

    out.title = try pageTitle(arena, document.headings, out.source);
    out.document = document;
    out.toc = try toc_list.toOwnedSlice(arena);
    out.xrefs = try xrefs.toOwnedSlice(arena);
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
    // A directory that already has a hand-written `index.md` keeps it: the reader path
    // (`docs/learn/ja/guides/index.html`) is an argument for reading on, not an alphabetical list,
    // and silently overwriting it would also make the generator's own links point at a page that
    // says something else.
    for (rendered) |page| {
        const dir = page.href[0 .. std.mem.lastIndexOfScalar(u8, page.href, '/') orelse 0];
        if (dir.len == 0) continue;
        if (std.mem.eql(u8, page.title, "")) continue;
        var known = false;
        for (dirs.items) |existing| if (std.mem.eql(u8, existing, dir)) {
            known = true;
        };
        if (known) continue;
        var has_index = false;
        for (rendered) |other| {
            if (other.href.len == dir.len + 11 and std.mem.startsWith(u8, other.href, dir) and
                std.mem.eql(u8, other.href[dir.len..], "/index.html")) has_index = true;
        }
        if (!has_index) try dirs.append(arena, dir);
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
    var dangling_anchors: std.ArrayListUnmanaged([]const u8) = .empty;

    // Collect first, then read: a directory iterator and file reads on the same handle do not mix
    // (the walker seeks its descriptor to 0 on every `next`).
    var pages: std.ArrayListUnmanaged([]const u8) = .empty;
    var walker = try out_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".html")) continue;
        // The walker joins with the platform separator (`docs\page.html` on Windows) while the
        // `href`s in the HTML — and therefore `resolveRelative`'s output — always use `/`. Without
        // this normalisation every cross-page fragment lookup missed on Windows and the anchor
        // check silently passed. Caught by enabling the test at the bottom of this file.
        try pages.append(arena, try normalizeSlashes(arena, entry.path));
    }

    // Pass 1: every `id="…"` of every page, id_list as `\x00id\x00id\x00`, so a fragment lookup is
    // one substring search. This is what makes `[…](../api/zts_rpc/mod.html#Schema)` a checked
    // link rather than a promise.
    var ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    var contents = try arena.alloc([]const u8, pages.items.len);
    for (pages.items, 0..) |page, i| {
        const html = try out_dir.readFileAlloc(io, page, arena, .limited(4 * 1024 * 1024));
        contents[i] = html;

        var id_list: std.ArrayListUnmanaged(u8) = .empty;
        try id_list.append(arena, 0);
        var cursor: usize = 0;
        while (std.mem.find(u8, html[cursor..], "id=\"")) |offset| {
            const start = cursor + offset + "id=\"".len;
            const end = std.mem.findScalarPos(u8, html, start, '"') orelse break;
            try id_list.appendSlice(arena, html[start..end]);
            try id_list.append(arena, 0);
            cursor = end + 1;
        }
        try ids.put(arena, page, try id_list.toOwnedSlice(arena));
    }

    for (pages.items, 0..) |page, i| {
        const html = contents[i];

        var cursor: usize = 0;
        while (nextAssetUrl(html, &cursor)) |url| {
            if (url.len == 0 or url[0] == '#') {
                // Same-page fragment: `#main` and friends must exist too.
                if (url.len > 1 and !hasFragment(ids.get(page) orelse "", url[1..])) {
                    try dangling_anchors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ page, url }));
                }
                continue;
            }
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
                continue;
            }

            // `page.html#anchor` — the anchor has to exist on the target page.
            const hash = std.mem.findScalarPos(u8, url, 0, '#') orelse continue;
            if (hash + 1 >= url.len) continue;
            if (ids.get(resolved)) |id_list| {
                if (!hasFragment(id_list, url[hash + 1 ..])) {
                    try dangling_anchors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ page, url }));
                }
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

    if (dangling_anchors.items.len > 0) {
        std.debug.print("docsite: {d} anchor(s) point at nothing\n", .{dangling_anchors.items.len});
        for (dangling_anchors.items[0..@min(dangling_anchors.items.len, 20)]) |line| {
            std.debug.print("  {s}\n", .{line});
        }
        return error.DanglingAnchors;
    }
    return checked;
}

test "normalizeSlashes turns the Windows walker's separators into href separators" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("docs/page.html", try normalizeSlashes(arena, "docs\\page.html"));
    // POSIX paths are copied, not aliased: the caller owns the result either way.
    const posix = try normalizeSlashes(arena, "docs/page.html");
    try std.testing.expectEqualStrings("docs/page.html", posix);
}

/// `docs\page.html` → `docs/page.html`. Site-relative paths are always `/`-separated.
fn normalizeSlashes(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return arena.dupe(u8, path);
    const out = try arena.dupe(u8, path);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return out;
}

/// `id_list` is `\x00id\x00id\x00`; a fragment matches only as a whole id (`abc` must not match
/// `abc-def`).
fn hasFragment(id_list: []const u8, fragment: []const u8) bool {
    if (id_list.len == 0 or fragment.len == 0) return false;
    var cursor: usize = 0;
    while (std.mem.find(u8, id_list[cursor..], fragment)) |offset| {
        const at = cursor + offset;
        const after = at + fragment.len;
        if (at > 0 and id_list[at - 1] == 0 and after < id_list.len and id_list[after] == 0) return true;
        cursor = at + 1;
    }
    return false;
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
    try list.append(arena, .{ .path = "README.md", .key = .hidden, .lang = .ja });
    // `AGENTS.md` is agent-facing: it belongs to the 内部資料 bucket like the design notes, not to
    // the reader's はじめに. Ask `groupFor` instead of hardcoding, so the sidebar and the search
    // index cannot disagree about it.
    try list.append(arena, .{ .path = "AGENTS.md", .key = groupFor("AGENTS.md"), .lang = .ja });

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
        try list.append(arena, .{
            .path = full,
            .key = groupFor(full),
            .lang = i18n.Lang.fromPath(full) orelse .ja,
        });
    }

    // Example READMEs are part of the public documentation surface.
    for ([_][]const u8{ "counter", "gallery", "c_embed", "frameworks" }) |example| {
        const path = try std.fmt.allocPrint(arena, "examples/{s}/README.md", .{example});
        // Missing examples are simply not part of the sidebar (no error: the corpus evolves).
        const bytes = cwd.readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch continue;
        _ = bytes;
        try list.append(arena, .{ .path = path, .key = .samples, .lang = .ja });
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
/// Generated error index. Lives under `docs/reference/` because it is a reference page, not a
/// chapter; the file is produced from `src/**` and has no Markdown source of its own.
const errors_href = "docs/reference/errors.html";
const glossary_href = "docs/glossary.html";

fn groupFor(path: []const u8) GroupKey {
    // The translated learning tree is grouped by its own folders, and its language comes from the
    // path — `docs/learn/en/concepts/rpc.md` is both a concept page and an English page.
    if (std.mem.startsWith(u8, path, i18n.learn_root)) {
        const rest = path[i18n.learn_root.len..];
        if (std.mem.startsWith(u8, rest, "ja/concepts/") or std.mem.startsWith(u8, rest, "en/concepts/")) return .concepts;
        if (std.mem.startsWith(u8, rest, "ja/tutorials/") or std.mem.startsWith(u8, rest, "en/tutorials/")) return .tutorials;
        if (std.mem.startsWith(u8, rest, "ja/patterns/") or std.mem.startsWith(u8, rest, "en/patterns/")) return .patterns;
        if (std.mem.startsWith(u8, rest, "ja/guides/") or std.mem.startsWith(u8, rest, "en/guides/")) return .guides;
        return .learn;
    }
    // `tauri-internals.md` is an implementation autopsy — it belongs with the design notes even
    // though it lives in `docs/reference/`.
    if (std.mem.eql(u8, path, "docs/reference/tauri-internals.md")) return .internals;
    if (std.mem.eql(u8, path, "AGENTS.md")) return .internals;
    if (std.mem.startsWith(u8, path, "docs/tasks/")) return .internals;
    if (std.mem.startsWith(u8, path, "docs/decisions/")) return .internals;
    if (std.mem.startsWith(u8, path, "docs/architecture/")) return .internals;
    if (std.mem.startsWith(u8, path, "docs/roadmap/")) return .internals;
    if (std.mem.startsWith(u8, path, "docs/environment/")) return .internals;
    if (std.mem.startsWith(u8, path, "docs/reference/")) return .reference;
    if (std.mem.eql(u8, path, "docs/glossary.md")) return .reference;
    // The pre-rewrite guides stay published (internal notes link to them) but they are no longer
    // the front door, so they ride below the new learning path under their own heading.
    if (std.mem.startsWith(u8, path, "docs/guides/")) return .deep;
    if (std.mem.startsWith(u8, path, "docs/contributing/")) return .dev;
    if (std.mem.startsWith(u8, path, "examples/")) return .samples;
    // `README.md` (the repository readme) and `docs/INDEX.md` (the map of the repository) are
    // published and linked, but they are not part of the reader's path.
    return .hidden;
}

/// Page kind, derived from the path. It drives the badge next to the breadcrumbs, and the CSS
/// that colours it — so the taxonomy is visible, not just documented.
fn pageKind(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "README.md")) return "home";
    if (std.mem.eql(u8, path, "docs/INDEX.md")) return "reference";
    if (std.mem.startsWith(u8, path, "docs/learn/")) {
        if (std.mem.indexOf(u8, path, "/concepts/") != null) return "concept";
        if (std.mem.indexOf(u8, path, "/tutorials/") != null) return "tutorial";
        if (std.mem.indexOf(u8, path, "/patterns/") != null) return "pattern";
        if (std.mem.indexOf(u8, path, "/guides/") != null) return "guide";
        return "home";
    }
    if (std.mem.startsWith(u8, path, "docs/recipes/")) return "recipe";
    if (std.mem.eql(u8, path, "docs/glossary.md")) return "reference";
    if (std.mem.startsWith(u8, path, "docs/reference/")) return "reference";
    if (std.mem.startsWith(u8, path, "docs/guides/migrating")) return "migration";
    if (std.mem.startsWith(u8, path, "docs/guides/")) return "deep";
    if (std.mem.startsWith(u8, path, "examples/")) return "recipe";
    if (std.mem.startsWith(u8, path, "docs/")) return "internals";
    return "home";
}

fn buildGroups(arena: Allocator, lang: i18n.Lang, rendered: anytype, packages: []const apidoc.Package) ![]const site.Group {
    var groups: std.ArrayListUnmanaged(site.Group) = .empty;
    for (GroupKey.order(lang)) |key| {
        var entries: std.ArrayListUnmanaged(site.NavEntry) = .empty;

        if (key == .api) {
            try entries.append(arena, .{ .href = "docs/api/index.html", .title = if (lang == .en) "All declarations (A–Z)" else "全体索引（A–Z）", .source = "src/" });
            for (packages) |pkg| {
                try entries.append(arena, .{
                    .href = try std.fmt.allocPrint(arena, "docs/api/{s}/index.html", .{pkg.spec.name}),
                    .title = pkg.spec.name,
                    .source = pkg.spec.root,
                });
            }
        } else if (key == .internals) {
            // One entry, not thirty: the whole point is that the sidebar stays reader-facing.
            try entries.append(arena, .{
                .href = internals_href,
                .title = if (lang == .en) "Design notes · ADRs · tasks" else "設計メモ・ADR・タスク",
                .source = "docs/",
            });
        } else {
            for (rendered) |page| {
                if (page.key != key) continue;
                // A page only appears in a sidebar written in its own language. Japanese deep
                // dives therefore never leak into the English navigation.
                if (page.lang != lang) continue;
                try entries.append(arena, .{
                    .href = page.href,
                    .title = page.title,
                    .source = page.source,
                });
            }
            // Generated reference pages ride with the reference group: they are read the same way
            // (look something up), but they have no Markdown source to be discovered from.
            if (key == .reference) {
                try entries.append(arena, .{ .href = errors_href, .title = if (lang == .en) "Error index (generated)" else "エラー索引（自動生成）", .source = "src/" });
            }
            switch (key) {
                .learn, .concepts, .tutorials, .guides => try orderLearnEntries(arena, lang, &entries),
                else => {},
            }
        }

        if (entries.items.len == 0) continue;
        try groups.append(arena, .{ .heading = try groupHeading(arena, key, lang), .entries = try entries.toOwnedSlice(arena) });
    }
    return groups.toOwnedSlice(arena);
}

/// Sidebar heading. The sections that are also steps of the beginner path carry that step's number
/// and its name from `learn_path.zig`, so the sidebar reads as a numbered path instead of parallel
/// folders. Everything else keeps its plain name.
fn groupHeading(arena: Allocator, key: GroupKey, lang: i18n.Lang) ![]const u8 {
    // The index into `learn_path.steps` — the numbers themselves come from the table, so inserting
    // a chapter renumbers the sidebar by editing one line. `patterns` sits between the tutorial and
    // the guides, which makes the guides step 5. A literal "4 ·" in `GroupKey.heading` is how the
    // guides ended up labelled "4 · 実用パターン" the day the patterns chapter landed.
    const step: ?usize = switch (key) {
        .concepts => 1,
        .tutorials => 2,
        .patterns => 3,
        .guides => 4,
        else => null,
    };
    if (step) |i| {
        const s = learn_path.steps[i];
        const text = s.title.get(switch (lang) {
            .ja => .ja,
            .en => .en,
        });
        return std.fmt.allocPrint(arena, "{d} · {s}", .{ i + 1, text });
    }
    return key.heading(lang);
}

/// Within the first group, the ordered steps come before the alphabetical rest, and each step
/// landing page is numbered — `1 · はじめての Z-Ts` sits right under the hub. Without this the
/// sidebar sorted `concepts/` above `start.md` and a beginner opened the concepts first.
fn orderLearnEntries(arena: Allocator, lang: i18n.Lang, entries: *std.ArrayListUnmanaged(site.NavEntry)) !void {
    const path_lang: learn_path.Lang = switch (lang) {
        .ja => .ja,
        .en => .en,
    };
    const Sort = struct {
        fn rank(source: []const u8) usize {
            // A section index opens its own group: `concepts/index.md` before `concepts/*.md`,
            // and the hub before everything.
            if (std.mem.endsWith(u8, source, "/index.md")) return 0;
            // The numbered path steps follow, in path order …
            if (learn_path.indexOf(source)) |i| return i + 1;
            // … and the rest of a section keeps its alphabetical order.
            return 100;
        }
        fn lessThan(_: void, a: site.NavEntry, b: site.NavEntry) bool {
            const ra = rank(a.source);
            const rb = rank(b.source);
            if (ra != rb) return ra < rb;
            return std.mem.order(u8, a.href, b.href) == .lt;
        }
    };
    std.mem.sort(site.NavEntry, entries.items, {}, Sort.lessThan);

    for (entries.items) |*entry| {
        const idx = learn_path.indexOf(entry.source) orelse continue;
        if (idx != 0) continue;
        // Only the step's own landing page gets the number, not every page inside the section.
        const landing = try learn_path.sourcePath(arena, path_lang, learn_path.steps[idx]);
        if (!std.mem.eql(u8, landing, entry.source)) continue;
        entry.title = try std.fmt.allocPrint(arena, "{d} · {s}", .{ idx + 1, entry.title });
    }
}

fn neighbors(groups: []const site.Group, href: []const u8) struct { prev: ?site.NavLink, next: ?site.NavLink } {
    var prev: ?site.NavLink = null;
    var found = false;
    for (groups) |group| {
        for (group.entries) |entry| {
            if (found) return .{ .prev = prev, .next = .{ .title = entry.title, .href = entry.href } };
            if (std.mem.eql(u8, entry.href, href)) {
                found = true;
            } else {
                prev = .{ .title = entry.title, .href = entry.href };
            }
        }
    }
    return .{ .prev = prev, .next = null };
}

/// 「このページに出てくる API」 — the inverse of the auto-linker. Every guide ends with the list of
/// declarations it just mentioned, so a reader who finished "connecting RPC" has the reference one
/// click away without going through the sidebar.
fn apiCrumbs(arena: Allocator, href: []const u8) ![]const site.Crumb {
    var list: std.ArrayListUnmanaged(site.Crumb) = .empty;
    try list.append(arena, .{ .label = "Z-Ts", .href = "index.html" });
    try list.append(arena, .{ .label = "API", .href = "docs/api/index.html" });
    // `docs/api/index.html` itself is the second crumb; do not repeat it as the third.
    if (!std.mem.eql(u8, href, "docs/api/index.html")) {
        const rest = href["docs/api/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const pkg = rest[0..slash];
            const stem = rest[slash + 1 .. rest.len - ".html".len];
            if (!std.mem.eql(u8, stem, "index")) {
                try list.append(arena, .{
                    .label = pkg,
                    .href = try std.fmt.allocPrint(arena, "docs/api/{s}/index.html", .{pkg}),
                });
                try list.append(arena, .{ .label = stem });
            } else {
                try list.append(arena, .{ .label = pkg });
            }
        }
    }
    return list.toOwnedSlice(arena);
}

fn buildCrumbs(arena: Allocator, lang: i18n.Lang, key: GroupKey, href: []const u8, title: []const u8) ![]const site.Crumb {
    var list: std.ArrayListUnmanaged(site.Crumb) = .empty;
    try list.append(arena, .{ .label = "Z-Ts", .href = if (lang == .en) "en/index.html" else "index.html" });
    if (key != .hidden) {
        try list.append(arena, .{ .label = key.heading(lang) });
    }
    try list.append(arena, .{ .label = title });
    _ = href;
    return list.toOwnedSlice(arena);
}

/// Resolves the `.md` counterpart of a translated page to the `.html` path the site writes.
/// `null` when the page is not part of the translated tree, which is what hides the language
/// switcher on the Japanese-only pages instead of pointing it at a 404.
fn altHref(arena: Allocator, io: Io, source_path: []const u8, lang: i18n.Lang) !?[]const u8 {
    if (i18n.Lang.fromPath(source_path) == null) return null;
    const md = try i18n.alternateHref(arena, source_path, lang.other());
    // The counterpart is only promised when the file is really there; a half-translated tree
    // would otherwise produce a switcher that dead-ends. One byte is enough: the read is an
    // existence probe, not a load.
    _ = Io.Dir.cwd().statFile(io, md, .{}) catch return null;
    return try htmlPath(arena, md);
}

fn renderRelatedApi(arena: Allocator, page_href: []const u8, lang: i18n.Lang, xrefs: []const markdown.Xref) ![]const u8 {
    if (xrefs.len == 0) return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    const title = switch (lang) {
        .ja => "このページに出てくる API",
        .en => "API mentioned on this page",
    };
    try w.print("<aside class=\"related\"><h2>{s}</h2><ul>", .{title});
    var seen: usize = 0;
    outer: for (xrefs) |xref| {
        for (xrefs[0..seen]) |earlier| {
            if (std.mem.eql(u8, earlier.href, xref.href)) continue :outer;
        }
        seen += 1;
        try w.print("<li><a href=\"{s}\"><code>{s}</code></a></li>", .{
            try paths.relativeHref(arena, page_href, xref.href),
            xref.name,
        });
        if (seen >= 24) break;
    }
    try w.writeAll("</ul></aside>\n");
    return out.toOwnedSlice();
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
    /// Declarations of the reader-facing modules (the number the coverage percentage uses).
    decl_count: usize,
    /// Struct fields and enum cases below those declarations. Reported apart from `decl_count` so
    /// the page can say "455 declarations, 1442 members" instead of one inflated total.
    member_count: usize,
    undoc_count: usize,
    /// Declarations of FFI tables and contract tests. Reported separately so a reader-facing number
    /// never hides a hundred `extern` declarations, and CI can still notice when the scan breaks.
    internal_count: usize,
};

/// Scans every package's import graph and renders the reference. A failure here fails the build:
/// an API page that silently disappears is worse than a red CI run.
/// Everything a code span may point at: API declarations, packages/modules, the glossary, the CLI
/// subcommands and the error index.
///
/// The API half is derived from the same parse that renders `docs/api/**`, so it cannot drift. The
/// glossary and the CLI reference are read from the corpus, and the errors come from the `error{…}`
/// sets in `src/**`: that is the part of the index a human would otherwise have to maintain by hand.
fn buildLinkIndex(arena: Allocator, io: Io, packages: []const apidoc.Package, errors: []const ErrorEntry) !xref_index.Index {
    var index = xref_index.Index.init(arena);
    const cwd = Io.Dir.cwd();

    for (packages) |pkg| {
        const pkg_href = try apidoc.packageHref(arena, pkg.spec.name);
        try index.addExact(pkg.spec.name, pkg_href);
        for (pkg.modules) |module| {
            const href = try apidoc.moduleHref(arena, pkg.spec.name, module);
            try index.addExact(try std.fmt.allocPrint(arena, "{s}.{s}", .{ pkg.spec.name, module.slug }), href);
            // `schema` / `ctx` on their own are too generic to claim globally, but a module slug is
            // a useful weak target: it loses only when a declaration has the same spelling.
            try index.addWeak(module.slug, href);
            for (module.decls) |decl| {
                // `@"error"` and friends: a quoted identifier is not a usable `#fragment`, so the
                // index skips it rather than emitting a link the anchor check would reject.
                if (!isIdent(decl.name)) continue;
                const anchor = try std.fmt.allocPrint(arena, "{s}#{s}", .{ href, decl.name });
                try index.addExact(try std.fmt.allocPrint(arena, "{s}.{s}", .{ module.slug, decl.name }), anchor);
                try index.addExact(try std.fmt.allocPrint(arena, "{s}.{s}", .{ pkg.spec.name, decl.name }), anchor);
                // A re-export points at another module's page; letting it claim the bare name would
                // make `Ctx` depend on import order. Only the defining module competes.
                if (!apidoc.isAlias(decl)) try index.addBare(decl.name, anchor);
                for (decl.members) |member| {
                    if (!isIdent(member.name)) continue;
                    try index.addExact(
                        try std.fmt.allocPrint(arena, "{s}.{s}", .{ decl.name, member.name }),
                        try std.fmt.allocPrint(arena, "{s}#{s}.{s}", .{ href, decl.name, member.name }),
                    );
                }
            }
        }
    }

    // Errors: `error.InvalidName` → `docs/reference/errors.html#error.InvalidName`. Registered
    // before the glossary so a capitalised error (`Unsupported`) beats a glossary entry that
    // happens to share the spelling.
    if (errors.len > 0) {
        try index.addExact("error", errors_href);
        for (errors) |entry| {
            const key = try std.fmt.allocPrint(arena, "error.{s}", .{entry.name});
            const href = try std.fmt.allocPrint(arena, "{s}#error.{s}", .{ errors_href, entry.name });
            try index.addExact(key, href);
            try index.addWeak(entry.name, href);
        }
        index.errors = errors.len;
    }

    // Glossary: `### Capability` → `docs/glossary.html#capability`.
    if (cwd.readFileAlloc(io, "docs/glossary.md", arena, .limited(1024 * 1024)) catch null) |bytes| {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "### ")) continue;
            const term = std.mem.trim(u8, line[4..], " \t");
            if (term.len == 0) continue;
            const slug = try markdown.slugify(arena, term);
            const href = try std.fmt.allocPrint(arena, "docs/glossary.html#{s}", .{slug});
            try index.addWeak(term, href);
        }
    }

    // CLI: `## `zts init [dir]`` → link `` `zts init` `` to `docs/reference/cli.html#zts-init-dir`.
    if (cwd.readFileAlloc(io, "docs/reference/cli.md", arena, .limited(1024 * 1024)) catch null) |bytes| {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "## ")) continue;
            const heading = std.mem.trim(u8, std.mem.trim(u8, line[3..], " \t"), "`");
            if (!std.mem.startsWith(u8, heading, "zts ")) continue;
            const slug = try markdown.slugify(arena, std.mem.trim(u8, line[3..], " \t"));
            const href = try std.fmt.allocPrint(arena, "docs/reference/cli.html#{s}", .{slug});
            // `zts init` (first two words) is what guides actually write.
            var words = std.mem.tokenizeScalar(u8, heading, ' ');
            const first = words.next() orelse continue;
            const second = words.next() orelse continue;
            try index.addWeak(try std.fmt.allocPrint(arena, "{s} {s}", .{ first, second }), href);
        }
    }

    return index;
}

pub const ErrorEntry = struct {
    name: []const u8,
    /// Files that declare or mention this name in an `error{…}` body.
    files: []const []const u8,
};

/// Scans `src/**/*.zig` for `error{…}` sets. The list is the compiler's list, which is exactly the
/// point: the error index cannot promise a name the library does not have, and a renamed error
/// breaks the `` `error.Old` `` link in the same build instead of six months later.
fn collectErrors(arena: Allocator, io: Io) ![]const ErrorEntry {
    const cwd = Io.Dir.cwd();
    const src = cwd.openDir(io, "src", .{ .iterate = true }) catch return &.{};
    defer src.close(io);

    const Acc = struct { name: []const u8, files: std.ArrayListUnmanaged([]const u8) = .empty };
    var by_name: std.StringHashMapUnmanaged(*Acc) = .empty;
    var list: std.ArrayListUnmanaged(*Acc) = .empty;

    var walker = try src.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const bytes = src.readFileAlloc(io, entry.path, arena, .limited(1024 * 1024)) catch continue;
        const path = try std.fmt.allocPrint(arena, "src/{s}", .{entry.path});
        var rest = bytes;
        while (std.mem.indexOf(u8, rest, "error{")) |at| {
            rest = rest[at + "error{".len ..];
            const close = std.mem.indexOfScalar(u8, rest, '}') orelse break;
            if (close > 4096) continue; // a prose mention in a comment, not a set
            const body = rest[0..close];
            rest = rest[close..];
            var toks = std.mem.tokenizeAny(u8, body, ", \t\r\n");
            while (toks.next()) |raw| {
                const name = std.mem.trim(u8, raw, " \t");
                if (name.len == 0 or name.len > 48) continue;
                if (!isIdent(name)) continue;
                // Zig error names are PascalCase; lowercase tokens are prose that happened to sit
                // between `error{` and the next `}` (a doc comment, a nested struct literal).
                if (!std.ascii.isUpper(name[0])) continue;
                const entry_ptr = try by_name.getOrPut(arena, name);
                if (!entry_ptr.found_existing) {
                    const acc = try arena.create(Acc);
                    acc.* = .{ .name = name };
                    entry_ptr.value_ptr.* = acc;
                    try list.append(arena, acc);
                }
                const acc = entry_ptr.value_ptr.*;
                var known = false;
                for (acc.files.items) |f| if (std.mem.eql(u8, f, path)) {
                    known = true;
                };
                if (!known) try acc.files.append(arena, path);
            }
        }
    }

    const out = try arena.alloc(ErrorEntry, list.items.len);
    for (list.items, out) |acc, *entry| {
        std.mem.sort([]const u8, acc.files.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        entry.* = .{ .name = acc.name, .files = try acc.files.toOwnedSlice(arena) };
    }
    std.mem.sort(ErrorEntry, out, {}, struct {
        fn lessThan(_: void, a: ErrorEntry, b: ErrorEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    return out;
}

fn isIdent(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    for (text) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn collectPackages(arena: Allocator, io: Io) ![]const apidoc.Package {
    const packages = try arena.alloc(apidoc.Package, apidoc.packages.len);
    for (apidoc.packages, 0..) |spec, i| packages[i] = try apidoc.collectPackage(arena, io, spec);
    return packages;
}

fn buildApiPages(arena: Allocator, packages: []const apidoc.Package, index: *const xref_index.Index) !ApiSite {
    var decl_count: usize = 0;
    var member_count: usize = 0;
    var undoc_count: usize = 0;
    var internal_count: usize = 0;
    for (packages) |pkg| {
        const coverage = apidoc.coverageOf(pkg);
        decl_count += coverage.total;
        member_count += coverage.member_total;
        undoc_count += (coverage.total - coverage.documented) + (coverage.member_total - coverage.member_documented);
        internal_count += coverage.internal_total;
    }

    return .{
        .pages = try apidoc.buildPages(arena, packages, index),
        .packages = packages,
        .decl_count = decl_count,
        .member_count = member_count,
        .undoc_count = undoc_count,
        .internal_count = internal_count,
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

/// The landing page. Two of them exist (`/index.html` and `/en/index.html`) and they are the same
/// generator with a different `Lang`, so the two languages cannot drift apart.
///
/// Shape (P19: the home page is an entrance, not an index):
///   hero → 4 entry points → features → every page, folded away.
fn renderLanding(arena: Allocator, lang: i18n.Lang, groups: []const site.Group, api: ApiSite, error_count: usize) ![]const u8 {
    const str = i18n.strings(lang);
    const prefix: []const u8 = if (lang == .en) "../" else "";
    const learn = if (lang == .en) "docs/learn/en" else "docs/learn/ja";

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;

    try w.print(
        \\<!doctype html>
        \\<html lang="{s}" data-theme="light">
        \\<head>
        \\<meta charset="utf-8" />
        \\<meta name="viewport" content="width=device-width, initial-scale=1" />
        \\<meta name="color-scheme" content="light dark" />
        \\<title>Z-Ts — Tauri in Zig</title>
        \\<meta name="description" content="{s}" />
        \\<link rel="alternate" hreflang="{s}" href="{s}{s}" />
        \\<link rel="stylesheet" href="{s}assets/site.css" />
        \\<link rel="icon" href="{s}assets/favicon.svg" type="image/svg+xml" />
        \\<script>document.documentElement.dataset.js="1";try{{var t=localStorage.getItem("zts-theme");if(t==="light"||t==="dark"){{document.documentElement.dataset.theme=t}}else if(window.matchMedia&&matchMedia("(prefers-color-scheme: dark)").matches){{document.documentElement.dataset.theme="dark"}}}}catch(e){{}}</script>
        \\</head>
        \\<body class="landing" data-root="{s}" data-lang="{s}">
        \\<header class="topbar landing-topbar">
        \\  <a class="brand" href="{s}index.html"><span class="brand-mark">Z</span><span class="brand-name">Z-Ts</span></a>
        \\  <span class="brand-tagline">Tauri in Zig</span>
        \\  <div class="topbar-actions">
        \\    <nav class="langs" aria-label="{s}"><a href="{s}index.html" hreflang="ja"{s}>日本語</a><a href="{s}en/index.html" hreflang="en"{s}>English</a></nav>
        \\    <button class="icon-btn" type="button" aria-label="{s}" data-theme-toggle>
        \\      <svg class="i-sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.2" /><path d="M12 2v2.6M12 19.4V22M2 12h2.6M19.4 12H22M4.9 4.9l1.9 1.9M17.2 17.2l1.9 1.9M19.1 4.9l-1.9 1.9M6.8 17.2l-1.9 1.9" /></svg>
        \\      <svg class="i-moon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5Z" /></svg>
        \\    </button>
        \\    <a class="icon-btn gh" href="https://github.com/umiturtle/Z-Ts" target="_blank" rel="noopener" aria-label="{s}"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48v-1.7c-2.78.6-3.37-1.34-3.37-1.34-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.89 1.53 2.34 1.09 2.91.83.09-.65.35-1.09.63-1.34-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.5 9.5 0 0 1 5 0c1.91-1.29 2.75-1.02 2.75-1.02.55 1.38.2 2.4.1 2.65.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.68-4.57 4.93.36.31.68.92.68 1.85v2.75c0 .27.18.58.69.48A10 10 0 0 0 12 2Z" /></svg></a>
        \\  </div>
        \\</header>
        \\<main class="landing-main">
        \\  <section class="hero">
        \\    <p class="eyebrow"><span class="dot" aria-hidden="true"></span>{s}</p>
        \\    <h1>{s}<br /><span class="accent">{s}</span></h1>
        \\    <p class="lede">{s}</p>
        \\    <div class="cta">
        \\      <a class="button primary" href="{s}{s}/start.html">{s}<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6" /></svg></a>
        \\      <a class="button" href="{s}{s}/tutorials/counter.html">{s}</a>
        \\      <a class="button ghost" href="{s}docs/api/index.html">{s}</a>
        \\      <a class="button ghost" href="https://github.com/umiturtle/Z-Ts/releases/latest" target="_blank" rel="noopener">{s}<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v10m0 0 4-4m-4 4-4-4M5 19h14" /></svg></a>
        \\    </div>
        \\    <p class="hero-meta">{s}</p>
        \\  </section>
        \\  <section class="terminal-card" aria-label="zts">
        \\    <div class="terminal-bar"><span class="t-dot r"></span><span class="t-dot y"></span><span class="t-dot g"></span><span class="terminal-title">zts</span></div>
        \\    <pre class="code"><code><span class="c-cmd">$ zts init my-app</span>
        \\<span class="c-out">zts: created my-app (6 files)</span>
        \\<span class="c-cmd">$ cd my-app &amp;&amp; zts dev</span>
        \\<span class="c-out">zts: my_app — serving web/ at http://127.0.0.1:5173/</span>
        \\<span class="c-cmd">$ zts build</span>
        \\<span class="c-out">zts: building my_app (ReleaseSmall)
        \\zts: built zig-out/bin/my_app</span></code></pre>
        \\  </section>
        \\
    , .{
        lang.code(),                                                        str.landing_lede,
        lang.other().code(),                                                prefix,
        if (lang == .en) "index.html" else "en/index.html",                 prefix,
        prefix,                                                             prefix,
        lang.code(),                                                        prefix,
        str.language,                                                       prefix,
        if (lang == .ja) " class=\"active\" aria-current=\"true\"" else "", prefix,
        if (lang == .en) " class=\"active\" aria-current=\"true\"" else "", str.theme,
        str.github,                                                         str.landing_eyebrow,
        str.landing_title_a,                                                str.landing_title_b,
        str.landing_lede,                                                   prefix,
        learn,                                                              str.landing_cta_start,
        prefix,                                                             learn,
        str.landing_cta_tutorial,                                           prefix,
        str.landing_cta_api,                                                str.landing_cta_download,
        str.landing_meta,
    });

    // ---- the path, before any other choice ------------------------------------
    // Four numbered steps, generated from the same table the per-page rail uses. A newcomer should
    // never have to choose between "concepts" and "tutorial" before seeing what either is.
    try w.print("<section class=\"landing-path\" aria-labelledby=\"path-title\"><div class=\"landing-path-head\"><h2 class=\"section-title\" id=\"path-title\">{s}</h2><p class=\"landing-path-lede\">{s}</p><span class=\"landing-path-total\">{s}</span></div><ol>", .{
        str.landing_path_title,
        str.landing_path_lede,
        // Runtime string (`{d} 分` / `{d} minutes`): substitute rather than `allocPrint`.
        try std.mem.replaceOwned(u8, arena, str.landing_path_total, "{d}", try std.fmt.allocPrint(arena, "{d}", .{learn_path.totalMinutes()})),
    });
    for (learn_path.steps, 0..) |step, step_index| {
        const step_lang: learn_path.Lang = switch (lang) {
            .ja => .ja,
            .en => .en,
        };
        const target = try learn_path.pageHref(arena, step_lang, step);
        try w.print("<li class=\"landing-step\"><a href=\"{s}{s}\"><span class=\"step-num\" aria-hidden=\"true\">{d}</span><span class=\"step-body\"><strong>{s}</strong><span class=\"step-blurb\">{s}</span>", .{
            prefix,
            target,
            step_index + 1,
            step.title.get(step_lang),
            step.blurb.get(step_lang),
        });
        if (step.minutes > 0) {
            try w.print("<span class=\"step-min\">{d} {s}</span>", .{ step.minutes, if (lang == .ja) "分" else "min" });
        }
        try w.writeAll("</span></a></li>");
    }
    try w.writeAll("</ol></section>");

    // ---- four ways in ---------------------------------------------------------
    const Path = struct {
        icon: []const u8,
        title: []const u8,
        blurb: []const u8,
        cta_label: []const u8,
        cta_href: []const u8,
        links: []const []const u8,
    };
    const guides = try std.fmt.allocPrint(arena, "{s}/guides/index.html", .{learn});
    const guide_rpc = try std.fmt.allocPrint(arena, "{s}/guides/rpc.html", .{learn});
    const guide_plugins = try std.fmt.allocPrint(arena, "{s}/guides/plugins.html", .{learn});
    const guide_static = try std.fmt.allocPrint(arena, "{s}/guides/static-site.html", .{learn});
    const guide_package = try std.fmt.allocPrint(arena, "{s}/guides/package.html", .{learn});
    const concept_security = try std.fmt.allocPrint(arena, "{s}/concepts/security.html", .{learn});

    const entry_points = if (lang == .en) [_]Path{
        .{
            .icon = "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
            .title = "Solve a specific problem",
            .blurb = "Commands and types, the seven Tauri plugins, static export, packaging, and the error you just hit.",
            .cta_label = "All guides",
            .cta_href = guides,
            .links = &.{ guide_rpc, guide_plugins, guide_static, guide_package },
        },
        .{
            .icon = "M4 5h16v12H4zM8 21h8M12 17v4",
            .title = "Look a name up",
            .blurb = "Every public declaration, generated from the /// comments, plus a glossary and an index of every error name.",
            .cta_label = "API reference",
            .cta_href = "docs/api/index.html",
            .links = &.{ "docs/api/zts_tauri/index.html", "docs/glossary.html", "docs/reference/errors.html" },
        },
        .{
            .icon = "M6 3v12a3 3 0 0 0 3 3h6M12 3v12M4 21h6M14 21h6",
            .title = "See a working example",
            .blurb = "Nine frameworks drawing the same screen, a three-artefact counter, and a C99 embed — all built in CI.",
            .cta_label = "Examples",
            .cta_href = "examples/frameworks/README.html",
            .links = &.{ "examples/counter/README.html", "examples/c_embed/README.html", "examples/gallery/README.html" },
        },
        .{
            .icon = "M9 12l2 2 4-4M12 3l8 4v6c0 5-3.5 7.5-8 8-4.5-.5-8-3-8-8V7z",
            .title = "Lock it down",
            .blurb = "Capabilities, scopes and CSP: what Z-Ts enforces, what it does not, and how to keep the default deny.",
            .cta_label = "Security",
            .cta_href = concept_security,
            .links = &.{ concept_security, guide_plugins, "docs/api/zts_tauri/index.html" },
        },
    } else [_]Path{
        .{
            .icon = "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
            .title = "困ったことを解決する",
            .blurb = "コマンドと型、7 つのプラグイン、静的サイト、配布物、そして今出ているエラー。",
            .cta_label = "ガイド一覧",
            .cta_href = guides,
            .links = &.{ guide_rpc, guide_plugins, guide_static, guide_package },
        },
        .{
            .icon = "M4 5h16v12H4zM8 21h8M12 17v4",
            .title = "名前から引く",
            .blurb = "全公開宣言（`///` から自動生成）、用語集、そしてエラー名の索引。",
            .cta_label = "API リファレンス",
            .cta_href = "docs/api/index.html",
            .links = &.{ "docs/api/zts_tauri/index.html", "docs/glossary.html", "docs/reference/errors.html" },
        },
        .{
            .icon = "M6 3v12a3 3 0 0 0 3 3h6M12 3v12M4 21h6M14 21h6",
            .title = "動くサンプルを見る",
            .blurb = "9 フレームワークが同じ画面を描くデモ、3 成果物のカウンター、C99 への埋め込み。すべて CI がビルドしています。",
            .cta_label = "サンプル",
            .cta_href = "examples/frameworks/README.html",
            .links = &.{ "examples/counter/README.html", "examples/c_embed/README.html", "examples/gallery/README.html" },
        },
        .{
            .icon = "M9 12l2 2 4-4M12 3l8 4v6c0 5-3.5 7.5-8 8-4.5-.5-8-3-8-8V7z",
            .title = "権限を絞る",
            .blurb = "capability・scope・CSP。Z-Ts が守るもの、守らないもの、既定拒否の維持のしかた。",
            .cta_label = "セキュリティ",
            .cta_href = concept_security,
            .links = &.{ concept_security, guide_plugins, "docs/api/zts_tauri/index.html" },
        },
    };

    try w.print("<section class=\"paths\"><h2 class=\"section-title\">{s}</h2><div class=\"path-grid\">", .{str.landing_paths_title});
    for (entry_points) |entry| {
        try w.writeAll("<article class=\"path\"><span class=\"path-icon\"><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"");
        try writeEscaped(w, entry.icon);
        try w.writeAll("\" /></svg></span><h3>");
        try writeEscaped(w, entry.title);
        try w.writeAll("</h3><p class=\"path-blurb\">");
        try writeEscaped(w, entry.blurb);
        try w.writeAll("</p><ul>");
        for (entry.links) |href| {
            var label: []const u8 = href;
            for (groups) |group| for (group.entries) |nav_entry| {
                if (std.mem.eql(u8, nav_entry.href, href)) label = nav_entry.title;
            };
            try w.print("<li><a href=\"{s}{s}\">{s}</a></li>", .{ prefix, href, label });
        }
        try w.print("</ul><a class=\"path-cta\" href=\"{s}{s}\">{s}<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M5 12h14M13 6l6 6-6 6\" /></svg></a></article>", .{ prefix, entry.cta_href, entry.cta_label });
    }
    try w.writeAll("</div></section>");

    // ---- why ----------------------------------------------------------------
    try w.print("<section class=\"features\"><h2 class=\"section-title\">{s}</h2><div class=\"feature-grid\">", .{str.landing_feature_title});
    const features = [_][2][]const u8{
        .{ str.landing_feature_1_t, str.landing_feature_1_b },
        .{ str.landing_feature_2_t, str.landing_feature_2_b },
        .{ str.landing_feature_3_t, str.landing_feature_3_b },
        .{ str.landing_feature_4_t, str.landing_feature_4_b },
    };
    for (features) |feature| {
        try w.writeAll("<div class=\"feature\"><h3>");
        try writeEscaped(w, feature[0]);
        try w.writeAll("</h3><p>");
        try writeEscaped(w, feature[1]);
        try w.writeAll("</p></div>");
    }
    try w.writeAll("</div>");

    // ---- live numbers, taken from this very build ---------------------------
    // `str.landing_stats_fmt` is runtime data, so the three numbers are substituted by hand.
    var stats: std.Io.Writer.Allocating = .init(arena);
    defer stats.deinit();
    {
        var rest = str.landing_stats_fmt;
        const numbers = [_]usize{ api.decl_count, api.pages.len, error_count };
        var next: usize = 0;
        while (std.mem.indexOf(u8, rest, "{d}")) |at| {
            try stats.writer.writeAll(rest[0..at]);
            try stats.writer.print("{d}", .{numbers[@min(next, numbers.len - 1)]});
            next += 1;
            rest = rest[at + 3 ..];
        }
        try stats.writer.writeAll(rest);
    }
    try w.print("<p class=\"landing-stats\">{s}</p></section>", .{stats.written()});

    // ---- everything else, folded -------------------------------------------
    // The sidebar order *is* the site map, so the folded list is generated from it: a renamed page
    // cannot leave a stale entry here the way a hand-written footer would.
    try w.print("<section class=\"all-pages\"><details><summary>{s}</summary><nav class=\"landing-nav\">", .{str.landing_all_pages});
    for (groups) |group| {
        if (group.entries.len == 0) continue;
        try w.writeAll("<div><h3>");
        try writeEscaped(w, group.heading);
        try w.writeAll("</h3><ul>");
        for (group.entries) |entry| {
            try w.print("<li><a href=\"{s}{s}\">{s}</a></li>", .{ prefix, entry.href, entry.title });
        }
        try w.writeAll("</ul></div>");
    }
    try w.writeAll("</nav></details></section>");
    try w.writeAll("</main>");
    try w.print(
        \\<footer class="footer landing-footer"><span>© Z-Ts — {s}</span><span class="footer-meta"><a href="https://github.com/umiturtle/Z-Ts" target="_blank" rel="noopener">{s}</a></span></footer>
        \\<script src="{s}assets/site.js"></script>
        \\</body>
        \\</html>
        \\
    , .{ str.footer_note, str.github, prefix });
    return out.toOwnedSlice();
}

const site_url = "https://umiturtle.github.io/Z-Ts/";

fn renderLlmsTxt(arena: Allocator, groups_ja: []const site.Group, groups_en: []const site.Group, rendered: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("# Z-Ts\n\n");
    try w.writeAll("> Tauri v2 のプロトコルとプラグインを Zig 0.17 で再実装したツールキット。" ++
        "同じアプリコードからネイティブ WebView / Live Preview / 静的 SSG の 3 つを生成する。\n>\n" ++
        "> A Zig 0.17 reimplementation of the Tauri v2 protocol and plugins. One app source, " ++
        "three artefacts: native WebView, browser Live Preview, static site.\n\n");
    try w.writeAll("- 対応: Zig 0.17.0 / Tauri v2（`@tauri-apps/api` を無改変で利用）\n");
    try w.writeAll("- パッケージ: zts_foundation, zts_web, zts_core, zts_rpc, zts_bridge, zts_webview, zts_tauri, zts_wasm, zts_ssg, z_ts\n");
    try w.writeAll("- 全文 / full text: llms-full.txt / エラー索引: docs/reference/errors.html\n");
    try w.writeAll(
        // The first thing a model should be told is where a human starts, in both languages.
        "- はじめかた / start here: docs/learn/ja/start.html (10 分) · docs/learn/en/start.html (10 min)\n" ++
            "- 学習パス / learning path: docs/learn/ja/index.html · docs/learn/en/index.html\n\n",
    );

    for ([_][2][]const u8{ .{ "日本語", "ja" }, .{ "English", "en" } }, 0..) |lang, lang_index| {
        try w.print("# {s}\n\n", .{lang[0]});
        const groups = if (lang_index == 0) groups_ja else groups_en;
        for (groups) |group| {
            if (std.mem.eql(u8, group.heading, GroupKey.internals.heading(.ja))) continue;
            if (std.mem.eql(u8, group.heading, GroupKey.internals.heading(.en))) continue;
            try w.print("## {s}\n\n", .{group.heading});
            for (group.entries) |entry| {
                // One line per page: the title, then the first sentence of the page itself so the
                // reader (human or model) can decide without fetching it.
                var summary: []const u8 = "";
                for (rendered) |page| {
                    if (!std.mem.eql(u8, page.href, entry.href)) continue;
                    summary = teaser(page.document.plain, page.title);
                }
                if (summary.len > 0) {
                    try w.print("- [{s}]({s}{s}): {s}\n", .{ entry.title, site_url, entry.href, summary });
                } else {
                    try w.print("- [{s}]({s}{s})\n", .{ entry.title, site_url, entry.href });
                }
            }
            try w.writeAll("\n");
        }
    }
    return out.toOwnedSlice();
}

/// `llms-full.txt`: every reader-facing page, in sidebar order, as plain text.
fn renderLlmsFull(arena: Allocator, rendered: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    for (rendered) |page| {
        if (page.key == .internals or page.key == .hidden) continue;
        try w.print("\n\n===== {s} ====\nURL: {s}{s}\n\n", .{ page.title, site_url, page.href });
        try w.writeAll(page.document.plain);
    }
    try w.writeAll("\n");
    return out.toOwnedSlice();
}

fn renderSitemap(arena: Allocator, pages: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.writeAll("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    for (pages) |page| {
        try w.print("  <url><loc>{s}{s}</loc></url>\n", .{ site_url, page });
    }
    try w.writeAll("</urlset>\n");
    return out.toOwnedSlice();
}

fn renderNotFoundBody(arena: Allocator, lang: i18n.Lang) ![]const u8 {
    const s = i18n.strings(lang);
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.print("<h1>{s}</h1>\n<p>{s}</p>\n", .{ s.not_found_title, s.not_found_body });
    try w.writeAll("<ul class=\"notfound\">");
    // Five links, not a menu: two ways back into the path (the first step and its hub), the map of
    // every page, and the dictionary. The 404 used to list six section pages, which asked a lost
    // reader to pick a section before knowing where they were.
    const Link = struct { href: []const u8, label: []const u8 };
    const links: []const Link = if (lang == .en) &.{
        .{ .href = "en/index.html", .label = "Home" },
        .{ .href = "docs/learn/en/start.html", .label = "Your first ten minutes" },
        .{ .href = "docs/learn/en/index.html", .label = "The learning path" },
        .{ .href = "docs/INDEX.html", .label = "Documentation index" },
        .{ .href = "docs/api/index.html", .label = "API reference (A–Z)" },
    } else &.{
        .{ .href = "index.html", .label = "ホーム" },
        .{ .href = "docs/learn/ja/start.html", .label = "はじめての Z-Ts（10 分）" },
        .{ .href = "docs/learn/ja/index.html", .label = "学習パス" },
        .{ .href = "docs/INDEX.html", .label = "ドキュメント索引" },
        .{ .href = "docs/api/index.html", .label = "API リファレンス（A–Z）" },
    };
    for (links) |link| {
        try w.print("<li><a href=\"{s}\">{s}</a></li>", .{ link.href, link.label });
    }
    try w.writeAll("</ul>\n");
    return out.toOwnedSlice();
}

/// The error index body. One `<section>` per name, anchored `error.<Name>` so that
/// `` `error.InvalidName` `` anywhere in the corpus lands here without a redirect table.
fn renderErrorsBody(arena: Allocator, errors: []const ErrorEntry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("<p class=\"api-crumbs\"><a href=\"../api/index.html\">API</a> / <code>error</code></p>\n");
    try w.writeAll("<h1>エラー索引</h1>\n");
    try w.print(
        "<p class=\"api-blurb\">このページは <code>src/**/*.zig</code> の <code>error{{…}}</code> から" ++
            "自動生成しています（{d} 件）。ライブラリが実際に宣言している名前だけを載せるので、" ++
            "「ドキュメントにはあるが存在しないエラー」は起こりません。逆向きも同じで、" ++
            "名前を変えると <code>error.旧名</code> へのリンクが壊れてビルドが落ちます。</p>\n",
        .{errors.len},
    );
    try w.writeAll("<p class=\"api-blurb\">使い方（どのエラーをどう扱うか）は " ++
        "<a href=\"../learn/ja/guides/troubleshooting.html\">トラブルシューティング</a>、" ++
        "API のどこで返るかは各宣言のシグネチャを見てください。</p>\n");

    try w.writeAll("<div class=\"error-grid\">\n");
    for (errors) |entry| {
        try w.print("<section class=\"error-entry\" id=\"error.{s}\">\n", .{entry.name});
        try w.print("<h2><code>error.{s}</code></h2>\n", .{entry.name});
        try w.writeAll("<p class=\"error-files\">");
        for (entry.files, 0..) |file, i| {
            if (i > 0) try w.writeAll(" · ");
            try w.print("<a href=\"https://github.com/umiturtle/Z-Ts/blob/main/{s}\">{s}</a>", .{ file, file });
        }
        try w.writeAll("</p>\n</section>\n");
    }
    try w.writeAll("</div>\n");
    return out.toOwnedSlice();
}

/// Plain text for the search index: the names, so `InvalidName` finds the entry.
fn errorIndexPlain(arena: Allocator, errors: []const ErrorEntry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    for (errors) |entry| try out.writer.print("error.{s} {s} ", .{ entry.name, entry.name });
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

test "hasFragment matches whole ids only" {
    const list = "\x00main\x00abc\x00abc-def\x00";
    try std.testing.expect(hasFragment(list, "main"));
    try std.testing.expect(hasFragment(list, "abc"));
    try std.testing.expect(hasFragment(list, "abc-def"));
    try std.testing.expect(!hasFragment(list, "ab"));
    try std.testing.expect(!hasFragment(list, ""));
    try std.testing.expect(!hasFragment("", "main"));
}

test "verifyAssets explains a dangling anchor" {
    // `walk` needs an iterable handle, otherwise the walker and the file reads fight over the
    // same descriptor (the `BADF` panic documented in docs/environment/arena-and-caching.md).
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "docs");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "index.html",
        .data = "<a href=\"docs/page.html#missing\">x</a><a href=\"docs/page.html#present\">y</a>",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "docs/page.html",
        .data = "<h2 id=\"present\">ok</h2>",
    });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.DanglingAnchors, verifyAssets(arena_state.allocator(), std.testing.io, tmp.dir));
}

test "groupFor keeps the reader-facing sidebar reader-facing" {
    // The new learning path is the front door, and it is grouped by folder.
    try std.testing.expectEqual(GroupKey.learn, groupFor("docs/learn/ja/index.md"));
    try std.testing.expectEqual(GroupKey.concepts, groupFor("docs/learn/ja/concepts/rpc.md"));
    try std.testing.expectEqual(GroupKey.tutorials, groupFor("docs/learn/en/tutorials/counter.md"));
    try std.testing.expectEqual(GroupKey.patterns, groupFor("docs/learn/en/patterns/commands.md"));
    try std.testing.expectEqual(GroupKey.guides, groupFor("docs/learn/en/guides/install.md"));
    // Lookups, samples, and the pre-rewrite guides kept as deep dives.
    try std.testing.expectEqual(GroupKey.reference, groupFor("docs/reference/cli.md"));
    try std.testing.expectEqual(GroupKey.samples, groupFor("examples/counter/README.md"));
    try std.testing.expectEqual(GroupKey.deep, groupFor("docs/guides/using-rpc.md"));
    try std.testing.expectEqual(GroupKey.dev, groupFor("docs/contributing/README.md"));
    // Published but not in the reading path.
    try std.testing.expectEqual(GroupKey.hidden, groupFor("README.md"));
    // Everything about *why* the code looks the way it does is collapsed into one entry.
    for ([_][]const u8{
        "AGENTS.md",
        "docs/architecture/documentation-site.md",
        "docs/decisions/0019-api-reference.md",
        "docs/roadmap/milestones.md",
        "docs/tasks/M5-07-api-reference.md",
        "docs/environment/arena-and-caching.md",
        "docs/reference/tauri-internals.md",
    }) |path| {
        try std.testing.expectEqual(GroupKey.internals, groupFor(path));
    }

    // English sidebars stop after the guides: the Japanese deep dives are not translated.
    try std.testing.expectEqualSlices(GroupKey, &.{ .learn, .concepts, .tutorials, .patterns, .guides, .api }, GroupKey.order(.en));
    try std.testing.expect(std.mem.indexOfScalar(GroupKey, GroupKey.order(.ja), .deep) != null);
}

test "languages are detected from the path, and only there" {
    try std.testing.expectEqual(@as(?i18n.Lang, .ja), i18n.Lang.fromPath("docs/learn/ja/index.md"));
    try std.testing.expectEqual(@as(?i18n.Lang, .en), i18n.Lang.fromPath("docs/learn/en/guides/install.md"));
    try std.testing.expectEqual(@as(?i18n.Lang, null), i18n.Lang.fromPath("docs/guides/using-rpc.md"));
}

test "the learn-path directive expands only on its own line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A marker alone on a line becomes the step list.
    const expanded = try expandDirectives(arena, "# Hub\n\n<!-- learn-path -->\n\nDone.\n", .ja);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "1. **[はじめての Z-Ts](start.html)**") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "<!-- learn-path -->") == null);

    // A marker quoted inline (as the writing guide does) is left verbatim.
    const quoted = "Write `<!-- learn-path -->` on its own line.\n";
    try std.testing.expectEqualStrings(quoted, try expandDirectives(arena, quoted, .en));

    // No marker at all: the input slice is returned as-is, not copied.
    const plain = "# No marker\n";
    const same = try expandDirectives(arena, plain, .ja);
    try std.testing.expect(same.ptr == plain.ptr);
}

test "the sidebar heading of a path section carries its step number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("2 · 仕組みを知る", try groupHeading(arena, .concepts, .ja));
    try std.testing.expectEqualStrings("3 · Build an app", try groupHeading(arena, .tutorials, .en));
    // Every path group is numbered from the same table the rail uses, so the numbers cannot
    // drift when a chapter is inserted. `patterns` is step 4, which makes the guides step 5.
    try std.testing.expectEqualStrings("4 · 実用パターン", try groupHeading(arena, .patterns, .ja));
    try std.testing.expectEqualStrings("5 · Look things up", try groupHeading(arena, .guides, .en));
    try std.testing.expectEqualStrings("学習パス", try groupHeading(arena, .learn, .ja));
    // Lookup groups keep their plain names: they are not steps of the path.
    try std.testing.expectEqualStrings("API", try groupHeading(arena, .api, .ja));
}

test "the first sidebar group opens with the hub, then step 1" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var entries: std.ArrayListUnmanaged(site.NavEntry) = .empty;
    // Deliberately out of order, and with a page that sorts before `index.md` alphabetically.
    try entries.append(arena, .{ .href = "docs/learn/ja/zzz.html", .title = "zzz", .source = "docs/learn/ja/zzz.md" });
    try entries.append(arena, .{ .href = "docs/learn/ja/start.html", .title = "はじめての Z-Ts", .source = "docs/learn/ja/start.md" });
    try entries.append(arena, .{ .href = "docs/learn/ja/index.html", .title = "Z-Ts を学ぶ", .source = "docs/learn/ja/index.md" });
    try orderLearnEntries(arena, .ja, &entries);

    try std.testing.expectEqualStrings("docs/learn/ja/index.html", entries.items[0].href);
    try std.testing.expectEqualStrings("1 · はじめての Z-Ts", entries.items[1].title);
    try std.testing.expectEqualStrings("docs/learn/ja/zzz.html", entries.items[2].href);
}

test "a section index opens its own group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var entries: std.ArrayListUnmanaged(site.NavEntry) = .empty;
    try entries.append(arena, .{ .href = "docs/learn/ja/concepts/security.html", .title = "Security", .source = "docs/learn/ja/concepts/security.md" });
    try entries.append(arena, .{ .href = "docs/learn/ja/concepts/index.html", .title = "概念", .source = "docs/learn/ja/concepts/index.md" });
    try orderLearnEntries(arena, .ja, &entries);

    try std.testing.expectEqualStrings("docs/learn/ja/concepts/index.html", entries.items[0].href);
    try std.testing.expectEqualStrings("docs/learn/ja/concepts/security.html", entries.items[1].href);
}
