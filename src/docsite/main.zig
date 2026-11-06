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
        group: []const u8,
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
            .group = source.group,
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
        const related = if (std.mem.eql(u8, page.group, internals_group)) "" else try renderRelatedApi(arena, page.href, page.xrefs);
        const body = if (std.mem.eql(u8, page.group, internals_group))
            try std.fmt.allocPrint(arena, "{s}{s}", .{ try internalsBanner(arena, page.href), page.document.html })
        else
            try std.fmt.allocPrint(arena, "{s}{s}", .{ page.document.html, related });
        const nav = neighbors(groups, page.href);
        const html = try site.renderPage(arena, .{
            .title = page.title,
            .active_href = page.href,
            .groups = groups,
            .body = body,
            .toc = page.toc,
            .plain = page.document.plain,
            .kind = pageKind(page.source),
            .source = page.source,
            .crumbs = try buildCrumbs(arena, page.group, page.href, page.title),
            .prev = nav.prev,
            .next = nav.next,
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

    // 5a. Machine-readable companions (P11 in docs/architecture/docs-as-a-product.md):
    // `llms.txt` is the table of contents an agent can read in one request, `llms-full.txt` is the
    // concatenated prose, and `sitemap.xml` is what crawlers expect. All three are generated from
    // the same page list as the sidebar, so they cannot disagree with it.
    try writeInDir(io, arena, out_dir, "llms.txt", try renderLlmsTxt(arena, groups, rendered));
    try writeInDir(io, arena, out_dir, "llms-full.txt", try renderLlmsFull(arena, rendered));
    try writeInDir(io, arena, out_dir, "sitemap.xml", try renderSitemap(arena, written.items));

    // 5a-bis. GitHub Pages serves `404.html` for anything that does not exist. Without it a
    // renamed page loses the reader at a blank screen with no way back.
    {
        const html = try site.renderPage(arena, .{
            .title = "ページが見つかりません",
            .active_href = "",
            .groups = groups,
            .body = try renderNotFoundBody(arena),
            .kind = "home",
        }, "404.html");
        try writeInDir(io, arena, out_dir, "404.html", html);
        report.bytes += html.len;
    }

    // Search is for readers: the internals (design notes, ADRs, task sheets) are deliberately not
    // indexed, and the API reference is indexed down to the individual declaration.
    var search_list: std.ArrayListUnmanaged(site.SearchEntry) = .empty;
    for (rendered) |page| {
        if (std.mem.eql(u8, page.group, internals_group)) continue;
        try search_list.append(arena, .{ .href = page.href, .title = page.title, .group = page.group, .text = page.document.plain });
    }
    for (api.pages) |page| {
        // An internal module page (FFI table, contract test) is generated so old links keep
        // working, but it is not part of the learning surface: indexing it would put
        // `gtk_bindings` in the same result list as `Engine`, which is exactly what the
        // 公開/内部 split exists to prevent.
        if (page.audience == .internal) continue;
        try search_list.append(arena, .{ .href = page.href, .title = page.title, .group = "API", .text = page.plain });
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
fn renderInto(arena: Allocator, cwd: Io.Dir, io: Io, out: anytype, index: *const xref_index.Index) !void {
    try renderIntoWithRewrites(arena, cwd, io, out, &.{}, index);
}

fn renderIntoWithRewrites(arena: Allocator, cwd: Io.Dir, io: Io, out: anytype, rewrites: []const markdown.Rewrite, index: *const xref_index.Index) !void {
    const bytes = cwd.readFileAlloc(io, out.source, arena, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("docsite: cannot read {s}: {t}\n", .{ out.source, err });
        return err;
    };

    var xrefs: std.ArrayListUnmanaged(markdown.Xref) = .empty;
    const document = try markdown.render(arena, bytes, .{
        .page = out.href,
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
    var dangling_anchors: std.ArrayListUnmanaged([]const u8) = .empty;

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
    try list.append(arena, .{ .path = "README.md", .group = "はじめに" });
    // `AGENTS.md` is agent-facing: it belongs to the 内部資料 bucket like the design notes, not to
    // the reader's はじめに. Ask `groupFor` instead of hardcoding, so the sidebar and the search
    // index cannot disagree about it.
    try list.append(arena, .{ .path = "AGENTS.md", .group = groupFor("AGENTS.md") });

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
/// Generated error index. Lives under `docs/reference/` because it is a reference page, not a
/// chapter; the file is produced from `src/**` and has no Markdown source of its own.
const errors_href = "docs/reference/errors.html";
const glossary_href = "docs/glossary.html";

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
    // Operating *this repository* (`./zigw`, CI, the docs site) is a different audience from
    // building an app with the library, so it gets its own sidebar group instead of diluting
    // the guides with contributor-only commands.
    if (std.mem.startsWith(u8, path, "docs/contributing/")) return "開発";
    if (std.mem.startsWith(u8, path, "docs/INDEX.md")) return "はじめに";
    if (std.mem.startsWith(u8, path, "examples/")) return "サンプル";
    return "はじめに";
}

const group_order = [_][]const u8{ "はじめに", "ガイド", "API", "サンプル", "開発", internals_group };

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
            // Generated reference pages ride with the guides: they are read the same way (look
            // something up), but they have no Markdown source to be discovered from.
            if (std.mem.eql(u8, heading, "ガイド")) {
                try entries.append(arena, .{ .href = errors_href, .title = "エラー索引（自動生成）", .source = "src/" });
            }
        }

        if (entries.items.len == 0) continue;
        try groups.append(arena, .{ .heading = heading, .entries = try entries.toOwnedSlice(arena) });
    }
    return groups.toOwnedSlice(arena);
}

/// The page's role, from its path. Deliberately path-based (no front matter to fix up, no tooling
/// to learn): adding `docs/learn/concepts/foo.md` is enough for it to be a concept page.
fn pageKind(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "README.md") or std.mem.eql(u8, path, "docs/INDEX.md")) return "home";
    if (std.mem.startsWith(u8, path, "docs/learn/concepts/")) return "concept";
    if (std.mem.startsWith(u8, path, "docs/learn/tutorial/")) return "tutorial";
    if (std.mem.startsWith(u8, path, "docs/recipes/")) return "recipe";
    if (std.mem.startsWith(u8, path, "docs/errors/")) return "errors";
    if (std.mem.eql(u8, path, "docs/glossary.md")) return "reference";
    if (std.mem.startsWith(u8, path, "docs/reference/")) return "reference";
    if (std.mem.startsWith(u8, path, "docs/guides/migrating")) return "migration";
    if (std.mem.startsWith(u8, path, "docs/guides/")) return "guide";
    if (std.mem.startsWith(u8, path, "examples/")) return "recipe";
    if (std.mem.startsWith(u8, path, "docs/")) return "internals";
    return "home";
}

/// `Z-Ts › ガイド › RPC` — the middle crumb points at the section index the generator wrote for
/// every directory, so it is never a dead end.
fn buildCrumbs(arena: Allocator, group: []const u8, href: []const u8, title: []const u8) ![]const site.Crumb {
    var list: std.ArrayListUnmanaged(site.Crumb) = .empty;
    try list.append(arena, .{ .label = "Z-Ts", .href = "index.html" });
    if (std.mem.lastIndexOfScalar(u8, href, '/')) |slash| {
        const dir = href[0..slash];
        if (dir.len > 0) {
            try list.append(arena, .{
                .label = group,
                .href = try std.fmt.allocPrint(arena, "{s}/index.html", .{dir}),
            });
        }
    }
    try list.append(arena, .{ .label = title });
    return list.toOwnedSlice(arena);
}

/// `Z-Ts › API › zts_rpc › schema` for `docs/api/zts_rpc/schema.html`.
fn apiCrumbs(arena: Allocator, href: []const u8) ![]const site.Crumb {
    var list: std.ArrayListUnmanaged(site.Crumb) = .empty;
    try list.append(arena, .{ .label = "Z-Ts", .href = "index.html" });
    try list.append(arena, .{ .label = "API", .href = "docs/api/index.html" });
    // `docs/api/index.html` itself is the second crumb; do not repeat it as the third.
    if (!std.mem.eql(u8, href, "docs/api/index.html")) {
        const rest = href["docs/api/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const pkg = rest[0..slash];
            try list.append(arena, .{
                .label = pkg,
                .href = try std.fmt.allocPrint(arena, "docs/api/{s}/index.html", .{pkg}),
            });
            const stem = rest[slash + 1 .. rest.len - ".html".len];
            if (!std.mem.eql(u8, stem, "index")) {
                try list.append(arena, .{ .label = stem });
            } else {
                // Drop the trailing duplicate: the package crumb is already the current page.
                _ = list.pop();
                try list.append(arena, .{ .label = pkg });
            }
        }
    }
    return list.toOwnedSlice(arena);
}

/// Previous/next in the sidebar's reading order (the groups are the curriculum, so their order is
/// the only sensible linearisation). 内部資料 is excluded: it is a filing cabinet, not a chapter.
fn neighbors(groups: []const site.Group, href: []const u8) struct { prev: ?site.NavLink, next: ?site.NavLink } {
    var prev: ?site.NavLink = null;
    var found = false;
    for (groups) |group| {
        if (std.mem.eql(u8, group.heading, internals_group)) continue;
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
fn renderRelatedApi(arena: Allocator, page_href: []const u8, xrefs: []const markdown.Xref) ![]const u8 {
    if (xrefs.len == 0) return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("<aside class=\"related\"><h2>このページに出てくる API</h2><ul>");
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
        "<section class=\"cards\"><article><h2>API リファレンス</h2><p>使う人のための公開宣言 {d} 件と、その下の" ++
            "型メンバ {d} 件を、シグネチャ・<code>///</code> ドキュメント・ソース行へのリンクつきで" ++
            "生成しています（FFI 宣言などの内部モジュールは別扱い）。</p>" ++
            "<p><a href=\"docs/api/index.html\">全体索引を開く →</a></p></article></section>\n",
        .{ api.decl_count, api.member_count },
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

const site_url = "https://umiturtle.github.io/Z-Ts/";

/// `llms.txt`: a single request that tells an agent what this site contains and where.
fn renderLlmsTxt(arena: Allocator, groups: []const site.Group, rendered: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("# Z-Ts\n\n");
    try w.writeAll("> Tauri v2 のプロトコルとプラグインを Zig 0.17 で再実装したツールキット。" ++
        "同じアプリコードからネイティブ WebView / Live Preview / 静的 SSG の 3 つを生成する。\n\n");
    try w.writeAll("- 対応: Zig 0.17.0 / Tauri v2（`@tauri-apps/api` を無改変で利用）\n");
    try w.writeAll("- パッケージ: zts_foundation, zts_web, zts_core, zts_rpc, zts_bridge, zts_webview, zts_tauri, zts_wasm, zts_ssg, z_ts\n");
    try w.writeAll("- 全文: llms-full.txt / エラー索引: docs/reference/errors.html\n\n");

    for (groups) |group| {
        if (std.mem.eql(u8, group.heading, internals_group)) continue;
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
    return out.toOwnedSlice();
}

/// `llms-full.txt`: every reader-facing page, in sidebar order, as plain text.
fn renderLlmsFull(arena: Allocator, rendered: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    for (rendered) |page| {
        if (std.mem.eql(u8, page.group, internals_group)) continue;
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

fn renderNotFoundBody(arena: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("<h1>ページが見つかりません</h1>\n");
    try w.writeAll("<p>URL が変わったか、まだ存在しません。検索（<kbd>/</kbd>）か、下の入口から辿ってください。</p>\n");
    try w.writeAll("<ul class=\"notfound\">");
    const links = [_]struct { href: []const u8, label: []const u8 }{
        .{ .href = "index.html", .label = "ホーム" },
        .{ .href = "docs/guides/getting-started.html", .label = "はじめかた（5 分）" },
        .{ .href = "docs/glossary.html", .label = "用語集" },
        .{ .href = "docs/api/index.html", .label = "API リファレンス（A–Z）" },
        .{ .href = "docs/reference/cli.html", .label = "CLI リファレンス" },
        .{ .href = "docs/reference/errors.html", .label = "エラー索引" },
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
        "<a href=\"../guides/troubleshooting.html\">トラブルシューティング</a>、" ++
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
    const internals = internals_group;
    // Root files and the landing pages.
    try std.testing.expectEqualStrings("はじめに", groupFor("README.md"));
    try std.testing.expectEqualStrings("はじめに", groupFor("docs/INDEX.md"));
    // Guides are the front door.
    try std.testing.expectEqualStrings("ガイド", groupFor("docs/guides/using-rpc.md"));
    try std.testing.expectEqualStrings("開発", groupFor("docs/contributing/README.md"));
    try std.testing.expectEqualStrings("ガイド", groupFor("docs/reference/cli.md"));
    try std.testing.expectEqualStrings("サンプル", groupFor("examples/counter/README.md"));
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
        try std.testing.expectEqualStrings(internals, groupFor(path));
    }
}
