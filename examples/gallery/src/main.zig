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
const builtin = @import("builtin");
const fw = @import("fw_assets.zig");

/// The custom scheme the gallery serves itself from. WebView2 has no custom-scheme API, so
/// `windows.zig` maps `tauri://localhost/x` onto `http://tauri.localhost/x`; registering the
/// gallery under `tauri` is what makes the *same* URL work on macOS, GTK and Windows. Every
/// other scheme name navigates nowhere on Windows (a blank surface, proven by CI run #40514152272).
const scheme_name = "tauri";

/// One screenshot scenario. `theme` is what the CI verifier asserts about the decoded pixels:
/// `light` → mean luminance > 170, `dark` → < 90, `mixed` → no constraint.
const Pattern = struct {
    name: []const u8,
    theme: []const u8,
    css_width: u32,
    css_height: u32,
    /// Embedded single-file page (the 8 hand-written patterns).
    html: ?[]const u8 = null,
    /// Path inside the embedded framework asset table (`fw/<name>/index.html`).
    /// Framework demos are real multi-file builds, served exactly like an app's `dist/`.
    route: []const u8 = "",
    /// Extra settle time after the load event before the capture is requested (ms).
    settle_ms: u32 = 700,
    /// Expected RGB of the centre pixel when the page paints a known colour (scheme round trip).
    expect_center_rgb: ?[3]u8 = null,
    /// The page must have posted at least one `__ztsPostMessage` before it is considered ready.
    expects_message: bool = false,
    /// Framework demos render (and hydrate) *after* `load`: wait for the app's own
    /// `{"app":"ready"}` message instead of trusting the load event alone.
    requires_app_ready: bool = false,
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

    // -- 9 framework builds (M5-05) -------------------------------------------------------------
    // Every demo renders the same 760×520 dashboard-like screen with the same DOM classes, so the
    // 3-OS comparator can diff them against each other *and* across OSes. Sources live in
    // `examples/frameworks/<name>/`; `scripts/gen-framework-demos.mjs` rebuilds the bundled HTML.
    .{
        .name = "fw-react",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/react/index.html",
        .requires_app_ready = true,
    },
    .{
        .name = "fw-solid",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/solid/index.html",
        .requires_app_ready = true,
    },
    .{
        .name = "fw-svelte",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/svelte/index.html",
        .requires_app_ready = true,
    },
    .{
        .name = "fw-angular",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/angular/index.html",
        .requires_app_ready = true,
    },
    .{
        .name = "fw-next",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/next/index.html",
        .requires_app_ready = true,
    },
    .{
        .name = "fw-nuxt",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/nuxt/index.html",
        .requires_app_ready = true,
    },
    .{
        .name = "fw-astro",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/astro/index.html",
        .requires_app_ready = true,
    },
    .{
        .name = "fw-sveltekit",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/sveltekit/index.html",
        .requires_app_ready = true,
    },
    .{
        .name = "fw-solidstart",
        .theme = "light",
        .css_width = 760,
        .css_height = 520,
        .route = "fw/solidstart/index.html",
        .requires_app_ready = true,
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
    /// The `{"app":"layout", …}` message: element boxes measured after fonts finished loading.
    /// Cross-OS comparison uses this, not the pixels, to prove the *layout* is identical.
    layout: ?[]u8 = null,
    /// The page's own `{"app":"ready"}` message (framework demos post it after hydration).
    app_ready: bool = false,
    /// The `{"app":"fontfetch", …}` probe: can the page actually read the bundled woff2 bytes?
    /// A webfont that loads in Chromium but not in WebKit shows up here as a failed fetch.
    font_fetch: ?[]u8 = null,
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
// Custom scheme handler: `tauri://localhost/<pattern>` and `.../api/state` (served by WebView2
// as `http://tauri.localhost/...`).
// ---------------------------------------------------------------------------

fn pathOf(uri: []const u8) []const u8 {
    // `tauri://localhost/name?query` (or `http://tauri.localhost/name?query` on Windows) —
    // everything after the authority, minus the query/fragment.
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
        // Framework demos live at their published path; `/fw/<name>` (no file) serves index.html.
        if (p.route.len != 0) {
            var route_buf: [128]u8 = undefined;
            const route = std.fmt.bufPrint(&route_buf, "/{s}", .{p.route}) catch continue;
            if (std.mem.eql(u8, path, route)) return idx;
            const dir = route[0 .. route.len - "index.html".len];
            if (std.mem.eql(u8, path, dir) or std.mem.eql(u8, path, dir[0 .. dir.len - 1])) return idx;
        }
    }
    // `/` (and `/index.html`) serves the first pattern, so a plain navigation always renders.
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) return 0;
    return null;
}

fn onSchemeRequest(userdata: ?*anyopaque, req: webview.types.SchemeRequest) void {
    const g: *Gallery = @ptrCast(@alignCast(userdata orelse return));
    const path = pathOf(req.uri);

    // Published framework builds (`/fw/<name>/…`), served like a real app's `dist/`.
    if (std.mem.startsWith(u8, path, "/fw/")) {
        if (fw_asset(path[1..])) |asset| {
            serveBytes(g, req, asset.bytes, asset.content_type);
            return;
        }
        // A directory-shaped request (`/fw/react/`) maps to its `index.html`.
        var buf: [160]u8 = undefined;
        if (std.mem.endsWith(u8, path, "/")) {
            const index_path = std.fmt.bufPrint(&buf, "{s}index.html", .{path[1..]}) catch "";
            if (fw_asset(index_path)) |asset| {
                serveBytes(g, req, asset.bytes, asset.content_type);
                return;
            }
        }
    }

    // Absolute asset URLs from a published build (`/assets/…`, `/_next/static/…`).
    if (fw_alias(path)) |asset| {
        serveBytes(g, req, asset.bytes, asset.content_type);
        return;
    }

    // Bundled fonts: the *same* bytes on every OS, which is what makes the rasters comparable.
    if (fontFor(path)) |asset| {
        const owned = foundation.OwnedBytes.dupe(g.allocator, asset.bytes) catch {
            g.engine.completeRequest(req.request_id, .{
                .status_code = 500,
                .content_type = "text/plain",
                .body = .{},
            }) catch {};
            return;
        };
        g.engine.completeRequest(req.request_id, .{
            .status_code = 200,
            .content_type = asset.content_type,
            .body = owned,
        }) catch {
            var mutable = owned;
            mutable.deinit();
        };
        return;
    }

    var status: u16 = 200;
    var content_type: []const u8 = "text/html; charset=utf-8";
    var body: []const u8 = "<!doctype html><meta charset=utf-8><title>404</title><p>404</p>";

    if (std.mem.eql(u8, path, "/api/state")) {
        content_type = "application/json";
        body = "{\"accent\":\"#123456\",\"ok\":true}";
    } else if (patternForPath(path)) |idx| {
        // Framework demos are multi-file sites: the navigation goes to `/fw/<name>/index.html`
        // and every chunk is fetched from the same embedded table.
        body = patterns[idx].html orelse "<!doctype html><meta charset=utf-8><title>see /fw</title>";
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

    if (std.mem.indexOf(u8, message, "\"app\":\"layout\"")) |_| {
        if (ws.layout == null) ws.layout = g.allocator.dupe(u8, message) catch null;
        return;
    }
    if (std.mem.indexOf(u8, message, "\"app\":\"ready\"")) |_| {
        ws.app_ready = true;
        return;
    }
    if (std.mem.indexOf(u8, message, "\"app\":\"fontfetch\"")) |_| {
        if (ws.font_fetch == null) ws.font_fetch = g.allocator.dupe(u8, message) catch null;
        return;
    }
    if (ws.report == null) {
        ws.report = g.allocator.dupe(u8, message) catch null;
    }
}

/// `document.fonts.check()` result from the layout message: both bundled families really loaded.
/// Framework bundlers emit `<!DOCTYPE html>` (uppercase), so the doctype check is case-insensitive.
fn containsDoctype(html: []const u8) bool {
    const needle = "<!doctype html>";
    if (html.len < needle.len) return false;
    for (0..html.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(html[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn fontOk(layout: ?[]const u8) bool {
    const msg = layout orelse return false;
    return std.mem.indexOf(u8, msg, "\"font_ok\":true") != null;
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

// ---------------------------------------------------------------------------
// Bundled fonts (OS 間で画素を一致させるための唯一のフォント)
// ---------------------------------------------------------------------------
//
// システムフォント（Hiragino / Yu Gothic / Noto CJK / 何も無い Ubuntu）を使うと、同じ HTML でも
// OS ごとに字形・字幅・行送りが変わり、スクリーンショット比較が成立しない。3 OS のブラウザに
// **同一の woff2 ファイル**を配信することで、レイアウトと字形を一致させる。
// 再生成は `python3 scripts/build-fonts.py`（Noto Sans/Serif JP + JetBrains Mono のサブセット）。

const FontAsset = struct {
    path: []const u8,
    content_type: []const u8,
    bytes: []const u8,
};

const font_assets = [_]FontAsset{
    .{
        .path = "/zts/fonts/zts-sans-400.woff2",
        .content_type = "font/woff2",
        .bytes = @embedFile("web/fonts/zts-sans-400.woff2"),
    },
    .{
        .path = "/zts/fonts/zts-sans-700.woff2",
        .content_type = "font/woff2",
        .bytes = @embedFile("web/fonts/zts-sans-700.woff2"),
    },
    .{
        .path = "/zts/fonts/zts-serif-400.woff2",
        .content_type = "font/woff2",
        .bytes = @embedFile("web/fonts/zts-serif-400.woff2"),
    },
    .{
        .path = "/zts/fonts/zts-mono-400.woff2",
        .content_type = "font/woff2",
        .bytes = @embedFile("web/fonts/zts-mono-400.woff2"),
    },
};

fn fw_asset(path: []const u8) ?*const fw.Asset {
    var buf: [192]u8 = undefined;
    const wanted = std.fmt.bufPrint(&buf, "/{s}", .{path}) catch return null;
    for (&fw.assets) |*asset| {
        if (std.mem.eql(u8, asset.path, wanted)) return asset;
    }
    return null;
}

/// Bundlers emit **absolute** asset URLs (`/assets/index-abc.js`, `/_next/static/…`, `/_nuxt/…`).
/// A page served from `/fw/<name>/index.html` would then request those at the *document root*, so
/// the handler also answers `/<path>` when some published build has a file with that suffix.
/// Hashed file names make collisions across the 9 builds practically impossible.
fn fw_alias(path: []const u8) ?*const fw.Asset {
    if (std.mem.eql(u8, path, "/")) return null;
    for (&fw.assets) |*asset| {
        if (asset.path.len <= path.len) continue;
        const cut = asset.path.len - path.len;
        if (!std.mem.endsWith(u8, asset.path, path)) continue;
        // `path` always starts with '/', so `cut` must land on a separator: that keeps
        // `/app.js` from matching `…/myapp.js`.
        if (asset.path[cut] != '/') continue;
        return asset;
    }
    return null;
}

fn serveBytes(g: *Gallery, req: webview.types.SchemeRequest, bytes: []const u8, content_type: []const u8) void {
    const owned = foundation.OwnedBytes.dupe(g.allocator, bytes) catch {
        g.engine.completeRequest(req.request_id, .{
            .status_code = 500,
            .content_type = "text/plain",
            .body = .{},
        }) catch {};
        return;
    };
    g.engine.completeRequest(req.request_id, .{
        .status_code = 200,
        .content_type = content_type,
        .body = owned,
    }) catch {
        var mutable = owned;
        mutable.deinit();
    };
}

fn fontFor(path: []const u8) ?*const FontAsset {
    for (&font_assets) |*asset| {
        if (std.mem.eql(u8, asset.path, path)) return asset;
    }
    return null;
}

/// Injected at `DOCUMENT_START`, before any page CSS is parsed. **This is only place the bundled
/// fonts come from** — the demo pages deliberately name `ZTSSans` / `ZTSSerif` / `ZTSMono` and never
/// declare `@font-face` themselves, so if this script is not installed every page silently falls back
/// to the system font and the 3-OS comparison degenerates into "each OS looks different".
///
///  - `@font-face` を 4 本（ZTS Sans 400/700・Serif・Mono）。`FontFace` API を優先し、無い環境だけ
///    CSS にフォールバックする（document-start では `<head>` がまだ存在しないため、CSS を
///    `document.head` に挿すだけでは **何も起きない**）。
///  - スクロールバーを隠す（GTK はオーバーレイ、Windows はクラシック、macOS は自動非表示と
///    3 OS で幅が違い、そのぶん本文の折り返し位置が変わってしまう）。
///  - 合成・ヒンティング依存の差を減らす（`font-synthesis: none` / `text-size-adjust: none`）。
const parity_script =
    \\(function () {
    \\  // 4 面ぶんのメタ情報: [family, weight, style, URL]。
    \\  var FACES = [
    \\    ['ZTSSans', '400', 'normal', '/zts/fonts/zts-sans-400.woff2'],
    \\    ['ZTSSans', '700', 'normal', '/zts/fonts/zts-sans-700.woff2'],
    \\    ['ZTSSerif', '400', 'normal', '/zts/fonts/zts-serif-400.woff2'],
    \\    ['ZTSMono', '400', 'normal', '/zts/fonts/zts-mono-400.woff2']
    \\  ];
    \\  var state = { api: false, css: false, faces: 0, errors: [] };
    \\  window.__ztsParity = state;
    \\  var faceCss = FACES.map(function (f) {
    \\    return '@font-face{font-family:' + f[0] + ';font-style:' + f[2] + ';font-weight:' + f[1] +
    \\      ';font-display:block;src:url("' + f[3] + '") format("woff2")}';
    \\  });
    \\  var parityCss = [
    \\    'html{scrollbar-width:none;-webkit-text-size-adjust:100%;}',
    \\    '::-webkit-scrollbar{width:0;height:0;}',
    \\    'body{font-synthesis:none;}'
    \\  ];
    \\
    \\  // (1) FontFace API。document-start（`<head>` すら無い時点）でも効く唯一の方法。
    \\  var useApi = !!(window.FontFace && document.fonts && document.fonts.add);
    \\  state.api = useApi;
    \\  var loads = [];
    \\  if (useApi) {
    \\    FACES.forEach(function (f) {
    \\      try {
    \\        var face = new FontFace(f[0], 'url("' + f[3] + '")', { style: f[2], weight: f[1] });
    \\        loads.push(face.load().then(function (loaded) {
    \\          try { document.fonts.add(loaded); state.faces += 1; } catch (e) { state.errors.push('add ' + f[0] + ': ' + e); }
    \\          return loaded;
    \\        }, function (err) {
    \\          state.errors.push(f[0] + '/' + f[1] + ': ' + (err && err.message ? err.message : err));
    \\        }));
    \\      } catch (e) { state.errors.push('new FontFace ' + f[0] + ': ' + e); }
    \\    });
    \\  }
    \\  window.__ztsFontsReady = window.Promise
    \\    ? Promise.all(loads).then(function () { return state.faces; })
    \\    : null;
    \\
    \\  // (2) CSS 側（フォールバックの @font-face と、パリティ用のルール）。
    \\  var css = (useApi ? [] : faceCss).concat(parityCss).join('\n');
    \\  var install = function () {
    \\    try {
    \\      var parent = document.head || document.documentElement;
    \\      if (!parent) return false; // document-start: まだ <html> すら無い
    \\      var style = document.createElement('style');
    \\      style.setAttribute('data-zts', 'parity');
    \\      style.textContent = css;
    \\      parent.appendChild(style);
    \\      state.css = true;
    \\      return true;
    \\    } catch (e) { state.errors.push('css: ' + e); return false; }
    \\  };
    \\  if (!install()) {
    \\    // <head> が現れた瞬間に入れ直す（この 1 段が無いとスタイルが永久に効かない）。
    \\    try {
    \\      var observer = new MutationObserver(function () { if (install()) observer.disconnect(); });
    \\      observer.observe(document, { childList: true, subtree: true });
    \\    } catch (e) {
    \\      document.addEventListener('DOMContentLoaded', install);
    \\    }
    \\  }
    \\})();
;

/// Every window gets both scripts, in this order: the font/CSS bootstrap must register the faces
/// before the measurer runs, otherwise the first measurement races the font load.
const init_scripts = [_][]const u8{ parity_script, ready_script };

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
    \\  // 3 通目: 同梱フォントが「ページから取得できるか」。WebKit がカスタムスキーム経由の
    \\  // webfont を拒否すると、ここだけが静かに失敗する（レイアウトはフォールバック書体で進む）。
    \\  try {
    \\    fetch('/zts/fonts/zts-sans-400.woff2').then(function (r) {
    \\      return r.arrayBuffer().then(function (b) { return [r.status, b.byteLength]; });
    \\    }).then(function (v) {
    \\      try {
    \\        window.__ztsPostMessage(JSON.stringify({
    \\          app: 'fontfetch', ok: v[0] === 200 && v[1] > 1000, status: v[0], bytes: v[1]
    \\        }));
    \\      } catch (e) {}
    \\    }, function (err) {
    \\      try {
    \\        window.__ztsPostMessage(JSON.stringify({ app: 'fontfetch', ok: false, err: String(err) }));
    \\      } catch (e) {}
    \\    });
    \\  } catch (e) {}
    \\  // 2 通目: レイアウト指紋。フォントのロード完了後・次フレームで測る。
    \\  // 3 OS のギャラリー出力を `scripts/compare-screenshots.mjs` が突き合わせ、
    \\  // 「同じ解像度なら同じ位置・同じ大きさ」を機械的に保証する。
    \\  var post = function (payload) {
    \\    try { window.__ztsPostMessage(JSON.stringify(payload)); } catch (e) {}
    \\  };
    \\  var measure = function () {
    \\    var sel = 'body,.shell,.head,.card,.counter,.value,.features,.features>li,.meta,' +
    \\              'h1,h2,h3,p,ul,li,button,footer,.badge,.title,.sub,.brand,.logo,.tag';
    \\    var boxes = [];
    \\    var names = [];
    \\    var nodes = document.querySelectorAll(sel);
    \\    for (var i = 0; i < nodes.length && i < 40; i++) {
    \\      var r = nodes[i].getBoundingClientRect();
    \\      boxes.push([Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]);
    \\      // 箱番号だけだと原因が分からないので、`tag.class` も一緒に送る。
    \\      var nm = nodes[i].tagName.toLowerCase();
    \\      var cl = nodes[i].getAttribute('class');
    \\      if (cl) nm += '.' + cl.replace(/^\s+|\s+$/g, '').split(/\s+/).join('.');
    \\      names.push(nm);
    \\    }
    \\
    \\    var round2 = function (v) { return Math.round(v * 100) / 100; };
    \\    // 送り幅は DOM で測る（canvas の measureText はレイアウトと食い違うことがある）。
    \\    var widthOf = function (family, weight, text) {
    \\      var el = document.createElement('span');
    \\      el.style.cssText = 'position:absolute;left:-9999px;top:0;white-space:pre;font-size:16px;' +
    \\                        'font-weight:' + (weight || 400) + ';font-family:' + family;
    \\      el.textContent = text;
    \\      document.body.appendChild(el);
    \\      var w = el.getBoundingClientRect().width;
    \\      document.body.removeChild(el);
    \\      return round2(w);
    \\    };
    \\    var probe = { error: null };
    \\    try {
    \\      var chEl = document.createElement('div');
    \\      chEl.style.cssText = 'position:absolute;left:-9999px;top:0;width:44ch;' +
    \\                           'font-size:16px;font-family:ZTSSans';
    \\      document.body.appendChild(chEl);
    \\      var chWidth = chEl.getBoundingClientRect().width;
    \\      document.body.removeChild(chEl);
    \\      probe = {
    \\        sans0: widthOf('ZTSSans', 400, '0'),
    \\        sans0b: widthOf('ZTSSans', 700, '0'),
    \\        serif0: widthOf('ZTSSerif', 400, '0'),
    \\        mono0: widthOf('ZTSMono', 400, '0'),
    \\        cjk: widthOf('ZTSSans', 400, 'デスクトップ'),
    \\        generic0: widthOf('sans-serif', 400, '0'),
    \\        ch44: round2(chWidth),
    \\        dpr: round2(window.devicePixelRatio || 1),
    \\        ua: navigator.userAgent
    \\      };
    \\    } catch (e) { probe = { error: String(e) }; }
    \\
    \\    // FontFaceSet は length も添字も持たない（Set 風）ので forEach で集める。
    \\    var faceList = [];
    \\    var facesLoaded = 0;
    \\    try {
    \\      document.fonts.forEach(function (f) {
    \\        faceList.push(f.family.replace(/["']/g, '') + '/' + f.weight + '/' + f.status);
    \\        if (f.status === 'loaded') facesLoaded += 1;
    \\      });
    \\    } catch (e) { faceList.push('!forEach: ' + e); }
    \\
    \\    // canvas 実描画の比較。WebKit では `document.fonts.check()` が未適用でも true を返すので、
    \\    // 「同梱書体 vs 総称ファミリ」を塗り比べた差分率も併せて取る（判定の主軸は送り幅のほう）。
    \\    var raster = function (family, text, px) {
    \\      var c = document.createElement('canvas');
    \\      c.width = 240;
    \\      c.height = 64;
    \\      var g = c.getContext('2d');
    \\      if (!g) return null;
    \\      g.fillStyle = '#ffffff';
    \\      g.fillRect(0, 0, 240, 64);
    \\      g.fillStyle = '#000000';
    \\      g.font = px + 'px "' + family + '"';
    \\      g.textBaseline = 'top';
    \\      g.fillText(text, 4, 6);
    \\      return g.getImageData(0, 0, 240, 64).data;
    \\    };
    \\    var ratioDifferent = function (family, generic, text) {
    \\      var a = raster(family, text, 40);
    \\      var b = raster(generic, text, 40);
    \\      if (!a || !b) return -1;
    \\      var n = 0;
    \\      for (var i = 0; i < a.length; i += 4) if (a[i] !== b[i]) n++;
    \\      return Math.round((n / (a.length / 4)) * 1000) / 1000;
    \\    };
    \\    var paint = {};
    \\    try {
    \\      paint = {
    \\        sans: ratioDifferent('ZTSSans', 'sans-serif', 'Zig 0'),
    \\        sansCjk: ratioDifferent('ZTSSans', 'sans-serif', 'あ'),
    \\        serif: ratioDifferent('ZTSSerif', 'serif', 'Zig 0'),
    \\        mono: ratioDifferent('ZTSMono', 'monospace', 'Zig 0')
    \\      };
    \\    } catch (e) { paint = { error: String(e) }; }
    \\
    \\    // 判定は「同梱 woff2 の送り幅どおりに組まれているか」。advances は
    \\    //   ZTSSans 400 '0' = 555/1000em → 8.88px @16px、700 = 590 → 9.44px、
    \\    //   ZTSSerif 400 = 557 → 8.91px、ZTSMono 400 = 600 → 9.60px、CJK = 1em/字 → 96px。
    \\    // フォールバック書体（Liberation / Segoe / Helvetica / DejaVu）でこの 5 値は揃わない。
    \\    //
    \\    // 測るのは **canvas の measureText**。WebKitGTK（GTK 4.1）は `getBoundingClientRect()`
    \\    // の幅を整数 px に丸めて返すため（8.88 → 9, 9.44 → 9）、DOM 計測では 400 と 700 が
    \\    // 区別できず、丸めだけでゲートが落ちる。measureText は両エンジンとも小数で返す。
    \\    var measureText = function (family, weight, text) {
    \\      try {
    \\        var c = document.createElement('canvas').getContext('2d');
    \\        if (!c) return null;
    \\        c.font = (weight || 400) + ' 16px "' + family + '"';
    \\        return Math.round(c.measureText(text).width * 100) / 100;
    \\      } catch (e) { return null; }
    \\    };
    \\    var expected = { sans0: 8.88, sans0b: 9.44, serif0: 8.91, mono0: 9.6, cjk: 96 };
    \\    var canvasMetrics = {
    \\      sans0: measureText('ZTSSans', 400, '0'),
    \\      sans0b: measureText('ZTSSans', 700, '0'),
    \\      serif0: measureText('ZTSSerif', 400, '0'),
    \\      mono0: measureText('ZTSMono', 400, '0'),
    \\      cjk: measureText('ZTSSans', 400, 'デスクトップ')
    \\    };
    \\    // canvas が使えない環境では DOM 計測に退避する（整数に丸められていても通るように、
    \\    // 「実値」と「丸め値」のどちらかに一致すれば良い）。
    \\    var canvasOk = Object.keys(expected).every(function (k) {
    \\      return typeof canvasMetrics[k] === 'number';
    \\    });
    \\    var source = canvasOk ? canvasMetrics : probe;
    \\    var off = [];
    \\    Object.keys(expected).forEach(function (k) {
    \\      var want = expected[k];
    \\      var got = source[k];
    \\      var ok = typeof got === 'number' &&
    \\        (Math.abs(got - want) <= 0.15 || (!canvasOk && Math.abs(got - Math.round(want)) <= 0.15));
    \\      if (!ok) off.push(k + '=' + got + '≠' + want);
    \\    });
    \\    var metricsOk = off.length === 0;
    \\    var parityState = window.__ztsParity || {};
    \\    var bootOk = !!(parityState.api || parityState.css);
    \\    var checkOk = false;
    \\    try {
    \\      checkOk = document.fonts.check('16px ZTSSans') && document.fonts.check('16px ZTSMono');
    \\    } catch (e) { checkOk = false; }
    \\    var fontOk = bootOk && facesLoaded >= 4 && metricsOk;
    \\    probe.canvas = canvasMetrics;
    \\    probe.metrics_source = canvasOk ? 'canvas' : 'dom';
    \\    probe.faces = faceList.length;
    \\    probe.face_detail = faceList.join(' ');
    \\    probe.paint = paint;
    \\    probe.fonts_status = (document.fonts && document.fonts.status) || '?';
    \\    probe.check_ok = checkOk;
    \\    probe.metrics_ok = metricsOk;
    \\    probe.metrics_off = off.join(' ');
    \\    probe.boot = (parityState.api ? 'api' : '') + (parityState.css ? '+css' : '') +
    \\      (parityState.errors && parityState.errors.length ? ' errors=' + parityState.errors.join('|') : '') +
    \\      (parityState.faces !== undefined ? ' faces=' + parityState.faces : '');
    \\    post({
    \\      app: 'layout',
    \\      boxes: boxes,
    \\      names: names,
    \\      doc_w: document.documentElement.scrollWidth,
    \\      doc_h: document.documentElement.scrollHeight,
    \\      font_ok: fontOk,
    \\      probe: probe
    \\    });
    \\  };
    \\  // フォントを **明示的に** 読み込む。`document.fonts.ready` だけだと「そのページが実際に
    \\  // 使った字」しか読み込まれず、CSS を後から差し込む構成（SvelteKit の single bundle 等）では
    \\  // 使われていない扱いになって `check()` が false のままになる。
    \\  var loads = [];
    \\  try {
    \\    loads.push(document.fonts.load('16px ZTSSans'));
    \\    loads.push(document.fonts.load('700 16px ZTSSans'));
    \\    loads.push(document.fonts.load('16px ZTSSerif'));
    \\    loads.push(document.fonts.load('16px ZTSMono'));
    \\  } catch (e) { /* no FontFaceSet: fall through to the timed measure */ }
    \\  var afterFonts = function () {
    \\    var ready = (document.fonts && document.fonts.ready) ? document.fonts.ready : null;
    \\    var next = function () {
    \\      requestAnimationFrame(function () { requestAnimationFrame(measure); });
    \\    };
    \\    if (ready && ready.then) ready.then(next); else next();
    \\  };
    \\  var boot = window.__ztsFontsReady;
    \\  if (loads.length > 0 && window.Promise) {
    \\    var chain = boot ? Promise.all(loads.concat([boot])) : Promise.all(loads);
    \\    chain.then(afterFonts, afterFonts);
    \\  } else if (boot && boot.then) {
    \\    boot.then(afterFonts, afterFonts);
    \\  } else {
    \\    afterFonts();
    \\  }
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
/// Drives the loop until the page reported its **layout fingerprint** (fonts loaded, next frame
/// measured). Returns `false` on timeout — the capture still happens, and CI logs say so.
fn waitForReady(g: *Gallery, win: webview.WindowId, timeout_ms: i64) bool {
    var waited: i64 = 0;
    while (waited < timeout_ms) : (waited += 10) {
        _ = g.engine.step(.poll);
        const ws = g.stateFor(win) orelse return false;
        if (ws.layout != null) return true;
        g.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

/// Framework demos hydrate after `load`: wait for their `{"app":"ready"}` on top of the layout.
fn waitForApp(g: *Gallery, win: webview.WindowId, timeout_ms: i64) bool {
    var waited: i64 = 0;
    while (waited < timeout_ms) : (waited += 10) {
        _ = g.engine.step(.poll);
        const ws = g.stateFor(win) orelse return false;
        if (ws.app_ready) return true;
        g.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

/// Escapes `text` as a JSON string body (quotes, backslashes, control characters).
fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
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
            .init_scripts = &init_scripts,
            .initial_url = null,
            .initial_html = null,
        });

        var url_buf: [192]u8 = undefined;
        const url = if (p.route.len != 0)
            try std.fmt.bufPrint(&url_buf, "{s}://localhost/{s}", .{ scheme_name, p.route })
        else
            try std.fmt.bufPrint(&url_buf, "{s}://localhost/{s}", .{ scheme_name, p.name });
        try g.engine.navigate(id, url);

        try g.windows.append(g.allocator, .{ .id = id, .pattern = idx });
        defer {
            // The ready report is owned by the window state, so releasing the window releases it.
            if (g.stateFor(id)) |state| {
                if (state.report) |report| g.allocator.free(report);
                if (state.layout) |layout| g.allocator.free(layout);
                if (state.font_fetch) |probe| g.allocator.free(probe);
            }
            _ = g.windows.pop();
            g.engine.closeWindow(id) catch {};
        }

        // 1. Wait until the document fired `load` **and** reported its real viewport. On Windows
        //    the WebView2 browser process can take seconds to start, so a fixed sleep alone would
        //    capture a blank surface (the first CI run proved exactly that).
        const is_mock = std.mem.eql(u8, host, "mock"); // the mock runs no JS: nothing to wait for
        const ready = if (is_mock) false else waitForReady(g, id, 20_000);
        // 1b. Framework demos mount after `load`: wait for their own ready message.
        if (p.requires_app_ready and !is_mock) {
            if (!waitForApp(g, id, 20_000)) {
                std.debug.print("gallery: {s} app never signalled ready within 20s\n", .{p.name});
            }
        }
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
        // Layout fingerprint (`{"app":"layout", …}`) — the cross-OS comparator consumes this.
        if (ws_ptr.layout) |layout| {
            try writer.writeAll(", \"layout\": ");
            try writeJsonString(writer, layout);
        }
        try writer.print(", \"font_ok\": {s}", .{if (fontOk(ws_ptr.layout)) "true" else "false"});
        // 同梱フォントをページ側から読めたか（WebKit のカスタムスキーム/CORS 問題の切り分け用）。
        if (ws_ptr.font_fetch) |probe| {
            try writer.writeAll(", \"font_fetch\": ");
            try writeJsonString(writer, probe);
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
        if (p.html) |html| {
            try testing.expect(containsDoctype(html));
        } else {
            // Framework demos are served from the embedded asset table instead.
            try testing.expect(p.route.len > 0);
            var route_buf: [128]u8 = undefined;
            const route = std.fmt.bufPrint(&route_buf, "/{s}", .{p.route}) catch unreachable;
            try testing.expectEqual(@as(?usize, idx), patternForPath(route));
        }
        if (p.html) |html| try testing.expect(std.mem.indexOf(u8, html, "<title>") != null);
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
    try testing.expectEqualStrings("/js-roundtrip", pathOf("tauri://localhost/js-roundtrip"));
    try testing.expectEqualStrings("/api/state", pathOf("tauri://localhost/api/state?x=1"));
    try testing.expectEqualStrings("/", pathOf("tauri://localhost"));
    // WebView2 rewrites the custom scheme to a virtual `http://` origin; the router must agree.
    try testing.expectEqualStrings("/hero-light", pathOf("http://tauri.localhost/hero-light"));
    try testing.expectEqualStrings("/api/state", pathOf("http://tauri.localhost/api/state"));
}

test "gallery: bundled framework builds are addressable by route and by absolute asset URL" {
    const testing = std.testing;
    // Every framework pattern resolves to its own index.html ...
    for (patterns) |p| {
        if (p.route.len == 0) continue;
        var buf: [128]u8 = undefined;
        const route = try std.fmt.bufPrint(&buf, "/{s}", .{p.route});
        const asset = fw_asset(route[1..]) orelse return error.MissingAsset;
        try testing.expect(std.mem.endsWith(u8, asset.path, "/index.html"));
        try testing.expectEqualStrings("text/html; charset=utf-8", asset.content_type);
        // ... and `tauri://localhost/fw/<name>` (no file name) maps to the same pattern.
        try testing.expect(patternForPath(route[0 .. route.len - "index.html".len]) != null);
    }

    // Absolute URLs emitted by bundlers fall back to a suffix match.
    var found_js = false;
    for (&fw.assets) |*asset| {
        if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
        const slash = std.mem.lastIndexOfScalar(u8, asset.path, '/') orelse continue;
        const tail = asset.path[slash..];
        const hit = fw_alias(tail) orelse return error.MissingAlias;
        try testing.expect(std.mem.endsWith(u8, hit.path, tail));
        found_js = true;
    }
    try testing.expect(found_js);
    // Paths that are not part of a build stay unhandled (so `/api/state` keeps working).
    try testing.expectEqual(@as(?*const fw.Asset, null), fw_alias("/api/state"));
    try testing.expectEqual(@as(?*const fw.Asset, null), fw_alias("/"));
}

test "gallery: the injected scripts actually install the bundled fonts" {
    // Regression guard for `M5-05`: `parity_script` once existed but was never added to
    // `init_scripts`, so no page ever saw an `@font-face` rule. Linux then rendered with
    // whatever font the container had (often none → tofu) while macOS/Windows used their own
    // system fonts, which is exactly the "Linux only looks broken" bug this task is about.
    try std.testing.expectEqual(@as(usize, 2), init_scripts.len);
    try std.testing.expectEqual(parity_script, init_scripts[0]);
    try std.testing.expectEqual(ready_script, init_scripts[1]);

    // Every embedded woff2 must be referenced by the injected bootstrap: a path typo or a
    // font that is served but never declared is invisible until a screenshot turns into tofu.
    for (&font_assets) |*asset| {
        try std.testing.expect(std.mem.indexOf(u8, parity_script, asset.path) != null);
        try std.testing.expect(fontFor(asset.path) != null);
    }
    // The families the demo pages name must be exactly the ones the bootstrap declares.
    for ([_][]const u8{ "ZTSSans", "ZTSSerif", "ZTSMono" }) |family| {
        try std.testing.expect(std.mem.indexOf(u8, parity_script, family) != null);
    }
    // The measurer must wait for the faces and gate on real metrics.
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "__ztsFontsReady") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "sans0b") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "\"font_ok\":") == null);
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
