//! Z-Ts: Zig port of Tauri
//!
//! Root library entry point (scaffold).

const std = @import("std");

pub const version = "0.1.0";

/// ① Zero-dependency Pure Zig primitives (`HandlePool`, `OwnedBytes`, queue,
/// geometry, host VTable and the Web asset/MIME/Range/CSP/URL/Glob foundation).
pub const core = @import("core/mod.zig");

test "z_ts scaffold version" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

test {
    _ = core;
}
