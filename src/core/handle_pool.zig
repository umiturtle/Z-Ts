//! 53-bit Generational Handle & Slot Pool (`Handle(Tag)` / `HandlePool(T, Tag)`).
//!
//! Designed specifically for crossing the Zig <-> JavaScript / JSON / C ABI boundary:
//! - Every `Handle(Tag)` packs a 24-bit slot index (up to 16,777,215 live items) and a
//!   29-bit non-zero generation counter into a single **53-bit unsigned integer (`u53`)**.
//! - Every possible handle value is strictly `<= 2^53 - 1` (`MAX_JS_SAFE_INT`), so converting
//!   to/from IEEE 754 `f64` (JavaScript `number` / `JSON.parse`) is **100% lossless**.
//! - Generation `0` is permanently reserved for `.invalid`, so zero-initialized memory never
//!   collides with any live handle across arbitrary wrap-arounds.
//! - Releasing a slot increments its generation, catching stale handle reuse (ABA bugs) in O(1).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum integer representable in IEEE 754 binary64 without precision loss (`Number.MAX_SAFE_INTEGER`).
pub const MAX_JS_SAFE_INT: u64 = (@as(u64, 1) << 53) - 1;

/// Maximum live slot count (`2^24 - 1`; `0xFF_FFFF` is reserved as the free-list sentinel).
pub const MAX_SLOTS: u32 = std.math.maxInt(u24);

const FREE_LIST_END: u24 = std.math.maxInt(u24);

pub const HandleError = error{
    InvalidHandle,
    Overflow,
    PoolCapacityExceeded,
    StaleHandle,
};

/// Strongly-typed 53-bit generational handle parameterized by a compile-time domain tag
/// (e.g. `.window`, `.ipc_request`, `.file`, `.channel`).
///
/// Distinct tags produce distinct Zig types that cannot be accidentally mixed at compile time,
/// and expose `zts_handle_tag` so `zts_rpc.tsgen` emits nominal branded TypeScript types.
pub fn Handle(comptime Tag: @TypeOf(.enum_literal)) type {
    return packed struct(u53) {
        index: u24,
        generation: u29,

        const Self = @This();

        /// Compile-time marker inspected by `zts_rpc` codec & TypeScript generator.
        pub const zts_handle_tag = Tag;

        /// Null sentinel guaranteed never to match any allocated slot.
        pub const invalid: Self = .{ .index = 0, .generation = 0 };

        pub inline fn isValid(self: Self) bool {
            return self.generation != 0 and self.index != FREE_LIST_END;
        }

        pub inline fn eql(a: Self, b: Self) bool {
            return a.toU53() == b.toU53();
        }

        pub inline fn toU53(self: Self) u53 {
            return @bitCast(self);
        }

        pub inline fn fromU53(raw: u53) HandleError!Self {
            const h: Self = @bitCast(raw);
            if (!h.isValid()) return error.InvalidHandle;
            return h;
        }

        pub inline fn fromU53Unchecked(raw: u53) Self {
            return @bitCast(raw);
        }

        pub inline fn toU64(self: Self) u64 {
            return @as(u64, self.toU53());
        }

        pub fn fromU64(raw: u64) HandleError!Self {
            if (raw > MAX_JS_SAFE_INT) return error.Overflow;
            return fromU53(@intCast(raw));
        }

        /// Lossless conversion to IEEE 754 `f64` (`Number` in JS).
        pub inline fn toF64(self: Self) f64 {
            return @floatFromInt(self.toU64());
        }

        /// Validates that `num` is a finite, exact integer within `[1, 2^53 - 1]` and valid handle.
        pub fn fromF64(num: f64) HandleError!Self {
            if (!std.math.isFinite(num) or num < 1.0 or num > @as(f64, @floatFromInt(MAX_JS_SAFE_INT))) {
                return error.InvalidHandle;
            }
            if (@trunc(num) != num) return error.InvalidHandle;
            return fromU64(@intFromFloat(num));
        }

        pub fn jsonStringify(self: Self, jws: anytype) !void {
            try jws.write(self.toU64());
        }

        pub fn jsonParse(_: Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            const raw = try std.json.innerParse(u64, undefined, source, options);
            return fromU64(raw) catch return error.InvalidNumber;
        }

        pub fn jsonParseFromValue(_: Allocator, source: std.json.Value, _: std.json.ParseOptions) !Self {
            return switch (source) {
                .integer => |i| {
                    if (i < 1) return error.InvalidNumber;
                    return fromU64(@intCast(i)) catch return error.InvalidNumber;
                },
                .float => |f| fromF64(f) catch return error.InvalidNumber,
                else => error.UnexpectedToken,
            };
        }
    };
}

/// Contiguous, allocation-minimal generational slot map storing values of type `T`.
///
/// Follows the unmanaged Zig container convention (`var pool: HandlePool(File, .file) = .empty;`).
/// Lookups (`get`, `getPtr`, `contains`) and `release` perform zero heap allocations in O(1) time.
pub fn HandlePool(comptime T: type, comptime Tag: @TypeOf(.enum_literal)) type {
    return struct {
        const Self = @This();
        pub const HandleType = Handle(Tag);

        const Slot = struct {
            generation: u29,
            occupied: bool,
            payload: union {
                value: T,
                next_free: u24,
            },
        };

        slots: std.ArrayList(Slot) = .empty,
        free_head: u24 = FREE_LIST_END,
        live_count: u32 = 0,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.slots.deinit(allocator);
            self.* = .empty;
        }

        /// Runs `dtor(ptr)` on every currently live element, then frees backing storage.
        pub fn deinitWith(self: *Self, allocator: Allocator, dtor: anytype) void {
            var it = self.iterator();
            while (it.next()) |entry| {
                dtor(entry.value_ptr);
            }
            self.deinit(allocator);
        }

        pub inline fn count(self: *const Self) u32 {
            return self.live_count;
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, new_capacity: usize) (Allocator.Error || HandleError)!void {
            if (new_capacity > MAX_SLOTS) return error.PoolCapacityExceeded;
            try self.slots.ensureTotalCapacity(allocator, new_capacity);
        }

        /// Inserts `value` into the pool and returns a unique generational `Handle(Tag)`.
        pub fn acquire(self: *Self, allocator: Allocator, value: T) (Allocator.Error || HandleError)!HandleType {
            if (self.free_head != FREE_LIST_END) {
                const idx = self.free_head;
                const slot = &self.slots.items[idx];
                std.debug.assert(!slot.occupied);
                self.free_head = slot.payload.next_free;
                slot.occupied = true;
                slot.payload = .{ .value = value };
                self.live_count += 1;
                return .{ .index = idx, .generation = slot.generation };
            }

            if (self.slots.items.len >= MAX_SLOTS) return error.PoolCapacityExceeded;
            const idx: u24 = @intCast(self.slots.items.len);
            try self.slots.append(allocator, .{
                .generation = 1,
                .occupied = true,
                .payload = .{ .value = value },
            });
            self.live_count += 1;
            return .{ .index = idx, .generation = 1 };
        }

        /// Returns a mutable pointer to the stored value, or `null` if `handle` is invalid or stale.
        pub inline fn getPtr(self: *Self, handle: HandleType) ?*T {
            if (!handle.isValid()) return null;
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (!slot.occupied or slot.generation != handle.generation) return null;
            return &slot.payload.value;
        }

        /// Returns a const pointer to the stored value, or `null` if `handle` is invalid or stale.
        pub inline fn get(self: *const Self, handle: HandleType) ?*const T {
            if (!handle.isValid()) return null;
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (!slot.occupied or slot.generation != handle.generation) return null;
            return &slot.payload.value;
        }

        pub inline fn contains(self: *const Self, handle: HandleType) bool {
            return self.get(handle) != null;
        }

        /// Removes the item identified by `handle` and returns it by value, advancing the slot's
        /// generation so any lingering copy of `handle` becomes permanently unusable.
        pub fn release(self: *Self, handle: HandleType) HandleError!T {
            if (!handle.isValid()) return error.InvalidHandle;
            if (handle.index >= self.slots.items.len) return error.StaleHandle;
            const slot = &self.slots.items[handle.index];
            if (!slot.occupied or slot.generation != handle.generation) return error.StaleHandle;

            const removed = slot.payload.value;
            slot.occupied = false;
            // Advance generation, skipping reserved `0` on 29-bit wrap-around.
            slot.generation = if (slot.generation == std.math.maxInt(u29)) 1 else slot.generation + 1;
            slot.payload = .{ .next_free = self.free_head };
            self.free_head = handle.index;
            self.live_count -= 1;
            return removed;
        }

        /// Invalidates all currently live handles while retaining backing memory capacity.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.free_head = FREE_LIST_END;
            self.live_count = 0;
            // Rebuild free list in reverse so index 0 is allocated first next time.
            var i: usize = self.slots.items.len;
            while (i > 0) {
                i -= 1;
                const slot = &self.slots.items[i];
                if (slot.occupied) {
                    slot.occupied = false;
                    slot.generation = if (slot.generation == std.math.maxInt(u29)) 1 else slot.generation + 1;
                }
                slot.payload = .{ .next_free = self.free_head };
                self.free_head = @intCast(i);
            }
        }

        pub const Entry = struct {
            handle: HandleType,
            value_ptr: *T,
        };

        pub const Iterator = struct {
            slots: []Slot,
            cursor: usize = 0,

            pub fn next(it: *Iterator) ?Entry {
                while (it.cursor < it.slots.len) {
                    const idx = it.cursor;
                    it.cursor += 1;
                    const slot = &it.slots[idx];
                    if (slot.occupied) {
                        return .{
                            .handle = .{ .index = @intCast(idx), .generation = slot.generation },
                            .value_ptr = &slot.payload.value,
                        };
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .slots = self.slots.items };
        }
    };
}

// ============================================================================
// Unit, Boundary & Stress Tests
// ============================================================================

test "Handle(Tag): 53-bit packing, f64 losslessness, and JSON round-trip" {
    const WinHandle = Handle(.test_win);

    try std.testing.expect(!WinHandle.invalid.isValid());
    try std.testing.expectEqual(@as(u64, 0), WinHandle.invalid.toU64());
    try std.testing.expectError(error.InvalidHandle, WinHandle.fromU64(0));
    try std.testing.expectError(error.Overflow, WinHandle.fromU64(MAX_JS_SAFE_INT + 1));

    // Extreme boundary: highest legal slot + highest 29-bit generation
    const extreme: WinHandle = .{
        .index = MAX_SLOTS - 1,
        .generation = std.math.maxInt(u29),
    };
    try std.testing.expect(extreme.isValid());
    try std.testing.expect(extreme.toU64() <= MAX_JS_SAFE_INT);

    // Exact IEEE 754 binary64 round-trip without a single bit lost
    const as_f64 = extreme.toF64();
    const recovered = try WinHandle.fromF64(as_f64);
    try std.testing.expectEqual(extreme, recovered);

    // Reject fractional, NaN, negative, and out-of-range floats from untrusted JS inputs
    try std.testing.expectError(error.InvalidHandle, WinHandle.fromF64(1.5));
    try std.testing.expectError(error.InvalidHandle, WinHandle.fromF64(-1.0));
    try std.testing.expectError(error.InvalidHandle, WinHandle.fromF64(std.math.nan(f64)));
    try std.testing.expectError(error.InvalidHandle, WinHandle.fromF64(std.math.inf(f64)));

    // JSON serialize & parse round-trip
    const Wrapper = struct { h: WinHandle };
    const json_text = try std.json.Stringify.valueAlloc(std.testing.allocator, Wrapper{ .h = extreme }, .{});
    defer std.testing.allocator.free(json_text);

    const parsed = try std.json.parseFromSlice(Wrapper, std.testing.allocator, json_text, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(extreme, parsed.value.h);

    // Invalid zero / overflow JSON numbers must fail cleanly
    try std.testing.expectError(error.InvalidNumber, std.json.parseFromSliceLeaky(Wrapper, std.testing.allocator, "{\"h\":0}", .{}));
    try std.testing.expectError(error.InvalidNumber, std.json.parseFromSliceLeaky(Wrapper, std.testing.allocator, "{\"h\":9007199254740992}", .{}));
}

test "HandlePool: ABA stale handle detection, wrap-around safety, and zero memory leaks" {
    const alloc = std.testing.allocator;
    var pool: HandlePool([]const u8, .resource) = .empty;
    defer pool.deinit(alloc);

    const h1 = try pool.acquire(alloc, "file-A");
    const h2 = try pool.acquire(alloc, "socket-B");
    try std.testing.expectEqual(@as(u32, 2), pool.count());
    try std.testing.expectEqualStrings("file-A", pool.get(h1).?.*);
    try std.testing.expectEqualStrings("socket-B", pool.get(h2).?.*);

    // Release h1, then immediately acquire h3 in the recycled slot 0 (classic ABA scenario)
    const old_val = try pool.release(h1);
    try std.testing.expectEqualStrings("file-A", old_val);
    const h3 = try pool.acquire(alloc, "pipe-C");
    try std.testing.expectEqual(h1.index, h3.index);
    try std.testing.expect(h1.generation != h3.generation);

    // Stale h1 MUST NOT read or destroy h3!
    try std.testing.expect(pool.get(h1) == null);
    try std.testing.expectError(error.StaleHandle, pool.release(h1));
    try std.testing.expectEqualStrings("pipe-C", pool.get(h3).?.*);

    // Force generation wrap-around past `maxInt(u29)` and verify generation `0` is skipped
    pool.slots.items[h3.index].generation = std.math.maxInt(u29);
    const max_gen_handle: @TypeOf(pool).HandleType = .{
        .index = h3.index,
        .generation = std.math.maxInt(u29),
    };
    _ = try pool.release(max_gen_handle);
    const wrapped = try pool.acquire(alloc, "wrapped-D");
    try std.testing.expectEqual(@as(u29, 1), wrapped.generation);
    try std.testing.expect(wrapped.isValid());

    // `clearRetainingCapacity` must invalidate all previously live handles
    pool.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u32, 0), pool.count());
    try std.testing.expect(!pool.contains(h2));
    try std.testing.expect(!pool.contains(wrapped));
}

test "HandlePool: deinitWith runs custom cleanup for every remaining live resource" {
    const alloc = std.testing.allocator;
    const CleanedCounter = struct {
        var closed: usize = 0;
        fn close(val: *u32) void {
            closed += val.*;
        }
    };
    CleanedCounter.closed = 0;

    var pool: HandlePool(u32, .cleanup_test) = .empty;
    const a = try pool.acquire(alloc, 10);
    _ = try pool.acquire(alloc, 20);
    _ = try pool.acquire(alloc, 30);
    _ = try pool.release(a); // Only 20 + 30 remain live

    pool.deinitWith(alloc, CleanedCounter.close);
    try std.testing.expectEqual(@as(usize, 50), CleanedCounter.closed);
}

test "HandlePool: 10,000-step randomized state-machine fuzz test against ground-truth oracle" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5A54_535F_4D31_3031);
    const rng = prng.random();

    const ValHandle = Handle(.fuzz_slot);
    var pool: HandlePool(u64, .fuzz_slot) = .empty;
    defer pool.deinit(alloc);

    var live_list: std.ArrayList(struct { h: ValHandle, v: u64 }) = .empty;
    defer live_list.deinit(alloc);

    var graveyard: std.ArrayList(ValHandle) = .empty;
    defer graveyard.deinit(alloc);

    for (0..10_000) |step| {
        const action = rng.uintLessThan(u8, 100);
        if (action < 55 or live_list.items.len == 0) {
            // Acquire new handle & verify lossless f64 round-trip on every single handle
            const secret: u64 = (@as(u64, step) << 16) ^ rng.int(u16);
            const h = try pool.acquire(alloc, secret);
            try std.testing.expectEqual(h, try ValHandle.fromF64(h.toF64()));
            try live_list.append(alloc, .{ .h = h, .v = secret });
        } else if (action < 85) {
            // Release a random live handle and record it in the stale graveyard
            const pick = rng.uintLessThan(usize, live_list.items.len);
            const entry = live_list.swapRemove(pick);
            const released_val = try pool.release(entry.h);
            try std.testing.expectEqual(entry.v, released_val);
            if (graveyard.items.len < 512) {
                try graveyard.append(alloc, entry.h);
            } else {
                graveyard.items[rng.uintLessThan(usize, graveyard.items.len)] = entry.h;
            }
        } else {
            // Probe both a random live handle and a random dead handle (ABA attack!)
            const pick = rng.uintLessThan(usize, live_list.items.len);
            const entry = live_list.items[pick];
            try std.testing.expectEqual(entry.v, pool.get(entry.h).?.*);

            if (graveyard.items.len > 0) {
                const dead = graveyard.items[rng.uintLessThan(usize, graveyard.items.len)];
                try std.testing.expect(pool.get(dead) == null);
                try std.testing.expectError(error.StaleHandle, pool.release(dead));
            }
        }
        try std.testing.expectEqual(@as(u32, @intCast(live_list.items.len)), pool.count());
    }
}
