//! `M5-02` `zts` CLI — `init` / `dev` / `build`.
//!
//! The CLI is split into pure, unit-tested pieces (`args`, `project`, `template`, `devserver`) plus
//! a thin `main.zig` that only does IO. Nothing here imports a `zts_*` module: the CLI drives the
//! user's `zig build`, it does not link the library.

pub const args = @import("args.zig");
pub const devserver = @import("devserver.zig");
pub const project = @import("project.zig");
pub const template = @import("template.zig");

// `main.zig` is intentionally absent from this test root: it imports the generated
// `zts_cli_options` module (the checkout path baked in by `build.zig`), which a bare
// `zig test src/cli/mod.zig` cannot provide. `zig build test` — and `zig build`, which installs
// the `zts` binary — type-check it instead.

test {
    _ = args;
    _ = devserver;
    _ = project;
    _ = template;
}
