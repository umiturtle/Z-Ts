//! `M5-02` `zts` CLI — `init` / `dev` / `build`.
//!
//! The CLI is split into pure, unit-tested pieces (`args`, `template`, and — as the next slices
//! land — `devserver` and `watch`) plus a thin `main.zig` that only does IO. Nothing here imports a
//! `zts_*` module: the CLI drives the user's `zig build`, it does not link the library.

pub const args = @import("args.zig");
pub const template = @import("template.zig");

test {
    _ = args;
    _ = template;
}
