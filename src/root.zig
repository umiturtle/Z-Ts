//! Z-Ts: Zig port of Tauri
//!
//! Root library entry point (scaffold).

const std = @import("std");

pub const version = "0.1.0";

test "z_ts scaffold version" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

test {
    _ = @import("rpc/codec.zig");
}
