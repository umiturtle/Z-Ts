//! `M5-17` — incremental rebuild decisions for `zts dev`.
//!
//! A Zig edit used to run a full `zig build` (semantic analysis, self-hosted codegen, link and
//! install) even though the dev preview
//! serves `web/` from disk and never runs that executable. Three cheap mechanisms decide what is
//! actually needed before a process is spawned:
//!
//! * **A dependency graph** of relative `@import` / `@embedFile` edges from the app root. A file
//!   that is not reachable from the root cannot affect the compiled program, so its edits neither
//!   rebuild nor reload the page. Anything the graph cannot prove falls back to a full build.
//! * **Check-only build steps.** A `std.Build` compile step whose emitted binary nobody asks for is
//!   compiled with `-fno-emit-bin` (semantic analysis, no codegen/link). `zts dev` only needs to
//!   know whether the Zig side type-checks, so this is enough between full builds.
//! * **Build-graph dirty flags.** `build.zig` / `build.zig.zon` changes invalidate the cached step
//!   list and force a full build; a missing `check` step falls back to a full build too.
//!
//! Content-hash dirty flags live in `devserver.Snapshot`; this module consumes its diff.
//! Deliberately pure: no process is started here (except `hasCheckStep`, which is called once), so
//! every branch of `plan` is unit-testable without a Zig toolchain.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const devserver = @import("devserver.zig");

/// What `zts dev` should do after a rescan. `skip` deliberately does not bump the reload counter:
/// nothing the browser can see changed.
pub const Mode = enum { none, skip, css, assets, check, full };

/// Largest source file we parse for imports. Bigger than any hand-written Zig file; a generated
/// blob is treated as unresolvable (and therefore forces a conservative full build).
const max_source_bytes = 8 * 1024 * 1024;

/// Project-relative files reachable from the app's root source file.
pub const Graph = struct {
    gpa: Allocator,
    files: std.StringHashMapUnmanaged(void) = .empty,
    /// False when any import could not be resolved. Callers must then never skip a rebuild:
    /// a slow build is always preferable to a stale page.
    complete: bool = true,

    pub fn deinit(self: *Graph) void {
        var it = self.files.iterator();
        while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.files.deinit(self.gpa);
    }

    /// `root` is project-relative (`src/main.zig`). `project_dir` is prepended for every read.
    /// The walk is breadth-first with a visited set, so import cycles terminate.
    pub fn build(gpa: Allocator, io: Io, project_dir: []const u8, root: []const u8) !Graph {
        // Everything discovered during the walk is temporary; only the final key set is owned by
        // `gpa`. An arena keeps the cycle/duplicate paths and read buffers leak-free on error.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var self: Graph = .{ .gpa = gpa };
        errdefer self.deinit();

        var queue: std.ArrayListUnmanaged([]const u8) = .empty;
        defer queue.deinit(arena);
        try queue.append(arena, root);

        const cwd = Io.Dir.cwd();
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const path = queue.items[cursor];
            if (self.files.contains(path)) continue;
            try self.files.put(gpa, try gpa.dupe(u8, path), {});

            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, path });
            const bytes = cwd.readFileAlloc(io, full, arena, .limited(max_source_bytes)) catch {
                self.complete = false;
                continue;
            };

            var scanner = ImportScanner{ .bytes = bytes, .gpa = arena };
            while (scanner.next()) |spec| {
                const resolved = resolveImport(arena, path, spec.name, spec.is_file) catch {
                    self.complete = false;
                    continue;
                };
                // A build-system package import has no project file to walk.
                const candidate = resolved.path orelse continue;
                try queue.append(arena, candidate);
            }
        }
        return self;
    }

    pub fn isRelevant(self: *const Graph, path: []const u8) bool {
        return self.files.contains(path);
    }
};

const Spec = struct {
    name: []const u8,
    /// `@embedFile` always names a file; `@import` only when it looks like a path.
    is_file: bool,
};

/// Finds `@import("…")` / `@embedFile("…")` string literals outside comments. A commented-out
/// import must not make the graph look incomplete (which would silently disable the fast path).
const ImportScanner = struct {
    bytes: []const u8,
    gpa: Allocator,
    cursor: usize = 0,
    line_comment: bool = false,
    block_comment: bool = false,

    fn next(self: *ImportScanner) ?Spec {
        while (self.cursor < self.bytes.len) {
            const c = self.bytes[self.cursor];
            if (c == '\n') {
                self.line_comment = false;
                self.cursor += 1;
                continue;
            }
            if (self.line_comment) {
                self.cursor += 1;
                continue;
            }
            if (self.block_comment) {
                if (c == '*' and self.cursor + 1 < self.bytes.len and self.bytes[self.cursor + 1] == '/') {
                    self.block_comment = false;
                    self.cursor += 2;
                } else {
                    self.cursor += 1;
                }
                continue;
            }
            if (c == '/' and self.cursor + 1 < self.bytes.len) {
                if (self.bytes[self.cursor + 1] == '/') {
                    self.line_comment = true;
                    self.cursor += 2;
                    continue;
                }
                if (self.bytes[self.cursor + 1] == '*') {
                    self.block_comment = true;
                    self.cursor += 2;
                    continue;
                }
            }
            const is_import = std.mem.startsWith(u8, self.bytes[self.cursor..], "@import(");
            const is_embed = std.mem.startsWith(u8, self.bytes[self.cursor..], "@embedFile(");
            if (is_import or is_embed) {
                self.cursor += if (is_import) "@import(".len else "@embedFile(".len;
                while (self.cursor < self.bytes.len and (self.bytes[self.cursor] == ' ' or self.bytes[self.cursor] == '\t')) self.cursor += 1;
                if (self.cursor >= self.bytes.len or self.bytes[self.cursor] != '"') continue;
                self.cursor += 1;
                var value: std.ArrayListUnmanaged(u8) = .empty;
                errdefer value.deinit(self.gpa);
                while (self.cursor < self.bytes.len) {
                    const ch = self.bytes[self.cursor];
                    self.cursor += 1;
                    if (ch == '"') break;
                    if (ch == '\\' and self.cursor < self.bytes.len) {
                        const escaped = self.bytes[self.cursor];
                        self.cursor += 1;
                        // Zig string escapes that matter for a path: a literal quote/backslash/slash.
                        value.append(self.gpa, switch (escaped) {
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            else => escaped,
                        }) catch {
                            value.deinit(self.gpa);
                            return null;
                        };
                        continue;
                    }
                    value.append(self.gpa, ch) catch {
                        value.deinit(self.gpa);
                        return null;
                    };
                }
                const name = value.toOwnedSlice(self.gpa) catch return null;
                return .{ .name = name, .is_file = is_embed };
            }
            self.cursor += 1;
        }
        return null;
    }
};

const Resolved = struct {
    /// `null` means "a build-system package import, not a project file".
    path: ?[]const u8,
};

/// Normalises `dir + spec` into a project-relative POSIX path. Returns `path == null` for package
/// imports (`@import("std")`, `@import("embedded_frontend")`), and an error for a path that escapes
/// the project — the caller then marks the graph incomplete.
fn resolveImport(gpa: Allocator, from_file: []const u8, spec: []const u8, is_file: bool) !Resolved {
    const looks_like_path = std.mem.indexOfScalar(u8, spec, '/') != null or
        std.mem.endsWith(u8, spec, ".zig") or std.mem.startsWith(u8, spec, ".");
    if (!is_file and !looks_like_path) return .{ .path = null };

    const dir = std.fs.path.dirname(from_file) orelse "";
    const joined = if (dir.len == 0)
        try gpa.dupe(u8, spec)
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, spec });
    defer gpa.free(joined);

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.splitScalar(u8, joined, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.EscapesProject;
            _ = parts.pop();
        } else {
            try parts.append(gpa, part);
        }
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    return .{ .path = try out.toOwnedSlice(gpa) };
}

pub fn isBuildFile(path: []const u8) bool {
    return std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon");
}

/// A project that links native libraries can fail at *link* time, which `-fno-emit-bin` does not
/// exercise. Those projects keep full builds; the pure-Zig template generated by `zts init` does
/// not hit either marker. Reading one small file at startup is cheaper than a false green.
pub fn needsFullBuild(gpa: Allocator, io: Io, project_dir: []const u8) bool {
    const path = std.fmt.allocPrint(gpa, "{s}/build.zig", .{project_dir}) catch return true;
    defer gpa.free(path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch return true;
    defer gpa.free(bytes);
    return std.mem.indexOf(u8, bytes, "linkSystemLibrary") != null or
        std.mem.indexOf(u8, bytes, "link_libc = true") != null or
        std.mem.indexOf(u8, bytes, "addObject") != null;
}

/// True when `zig build --list-steps` advertises a `check` step. Called once at startup and again
/// whenever a build file changes. Any error means "assume no" → full build, which is always safe.
pub fn hasCheckStep(gpa: Allocator, io: Io, zig_path: []const u8, dir: []const u8) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ zig_path, "build", "--list-steps" },
        .cwd = .{ .path = dir },
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) return false;

    return listStepsHasCheck(result.stdout);
}

/// Pure parser for `zig build --list-steps`, so the detection is unit-testable without a compiler.
pub fn listStepsHasCheck(stdout: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        if (std.mem.eql(u8, trimmed[0..end], "check")) return true;
    }
    return false;
}

/// Decides what a rescan should do. `structural` are paths that appeared or disappeared (from
/// `Snapshot.structural`); those under `src/` can change the module graph in ways a diff of
/// contents cannot, so they force a full build.
pub fn plan(
    changed: []const []const u8,
    structural: []const []const u8,
    graph: *const Graph,
    check_step: bool,
) Mode {
    var web: [256][]const u8 = undefined;
    var web_len: usize = 0;
    var web_overflow = false;
    var src_changed = false;
    var src_relevant = false;

    for (structural) |path| {
        if (isBuildFile(path) or std.mem.startsWith(u8, path, "src/")) return .full;
    }
    for (changed) |path| {
        if (isBuildFile(path)) return .full;
        if (std.mem.startsWith(u8, path, "src/")) {
            src_changed = true;
            if (graph.isRelevant(path)) src_relevant = true;
            continue;
        }
        if (web_len < web.len) {
            web[web_len] = path;
            web_len += 1;
        } else {
            web_overflow = true;
        }
    }

    if (src_changed) {
        if (!graph.complete) return .full;
        if (!src_relevant) return .skip;
        return if (check_step) .check else .full;
    }
    if (web_len == 0) return .none;
    if (web_overflow) return .assets; // too many to classify individually; a reload is safe
    return switch (devserver.Change.classify(web[0..web_len])) {
        .css => .css,
        .assets => .assets,
        // `src/` paths were filtered out above, so `.source` cannot occur here.
        .none, .source => .none,
    };
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "resolveImport normalises relatives and distinguishes package imports" {
    const gpa = testing.allocator;
    {
        const r = try resolveImport(gpa, "src/main.zig", "util.zig", false);
        defer if (r.path) |p| gpa.free(p);
        try testing.expectEqualStrings("src/util.zig", r.path.?);
    }
    {
        const r = try resolveImport(gpa, "src/app/main.zig", "../shared/x.zig", false);
        defer if (r.path) |p| gpa.free(p);
        try testing.expectEqualStrings("src/shared/x.zig", r.path.?);
    }
    {
        const r = try resolveImport(gpa, "src/main.zig", "data.txt", true);
        defer if (r.path) |p| gpa.free(p);
        try testing.expectEqualStrings("src/data.txt", r.path.?);
    }
    {
        const r = try resolveImport(gpa, "src/main.zig", "embedded_frontend", false);
        defer if (r.path) |p| gpa.free(p);
        try testing.expect(r.path == null);
    }
    try testing.expectError(error.EscapesProject, resolveImport(gpa, "src/main.zig", "../../outside.zig", false));
}

test "ImportScanner ignores comments and finds both import forms" {
    const src =
        \\// @import("commented.zig")
        \\/* @import("block.zig") */
        \\const a = @import("real.zig");
        \\const b = @embedFile("data.bin");
        \\const pkg = @import("zts_web");
        \\const c = @import( "spaced.zig" );
    ;
    var scanner = ImportScanner{ .bytes = src, .gpa = testing.allocator };
    var found: [8][]const u8 = undefined;
    var n: usize = 0;
    while (scanner.next()) |spec| {
        found[n] = spec.name;
        n += 1;
    }
    defer for (found[0..n]) |name| testing.allocator.free(name);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("real.zig", found[0]);
    try testing.expectEqualStrings("data.bin", found[1]);
    try testing.expectEqualStrings("zts_web", found[2]);
    try testing.expectEqualStrings("spaced.zig", found[3]);
}

test "Graph follows transitive imports and terminates on a cycle" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data =
        \\const a = @import("sub/a.zig");
        \\const w = @import("zts_web"); // a build-system module, not a file
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/a.zig", .data =
        \\const b = @import("b.zig");
        \\const data = @embedFile("data.txt");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/b.zig", .data =
        \\const again = @import("a.zig"); // cycle
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/data.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/scratch.zig", .data = "pub const x = 1;" });

    const root_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root_dir);
    var graph = try Graph.build(testing.allocator, io, root_dir, "src/main.zig");
    defer graph.deinit();

    try testing.expect(graph.complete);
    try testing.expect(graph.isRelevant("src/main.zig"));
    try testing.expect(graph.isRelevant("src/sub/a.zig"));
    try testing.expect(graph.isRelevant("src/sub/b.zig"));
    try testing.expect(graph.isRelevant("src/sub/data.txt"));
    try testing.expect(!graph.isRelevant("src/scratch.zig"));
}

test "Graph marks itself incomplete when an imported file is missing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data =
        \\const a = @import("gone.zig");
    });
    const root_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root_dir);
    var graph = try Graph.build(testing.allocator, testing.io, root_dir, "src/main.zig");
    defer graph.deinit();
    try testing.expect(!graph.complete);
}

fn emptyGraph() Graph {
    return .{ .gpa = testing.allocator };
}

test "plan: a reachable Zig edit uses the check step" {
    var graph = emptyGraph();
    defer graph.deinit();
    try graph.files.put(testing.allocator, try testing.allocator.dupe(u8, "src/main.zig"), {});
    try testing.expectEqual(Mode.check, plan(&.{"src/main.zig"}, &.{}, &graph, true));
    // No `check` step (older template) -> full build, never a skipped build.
    try testing.expectEqual(Mode.full, plan(&.{"src/main.zig"}, &.{}, &graph, false));
}

test "plan: an unreachable file neither rebuilds nor reloads" {
    var graph = emptyGraph();
    defer graph.deinit();
    try graph.files.put(testing.allocator, try testing.allocator.dupe(u8, "src/main.zig"), {});
    try testing.expectEqual(Mode.skip, plan(&.{"src/scratch.zig"}, &.{}, &graph, true));
    // An incomplete graph must never claim a file is irrelevant.
    graph.complete = false;
    try testing.expectEqual(Mode.full, plan(&.{"src/scratch.zig"}, &.{}, &graph, true));
}

test "needsFullBuild is conservative about native linkage and missing build.zig" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const root_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root_dir);
    // No build.zig at all -> assume the slow, safe path.
    try testing.expect(needsFullBuild(testing.allocator, io, root_dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void {}" });
    try testing.expect(!needsFullBuild(testing.allocator, io, root_dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "exe.linkSystemLibrary(\"gtk-3\");" });
    try testing.expect(needsFullBuild(testing.allocator, io, root_dir));
}

test "listStepsHasCheck recognises the step and ignores look-alikes" {
    const with_check = "  install (default)            Copy build artifacts\n" ++
        "  check                        Type-check the app without emitting a binary\n" ++
        "  frontend                     Re-embed web/\n";
    try testing.expect(listStepsHasCheck(with_check));
    const look_alike = "  install (default)            Copy build artifacts\n" ++
        "  check-bindings               Fail when bindings.gen.ts is out of date\n";
    try testing.expect(!listStepsHasCheck(look_alike));
    try testing.expect(!listStepsHasCheck(""));
}

test "plan: build files, structural changes and web edits" {
    var graph = emptyGraph();
    defer graph.deinit();
    try graph.files.put(testing.allocator, try testing.allocator.dupe(u8, "src/main.zig"), {});
    try testing.expectEqual(Mode.full, plan(&.{"build.zig"}, &.{}, &graph, true));
    try testing.expectEqual(Mode.full, plan(&.{"src/main.zig"}, &.{"src/new.zig"}, &graph, true));
    try testing.expectEqual(Mode.css, plan(&.{"web/site.css"}, &.{}, &graph, true));
    try testing.expectEqual(Mode.assets, plan(&.{"web/index.html"}, &.{}, &graph, true));
    try testing.expectEqual(Mode.none, plan(&.{}, &.{}, &graph, true));
    // A CSS edit arriving in the same burst as a Zig edit still rebuilds.
    try testing.expectEqual(Mode.check, plan(&.{ "web/site.css", "src/main.zig" }, &.{}, &graph, true));
    // A structural change under web/ is an asset change, not a reason for a full build.
    try testing.expectEqual(Mode.assets, plan(&.{"web/new.html"}, &.{"web/new.html"}, &graph, true));
}
