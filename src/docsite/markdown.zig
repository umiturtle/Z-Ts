//! `M5-06` documentation site — a self-contained Markdown renderer.
//!
//! The repository docs are the corpus: GFM-ish tables, nested lists, task lists, fenced code with
//! info strings, block quotes, rules and a handful of raw HTML blocks. This module renders exactly
//! that subset (plus the usual inline spans) into HTML and reports the headings/links it saw so the
//! site builder can build a table of contents and *verify* every internal link.
//!
//! Design rules:
//! * `std` only — the doc site is built by `./zigw build docs` on a cold container.
//! * No allocation outside the `arena` the caller passes in, so a page render never leaks.
//! * Everything is a pure function of the input bytes: the same Markdown always produces the same
//!   HTML (that is what makes the link check and the diff in CI meaningful).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `std.Io.Writer.Allocating` reports an allocation failure as `error.WriteFailed`, so the internal
/// helpers declare it alongside `OutOfMemory`; [`render`] narrows it back to `OutOfMemory` (which is
/// what it really means) at the public boundary.
const Error = Allocator.Error || error{WriteFailed};

pub const RenderOptions = struct {
    /// `[x](../tasks/M5-01-build-tools.md)` → `…html` so the rendered site has no dead links.
    rewrite_md_links: bool = true,
    /// Add `target="_blank" rel="noopener"` to absolute `http(s)` links.
    external_blank: bool = true,
    /// Site-relative path of the page being rendered; only used by `rewrites`.
    page: []const u8 = "",
    /// Per-page overrides, e.g. turn `../../src/tauri/fs/scope.zig` into a GitHub blob URL on the
    /// published site (that file is not part of the site itself).
    rewrites: []const Rewrite = &.{},
};

pub const Rewrite = struct {
    page: []const u8,
    href: []const u8,
    to: []const u8,
};

pub const Heading = struct {
    level: u8,
    /// GitHub-compatible slug, unique within the page.
    id: []const u8,
    /// Heading text with the inline markup stripped (`**`/backticks/links resolved).
    text: []const u8,
};

pub const Link = struct {
    href: []const u8,
    text: []const u8,
};

pub const Document = struct {
    html: []const u8,
    headings: []const Heading,
    links: []const Link,
    /// Tag-free text, used for the search index and for word counts.
    plain: []const u8,
};

/// Renders one Markdown document. Every returned slice lives in `arena`.
pub fn render(arena: Allocator, source: []const u8, options: RenderOptions) Allocator.Error!Document {
    var parser: Parser = .{
        .arena = arena,
        .options = options,
        .headings = .empty,
        .links = .empty,
        .slugs = .empty,
    };

    const lines = splitLines(arena, source) catch return error.OutOfMemory;

    var html: std.Io.Writer.Allocating = .init(arena);
    defer html.deinit();
    {
        const out = &html.writer;
        // `Allocating` can only fail with `WriteFailed`, which *is* an allocation failure.
        parser.renderBlocks(out, lines) catch return error.OutOfMemory;
    }

    const rendered = try html.toOwnedSlice();

    return .{
        .html = rendered,
        .headings = try parser.headings.toOwnedSlice(arena),
        .links = try parser.links.toOwnedSlice(arena),
        .plain = plainText(arena, rendered) catch return error.OutOfMemory,
    };
}

fn splitLines(arena: Allocator, source: []const u8) Error![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try list.append(arena, trimmed);
    }
    return list.toOwnedSlice(arena);
}

const Parser = struct {
    arena: Allocator,
    options: RenderOptions,
    headings: std.ArrayListUnmanaged(Heading),
    links: std.ArrayListUnmanaged(Link),
    slugs: std.StringHashMapUnmanaged(usize),

    // ---------------------------------------------------------------- blocks

    fn renderBlocks(self: *Parser, out: *std.Io.Writer, lines: []const []const u8) Error!void {
        var i: usize = 0;
        while (i < lines.len) {
            const line = lines[i];
            if (isBlank(line)) {
                i += 1;
                continue;
            }

            if (fenceOpen(line)) |fence| {
                i = try self.renderCodeFence(out, lines, i, fence);
                continue;
            }

            if (headingOf(line)) |heading| {
                try self.renderHeading(out, heading);
                i += 1;
                continue;
            }

            if (isRule(line)) {
                try out.writeAll("<hr />\n");
                i += 1;
                continue;
            }

            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), ">")) {
                i = try self.renderBlockQuote(out, lines, i);
                continue;
            }

            if (self.renderTable(out, lines, i)) |result| {
                i = try result;
                continue;
            }

            if (listMarker(line) != null) {
                i = try self.renderList(out, lines, i);
                continue;
            }

            if (isRawHtmlBlock(line)) {
                i = try self.renderRawHtml(out, lines, i);
                continue;
            }

            i = try self.renderParagraph(out, lines, i);
        }
    }

    fn renderCodeFence(self: *Parser, out: *std.Io.Writer, lines: []const []const u8, start: usize, fence: Fence) Error!usize {
        const indent = fence.indent;
        var i = start + 1;
        var body: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer body.deinit(self.arena);

        while (i < lines.len) : (i += 1) {
            const line = lines[i];
            if (fenceClose(line, fence)) break;
            // Strip the fence's own indentation so indented fences stay readable.
            const dedented = if (line.len >= indent) line[@min(indent, line.len)..] else line;
            try body.append(self.arena, dedented);
        }
        // Consume the closing fence line itself.
        if (i < lines.len) i += 1;

        const language = std.mem.trim(u8, fence.info, " \t");
        if (language.len > 0) {
            try out.writeAll("<pre class=\"code\"><code class=\"language-");
            try writeEscaped(out, firstWord(language));
            try out.writeAll("\">");
        } else {
            try out.writeAll("<pre class=\"code\"><code>");
        }
        for (body.items, 0..) |line, index| {
            if (index > 0) try out.writeAll("\n");
            try writeEscaped(out, line);
        }
        try out.writeAll("</code></pre>\n");
        return i;
    }

    fn renderHeading(self: *Parser, out: *std.Io.Writer, heading: Entity) Error!void {
        const text = std.mem.trim(u8, heading.text, " \t");
        if (text.len == 0) return;

        const plain = try self.plainInline(text);
        const id = try self.uniqueSlug(plain);
        try self.headings.append(self.arena, .{ .level = heading.level, .id = id, .text = plain });

        try out.print("<h{d} id=\"", .{heading.level});
        try writeEscaped(out, id);
        try out.writeAll("\"><a class=\"anchor\" href=\"#");
        try writeEscaped(out, id);
        try out.writeAll("\" aria-label=\"permalink\"></a>");
        try self.renderInline(out, text);
        try out.print("</h{d}>\n", .{heading.level});
    }

    fn renderBlockQuote(self: *Parser, out: *std.Io.Writer, lines: []const []const u8, start: usize) Error!usize {
        var inner: std.ArrayListUnmanaged([]const u8) = .empty;
        var i = start;
        while (i < lines.len) : (i += 1) {
            const trimmed = std.mem.trimStart(u8, lines[i], " \t");
            if (std.mem.startsWith(u8, trimmed, ">")) {
                var rest = trimmed[1..];
                if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                try inner.append(self.arena, rest);
            } else if (isBlank(lines[i])) {
                // A blank line ends the quote unless the next line continues it.
                if (i + 1 < lines.len and std.mem.startsWith(u8, std.mem.trimStart(u8, lines[i + 1], " \t"), ">")) {
                    try inner.append(self.arena, "");
                    continue;
                }
                break;
            } else break;
        }

        try out.writeAll("<blockquote>\n");
        try self.renderBlocks(out, inner.items);
        try out.writeAll("</blockquote>\n");
        return i;
    }

    fn renderTable(self: *Parser, out: *std.Io.Writer, lines: []const []const u8, start: usize) ?Error!usize {
        if (start + 1 >= lines.len) return null;
        if (!looksLikeTableRow(lines[start])) return null;
        if (!isDelimiterRow(lines[start + 1])) return null;

        const header = try self.splitCells(lines[start]);
        const aligns = try self.parseAlignments(lines[start + 1]);
        if (header.len != aligns.len) return null;

        try out.writeAll("<div class=\"table-wrap\"><table>\n<thead><tr>");
        for (header, aligns) |cell, alignment| {
            try out.writeAll("<th");
            try writeAlignClass(out, alignment);
            try out.writeAll(">");
            try self.renderInline(out, std.mem.trim(u8, cell, " \t"));
            try out.writeAll("</th>");
        }
        try out.writeAll("</tr></thead>\n<tbody>\n");

        var i = start + 2;
        while (i < lines.len and looksLikeTableRow(lines[i])) : (i += 1) {
            const cells = try self.splitCells(lines[i]);
            try out.writeAll("<tr>");
            for (0..aligns.len) |index| {
                const cell = if (index < cells.len) cells[index] else "";
                try out.writeAll("<td");
                try writeAlignClass(out, aligns[index]);
                try out.writeAll(">");
                try self.renderInline(out, std.mem.trim(u8, cell, " \t"));
                try out.writeAll("</td>");
            }
            try out.writeAll("</tr>\n");
        }
        try out.writeAll("</tbody></table></div>\n");
        return i;
    }

    fn renderList(self: *Parser, out: *std.Io.Writer, lines: []const []const u8, start: usize) Error!usize {
        const first = listMarker(lines[start]) orelse unreachable;
        const tag = if (first.ordered) "ol" else "ul";

        try out.print("<{s}", .{tag});
        if (first.ordered and first.number != 1) try out.print(" start=\"{d}\"", .{first.number});
        try out.writeAll(">\n");

        var i = start;
        while (i < lines.len) {
            const marker = listMarker(lines[i]) orelse break;
            if (marker.ordered != first.ordered or marker.indent != first.indent) break;

            // Gather this item: the marker line plus every continuation line indented past it.
            var body: std.ArrayListUnmanaged([]const u8) = .empty;
            var task: ?bool = null;
            var content = marker.rest;
            if (parseTaskBox(content)) |box| {
                task = box.done;
                content = box.rest;
            }
            try body.append(self.arena, content);
            i += 1;

            while (i < lines.len) {
                const line = lines[i];
                if (isBlank(line)) {
                    // Keep blank lines only when the item continues afterwards.
                    var j = i + 1;
                    while (j < lines.len and isBlank(lines[j])) j += 1;
                    if (j < lines.len and leadingSpaces(lines[j]) > marker.indent) {
                        try body.append(self.arena, "");
                        i += 1;
                        continue;
                    }
                    break;
                }
                if (leadingSpaces(line) <= marker.indent and listMarker(line) != null) break;
                if (leadingSpaces(line) <= marker.indent) break;

                try body.append(self.arena, dedent(line, marker.indent + 2));
                i += 1;
            }

            try out.writeAll("<li");
            if (task != null) try out.writeAll(" class=\"task\"");
            try out.writeAll(">");
            if (task) |done| {
                try out.writeAll(if (done)
                    "<input type=\"checkbox\" disabled checked aria-label=\"done\" /> "
                else
                    "<input type=\"checkbox\" disabled aria-label=\"todo\" /> ");
            }
            try self.renderItemBody(out, body.items);
            try out.writeAll("</li>\n");

            // Skip the blank separator lines between the items.
            var k = i;
            while (k < lines.len and isBlank(lines[k])) k += 1;
            if (k < lines.len) {
                if (listMarker(lines[k])) |next| {
                    if (next.ordered == first.ordered and next.indent == first.indent) i = k;
                }
            }
        }
        try out.print("</{s}>\n", .{tag});
        return i;
    }

    /// A single-paragraph item is rendered inline (`<li>text</li>`) so tight lists do not gain
    /// stray `<p>` margins; anything richer goes through the block renderer.
    fn renderItemBody(self: *Parser, out: *std.Io.Writer, body: []const []const u8) Error!void {
        var paragraph_end: usize = 0;
        while (paragraph_end < body.len and !isBlank(body[paragraph_end])) paragraph_end += 1;
        var simple = paragraph_end == body.len;
        for (body) |line| {
            if (listMarker(line) != null or headingOf(line) != null or fenceOpen(line) != null or
                isRule(line) or std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), ">")) simple = false;
        }

        if (simple) {
            try out.writeAll("<span class=\"li-text\">");
            for (body, 0..) |line, index| {
                if (index > 0) try out.writeAll(" ");
                try self.renderInline(out, std.mem.trim(u8, line, " \t"));
            }
            try out.writeAll("</span>");
            return;
        }
        try out.writeAll("\n");
        try self.renderBlocks(out, body);
    }

    fn renderRawHtml(self: *Parser, out: *std.Io.Writer, lines: []const []const u8, start: usize) Error!usize {
        _ = self;
        var i = start;
        while (i < lines.len and !isBlank(lines[i])) : (i += 1) {
            try out.writeAll(lines[i]);
            try out.writeAll("\n");
        }
        return i;
    }

    fn renderParagraph(self: *Parser, out: *std.Io.Writer, lines: []const []const u8, start: usize) Error!usize {
        var i = start;
        var out_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        while (i < lines.len) : (i += 1) {
            const line = lines[i];
            if (isBlank(line)) break;
            if (i > start) {
                if (fenceOpen(line) != null) break;
                if (headingOf(line) != null) break;
                if (isRule(line)) break;
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), ">")) break;
                if (listMarker(line) != null) break;
            }
            try out_lines.append(self.arena, std.mem.trim(u8, line, " \t"));
        }

        try out.writeAll("<p>");
        var previous_broke = false;
        for (out_lines.items, 0..) |line, index| {
            // A trailing `\` forces a hard break; everything else joins with a space.
            if (index > 0 and !previous_broke) try out.writeAll(" ");
            if (std.mem.endsWith(u8, line, "\\")) {
                try self.renderInline(out, line[0 .. line.len - 1]);
                try out.writeAll("<br />");
                previous_broke = true;
            } else {
                try self.renderInline(out, line);
                previous_broke = false;
            }
        }
        try out.writeAll("</p>\n");
        return i;
    }

    // ----------------------------------------------------------------- inline

    fn renderInline(self: *Parser, out: *std.Io.Writer, text: []const u8) Error!void {
        var i: usize = 0;
        while (i < text.len) {
            const ch = text[i];

            if (ch == '\\' and i + 1 < text.len) {
                try writeEscaped(out, text[i + 1 .. i + 2]);
                i += 2;
                continue;
            }

            if (ch == '`') {
                const run = countRun(text, i, '`');
                if (std.mem.indexOfPos(u8, text, i + run, text[i .. i + run])) |end| {
                    const body = text[i + run .. end];
                    try out.writeAll("<code>");
                    try writeEscaped(out, trimCodeSpan(body));
                    try out.writeAll("</code>");
                    i = end + run;
                    continue;
                }
            }

            if (ch == '!' and i + 1 < text.len and text[i + 1] == '[') {
                if (try self.tryLink(out, text, i, true)) |next| {
                    i = next;
                    continue;
                }
            }

            if (ch == '[') {
                if (try self.tryLink(out, text, i, false)) |next| {
                    i = next;
                    continue;
                }
            }

            if (ch == '<') {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '>')) |close| {
                    const inner = text[i + 1 .. close];
                    if (isSafeInlineHtml(inner)) {
                        try out.writeAll(text[i .. close + 1]);
                        i = close + 1;
                        continue;
                    }
                    if (isAutolink(inner)) {
                        try out.writeAll("<a href=\"");
                        try writeEscaped(out, inner);
                        try out.writeAll("\" target=\"_blank\" rel=\"noopener\">");
                        try writeEscaped(out, inner);
                        try out.writeAll("</a>");
                        try self.recordLink(inner, inner);
                        i = close + 1;
                        continue;
                    }
                }
            }

            if (std.mem.startsWith(u8, text[i..], "**") or std.mem.startsWith(u8, text[i..], "__")) {
                const delim = text[i .. i + 2];
                if (std.mem.indexOfPos(u8, text, i + 2, delim)) |end| {
                    if (end > i + 2) {
                        try out.writeAll("<strong>");
                        try self.renderInline(out, text[i + 2 .. end]);
                        try out.writeAll("</strong>");
                        i = end + 2;
                        continue;
                    }
                }
            }

            if (std.mem.startsWith(u8, text[i..], "~~")) {
                if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
                    if (end > i + 2) {
                        try out.writeAll("<del>");
                        try self.renderInline(out, text[i + 2 .. end]);
                        try out.writeAll("</del>");
                        i = end + 2;
                        continue;
                    }
                }
            }

            if (ch == '*' or ch == '_') {
                const run = countRun(text, i, ch);
                if (run == 1) {
                    if (std.mem.indexOfScalarPos(u8, text, i + 1, ch)) |end| {
                        if (end > i + 1 and !std.ascii.isWhitespace(text[i + 1])) {
                            try out.writeAll("<em>");
                            try self.renderInline(out, text[i + 1 .. end]);
                            try out.writeAll("</em>");
                            i = end + 1;
                            continue;
                        }
                    }
                }
            }

            try writeEscaped(out, text[i .. i + 1]);
            i += 1;
        }
    }

    /// `[text](href)` / `![alt](src)` → returns the index just past the closing paren.
    fn tryLink(self: *Parser, out: *std.Io.Writer, text: []const u8, start: usize, image: bool) Error!?usize {
        const open = if (image) start + 1 else start;
        if (open >= text.len or text[open] != '[') return null;

        const close_bracket = findClosingBracket(text, open) orelse return null;
        if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return null;
        const close_paren = std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse return null;

        const label = text[open + 1 .. close_bracket];
        const target = std.mem.trim(u8, text[close_bracket + 2 .. close_paren], " \t");
        if (target.len == 0) return null;

        if (image) {
            try out.writeAll("<img src=\"");
            try writeEscaped(out, target);
            try out.writeAll("\" alt=\"");
            try writeEscaped(out, label);
            try out.writeAll("\" loading=\"lazy\" />");
        } else {
            const href = try self.rewriteHref(target);
            try out.writeAll("<a href=\"");
            try writeEscaped(out, href);
            try out.writeAll("\"");
            if (self.options.external_blank and isExternal(href)) {
                try out.writeAll(" target=\"_blank\" rel=\"noopener\"");
            }
            try out.writeAll(">");
            try self.renderInline(out, label);
            try out.writeAll("</a>");
            try self.recordLink(href, label);
        }
        return close_paren + 1;
    }

    fn rewriteHref(self: *Parser, href: []const u8) Error![]const u8 {
        for (self.options.rewrites) |rule| {
            if (!std.mem.eql(u8, rule.page, self.options.page)) continue;
            if (std.mem.eql(u8, rule.href, href)) return rule.to;
        }
        if (!self.options.rewrite_md_links) return href;
        if (isExternal(href) or href.len == 0 or href[0] == '#') return href;

        const hash_at = std.mem.indexOfScalar(u8, href, '#');
        const path_end = hash_at orelse href.len;
        if (!std.mem.endsWith(u8, href[0..path_end], ".md")) return href;

        return std.fmt.allocPrint(self.arena, "{s}.html{s}", .{ href[0 .. path_end - 3], href[path_end..] });
    }

    fn recordLink(self: *Parser, href: []const u8, label: []const u8) Error!void {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        defer out.deinit();
        try self.renderInline(&out.writer, label);
        const text = try out.toOwnedSlice();
        try self.links.append(self.arena, .{ .href = href, .text = try decodeEntities(self.arena, text) });
    }

    // --------------------------------------------------------------- helpers

    fn uniqueSlug(self: *Parser, text: []const u8) Error![]const u8 {
        const base = try slugify(self.arena, text);
        const entry = try self.slugs.getOrPut(self.arena, base);
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
            return base;
        }
        entry.value_ptr.* += 1;
        return std.fmt.allocPrint(self.arena, "{s}-{d}", .{ base, entry.value_ptr.* });
    }

    /// Renders inline markup away, for slugs and the table of contents.
    fn plainInline(self: *Parser, text: []const u8) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        defer out.deinit();

        var i: usize = 0;
        while (i < text.len) {
            const ch = text[i];
            if (ch == '`') {
                const run = countRun(text, i, '`');
                if (std.mem.indexOfPos(u8, text, i + run, text[i .. i + run])) |end| {
                    try out.writer.writeAll(trimCodeSpan(text[i + run .. end]));
                    i = end + run;
                    continue;
                }
            }
            if ((ch == '*' or ch == '_' or ch == '~') and i + 1 < text.len and text[i + 1] == ch) {
                i += 2;
                continue;
            }
            if (ch == '*' or ch == '_' or ch == '~') {
                i += 1;
                continue;
            }
            if (ch == '\\' and i + 1 < text.len) {
                try out.writer.writeAll(text[i + 1 .. i + 2]);
                i += 2;
                continue;
            }
            if (ch == '[') {
                if (findClosingBracket(text, i)) |close| {
                    if (close + 1 < text.len and text[close + 1] == '(') {
                        if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |paren| {
                            try out.writer.writeAll(try self.plainInline(text[i + 1 .. close]));
                            i = paren + 1;
                            continue;
                        }
                    }
                }
            }
            try out.writer.writeAll(text[i .. i + 1]);
            i += 1;
        }
        const result = try out.toOwnedSlice();
        return std.mem.trim(u8, result, " \t");
    }

    fn splitCells(self: *Parser, line: []const u8) Error![]const []const u8 {
        var cells: std.ArrayListUnmanaged([]const u8) = .empty;
        var trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] == '|') trimmed = trimmed[1..];
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') {
            // Keep a trailing escaped pipe (`\|`) out of the trim.
            if (trimmed.len < 2 or trimmed[trimmed.len - 2] != '\\') trimmed = trimmed[0 .. trimmed.len - 1];
        }

        var start: usize = 0;
        var in_code = false;
        var i: usize = 0;
        while (i < trimmed.len) : (i += 1) {
            const ch = trimmed[i];
            if (ch == '\\' and i + 1 < trimmed.len) {
                i += 1;
                continue;
            }
            if (ch == '`') {
                in_code = !in_code;
                continue;
            }
            if (ch == '|' and !in_code) {
                try cells.append(self.arena, replaceEscapedPipes(self.arena, trimmed[start..i]) catch return error.OutOfMemory);
                start = i + 1;
            }
        }
        try cells.append(self.arena, try replaceEscapedPipes(self.arena, trimmed[start..]));
        return cells.toOwnedSlice(self.arena);
    }

    fn parseAlignments(self: *Parser, line: []const u8) Error![]const Align {
        const cells = try self.splitCells(line);
        const alignments = try self.arena.alloc(Align, cells.len);
        for (cells, alignments) |cell, *alignment| {
            const value = std.mem.trim(u8, cell, " \t");
            const left = value.len > 0 and value[0] == ':';
            const right = value.len > 0 and value[value.len - 1] == ':';
            alignment.* = if (left and right) .center else if (right) .right else if (left) .left else .none;
        }
        return alignments;
    }
};

const Align = enum { none, left, center, right };

fn writeAlignClass(out: *std.Io.Writer, alignment: Align) !void {
    switch (alignment) {
        .none => {},
        .left => try out.writeAll(" style=\"text-align:left\""),
        .center => try out.writeAll(" style=\"text-align:center\""),
        .right => try out.writeAll(" style=\"text-align:right\""),
    }
}

const Fence = struct {
    char: u8,
    length: usize,
    indent: usize,
    info: []const u8,
};

fn fenceOpen(line: []const u8) ?Fence {
    const indent = leadingSpaces(line);
    if (indent > 3) return null;
    const rest = line[indent..];
    if (rest.len < 3) return null;
    const ch = rest[0];
    if (ch != '`' and ch != '~') return null;
    const run = countRun(rest, 0, ch);
    if (run < 3) return null;
    if (ch == '`' and std.mem.indexOfScalar(u8, rest[run..], '`') != null) return null;
    return .{ .char = ch, .length = run, .indent = indent, .info = rest[run..] };
}

fn fenceClose(line: []const u8, fence: Fence) bool {
    const indent = leadingSpaces(line);
    if (indent > 3) return false;
    const rest = line[indent..];
    if (rest.len == 0 or rest[0] != fence.char) return false;
    const run = countRun(rest, 0, fence.char);
    if (run < fence.length) return false;
    return std.mem.trim(u8, rest[run..], " \t").len == 0;
}

const Entity = struct { level: u8, text: []const u8 };

fn headingOf(line: []const u8) ?Entity {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    var level: u8 = 0;
    while (level < trimmed.len and trimmed[level] == '#') : (level += 1) {}
    if (level == 0 or level > 6) return null;
    if (level >= trimmed.len) return null;
    if (trimmed[level] != ' ') return null;

    var text = std.mem.trim(u8, trimmed[level..], " \t");
    // Optional closing hashes (`## Title ##`).
    var end = text.len;
    while (end > 0 and text[end - 1] == '#') end -= 1;
    if (end != text.len) {
        const candidate = std.mem.trimEnd(u8, text[0..end], " \t");
        if (candidate.len > 0) text = candidate;
    }
    return .{ .level = level, .text = text };
}

fn isRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    const ch = trimmed[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (trimmed) |c| if (c != ch) return false;
    return true;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn dedent(line: []const u8, amount: usize) []const u8 {
    var drop: usize = 0;
    while (drop < amount and drop < line.len and line[drop] == ' ') : (drop += 1) {}
    return line[drop..];
}

fn countRun(text: []const u8, start: usize, ch: u8) usize {
    var run: usize = 0;
    while (start + run < text.len and text[start + run] == ch) : (run += 1) {}
    return run;
}

fn trimCodeSpan(body: []const u8) []const u8 {
    if (body.len >= 2 and body[0] == ' ' and body[body.len - 1] == ' ') return body[1 .. body.len - 1];
    return body;
}

fn firstWord(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
    return text[0..end];
}

const ListMarker = struct {
    indent: usize,
    ordered: bool,
    number: usize,
    rest: []const u8,
};

fn listMarker(line: []const u8) ?ListMarker {
    const indent = leadingSpaces(line);
    if (indent > 8) return null;
    if (indent >= line.len) return null;

    const rest = line[indent..];
    if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        return .{ .indent = indent, .ordered = false, .number = 0, .rest = rest[2..] };
    }

    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) : (digits += 1) {}
    if (digits == 0 or digits + 1 >= rest.len) return null;
    if (rest[digits] != '.' or rest[digits + 1] != ' ') return null;
    const number = std.fmt.parseInt(usize, rest[0..digits], 10) catch return null;
    return .{ .indent = indent, .ordered = true, .number = number, .rest = rest[digits + 2 ..] };
}

fn parseTaskBox(content: []const u8) ?struct { done: bool, rest: []const u8 } {
    if (content.len < 4) return null;
    if (content[0] != '[' or content[2] != ']' or content[3] != ' ') return null;
    const done = switch (content[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };
    return .{ .done = done, .rest = content[4..] };
}

fn looksLikeTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '|') != null and !isBlank(trimmed);
}

fn isDelimiterRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '-') == null) return false;
    for (trimmed) |ch| {
        switch (ch) {
            '-', '|', ':', ' ' => {},
            else => return false,
        }
    }
    return true;
}

fn isRawHtmlBlock(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const tags = [_][]const u8{ "<details", "<summary", "<div", "<table", "<video", "<picture", "<figure", "<iframe", "<p", "<section" };
    for (tags) |tag| if (std.mem.startsWith(u8, trimmed, tag)) return true;
    return false;
}

fn isSafeInlineHtml(inner: []const u8) bool {
    if (inner.len == 0) return false;
    if (std.mem.startsWith(u8, inner, "http://") or std.mem.startsWith(u8, inner, "https://")) return false;
    if (inner[0] == '@') return false; // `@import("…")` style prose, not a tag
    if (!std.ascii.isAlphabetic(inner[0]) and inner[0] != '/') return false;

    const tags = [_][]const u8{ "br", "kbd", "sub", "sup", "b", "i", "em", "strong", "code", "span", "mark", "small", "a", "img", "wbr", "/a", "/span", "/code", "/b", "/i", "/em", "/strong", "/kbd" };
    var name_end: usize = if (inner[0] == '/') 1 else 0;
    while (name_end < inner.len and (std.ascii.isAlphanumeric(inner[name_end]))) : (name_end += 1) {}
    const name = inner[0..name_end];
    for (tags) |tag| if (std.mem.eql(u8, name, tag)) return true;
    return false;
}

fn isAutolink(inner: []const u8) bool {
    return std.mem.startsWith(u8, inner, "http://") or std.mem.startsWith(u8, inner, "https://");
}

fn isExternal(href: []const u8) bool {
    return std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://") or
        std.mem.startsWith(u8, href, "mailto:");
}

fn findClosingBracket(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == '[') depth += 1;
        if (text[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn replaceEscapedPipes(arena: Allocator, cell: []const u8) Error![]const u8 {
    if (std.mem.indexOf(u8, cell, "\\|") == null) return cell;
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var i: usize = 0;
    while (i < cell.len) : (i += 1) {
        if (cell[i] == '\\' and i + 1 < cell.len and cell[i + 1] == '|') {
            try out.writer.writeByte('|');
            i += 1;
            continue;
        }
        try out.writer.writeByte(cell[i]);
    }
    return out.toOwnedSlice();
}

/// GitHub-style anchor: lowercase ASCII, spaces to `-`, drop punctuation, keep every non-ASCII
/// byte (the docs are Japanese, and CJK anchors must survive).
pub fn slugify(arena: Allocator, text: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    var pending_dash = false;
    for (text) |ch| {
        if (ch >= 0x80) {
            if (pending_dash and out.written().len > 0) {
                try out.writer.writeByte('-');
                pending_dash = false;
            }
            try out.writer.writeByte(ch);
            continue;
        }
        switch (ch) {
            'A'...'Z' => {
                if (pending_dash and out.written().len > 0) {
                    try out.writer.writeByte('-');
                    pending_dash = false;
                }
                try out.writer.writeByte(ch + ('a' - 'A'));
            },
            'a'...'z', '0'...'9', '_' => {
                if (pending_dash and out.written().len > 0) {
                    try out.writer.writeByte('-');
                    pending_dash = false;
                }
                try out.writer.writeByte(ch);
            },
            '-', ' ' => pending_dash = true,
            else => {},
        }
    }
    const slug = try out.toOwnedSlice();
    if (slug.len == 0) return "section";
    return slug;
}

pub fn escapeHtml(arena: Allocator, text: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try writeEscaped(&out.writer, text);
    return out.toOwnedSlice();
}

fn writeEscaped(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '&' => try out.writeAll("&amp;"),
            '"' => try out.writeAll("&quot;"),
            '\'' => try out.writeAll("&#39;"),
            else => try out.writeByte(ch),
        }
    }
}

fn isBlockTag(name: []const u8) bool {
    for ([_][]const u8{ "p", "div", "br", "li", "ul", "ol", "table", "tr", "td", "th", "thead", "tbody", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "details", "summary", "section", "hr" }) |tag| {
        if (std.mem.eql(u8, name, tag)) return true;
    }
    return false;
}

fn decodeEntities(arena: Allocator, text: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '&') {
            const pairs = [_]struct { from: []const u8, to: u8 }{
                .{ .from = "&amp;", .to = '&' },
                .{ .from = "&lt;", .to = '<' },
                .{ .from = "&gt;", .to = '>' },
                .{ .from = "&quot;", .to = '"' },
                .{ .from = "&#39;", .to = '\'' },
            };
            var matched = false;
            for (pairs) |pair| {
                if (std.mem.startsWith(u8, text[i..], pair.from)) {
                    try out.writer.writeByte(pair.to);
                    i += pair.from.len - 1;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }
        try out.writer.writeByte(text[i]);
    }
    return out.toOwnedSlice();
}

fn plainText(arena: Allocator, html: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    var in_tag = false;
    var last_space = true;
    var tag: std.Io.Writer.Allocating = .init(arena);
    defer tag.deinit();
    for (html) |ch| {
        if (ch == '<') {
            in_tag = true;
            tag.clearRetainingCapacity();
            continue;
        }
        if (ch == '>') {
            in_tag = false;
            const name = std.mem.trimStart(u8, std.mem.trimEnd(u8, tag.written(), "/"), " ");
            if (isBlockTag(name)) {
                if (!last_space) try out.writer.writeByte(' ');
                last_space = true;
            }
            continue;
        }
        if (in_tag) {
            try tag.writer.writeByte(ch);
            continue;
        }
        if (std.ascii.isWhitespace(ch)) {
            if (!last_space) try out.writer.writeByte(' ');
            last_space = true;
            continue;
        }
        try out.writer.writeByte(ch);
        last_space = false;
    }

    const raw = try out.toOwnedSlice();
    // Collapse `&amp;` / `&lt;` back so the search index does not show entities.
    var fixed: std.Io.Writer.Allocating = .init(arena);
    defer fixed.deinit();
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '&') {
            const rest = raw[i..];
            const pairs = [_]struct { from: []const u8, to: u8 }{
                .{ .from = "&amp;", .to = '&' },
                .{ .from = "&lt;", .to = '<' },
                .{ .from = "&gt;", .to = '>' },
                .{ .from = "&quot;", .to = '"' },
                .{ .from = "&#39;", .to = '\'' },
            };
            var matched = false;
            for (pairs) |pair| {
                if (std.mem.startsWith(u8, rest, pair.from)) {
                    try fixed.writer.writeByte(pair.to);
                    i += pair.from.len - 1;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }
        try fixed.writer.writeByte(raw[i]);
    }
    return std.mem.trim(u8, try fixed.toOwnedSlice(), " ");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectRender(expected: []const u8, source: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try render(arena, source, .{});
    try testing.expectEqualStrings(expected, doc.html);
}

fn renderIn(arena: Allocator, source: []const u8) !Document {
    return render(arena, source, .{});
}

test "paragraphs, emphasis, code spans and escaping" {
    try expectRender(
        "<p>Hello <strong>bold</strong> and <em>italic</em> with <code>a &lt; b</code>.</p>\n",
        "Hello **bold** and *italic* with `a < b`.",
    );
    try expectRender("<p>5 &gt; 3 &amp; 2 &lt; 4</p>\n", "5 > 3 & 2 < 4");
}

test "headings get GitHub-compatible unique anchors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try renderIn(arena,
        \\# Top
        \\## `build.zig` ヘルパー
        \\## `build.zig` ヘルパー
        \\### 日本語 見出し
    );
    try testing.expectEqual(@as(usize, 4), doc.headings.len);
    try testing.expectEqual(@as(u8, 1), doc.headings[0].level);
    try testing.expectEqualStrings("top", doc.headings[0].id);
    try testing.expectEqualStrings("buildzig-ヘルパー", doc.headings[1].id);
    try testing.expectEqualStrings("buildzig-ヘルパー-1", doc.headings[2].id);
    try testing.expectEqualStrings("日本語-見出し", doc.headings[3].id);
    try testing.expect(std.mem.indexOf(u8, doc.html, "<h2 id=\"top\"") == null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "id=\"buildzig-ヘルパー-1\"") != null);
}

test "fenced code keeps its bytes and reports the language" {
    try expectRender(
        "<pre class=\"code\"><code class=\"language-zig\">const a = 1 &lt; 2;\n\nline two</code></pre>\n",
        "```zig\nconst a = 1 < 2;\n\nline two\n```",
    );
    try expectRender(
        "<pre class=\"code\"><code>plain</code></pre>\n",
        "~~~\nplain\n~~~",
    );
}

test "GFM tables honour alignment and escaped pipes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try renderIn(arena,
        \\| Name | Value | Note |
        \\| :--- | ---: | :-: |
        \\| `a\|b` | 1 | plain |
    );
    try testing.expect(std.mem.indexOf(u8, doc.html, "<th style=\"text-align:left\">Name</th>") != null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "<th style=\"text-align:right\">Value</th>") != null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "<th style=\"text-align:center\">Note</th>") != null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "<code>a|b</code>") != null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "<td style=\"text-align:right\">1</td>") != null);
}

test "nested lists, ordered lists and task list checkboxes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try renderIn(arena,
        \\- parent
        \\  - child
        \\- [x] done
        \\- [ ] todo
        \\
        \\1. first
        \\2. second
    );
    try testing.expect(std.mem.indexOf(u8, doc.html, "<li>\n<p>parent</p>\n<ul>\n<li><span class=\"li-text\">child</span></li>\n</ul>\n</li>") != null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "<input type=\"checkbox\" disabled checked") != null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "<input type=\"checkbox\" disabled aria-label=\"todo\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "<ol>\n<li><span class=\"li-text\">first</span></li>") != null);
}

test "block quotes, rules and raw HTML blocks" {
    try expectRender(
        "<blockquote>\n<p>quoted <em>text</em></p>\n</blockquote>\n<hr />\n",
        "> quoted *text*\n\n---",
    );
    try expectRender(
        "<details>\n<summary>more</summary>\nbody\n</details>\n",
        "<details>\n<summary>more</summary>\nbody\n</details>",
    );
}

test "relative .md links become .html and external links open in a new tab" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try renderIn(arena,
        \\See [the ADR](../decisions/0017-build-tools.md#4-結果) and [Tauri](https://tauri.app).
    );
    try testing.expect(std.mem.indexOf(u8, doc.html, "href=\"../decisions/0017-build-tools.html#4-結果\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc.html, "href=\"https://tauri.app\" target=\"_blank\" rel=\"noopener\"") != null);

    try testing.expectEqual(@as(usize, 2), doc.links.len);
    try testing.expectEqualStrings("../decisions/0017-build-tools.html#4-結果", doc.links[0].href);
    try testing.expectEqualStrings("https://tauri.app", doc.links[1].href);
}

test "images, autolinks and inline HTML pass through" {
    try expectRender(
        "<p><img src=\"a.png\" alt=\"alt text\" loading=\"lazy\" /> and <kbd>Ctrl</kbd> plus <a href=\"https://x.dev\" target=\"_blank\" rel=\"noopener\">https://x.dev</a></p>\n",
        "![alt text](a.png) and <kbd>Ctrl</kbd> plus <https://x.dev>",
    );
}

test "hard breaks with a trailing backslash" {
    try expectRender("<p>line one<br />line two</p>\n", "line one\\\nline two");
}

test "plain text strips markup for the search index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try renderIn(arena, "# Title\n\nSome **bold** text & a [link](x.md).\n");
    try testing.expect(std.mem.indexOf(u8, doc.plain, "Title") != null);
    try testing.expect(std.mem.indexOf(u8, doc.plain, "Title Some bold text & a link.") != null);
    try testing.expect(std.mem.indexOf(u8, doc.plain, "<") == null);
}

test "slugify keeps CJK and folds ASCII punctuation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "Hello World", .expected = "hello-world" },
        .{ .input = "`a/b` and (c)", .expected = "ab-and-c" },
        .{ .input = "決定事項 2.1", .expected = "決定事項-21" },
        .{ .input = "---", .expected = "section" },
    };
    for (cases) |case| {
        const slug = try slugify(arena, case.input);
        try testing.expectEqualStrings(case.expected, slug);
    }
}

test "render is deterministic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = "# A\n\n- one\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n";
    const first = try renderIn(arena, source);
    const second = try renderIn(arena, source);
    try testing.expectEqualStrings(first.html, second.html);
}
