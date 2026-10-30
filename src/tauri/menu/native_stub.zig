//! Fallback menu backend: no toolkit on this target (headless, `wasm`, or `-Dgtk=false`).
//!
//! Keeps `plugin:menu` importable and unit-testable everywhere; every apply reports
//! `error.Unavailable`, which the wire surfaces as an IPC error instead of pretending to work.

const menu = @import("mod.zig");

pub fn backend() menu.Backend {
    return .{ .vtable = &menu.StubBackend.vtable };
}
