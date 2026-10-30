//! `M5-06` documentation site: a std-only Markdown renderer + static site generator.
//!
//! Exposed as a module so the renderer can be unit-tested (`./zigw quick-test`) independently of
//! the IO wrapper, and so `zts` (M5-02) can eventually reuse it.

pub const markdown = @import("markdown.zig");
pub const site = @import("site.zig");
pub const demos = @import("demos.zig");
pub const generate = @import("main.zig").generate;
pub const SiteReport = @import("main.zig").SiteReport;

test {
    _ = markdown;
    _ = site;
    _ = demos;
}
