//! Transport- & Domain-Independent Execution Context (`Ctx`) & RPC `Handler` (`src/rpc/ctx.zig`).
//!
//! `zts_rpc` depends **exclusively** on `zts_foundation` (zero windowing VTables, zero WebView
//! headers, zero HTTP server coupling), making the entire `src/rpc/` package directly reusable in
//! standalone engines, media/streaming tools, HTTP/WebSocket servers, CLI daemons, and Z-Ts apps:
//! - Callers inject any domain-specific runtime context (e.g. a desktop `CallContext`, a media
//!   pipeline handle, or a session object) with zero heap allocations via `ctx.withEnv(&my_env)`,
//!   and commands retrieve it with compile-time type-checked safety via `ctx.env(T)` / `ctx.requireEnv(T)`.
//! - Error responses (`ErrorSet`) resolve to compile-time static string literals (`{"code":"..."}`)
//!   wrapped in `OwnedBytes.static(...)`, guaranteeing **0 bytes of heap allocation on error paths**.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("zts_foundation");

fn typeIdOf(comptime T: type) usize {
    return @intFromPtr(@typeName(T).ptr);
}

/// Per-invocation execution context passed to RPC command functions requesting `*Ctx`.
pub const Ctx = struct {
    /// Zig 0.17 asynchronous / filesystem / synchronization I/O token.
    io: std.Io,
    /// Reusable per-request scratch allocator (e.g. resettable `ArenaAllocator`).
    /// Temporary allocations made here are automatically reclaimed after the call returns.
    scratch: Allocator,
    /// Optional caller origin / peer identifier (e.g. `"tauri://localhost"`, `"ws://127.0.0.1"`).
    origin: []const u8 = "",
    /// Raw unparsed request payload bytes.
    raw_body: []const u8 = "",
    /// Optional zero-allocation type-erased pointer to host/engine-specific per-call environment.
    env_ptr: ?*anyopaque = null,
    /// Compile-time `@typeName(T).ptr` identity tag guarding `env(T)` against wrong-type casts.
    env_type_id: usize = 0,

    /// Convenience constructor for standalone / unit-test invocations.
    pub fn init(io: std.Io, scratch: Allocator) Ctx {
        return .{
            .io = io,
            .scratch = scratch,
        };
    }

    /// Attaches a strongly typed pointer `*T` to this `Ctx` with zero allocations.
    pub fn withEnv(self: Ctx, ptr: anytype) Ctx {
        const PtrT = @TypeOf(ptr);
        const info = @typeInfo(PtrT);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("zts_rpc.Ctx.withEnv expects a single-item pointer `*T` or `*const T`.");
        }
        var copy = self;
        copy.env_ptr = @ptrCast(@constCast(ptr));
        copy.env_type_id = typeIdOf(info.pointer.child);
        return copy;
    }

    /// Returns `*T` if an environment of exact type `T` was attached via `withEnv`, else `null`.
    pub fn env(self: *const Ctx, comptime T: type) ?*T {
        const raw = self.env_ptr orelse return null;
        if (self.env_type_id != typeIdOf(T)) return null;
        return @ptrCast(@alignCast(raw));
    }

    /// Alias for `env(T)` for callers expecting `getEnv`.
    pub const getEnv = env;

    /// Returns `*T` or `error.MissingContext` (which serializes with 0 heap allocations as `{"code":"MissingContext"}`).
    pub fn requireEnv(self: *const Ctx, comptime T: type) error{MissingContext}!*T {
        return self.env(T) orelse error.MissingContext;
    }
};

/// Single-function authorization gate (`ADR-0002` §1.6).
/// Return `true` to allow `command` execution for `ctx`, or `false` to reject with `403 Forbidden`.
pub const AuthorizeFn = *const fn (ctx: *const Ctx, command: []const u8) bool;

/// Constructs a **zero-allocation** `OutgoingResponse` encoding `{"code":"<ErrorName>"}`
/// directly from read-only static `.rodata` memory via Zig's `inline else` prong.
pub fn errorResponseComptime(http_code: u16, err: anytype) core.OutgoingResponse {
    return switch (err) {
        inline else => |e| .{
            .status = .err,
            .http_code = http_code,
            .content_type = "application/json",
            .body = core.OwnedBytes.static("{\"code\":\"" ++ @errorName(e) ++ "\"}"),
        },
    };
}

/// Standard pre-built zero-allocation protocol error responses.
pub const Responses = struct {
    pub const unknown_command: core.OutgoingResponse = .{
        .status = .err,
        .http_code = 404,
        .content_type = "application/json",
        .body = core.OwnedBytes.static("{\"code\":\"UnknownCommand\"}"),
    };

    pub const forbidden: core.OutgoingResponse = .{
        .status = .err,
        .http_code = 403,
        .content_type = "application/json",
        .body = core.OwnedBytes.static("{\"code\":\"Forbidden\"}"),
    };

    pub const internal_oom: core.OutgoingResponse = .{
        .status = .err,
        .http_code = 500,
        .content_type = "application/json",
        .body = core.OwnedBytes.static("{\"code\":\"OutOfMemory\"}"),
    };

    pub const ok_null: core.OutgoingResponse = .{
        .status = .ok,
        .http_code = 200,
        .content_type = "application/json",
        .body = core.OwnedBytes.static("null"),
    };

    pub const ok_true: core.OutgoingResponse = .{
        .status = .ok,
        .http_code = 200,
        .content_type = "application/json",
        .body = core.OwnedBytes.static("true"),
    };

    pub const ok_false: core.OutgoingResponse = .{
        .status = .ok,
        .http_code = 200,
        .content_type = "application/json",
        .body = core.OwnedBytes.static("false"),
    };
};

/// Type-erased 2-word RPC dispatcher consumed by any transport (HTTP, WebSocket, stdio, WebView IPC).
pub const Handler = struct {
    userdata: ?*anyopaque = null,
    dispatchFn: *const fn (
        userdata: ?*anyopaque,
        resp_allocator: Allocator,
        ctx: *Ctx,
        command: []const u8,
        payload: []const u8,
    ) core.OutgoingResponse,

    /// Dispatches `command` using caller-supplied `ctx` (`ctx.scratch` may be a resettable arena,
    /// while any dynamically serialized response bytes are owned by `resp_allocator`).
    pub inline fn dispatch(
        self: Handler,
        resp_allocator: Allocator,
        ctx: *Ctx,
        command: []const u8,
        payload: []const u8,
    ) core.OutgoingResponse {
        ctx.raw_body = payload;
        return self.dispatchFn(self.userdata, resp_allocator, ctx, command, payload);
    }

    /// Ergonomic helper creating a temporary per-call scratch `ArenaAllocator` automatically,
    /// freeing all temporary argument allocations before returning the owned `OutgoingResponse`.
    pub fn invoke(
        self: Handler,
        allocator: Allocator,
        io: std.Io,
        command: []const u8,
        payload: []const u8,
    ) core.OutgoingResponse {
        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();

        var ctx = Ctx.init(io, scratch_arena.allocator());
        return self.dispatch(allocator, &ctx, command, payload);
    }
};
