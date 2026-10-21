//! `zts_core` — zero-dependency, allocation-explicit primitives shared by every
//! higher Z-Ts package.
//!
//! Everything here is OS-I/O-free and `link_libc = false` compatible:
//!
//! - `assets` — static/directory asset resolution, SPA fallback, Range/HEAD
//! - `csp` — CSP nonces, SHA-256 source hashes, `<head>` injection
//! - `glob` — capability-scope matcher with traversal hardening
//! - `html_escape` — HTML-safe JSON serialization (anti-`</script>` XSS)
//! - `http_range` — RFC 9110 byte ranges and `206`/`416` helpers
//! - `mime` — strict MIME table + magic-byte sniffing
//! - `url` — origin extraction/comparison with spoofing rejection
//!
//! New modules must stay in alphabetical order to keep parallel-agent diffs
//! conflict-free (see `AGENTS.md` §1.3).

pub const assets = @import("assets.zig");
pub const csp = @import("csp.zig");
pub const glob = @import("glob.zig");
pub const html_escape = @import("html_escape.zig");
pub const http_range = @import("http_range.zig");
pub const mime = @import("mime.zig");
pub const url = @import("url.zig");

test {
    _ = assets;
    _ = csp;
    _ = glob;
    _ = html_escape;
    _ = http_range;
    _ = mime;
    _ = url;
}
