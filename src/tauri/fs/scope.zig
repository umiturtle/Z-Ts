//! Capability Scope for `plugin:fs|*`: lexical normalization → symlink resolution → containment.
//!
//! A web frontend is untrusted input. Every path that reaches `src/tauri/fs/commands.zig`
//! must pass through [`Scope.resolveAlloc`] **before** any syscall touches it:
//!
//! 1. **Lexical normalization** ([`path.normalizeWithStyle`]) collapses `.` / `..` so `../../etc`
//!    cannot climb above the application root.
//! 2. **Symlink resolution** ([`canonicalizeAlloc`]) rewrites every symlink component into its
//!    target, bounded by [`max_symlink_hops`], so a link *inside* the scope cannot point *outside*
//!    of it (`/allowed/link -> /etc` then `/allowed/link/passwd` is rejected).
//! 3. **Containment** ([`allowsPath`]) compares whole path components (never raw string prefixes),
//!    so `/allowed` does **not** cover `/allowed-evil`. On Windows the comparison folds ASCII case
//!    because NTFS is case-insensitive.
//!
//! The resolver is pure Zig (`link_libc = false`) and takes an explicit `std.Io`, which keeps it
//! unit-testable against a temporary directory on every OS.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const path = @import("../path.zig");

/// Hard upper bound on chained symlink rewrites (`a -> b -> c -> ...`).
pub const max_symlink_hops: usize = 40;

pub const ResolveError = Allocator.Error || error{
    /// The canonical path is outside every configured root.
    OutOfScope,
    /// Symlink chain exceeded [`max_symlink_hops`] (a loop, or a pathological layout).
    SymLinkLoop,
    /// A component exists but its metadata could not be read, so the scope cannot be verified.
    CannotVerify,
    /// The path is empty or otherwise unusable after normalization.
    InvalidPath,
};

/// One allowed root. `recursive = false` admits only the root itself (a single file grant).
pub const Root = struct {
    path: []const u8,
    recursive: bool = true,
};

/// Result of splitting an absolute normalized path into its root prefix and the rest.
pub const SplitRoot = struct {
    root: []const u8,
    rest: []const u8,
};

fn isSep(style: path.PathStyle, c: u8) bool {
    return switch (style) {
        .posix => c == '/',
        // `std.fs.path` accepts `/` on Windows too, and users type both.
        .windows => c == '\\' or c == '/',
    };
}

fn eqlByteFold(style: path.PathStyle, a: u8, b: u8) bool {
    return switch (style) {
        .posix => a == b,
        .windows => std.ascii.toLower(a) == std.ascii.toLower(b),
    };
}

/// Component-wise path equality (ASCII case-folded on Windows).
pub fn pathEql(style: path.PathStyle, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (!eqlByteFold(style, ca, cb)) return false;
    }
    return true;
}

/// Splits `abs` (already normalized & absolute) into the OS root prefix and the remaining path.
///
/// - POSIX: `/` + `usr/bin`
/// - Windows drive: `C:\` + `Users\me`
/// - Windows UNC: `\\server\share` + `dir\file`
pub fn splitRoot(style: path.PathStyle, abs: []const u8) SplitRoot {
    switch (style) {
        .posix => {
            if (abs.len == 0 or abs[0] != '/') return .{ .root = "", .rest = abs };
            return .{ .root = abs[0..1], .rest = abs[1..] };
        },
        .windows => {
            if (abs.len >= 3 and std.ascii.isAlphabetic(abs[0]) and abs[1] == ':' and isSep(.windows, abs[2])) {
                return .{ .root = abs[0..3], .rest = abs[3..] };
            }
            if (abs.len >= 2 and isSep(.windows, abs[0]) and isSep(.windows, abs[1])) {
                var i: usize = 2;
                var seen: usize = 0;
                while (i < abs.len) : (i += 1) {
                    if (isSep(.windows, abs[i])) {
                        seen += 1;
                        if (seen == 2) return .{ .root = abs[0..i], .rest = abs[i + 1 ..] };
                    }
                }
                return .{ .root = abs, .rest = abs[abs.len..] };
            }
            return .{ .root = "", .rest = abs };
        },
    }
}

/// Iterator over the non-empty components of `rest`.
const ComponentIter = struct {
    style: path.PathStyle,
    rest: []const u8,
    cursor: usize = 0,

    fn next(self: *ComponentIter) ?[]const u8 {
        while (self.cursor < self.rest.len) {
            const start = self.cursor;
            var end = start;
            while (end < self.rest.len and !isSep(self.style, self.rest[end])) : (end += 1) {}
            self.cursor = end + 1;
            if (end > start) return self.rest[start..end];
        }
        return null;
    }
};

/// Replaces the first symlink component of `abs` with its target and returns the lexical result.
///
/// Returns `null` when no symlink component exists (or when the tail does not exist yet, which is
/// legal for `create` / `mkdir`). OS failures that would hide the true identity of an **existing**
/// component surface as `error.CannotVerify` — we never fall back to the unverified path.
fn firstSymlinkSubstitution(
    io: Io,
    allocator: Allocator,
    style: path.PathStyle,
    abs: []const u8,
) ResolveError!?[]u8 {
    const dir = Io.Dir.cwd();
    const parts = splitRoot(style, abs);

    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(allocator);
    try prefix.appendSlice(allocator, parts.root);

    var it = ComponentIter{ .style = style, .rest = parts.rest };
    while (it.next()) |comp| {
        if (prefix.items.len > 0 and !isSep(style, prefix.items[prefix.items.len - 1])) {
            try prefix.append(allocator, style.sep());
        }
        try prefix.appendSlice(allocator, comp);

        const stat = dir.statFile(io, prefix.items, .{ .follow_symlinks = false }) catch |err| switch (err) {
            // The tail does not exist yet: nothing further can be a symlink.
            error.FileNotFound, error.NotDir => return null,
            // Permission denied / link loop / unsupported reparse point: cannot verify.
            else => return error.CannotVerify,
        };
        if (stat.kind != .sym_link) continue;

        var link_buf: [4096]u8 = undefined;
        const n = dir.readLink(io, prefix.items, &link_buf) catch return error.CannotVerify;
        const target = link_buf[0..n];

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        if (path.isAbsoluteWithStyle(style, target)) {
            try out.appendSlice(allocator, target);
        } else {
            // `prefix` currently ends with the link name: drop it to get the containing directory.
            var cut = prefix.items.len;
            while (cut > 0 and !isSep(style, prefix.items[cut - 1])) : (cut -= 1) {}
            try out.appendSlice(allocator, prefix.items[0..cut]);
            try out.appendSlice(allocator, target);
        }
        while (it.next()) |rest_comp| {
            if (out.items.len > 0 and !isSep(style, out.items[out.items.len - 1])) {
                try out.append(allocator, style.sep());
            }
            try out.appendSlice(allocator, rest_comp);
        }
        return try path.normalizeWithStyle(allocator, style, out.items);
    }
    return null;
}

/// Resolves every symlink component of `abs` and returns the canonical absolute path.
///
/// Caller owns the returned slice. The input must already be absolute and lexically normalized.
pub fn canonicalizeAlloc(
    io: Io,
    allocator: Allocator,
    style: path.PathStyle,
    abs: []const u8,
) ResolveError![]u8 {
    if (abs.len == 0) return error.InvalidPath;
    var current = try path.normalizeWithStyle(allocator, style, abs);
    errdefer allocator.free(current);

    var hops: usize = 0;
    while (true) {
        const replacement = try firstSymlinkSubstitution(io, allocator, style, current);
        if (replacement) |next| {
            allocator.free(current);
            current = next;
            hops += 1;
            if (hops >= max_symlink_hops) {
                allocator.free(current);
                return error.SymLinkLoop;
            }
        } else {
            return current;
        }
    }
}

/// Pure containment test: is `canonical` inside one of `roots`?
///
/// Comparison is component-wise (`/a/b` never covers `/a/bc`) and case-folded on Windows.
pub fn allowsPath(style: path.PathStyle, roots: []const Root, canonical: []const u8) bool {
    if (canonical.len == 0) return false;
    for (roots) |root| {
        if (root.path.len == 0) continue;
        if (pathEql(style, canonical, root.path)) return true;
        if (!root.recursive) continue;
        if (canonical.len <= root.path.len) continue;

        const prefix = canonical[0..root.path.len];
        if (!pathEql(style, prefix, root.path)) continue;

        // A root that already ends in a separator (`/` or `C:\`) needs no extra boundary check.
        if (isSep(style, root.path[root.path.len - 1])) return true;
        if (isSep(style, canonical[root.path.len])) return true;
    }
    return false;
}

pub const Scope = struct {
    allocator: Allocator,
    style: path.PathStyle,
    /// Growable: `plugin:dialog` appends a grant for every path the user picks (upstream
    /// `tauri-plugin-fs` scope behaviour), so a dialog result can be read with `plugin:fs|*`.
    roots: std.ArrayListUnmanaged(Root) = .empty,

    /// Builds a scope from raw root strings. Roots are lexically normalized only; pass them
    /// through [`initCanonical`] when the roots themselves may contain symlinks.
    pub fn init(allocator: Allocator, style: path.PathStyle, specs: []const Root) Allocator.Error!Scope {
        var self: Scope = .{ .allocator = allocator, .style = style };
        errdefer self.deinit();
        try self.roots.ensureTotalCapacity(allocator, specs.len);
        for (specs) |spec| {
            if (!path.isAbsoluteWithStyle(style, spec.path)) return error.OutOfMemory;
            try self.roots.append(allocator, .{
                .path = try path.normalizeWithStyle(allocator, style, spec.path),
                .recursive = spec.recursive,
            });
        }
        return self;
    }

    /// Builds a scope whose roots are fully canonicalized (symlinks resolved) exactly once.
    pub fn initCanonical(
        allocator: Allocator,
        io: Io,
        style: path.PathStyle,
        specs: []const Root,
    ) ResolveError!Scope {
        var self: Scope = .{ .allocator = allocator, .style = style };
        errdefer self.deinit();
        try self.roots.ensureTotalCapacity(allocator, specs.len);
        for (specs) |spec| {
            if (!path.isAbsoluteWithStyle(style, spec.path)) return error.InvalidPath;
            const canonical = try self.canonicalRootAlloc(io, spec.path);
            errdefer allocator.free(canonical);
            try self.roots.append(allocator, .{ .path = canonical, .recursive = spec.recursive });
        }
        return self;
    }

    fn canonicalRootAlloc(self: *Scope, io: Io, raw: []const u8) ResolveError![]u8 {
        const normalized = try path.normalizeWithStyle(self.allocator, self.style, raw);
        defer self.allocator.free(normalized);
        return canonicalizeAlloc(io, self.allocator, self.style, normalized);
    }

    pub fn deinit(self: *Scope) void {
        for (self.roots.items) |root| self.allocator.free(root.path);
        self.roots.deinit(self.allocator);
        self.* = undefined;
    }

    /// Grants `raw` at runtime (e.g. a path the user just picked in a native file dialog).
    ///
    /// The path is canonicalized first, so the grant names the real target rather than a symlink.
    /// Returns `error.OutOfScope` when `raw` itself cannot be verified — callers should surface
    /// that as a failed dialog grant instead of widening the scope blindly.
    pub fn addRoot(self: *Scope, io: Io, raw: []const u8, recursive: bool) ResolveError!void {
        if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPath;
        if (!path.isAbsoluteWithStyle(self.style, raw)) return error.InvalidPath;

        const canonical = try self.canonicalRootAlloc(io, raw);
        errdefer self.allocator.free(canonical);
        try self.roots.append(self.allocator, .{ .path = canonical, .recursive = recursive });
    }

    pub fn allowsCanonical(self: *const Scope, canonical: []const u8) bool {
        return allowsPath(self.style, self.roots.items, canonical);
    }

    /// Turns an untrusted `raw` path into a canonical, in-scope absolute path owned by `allocator`.
    ///
    /// Relative paths are resolved against `cwd` (the application working directory), mirroring
    /// `plugin:path|resolve`. Everything outside the scope returns `error.OutOfScope`.
    pub fn resolveAlloc(
        self: *const Scope,
        io: Io,
        allocator: Allocator,
        raw: []const u8,
        cwd: []const u8,
    ) ResolveError![]u8 {
        if (raw.len == 0) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPath;

        const absolute = if (path.isAbsoluteWithStyle(self.style, raw))
            try path.normalizeWithStyle(allocator, self.style, raw)
        else
            try path.joinWithStyle(allocator, self.style, &.{ cwd, raw });
        defer allocator.free(absolute);

        const canonical = try canonicalizeAlloc(io, allocator, self.style, absolute);
        errdefer allocator.free(canonical);

        if (!self.allowsCanonical(canonical)) return error.OutOfScope;
        return canonical;
    }
};

// ============================================================================
// Tests: pure containment rules (no filesystem)
// ============================================================================

test "allowsPath: component boundary, exact match, and non-recursive grants" {
    const roots = [_]Root{
        .{ .path = "/srv/app", .recursive = true },
        .{ .path = "/srv/single.txt", .recursive = false },
    };

    try testing.expect(allowsPath(.posix, &roots, "/srv/app"));
    try testing.expect(allowsPath(.posix, &roots, "/srv/app/file.txt"));
    try testing.expect(allowsPath(.posix, &roots, "/srv/app/a/b/c"));

    // String-prefix trap: `/srv/app-evil` shares a prefix but not a component.
    try testing.expect(!allowsPath(.posix, &roots, "/srv/app-evil/file.txt"));
    try testing.expect(!allowsPath(.posix, &roots, "/srv/other"));
    try testing.expect(!allowsPath(.posix, &roots, "/"));
    try testing.expect(!allowsPath(.posix, &roots, ""));

    // A non-recursive root admits exactly itself.
    try testing.expect(allowsPath(.posix, &roots, "/srv/single.txt"));
    try testing.expect(!allowsPath(.posix, &roots, "/srv/single.txt/below"));
}

test "allowsPath: root `/` covers everything, Windows comparison folds ASCII case" {
    const root_only = [_]Root{.{ .path = "/" }};
    try testing.expect(allowsPath(.posix, &root_only, "/etc/passwd"));

    const win = [_]Root{.{ .path = "C:\\Users\\App\\Data" }};
    try testing.expect(allowsPath(.windows, &win, "C:\\Users\\App\\Data"));
    try testing.expect(allowsPath(.windows, &win, "C:\\Users\\App\\Data\\a.txt"));
    try testing.expect(allowsPath(.windows, &win, "c:\\users\\app\\data\\a.txt"));
    try testing.expect(!allowsPath(.windows, &win, "C:\\Users\\App\\Data2\\a.txt"));
    try testing.expect(!allowsPath(.windows, &win, "C:\\Users\\App"));
    // POSIX style stays case sensitive even for identical-looking strings.
    try testing.expect(!allowsPath(.posix, &[_]Root{.{ .path = "/Data" }}, "/data/x"));
}

test "splitRoot: POSIX, drive letters, and UNC prefixes" {
    try testing.expectEqualStrings("/", splitRoot(.posix, "/usr/bin").root);
    try testing.expectEqualStrings("usr/bin", splitRoot(.posix, "/usr/bin").rest);

    try testing.expectEqualStrings("C:\\", splitRoot(.windows, "C:\\Users\\me").root);
    try testing.expectEqualStrings("Users\\me", splitRoot(.windows, "C:\\Users\\me").rest);

    const unc = splitRoot(.windows, "\\\\server\\share\\dir\\f.txt");
    try testing.expectEqualStrings("\\\\server\\share", unc.root);
    try testing.expectEqualStrings("dir\\f.txt", unc.rest);
}

// ============================================================================
// Tests: real filesystem behavior (runs on Linux, macOS, and Windows CI)
// ============================================================================

test "Scope.resolveAlloc: rejects `..` traversal out of the root" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root_path = root_buf[0..root_len];

    var scope = try Scope.initCanonical(testing.allocator, io, path.PathStyle.current(), &.{
        .{ .path = root_path },
    });
    defer scope.deinit();

    const inside = try scope.resolveAlloc(io, testing.allocator, "sub/../file.txt", root_path);
    defer testing.allocator.free(inside);
    try testing.expect(std.mem.endsWith(u8, inside, "file.txt"));

    try testing.expectError(error.OutOfScope, scope.resolveAlloc(io, testing.allocator, "../../etc/passwd", root_path));
    // An absolute path that is definitely outside the temporary directory on this OS.
    const outside_abs = if (path.PathStyle.current() == .windows)
        "C:\\Windows\\System32\\drivers\\etc\\hosts"
    else
        "/etc/passwd";
    try testing.expectError(error.OutOfScope, scope.resolveAlloc(io, testing.allocator, outside_abs, root_path));
    try testing.expectError(error.InvalidPath, scope.resolveAlloc(io, testing.allocator, "", root_path));
}

test "Scope.resolveAlloc: symlink inside the root cannot be used to escape it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root_path = root_buf[0..root_len];

    // <tmp>/outside/secret.txt  and  <tmp>/root/link -> ../outside
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.createDir(io, "root", .default_dir);
    {
        const f = try tmp.dir.createFile(io, "outside/secret.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "top secret");
    }
    try tmp.dir.symLink(io, "../outside", "root/link", .{});

    const root_spec = try std.fmt.allocPrint(testing.allocator, "{s}/root", .{root_path});
    defer testing.allocator.free(root_spec);

    var scope = try Scope.initCanonical(testing.allocator, io, path.PathStyle.current(), &.{
        .{ .path = root_spec },
    });
    defer scope.deinit();

    // Reading *through* the escaping link is refused...
    try testing.expectError(
        error.OutOfScope,
        scope.resolveAlloc(io, testing.allocator, "link/secret.txt", root_spec),
    );
    // ...while a plain in-root path still resolves.
    const ok = try scope.resolveAlloc(io, testing.allocator, "file.txt", root_spec);
    defer testing.allocator.free(ok);
    try testing.expect(std.mem.endsWith(u8, ok, "file.txt"));
}

test "Scope.resolveAlloc: symlink that stays inside the root is allowed and canonicalized" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root_path = root_buf[0..root_len];

    try tmp.dir.createDir(io, "real", .default_dir);
    {
        const f = try tmp.dir.createFile(io, "real/data.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hello");
    }
    try tmp.dir.symLink(io, "real", "alias", .{});

    var scope = try Scope.initCanonical(testing.allocator, io, path.PathStyle.current(), &.{
        .{ .path = root_path },
    });
    defer scope.deinit();

    const resolved = try scope.resolveAlloc(io, testing.allocator, "alias/data.txt", root_path);
    defer testing.allocator.free(resolved);
    // Compare against the separator-correct expectation (`/` on POSIX, `\` on Windows).
    const expected = try path.joinWithStyle(testing.allocator, path.PathStyle.current(), &.{ root_path, "real", "data.txt" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, resolved);
}
