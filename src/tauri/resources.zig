//! Generational Server-Side Resource Table & `plugin:resources|*` Commands (`src/tauri/resources.zig`).
//!
//! Backs `@tauri-apps/api/core` `Resource` (`await using res = ...` / `res.close()` -> `plugin:resources|close`).
//! Resources are stored in a thread-safe `HandlePool` so forged or double-closed resource IDs
//! return `error.BadResourceId` instead of causing Use-After-Free or ABA corruption.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");

pub const ResourceHandle = core.Handle(.resource);

pub const ResourceError = error{
    BadResourceId,
};

const Entry = struct {
    ptr: ?*anyopaque,
    type_id: usize,
    destroy_fn: ?*const fn (Allocator, ?*anyopaque) void,
};

pub const ResourceTable = struct {
    allocator: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    pool: core.HandlePool(Entry, .resource) = .empty,

    pub fn init(allocator: Allocator, io: Io) ResourceTable {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *ResourceTable) void {
        var it = self.pool.iterator();
        while (it.next()) |slot| {
            if (slot.value_ptr.destroy_fn) |dtor| {
                dtor(self.allocator, slot.value_ptr.ptr);
            }
        }
        self.pool.deinit(self.allocator);
    }

    fn typeIdOf(comptime T: type) usize {
        const Holder = struct {
            const Self = T;
            var marker: u8 = 0;
            comptime {
                _ = Self;
            }
        };
        return @intFromPtr(&Holder.marker);
    }

    /// Allocates and registers a typed value `T` inside the table, returning its 53-bit `rid`.
    pub fn insertOwned(self: *ResourceTable, comptime T: type, value: T) !u53 {
        const boxed = try self.allocator.create(T);
        errdefer self.allocator.destroy(boxed);
        boxed.* = value;

        const Dtor = struct {
            fn run(alloc: Allocator, raw: ?*anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(raw.?));
                if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) {
                    typed.deinit();
                }
                alloc.destroy(typed);
            }
        };

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        const h = try self.pool.acquire(self.allocator, .{
            .ptr = boxed,
            .type_id = typeIdOf(T),
            .destroy_fn = Dtor.run,
        });
        return h.toU53();
    }

    /// Looks up a typed pointer `*T` by `rid`, verifying both generation validity AND exact type `T`.
    pub fn getPtr(self: *ResourceTable, comptime T: type, rid: u53) ResourceError!*T {
        const handle = ResourceHandle.fromU53(rid) catch return error.BadResourceId;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        const entry = self.pool.get(handle) orelse return error.BadResourceId;
        if (entry.type_id != typeIdOf(T)) return error.BadResourceId;
        return @ptrCast(@alignCast(entry.ptr.?));
    }

    /// Destroys and removes the resource identified by `rid`.
    pub fn closeRid(self: *ResourceTable, rid: u53) ResourceError!void {
        const handle = ResourceHandle.fromU53(rid) catch return error.BadResourceId;
        self.mu.lockUncancelable(self.io);
        const removed = self.pool.release(handle) catch {
            self.mu.unlock(self.io);
            return error.BadResourceId;
        };
        self.mu.unlock(self.io);

        if (removed.destroy_fn) |dtor| {
            dtor(self.allocator, removed.ptr);
        }
    }
};

/// `plugin:resources|*` RPC command namespace (`Schema` key: `.resources`).
pub const Commands = struct {
    pub const rpc_prefix = "plugin:resources|";
    pub const RpcState = ResourceTable;

    pub fn close(state: *ResourceTable, args: struct { rid: u53 }) ResourceError!void {
        try state.closeRid(args.rid);
    }
};

test "ResourceTable tracks typed resources, runs deinit on close, and rejects stale/wrong-type access" {
    const CounterRes = struct {
        cleaned: *usize,
        label: []const u8,
        pub fn deinit(self: *@This()) void {
            self.cleaned.* += 1;
        }
    };

    var cleaned_count: usize = 0;
    var table = ResourceTable.init(testing.allocator, testing.io);
    defer table.deinit();

    const rid = try table.insertOwned(CounterRes, .{ .cleaned = &cleaned_count, .label = "tex0" });
    const ptr = try table.getPtr(CounterRes, rid);
    try testing.expectEqualStrings("tex0", ptr.label);

    // Wrong type lookup fails safely without UB!
    try testing.expectError(error.BadResourceId, table.getPtr(u32, rid));

    try Commands.close(&table, .{ .rid = rid });
    try testing.expectEqual(@as(usize, 1), cleaned_count);

    // Double close rejected cleanly!
    try testing.expectError(error.BadResourceId, Commands.close(&table, .{ .rid = rid }));
}
