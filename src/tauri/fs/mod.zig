//! `zts_tauri.fs` — Capability-Scoped Filesystem Plugin (`@tauri-apps/plugin-fs` v2 wire compatible).
//!
//! ```zig
//! var scope = try fs.Scope.initCanonical(alloc, io, .current(), &.{
//!     .{ .path = app_data_dir },          // recursive grant
//!     .{ .path = config_file, .recursive = false }, // single-file grant
//! });
//! defer scope.deinit();
//!
//! var fs_state = fs.FsState.init(alloc, io, scope, &resources, &paths);
//! defer fs_state.deinit();
//!
//! const App = rpc.merge(.{ MySchema, rpc.Schema(.{ .fs = fs.Commands }) });
//! var router = App.bind(.{ .my_command = &my_state, .fs = &fs_state });
//! ```
//!
//! Everything is Pure Zig (`link_libc = false`) and depends only on `zts_rpc` / `zts_core`:
//! - `scope.zig` — lexical normalization → symlink resolution → component-wise containment.
//! - `commands.zig` — the `plugin:fs|*` namespace (`read_text_file`, `write_file`, `read_dir`,
//!   `stat`, `open`/`read`/`write`/`seek` streaming handles, ...).
//!
//! Unused commands are dropped by dead-code elimination, so an app that only imports
//! `fs.Commands` for `read_text_file` pays nothing for the rest.

const std = @import("std");

pub const scope = @import("scope.zig");
pub const commands = @import("commands.zig");

pub const BaseOptions = commands.BaseOptions;
pub const Commands = commands.Commands;
pub const CopyOptions = commands.CopyOptions;
pub const DirEntry = commands.DirEntry;
pub const FileHandle = commands.FileHandle;
pub const FileInfo = commands.FileInfo;
pub const FsError = commands.FsError;
pub const FsState = commands.FsState;
pub const MkdirOptions = commands.MkdirOptions;
pub const ReadDirOptions = commands.ReadDirOptions;
pub const RemoveOptions = commands.RemoveOptions;
pub const RenameOptions = commands.RenameOptions;
pub const WriteOptions = commands.WriteOptions;
pub const ResolveError = scope.ResolveError;
pub const Scope = scope.Scope;
pub const ScopeRoot = scope.Root;
pub const allowsPath = scope.allowsPath;
pub const canonicalizeAlloc = scope.canonicalizeAlloc;
pub const default_max_io_bytes = commands.default_max_io_bytes;
pub const max_symlink_hops = scope.max_symlink_hops;
pub const pathEql = scope.pathEql;
pub const splitRoot = scope.splitRoot;
pub const toFileInfo = commands.toFileInfo;

test {
    _ = scope;
    _ = commands;
}
