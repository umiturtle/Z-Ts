//! Z-Ts: Lightweight Desktop & WebView Application Framework in Zig 0.17.
//!
//! Root facade module exporting the orthogonal package layers (`docs/architecture/00-overview.md`).

const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

/// `zts_core` — Zero-dependency pure Zig primitives, handles, geometry, host VTable & web asset engine.
pub const core = @import("core/mod.zig");

/// `zts_rpc` — Type-safe Web ⇔ Zig JSON codec, 53-bit integer guards, boundary types & naming rules.
pub const rpc = @import("rpc/mod.zig");

test "z_ts scaffold version" {
    try std.testing.expectEqual(@as(usize, 0), version.major);
    try std.testing.expectEqual(@as(usize, 1), version.minor);
}

test {
    _ = core;
    _ = rpc;
}
