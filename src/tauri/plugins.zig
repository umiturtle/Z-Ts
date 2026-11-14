//! P2 — optional official-plugin namespaces, as **standalone** `rpc.Schema` modules.
//!
//! Design rule (unused modules must link 0 bytes): an app merges only the namespaces it uses, so an app that never
//! calls `store` links 0 bytes of it. Nothing here is added to `CorePluginsSchema`, and nothing
//! here imports an OS GUI toolkit. Every command name matches the upstream
//! `@tauri-apps/plugin-*` package, so an unmodified frontend keeps working.
//!
//! ```zig
//! const S = rpc.Schema(.{
//!     .store = plugins.StoreCommands,
//!     .log = plugins.LogCommands,
//!     .os = plugins.OsCommands,
//! });
//! var state = try plugins.PluginState.init(allocator, io, .{});
//! defer state.deinit();
//! var bound = S.bind(.{ .store = &state, .log = &state, .os = &state });
//! ```
//!
//! What is deliberately NOT here (see `docs/architecture/tauri-feature-gap.md` §4):
//! * `plugin-http` / `websocket` / `upload` / `updater` — need a TLS stack (external dependency).
//! * `sql` / `stronghold` / mobile-only plugins — external engines or wrong targets.
//! * `global-shortcut`, native notifications, `deep-link`, `autostart` — need OS hooks / registry /
//!   plist / `.desktop` writes. `notification` below is the **in-app event + ring buffer** form;
//!   the OS notification center is intentionally not faked.
//! * signing / notarytool / MSI / NSIS / AppImage — external tools, already deferred in the
//!   packaging design. `.icns` is the one Pure-Zig artefact added (see `src/bundler/icns.zig`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");
const monitor = @import("monitor.zig");

pub const PluginError = error{
    OutOfMemory,
    /// A provider (opener) or an OS facility is not installed on this host.
    Unsupported,
    /// An enum / numeric argument was outside the documented range.
    InvalidValue,
    /// The store / lock file could not be written.
    PersistFailed,
    /// `restore()` found no saved file (normal on first launch).
    StoreMissing,
    /// The saved file exists but cannot be read.
    StoreUnreadable,
    /// The saved file is not a JSON object of raw values.
    StoreMalformed,
};

/// Result of the store restore attempted at startup. The app can inspect this instead of an
/// empty state appearing silently after an unreadable or corrupt file.
pub const RestoreDiagnostics = struct {
    pub const Status = enum {
        /// The saved file was read and every key restored.
        ok,
        /// No saved file exists yet (normal on first launch).
        missing,
        /// The saved file exists but could not be read.
        unreadable,
        /// The saved file is not a JSON object of raw values.
        malformed,
    };
    /// What happened to the saved file.
    status: Status = .ok,
    /// How many keys were restored (0 unless `status == .ok`).
    restored_keys: usize = 0,
};

/// Maximum number of log lines / notifications retained, so a long-running app cannot grow
/// without bound. Deterministic on all three OSes.
pub const max_log_lines = 256;
/// Max notifications exposed by this module.
pub const max_notifications = 64;

/// One retained log line.
pub const LogLine = struct {
    /// Severity string (`trace` / `debug` / `info` / `warn` / `error`).
    level: []const u8,
    /// Rendered log message.
    message: []const u8,
};

/// One retained in-app notification.
pub const Notification = struct {
    /// Monotonically increasing notification id.
    id: u32,
    /// Notification title shown in the in-app event.
    title: []const u8,
    /// Optional notification body.
    body: []const u8,
};

/// Provider for `opener` / `shell`. Installing one is optional; without it the commands return
/// `error.Unsupported` instead of silently spawning a process. Native backends can supply it
/// without any `if (windows)` branch in application code.
pub const OpenerProvider = struct {
    /// Opaque pointer handed back to every provider callback.
    ctx: ?*anyopaque = null,
    /// Optional callback that opens a URL or path in the host application.
    open: ?*const fn (?*anyopaque, []const u8) void = null,
};

/// Construction options shared by every P2 namespace.
pub const Options = struct {
    /// Snapshot of `argv[1..]` for `plugin:cli`.
    argv: []const []const u8 = &.{},
    /// JSON file the store is persisted to. `null` = in-memory only.
    store_path: ?[]const u8 = null,
    /// Advisory lock file for `single-instance`. `null` = in-memory only (always primary).
    lock_path: ?[]const u8 = null,
    /// Optional provider for `plugin:opener` / `shell`.
    opener: OpenerProvider = .{},
    /// Persist after every mutating store command. `false` restores the explicit-`save`-only
    /// behaviour; `store_path == null` makes this a no-op.
    autosave: bool = true,
    /// Where startup restore diagnostics are recorded (may be `null`).
    restore_diagnostics: ?*RestoreDiagnostics = null,
    /// Returns this process's id. Required, together with `process_alive`, for stale-lock
    /// recovery. Supplied by `zts_tauri_native.providers()`; Pure Zig callers leave it `null`.
    current_pid: ?*const fn () u32 = null,
    /// Whether `pid` still names a live process. `null` = fail-closed (keep the lock).
    process_alive: ?*const fn (u32, ?*anyopaque) bool = null,
    /// Opaque pointer handed to `process_alive`.
    process_alive_ctx: ?*anyopaque = null,
};

/// One state object can back every P2 namespace. All owned strings live in `allocator`; a HashMap
/// entry owns both its key and its (raw JSON) value.
pub const PluginState = struct {
    /// Allocator that owns this object's strings and buffers.
    allocator: Allocator,
    /// IO reactor used for filesystem access and mutexes.
    io: Io,
    /// Raw JSON values keyed by string.
    store: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Optional JSON file the store is persisted to.
    store_path: ?[]const u8 = null,
    /// Returns every retained log line in insertion order.
    logs: std.ArrayList(LogLine) = .empty,
    /// Bounded ring buffer of recent in-app notifications.
    notifications: std.ArrayList(Notification) = .empty,
    /// Monotonically increasing id for the next notification.
    next_notification_id: u32 = 1,
    /// Snapshot of `argv[1..]` used by `plugin:cli`.
    argv: []const []const u8 = &.{},
    /// Optional provider for `plugin:opener` / `shell`.
    opener: OpenerProvider = .{},
    /// Optional advisory lock file; `null` means in-memory only.
    lock_path: ?[]const u8 = null,
    /// Whether this process currently owns the single-instance lock.
    lock_held: bool = false,
    /// Exit code recorded by `plugin:process|exit`, or `null`.
    requested_exit_code: ?i32 = null,
    /// Persist after every mutating store command (see `Options.autosave`).
    autosave: bool = true,
    /// Where startup restore diagnostics are recorded.
    restore_diagnostics: ?*RestoreDiagnostics = null,
    /// True while `restore()` is replaying a file: do not write it back on every key.
    restoring: bool = false,
    /// OS process-id provider for the single-instance lock.
    current_pid: ?*const fn () u32 = null,
    /// OS liveness provider for stale-lock recovery.
    process_alive: ?*const fn (u32, ?*anyopaque) bool = null,
    /// Opaque pointer handed to `process_alive`.
    process_alive_ctx: ?*anyopaque = null,

    /// Creates an empty, deterministic instance.
    pub fn init(allocator: Allocator, io: Io, options: Options) PluginError!PluginState {
        var self: PluginState = .{
            .allocator = allocator,
            .io = io,
            .store_path = options.store_path,
            .argv = options.argv,
            .opener = options.opener,
            .lock_path = options.lock_path,
            .autosave = options.autosave,
            .restore_diagnostics = options.restore_diagnostics,
            .current_pid = options.current_pid,
            .process_alive = options.process_alive,
            .process_alive_ctx = options.process_alive_ctx,
        };
        errdefer self.deinit();
        if (options.store_path) |_| {
            self.restore() catch {};
        }
        return self;
    }

    /// Frees every owned buffer and poisons the value.
    pub fn deinit(self: *PluginState) void {
        var it = self.store.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.store.deinit(self.allocator);
        for (self.logs.items) |line| {
            self.allocator.free(line.level);
            self.allocator.free(line.message);
        }
        self.logs.deinit(self.allocator);
        for (self.notifications.items) |n| {
            self.allocator.free(n.title);
            self.allocator.free(n.body);
        }
        self.notifications.deinit(self.allocator);
        self.* = undefined;
    }

    fn setRaw(self: *PluginState, key: []const u8, raw: []const u8) PluginError!void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, raw);
        errdefer self.allocator.free(value_copy);
        const old = try self.store.fetchPut(self.allocator, key_copy, value_copy);
        if (old) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        try self.autoSave();
    }

    /// Writes the store back after a mutation when `autosave` is on. No-op during `restore()`
    /// and when there is no `store_path`.
    fn autoSave(self: *PluginState) PluginError!void {
        if (!self.autosave or self.restoring or self.store_path == null) return;
        try self.save();
    }

    fn appendLog(self: *PluginState, level: []const u8, message: []const u8) PluginError!void {
        if (self.logs.items.len >= max_log_lines) {
            const dropped = self.logs.orderedRemove(0);
            self.allocator.free(dropped.level);
            self.allocator.free(dropped.message);
        }
        try self.logs.append(self.allocator, .{
            .level = try self.allocator.dupe(u8, level),
            .message = try self.allocator.dupe(u8, message),
        });
    }

    /// Writes the store as a JSON object whose values are raw (never re-encoded) JSON.
    pub fn save(self: *PluginState) PluginError!void {
        const path = self.store_path orelse return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{") catch return error.OutOfMemory;
        var it = self.store.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) w.writeAll(",") catch return error.OutOfMemory;
            first = false;
            const k = std.json.Stringify.valueAlloc(self.allocator, entry.key_ptr.*, .{}) catch return error.OutOfMemory;
            defer self.allocator.free(k);
            w.writeAll(k) catch return error.OutOfMemory;
            w.writeAll(":") catch return error.OutOfMemory;
            w.writeAll(entry.value_ptr.*) catch return error.OutOfMemory;
        }
        w.writeAll("}\n") catch return error.OutOfMemory;
        const bytes = try aw.toOwnedSlice();
        defer self.allocator.free(bytes);
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch return error.PersistFailed;
    }

    /// Records a restore outcome for the app. A missing/corrupt file still starts empty, but it
    /// is no longer swallowed by `catch {}`: `RestoreDiagnostics` says why.
    fn recordRestore(self: *PluginState, status: RestoreDiagnostics.Status, keys: usize) void {
        if (self.restore_diagnostics) |d| {
            d.status = status;
            d.restored_keys = keys;
        }
    }

    /// Loads previously persisted state from disk, reporting why it failed when it does.
    pub fn restore(self: *PluginState) PluginError!void {
        const path = self.store_path orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(8 * 1024 * 1024)) catch |err| {
            const status: RestoreDiagnostics.Status = switch (err) {
                error.FileNotFound => .missing,
                else => .unreadable,
            };
            self.recordRestore(status, 0);
            return switch (err) {
                error.FileNotFound => error.StoreMissing,
                else => error.StoreUnreadable,
            };
        };
        defer self.allocator.free(bytes);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{}) catch {
            self.recordRestore(.malformed, 0);
            return error.StoreMalformed;
        };
        if (parsed != .object) {
            self.recordRestore(.malformed, 0);
            return error.StoreMalformed;
        }
        // Replaying the file must not immediately write it back on every key.
        self.restoring = true;
        defer self.restoring = false;
        var count: usize = 0;
        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            const raw = std.json.Stringify.valueAlloc(arena.allocator(), entry.value_ptr.*, .{}) catch continue;
            try self.setRaw(entry.key_ptr.*, raw);
            count += 1;
        }
        self.recordRestore(.ok, count);
    }

    /// The lock file records the owning pid so a crash can be detected without a timestamp.
    pub const lock_magic = "zts-lock-v2";

    /// Removes a lock file only when it belongs to a process that is demonstrably gone.
    /// Without both OS providers this is fail-closed: the lock is kept and `false` is returned.
    fn reclaimStaleLock(self: *PluginState, path: []const u8) bool {
        const pid_fn = self.current_pid orelse return false;
        const alive_fn = self.process_alive orelse return false;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(256)) catch return false;
        defer self.allocator.free(bytes);
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, " \t\r\n"), ' ');
        const magic = it.next() orelse return false;
        if (!std.mem.eql(u8, magic, lock_magic)) return false;
        const pid_text = it.next() orelse return false;
        const pid = std.fmt.parseInt(u32, pid_text, 10) catch return false;
        if (pid == 0 or pid == pid_fn()) return false;
        if (alive_fn(pid, self.process_alive_ctx)) return false;
        Io.Dir.cwd().deleteFile(self.io, path) catch return false;
        return true;
    }

    /// Tries an exclusive lock file. `true` means this process is the primary instance.
    /// A leftover file from a dead process is reclaimed once; an unknown/live owner keeps it.
    pub fn requestLock(self: *PluginState) PluginError!bool {
        if (self.lock_held) return true;
        const path = self.lock_path orelse {
            self.lock_held = true;
            return true;
        };
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            const file = Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    if (self.reclaimStaleLock(path)) continue;
                    return false;
                },
                else => return error.PersistFailed,
            };
            var buf: [64]u8 = undefined;
            const pid: u32 = if (self.current_pid) |f| f() else 0;
            const content = std.fmt.bufPrint(&buf, lock_magic ++ " {d}\n", .{pid}) catch lock_magic ++ " 0\n";
            file.writeStreamingAll(self.io, content) catch {};
            file.close(self.io);
            self.lock_held = true;
            return true;
        }
        return false;
    }

    /// Releases the lock and removes the lock file.
    pub fn releaseLock(self: *PluginState) PluginError!void {
        if (!self.lock_held) return;
        if (self.lock_path) |path| {
            Io.Dir.cwd().deleteFile(self.io, path) catch {};
        }
        self.lock_held = false;
    }
};

// ---------------------------------------------------------------------------
// plugin:store|* — JSON key/value store
// ---------------------------------------------------------------------------

/// `plugin:store|*` — JSON key/value store.
pub const StoreCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:store|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// Returns the raw JSON stored under `key`, or `null`.
    pub fn get(_: *rpc.Ctx, state: *PluginState, args: struct { key: []const u8 }) ?rpc.RawJson {
        if (state.store.get(args.key)) |raw| return .{ .raw = raw };
        return null;
    }

    /// Stores raw JSON under `key`.
    pub fn set(_: *rpc.Ctx, state: *PluginState, args: struct { key: []const u8, value: rpc.RawJson }) PluginError!void {
        try state.setRaw(args.key, args.value.raw);
    }

    /// Removes `key`; returns whether it existed.
    pub fn delete(_: *rpc.Ctx, state: *PluginState, args: struct { key: []const u8 }) PluginError!bool {
        if (state.store.fetchRemove(args.key)) |entry| {
            state.allocator.free(entry.key);
            state.allocator.free(entry.value);
            try state.autoSave();
            return true;
        }
        return false;
    }

    /// Drops every stored key and persists the empty state when `autosave` is on.
    pub fn clear(_: *rpc.Ctx, state: *PluginState) PluginError!void {
        var it = state.store.iterator();
        while (it.next()) |entry| {
            state.allocator.free(entry.key_ptr.*);
            state.allocator.free(entry.value_ptr.*);
        }
        state.store.clearRetainingCapacity();
        try state.autoSave();
    }

    /// Whether `key` is present.
    pub fn has(_: *rpc.Ctx, state: *PluginState, args: struct { key: []const u8 }) bool {
        return state.store.contains(args.key);
    }

    /// Number of stored keys (JS-safe `u32`).
    pub fn length(_: *rpc.Ctx, state: *PluginState) u32 {
        return @intCast(state.store.count());
    }

    /// Sorted snapshot of all keys.
    pub fn keys(ctx: *rpc.Ctx, state: *PluginState) PluginError![]const []const u8 {
        const out = try ctx.scratch.alloc([]const u8, state.store.count());
        var it = state.store.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| : (i += 1) out[i] = key.*;
        std.mem.sort([]const u8, out, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        return out;
    }

    /// Persists the current state as deterministic JSON.
    pub fn save(_: *rpc.Ctx, state: *PluginState) PluginError!void {
        try state.save();
    }

    /// Reloads the store from `store_path`.
    pub fn load(_: *rpc.Ctx, state: *PluginState) PluginError!void {
        try state.restore();
    }
};

// ---------------------------------------------------------------------------
// plugin:log|* — bounded in-memory log
// ---------------------------------------------------------------------------

/// `plugin:log|*` — bounded in-memory log.
pub const LogCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:log|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// Appends one line to the bounded ring buffer.
    pub fn log(_: *rpc.Ctx, state: *PluginState, args: struct {
        level: []const u8 = "info",
        message: []const u8,
    }) PluginError!void {
        try state.appendLog(args.level, args.message);
    }

    /// Returns every retained log line in insertion order.
    pub fn logs(_: *rpc.Ctx, state: *PluginState) []const LogLine {
        return state.logs.items;
    }

    /// Drops every buffered log line from memory.
    pub fn clear(_: *rpc.Ctx, state: *PluginState) void {
        for (state.logs.items) |line| {
            state.allocator.free(line.level);
            state.allocator.free(line.message);
        }
        state.logs.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// plugin:os|* — compile-time target facts (no runtime OS calls)
// ---------------------------------------------------------------------------

/// `plugin:os|*` — compile-time target facts.
pub const OsCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:os|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// Target OS name (`linux` / `macos` / `windows`).
    pub fn platform(_: *rpc.Ctx, _: *PluginState) []const u8 {
        return switch (builtin.os.tag) {
            .windows => "windows",
            .macos => "macos",
            else => "linux",
        };
    }

    /// Target CPU architecture, from `builtin.cpu.arch`.
    pub fn arch(_: *rpc.Ctx, _: *PluginState) []const u8 {
        return @tagName(builtin.cpu.arch);
    }

    /// OS family (`unix` / `windows`).
    pub fn family(_: *rpc.Ctx, _: *PluginState) []const u8 {
        return switch (builtin.os.tag) {
            .windows => "windows",
            else => "unix",
        };
    }

    /// Executable suffix on this target (`exe` or empty).
    pub fn exe_extension(_: *rpc.Ctx, _: *PluginState) []const u8 {
        return if (builtin.os.tag == .windows) "exe" else "";
    }

    /// ziggurats does not read the host kernel version: doing so would break bit-for-bit parity
    /// across OSes and CI runners. Upstream callers get a stable string instead.
    pub fn version(_: *rpc.Ctx, _: *PluginState) []const u8 {
        return "ziggurats";
    }

    /// `locale` is intentionally `null`: reading it needs an OS locale API.
    pub fn locale(_: *rpc.Ctx, _: *PluginState) ?[]const u8 {
        return null;
    }
};

// ---------------------------------------------------------------------------
// plugin:process|* — exit is recorded and delegated to Host.requestQuit
// ---------------------------------------------------------------------------

/// `plugin:process|*` — exit request and deterministic pid.
pub const ProcessCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:process|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// Records the exit code and asks the host loop to stop. Never calls `std.process.exit`:
    /// a test / Live Preview must be able to observe the request without killing the process.
    pub fn exit(ctx: *rpc.Ctx, state: *PluginState, args: struct { code: i32 = 0 }) void {
        state.requested_exit_code = args.code;
        if (ctx.getEnv(core.CallContext)) |call| call.host.requestQuit();
    }

    /// Deterministic placeholder. A real PID would differ on every run and break reproducibility.
    pub fn pid(_: *rpc.Ctx, _: *PluginState) u32 {
        return 0;
    }
};

// ---------------------------------------------------------------------------
// plugin:cli|* — argv snapshot and simple flag matching
// ---------------------------------------------------------------------------

/// `plugin:cli|*` — argv snapshot and flag matching.
pub const CliCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:cli|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// The startup argv snapshot.
    pub fn args(_: *rpc.Ctx, state: *PluginState) []const []const u8 {
        return state.argv;
    }

    /// Whether `--flag` or `--flag=value` appeared on the command line.
    pub fn matches(_: *rpc.Ctx, state: *PluginState, request: struct { flag: []const u8 }) bool {
        for (state.argv) |arg| {
            if (std.mem.eql(u8, arg, request.flag)) return true;
            if (std.mem.startsWith(u8, arg, request.flag) and arg.len > request.flag.len and arg[request.flag.len] == '=') return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// plugin:window-state|* — geometry persisted in the store under a reserved key
// ---------------------------------------------------------------------------

/// `plugin:window-state|*` — persisted window geometry.
pub const WindowStateCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:window-state|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// Statedto exposed by this module.
    pub const StateDto = struct {
        label: []const u8,
        width: f64,
        height: f64,
        x: f64,
        y: f64,
    };

    fn keyFor(allocator: Allocator, label: []const u8) PluginError![]u8 {
        return std.fmt.allocPrint(allocator, "__zts_window_state__{s}", .{label}) catch error.OutOfMemory;
    }

    /// Persists the current state as deterministic JSON.
    pub fn save(ctx: *rpc.Ctx, state: *PluginState, args: struct { value: StateDto }) PluginError!void {
        const key = try keyFor(ctx.scratch, args.value.label);
        const raw = rpc.encodeAlloc(ctx.scratch, args.value) catch return error.OutOfMemory;
        try state.setRaw(key, raw);
        try state.save();
    }

    /// Loads previously persisted state from disk; a missing file is not an error.
    pub fn restore(ctx: *rpc.Ctx, state: *PluginState, args: struct { label: []const u8 }) ?StateDto {
        const key = keyFor(ctx.scratch, args.label) catch return null;
        const raw = state.store.get(key) orelse return null;
        return rpc.decodeLeaky(StateDto, ctx.scratch, raw) catch null;
    }

    /// Removes the entry for `label`; returns whether it existed.
    pub fn clear(ctx: *rpc.Ctx, state: *PluginState, args: struct { label: []const u8 }) bool {
        const key = keyFor(ctx.scratch, args.label) catch return false;
        if (state.store.fetchRemove(key)) |entry| {
            state.allocator.free(entry.key);
            state.allocator.free(entry.value);
            return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// plugin:opener|* — capability-gated external open, behind a provider
// ---------------------------------------------------------------------------

/// `plugin:opener|*` — capability-gated external open.
pub const OpenerCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:opener|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    fn open(state: *PluginState, target: []const u8) PluginError!void {
        const fn_ptr = state.opener.open orelse return error.Unsupported;
        fn_ptr(state.opener.ctx, target);
    }

    /// Opens an `http(s)` / `mailto` URL through the installed provider.
    pub fn open_url(_: *rpc.Ctx, state: *PluginState, args: struct { url: []const u8 }) PluginError!void {
        if (!std.mem.startsWith(u8, args.url, "https://") and !std.mem.startsWith(u8, args.url, "http://") and !std.mem.startsWith(u8, args.url, "mailto:")) {
            return error.InvalidValue;
        }
        try open(state, args.url);
    }

    /// Opens a filesystem path through the installed provider.
    pub fn open_path(_: *rpc.Ctx, state: *PluginState, args: struct { path: []const u8 }) PluginError!void {
        try open(state, args.path);
    }
};

// ---------------------------------------------------------------------------
// plugin:single-instance|* — advisory lock file, identical on all 3 OSes
// ---------------------------------------------------------------------------

/// `plugin:single-instance|*` — advisory lock file.
pub const SingleInstanceCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:single-instance|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// Claims the single-instance lock; `false` means another instance holds it.
    pub fn request_lock(_: *rpc.Ctx, state: *PluginState) PluginError!bool {
        return state.requestLock();
    }

    /// Whether this process owns the single-instance lock.
    pub fn is_primary(_: *rpc.Ctx, state: *PluginState) bool {
        return state.lock_held;
    }

    /// Releases the single-instance lock.
    pub fn release(_: *rpc.Ctx, state: *PluginState) PluginError!void {
        try state.releaseLock();
    }
};

// ---------------------------------------------------------------------------
// plugin:notification|* — in-app event + ring buffer (not the OS notification center)
// ---------------------------------------------------------------------------

/// `plugin:notification|*` — in-app event and ring buffer.
pub const NotificationCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:notification|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// Records a notification and dispatches an in-app `zts:event`.
    pub fn notify(ctx: *rpc.Ctx, state: *PluginState, args: struct {
        title: []const u8,
        body: []const u8 = "",
    }) PluginError!u32 {
        if (state.notifications.items.len >= max_notifications) {
            const dropped = state.notifications.orderedRemove(0);
            state.allocator.free(dropped.title);
            state.allocator.free(dropped.body);
        }
        const id = state.next_notification_id;
        state.next_notification_id += 1;
        try state.notifications.append(state.allocator, .{
            .id = id,
            .title = try state.allocator.dupe(u8, args.title),
            .body = try state.allocator.dupe(u8, args.body),
        });
        // Deliver through the same `zts:event` CustomEvent path the bootstrap installs.
        if (ctx.getEnv(core.CallContext)) |call| {
            const t = std.json.Stringify.valueAlloc(ctx.scratch, args.title, .{}) catch return error.OutOfMemory;
            const b = std.json.Stringify.valueAlloc(ctx.scratch, args.body, .{}) catch return error.OutOfMemory;
            var aw: std.Io.Writer.Allocating = .init(ctx.scratch);
            defer aw.deinit();
            const w = &aw.writer;
            w.writeAll("window.dispatchEvent(new CustomEvent(\"zts:event\",{detail:{event:\"notification\",payload:{id:") catch return error.OutOfMemory;
            w.print("{d},title:", .{id}) catch return error.OutOfMemory;
            w.writeAll(t) catch return error.OutOfMemory;
            w.writeAll(",body:") catch return error.OutOfMemory;
            w.writeAll(b) catch return error.OutOfMemory;
            w.writeAll("}}}));") catch return error.OutOfMemory;
            const script = aw.toOwnedSlice() catch return error.OutOfMemory;
            call.host.evalJs(call.window_id, script) catch {};
        }
        return id;
    }

    /// Returns the bounded notification ring.
    pub fn pending(_: *rpc.Ctx, state: *PluginState) []const Notification {
        return state.notifications.items;
    }
};

// ---------------------------------------------------------------------------
// plugin:positioner|* — pure geometry, no OS call
// ---------------------------------------------------------------------------

/// Where `plugin:positioner` places a window relative to its monitor.
pub const Position = enum {
    /// Top-left corner of the monitor.
    top_left,
    /// Top edge, horizontally centred.
    top_center,
    /// Top-right corner of the monitor.
    top_right,
    /// Window centred on its monitor.
    center,
    /// Bottom-left corner of the monitor.
    bottom_left,
    /// Bottom edge, horizontally centred.
    bottom_center,
    /// Bottom-right corner of the monitor.
    bottom_right,
    /// Left edge, vertically centred.
    left_center,
    /// Right edge, vertically centred.
    right_center,
};

/// `plugin:positioner|*` — pure monitor-relative geometry.
pub const PositionerCommands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:positioner|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = PluginState;

    /// Computes a window origin from a monitor rectangle and a window size. Same arithmetic on
    /// every OS; the caller supplies the monitor rectangle from `MonitorRegistry`.
    pub fn move_window(_: *rpc.Ctx, _: *PluginState, args: struct {
        position: Position,
        monitor_x: i32,
        monitor_y: i32,
        monitor_width: u32,
        monitor_height: u32,
        window_width: f64,
        window_height: f64,
    }) monitor.Point {
        const mw: f64 = @floatFromInt(args.monitor_width);
        const mh: f64 = @floatFromInt(args.monitor_height);
        const half_x = (mw - args.window_width) / 2;
        const half_y = (mh - args.window_height) / 2;
        const right = mw - args.window_width;
        const bottom = mh - args.window_height;
        const dx: f64 = switch (args.position) {
            .top_left, .left_center, .bottom_left, .center, .top_center, .bottom_center => if (args.position == .center or args.position == .top_center or args.position == .bottom_center) half_x else 0,
            .top_right, .right_center, .bottom_right => right,
        };
        const dy: f64 = switch (args.position) {
            .top_left, .top_center, .top_right, .center, .left_center, .right_center => if (args.position == .center or args.position == .left_center or args.position == .right_center) half_y else 0,
            .bottom_left, .bottom_center, .bottom_right => bottom,
        };
        return .{
            .x = args.monitor_x + @as(i32, @intFromFloat(@round(dx))),
            .y = args.monitor_y + @as(i32, @intFromFloat(@round(dy))),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const P2Schema = rpc.Schema(.{
    .store = StoreCommands,
    .log = LogCommands,
    .os = OsCommands,
    .process = ProcessCommands,
    .cli = CliCommands,
    .window_state = WindowStateCommands,
    .opener = OpenerCommands,
    .single_instance = SingleInstanceCommands,
    .notification = NotificationCommands,
    .positioner = PositionerCommands,
});

fn bindAll(state: *PluginState) P2Schema.Router {
    return P2Schema.bind(.{
        .store = state,
        .log = state,
        .os = state,
        .process = state,
        .cli = state,
        .window_state = state,
        .opener = state,
        .single_instance = state,
        .notification = state,
        .positioner = state,
    });
}

test "P2: store, log, os, cli, process, window-state, opener, single-instance, notification, positioner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var host = core.RecordingHost.init(testing.allocator);
    defer host.deinit();
    const win = try host.host().createWindow(.{ .label = "main" });
    var state = try PluginState.init(testing.allocator, testing.io, .{
        .argv = &.{ "--theme=dark", "--verbose" },
    });
    defer state.deinit();
    var bound = bindAll(&state);
    var handler = bound.handler();
    var ctx = rpc.Ctx.init(testing.io, scratch);
    var call = core.CallContext{ .host = host.host(), .window_id = win };
    ctx = ctx.withEnv(&call);
    const invoke = struct {
        fn go(h: *rpc.Handler, c: *rpc.Ctx, cmd: []const u8, body: []const u8) core.OutgoingResponse {
            return h.dispatch(testing.allocator, c, cmd, body);
        }
    }.go;

    // store: set / get / has / keys / length / delete / clear
    {
        var r = invoke(&handler, &ctx, "plugin:store|set", "{\"key\":\"a\",\"value\":{\"n\":1}}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:store|get", "{\"key\":\"a\"}");
        defer r.deinit();
        try testing.expectEqualStrings("{\"n\":1}", r.body.slice());
    }
    {
        var r = invoke(&handler, &ctx, "plugin:store|keys", "{}");
        defer r.deinit();
        try testing.expectEqualStrings("[\"a\"]", r.body.slice());
    }
    {
        var r = invoke(&handler, &ctx, "plugin:store|length", "{}");
        defer r.deinit();
        try testing.expectEqualStrings("1", r.body.slice());
    }
    {
        var r = invoke(&handler, &ctx, "plugin:store|delete", "{\"key\":\"a\"}");
        defer r.deinit();
        try testing.expectEqualStrings("true", r.body.slice());
    }

    // log: bounded ring + clear
    {
        var r = invoke(&handler, &ctx, "plugin:log|log", "{\"level\":\"warn\",\"message\":\"hi\"}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:log|logs", "{}");
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.body.slice(), "\"hi\"") != null);
    }

    // os / cli / process
    {
        var r = invoke(&handler, &ctx, "plugin:os|platform", "{}");
        defer r.deinit();
        try testing.expect(r.body.slice().len >= 5);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:cli|args", "{}");
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.body.slice(), "--theme=dark") != null);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:cli|matches", "{\"flag\":\"--theme\"}");
        defer r.deinit();
        try testing.expectEqualStrings("true", r.body.slice());
    }
    {
        var r = invoke(&handler, &ctx, "plugin:process|exit", "{\"code\":3}");
        defer r.deinit();
        try testing.expectEqual(@as(i32, 3), state.requested_exit_code.?);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:process|pid", "{}");
        defer r.deinit();
        try testing.expectEqualStrings("0", r.body.slice());
    }

    // window-state round-trip through the store
    {
        var r = invoke(&handler, &ctx, "plugin:window-state|save", "{\"value\":{\"label\":\"main\",\"width\":800,\"height\":600,\"x\":10,\"y\":20}}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:window-state|restore", "{\"label\":\"main\"}");
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.body.slice(), "\"width\":800") != null);
    }

    // opener fails closed when no provider is installed; an invalid URL is rejected
    {
        var r = invoke(&handler, &ctx, "plugin:opener|open_url", "{\"url\":\"https://example.com\"}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:opener|open_url", "{\"url\":\"javascript:alert(1)\"}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }

    // single-instance (in-memory lock)
    {
        var r = invoke(&handler, &ctx, "plugin:single-instance|request_lock", "{}");
        defer r.deinit();
        try testing.expectEqualStrings("true", r.body.slice());
    }
    {
        var r = invoke(&handler, &ctx, "plugin:single-instance|is_primary", "{}");
        defer r.deinit();
        try testing.expectEqualStrings("true", r.body.slice());
    }

    // notification emits a zts:event CustomEvent and keeps a bounded ring
    {
        var r = invoke(&handler, &ctx, "plugin:notification|notify", "{\"title\":\"Hi\",\"body\":\"there\"}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        try testing.expect(std.mem.indexOf(u8, host.eval_log.items[host.eval_log.items.len - 1], "notification") != null);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:notification|pending", "{}");
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.body.slice(), "\"Hi\"") != null);
    }

    // positioner: pure geometry
    {
        var r = invoke(&handler, &ctx, "plugin:positioner|move_window", "{\"position\":\"center\",\"monitorX\":0,\"monitorY\":0,\"monitorWidth\":1920,\"monitorHeight\":1080,\"windowWidth\":800,\"windowHeight\":600}");
        defer r.deinit();
        try testing.expectEqualStrings("{\"x\":560,\"y\":240}", r.body.slice());
    }
    {
        var r = invoke(&handler, &ctx, "plugin:positioner|move_window", "{\"position\":\"bottom_right\",\"monitorX\":100,\"monitorY\":50,\"monitorWidth\":1920,\"monitorHeight\":1080,\"windowWidth\":800,\"windowHeight\":600}");
        defer r.deinit();
        try testing.expectEqualStrings("{\"x\":1220,\"y\":530}", r.body.slice());
    }
}

test "P2: store persistence and single-instance lock file are deterministic across restarts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..len];
    const store_path = try std.fmt.allocPrint(testing.allocator, "{s}/store.json", .{root});
    defer testing.allocator.free(store_path);
    const lock_path = try std.fmt.allocPrint(testing.allocator, "{s}/app.lock", .{root});
    defer testing.allocator.free(lock_path);

    {
        var state = try PluginState.init(testing.allocator, testing.io, .{
            .store_path = store_path,
            .lock_path = lock_path,
            .opener = .{ .open = struct {
                fn go(_: ?*anyopaque, target: []const u8) void {
                    _ = target;
                }
            }.go },
        });
        defer state.deinit();
        try state.setRaw("theme", "\"dark\"");
        try state.save();
        try testing.expect(try state.requestLock());
        try state.releaseLock();
    }
    {
        var state = try PluginState.init(testing.allocator, testing.io, .{
            .store_path = store_path,
            .lock_path = lock_path,
        });
        defer state.deinit();
        try testing.expectEqualStrings("\"dark\"", state.store.get("theme").?);
        try testing.expect(try state.requestLock());
        var second = try PluginState.init(testing.allocator, testing.io, .{ .lock_path = lock_path });
        defer second.deinit();
        try testing.expect(!try second.requestLock()); // exclusive file blocks the second instance
        try state.releaseLock();
        try testing.expect(try second.requestLock());
        try second.releaseLock();
    }
}

test "M6-04: autosave persists mutations and restore diagnostics report a corrupt file" {
    const store_path = "zts-m6-04-store.json";
    defer std.Io.Dir.cwd().deleteFile(testing.io, store_path) catch {};

    var diagnostics = RestoreDiagnostics{};
    {
        // A valid saved file restores cleanly; a first launch with no file reports `.missing`.
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = store_path, .data = "{}\n" });
        var state = try PluginState.init(testing.allocator, testing.io, .{
            .store_path = store_path,
            .autosave = true,
            .restore_diagnostics = &diagnostics,
        });
        defer state.deinit();
        try state.setRaw("answer", "42");
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, store_path, testing.allocator, .limited(4096));
        defer testing.allocator.free(bytes);
        try testing.expect(std.mem.indexOf(u8, bytes, "\"answer\":42") != null);
        try testing.expectEqual(RestoreDiagnostics.Status.ok, diagnostics.status);
    }
    {
        // A corrupt file must not be swallowed silently: the app sees `.malformed`.
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = store_path, .data = "not-json" });
        var broken = RestoreDiagnostics{};
        var state = try PluginState.init(testing.allocator, testing.io, .{
            .store_path = store_path,
            .restore_diagnostics = &broken,
        });
        defer state.deinit();
        try testing.expectEqual(RestoreDiagnostics.Status.malformed, broken.status);
        try testing.expectEqual(@as(usize, 0), broken.restored_keys);
    }
    {
        // `autosave = false` restores the explicit-save-only contract.
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = store_path, .data = "{}\n" });
        var state = try PluginState.init(testing.allocator, testing.io, .{
            .store_path = store_path,
            .autosave = false,
        });
        defer state.deinit();
        try state.setRaw("later", "1");
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, store_path, testing.allocator, .limited(4096));
        defer testing.allocator.free(bytes);
        try testing.expectEqualStrings("{}\n", bytes);
        try state.save();
        const saved = try std.Io.Dir.cwd().readFileAlloc(testing.io, store_path, testing.allocator, .limited(4096));
        defer testing.allocator.free(saved);
        try testing.expect(std.mem.indexOf(u8, saved, "\"later\":1") != null);
    }
}

test "M6-04: a lock file owned by a dead process is reclaimed once" {
    const lock_path = "zts-m6-04.lock";
    defer std.Io.Dir.cwd().deleteFile(testing.io, lock_path) catch {};
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = lock_path,
        .data = "zts-lock-v2 999999\n",
    });

    const Helpers = struct {
        fn pid() u32 {
            return 111;
        }
        fn dead(process_id: u32, _: ?*anyopaque) bool {
            return process_id == 111;
        }
        fn allAlive(_: u32, _: ?*anyopaque) bool {
            return true;
        }
    };

    var state = try PluginState.init(testing.allocator, testing.io, .{
        .lock_path = lock_path,
        .current_pid = Helpers.pid,
        .process_alive = Helpers.dead,
    });
    defer state.deinit();
    try testing.expect(try state.requestLock());
    try testing.expect(state.lock_held);
    try state.releaseLock();

    // A live owner keeps the lock, and no provider means fail-closed.
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = lock_path,
        .data = "zts-lock-v2 999999\n",
    });
    var guarded = try PluginState.init(testing.allocator, testing.io, .{
        .lock_path = lock_path,
        .current_pid = Helpers.pid,
        .process_alive = Helpers.allAlive,
    });
    defer guarded.deinit();
    try testing.expect(!(try guarded.requestLock()));
}
