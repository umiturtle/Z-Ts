//! Transport-Neutral Outgoing Message Envelope (`src/core/response.zig`).
//!
//! Shared across standalone RPC servers (`zts_rpc`), custom-scheme WebView handlers,
//! HTTP bridges, and embedded asset pipelines without pulling in any windowing or OS types.

const owned_bytes = @import("owned_bytes.zig");
pub const OwnedBytes = owned_bytes.OwnedBytes;

pub const IpcStatus = enum {
    ok,
    err,
};

/// Transport-neutral response payload carrying status, MIME content type, and owned/static bytes.
pub const OutgoingResponse = struct {
    status: IpcStatus = .ok,
    http_code: u16 = 200,
    content_type: []const u8 = "application/json",
    body: OwnedBytes = .empty,

    pub fn deinit(self: *OutgoingResponse) void {
        self.body.deinit();
    }
};
