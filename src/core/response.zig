//! Transport-Neutral Outgoing Message Envelope (`src/core/response.zig`).
//!
//! Shared across standalone RPC servers (`zts_rpc`), custom-scheme WebView handlers,
//! HTTP bridges, and embedded asset pipelines without pulling in any windowing or OS types.

const owned_bytes = @import("owned_bytes.zig");
pub const OwnedBytes = owned_bytes.OwnedBytes;

/// The `"ok" / "error"` discriminant of a Tauri v2 IPC response, so `@tauri-apps/api`'s `invoke()`
/// can reject a promise without parsing the body.
pub const IpcStatus = enum {
    /// The command succeeded.
    ok,
    /// The command failed; the body carries the error payload.
    err,
};

/// Transport-neutral response payload carrying status, MIME content type, and owned/static bytes.
pub const OutgoingResponse = struct {
    /// Whether this is a success or a failure.
    status: IpcStatus = .ok,
    /// HTTP status the bridge should report.
    http_code: u16 = 200,
    /// `Content-Type` of `body`.
    content_type: []const u8 = "application/json",
    /// The payload, owned by the response.
    body: OwnedBytes = .empty,

    /// Releases the body.
    pub fn deinit(self: *OutgoingResponse) void {
        self.body.deinit();
    }
};
