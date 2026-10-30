//! Native Windows deployment smoke test — a **single self-contained `.exe`** (`M3-02`).
//!
//! `zig build -Dtarget=x86_64-windows-gnu` installs exactly one file, `zts_webview2_smoke.exe`:
//! no `WebView2Loader.dll`, no CRT redistributable, no MSVC SDK. The Evergreen WebView2 runtime is
//! discovered in the registry and `EmbeddedBrowserWebView.dll` is loaded directly by
//! `src/webview/webview2_loader.zig`.
//!
//! This is deliberately a *thin consumer* of the standalone `zts_webview` module (it never imports
//! `zts_core` / `zts_tauri`), which proves the Win32 + WebView2 backend is usable as a drop-in
//! library. `ci-windows` runs the installed `.exe` and greps for the `OK windows-webview2-smoke`
//! marker, so a missing WebView2 runtime (or a silently degraded headless fallback) fails the job.

const std = @import("std");
const zts_webview = @import("zts_webview");

const Page =
    \\<!doctype html>
    \\<meta charset="utf-8">
    \\<title>Z-Ts WebView2 smoke</title>
    \\<body style="font:16px system-ui;background:#101014;color:#eee;margin:24px">
    \\  <h1 id="h">Z-Ts · Win32 + Direct WebView2</h1>
    \\  <p id="p">booting…</p>
    \\  <script>
    \\    const dpi = window.devicePixelRatio || 1;
    \\    const w = window.innerWidth, h = window.innerHeight;
    \\    const ua = navigator.userAgent.includes("Windows");
    \\    document.getElementById("p").textContent =
    \\      `ok  dpr=${dpi}  ${w}x${h}  windows=${ua}`;
    \\    window.__ztsPostMessage(JSON.stringify({ dpr: dpi, w, h, ua }));
    \\  </script>
    \\</body>
;

const Ctx = struct {
    report: ?[]u8 = null,
    done: bool = false,
};

fn onMessage(raw: ?*anyopaque, _: zts_webview.WindowId, message: []const u8) void {
    const ctx: *Ctx = @ptrCast(@alignCast(raw.?));
    ctx.done = true;
    ctx.report = std.heap.page_allocator.dupe(u8, message) catch null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var engine = zts_webview.Engine.init(allocator, io, .native) catch |err| {
        std.debug.print("FAIL windows-webview2-smoke: no native backend ({s})\n", .{@errorName(err)});
        return err;
    };
    defer engine.deinit();

    var ctx: Ctx = .{};
    defer if (ctx.report) |r| std.heap.page_allocator.free(r);
    engine.setMessageHandler(.{ .userdata = &ctx, .onMessage = onMessage });

    const win = try engine.createWindow(.{
        .title = "Z-Ts · WebView2 smoke",
        .size = .wh(520, 320),
        .visible = true,
        .initial_html = Page,
    });

    // `step(.blocking)` waits at most 1 s per iteration inside `MsgWaitForMultipleObjectsEx`, so a
    // 30-iteration budget bounds this smoke test at ~30 s without a separate watchdog thread.
    var budget: usize = 30;
    while (budget > 0 and !ctx.done) : (budget -= 1) {
        if (!engine.step(.blocking)) break;
    }

    if (!ctx.done) {
        std.debug.print("FAIL windows-webview2-smoke: JS message never arrived (timeout)\n", .{});
        return error.WebView2SmokeTimeout;
    }

    try engine.closeWindow(win);
    std.debug.print("OK windows-webview2-smoke single-exe=1 report={s}\n", .{ctx.report orelse "{}"});
}
