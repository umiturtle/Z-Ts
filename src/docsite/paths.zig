//! Site-relative path arithmetic shared by the page shell (`site.zig`), the Markdown renderer
//! (`markdown.zig`) and the cross-reference index (`links.zig`).
//!
//! It lives in its own file because `site.zig` imports `markdown.zig`: if the renderer had to import
//! the shell to turn `docs/api/zts_rpc/schema.html#Bind` into `../api/zts_rpc/schema.html#Bind`,
//! the two modules would form a cycle. A 40-line leaf module keeps the dependency graph a DAG.

const std = @import("std");
const Allocator = std.mem.Allocator;

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
    // `from_dir` entirely consumed means the target may sit in the same directory — but only when
    // the next character of `to` is a separator (or the paths are equal). Matching `from_dir` as a
    // *string* is not enough: `docs/api/zts_web` is a prefix of `docs/api/zts_webview`, and an
    // unguarded branch here turned that into `href="iew/index.html"`.
    if (probe == from_dir.len) {
        if (to.len == from_dir.len) {
            shared = from_dir.len;
        } else if (to[from_dir.len] == '/') {
            shared = from_dir.len + 1; // the target lives in the same directory
        } else {
            // `from_dir` matched as a string but not as a path segment: keep the last boundary.
            shared = @min(shared, from_dir.len);
        }
    }

    // `shared` indexes both strings; when the whole directory is shared it overshoots by one.
    const rest_up = from_dir[@min(shared, from_dir.len)..];
    var depth: usize = 0;
    if (rest_up.len > 0) depth = std.mem.count(u8, rest_up, "/") + 1;

    const up = try arena.alloc(u8, depth * 3);
    for (0..depth) |i| @memcpy(up[i * 3 ..][0..3], "../");
    return std.fmt.allocPrint(arena, "{s}{s}", .{ up, to[shared..] });
}

test "relativeHref keeps sibling and ancestor links short" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { from: []const u8, to: []const u8, expected: []const u8 }{
        .{ .from = "docs/api/zts_rpc/schema.html", .to = "docs/api/zts_rpc/mod.html", .expected = "mod.html" },
        .{ .from = "docs/api/zts_rpc/schema.html", .to = "docs/api/index.html", .expected = "../index.html" },
        .{ .from = "docs/api/zts_rpc/schema.html", .to = "docs/guides/using-rpc.html", .expected = "../../guides/using-rpc.html" },
        .{ .from = "index.html", .to = "docs/api/index.html", .expected = "docs/api/index.html" },
        .{ .from = "docs/tasks/a.html", .to = "docs/tasks/b.html", .expected = "b.html" },
        // The prefix-vs-segment bug that produced `href="iew/index.html"`.
        .{ .from = "docs/api/zts_web/index.html", .to = "docs/api/zts_webview/index.html", .expected = "../zts_webview/index.html" },
    };
    for (cases) |case| {
        const got = try relativeHref(arena, case.from, case.to);
        try std.testing.expectEqualStrings(case.expected, got);
    }
}
