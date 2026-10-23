//! Main-Thread Pending Request Isolation Table & Thread-Safe Completion Queue (`src/webview/pending.zig`).
//!
//! Enforces Architectural Invariant #4 from `ADR-0002`:
//! - Raw OS request objects (`WebKitURISchemeRequest*`, `WKURLSchemeTask`, `ICoreWebView2WebResourceRequestedEventArgs*`)
//!   NEVER cross thread boundaries and NEVER escape the UI main thread.
//! - Worker threads receive ONLY a 53-bit generational `RequestId` (`Handle(.ipc_request)`) + payload bytes,
//!   and submit finished responses via `CompletionQueue.submit(...)` + `wakeup()`.
//! - On the main thread, `PendingTable(NativeReq)` validates generation counters so late responses for
//!   reloaded/closed windows are safely discarded with zero ABA bugs and zero memory leaks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const foundation = @import("zts_foundation");
const types = @import("types.zig");

/// Main-thread-only generational table isolating raw OS request objects per window.
pub fn PendingTable(comptime NativePayload: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            window_id: types.WindowId,
            payload: NativePayload,
        };

        pool: foundation.HandlePool(Entry, .ipc_request) = .empty,

        pub fn deinitWith(
            self: *Self,
            allocator: Allocator,
            cancel_fn: *const fn (payload: NativePayload) void,
        ) void {
            var it = self.pool.iterator();
            while (it.next()) |slot| {
                cancel_fn(slot.value_ptr.payload);
            }
            self.pool.deinit(allocator);
        }

        pub fn insert(
            self: *Self,
            allocator: Allocator,
            window_id: types.WindowId,
            payload: NativePayload,
        ) Allocator.Error!types.RequestId {
            return self.pool.acquire(allocator, .{
                .window_id = window_id,
                .payload = payload,
            }) catch return error.OutOfMemory;
        }

        /// Removes and returns `NativePayload` iff `id` matches the live slot AND generation;
        /// returns `null` when the request was already completed or canceled on reload/close.
        pub fn take(self: *Self, id: types.RequestId) ?Entry {
            return self.pool.release(id) catch null;
        }

        /// Cancels and removes every in-flight request belonging to `window_id` when a window closes.
        pub fn cancelForWindow(
            self: *Self,
            allocator: Allocator,
            window_id: types.WindowId,
            cancel_fn: *const fn (payload: NativePayload) void,
        ) usize {
            var ids: std.ArrayList(types.RequestId) = .empty;
            defer ids.deinit(allocator);

            var it = self.pool.iterator();
            while (it.next()) |slot| {
                if (slot.value_ptr.window_id == window_id) {
                    ids.append(allocator, slot.handle) catch break;
                }
            }

            for (ids.items) |h| {
                if (self.take(h)) |entry| {
                    cancel_fn(entry.payload);
                }
            }
            return ids.items.len;
        }

        pub inline fn count(self: *const Self) u32 {
            return self.pool.count();
        }
    };
}

/// Multi-producer, main-thread single-consumer completion channel for `completeRequest`.
pub const CompletionQueue = struct {
    allocator: Allocator,
    io: Io,
    queue: foundation.RingQueue(types.QueuedCompletion) = .empty,

    pub fn init(allocator: Allocator, io: Io) CompletionQueue {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *CompletionQueue) void {
        while (self.queue.tryPop(self.io)) |item_val| {
            var item = item_val;
            item.deinit(self.allocator);
        }
        self.queue.deinit(self.allocator);
    }

    pub fn push(
        self: *CompletionQueue,
        request_id: types.RequestId,
        resp: types.SchemeResponse,
    ) Allocator.Error!void {
        var cloned = try types.QueuedCompletion.cloneFrom(self.allocator, request_id, resp);
        errdefer cloned.deinit(self.allocator);
        _ = self.queue.push(self.allocator, self.io, cloned) catch return error.OutOfMemory;
    }

    pub fn tryPop(self: *CompletionQueue) ?types.QueuedCompletion {
        return self.queue.tryPop(self.io);
    }
};

test "PendingTable & CompletionQueue isolate native handles and safely discard stale/canceled completions with zero leaks" {
    const DummyNative = struct {
        tag: usize,
        canceled: *usize,
        fn cancel(self: @This()) void {
            self.canceled.* += 1;
        }
    };

    var canceled_count: usize = 0;
    var table: PendingTable(DummyNative) = .{};
    defer table.deinitWith(testing.allocator, DummyNative.cancel);

    var completions = CompletionQueue.init(testing.allocator, testing.io);
    defer completions.deinit();

    const win_a = try types.WindowId.fromU53((1 << 24) | 0);
    const req1 = try table.insert(testing.allocator, win_a, .{ .tag = 111, .canceled = &canceled_count });
    const req2 = try table.insert(testing.allocator, win_a, .{ .tag = 222, .canceled = &canceled_count });

    // Window closes while `req1` is still in flight on a background thread!
    try testing.expectEqual(@as(usize, 2), table.cancelForWindow(testing.allocator, win_a, DummyNative.cancel));
    try testing.expectEqual(@as(usize, 2), canceled_count);

    // A new window opens and reuses slot 0 with bumped generation (`req3 != req1`)
    const win_b = try types.WindowId.fromU53((2 << 24) | 0);
    const req3 = try table.insert(testing.allocator, win_b, .{ .tag = 333, .canceled = &canceled_count });
    try testing.expect(req3 != req1);

    // Late worker finishes `req1` with dynamically owned heap buffer -> MUST NOT clobber `req3`, and MUST free `body` cleanly!
    const heap_payload = try testing.allocator.dupe(u8, "late worker response");
    try completions.push(req1, .{
        .status_code = 200,
        .content_type = "text/plain",
        .body = types.OwnedBytes.fromOwnedSlice(testing.allocator, heap_payload),
    });

    while (completions.tryPop()) |item_val| {
        var item = item_val;
        defer item.deinit(testing.allocator);
        // `table.take(req1)` returns `null` because generation mismatched `req3`!
        try testing.expect(table.take(item.request_id) == null);
    }

    // Meanwhile `req3` remains intact and untouched!
    try testing.expectEqual(@as(usize, 333), table.take(req3).?.payload.tag);
    _ = req2;
}
