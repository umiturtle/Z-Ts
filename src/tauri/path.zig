//! `plugin:path|*` Cross-Platform Directory & Path Manipulation Commands (`src/tauri/path.zig`).
//!
//! 100% wire-compatible with `@tauri-apps/api/path` (`vendor/tauri/packages/api/src/path.ts`),
//! covering all 23 `BaseDirectory` enum discriminants (`1..23`) plus `resolve`, `normalize`,
//! `join`, `dirname`, `extname`, `basename`, and `is_absolute`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const rpc = @import("zts_rpc");

pub const PathStyle = enum {
    posix,
    windows,

    pub fn current() PathStyle {
        return if (builtin.os.tag == .windows) .windows else .posix;
    }

    pub fn sep(self: PathStyle) u8 {
        return switch (self) {
            .posix => '/',
            .windows => '\\',
        };
    }
};

/// Exact wire integer discriminants matching `@tauri-apps/api/path` `enum BaseDirectory`.
pub const BaseDirectory = enum(u8) {
    audio = 1,
    cache = 2,
    config = 3,
    data = 4,
    local_data = 5,
    document = 6,
    download = 7,
    picture = 8,
    public = 9,
    video = 10,
    resource = 11,
    temp = 12,
    app_config = 13,
    app_data = 14,
    app_local_data = 15,
    app_cache = 16,
    app_log = 17,
    desktop = 18,
    executable = 19,
    font = 20,
    home = 21,
    runtime = 22,
    template = 23,
};

pub const PathError = error{
    UnknownBaseDirectory,
    OutOfMemory,
};

/// Deterministic cross-platform path configuration (pure Zig, zero `libc` / `getenv` global races).
pub const PathState = struct {
    style: PathStyle = PathStyle.current(),
    app_identifier: []const u8 = "com.zts.app",
    home_dir: []const u8 = "/home/user",
    cache_dir: ?[]const u8 = null,
    config_dir: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    local_data_dir: ?[]const u8 = null,
    resource_dir: []const u8 = "/app/resources",
    executable_dir: []const u8 = "/app/bin",
    runtime_dir: []const u8 = "/run/user/1000",
    temp_dir: []const u8 = if (builtin.os.tag == .windows) "C:\\Temp" else "/tmp",
    cwd: []const u8 = "/",

    pub fn resolveBaseAlloc(self: *const PathState, scratch: Allocator, raw_dir: u8) PathError![]const u8 {
        const dir = std.enums.fromInt(BaseDirectory, raw_dir) orelse return error.UnknownBaseDirectory;
        const home = self.home_dir;
        const cfg_base = self.config_dir orelse try joinWithStyle(scratch, self.style, &.{ home, ".config" });
        const data_base = self.data_dir orelse try joinWithStyle(scratch, self.style, &.{ home, ".local", "share" });
        const local_base = self.local_data_dir orelse data_base;
        const cache_base = self.cache_dir orelse try joinWithStyle(scratch, self.style, &.{ home, ".cache" });

        return switch (dir) {
            .home => home,
            .cache => cache_base,
            .config => cfg_base,
            .data => data_base,
            .local_data => local_base,
            .audio => try joinWithStyle(scratch, self.style, &.{ home, "Music" }),
            .document => try joinWithStyle(scratch, self.style, &.{ home, "Documents" }),
            .download => try joinWithStyle(scratch, self.style, &.{ home, "Downloads" }),
            .picture => try joinWithStyle(scratch, self.style, &.{ home, "Pictures" }),
            .public => try joinWithStyle(scratch, self.style, &.{ home, "Public" }),
            .video => try joinWithStyle(scratch, self.style, &.{ home, "Videos" }),
            .desktop => try joinWithStyle(scratch, self.style, &.{ home, "Desktop" }),
            .template => try joinWithStyle(scratch, self.style, &.{ home, "Templates" }),
            .font => try joinWithStyle(scratch, self.style, &.{ data_base, "fonts" }),
            .resource => self.resource_dir,
            .executable => self.executable_dir,
            .runtime => self.runtime_dir,
            .temp => self.temp_dir,
            .app_config => try joinWithStyle(scratch, self.style, &.{ cfg_base, self.app_identifier }),
            .app_data => try joinWithStyle(scratch, self.style, &.{ data_base, self.app_identifier }),
            .app_local_data => try joinWithStyle(scratch, self.style, &.{ local_base, self.app_identifier }),
            .app_cache => try joinWithStyle(scratch, self.style, &.{ cache_base, self.app_identifier }),
            .app_log => try joinWithStyle(scratch, self.style, &.{ local_base, self.app_identifier, "logs" }),
        };
    }
};

fn isSep(style: PathStyle, c: u8) bool {
    return switch (style) {
        .posix => c == '/',
        .windows => c == '\\' or c == '/',
    };
}

pub fn isAbsoluteWithStyle(style: PathStyle, p: []const u8) bool {
    if (p.len == 0) return false;
    return switch (style) {
        .posix => p[0] == '/',
        .windows => blk: {
            if (p.len >= 2 and isSep(.windows, p[0]) and isSep(.windows, p[1])) break :blk true;
            if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and isSep(.windows, p[2])) break :blk true;
            break :blk false;
        },
    };
}

pub fn normalizeWithStyle(allocator: Allocator, style: PathStyle, raw_path: []const u8) Allocator.Error![]u8 {
    if (raw_path.len == 0) return allocator.dupe(u8, ".");

    const sep_char = style.sep();
    var prefix: []const u8 = "";
    var rest = raw_path;
    var rooted = false;

    if (style == .windows and rest.len >= 2 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':') {
        prefix = rest[0..2];
        rest = rest[2..];
        if (rest.len > 0 and isSep(.windows, rest[0])) {
            rooted = true;
            rest = rest[1..];
        }
    } else if (isSep(style, rest[0])) {
        rooted = true;
        rest = rest[1..];
    }

    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);

    var start: usize = 0;
    while (start <= rest.len) {
        var end = start;
        while (end < rest.len and !isSep(style, rest[end])) : (end += 1) {}
        const seg = rest[start..end];
        start = end + 1;

        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (stack.items.len > 0 and !std.mem.eql(u8, stack.items[stack.items.len - 1], "..")) {
                _ = stack.pop();
            } else if (!rooted) {
                try stack.append(allocator, "..");
            }
        } else {
            try stack.append(allocator, seg);
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    if (prefix.len > 0) aw.writer.writeAll(prefix) catch return error.OutOfMemory;
    if (rooted) aw.writer.writeByte(sep_char) catch return error.OutOfMemory;

    for (stack.items, 0..) |seg, i| {
        if (i > 0) aw.writer.writeByte(sep_char) catch return error.OutOfMemory;
        aw.writer.writeAll(seg) catch return error.OutOfMemory;
    }

    const written = aw.written();
    if (written.len == 0) {
        return allocator.dupe(u8, ".");
    }
    return aw.toOwnedSlice();
}

pub fn joinWithStyle(allocator: Allocator, style: PathStyle, parts: []const []const u8) Allocator.Error![]u8 {
    if (parts.len == 0) return allocator.dupe(u8, ".");
    const sep_char = style.sep();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    for (parts, 0..) |part, i| {
        if (part.len == 0) continue;
        if (i > 0 and aw.written().len > 0) {
            aw.writer.writeByte(sep_char) catch return error.OutOfMemory;
        }
        aw.writer.writeAll(part) catch return error.OutOfMemory;
    }
    return normalizeWithStyle(allocator, style, aw.written());
}

pub fn resolveWithStyle(
    allocator: Allocator,
    style: PathStyle,
    cwd: []const u8,
    parts: []const []const u8,
) Allocator.Error![]u8 {
    var acc = try allocator.dupe(u8, cwd);
    errdefer allocator.free(acc);

    for (parts) |p| {
        if (p.len == 0) continue;
        if (isAbsoluteWithStyle(style, p)) {
            allocator.free(acc);
            acc = try normalizeWithStyle(allocator, style, p);
        } else {
            const next = try joinWithStyle(allocator, style, &.{ acc, p });
            allocator.free(acc);
            acc = next;
        }
    }
    return normalizeWithStyle(allocator, style, acc);
}

pub fn dirnameWithStyle(style: PathStyle, p: []const u8) []const u8 {
    if (p.len == 0) return ".";
    var end = p.len;
    while (end > 1 and isSep(style, p[end - 1])) : (end -= 1) {}
    const trimmed = p[0..end];

    var idx = trimmed.len;
    while (idx > 0 and !isSep(style, trimmed[idx - 1])) : (idx -= 1) {}
    if (idx == 0) return ".";
    if (idx == 1) return trimmed[0..1];
    return trimmed[0 .. idx - 1];
}

pub fn basenameWithStyle(style: PathStyle, p: []const u8, ext: ?[]const u8) []const u8 {
    if (p.len == 0) return "";
    var end = p.len;
    while (end > 0 and isSep(style, p[end - 1])) : (end -= 1) {}
    if (end == 0) return "";

    var start = end;
    while (start > 0 and !isSep(style, p[start - 1])) : (start -= 1) {}
    const base = p[start..end];

    if (ext) |suffix| {
        if (suffix.len > 0 and base.len > suffix.len and std.mem.endsWith(u8, base, suffix)) {
            return base[0 .. base.len - suffix.len];
        }
        // Tauri `basename('a.html', 'html')` also strips without leading dot if specified cleanly
        if (suffix.len > 0 and suffix[0] != '.' and base.len > suffix.len + 1 and
            std.mem.endsWith(u8, base, suffix) and base[base.len - suffix.len - 1] == '.')
        {
            return base[0 .. base.len - suffix.len - 1];
        }
    }
    return base;
}

/// Returns extension WITHOUT leading `.` per `@tauri-apps/api/path` (`extname('/a/b.html') === 'html'`).
pub fn extnameWithStyle(style: PathStyle, p: []const u8) []const u8 {
    const base = basenameWithStyle(style, p, null);
    if (base.len <= 1) return "";
    var i = base.len;
    while (i > 1) {
        i -= 1;
        if (base[i] == '.') {
            return base[i + 1 ..];
        }
    }
    return "";
}

/// `plugin:path|*` RPC command namespace (`Schema` key: `.path`).
pub const Commands = struct {
    pub const rpc_prefix = "plugin:path|";
    pub const RpcState = PathState;

    pub fn resolve_directory(
        ctx: *rpc.Ctx,
        state: *PathState,
        args: struct { directory: u8, path: ?[]const u8 = null },
    ) PathError![]const u8 {
        const base = try state.resolveBaseAlloc(ctx.scratch, args.directory);
        if (args.path) |sub| {
            if (sub.len > 0) {
                return joinWithStyle(ctx.scratch, state.style, &.{ base, sub });
            }
        }
        return base;
    }

    pub fn resolve(ctx: *rpc.Ctx, state: *PathState, args: struct { paths: []const []const u8 }) PathError![]const u8 {
        return resolveWithStyle(ctx.scratch, state.style, state.cwd, args.paths);
    }

    pub fn normalize(ctx: *rpc.Ctx, state: *PathState, args: struct { path: []const u8 }) PathError![]const u8 {
        return normalizeWithStyle(ctx.scratch, state.style, args.path);
    }

    pub fn join(ctx: *rpc.Ctx, state: *PathState, args: struct { paths: []const []const u8 }) PathError![]const u8 {
        return joinWithStyle(ctx.scratch, state.style, args.paths);
    }

    pub fn dirname(_: *PathState, args: struct { path: []const u8 }) []const u8 {
        return dirnameWithStyle(PathStyle.current(), args.path);
    }

    pub fn extname(_: *PathState, args: struct { path: []const u8 }) []const u8 {
        return extnameWithStyle(PathStyle.current(), args.path);
    }

    pub fn basename(_: *PathState, args: struct { path: []const u8, ext: ?[]const u8 = null }) []const u8 {
        return basenameWithStyle(PathStyle.current(), args.path, args.ext);
    }

    pub fn is_absolute(state: *PathState, args: struct { path: []const u8 }) bool {
        return isAbsoluteWithStyle(state.style, args.path);
    }
};

test "plugin:path resolves all BaseDirectory discriminants and normalizes POSIX + Windows paths" {
    var posix_state: PathState = .{
        .style = .posix,
        .app_identifier = "io.zts.novel",
        .home_dir = "/home/alice",
        .cwd = "/workspace",
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Verify every single discriminant 1..23 resolves cleanly!
    var code: u8 = 1;
    while (code <= 23) : (code += 1) {
        const p = try posix_state.resolveBaseAlloc(arena.allocator(), code);
        try testing.expect(p.len > 0);
    }
    try testing.expectError(error.UnknownBaseDirectory, posix_state.resolveBaseAlloc(arena.allocator(), 99));

    const app_data = try posix_state.resolveBaseAlloc(arena.allocator(), @backingInt(BaseDirectory.app_data));
    try testing.expectEqualStrings("/home/alice/.local/share/io.zts.novel", app_data);

    const joined = try joinWithStyle(arena.allocator(), .posix, &.{ "/home/alice/app", "..", "saves", "slot1.sav" });
    try testing.expectEqualStrings("/home/alice/saves/slot1.sav", joined);

    try testing.expectEqualStrings("html", extnameWithStyle(.posix, "/path/to/index.html"));
    try testing.expectEqualStrings("", extnameWithStyle(.posix, "/path/to/.gitignore"));
    try testing.expectEqualStrings("app", basenameWithStyle(.posix, "/path/to/app.conf", ".conf"));
    try testing.expectEqualStrings("/path/to", dirnameWithStyle(.posix, "/path/to/somedir/"));

    // Windows drive-letter & backslash semantics verified regardless of host OS!
    try testing.expect(isAbsoluteWithStyle(.windows, "C:\\Users\\Alice"));
    try testing.expect(!isAbsoluteWithStyle(.windows, "relative\\file.png"));
    const win_norm = try normalizeWithStyle(arena.allocator(), .windows, "C:\\Users\\Alice\\..\\Bob\\.\\deck.json");
    try testing.expectEqualStrings("C:\\Users\\Bob\\deck.json", win_norm);
}
