//! Fallback tray backend: no toolkit on this target (headless, `wasm`, or `-Dgtk=false`).

const tray = @import("mod.zig");

pub fn backend() tray.Backend {
    return .{ .vtable = &tray.StubBackend.vtable };
}
