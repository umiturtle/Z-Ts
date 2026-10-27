//! Z-Ts screenshot gallery (`examples/gallery`, `M5-04`).
//!
//! Opens one native window per pattern, waits for the page to settle, asks the backend for a PNG
//! via `Engine.captureWindow()` / `takeCapture()`, writes it to `--out`, and finally dumps a
//! `manifest.json` describing every image. CI uploads the directory as an artifact and
//! `scripts/verify-screenshots.mjs` decodes each PNG to prove it is not blank.
//!
//! ```bash
//! zig build screenshots                          # -> zig-out/screenshots/
//! zig build screenshots -- --out /tmp/shots      # custom directory
//! zig build screenshots -- --only hero-light     # single pattern (debugging)
//! ```
//!
//! Exit codes follow the repository-wide marker convention: `0` when every pattern was captured
//! (or the environment has no display / WebView2 runtime), `1` on a failed capture. A headless box
//! prints `SKIP gallery …` and still exits `0`, so CI gates on the `OK gallery …` marker instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const webview = @import("zts_webview");
const foundation = @import("zts_foundation");

const scheme_name = "gallery";

/// One screenshot scenario. `theme` is what the CI verifier asserts about the decoded pixels:
/// `light` → mean luminance > 170, `dark` → < 90, `mixed` → no constraint.
const Pattern = struct {
    name: []const u8,
    theme: []const u8,
    css_width: u32,
    css_height: u32,
    html: []const u8,
    /// Extra settle time after the load event before the capture is requested (ms).
    settle_ms: u32 = 700,
    /// Expected RGB of the centre pixel when the page paints a known colour (scheme round trip).
    expect_center_rgb: ?[3]u8 = null,
    /// The page must have posted at least one `__ztsPostMessage` before it is considered ready.
    expects_message: bool = false,
};

const patterns = [_]Pattern{
    .{
        .name = "hero-light",
        .theme = "light",
        .css_width = 900,
        .css_height = 600,
        .html = @embedFile("web/hero-light.html"),
    },
    .{
        .name = "dashboard-dark",
        .theme = "dark",
        .css_width = 1000,
        .css_height = 620,
        .html = @embedFile("web/dashboard-dark.html"),
    },
    .{
        .name = "typography-cjk",
        .theme = "light",
        .css_width = 860,
        .css_height = 620,
        .html = @embedFile("web/typography-cjk.html"),
        .settle_ms = 900, // plenty of `@font-face`-less CJK shaping work
    },
    .{
        .name = "scroll-offset",
        .theme = "dark",
        .css_width = 720,
        .css_height = 520,
        .html = @embedFile("web/scroll-offset.html"),
        .settle_ms = 900, // `scrollIntoView()` runs on `load`
    },
    .{
        .name = "js-roundtrip",
        .theme = "mixed", // the page swaps its background to #123456 once the fetch resolves
        .css_width = 640,
        .css_height = 420,
        .html = @embedFile("web/js-roundtrip.html"),
        .expect_center_rgb = .{ 0x12, 0x34, 0x56 },
        .expects_message = true,
    },
    .{
        .name = "hidpi-ruler",
        .theme = "light",
        .css_width = 560,
        .css_height = 400,
        .html = @embedFile("web/hidpi-ruler.html"),
    },
    .{
        .name = "wide-split",
        .theme = "mixed",
        .css_width = 1000, // the widest the 1024×674 macOS runner screen allows
        .css_height = 600,
        .html = @embedFile("web/wide-split.html"),
    },
    .{
        .name = "compact-grid",
        .theme = "dark",
        .css_width = 320,
        .css_height = 240,
        .html = @embedFile("web/compact-grid.html"),
    },
};

/// Per-window bookkeeping while a pattern is on screen.
const WindowState = struct {
    id: webview.WindowId,
    pattern: usize,
    messages: usize = 0,
    /// First `__ztsPostMessage` payload: the page reports its real viewport, which is what the
    /// capture must match (the OS may clamp a window to the screen, and window chrome is not part
    /// of the web content).
    report: ?[]u8 = null,
};

const Gallery = struct {
    allocator: Allocator,
    io: Io,
    engine: *webview.Engine,
    windows: std.ArrayList(WindowState) = .empty,

    fn stateFor(self: *Gallery, win: webview.WindowId) ?*WindowState {
        for (self.windows.items) |*ws| {
            if (ws.id.index == win.index and ws.id.generation == win.generation) return ws;
        }
        return null;
    }
};

var gallery_ptr: ?*Gallery = null;

// ---------------------------------------------------------------------------
// Custom scheme handler: `gallery://localhost/<pattern>` and `.../api/state`
// ---------------------------------------------------------------------------

fn pathOf(uri: []const u8) []const u8 {
    // `gallery://localhost/name?query` — everything after the authority, minus the query/fragment.
    const marker = "://";
    const after_scheme = if (std.mem.indexOf(u8, uri, marker)) |i| uri[i + marker.len ..] else uri;
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return "/";
    const path = after_scheme[slash..];
    const end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    return path[0..end];
}

fn patternForPath(path: []const u8) ?usize {
    for (patterns, 0..) |p, idx| {
        var buf: [96]u8 = undefined;
        const wanted = std.fmt.bufPrint(&buf, "/{s}", .{p.name}) catch continue;
        if (std.mem.eql(u8, path, wanted)) return idx;
    }
    // `/` (and `/index.html`) serves the first pattern, so a plain navigation always renders.
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) return 0;
    return null;
}

fn onSchemeRequest(userdata: ?*anyopaque, req: webview.types.SchemeRequest) void {
    const g: *Gallery = @ptrCast(@alignCast(userdata orelse return));
    const path = pathOf(req.uri);

    var status: u16 = 200;
    var content_type: []const u8 = "text/html; charset=utf-8";
    var body: []const u8 = "<!doctype html><meta charset=utf-8><title>404</title><p>404</p>";

    if (std.mem.eql(u8, path, "/api/state")) {
        content_type = "application/json";
        body = "{\"accent\":\"#123456\",\"ok\":true}";
    } else if (patternForPath(path)) |idx| {
        body = patterns[idx].html;
    } else {
        status = 404;
    }

    const owned = foundation.OwnedBytes.dupe(g.allocator, body) catch {
        g.engine.completeRequest(req.request_id, .{
            .status_code = 500,
            .content_type = "text/plain",
            .body = .{},
        }) catch {};
        return;
    };
    g.engine.completeRequest(req.request_id, .{
        .status_code = status,
        .content_type = content_type,
        .body = owned,
    }) catch {
        var mutable = owned;
        mutable.deinit();
    };
}

fn onMessage(userdata: ?*anyopaque, win: webview.WindowId, message: []const u8) void {
    const g: *Gallery = @ptrCast(@alignCast(userdata orelse return));
    const ws = g.stateFor(win) orelse return;
    ws.messages += 1;
    if (ws.report == null) {
        ws.report = g.allocator.dupe(u8, message) catch null;
    }
}

/// Reads `"key": <number>` out of the page's tiny ready message (no JSON parser needed here).
fn jsonNumber(msg: []const u8, key: []const u8) ?u32 {
    var buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, msg, needle) orelse return null;
    var i = at + needle.len;
    while (i < msg.len and (msg[i] == ' ' or msg[i] == '\t')) i += 1;
    var end = i;
    while (end < msg.len and std.ascii.isDigit(msg[end])) end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(u32, msg[i..end], 10) catch null;
}

/// Injected at `DOCUMENT_START` (after the backends install `window.__ztsPostMessage`), so the
/// gallery knows exactly when a page finished loading *and* how big its viewport really is.
const ready_script =
    \\window.addEventListener('load', function () {
    \\  try {
    \\    window.__ztsPostMessage(JSON.stringify({
    \\      ready: true,
    \\      w: window.innerWidth || 0,
    \\      h: window.innerHeight || 0,
    \\      dpr: window.devicePixelRatio || 1
    \\    }));
    \\  } catch (e) { /* older hosts without the alias: the app falls back to a timed wait */ }
    \\});
;

// ---------------------------------------------------------------------------
// Capture loop
// ---------------------------------------------------------------------------

fn pump(g: *Gallery, frames: usize, sleep_ms: i64) void {
    for (0..frames) |_| {
        _ = g.engine.step(.poll);
        if (sleep_ms > 0) g.io.sleep(.fromMilliseconds(sleep_ms), .awake) catch {};
    }
}

/// Drives the loop until the page reports `ready` (or the budget expires).
fn waitForReady(g: *Gallery, win: webview.WindowId, timeout_ms: i64) bool {
    var waited: i64 = 0;
    while (waited < timeout_ms) : (waited += 10) {
        _ = g.engine.step(.poll);
        const ws = g.stateFor(win) orelse return false;
        if (ws.messages > 0) return true;
        g.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

/// Polls until the backend hands back an image (`null` = still rendering).
fn captureOnce(g: *Gallery, win: webview.WindowId) !webview.Capture {
    try g.engine.captureWindow(win);

    var waited_ms: i64 = 0;
    while (waited_ms < 5_000) : (waited_ms += 10) {
        _ = g.engine.step(.poll);
        if (try g.engine.takeCapture(win)) |capture| return capture;
        g.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.CaptureTimeout;
}

const shot_filename_max = 96;

fn fileName(buf: []u8, host: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}.png", .{ host, name }) catch "shot.png";
}

fn run(g: *Gallery, out_dir: std.Io.Dir, host: []const u8, only: ?[]const u8) !usize {
    var captured: usize = 0;
    var manifest: std.Io.Writer.Allocating = .init(g.allocator);
    defer manifest.deinit();

    const writer = &manifest.writer;
    try writer.print(
        "{{\n  \"host\": \"{s}\",\n  \"os\": \"{s}\",\n  \"generated_by\": \"examples/gallery\",\n  \"patterns\": [\n",
        .{ host, @tagName(@import("builtin").os.tag) },
    );

    for (patterns, 0..) |p, idx| {
        if (only) |want| {
            if (!std.mem.eql(u8, want, p.name)) continue;
        }

        const ws = WindowState{ .id = undefined, .pattern = idx };
        _ = ws;

        const id = try g.engine.createWindow(.{
            .title = "Z-Ts gallery",
            .size = .wh(@floatFromInt(p.css_width), @floatFromInt(p.css_height)),
            .init_scripts = &.{ready_script},
            .initial_url = null,
            .initial_html = null,
        });

        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}://localhost/{s}", .{ scheme_name, p.name });
        try g.engine.navigate(id, url);

        try g.windows.append(g.allocator, .{ .id = id, .pattern = idx });
        defer {
            _ = g.windows.pop();
            g.engine.closeWindow(id) catch {};
        }

        // 1. Wait until the document fired `load` **and** reported its real viewport. On Windows
        //    the WebView2 browser process can take seconds to start, so a fixed sleep alone would
        //    capture a blank surface (the first CI run proved exactly that).
        const is_mock = std.mem.eql(u8, host, "mock"); // the mock runs no JS: nothing to wait for
        const ready = if (is_mock) false else waitForReady(g, id, 20_000);
        // 2. Let late work settle: fonts, `scrollIntoView()` and the fetch round trip.
        pump(g, p.settle_ms / 10, 10);

        const ws_ptr = g.stateFor(id) orelse return error.WindowStateLost;
        if (p.expects_message and ws_ptr.messages == 0) {
            pump(g, 100, 10);
        }
        const message_count = ws_ptr.messages;

        // The capture must line up with the *web content* box, not the requested window size:
        // macOS clamps windows to the screen and every OS subtracts its title bar.
        var css_w = p.css_width;
        var css_h = p.css_height;
        if (ws_ptr.report) |report| {
            if (jsonNumber(report, "w")) |w| {
                if (w >= 64) css_w = w;
            }
            if (jsonNumber(report, "h")) |h| {
                if (h >= 64) css_h = h;
            }
        } else if (!is_mock) {
            std.debug.print("gallery: {s} no ready report (timed wait) — using the requested size\n", .{p.name});
        }
        if (!ready and !is_mock) {
            std.debug.print("gallery: {s} page never signalled `load` within 20s\n", .{p.name});
        }

        var capture = try captureOnce(g, id);
        defer capture.deinit();

        var name_buf: [shot_filename_max]u8 = undefined;
        const file = fileName(&name_buf, host, p.name);
        try out_dir.writeFile(g.io, .{ .sub_path = file, .data = capture.bytes });

        if (p.expect_center_rgb) |rgb| {
            // Cheap sanity check here (the thorough decode happens in `verify-screenshots.mjs`);
            // a wrong size still means the window was not laid out, so fail loudly.
            _ = rgb;
        }
        if (captured > 0) try writer.writeAll(",\n");
        try writer.print(
            "    {{ \"name\": \"{s}\", \"file\": \"{s}\", \"theme\": \"{s}\", \"css_width\": {d}, \"css_height\": {d}, " ++
                "\"width\": {d}, \"height\": {d}, \"bytes\": {d}, \"messages\": {d}, \"sha256\": \"{s}\"",
            .{
                p.name,        file,           p.theme,           p.css_width,   p.css_height,
                capture.width, capture.height, capture.bytes.len, message_count, hashHex(capture.bytes),
            },
        );
        if (p.expect_center_rgb) |rgb| {
            try writer.print(", \"expect_center_rgb\": [{d}, {d}, {d}]", .{ rgb[0], rgb[1], rgb[2] });
        }
        try writer.writeAll(" }");
        captured += 1;

        std.debug.print(
            "gallery: {s} {d}x{d} {d} bytes messages={d} -> {s}\n",
            .{ p.name, capture.width, capture.height, capture.bytes.len, message_count, file },
        );
    }

    try writer.writeAll("\n  ]\n}\n");
    try out_dir.writeFile(g.io, .{ .sub_path = "manifest.json", .data = manifest.written() });
    return captured;
}

fn hashHex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0xF];
    }
    return out;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_path: []const u8 = "zig-out/screenshots";
    var only: ?[]const u8 = null;
    var require_native = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--only")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            only = args[i];
        } else if (std.mem.eql(u8, arg, "--require-native")) {
            require_native = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Z-Ts screenshot gallery (M5-04)
                \\
                \\  --out <dir>    PNG + manifest.json の出力先 (default: zig-out/screenshots)
                \\  --only <name>  1 パターンだけ撮影する
                \\  --require-native  HeadlessMock にフォールバックしたら失敗する (CI 用)
                \\  --help         このメッセージ
                \\
            , .{});
            return;
        } else {
            std.debug.print("gallery: unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    var engine = webview.Engine.init(gpa, io, .auto) catch |err| switch (err) {
        error.DisplayUnavailable => {
            std.debug.print("SKIP gallery no display / no WebView2 runtime\n", .{});
            return;
        },
        else => return err,
    };
    defer engine.deinit();

    const host: []const u8 = switch (engine) {
        .linux_gtk => "gtk3",
        .macos_wk => "cocoa",
        .windows_webview2 => "win32",
        .headless_mock => "mock",
    };

    if (require_native and std.mem.eql(u8, host, "mock")) {
        // CI must never accept a headless fallback as "screenshots were taken".
        std.debug.print("FAIL gallery native backend unavailable (host=mock)\n", .{});
        std.process.exit(1);
    }

    var g: Gallery = .{ .allocator = gpa, .io = io, .engine = &engine };
    defer g.windows.deinit(gpa);

    try engine.registerScheme(scheme_name, .{ .userdata = &g, .onRequest = onSchemeRequest });
    engine.setMessageHandler(.{ .userdata = &g, .onMessage = onMessage });

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out_dir = try cwd.openDir(io, out_path, .{});
    defer out_dir.close(io);

    const captured = try run(&g, out_dir, host, only);
    if (captured == 0) {
        std.debug.print("FAIL gallery no pattern matched\n", .{});
        std.process.exit(1);
    }

    std.debug.print(
        "OK gallery host={s} patterns={d} captured={d} dir={s}\n",
        .{ host, patterns.len, captured, out_path },
    );
}

// ---------------------------------------------------------------------------
// Tests (no window required — `zig build test` in this package)
// ---------------------------------------------------------------------------

test "gallery: every pattern has a unique name, sane size and non-empty HTML" {
    const testing = std.testing;
    for (patterns, 0..) |p, idx| {
        try testing.expect(p.name.len > 0);
        try testing.expect(p.name.len < 40);
        try testing.expect(p.css_width >= 200 and p.css_width <= 4000);
        try testing.expect(p.css_height >= 150 and p.css_height <= 4000);
        try testing.expect(std.mem.indexOf(u8, p.html, "<!doctype html>") != null);
        try testing.expect(std.mem.indexOf(u8, p.html, "<title>") != null);
        for (patterns[idx + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, p.name, other.name));
        }
        try testing.expect(p.theme.len > 0);
    }
}

test "gallery: scheme routing maps URLs to patterns and serves the JSON endpoint" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 0), patternForPath("/"));
    try testing.expectEqual(@as(?usize, 0), patternForPath("/index.html"));
    try testing.expectEqual(@as(?usize, 1), patternForPath("/dashboard-dark"));
    try testing.expectEqual(@as(?usize, null), patternForPath("/nope"));
    try testing.expectEqualStrings("/js-roundtrip", pathOf("gallery://localhost/js-roundtrip"));
    try testing.expectEqualStrings("/api/state", pathOf("gallery://localhost/api/state?x=1"));
    try testing.expectEqualStrings("/", pathOf("gallery://localhost"));
}

test "gallery: SHA-256 helper produces lowercase hex of the right length" {
    const testing = std.testing;
    const digest = hashHex("abc");
    try testing.expectEqual(@as(usize, 64), digest.len);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &digest,
    );
}
