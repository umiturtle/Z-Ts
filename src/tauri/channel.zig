//! Ordered Streaming `Channel(T)` for Tauri v2 IPC (`src/tauri/channel.zig`).
//!
//! Wire format matches `@tauri-apps/api/core` `Channel<T>` (`vendor/tauri/packages/api/src/core.ts`):
//! - Frontend passes `"__CHANNEL__:<callback_id>"` in JSON RPC arguments.
//! - Backend decodes `Channel(T)` with **zero heap allocations** (`decodeZtsJson`).
//! - Each `send()` assigns a monotonically increasing 0-based `index` (`atomic.Value(u32)`) and evaluates:
//!   `window.__TAURI_INTERNALS__.runCallback(<id>,{"index":<index>,"message":<payload>});`
//!   so out-of-order deliveries are re-ordered deterministically on the JS side.
//! - `close()` emits `window.__TAURI_INTERNALS__.runCallback(<id>,{"end":true,"index":<count>});`
//!   so `@tauri-apps/api` unregisters the callback from `window.__TAURI_INTERNALS__.callbacks` with zero leaks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");

/// Wire marker of a `Channel<T>` handle: the JS side passes `"__CHANNEL__:<id>"` in the command
/// arguments, and the engine turns it back into a native send/receive pair.
pub const channel_prefix = "__CHANNEL__:";

/// `Channel<T>` failures: the host could not deliver, the payload failed to encode, or the channel
/// was closed by the receiver.
pub const ChannelError = core.HostError || rpc.EncodeError || error{
    MissingHostContext,
    ChannelClosed,
};

/// Parses a JSON-encoded string literal `"__CHANNEL__:<u32>"` or bare slice `__CHANNEL__:<u32>`.
pub fn parseChannelWire(raw_slice: []const u8) rpc.DecodeError!u32 {
    var inner = std.mem.trim(u8, raw_slice, " \t\r\n");
    if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"') {
        inner = inner[1 .. inner.len - 1];
    } else {
        return error.UnexpectedToken;
    }

    if (!std.mem.startsWith(u8, inner, channel_prefix)) {
        return error.UnexpectedToken;
    }
    const digits = inner[channel_prefix.len..];
    if (digits.len == 0) return error.InvalidNumber;
    for (digits) |ch| {
        if (!std.ascii.isDigit(ch)) return error.InvalidNumber;
    }
    return std.fmt.parseInt(u32, digits, 10) catch |err| switch (err) {
        error.Overflow => error.Overflow,
        error.InvalidCharacter => error.InvalidNumber,
    };
}

/// Typed server-to-client streaming channel compatible with Both `@tauri-apps/api/core` `Channel<T>`
/// and `zts_rpc.tsgen` generated TypeScript bindings.
pub fn Channel(comptime T: type) type {
    comptime rpc.assertValidRpcType(T);

    return struct {
        callback_id: u32,
        next_index: u32 = 0,
        closed: bool = false,

        pub const MessageType = T;

        /// Structural TypeScript type accepting `new Channel<T>()` from `@tauri-apps/api/core` with strict payload checking!
        pub const zts_ts_type: []const u8 =
            "{ readonly id: number; readonly onmessage: (response: " ++ rpc.tsgen.renderTsTypeComptime(T, false) ++ ") => void; toJSON(): string }";

        pub fn init(callback_id: u32) @This() {
            return .{ .callback_id = callback_id };
        }

        /// Zero-allocation custom wire hook invoked directly by `zts_rpc.codec`.
        pub fn decodeZtsJson(_: Allocator, raw_slice: []const u8) rpc.DecodeError!@This() {
            const id = try parseChannelWire(raw_slice);
            return .{ .callback_id = id };
        }

        pub fn writeJson(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("\"{s}{d}\"", .{ channel_prefix, self.callback_id });
        }

        /// Sends one typed message along this channel via an explicit `(host, window_id, scratch)`.
        pub fn send(
            self: *@This(),
            host: core.Host,
            window_id: core.WindowId,
            scratch: Allocator,
            value: T,
        ) ChannelError!void {
            if (self.closed) return error.ChannelClosed;
            const idx = self.next_index;
            self.next_index += 1;

            var aw: std.Io.Writer.Allocating = .init(scratch);
            defer aw.deinit();

            aw.writer.print(
                "window.__TAURI_INTERNALS__.runCallback({d},{{\"index\":{d},\"message\":",
                .{ self.callback_id, idx },
            ) catch return error.OutOfMemory;

            try rpc.encodeWithOptions(&aw.writer, value, .{ .html_safe = true });

            aw.writer.writeAll("});") catch return error.OutOfMemory;
            try host.evalJs(window_id, aw.written());
        }

        /// Convenience helper for RPC command handlers receiving `ctx: *rpc.Ctx` with `core.CallContext` attached.
        pub fn sendCtx(self: *@This(), ctx: *rpc.Ctx, value: T) ChannelError!void {
            const call_ctx = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;
            return self.send(call_ctx.host, call_ctx.window_id, ctx.scratch, value);
        }

        /// Emits the end-of-stream marker `{"end":true,"index":<count>}` so `@tauri-apps/api` cleans up `callbacks`.
        pub fn close(
            self: *@This(),
            host: core.Host,
            window_id: core.WindowId,
            _: Allocator,
        ) ChannelError!void {
            if (self.closed) return;
            self.closed = true;
            var end_buf: [128]u8 = undefined;
            const end_js = std.fmt.bufPrint(
                &end_buf,
                "window.__TAURI_INTERNALS__.runCallback({d},{{\"end\":true,\"index\":{d}}});",
                .{ self.callback_id, self.next_index },
            ) catch unreachable;
            try host.evalJs(window_id, end_js);
        }

        pub fn closeCtx(self: *@This(), ctx: *rpc.Ctx) ChannelError!void {
            const call_ctx = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;
            return self.close(call_ctx.host, call_ctx.window_id, ctx.scratch);
        }
    };
}

test "Channel(T) decodes __CHANNEL__:<id> with 0 heap allocations and streams indexed frames + end marker" {
    const Progress = struct {
        step: u32,
        note: []const u8,
    };

    const parsed = try rpc.decode(struct {
        url: []const u8,
        on_event: Channel(Progress),
    }, testing.failing_allocator, "{\"url\":\"https://example.com\",\"onEvent\":\"__CHANNEL__:9042\"}");
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 9042), parsed.value.on_event.callback_id);

    // Invalid wire formats are deterministically rejected
    try testing.expectError(error.UnexpectedToken, parseChannelWire("\"not_a_channel:1\""));
    try testing.expectError(error.InvalidNumber, parseChannelWire("\"__CHANNEL__:abc\""));
    try testing.expectError(error.Overflow, parseChannelWire("\"__CHANNEL__:99999999999\""));

    var rec = core.RecordingHost.init(testing.allocator);
    defer rec.deinit();
    const win = try rec.host().createWindow(.{ .title = "ChanTest" });

    var ch = parsed.value.on_event;
    try ch.send(rec.host(), win, testing.allocator, .{ .step = 1, .note = "init" });
    try ch.send(rec.host(), win, testing.allocator, .{ .step = 2, .note = "</script>" });
    try ch.close(rec.host(), win, testing.allocator);

    try testing.expectEqualStrings(
        "window.__TAURI_INTERNALS__.runCallback(9042,{\"index\":0,\"message\":{\"step\":1,\"note\":\"init\"}});",
        rec.eval_log.items[0],
    );
    try testing.expectEqualStrings(
        "window.__TAURI_INTERNALS__.runCallback(9042,{\"index\":1,\"message\":{\"step\":2,\"note\":\"\\u003c/script\\u003e\"}});",
        rec.eval_log.items[1],
    );
    try testing.expectEqualStrings(
        "window.__TAURI_INTERNALS__.runCallback(9042,{\"end\":true,\"index\":2});",
        rec.eval_log.items[2],
    );
}
