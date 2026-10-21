//! Asynchronous / Deferred Ownership Byte Slice (`OwnedBytes`).
//!
//! Solves the cross-thread and OS-callback lifetime problem without extra copies:
//! - Static string/asset literals (`OwnedBytes.static("...")`) incur **0 allocations** and a no-op release.
//! - Zig-allocated slices (`OwnedBytes.fromOwnedSlice(alloc, buf)` / `dupe`) carry their exact
//!   `std.mem.Allocator` inline (zero extra heap header) and free cleanly on any thread.
//! - `intoCToken` / `destroyFromC` pack ownership into a single `*anyopaque` pointer directly
//!   compatible with C destruction callbacks such as WebKitGTK's `GDestroyNotify`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OwnedBytes = struct {
    bytes: []const u8 = "",
    ctx_ptr: ?*anyopaque = null,
    ctx_meta: ?*const anyopaque = null,
    release_fn: ?ReleaseFn = null,

    pub const ReleaseFn = *const fn (bytes: []const u8, ctx_ptr: ?*anyopaque, ctx_meta: ?*const anyopaque) void;

    pub const empty: OwnedBytes = .{};

    /// Wraps compile-time or externally outliving immutable memory with zero overhead.
    pub inline fn static(bytes: []const u8) OwnedBytes {
        return .{ .bytes = bytes };
    }

    /// Takes ownership of `buf` allocated from `allocator` with zero heap overhead.
    pub inline fn fromOwnedSlice(allocator: Allocator, buf: []u8) OwnedBytes {
        if (buf.len == 0) return .empty;
        return .{
            .bytes = buf,
            .ctx_ptr = allocator.ptr,
            .ctx_meta = @ptrCast(allocator.vtable),
            .release_fn = releaseZigAllocator,
        };
    }

    /// Copies `src` into fresh `allocator`-backed memory managed by `OwnedBytes`.
    pub fn dupe(allocator: Allocator, src: []const u8) Allocator.Error!OwnedBytes {
        if (src.len == 0) return .empty;
        const copy = try allocator.dupe(u8, src);
        return fromOwnedSlice(allocator, copy);
    }

    /// Wraps foreign memory (e.g. slab pool slot, mmap, or C library buffer) with a custom deleter.
    pub inline fn initCustom(
        bytes: []const u8,
        ctx_ptr: ?*anyopaque,
        ctx_meta: ?*const anyopaque,
        release_fn: ReleaseFn,
    ) OwnedBytes {
        return .{
            .bytes = bytes,
            .ctx_ptr = ctx_ptr,
            .ctx_meta = ctx_meta,
            .release_fn = release_fn,
        };
    }

    pub inline fn slice(self: *const OwnedBytes) []const u8 {
        return self.bytes;
    }

    pub inline fn len(self: *const OwnedBytes) usize {
        return self.bytes.len;
    }

    /// Transfers ownership out of `self`, leaving `self.*` safely inert (`.empty`) so a `defer`
    /// in the caller becomes a harmless no-op.
    pub inline fn move(self: *OwnedBytes) OwnedBytes {
        const out = self.*;
        self.* = .empty;
        return out;
    }

    /// Releases underlying storage if owned and resets `self.*` to `.empty` (idempotent).
    pub inline fn deinit(self: *OwnedBytes) void {
        if (self.release_fn) |f| {
            f(self.bytes, self.ctx_ptr, self.ctx_meta);
        }
        self.* = .empty;
    }

    fn releaseZigAllocator(bytes: []const u8, ctx_ptr: ?*anyopaque, ctx_meta: ?*const anyopaque) void {
        const vtable: *const Allocator.VTable = @ptrCast(@alignCast(ctx_meta.?));
        const allocator: Allocator = .{
            .ptr = ctx_ptr.?,
            .vtable = vtable,
        };
        const mut_ptr: [*]u8 = @constCast(bytes.ptr);
        allocator.free(mut_ptr[0..bytes.len]);
    }

    // ------------------------------------------------------------------------
    // Single-pointer C callback bridge (e.g. `GDestroyNotify` / Win32 stream)
    // ------------------------------------------------------------------------

    const CBox = struct {
        payload: OwnedBytes,
        box_alloc: Allocator,
    };

    pub const CParts = struct {
        ptr: ?[*]const u8,
        len: usize,
        /// Pass to C `user_data`; invoke `OwnedBytes.destroyFromC(token)` when C finishes reading `ptr[0..len]`.
        /// May be `null` when the slice requires no destruction (static/empty), in which case `destroyFromC(null)` is also safe.
        token: ?*anyopaque,
    };

    /// Converts `self` into `(ptr, len, user_data_token)` for C APIs whose completion callback
    /// only accepts a single `void* user_data` argument. Static slices allocate **0 bytes**.
    pub fn intoCParts(self: *OwnedBytes, box_alloc: Allocator) Allocator.Error!CParts {
        if (self.release_fn == null) {
            const p: ?[*]const u8 = if (self.bytes.len > 0) self.bytes.ptr else null;
            const n = self.bytes.len;
            self.* = .empty;
            return .{ .ptr = p, .len = n, .token = null };
        }
        const box = try box_alloc.create(CBox);
        box.* = .{
            .payload = self.move(),
            .box_alloc = box_alloc,
        };
        return .{
            .ptr = box.payload.bytes.ptr,
            .len = box.payload.bytes.len,
            .token = box,
        };
    }

    /// C-ABI compatible destruction callback matching `void (*)(void *user_data)` (`GDestroyNotify`).
    pub fn destroyFromC(token: ?*anyopaque) callconv(.c) void {
        const ptr = token orelse return;
        const box: *CBox = @ptrCast(@alignCast(ptr));
        const alloc = box.box_alloc;
        box.payload.deinit();
        alloc.destroy(box);
    }
};

// ============================================================================
// Unit & Ownership Transfer Tests
// ============================================================================

test "OwnedBytes: static, allocator-backed, idempotent deinit, move, and C callback bridge" {
    const alloc = std.testing.allocator;

    // 1. Static literal requires zero heap allocations and double-deinit is safe
    var s = OwnedBytes.static("hello static");
    try std.testing.expectEqualStrings("hello static", s.slice());
    s.deinit();
    s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.len());

    // 2. Heap allocation + move semantics ensure zero double-free & zero leak
    var original = try OwnedBytes.dupe(alloc, "payload from worker thread");
    defer original.deinit(); // Will be a safe no-op after `.move()`
    var transferred = original.move();
    try std.testing.expectEqual(@as(usize, 0), original.len());
    try std.testing.expectEqualStrings("payload from worker thread", transferred.slice());

    // 3. Round-trip through C single-pointer callback (`GDestroyNotify` simulation)
    const c_parts = try transferred.intoCParts(alloc);
    try std.testing.expect(c_parts.token != null);
    try std.testing.expectEqualStrings("payload from worker thread", c_parts.ptr.?[0..c_parts.len]);
    OwnedBytes.destroyFromC(c_parts.token);

    // Static CParts allocates nothing and tolerates null token destruction
    var static_bytes = OwnedBytes.static("zero-alloc asset");
    const static_parts = try static_bytes.intoCParts(alloc);
    try std.testing.expect(static_parts.token == null);
    OwnedBytes.destroyFromC(static_parts.token);
}
