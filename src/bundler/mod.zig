//! `M5-03` — turn a built Z-Ts executable into something a user can install.
//!
//! The bundler is split so that everything except the final write is a pure function:
//!
//! * [`app`] — metadata (`App`) plus the exact bytes of `control`, `.desktop`, `Info.plist`,
//!   `AppRun` and the artifact file names.
//! * [`plan`] — the virtual package: a deterministic, sorted list of `Entry { path, mode, bytes }`
//!   for each layout (AppDir, `.app`, `.deb` payload, portable tarball).
//! * [`deb`] — `ar` + `control.tar.gz` + `data.tar.gz`, byte-for-byte reproducible.
//! * [`tree`] — materialise a plan into a directory (the only part that writes files).
//! * [`ico`] / [`pe`] — Windows: parse a `.ico` and append a `.rsrc` section to a finished PE image,
//!   because Zig 0.17's build system has no Win32 resource embedding step.
//! * [`binary`] — read the object format and CPU back out of a built executable, so a cross-build
//!   is labelled with its real architecture.
//!
//! `src/cli` calls [`tree.write`] and [`deb.buildAlloc`]; the tests in this directory never touch
//! the filesystem beyond `testing.tmpDir`.

const std = @import("std");

pub const app = @import("app.zig");
pub const plan = @import("plan.zig");
pub const deb = @import("deb.zig");
pub const tree = @import("tree.zig");
pub const pe = @import("pe.zig");
pub const ico = @import("ico.zig");
pub const binary = @import("binary.zig");

pub const App = app.App;
pub const Format = app.Format;
pub const Entry = plan.Entry;
pub const Package = plan.Package;

test {
    _ = app;
    _ = plan;
    _ = deb;
    _ = tree;
    _ = pe;
    _ = ico;
    _ = binary;
}
