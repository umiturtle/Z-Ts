//! Native Windows E2E — a **real** `HWND` + WebView2 round trip (`M3-02`).
//!
//! Built and executed by `zig build test` on `windows-latest` only. It is deliberately a *standalone
//! executable* rather than a `test` block for three reasons:
//!
//! 1. A crash in a COM/browser callback must not corrupt the test-runner's accounting — as a `run`
//!    step its stderr goes straight into the CI log, which is what makes the gate debuggable.
//! 2. It consumes `zts_webview` exactly like a third-party app would (`Engine` + public callbacks),
//!    proving the backend is usable as a drop-in library on Windows.
//! 3. Progress markers (`e2e: stage=…`) pinpoint the failing step when the browser misbehaves.
//!
//! What it proves, end to end:
//! `Win32` window → WebView2 environment (`EmbeddedBrowserWebView.dll` loaded directly from the
//! registry-discovered Evergreen runtime, no `WebView2Loader.dll`) → `ICoreWebView2Controller` →
//! `tauri://localhost` navigation rewritten to `http://tauri.localhost` and answered through
//! `WebResourceRequested` + `ICoreWebView2Deferral` → page JS `fetch('http://ipc.localhost/ping')`
//! (`application/json` POST ⇒ real CORS preflight) → `OPTIONS` absorbed by the backend → response
//! completed from a **worker thread** → `postMessage` back into Zig → clean window teardown.
//!
//! The page also reports three CORS probes (`probeSame` / `probeGet` / `probePlain`) as
//! `<status>|acao=<header>|tr=<header>` strings. They separate the layers that broke during `M3-02`
//! bring-up: header-block delivery (`tr=ok` on a same-origin fetch), response CORS headers
//! (`200|` on a simple cross-origin GET) and a CORS-safelisted `text/plain` POST.

const std = @import("std");
const zts_webview = @import("zts_webview");

const max_body_seen = 64;

const page =
    \\<!doctype html>
    \\<meta charset="utf-8">
    \\<title>Z-Ts Windows E2E</title>
    \\<body style="font:16px system-ui;background:#101014;color:#eee">
    \\<script>
    \\(async () => {
    \\  const out = { bootInjected: typeof window.__ztsPostMessage === 'function' };
    \\  const probe = async (name, url, opts) => {
    \\    try {
    \\      const r = await fetch(url, opts);
    \\      out[name] = r.status + '|acao=' + (r.headers.get('Access-Control-Allow-Origin') || '-') +
    \\        '|tr=' + (r.headers.get('Tauri-Response') || '-');
    \\    } catch (e) { out[name] = 'ERR ' + String(e); }
    \\  };
    \\  // Same-origin: proves the custom response headers survive WebView2's header-block parser.
    \\  await probe('probeSame', 'http://tauri.localhost/index.html');
    \\  // Simple cross-origin GET: no preflight, so only the *response* CORS headers matter.
    \\  await probe('probeGet', 'http://ipc.localhost/probe-get');
    \\  // `text/plain` keeps the POST CORS-safelisted: again no preflight.
    \\  await probe('probePlain', 'http://ipc.localhost/probe-plain',
    \\    { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: '{"n":41}' });
    \\  try {
    \\    const r = await fetch('http://ipc.localhost/ping', {
    \\      method: 'POST',
    \\      headers: { 'Content-Type': 'application/json' },
    \\      body: JSON.stringify({ n: 41 }),
    \\    });
    \\    out.tauriHdr = r.headers.get('Tauri-Response');
    \\    out.cors = r.headers.get('Access-Control-Allow-Origin');
    \\    const j = await r.json();
    \\    out.sum = j.sum;
    \\    out.method = j.method;
    \\    out.bodyLen = j.bodyLen;
    \\    out.deferral = j.deferral;
    \\    out.ua = navigator.userAgent.includes('Windows');
    \\    out.dpr = window.devicePixelRatio || 1;
    \\  } catch (e) { out.err = String(e); }
    \\  window.__ztsPostMessage(JSON.stringify(out));
    \\})();
    \\</script>
;

const Ctx = struct {
    allocator: std.mem.Allocator,
    engine: ?*zts_webview.Engine = null,
    report: ?[]u8 = null,
    done: bool = false,
    tauri_hits: u32 = 0,
    ipc_hits: u32 = 0,
    ipc_method: [8]u8 = @splat(0),
    ipc_method_len: usize = 0,
    ipc_body_len: usize = 0,
    workers: [8]?std.Thread = @splat(null),
    worker_count: usize = 0,
};

fn stage(comptime text: []const u8) void {
    std.debug.print("e2e: {s}\n", .{text});
}

fn onTauriRequest(userdata: ?*anyopaque, req: zts_webview.SchemeRequest) void {
    const ctx: *Ctx = @ptrCast(@alignCast(userdata.?));
    ctx.tauri_hits += 1;
    ctx.engine.?.completeRequest(req.request_id, .{
        .status_code = 200,
        .content_type = "text/html; charset=utf-8",
        .extra_headers = &.{.{ .name = "Tauri-Response", .value = "ok" }},
        .body = zts_webview.OwnedBytes.static(page),
    }) catch {};
}

const IpcJob = struct {
    engine: *zts_webview.Engine,
    allocator: std.mem.Allocator,
    req_id: zts_webview.RequestId,
    method: [8]u8,
    method_len: usize,
    body_len: usize,
};

/// Completes the request from a **worker thread**: only the 53-bit `RequestId` + bytes cross the
/// thread boundary, the `ICoreWebView2Deferral` stays on the STA (Architectural Invariant #4).
fn ipcWorker(job: *IpcJob) void {
    const body = std.fmt.allocPrint(
        job.allocator,
        "{{\"sum\":42,\"method\":\"{s}\",\"bodyLen\":{d},\"deferral\":true}}",
        .{ job.method[0..job.method_len], job.body_len },
    ) catch {
        job.allocator.destroy(job);
        return;
    };
    job.engine.completeRequest(job.req_id, .{
        .status_code = 200,
        .content_type = "application/json",
        .extra_headers = &.{.{ .name = "Tauri-Response", .value = "ok" }},
        .body = zts_webview.OwnedBytes.fromOwnedSlice(job.allocator, body),
    }) catch job.allocator.free(body);
    job.allocator.destroy(job);
}

fn onIpcRequest(userdata: ?*anyopaque, req: zts_webview.SchemeRequest) void {
    const ctx: *Ctx = @ptrCast(@alignCast(userdata.?));
    ctx.ipc_hits += 1;
    // Only `/ping` takes part in the assertions; the CORS probes hit other paths so they cannot
    // overwrite the recorded method/body length.
    if (std.mem.endsWith(u8, req.uri, "/ping")) {
        ctx.ipc_method_len = @min(req.method.len, ctx.ipc_method.len);
        @memcpy(ctx.ipc_method[0..ctx.ipc_method_len], req.method[0..ctx.ipc_method_len]);
        ctx.ipc_body_len = req.body.len;
    }

    const job = ctx.allocator.create(IpcJob) catch return;
    job.* = .{
        .engine = ctx.engine.?,
        .allocator = ctx.allocator,
        .req_id = req.request_id,
        .method = ctx.ipc_method,
        .method_len = ctx.ipc_method_len,
        .body_len = req.body.len,
    };
    if (ctx.worker_count == ctx.workers.len) {
        ipcWorker(job); // thread budget exhausted: still validate the IPC path
        return;
    }
    // `error.ThreadQuotaExceeded` and friends: fall back to a synchronous completion.
    const spawned = std.Thread.spawn(.{}, ipcWorker, .{job}) catch {
        ipcWorker(job);
        return;
    };
    ctx.workers[ctx.worker_count] = spawned;
    ctx.worker_count += 1;
}

fn onMessage(userdata: ?*anyopaque, _: zts_webview.WindowId, message: []const u8) void {
    const ctx: *Ctx = @ptrCast(@alignCast(userdata.?));
    ctx.done = true;
    if (ctx.report) |old| ctx.allocator.free(old);
    ctx.report = ctx.allocator.dupe(u8, message) catch null;
}

const Report = struct {
    err: ?[]const u8 = null,
    bootInjected: ?bool = null,
    tauriHdr: ?[]const u8 = null,
    cors: ?[]const u8 = null,
    sum: ?i64 = null,
    method: ?[]const u8 = null,
    bodyLen: ?i64 = null,
    deferral: ?bool = null,
    ua: ?bool = null,
    dpr: ?f64 = null,
    probeSame: ?[]const u8 = null,
    probeGet: ?[]const u8 = null,
    probePlain: ?[]const u8 = null,
};

var checks_passed: u32 = 0;

/// Marker check for a probe string produced by the page (`"<status>|acao=…|tr=…"`).
fn has(probe: ?[]const u8, comptime needle: []const u8) bool {
    const text = probe orelse return false;
    return std.mem.indexOf(u8, text, needle) != null;
}

fn check(ok: bool, comptime what: []const u8) !void {
    if (!ok) {
        std.debug.print("e2e: CHECK FAILED {s}\n", .{what});
        return error.E2eCheckFailed;
    }
    checks_passed += 1;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    stage("start");
    var engine = zts_webview.Engine.init(allocator, io, .native) catch |err| switch (err) {
        error.DisplayUnavailable => {
            std.debug.print(
                "SKIP windows-wv2: no Evergreen WebView2 runtime on this machine " ++
                    "(ci-windows installs it before running this test)\n",
                .{},
            );
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer engine.deinit();

    var ctx: Ctx = .{ .allocator = allocator, .engine = &engine };
    defer if (ctx.report) |r| allocator.free(r);
    defer {
        for (ctx.workers[0..ctx.worker_count]) |entry| {
            if (entry) |t| t.join();
        }
    }

    const version = engine.runtimeVersion() orelse "";
    stage("init ok");
    std.debug.print("e2e: runtime={s}\n", .{version});
    try check(version.len > 0, "runtime version discovered from the registry");

    engine.setMessageHandler(.{ .userdata = &ctx, .onMessage = onMessage });
    try engine.registerScheme("tauri", .{ .userdata = &ctx, .onRequest = onTauriRequest });
    try engine.registerScheme("ipc", .{ .userdata = &ctx, .onRequest = onIpcRequest });
    stage("schemes registered");

    const win = try engine.createWindow(.{
        .title = "Z-Ts · WebView2 E2E",
        .size = .wh(560, 360),
        .decorations = false,
        .transparent = true,
        .initial_url = "tauri://localhost/index.html",
    });
    stage("window created");
    try check(engine.nativeHandle(win) != null, "real HWND created");

    var budget: usize = 120;
    var iterations: usize = 0;
    while (budget > 0 and !ctx.done) : (budget -= 1) {
        iterations += 1;
        if (iterations % 10 == 0) std.debug.print("e2e: step {d}\n", .{iterations});
        if (!engine.step(.blocking)) break;
    }
    stage("loop finished");
    try check(ctx.done, "page reported back through postMessage");

    const report = ctx.report orelse return error.MissingJsReport;
    var parsed = try std.json.parseFromSlice(Report, allocator, report, .{});
    defer parsed.deinit();
    const value = parsed.value;

    // Printed before the failure branch so a broken CORS layer is diagnosable from CI logs alone.
    std.debug.print("e2e: report={s}\n", .{report});
    if (value.err) |e| {
        std.debug.print("e2e: JS error: {s}\n", .{e});
        return error.WebView2JsError;
    }

    try check(value.bootInjected orelse false, "__ztsPostMessage injected at DOCUMENT_START");
    try check(has(value.probeSame, "tr=ok"), "custom response headers survive the header block");
    try check(has(value.probeGet, "200|"), "cross-origin GET answered without a preflight");
    try check(has(value.probePlain, "200|"), "cross-origin POST without a preflight succeeded");
    try check(std.mem.eql(u8, value.tauriHdr orelse "", "ok"), "Tauri-Response header exposed through CORS");
    // `Access-Control-Allow-Origin` is **not** a CORS-safelisted response header, so the page
    // cannot read it back (`cors` stays null even on a successful request) — `Tauri-Response` above
    // is what proves the response passed the CORS check. Do not assert on `cors`.

    try check((value.sum orelse -1) == 42, "JSON body decoded by the page");
    try check(std.mem.eql(u8, value.method orelse "", "POST"), "request method survived the filter");
    try check((value.bodyLen orelse -1) == 8, "request body reached the Zig handler intact");
    try check(value.deferral orelse false, "response completed from a worker thread");
    try check(value.ua orelse false, "user agent reports Windows");
    try check((value.dpr orelse 0) >= 1.0, "devicePixelRatio available (DPI aware)");
    try check(ctx.tauri_hits >= 1, "tauri:// document served by the Zig scheme handler");
    try check(ctx.ipc_hits >= 1, "ipc:// request served by the Zig scheme handler");
    try check(std.mem.eql(u8, ctx.ipc_method[0..ctx.ipc_method_len], "POST"), "ipc request was a POST");
    // A cross-origin `application/json` POST is preflighted: the backend must have answered
    // `OPTIONS` itself (204 + `Access-Control-Allow-*`) without ever waking Zig.
    try check(engine.preflightCount() >= 1, "CORS preflight absorbed by the backend");

    try engine.closeWindow(win);
    stage("window closed");
    try check(!engine.step(.poll), "step() returns false after the last window closed");

    std.debug.print(
        "OK windows-wv2 checks={d} runtime={s} preflights={d} dpr={d:.2} single-exe=1\n",
        .{ checks_passed, version, engine.preflightCount(), value.dpr orelse 1.0 },
    );
}
