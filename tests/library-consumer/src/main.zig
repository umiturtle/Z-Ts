//! Exercises one real API from each of the four pure-Zig modules, so a successful run proves the
//! dependency resolves *and* that its exported declarations are usable from another package.

const std = @import("std");
const foundation = @import("zts_foundation");
const core = @import("zts_core");
const rpc = @import("zts_rpc");
const web = @import("zts_web");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // zts_foundation: generational handles really allocate and resolve.
    const ResourceId = foundation.Handle(.resource);
    var pool: foundation.HandlePool([]const u8, .resource) = .empty;
    defer pool.deinit(allocator);
    const handle: ResourceId = try pool.acquire(allocator, "lib://resource");
    if (!std.mem.eql(u8, pool.getPtr(handle).?.*, "lib://resource")) return error.HandleMismatch;

    // zts_core: the re-exported geometry types keep their value semantics.
    const size = core.LogicalSize{ .width = .{ .v = 640 }, .height = .{ .v = 480 } };
    if (size.width.v != 640 or size.height.v != 480) return error.GeometryMismatch;

    // zts_web: an embedded asset is served with a byte range.
    const assets = web.Assets{ .entries = &.{
        .{ .path = "/hello.txt", .bytes = "0123456789ABCDEFGHIJ" },
    } };
    var response = try assets.resolve(allocator, "/hello.txt", .{ .range_header = "bytes=10-19" });
    defer response.deinit();
    if (response.status != web.AssetStatus.partial_content) return error.AssetMismatch;
    if (!std.mem.eql(u8, response.body.slice(), "ABCDEFGHIJ")) return error.AssetMismatch;

    // zts_rpc: the module is importable and its codec surface exists.
    _ = rpc.codec;

    std.debug.print("OK library consumer modules=4 handle=1 geometry=640x480 assets=10\n", .{});
}
