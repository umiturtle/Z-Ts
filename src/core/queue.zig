//! Thread-Safe Bounded/Growable MPSC Ring Queue (`RingQueue(T)`).
//!
//! Built directly on Zig 0.17's native `std.Io.Mutex` and `std.Io.Condition`:
//! - **Non-blocking GUI integration**: Worker threads push tasks/responses via `push()` while
//!   the main GUI loop drains batches in one lock acquisition via `drain()` / `tryPop()`.
//! - **Blocking worker integration**: Background pools can sleep at 0% CPU via `waitPop()`
//!   and wake cleanly on shutdown via `close()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const QueueError = error{
    Closed,
} || Allocator.Error;

/// A bounded, thread-safe multi-producer/multi-consumer queue that grows on demand. `pop` blocks
/// until an item arrives or the queue is closed (`error.Closed`), which is how the SSE and event
/// pumps idle without spinning.
pub fn RingQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        mu: Io.Mutex = .init,
        not_empty: Io.Condition = .init,
        buf: []T = &.{},
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.buf.len > 0) allocator.free(self.buf);
            self.* = .empty;
        }

        /// Runs `dtor(&item)` on every remaining queued item before freeing the ring buffer.
        pub fn deinitWith(self: *Self, allocator: Allocator, dtor: anytype) void {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                const idx = (self.head + i) & (self.buf.len - 1);
                dtor(&self.buf[idx]);
            }
            self.deinit(allocator);
        }

        /// Marks the queue closed and wakes all threads blocked in `waitPop`.
        /// Already-enqueued items remain readable until drained.
        pub fn close(self: *Self, io: Io) void {
            self.mu.lockUncancelable(io);
            self.closed = true;
            self.mu.unlock(io);
            self.not_empty.broadcast(io);
        }

        pub fn count(self: *Self, io: Io) usize {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            return self.len;
        }

        /// Appends `item` to the tail of the queue. Returns `true` if the queue transitioned
        /// from empty to non-empty (useful for coalescing OS event-loop `wakeup()` syscalls!).
        pub fn push(self: *Self, allocator: Allocator, io: Io, item: T) QueueError!bool {
            self.mu.lockUncancelable(io);
            if (self.closed) {
                self.mu.unlock(io);
                return error.Closed;
            }
            if (self.len == self.buf.len) {
                self.growLocked(allocator) catch |err| {
                    self.mu.unlock(io);
                    return err;
                };
            }
            const was_empty = (self.len == 0);
            const tail = (self.head + self.len) & (self.buf.len - 1);
            self.buf[tail] = item;
            self.len += 1;
            self.mu.unlock(io);

            self.not_empty.signal(io);
            return was_empty;
        }

        /// Pops a single item immediately, returning `null` if currently empty.
        pub fn tryPop(self: *Self, io: Io) ?T {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            return self.popUnlocked();
        }

        /// Drains up to `out.len` items under a single lock acquisition and returns the number copied.
        pub fn drain(self: *Self, io: Io, out: []T) usize {
            if (out.len == 0) return 0;
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);

            const n = @min(self.len, out.len);
            for (0..n) |i| {
                out[i] = self.popUnlocked().?;
            }
            return n;
        }

        /// Blocks until an item is available, or returns `null` once `close()` is called and drained.
        pub fn waitPop(self: *Self, io: Io) Io.Cancelable!?T {
            try self.mu.lock(io);
            defer self.mu.unlock(io);

            while (self.len == 0) {
                if (self.closed) return null;
                try self.not_empty.wait(io, &self.mu);
            }
            return self.popUnlocked();
        }

        inline fn popUnlocked(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) & (self.buf.len - 1);
            self.len -= 1;
            return item;
        }

        fn growLocked(self: *Self, allocator: Allocator) Allocator.Error!void {
            const new_cap = if (self.buf.len == 0) 16 else self.buf.len * 2;
            const new_buf = try allocator.alloc(T, new_cap);
            for (0..self.len) |i| {
                new_buf[i] = self.buf[(self.head + i) & (self.buf.len - 1)];
            }
            if (self.buf.len > 0) allocator.free(self.buf);
            self.buf = new_buf;
            self.head = 0;
        }
    };
}

// ============================================================================
// Single-Threaded & Multi-Producer Concurrency Stress Tests
// ============================================================================

test "RingQueue: wrap-around ordering, wakeup coalescing flag, batch drain, and close" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var q: RingQueue(u32) = .empty;
    defer q.deinit(alloc);

    // First push onto empty queue must return `was_empty == true`, second `false`
    try std.testing.expect(try q.push(alloc, io, 100));
    try std.testing.expect(!(try q.push(alloc, io, 200)));
    try std.testing.expectEqual(@as(?u32, 100), q.tryPop(io));
    try std.testing.expectEqual(@as(?u32, 200), q.tryPop(io));
    try std.testing.expectEqual(@as(?u32, null), q.tryPop(io));

    // Exercise wrap-around + multiple doublings while preserving exact FIFO order
    var next_in: u32 = 0;
    var next_out: u32 = 0;
    for (0..40) |_| {
        for (0..5) |_| {
            _ = try q.push(alloc, io, next_in);
            next_in += 1;
        }
        var batch: [3]u32 = undefined;
        const got = q.drain(io, &batch);
        try std.testing.expectEqual(@as(usize, 3), got);
        for (batch[0..got]) |v| {
            try std.testing.expectEqual(next_out, v);
            next_out += 1;
        }
    }
    while (q.tryPop(io)) |v| {
        try std.testing.expectEqual(next_out, v);
        next_out += 1;
    }
    try std.testing.expectEqual(next_in, next_out);

    q.close(io);
    try std.testing.expectError(error.Closed, q.push(alloc, io, 999));
    try std.testing.expectEqual(@as(?u32, null), try q.waitPop(io));
}

test "RingQueue: multi-producer concurrent stress test via std.Io.Group" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const NUM_PRODUCERS = 4;
    const ITEMS_PER_PRODUCER = 500;

    const Shared = struct {
        q: RingQueue(u64) = .empty,
        sum: std.atomic.Value(u64) = .init(0),
        popped_count: std.atomic.Value(usize) = .init(0),

        fn producer(s: *@This(), gpa: Allocator, task_io: Io, base: u64) void {
            for (1..ITEMS_PER_PRODUCER + 1) |i| {
                _ = s.q.push(gpa, task_io, base + i) catch unreachable;
            }
        }

        fn consumer(s: *@This(), task_io: Io) void {
            while (s.q.waitPop(task_io) catch null) |val| {
                _ = s.sum.fetchAdd(val, .monotonic);
                _ = s.popped_count.fetchAdd(1, .monotonic);
            }
        }
    };

    var shared: Shared = .{};
    defer shared.q.deinit(alloc);

    var producers: Io.Group = .init;
    var consumers: Io.Group = .init;

    for (0..2) |_| {
        try consumers.concurrent(io, Shared.consumer, .{ &shared, io });
    }
    for (0..NUM_PRODUCERS) |p| {
        try producers.concurrent(io, Shared.producer, .{ &shared, alloc, io, p * 1000 });
    }

    try producers.await(io);
    shared.q.close(io);
    try consumers.await(io);

    try std.testing.expectEqual(@as(usize, NUM_PRODUCERS * ITEMS_PER_PRODUCER), shared.popped_count.load(.acquire));

    var expected_sum: u64 = 0;
    for (0..NUM_PRODUCERS) |p| {
        for (1..ITEMS_PER_PRODUCER + 1) |i| expected_sum += p * 1000 + i;
    }
    try std.testing.expectEqual(expected_sum, shared.sum.load(.acquire));
}
