//! `M5-02` — pure helpers shared by the `zts` sub-commands.
//!
//! Everything here is a string transformation: no filesystem, no processes. `main.zig` does the IO,
//! so every rule below (how a package name is recovered from `build.zig.zon`, what a dev server
//! calls a `.wasm` file, what the live-reload snippet looks like) is asserted by unit tests.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Reads a `.<field> = …` value out of a `build.zig.zon`.
///
/// Two spellings exist in the wild and both are accepted: the 0.17 enum literal
/// (`.name = .demo,`) and the string form (`.name = "demo",`). The scan requires the character
/// before the field name to be a separator so `.minimum_zig_version` is never mistaken for `.name`.
fn fieldValue(source: []const u8, field: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.find(u8, source[cursor..], field)) |offset| {
        const at = cursor + offset;
        cursor = at + field.len;
        if (at > 0 and (std.ascii.isAlphanumeric(source[at - 1]) or source[at - 1] == '_')) continue;

        var rest = std.mem.trimStart(u8, source[cursor..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
        if (rest.len == 0) return null;

        switch (rest[0]) {
            '"' => {
                const end = std.mem.findScalar(u8, rest[1..], '"') orelse return null;
                return rest[1 .. 1 + end];
            },
            '.' => {
                var end: usize = 1;
                while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
                if (end == 1) return null;
                return rest[1..end];
            },
            else => return null,
        }
    }
    return null;
}

/// `.name = .demo,` → `demo`.
pub fn packageName(zon: []const u8) ?[]const u8 {
    return fieldValue(zon, ".name");
}

/// `.z_ts = .{ .path = "../Z-Ts" },` → `../Z-Ts`.
///
/// The dependency name is searched for first, so a project that also path-depends on something else
/// still reports the right path, and a zon without the dependency answers `null` instead of
/// guessing at the first `.path` in the file.
pub fn dependencyPath(zon: []const u8, dep: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.find(u8, zon[cursor..], dep)) |offset| {
        const at = cursor + offset;
        cursor = at + dep.len;
        if (at > 0 and (std.ascii.isAlphanumeric(zon[at - 1]) or zon[at - 1] == '_')) continue;
        if (fieldValue(zon[at..], ".path")) |path| return path;
    }
    return null;
}

/// Where `zts build` puts the executable: `zig-out/bin/<name>` (plus `.exe` for Windows targets,
/// because a cross-compiled PE without the extension still runs but looks broken in a file manager).
pub fn executablePath(alloc: Allocator, name: []const u8, windows: bool) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "zig-out/bin/{s}{s}", .{ name, if (windows) ".exe" else "" });
}

/// Whether a `-Dtarget=` triple (or the host) produces a Windows executable.
pub fn isWindowsTarget(target: ?[]const u8) bool {
    const triple = target orelse return @import("builtin").os.tag == .windows;
    return std.mem.indexOf(u8, triple, "windows") != null;
}

/// Content type for the dev server. Deliberately short: a preview server's job is to make the
/// browser render the page, not to be a CDN. Unknown extensions fall back to `text/plain` so a
/// `.ts` source file opened by hand is readable instead of downloading itself.
pub fn mimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".map", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".ico", "image/x-icon" },
        .{ ".wasm", "application/wasm" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".md", "text/markdown; charset=utf-8" },
        .{ ".xml", "application/xml" },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    }
    if (std.mem.eql(u8, ext, ".ts")) return "text/javascript; charset=utf-8";
    return "application/octet-stream";
}

/// True when the response should be rewritten with the live-reload snippet.
pub fn isHtml(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".html") or
        std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".htm");
}

/// `/dir/page.html?x=1#top` → `/dir/page.html`. Query strings and fragments are the browser's
/// business; the filesystem never has a `?` in an asset name.
pub fn stripQuery(target: []const u8) []const u8 {
    const end = std.mem.findAny(u8, target, "?#") orelse return target;
    return target[0..end];
}

/// Maps a URL path onto a file below the project's `web/` directory.
///
/// Returns `null` for anything that could escape the root (`..`, backslashes, a drive letter).
/// A trailing slash means `index.html`, because `GET /` is the first request every browser sends.
pub fn assetPath(alloc: Allocator, target: []const u8) Allocator.Error!?[]const u8 {
    const path = stripQuery(target);
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return null;

    const relative = std.mem.trimStart(u8, path, "/");
    if (relative.len == 0) return try alloc.dupe(u8, "index.html");
    if (std.mem.endsWith(u8, relative, "/")) {
        return try std.fmt.allocPrint(alloc, "{s}index.html", .{relative});
    }
    return try alloc.dupe(u8, relative);
}

/// The live-reload snippet, injected into every served HTML page.
///
/// A polling `fetch` (not `EventSource`) keeps the dev server single-threaded and stateless: any
/// `GET` answers with the current build number, so no connection has to stay open while a rebuild
/// is running.
pub fn reloadScript(alloc: Allocator, build: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "<script data-zts-dev>(function(){{var v={d};var poll=function(){{fetch('/__zts_dev__/state',{{cache:'no-store'}})" ++
            ".then(function(r){{return r.json()}}).then(function(s){{if(s.v!==v)location.reload()}})" ++
            ".catch(function(){{}})}};setInterval(poll,700)}})()</script>",
        .{build},
    );
}

/// Inserts [`reloadScript`] just before `</body>` (the conventional place, so scripts that rely on
/// `document.body` still run first). Pages without a body tag get the snippet appended.
pub fn injectReload(alloc: Allocator, html: []const u8, build: u64) Allocator.Error![]u8 {
    const script = try reloadScript(alloc, build);
    defer alloc.free(script);
    if (std.mem.find(u8, html, "</body>")) |at| {
        var out = try alloc.alloc(u8, html.len + script.len);
        @memcpy(out[0..at], html[0..at]);
        @memcpy(out[at..][0..script.len], script);
        @memcpy(out[at + script.len ..], html[at..]);
        return out;
    }
    var out = try alloc.alloc(u8, html.len + script.len);
    @memcpy(out[0..html.len], html);
    @memcpy(out[html.len..], script);
    return out;
}

/// Rewrites a path in place to POSIX separators.
///
/// `std.fs.path.relativeAlloc` uses the native separator, but every `build.zig.zon` in the docs is
/// written POSIX-style and a backslash inside a Zig string literal is an escape — so the CLI
/// normalises before writing a dependency path.
pub fn toPosix(path: []u8) []u8 {
    for (path) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return path;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "packageName reads the enum-literal and the string spelling" {
    try testing.expectEqualStrings("demo", packageName(
        \\.{
        \\    .name = .demo,
        \\    .version = "0.1.0",
        \\}
    ).?);
    try testing.expectEqualStrings("legacy_app", packageName(
        \\.{ .name = "legacy_app", .version = "0.1.0" }
    ).?);
}

test "packageName ignores look-alike fields instead of returning the wrong name" {
    // `.minimum_zig_version` contains `name` but not as a field; a careless `indexOf(".name")`
    // would return null here and `zts build` would print the wrong executable path.
    const zon =
        \\.{
        \\    .minimum_zig_version = "0.17.0",
        \\    .name = .real_name,
        \\}
    ;
    try testing.expectEqualStrings("real_name", packageName(zon).?);
    try testing.expect(packageName(".version = \"1.0.0\",") == null);
}

test "dependencyPath finds the z_ts entry and not some other path" {
    const zon =
        \\.{ .name = .demo, .dependencies = .{
        \\    .other = .{ .path = "../other" },
        \\    .z_ts = .{ .path = "../Z-Ts" },
        \\} }
    ;
    try testing.expectEqualStrings("../Z-Ts", dependencyPath(zon, ".z_ts").?);
    try testing.expect(dependencyPath(zon, ".zts") == null);
    try testing.expect(dependencyPath(zon, ".missing") == null);
}

test "executablePath adds .exe only for Windows targets" {
    const alloc = testing.allocator;
    const native = try executablePath(alloc, "demo", false);
    defer alloc.free(native);
    try testing.expectEqualStrings("zig-out/bin/demo", native);

    const cross = try executablePath(alloc, "demo", true);
    defer alloc.free(cross);
    try testing.expectEqualStrings("zig-out/bin/demo.exe", cross);

    try testing.expect(isWindowsTarget("x86_64-windows-gnu"));
    try testing.expect(!isWindowsTarget("aarch64-macos"));
    try testing.expect(!isWindowsTarget("x86_64-linux-gnu"));
}

test "mimeType covers the assets a front end actually ships" {
    try testing.expectEqualStrings("text/html; charset=utf-8", mimeType("index.html"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", mimeType("app.js"));
    try testing.expectEqualStrings("application/wasm", mimeType("app.wasm"));
    try testing.expectEqualStrings("font/woff2", mimeType("INTER.woff2"));
    try testing.expectEqualStrings("image/png", mimeType("logo.PNG"));
    try testing.expectEqualStrings("application/octet-stream", mimeType("archive.bin"));
    try testing.expectEqualStrings("application/octet-stream", mimeType("Makefile"));
}

test "assetPath maps URLs onto web/ and refuses to escape the root" {
    const alloc = testing.allocator;

    const root = (try assetPath(alloc, "/")).?;
    defer alloc.free(root);
    try testing.expectEqualStrings("index.html", root);

    const nested = (try assetPath(alloc, "/assets/app.css?v=3")).?;
    defer alloc.free(nested);
    try testing.expectEqualStrings("assets/app.css", nested);

    const dir = (try assetPath(alloc, "/docs/")).?;
    defer alloc.free(dir);
    try testing.expectEqualStrings("docs/index.html", dir);

    try testing.expect((try assetPath(alloc, "/../etc/passwd")) == null);
    try testing.expect((try assetPath(alloc, "/a/..\u{5c}b")) == null);
    try testing.expect((try assetPath(alloc, "C:/Windows/win.ini")) == null);

    try testing.expectEqualStrings("/a/b.html", stripQuery("/a/b.html?x=1#y"));
}

test "injectReload lands before </body> and survives a page without one" {
    const alloc = testing.allocator;

    const page = "<!doctype html><html><body><h1>hi</h1></body></html>";
    const with_script = try injectReload(alloc, page, 7);
    defer alloc.free(with_script);
    try testing.expect(std.mem.find(u8, with_script, "<script data-zts-dev>") != null);
    try testing.expect(std.mem.find(u8, with_script, "v=7") != null);
    // The original body content is still intact and the tag still closes the document.
    try testing.expect(std.mem.startsWith(u8, with_script, "<!doctype html><html><body><h1>hi</h1>"));
    try testing.expect(std.mem.endsWith(u8, with_script, "</body></html>"));

    const fragment = try injectReload(alloc, "<h1>hi</h1>", 0);
    defer alloc.free(fragment);
    try testing.expect(std.mem.startsWith(u8, fragment, "<h1>hi</h1><script data-zts-dev>"));
}

test "isHtml only claims markup" {
    try testing.expect(isHtml("index.html"));
    try testing.expect(isHtml("INDEX.HTM"));
    try testing.expect(!isHtml("app.js"));
    try testing.expect(!isHtml("index.html.gz"));
}

test "toPosix rewrites every native separator and leaves POSIX paths untouched" {
    const alloc = testing.allocator;

    const windows = try alloc.dupe(u8, "..\\..\\Z-Ts");
    defer alloc.free(windows);
    try testing.expectEqualStrings("../../Z-Ts", toPosix(windows));

    const posix = try alloc.dupe(u8, "../../Z-Ts");
    defer alloc.free(posix);
    try testing.expectEqualStrings("../../Z-Ts", toPosix(posix));

    const plain = try alloc.dupe(u8, ".");
    defer alloc.free(plain);
    try testing.expectEqualStrings(".", toPosix(plain));
}
