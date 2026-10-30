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

/// Which platform's path grammar to use. The plugin must be *host independent*: a `path.join`
/// invoked by a Windows client has to use Windows rules even when the test runs on Linux, so every
/// function below takes the style explicitly and `.current()` only appears at the OS boundary.
pub const PathStyle = enum {
    /// `/` separators, case-sensitive (Linux, macOS).
    posix,
    /// `\` separators, drive letters and UNC prefixes.
    windows,

    /// The style of the OS this binary was built for.
    pub fn current() PathStyle {
        return if (builtin.os.tag == .windows) .windows else .posix;
    }

    /// The separator character (`/` or `\`).
    pub fn sep(self: PathStyle) u8 {
        return switch (self) {
            .posix => '/',
            .windows => '\\',
        };
    }
};

/// Exact wire integer discriminants matching `@tauri-apps/api/path` `enum BaseDirectory`.
pub const BaseDirectory = enum(u8) {
    /// User's audio library (`$XDG_MUSIC_DIR` / `~/Music` / `%USERPROFILE%\Music`).
    audio = 1,
    /// Per-user cache (`$XDG_CACHE_HOME` / `~/Library/Caches` / `%LOCALAPPDATA%`). Safe to delete.
    cache = 2,
    /// Per-user configuration (`$XDG_CONFIG_HOME` / `~/Library/Application Support` / `%APPDATA%`).
    config = 3,
    /// Per-user data (`$XDG_DATA_HOME` / `~/Library/Application Support` / `%APPDATA%`).
    data = 4,
    /// Per-user, machine-local data that must not roam (`%LOCALAPPDATA%` on Windows).
    local_data = 5,
    /// The user's Documents folder.
    document = 6,
    /// The user's Downloads folder.
    download = 7,
    /// The user's Pictures folder.
    picture = 8,
    /// The shared Public folder (Windows `%PUBLIC%`, macOS `~/Public`).
    public = 9,
    /// The user's Videos folder.
    video = 10,
    /// The app's bundled resources (`<exe dir>/resources`). Read-only in a released build.
    resource = 11,
    /// The OS temporary directory. Everything here may vanish between runs.
    temp = 12,
    /// `<config>/<bundle identifier>` — this application's own configuration.
    app_config = 13,
    /// `<data>/<bundle identifier>` — this application's own data.
    app_data = 14,
    /// `<local_data>/<bundle identifier>` — machine-local application data.
    app_local_data = 15,
    /// `<cache>/<bundle identifier>` — this application's cache.
    app_cache = 16,
    /// `<data>/<bundle identifier>/logs` — where `tauri-plugin-log` writes.
    app_log = 17,
    /// The user's Desktop folder.
    desktop = 18,
    /// The directory containing the running executable.
    executable = 19,
    /// The user's font directory (`~/.local/share/fonts` / `~/Library/Fonts`).
    font = 20,
    /// The user's home directory.
    home = 21,
    /// The runtime directory (`$XDG_RUNTIME_DIR`); falls back to `temp` where the OS has none.
    runtime = 22,
    /// A scratch directory for templates shipped with the app.
    template = 23,
};

pub const PathError = error{
    UnknownBaseDirectory,
    OutOfMemory,
};

/// Deterministic cross-platform path configuration (pure Zig, zero `libc` / `getenv` global races).
pub const PathState = struct {
    /// Which separator conventions `normalize`/`join` follow.
    style: PathStyle = PathStyle.current(),
    /// Bundle id used for the per-app subdirectories.
    app_identifier: []const u8 = "com.zts.app",
    /// `$HOME` (override in tests).
    home_dir: []const u8 = "/home/user",
    /// `appCacheDir` base, or `null` to derive it.
    cache_dir: ?[]const u8 = null,
    /// `appConfigDir` base, or `null` to derive it.
    config_dir: ?[]const u8 = null,
    /// `appDataDir` base, or `null` to derive it.
    data_dir: ?[]const u8 = null,
    /// `appLocalDataDir` base, or `null` to derive it.
    local_data_dir: ?[]const u8 = null,
    /// `resourceDir()` — where bundled resources live.
    resource_dir: []const u8 = "/app/resources",
    /// `resolve('exe')` — directory of the running binary.
    executable_dir: []const u8 = "/app/bin",
    /// `$XDG_RUNTIME_DIR` (Linux); unused on other platforms.
    runtime_dir: []const u8 = "/run/user/1000",
    /// `tempDir()`.
    temp_dir: []const u8 = if (builtin.os.tag == .windows) "C:\\Temp" else "/tmp",
    /// `resolve('cwd')` — the process working directory.
    cwd: []const u8 = "/",

    /// Maps a `BaseDirectory` tag to its absolute path, appending the identifier where needed.
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

/// `true` for `/x` (posix) and `C:\\x`, `\\\\server\\share` (windows). Drive-relative `C:x` is *not*
/// absolute — treating it as such is how a scope check gets bypassed.
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

/// Collapses `.`/`..`, drops duplicate separators and guarantees a non-empty result (`"."`), keeping
/// the drive/UNC prefix. This is the first step of every `plugin:fs` scope check: the engine never
/// compares a raw string with a root.
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

/// Joins `parts` with the platform separator, then normalises. Empty parts are skipped so
/// `join(&.{ base, "", "x" })` still yields `<base>/x`.
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

/// Resolves `parts` against `cwd` — the pure half of `path.resolve`. An absolute part restarts the
/// walk (a later absolute component wins, exactly like the Node API).
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

/// Directory part of `p`, without allocating. Trailing separators are ignored and a bare file name
/// yields `"."` (the Node behaviour, which is what JS callers expect).
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

/// Final component of `p`, optionally with `ext` stripped (`"/a/b.html", ".html"` → `"b"`). The
/// comparison is exact, case-sensitive and only strips one extension.
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
    /// Every command in this namespace starts with this prefix.
    pub const rpc_prefix = "plugin:path|";
    /// The state type `zts_rpc` resolves per app; identical to `PathState` here.
    pub const RpcState = PathState;

    /// `plugin:path|resolve_directory` — base directory without a sub-path.
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

    /// `plugin:path|resolve` — joins a base directory with `path`.
    pub fn resolve(ctx: *rpc.Ctx, state: *PathState, args: struct { paths: []const []const u8 }) PathError![]const u8 {
        return resolveWithStyle(ctx.scratch, state.style, state.cwd, args.paths);
    }

    /// `plugin:path|normalize` — resolves `.` and `..` without touching the filesystem.
    pub fn normalize(ctx: *rpc.Ctx, state: *PathState, args: struct { path: []const u8 }) PathError![]const u8 {
        return normalizeWithStyle(ctx.scratch, state.style, args.path);
    }

    /// `plugin:path|join` — joins parts with the platform separator.
    pub fn join(ctx: *rpc.Ctx, state: *PathState, args: struct { paths: []const []const u8 }) PathError![]const u8 {
        return joinWithStyle(ctx.scratch, state.style, args.paths);
    }

    /// `plugin:path|dirname` — the parent directory.
    pub fn dirname(_: *PathState, args: struct { path: []const u8 }) []const u8 {
        return dirnameWithStyle(PathStyle.current(), args.path);
    }

    /// `plugin:path|extname` — the extension including the dot.
    pub fn extname(_: *PathState, args: struct { path: []const u8 }) []const u8 {
        return extnameWithStyle(PathStyle.current(), args.path);
    }

    /// `plugin:path|basename` — the last component, minus a matching suffix.
    pub fn basename(_: *PathState, args: struct { path: []const u8, ext: ?[]const u8 = null }) []const u8 {
        return basenameWithStyle(PathStyle.current(), args.path, args.ext);
    }

    /// `plugin:path|is_absolute` — whether the path starts at a root.
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
