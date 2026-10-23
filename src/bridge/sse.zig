//! Thread-Safe Multi-Subscriber Server-Sent Events Broker (`src/bridge/sse.zig`).
//!
//! Broadcasts real-time server -> client frames (`eval`, `emit`, `window`, or arbitrary custom
//! event streams) to all connected SSE clients (`GET /__zts_events__`):
//! - Each subscriber gets an isolated `foundation.RingQueue([]u8)` so a slow tab cannot block
//!   RPC workers or other tabs.
//! - Multi-line payloads are strictly formatted line-by-line (`data: ...\n`) per WHATWG SSE spec,
//!   preventing newline frame-injection vulnerabilities.
//! - `closeAll(io)` closes every subscriber queue AND calls `stream.shutdown(io, .both)` so
//!   blocking network writers unblock immediately with zero memory or socket leaks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const foundation = @import("zts_foundation");
const html_escape = foundation.html_escape;

pub const ClientId = foundation.Handle(.sse_client);

pub const ClientEntry = struct {
    allocator: Allocator,
    queue: foundation.RingQueue([]u8) = .empty,
    stream: ?Io.net.Stream = null,

    fn freeSlice(alloc: Allocator, item_ptr: *[]u8) void {
        alloc.free(item_ptr.*);
    }

    pub fn deinit(self: *ClientEntry) void {
        const alloc = self.allocator;
        while (self.queue.buf.len > 0 and self.queue.len > 0) {
            const idx = self.queue.head & (self.queue.buf.len - 1);
            alloc.free(self.queue.buf[idx]);
            self.queue.head +%= 1;
            self.queue.len -= 1;
        }
        self.queue.deinit(alloc);
    }
};

/// Formats an SSE frame (`event: <name>\ndata: <line1>\ndata: <line2>\n\n`), stripping `\r` in event names.
pub fn formatSseFrameAlloc(allocator: Allocator, event_name: []const u8, data: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (event_name.len > 0) {
        try out.appendSlice(allocator, "event: ");
        for (event_name) |c| {
            if (c != '\r' and c != '\n') try out.append(allocator, c);
        }
        try out.append(allocator, '\n');
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        try out.appendSlice(allocator, "data: ");
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    try out.append(allocator, '\n');

    return out.toOwnedSlice(allocator);
}

pub const SseHub = struct {
    allocator: Allocator,
    mu: Io.Mutex = .init,
    clients: foundation.HandlePool(*ClientEntry, .sse_client) = .empty,
    closed: bool = false,

    pub fn init(allocator: Allocator) SseHub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SseHub) void {
        var it = self.clients.iterator();
        while (it.next()) |slot| {
            const entry = slot.value_ptr.*;
            entry.deinit();
            self.allocator.destroy(entry);
        }
        self.clients.deinit(self.allocator);
    }

    pub const Subscription = struct {
        id: ClientId,
        entry: *ClientEntry,
    };

    /// Registers a new SSE subscriber queue and optional TCP stream handle.
    pub fn subscribe(self: *SseHub, io: Io, stream: ?Io.net.Stream) !Subscription {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.closed) return error.Closed;

        const entry = try self.allocator.create(ClientEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .allocator = self.allocator,
            .stream = stream,
        };

        const id = try self.clients.acquire(self.allocator, entry);
        return .{ .id = id, .entry = entry };
    }

    /// Removes and frees a subscriber queue when its HTTP stream disconnects.
    pub fn unsubscribe(self: *SseHub, io: Io, id: ClientId) void {
        var removed: ?*ClientEntry = null;
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            if (self.clients.release(id)) |entry| {
                removed = entry;
            } else |_| {}
        }
        if (removed) |entry| {
            entry.deinit();
            self.allocator.destroy(entry);
        }
    }

    pub fn subscriberCount(self: *SseHub, io: Io) u32 {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.clients.count();
    }

    /// Broadcasts a pre-formatted SSE frame to every connected subscriber.
    pub fn broadcastRawFrame(self: *SseHub, io: Io, frame: []const u8) Allocator.Error!usize {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.closed) return 0;

        var delivered: usize = 0;
        var it = self.clients.iterator();
        while (it.next()) |slot| {
            const entry = slot.value_ptr.*;
            const copy = try self.allocator.dupe(u8, frame);
            _ = entry.queue.push(self.allocator, io, copy) catch {
                self.allocator.free(copy);
                continue;
            };
            delivered += 1;
        }
        return delivered;
    }

    /// Broadcasts a custom SSE event (`event: <event_type>\ndata: ...\n\n`).
    pub fn publishRaw(self: *SseHub, io: Io, event_type: []const u8, data: []const u8) Allocator.Error!usize {
        const frame = try formatSseFrameAlloc(self.allocator, event_type, data);
        defer self.allocator.free(frame);
        return self.broadcastRawFrame(io, frame);
    }

    /// Broadcasts a structured `emit` event (`event: emit\ndata: {"event":"...","payload":...}\n\n`).
    pub fn publishEmit(self: *SseHub, io: Io, event_name: []const u8, raw_json_payload: []const u8) Allocator.Error!usize {
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        var aw: Io.Writer.Allocating = .fromArrayList(self.allocator, &json_buf);
        aw.writer.writeAll("{\"event\":") catch return error.OutOfMemory;
        html_escape.writeJsonString(&aw.writer, event_name, true) catch return error.OutOfMemory;
        aw.writer.writeAll(",\"payload\":") catch return error.OutOfMemory;
        aw.writer.writeAll(if (raw_json_payload.len > 0) raw_json_payload else "null") catch return error.OutOfMemory;
        aw.writer.writeAll("}") catch return error.OutOfMemory;
        json_buf = aw.toArrayList();

        return self.publishRaw(io, "emit", json_buf.items);
    }

    /// Broadcasts an `eval` JavaScript execution command (`event: eval\ndata: {"script":"..."}\n\n`).
    pub fn publishEval(self: *SseHub, io: Io, js_source: []const u8) Allocator.Error!usize {
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        var aw: Io.Writer.Allocating = .fromArrayList(self.allocator, &json_buf);
        aw.writer.writeAll("{\"script\":") catch return error.OutOfMemory;
        html_escape.writeJsonString(&aw.writer, js_source, true) catch return error.OutOfMemory;
        aw.writer.writeAll("}") catch return error.OutOfMemory;
        json_buf = aw.toArrayList();

        return self.publishRaw(io, "eval", json_buf.items);
    }

    /// Broadcasts a window state mutation (e.g. `document.title` update) to browser tabs.
    pub fn publishWindowTitle(self: *SseHub, io: Io, title: []const u8) Allocator.Error!usize {
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        var aw: Io.Writer.Allocating = .fromArrayList(self.allocator, &json_buf);
        aw.writer.writeAll("{\"title\":") catch return error.OutOfMemory;
        html_escape.writeJsonString(&aw.writer, title, true) catch return error.OutOfMemory;
        aw.writer.writeAll("}") catch return error.OutOfMemory;
        json_buf = aw.toArrayList();

        return self.publishRaw(io, "window", json_buf.items);
    }

    /// Closes all active subscriber queues AND shuts down their sockets to unblock writers immediately.
    pub fn closeAll(self: *SseHub, io: Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.closed = true;

        var it = self.clients.iterator();
        while (it.next()) |slot| {
            const entry = slot.value_ptr.*;
            entry.queue.close(io);
            if (entry.stream) |s| {
                s.shutdown(io, .both) catch {};
            }
        }
    }
};

test "SseHub fans out multi-line frames safely to multiple subscribers with zero memory leaks" {
    var hub = SseHub.init(testing.allocator);
    defer hub.deinit();

    const sub1 = try hub.subscribe(testing.io, null);
    const sub2 = try hub.subscribe(testing.io, null);
    try testing.expectEqual(@as(u32, 2), hub.subscriberCount(testing.io));

    const n = try hub.publishRaw(testing.io, "telemetry\r\nevil", "line1\nline2");
    try testing.expectEqual(@as(usize, 2), n);

    const f1 = sub1.entry.queue.tryPop(testing.io).?;
    defer testing.allocator.free(f1);
    try testing.expectEqualStrings("event: telemetryevil\ndata: line1\ndata: line2\n\n", f1);

    // Unsubscribing sub2 while it still has unread queued frames MUST free all unread slices cleanly!
    hub.unsubscribe(testing.io, sub2.id);
    hub.unsubscribe(testing.io, sub1.id);
    try testing.expectEqual(@as(u32, 0), hub.subscriberCount(testing.io));
}
