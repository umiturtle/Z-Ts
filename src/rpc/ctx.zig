//! Execution Context (`Ctx`), Authorization Hook & Type-Erased RPC `Handler` (`src/rpc/ctx.zig`).
//!
//! Designed so `zts_rpc` has **zero dependency on OS GUI / WebView / HTTP transport crates**:
//! - Standalone HTTP/WebSocket servers, CLI daemons, unit tests, `zts_bridge`, and `zts_webview`
//!   all invoke commands through the exact same 2-word `Handler` fat pointer (`userdata + dispatchFn`).
//! - Error responses (`ErrorSet`) resolve to compile-time static string literals (`{"code":"..."}`)
//!   wrapped in `OwnedBytes.static(...)`, guaranteeing **0 bytes of heap allocation on error paths**.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");

const noopHostVTable = core.Host.VTable{};

/// Inert default `Host` instance used when running RPC handlers outside a GUI host (e.g. CLI/HTTP/tests).
pub const inert_host: core.Host = .{
    .userdata = null,
    .vtable = &noopHostVTable,
};

/// Per-invocation execution context passed to RPC command functions requesting `*Ctx`.
pub const Ctx = struct {
    /// Zig 0.17 asynchronous / filesystem / synchronization I/O token.
    io: std.Io,
    /// Reusable per-request scratch allocator (e.g. resettable `ArenaAllocator`).
    /// Temporary allocations made here are automatically reclaimed after the call returns.
    scratch: Allocator,
    /// Platform-independent window/webview host VTable (`inert_host` when headless/standalone).
    host: core.Host = inert_host,
    /// Calling window handle (`core.WindowId.invalid` when invoked outside a window context).
    window_id: core.WindowId = .invalid,
    /// Verified caller Web Origin (e.g. `"tauri://localhost"`), inspectable by `AuthorizeFn` or commands.
    origin: []const u8 = "",
    /// Raw unparsed request payload bytes.
    raw_body: []const u8 = "",

    /// Convenience constructor for standalone / unit-test invocations.
    pub fn init(io: std.Io, scratch: Allocator) Ctx {
        return .{
            .io = io,
            .scratch = scratch,
        };
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

/// Type-erased 2-word RPC dispatcher consumed by `zts_bridge`, `zts_webview` hosts, and tests.
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
