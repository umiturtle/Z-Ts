//! `plugin:fs|*` — Scoped filesystem commands (`@tauri-apps/plugin-fs` v2 compatible).
//!
//! Every command funnels through [`FsState.resolve`], which canonicalizes (symlink-resolved) the
//! untrusted path and rejects anything outside the configured capability roots
//! (see `scope.zig`). Commands never touch a raw frontend path.
//!
//! ## Wire notes
//! - Names, argument shapes, and result shapes follow `plugins-workspace/plugins/fs/src/commands.rs`
//!   (`plugin:fs|read_text_file`, `plugin:fs|write_text_file`, `plugin:fs|read_dir`, ...).
//! - Tauri returns a raw `ArrayBuffer` for binary reads/writes. `zts_rpc` is a JSON codec, so binary
//!   payloads travel as Base64 [`rpc.Bytes`] (documented in ADR-0011). Text commands stay strings.
//! - File handles are ordinary `zts_tauri` resources (`rid`), closed via `plugin:resources|close`.
//!   Positions are tracked in Zig (`readPositional`/`writePositional`), because Zig 0.17's
//!   `std.Io.File` intentionally exposes no `seek` syscall wrapper.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const rpc = @import("zts_rpc");

const path = @import("../path.zig");
const resources = @import("../resources.zig");
const scope_mod = @import("scope.zig");

pub const Scope = scope_mod.Scope;
pub const ScopeRoot = scope_mod.Root;
pub const ResolveError = scope_mod.ResolveError;
pub const ScopeError = scope_mod.ResolveError;

/// Errors surfaced to the webview. Names are stable: they become `{"code":"<Name>"}` bodies.
pub const FsError = error{
    NotFound,
    AlreadyExists,
    AccessDenied,
    NotADirectory,
    IsADirectory,
    NotAFile,
    DirectoryNotEmpty,
    ReadOnlyFileSystem,
    NameTooLong,
    InvalidPath,
    SymLinkLoop,
    CannotVerify,
    OutOfScope,
    FileTooLarge,
    BadResourceId,
    NotSeekable,
    NegativeOffset,
    OutOfMemory,
    IoFailure,
};

fn mapResolveError(err: ResolveError) FsError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.OutOfScope => error.OutOfScope,
        error.SymLinkLoop => error.SymLinkLoop,
        error.CannotVerify => error.CannotVerify,
        error.InvalidPath => error.InvalidPath,
    };
}

fn mapIoError(err: anyerror) FsError {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.PathAlreadyExists => error.AlreadyExists,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.NotDir => error.NotADirectory,
        error.IsDir => error.IsADirectory,
        error.DirNotEmpty => error.DirectoryNotEmpty,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.NameTooLong => error.NameTooLong,
        error.SymLinkLoop => error.SymLinkLoop,
        error.OutOfMemory => error.OutOfMemory,
        error.FileTooBig => error.FileTooLarge,
        error.OperationAborted, error.Canceled => error.IoFailure,
        else => error.IoFailure,
    };
}

/// Largest single `read`/`write` payload accepted from (or sent to) the webview.
pub const default_max_io_bytes: usize = 16 * 1024 * 1024;

pub const BaseOptions = struct {
    /// `@tauri-apps/api/path` `BaseDirectory` discriminant (`1..23`).
    base_dir: ?u8 = null,
};

pub const WriteOptions = struct {
    base_dir: ?u8 = null,
    append: bool = false,
    create: bool = true,
    create_new: bool = false,
};

pub const OpenOptions = struct {
    base_dir: ?u8 = null,
    read: bool = true,
    write: bool = false,
    append: bool = false,
    truncate: bool = false,
    create: bool = false,
    create_new: bool = false,
};

pub const ReadDirOptions = struct {
    base_dir: ?u8 = null,
};

pub const MkdirOptions = struct {
    base_dir: ?u8 = null,
    recursive: bool = false,
};

pub const RemoveOptions = struct {
    base_dir: ?u8 = null,
    recursive: bool = false,
};

pub const RenameOptions = struct {
    old_path_base_dir: ?u8 = null,
    new_path_base_dir: ?u8 = null,
};

pub const CopyOptions = struct {
    from_path_base_dir: ?u8 = null,
    to_path_base_dir: ?u8 = null,
};

/// Mirrors `plugins-workspace/plugins/fs/src/commands.rs` `FileInfo` (camelCase on the wire).
pub const FileInfo = struct {
    is_file: bool,
    is_directory: bool,
    is_symlink: bool,
    size: rpc.SafeInt,
    /// Milliseconds since the Unix epoch, like JavaScript's `Date.now()`.
    mtime: ?rpc.SafeInt = null,
    atime: ?rpc.SafeInt = null,
    /// `Io.File.Stat` exposes no birth time; always `null` until a backend provides one.
    birthtime: ?rpc.SafeInt = null,
    readonly: bool = false,
    /// Upstream v2 still spells this field `fileAttribues` (sic); kept verbatim for compatibility.
    file_attribues: ?u32 = null,
    dev: ?rpc.SafeInt = null,
    ino: ?rpc.SafeInt = null,
    mode: ?u32 = null,
    nlink: ?rpc.SafeInt = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    rdev: ?rpc.SafeInt = null,
    blksize: ?rpc.SafeInt = null,
    blocks: ?rpc.SafeInt = null,
};

pub const DirEntry = struct {
    name: []const u8,
    is_directory: bool,
    is_file: bool,
    is_symlink: bool,
};

fn toMillis(ts: Io.Timestamp) rpc.SafeInt {
    const ms = ts.toMilliseconds();
    return rpc.SafeInt.init(ms) catch .{ .value = if (ms < 0) rpc.types.min_safe_int else rpc.types.max_safe_int };
}

fn safeU64(v: u64) rpc.SafeInt {
    const as_i: i64 = if (v > @as(u64, @intCast(rpc.types.max_safe_int)))
        rpc.types.max_safe_int
    else
        @intCast(v);
    return .{ .value = as_i };
}

/// Converts a `std.Io.File.Stat` into the wire shape.
pub fn toFileInfo(stat: Io.File.Stat) FileInfo {
    const permissions = stat.permissions;
    const mode_bits: ?u32 = switch (@typeInfo(Io.File.Permissions)) {
        .int => @intCast(permissions),
        else => null,
    };
    const win_attrs: ?u32 = switch (@typeInfo(Io.File.Permissions)) {
        .@"enum" => @intCast(@backingInt(permissions)),
        else => null,
    };
    return .{
        .is_file = stat.kind == .file,
        .is_directory = stat.kind == .directory,
        .is_symlink = stat.kind == .sym_link,
        .size = safeU64(stat.size),
        .mtime = toMillis(stat.mtime),
        .atime = if (stat.atime) |at| toMillis(at) else null,
        .readonly = false,
        .file_attribues = win_attrs,
        .ino = safeU64(@intCast(stat.inode)),
        .nlink = safeU64(@intCast(stat.nlink)),
        .mode = mode_bits,
    };
}

/// An open file, stored in the shared [`resources.ResourceTable`].
pub const FileHandle = struct {
    allocator: Allocator,
    io: Io,
    file: Io.File,
    /// Logical cursor, advanced by `read`/`write` and repositioned by `seek`.
    pos: u64 = 0,
    /// Canonical absolute path (owned), for diagnostics and `rename`-free re-resolution.
    path: []u8,

    pub fn deinit(self: *FileHandle) void {
        self.file.close(self.io);
        self.allocator.free(self.path);
    }

    fn appendMode(self: *FileHandle, io: Io) FsError!void {
        self.pos = self.file.length(io) catch |err| return mapIoError(err);
    }
};

/// RPC state for the `plugin:fs|*` namespace.
pub const FsState = struct {
    allocator: Allocator,
    io: Io,
    scope: Scope,
    resources: *resources.ResourceTable,
    /// Resolves relative paths and `BaseDirectory` discriminants (`plugin:path|*`).
    paths: *path.PathState,
    max_io_bytes: usize = default_max_io_bytes,

    pub fn init(
        allocator: Allocator,
        io: Io,
        scope: Scope,
        res: *resources.ResourceTable,
        paths: *path.PathState,
    ) FsState {
        return .{
            .allocator = allocator,
            .io = io,
            .scope = scope,
            .resources = res,
            .paths = paths,
        };
    }

    pub fn deinit(self: *FsState) void {
        self.scope.deinit();
    }

    /// Resolves `raw` (relative to `base_dir` when given) into a canonical in-scope path
    /// allocated from `scratch` (typically `rpc.Ctx.scratch`).
    pub fn resolve(
        self: *const FsState,
        scratch: Allocator,
        raw: []const u8,
        base_dir: ?u8,
    ) FsError![]const u8 {
        const anchored = if (base_dir) |dir| blk: {
            const base = self.paths.resolveBaseAlloc(scratch, dir) catch |err| return switch (err) {
                error.UnknownBaseDirectory => error.InvalidPath,
                error.OutOfMemory => error.OutOfMemory,
            };
            break :blk if (path.isAbsoluteWithStyle(self.scope.style, raw))
                raw
            else
                path.joinWithStyle(scratch, self.scope.style, &.{ base, raw }) catch |e| return mapIoError(e);
        } else raw;

        return self.scope.resolveAlloc(self.io, scratch, anchored, self.paths.cwd) catch |err| return mapResolveError(err);
    }

    fn openHandle(self: *FsState, canonical: []const u8, mode: Io.Dir.OpenFileOptions) FsError!u53 {
        const file = Io.Dir.cwd().openFile(self.io, canonical, mode) catch |err| return mapIoError(err);
        errdefer file.close(self.io);

        const owned_path = try self.allocator.dupe(u8, canonical);
        errdefer self.allocator.free(owned_path);

        const handle = self.resources.insertOwned(FileHandle, .{
            .allocator = self.allocator,
            .io = self.io,
            .file = file,
            .path = owned_path,
        }) catch |err| return mapIoError(err);
        return handle;
    }

    fn getHandle(self: *FsState, rid: u53) FsError!*FileHandle {
        return self.resources.getPtr(FileHandle, rid) catch error.BadResourceId;
    }

    fn readAlloc(self: *FsState, allocator: Allocator, canonical: []const u8, limit: usize) FsError![]u8 {
        const file = Io.Dir.cwd().openFile(self.io, canonical, .{ .mode = .read_only, .allow_directory = false }) catch |err| return mapIoError(err);
        defer file.close(self.io);

        const stat = file.stat(self.io) catch |err| return mapIoError(err);
        if (stat.kind == .directory) return error.IsADirectory;
        if (stat.size > limit) return error.FileTooLarge;

        const buf = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(buf);
        if (buf.len == 0) return buf;

        var read: usize = 0;
        while (read < buf.len) {
            const n = file.readPositionalAll(self.io, buf[read..], read) catch |err| return mapIoError(err);
            if (n == 0) break;
            read += n;
        }
        if (read == buf.len) return buf;
        return allocator.realloc(buf, read);
    }

    fn writeAll(self: *FsState, canonical: []const u8, data: []const u8, opts: WriteOptions) FsError!void {
        if (data.len > self.max_io_bytes) return error.FileTooLarge;

        var file: Io.File = undefined;
        if (opts.append and !opts.create_new) {
            file = Io.Dir.cwd().openFile(self.io, canonical, .{ .mode = .read_write, .allow_directory = false }) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    if (!opts.create) return error.NotFound;
                    break :blk Io.Dir.cwd().createFile(self.io, canonical, .{ .read = true, .truncate = false }) catch |e| return mapIoError(e);
                },
                else => return mapIoError(err),
            };
        } else if (opts.create_new) {
            file = Io.Dir.cwd().createFile(self.io, canonical, .{ .read = true, .truncate = false, .exclusive = true }) catch |err| return mapIoError(err);
        } else if (opts.create) {
            file = Io.Dir.cwd().createFile(self.io, canonical, .{ .read = true, .truncate = true }) catch |err| return mapIoError(err);
        } else {
            file = Io.Dir.cwd().openFile(self.io, canonical, .{ .mode = .read_write, .allow_directory = false }) catch |err| return mapIoError(err);
        }
        defer file.close(self.io);

        var offset: u64 = 0;
        if (opts.append) offset = file.length(self.io) catch |err| return mapIoError(err);
        file.writePositionalAll(self.io, data, offset) catch |err| return mapIoError(err);
    }

    fn dirSize(self: *FsState, canonical: []const u8, budget: *usize) FsError!u64 {
        const dir = Io.Dir.cwd().openDir(self.io, canonical, .{ .iterate = true }) catch |err| return mapIoError(err);
        defer dir.close(self.io);

        var total: u64 = 0;
        var it = dir.iterate();
        while (it.next(self.io) catch |err| return mapIoError(err)) |entry| {
            if (budget.* == 0) return error.FileTooLarge;
            budget.* -= 1;
            const child = path.joinWithStyle(self.allocator, self.scope.style, &.{ canonical, entry.name }) catch |e| return mapIoError(e);
            defer self.allocator.free(child);
            // Never follow a symlink while sizing: it would leak the size of an out-of-scope target.
            const st = Io.Dir.cwd().statFile(self.io, child, .{ .follow_symlinks = false }) catch |err| return mapIoError(err);
            switch (st.kind) {
                .file => total += st.size,
                .directory => {
                    if (!self.scope.allowsCanonical(child)) continue;
                    total += try self.dirSize(child, budget);
                },
                else => {},
            }
        }
        return total;
    }
};

fn joinInRoot(state: *FsState, scratch: Allocator, dir: []const u8, name: []const u8) FsError![]const u8 {
    return path.joinWithStyle(scratch, state.scope.style, &.{ dir, name }) catch |e| return mapIoError(e);
}

/// `plugin:fs|*` RPC command namespace (`Schema` key: `.fs`).
pub const Commands = struct {
    pub const rpc_prefix = "plugin:fs|";
    pub const RpcState = FsState;

    // ---------------------------------------------------------------- metadata

    pub fn exists(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?BaseOptions = null }) FsError!bool {
        const target = try state.resolve(ctx.scratch, args.path, (args.options orelse BaseOptions{}).base_dir);
        const st = Io.Dir.cwd().statFile(state.io, target, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return mapIoError(err),
        };
        _ = st;
        return true;
    }

    pub fn stat(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?BaseOptions = null }) FsError!FileInfo {
        const target = try state.resolve(ctx.scratch, args.path, (args.options orelse BaseOptions{}).base_dir);
        const st = Io.Dir.cwd().statFile(state.io, target, .{ .follow_symlinks = true }) catch |err| return mapIoError(err);
        return toFileInfo(st);
    }

    pub fn lstat(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?BaseOptions = null }) FsError!FileInfo {
        const target = try state.resolve(ctx.scratch, args.path, (args.options orelse BaseOptions{}).base_dir);
        const st = Io.Dir.cwd().statFile(state.io, target, .{ .follow_symlinks = false }) catch |err| return mapIoError(err);
        return toFileInfo(st);
    }

    pub fn size(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?BaseOptions = null }) FsError!rpc.SafeInt {
        const target = try state.resolve(ctx.scratch, args.path, (args.options orelse BaseOptions{}).base_dir);
        const st = Io.Dir.cwd().statFile(state.io, target, .{ .follow_symlinks = true }) catch |err| return mapIoError(err);
        if (st.kind != .directory) return safeU64(st.size);

        var budget: usize = 65_536;
        return safeU64(try state.dirSize(target, &budget));
    }

    // ------------------------------------------------------------ whole files

    pub fn read_text_file(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?BaseOptions = null }) FsError![]const u8 {
        const target = try state.resolve(ctx.scratch, args.path, (args.options orelse BaseOptions{}).base_dir);
        return state.readAlloc(ctx.scratch, target, state.max_io_bytes);
    }

    pub fn read_file(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?BaseOptions = null }) FsError!rpc.Bytes {
        const target = try state.resolve(ctx.scratch, args.path, (args.options orelse BaseOptions{}).base_dir);
        return rpc.Bytes.init(try state.readAlloc(ctx.scratch, target, state.max_io_bytes));
    }

    pub fn write_text_file(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, data: []const u8, options: ?WriteOptions = null }) FsError!void {
        const opts = args.options orelse WriteOptions{};
        const target = try state.resolve(ctx.scratch, args.path, opts.base_dir);
        try state.writeAll(target, args.data, opts);
    }

    pub fn write_file(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, data: rpc.Bytes, options: ?WriteOptions = null }) FsError!void {
        const opts = args.options orelse WriteOptions{};
        const target = try state.resolve(ctx.scratch, args.path, opts.base_dir);
        try state.writeAll(target, args.data.slice(), opts);
    }

    // -------------------------------------------------------------- structure

    pub fn mkdir(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?MkdirOptions = null }) FsError!void {
        const opts = args.options orelse MkdirOptions{};
        const target = try state.resolve(ctx.scratch, args.path, opts.base_dir);
        if (opts.recursive) {
            Io.Dir.cwd().createDirPath(state.io, target) catch |err| return mapIoError(err);
        } else {
            Io.Dir.cwd().createDir(state.io, target, .default_dir) catch |err| return mapIoError(err);
        }
    }

    pub fn remove(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?RemoveOptions = null }) FsError!void {
        const opts = args.options orelse RemoveOptions{};
        const target = try state.resolve(ctx.scratch, args.path, opts.base_dir);
        const st = Io.Dir.cwd().statFile(state.io, target, .{ .follow_symlinks = false }) catch |err| return mapIoError(err);
        switch (st.kind) {
            .directory => {
                if (opts.recursive) {
                    Io.Dir.cwd().deleteTree(state.io, target) catch |err| return mapIoError(err);
                } else {
                    Io.Dir.cwd().deleteDir(state.io, target) catch |err| return mapIoError(err);
                }
            },
            else => Io.Dir.cwd().deleteFile(state.io, target) catch |err| return mapIoError(err),
        }
    }

    pub fn rename(ctx: *rpc.Ctx, state: *FsState, args: struct { old_path: []const u8, new_path: []const u8, options: ?RenameOptions = null }) FsError!void {
        const opts = args.options orelse RenameOptions{};
        const from = try state.resolve(ctx.scratch, args.old_path, opts.old_path_base_dir);
        const to = try state.resolve(ctx.scratch, args.new_path, opts.new_path_base_dir);
        Io.Dir.cwd().rename(from, Io.Dir.cwd(), to, state.io) catch |err| return mapIoError(err);
    }

    pub fn copy_file(ctx: *rpc.Ctx, state: *FsState, args: struct { from_path: []const u8, to_path: []const u8, options: ?CopyOptions = null }) FsError!void {
        const opts = args.options orelse CopyOptions{};
        const from = try state.resolve(ctx.scratch, args.from_path, opts.from_path_base_dir);
        const to = try state.resolve(ctx.scratch, args.to_path, opts.to_path_base_dir);

        const src = Io.Dir.cwd().openFile(state.io, from, .{ .mode = .read_only, .allow_directory = false }) catch |err| return mapIoError(err);
        defer src.close(state.io);
        const dst = Io.Dir.cwd().createFile(state.io, to, .{ .truncate = true }) catch |err| return mapIoError(err);
        defer dst.close(state.io);

        var buf: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = src.readPositionalAll(state.io, &buf, offset) catch |err| return mapIoError(err);
            if (n == 0) break;
            dst.writePositionalAll(state.io, buf[0..n], offset) catch |err| return mapIoError(err);
            offset += n;
        }
    }

    pub fn read_dir(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?ReadDirOptions = null }) FsError![]DirEntry {
        const opts = args.options orelse ReadDirOptions{};
        const target = try state.resolve(ctx.scratch, args.path, opts.base_dir);

        const dir = Io.Dir.cwd().openDir(state.io, target, .{ .iterate = true }) catch |err| return mapIoError(err);
        defer dir.close(state.io);

        var out: std.ArrayList(DirEntry) = .empty;
        errdefer out.deinit(ctx.scratch);

        var it = dir.iterate();
        while (it.next(state.io) catch |err| return mapIoError(err)) |entry| {
            // Report the link itself, never what it points at (a link may leave the scope).
            const is_symlink = entry.kind == .sym_link;
            const child = path.joinWithStyle(ctx.scratch, state.scope.style, &.{ target, entry.name }) catch |e| return mapIoError(e);
            const in_scope = state.scope.allowsCanonical(child);
            if (!in_scope) continue;
            try out.append(ctx.scratch, .{
                .name = try ctx.scratch.dupe(u8, entry.name),
                .is_directory = entry.kind == .directory,
                .is_file = entry.kind == .file,
                .is_symlink = is_symlink,
            });
        }
        return out.toOwnedSlice(ctx.scratch);
    }

    // ------------------------------------------------------- streaming handles

    pub fn create(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, options: ?BaseOptions = null }) FsError!u53 {
        const target = try state.resolve(ctx.scratch, args.path, (args.options orelse BaseOptions{}).base_dir);
        return state.openHandle(target, .{ .mode = .read_write, .allow_directory = false });
    }

    pub fn open(ctx: *rpc.Ctx, state: *FsState, args: struct {
        path: []const u8,
        options: ?OpenOptions = null,
    }) FsError!u53 {
        const opts = args.options orelse OpenOptions{};
        const target = try state.resolve(ctx.scratch, args.path, opts.base_dir);

        const mode: Io.Dir.OpenFileOptions.Mode = if (opts.write or opts.append or opts.truncate)
            (if (opts.read) .read_write else .write_only)
        else
            .read_only;

        if (opts.create_new or opts.create) {
            const file = Io.Dir.cwd().createFile(state.io, target, .{
                .read = opts.read,
                .truncate = opts.truncate,
                .exclusive = opts.create_new,
            }) catch |err| return mapIoError(err);
            errdefer file.close(state.io);
            const owned_path = try state.allocator.dupe(u8, target);
            errdefer state.allocator.free(owned_path);
            return state.resources.insertOwned(FileHandle, .{
                .allocator = state.allocator,
                .io = state.io,
                .file = file,
                .path = owned_path,
            }) catch |err| return mapIoError(err);
        }

        const rid = try state.openHandle(target, .{ .mode = mode, .allow_directory = false });
        if (opts.append) {
            const h = try state.getHandle(rid);
            try h.appendMode(state.io);
        }
        return rid;
    }

    pub fn read(ctx: *rpc.Ctx, state: *FsState, args: struct { rid: u53, len: u32 }) FsError!rpc.Bytes {
        const h = try state.getHandle(args.rid);
        const want = @min(@as(usize, args.len), state.max_io_bytes);
        if (want == 0) return rpc.Bytes.empty();

        const buf = ctx.scratch.alloc(u8, want) catch return error.OutOfMemory;
        const n = h.file.readPositionalAll(state.io, buf, h.pos) catch |err| return mapIoError(err);
        h.pos += n;
        return rpc.Bytes.init(buf[0..n]);
    }

    pub fn write(ctx: *rpc.Ctx, state: *FsState, args: struct { rid: u53, data: rpc.Bytes }) FsError!rpc.SafeInt {
        _ = ctx;
        const h = try state.getHandle(args.rid);
        const data = args.data.slice();
        if (data.len > state.max_io_bytes) return error.FileTooLarge;
        h.file.writePositionalAll(state.io, data, h.pos) catch |err| return mapIoError(err);
        h.pos += data.len;
        return safeU64(data.len);
    }

    pub fn seek(ctx: *rpc.Ctx, state: *FsState, args: struct { rid: u53, offset: rpc.SafeInt, whence: u8 }) FsError!rpc.SafeInt {
        _ = ctx;
        const h = try state.getHandle(args.rid);

        const base: i128 = switch (args.whence) {
            0 => 0, // Start
            1 => @intCast(h.pos), // Current
            2 => @intCast(h.file.length(state.io) catch |err| return mapIoError(err)), // End
            else => return error.InvalidPath,
        };
        const next = base + @as(i128, args.offset.get());
        if (next < 0) return error.NegativeOffset;
        if (next > @as(i128, @intCast(std.math.maxInt(u64)))) return error.InvalidPath;
        h.pos = @intCast(next);
        return safeU64(h.pos);
    }

    pub fn fstat(ctx: *rpc.Ctx, state: *FsState, args: struct { rid: u53 }) FsError!FileInfo {
        _ = ctx;
        const h = try state.getHandle(args.rid);
        const st = h.file.stat(state.io) catch |err| return mapIoError(err);
        return toFileInfo(st);
    }

    pub fn truncate(ctx: *rpc.Ctx, state: *FsState, args: struct { path: []const u8, len: rpc.SafeInt, options: ?BaseOptions = null }) FsError!void {
        const target = try state.resolve(ctx.scratch, args.path, (args.options orelse BaseOptions{}).base_dir);
        const file = Io.Dir.cwd().openFile(state.io, target, .{ .mode = .read_write, .allow_directory = false }) catch |err| return mapIoError(err);
        defer file.close(state.io);
        if (args.len.get() < 0) return error.NegativeOffset;
        file.setLength(state.io, @intCast(args.len.get())) catch |err| return mapIoError(err);
    }

    pub fn ftruncate(ctx: *rpc.Ctx, state: *FsState, args: struct { rid: u53, len: rpc.SafeInt }) FsError!void {
        _ = ctx;
        const h = try state.getHandle(args.rid);
        if (args.len.get() < 0) return error.NegativeOffset;
        h.file.setLength(state.io, @intCast(args.len.get())) catch |err| return mapIoError(err);
    }
};

// ============================================================================
// Tests: full RPC dispatch through `plugin:fs|*`
// ============================================================================

const TestSchema = rpc.Schema(.{ .fs = Commands, .resources = resources.Commands });

const TestFixture = struct {
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    arena: std.heap.ArenaAllocator,
    scope: Scope = undefined,
    resources: resources.ResourceTable = undefined,
    paths: path.PathState = undefined,
    state: FsState = undefined,

    fn create() !*TestFixture {
        const self = try testing.allocator.create(TestFixture);
        errdefer testing.allocator.destroy(self);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        const len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..len];
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);

        self.scope = try Scope.initCanonical(testing.allocator, testing.io, path.PathStyle.current(), &.{
            .{ .path = self.root },
        });
        self.resources = resources.ResourceTable.init(testing.allocator, testing.io);
        self.paths = .{ .cwd = self.root, .temp_dir = self.root };
        self.state = FsState.init(testing.allocator, testing.io, self.scope, &self.resources, &self.paths);
        return self;
    }

    fn destroy(self: *TestFixture) void {
        self.state.deinit();
        self.resources.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    fn resetScratch(self: *TestFixture) void {
        _ = self.arena.reset(.retain_capacity);
    }

    fn invoke(self: *TestFixture, command: []const u8, payload: []const u8) !Response {
        self.resetScratch();
        var router = TestSchema.bind(.{ .fs = &self.state, .resources = &self.resources });
        var handler = router.handler();
        var ctx = rpc.Ctx.init(testing.io, self.arena.allocator());
        return .{ .resp = handler.dispatch(testing.allocator, &ctx, command, payload) };
    }

    const Response = struct {
        resp: @import("zts_core").OutgoingResponse,

        fn deinit(self: *Response) void {
            self.resp.deinit();
        }
        fn body(self: *const Response) []const u8 {
            return self.resp.body.slice();
        }
        fn expectOk(self: *const Response) !void {
            try testing.expectEqual(@import("zts_core").IpcStatus.ok, self.resp.status);
        }
        fn expectOctetStream(self: *const Response, bytes: []const u8) !void {
            try testing.expectEqual(@import("zts_core").IpcStatus.ok, self.resp.status);
            try testing.expectEqualStrings("application/octet-stream", self.resp.content_type);
            try testing.expectEqualStrings(bytes, self.body());
        }
        fn expectCode(self: *const Response, code: []const u8) !void {
            try testing.expectEqual(@as(u16, 400), self.resp.http_code);
            const expected = try std.fmt.allocPrint(testing.allocator, "{{\"code\":\"{s}\"}}", .{code});
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, self.body());
        }
    };

    fn makeSymlink(self: *TestFixture, target: []const u8, link_path: []const u8) !bool {
        self.tmp.dir.symLink(testing.io, target, link_path, .{}) catch |err| switch (err) {
            // Windows requires Developer Mode / SeCreateSymbolicLinkPrivilege.
            error.AccessDenied, error.PermissionDenied => return false,
            else => return err,
        };
        return true;
    }
};

test "plugin:fs round-trips text, binary, metadata, and directory listings" {
    var f = try TestFixture.create();
    defer f.destroy();

    {
        var r = try f.invoke("plugin:fs|write_text_file", "{\"path\":\"hello.txt\",\"data\":\"こんにちは world\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("null", r.body());
    }

    {
        var r = try f.invoke("plugin:fs|read_text_file", "{\"path\":\"hello.txt\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("\"こんにちは world\"", r.body());
    }

    {
        // Binary writes travel as Base64 (`rpc.Bytes`).
        var r = try f.invoke("plugin:fs|write_file", "{\"path\":\"bin.dat\",\"data\":\"aGkA\"}");
        defer r.deinit();
        try r.expectOk();
    }
    {
        // A top-level `Bytes` result is emitted as a raw body (Tauri `ipc::Response` parity),
        // not as a JSON string.
        var r = try f.invoke("plugin:fs|read_file", "{\"path\":\"bin.dat\"}");
        defer r.deinit();
        try r.expectOctetStream("hi\x00");
    }

    {
        var r = try f.invoke("plugin:fs|exists", "{\"path\":\"hello.txt\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("true", r.body());
    }
    {
        var r = try f.invoke("plugin:fs|exists", "{\"path\":\"nope.txt\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("false", r.body());
    }

    {
        var r = try f.invoke("plugin:fs|stat", "{\"path\":\"hello.txt\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expect(std.mem.indexOf(u8, r.body(), "\"isFile\":true") != null);
        try testing.expect(std.mem.indexOf(u8, r.body(), "\"size\":21") != null);
        // Upstream's `fileAttribues` typo is preserved verbatim.
        try testing.expect(std.mem.indexOf(u8, r.body(), "\"fileAttribues\":") != null);
    }

    {
        var r = try f.invoke("plugin:fs|mkdir", "{\"path\":\"sub\",\"options\":{\"recursive\":true}}");
        defer r.deinit();
        try r.expectOk();
    }
    {
        var r = try f.invoke("plugin:fs|read_dir", "{\"path\":\".\"}");
        defer r.deinit();
        try r.expectOk();
        const body = r.body();
        try testing.expect(std.mem.indexOf(u8, body, "{\"name\":\"hello.txt\",\"isDirectory\":false,\"isFile\":true,\"isSymlink\":false}") != null);
        try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"sub\",\"isDirectory\":true") != null);
    }

    {
        var r = try f.invoke("plugin:fs|copy_file", "{\"fromPath\":\"hello.txt\",\"toPath\":\"copy.txt\"}");
        defer r.deinit();
        try r.expectOk();
    }
    {
        var r = try f.invoke("plugin:fs|rename", "{\"oldPath\":\"copy.txt\",\"newPath\":\"moved.txt\"}");
        defer r.deinit();
        try r.expectOk();
    }
    {
        var r = try f.invoke("plugin:fs|size", "{\"path\":\"moved.txt\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("21", r.body());
    }
    {
        var r = try f.invoke("plugin:fs|remove", "{\"path\":\"sub\",\"options\":{\"recursive\":true}}");
        defer r.deinit();
        try r.expectOk();
    }
    {
        var r = try f.invoke("plugin:fs|exists", "{\"path\":\"sub\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("false", r.body());
    }
}

test "plugin:fs denies `..` traversal, out-of-scope absolute paths, and symlink escapes" {
    var f = try TestFixture.create();
    defer f.destroy();

    {
        var r = try f.invoke("plugin:fs|read_text_file", "{\"path\":\"../../../etc/passwd\"}");
        defer r.deinit();
        try r.expectCode("OutOfScope");
    }
    {
        var r = try f.invoke("plugin:fs|write_text_file", "{\"path\":\"/tmp/zts-escape.txt\",\"data\":\"x\"}");
        defer r.deinit();
        try r.expectCode("OutOfScope");
    }

    // <tmp>/outside/secret.txt + <tmp>/link -> ../outside : reading through the link must fail.
    try f.tmp.dir.createDir(testing.io, "outside", .default_dir);
    {
        const file = try f.tmp.dir.createFile(testing.io, "outside/secret.txt", .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "top secret");
    }
    if (try f.makeSymlink("../outside", "link")) {
        var r = try f.invoke("plugin:fs|read_text_file", "{\"path\":\"link/secret.txt\"}");
        defer r.deinit();
        try r.expectCode("OutOfScope");

        // The link itself is reported by `read_dir`, but only because its own path is in scope.
        var listing = try f.invoke("plugin:fs|read_dir", "{\"path\":\".\"}");
        defer listing.deinit();
        try listing.expectOk();
        try testing.expect(std.mem.indexOf(u8, listing.body(), "\"name\":\"link\"") != null);
    }
}

test "plugin:fs stream handles: open, write, seek, read, ftruncate, fstat, close" {
    const f = try TestFixture.create();
    defer f.destroy();

    var open_payload: [128]u8 = undefined;
    var rid: u53 = 0;
    {
        const payload = try std.fmt.bufPrint(&open_payload, "{{\"path\":\"stream.txt\",\"options\":{{\"read\":true,\"write\":true,\"create\":true,\"truncate\":true}}}}", .{});
        var r = try f.invoke("plugin:fs|open", payload);
        defer r.deinit();
        try r.expectOk();
        rid = try std.fmt.parseInt(u53, r.body(), 10);
    }

    {
        const payload = try std.fmt.bufPrint(&open_payload, "{{\"rid\":{d},\"data\":\"aGVsbG8=\"}}", .{rid}); // "hello"
        var r = try f.invoke("plugin:fs|write", payload);
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("5", r.body());
    }
    {
        // Seek back to the start, then to offset 1 relative to Current.
        const p1 = try std.fmt.bufPrint(&open_payload, "{{\"rid\":{d},\"offset\":0,\"whence\":0}}", .{rid});
        var r1 = try f.invoke("plugin:fs|seek", p1);
        defer r1.deinit();
        try r1.expectOk();
        try testing.expectEqualStrings("0", r1.body());
    }
    {
        const payload = try std.fmt.bufPrint(&open_payload, "{{\"rid\":{d},\"len\":3}}", .{rid});
        var r = try f.invoke("plugin:fs|read", payload);
        defer r.deinit();
        try r.expectOctetStream("hel");
    }
    {
        const payload = try std.fmt.bufPrint(&open_payload, "{{\"rid\":{d}}}", .{rid});
        var r = try f.invoke("plugin:fs|fstat", payload);
        defer r.deinit();
        try r.expectOk();
        try testing.expect(std.mem.indexOf(u8, r.body(), "\"size\":5") != null);
    }
    {
        const payload = try std.fmt.bufPrint(&open_payload, "{{\"rid\":{d},\"len\":2}}", .{rid});
        var r = try f.invoke("plugin:fs|ftruncate", payload);
        defer r.deinit();
        try r.expectOk();
    }
    {
        var r = try f.invoke("plugin:fs|read_text_file", "{\"path\":\"stream.txt\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("\"he\"", r.body());
    }
    {
        const payload = try std.fmt.bufPrint(&open_payload, "{{\"rid\":{d}}}", .{rid});
        var r = try f.invoke("plugin:resources|close", payload);
        defer r.deinit();
        try r.expectOk();
    }
    {
        // A closed handle is a bad rid, not UB.
        const payload = try std.fmt.bufPrint(&open_payload, "{{\"rid\":{d},\"len\":1}}", .{rid});
        var r = try f.invoke("plugin:fs|read", payload);
        defer r.deinit();
        try r.expectCode("BadResourceId");
    }
}
