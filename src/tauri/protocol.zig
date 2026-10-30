//! Tauri v2 Custom Protocol (`tauri://`, `ipc://`, `asset://`) & `postMessage` Router (`src/tauri/protocol.zig`).
//!
//! Pure Zig (`link_libc = false`) protocol engine connecting any `zts_core.Host` implementation
//! (`HeadlessMock`, `LinuxGtkBackend`, future `macOS WKWebView` / `Windows WebView2`) to:
//! 1. `tauri://localhost/*` (`http://tauri.localhost/*`):
//!    - Serves embedded/custom `zts_web.Assets` with SPA routing, optional inline `<head>` bootstrap
//!      script injection, CSP headers, and RFC 9110 `206 Partial Content` byte ranges.
//! 2. `asset://localhost/<encoded_path>` (`http://asset.localhost/<encoded_path>`):
//!    - Percent-decodes file path, blocks NUL bytes & `..` traversal, validates against explicit
//!      `zts_foundation.glob` allowlist scopes (`403 Forbidden` by default), and streams ranges (`200`/`206`).
//! 3. `ipc://localhost/<encoded_cmd>` (`http://ipc.localhost/<encoded_cmd>`):
//!    - Enforces **constant-time `Tauri-Invoke-Key` verification** AND **Origin allowlist check**
//!      (`403 Forbidden` before touching command logic), percent-decodes `<cmd>` (`plugin%3Awindow%7C...`),
//!      dispatches to `zts_rpc.Handler`, and attaches `Tauri-Response: ok|error`.
//! 4. `handlePostMessage`:
//!    - Full fallback handler when JS sends `{ cmd, callback, error, payload, __TAURI_INVOKE_KEY__ }`
//!      over `window.webkit.messageHandlers` / `window.chrome.webview.postMessage`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const foundation = @import("zts_foundation");
const html_escape = foundation.html_escape;
const glob = foundation.glob;
const web = @import("zts_web");
const core = @import("zts_core");
const rpc = @import("zts_rpc");
const js_bootstrap = @import("js_bootstrap.zig");

/// A request/response header. Values are borrowed slices, never NUL terminated.
pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

/// One `tauri://` / `ipc://` / `asset://` hit, already decoded from the WebView's callback. A
/// `WindowId` of `0` means "no window" (a request that arrived before the first window existed).
pub const IncomingSchemeRequest = struct {
    window_id: core.WindowId,
    method: []const u8,
    uri: []const u8,
    headers: []const HeaderPair = &.{},
    body: []const u8 = "",

    pub fn header(self: IncomingSchemeRequest, wanted_name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, wanted_name)) return h.value;
        }
        return null;
    }
};

/// What the router hands back to the WebView. `body` is owned by the response (see
/// `core.OwnedBytes`), and `content_range_buf` avoids an allocation for the 206 case by formatting
/// `bytes 0-1023/4096` into a fixed buffer.
pub const RoutedResponse = struct {
    status_code: u16 = 200,
    content_type: []const u8 = "application/json",
    tauri_response: ?[]const u8 = null,
    accept_ranges: bool = false,
    content_range_buf: [64]u8 = undefined,
    content_range_len: usize = 0,
    csp_header: ?[]const u8 = null,
    body: core.OwnedBytes = .empty,

    pub fn intoHeaderSlice(self: *const RoutedResponse, scratch: Allocator) Allocator.Error![]HeaderPair {
        var list: std.ArrayList(HeaderPair) = .empty;
        if (self.tauri_response) |tr| {
            try list.append(scratch, .{ .name = "Tauri-Response", .value = tr });
        }
        if (self.accept_ranges) {
            try list.append(scratch, .{ .name = "Accept-Ranges", .value = "bytes" });
        }
        if (self.content_range_len > 0) {
            try list.append(scratch, .{
                .name = "Content-Range",
                .value = self.content_range_buf[0..self.content_range_len],
            });
        }
        if (self.csp_header) |csp_val| {
            try list.append(scratch, .{ .name = "Content-Security-Policy", .value = csp_val });
        }
        return list.toOwnedSlice(scratch);
    }
};

/// Everything the protocol layer needs that is not per-request.
///
/// * `invoke_key` — per-run CSRF token; `ipc://` requests must echo it, and the comparison is
///   constant-time.
/// * `assets` — the embedded `dist/` bundle served from `tauri://localhost/`.
/// * `inject_bootstrap_into_html` — inject `window.__TAURI_INTERNALS__` into every HTML response.
/// * `default_window_label` — label used when a command omits `window` (Tauri v2 semantics).
/// * `csp` — `Content-Security-Policy` header value; `null` disables the header.
/// * `asset_root_dir` / `asset_allow_globs` — dev-mode serving from disk, restricted to the globs.
/// * `extra_allowed_origins` — additional origins accepted for `ipc://` (dev servers).
pub const ProtocolConfig = struct {
    invoke_key: []const u8,
    assets: ?*const web.Assets = null,
    inject_bootstrap_into_html: bool = false,
    default_window_label: []const u8 = "main",
    csp: ?[]const u8 = null,
    asset_root_dir: ?[]const u8 = null,
    asset_allow_globs: []const []const u8 = &.{},
    extra_allowed_origins: []const []const u8 = &.{},
};

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |ca, cb| {
        diff |= ca ^ cb;
    }
    return diff == 0;
}

fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Percent-decodes `input` into a new buffer, failing with `InvalidPercentEncoding` on a truncated
/// `%`-escape. Unlike `decodeURIComponent` it also decodes `%2F`, because the router needs the
/// *real* separators before it can apply a path scope.
pub fn percentDecodeRawAlloc(allocator: Allocator, input: []const u8) error{ OutOfMemory, InvalidPercentEncoding }![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%') {
            if (i + 2 >= input.len) return error.InvalidPercentEncoding;
            const hi = hexNibble(input[i + 1]) orelse return error.InvalidPercentEncoding;
            const lo = hexNibble(input[i + 2]) orelse return error.InvalidPercentEncoding;
            out.appendAssumeCapacity((@as(u8, hi) << 4) | @as(u8, lo));
            i += 3;
        } else {
            out.appendAssumeCapacity(input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

const ParsedSchemeTarget = struct {
    kind: enum { tauri, ipc, asset, unknown },
    path: []const u8,
};

/// Maps a request URI to the scheme it belongs to (`tauri` / `ipc` / `asset` / `unknown`) plus the
/// path without query or fragment. Both the custom scheme (`tauri://localhost/x`) and the HTTP form
/// (`http://tauri.localhost/x`) are recognised, because Windows resolves custom schemes through
/// `http://<scheme>.localhost`.
pub fn classifyUri(uri: []const u8) ParsedSchemeTarget {
    const scheme_sep = std.mem.indexOf(u8, uri, "://") orelse return .{ .kind = .unknown, .path = "/" };
    const raw_scheme = uri[0..scheme_sep];
    const rest = uri[scheme_sep + 3 ..];

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/');
    const host_part = if (slash_idx) |i| rest[0..i] else rest;
    const raw_path_with_q = if (slash_idx) |i| rest[i..] else "/";
    const q_idx = std.mem.indexOfAny(u8, raw_path_with_q, "?#");
    const clean_path = if (q_idx) |qi| raw_path_with_q[0..qi] else raw_path_with_q;

    if (std.ascii.eqlIgnoreCase(raw_scheme, "tauri")) return .{ .kind = .tauri, .path = clean_path };
    if (std.ascii.eqlIgnoreCase(raw_scheme, "ipc")) return .{ .kind = .ipc, .path = clean_path };
    if (std.ascii.eqlIgnoreCase(raw_scheme, "asset")) return .{ .kind = .asset, .path = clean_path };

    if (std.ascii.eqlIgnoreCase(raw_scheme, "http") or std.ascii.eqlIgnoreCase(raw_scheme, "https")) {
        if (std.ascii.eqlIgnoreCase(host_part, "tauri.localhost")) return .{ .kind = .tauri, .path = clean_path };
        if (std.ascii.eqlIgnoreCase(host_part, "ipc.localhost")) return .{ .kind = .ipc, .path = clean_path };
        if (std.ascii.eqlIgnoreCase(host_part, "asset.localhost")) return .{ .kind = .asset, .path = clean_path };
    }
    return .{ .kind = .unknown, .path = clean_path };
}

/// Routes one WebView request: static asset, `ipc://` command, or a 404. Holds no mutable state —
/// the only per-engine value is the CSRF `invoke_key` inside the config — so the same router serves
/// every window.
pub const ProtocolRouter = struct {
    allocator: Allocator,
    io: Io,
    config: ProtocolConfig,
    rpc_handler: rpc.Handler,

    pub fn init(
        allocator: Allocator,
        io: Io,
        config: ProtocolConfig,
        rpc_handler: rpc.Handler,
    ) ProtocolRouter {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .rpc_handler = rpc_handler,
        };
    }

    pub fn isAllowedOrigin(self: *const ProtocolRouter, origin_opt: ?[]const u8) bool {
        const origin = origin_opt orelse return true;
        if (origin.len == 0 or std.ascii.eqlIgnoreCase(origin, "null")) return false;
        if (foundation.url.isBuiltInLocalWebViewOrigin(origin)) return true;
        for (self.config.extra_allowed_origins) |extra| {
            if (std.ascii.eqlIgnoreCase(origin, extra)) return true;
        }
        return false;
    }

    pub fn generateInvokeKeyHex(io: Io) [64]u8 {
        var bytes: [32]u8 = undefined;
        io.randomSecure(&bytes) catch io.random(&bytes);
        return std.fmt.bytesToHex(bytes, .lower);
    }

    pub fn handleRequest(
        self: *const ProtocolRouter,
        host: core.Host,
        req: IncomingSchemeRequest,
    ) RoutedResponse {
        const target = classifyUri(req.uri);
        return switch (target.kind) {
            .ipc => self.handleIpc(host, req, target.path),
            .tauri => self.handleTauriAsset(req, target.path),
            .asset => self.handleFilesystemAsset(req, target.path),
            .unknown => .{
                .status_code = 404,
                .content_type = "application/json",
                .body = core.OwnedBytes.static("{\"code\":\"UnknownScheme\"}"),
            },
        };
    }

    fn handleIpc(
        self: *const ProtocolRouter,
        host: core.Host,
        req: IncomingSchemeRequest,
        raw_path: []const u8,
    ) RoutedResponse {
        const provided_key = req.header("Tauri-Invoke-Key") orelse {
            return .{
                .status_code = 403,
                .content_type = "application/json",
                .tauri_response = "error",
                .body = core.OwnedBytes.static("{\"code\":\"ForbiddenMissingInvokeKey\"}"),
            };
        };
        if (!constantTimeEql(provided_key, self.config.invoke_key)) {
            return .{
                .status_code = 403,
                .content_type = "application/json",
                .tauri_response = "error",
                .body = core.OwnedBytes.static("{\"code\":\"ForbiddenInvalidInvokeKey\"}"),
            };
        }
        if (!self.isAllowedOrigin(req.header("Origin"))) {
            return .{
                .status_code = 403,
                .content_type = "application/json",
                .tauri_response = "error",
                .body = core.OwnedBytes.static("{\"code\":\"ForbiddenOrigin\"}"),
            };
        }

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const encoded_cmd = std.mem.trimStart(u8, raw_path, "/");
        const cmd_name = percentDecodeRawAlloc(scratch, encoded_cmd) catch {
            return .{
                .status_code = 400,
                .content_type = "application/json",
                .tauri_response = "error",
                .body = core.OwnedBytes.static("{\"code\":\"BadCommandEncoding\"}"),
            };
        };

        var call_ctx: core.CallContext = .{
            .host = host,
            .window_id = req.window_id,
        };
        var rpc_ctx = rpc.Ctx.init(self.io, scratch).withEnv(&call_ctx);
        if (req.header("Origin")) |orig| rpc_ctx.origin = orig;

        var out = self.rpc_handler.dispatch(self.allocator, &rpc_ctx, cmd_name, req.body);
        defer out.deinit();

        const out_slice = out.body.slice();
        const safe_body: core.OwnedBytes = if (out.body.release_fn != null)
            out.body.move()
        else if (out_slice.len == 0)
            .empty
        else
            core.OwnedBytes.static(out_slice);

        return switch (out.status) {
            .ok => .{
                .status_code = 200,
                .content_type = out.content_type,
                .tauri_response = "ok",
                .body = safe_body,
            },
            .err => .{
                .status_code = 400,
                .content_type = out.content_type,
                .tauri_response = "error",
                .body = safe_body,
            },
        };
    }

    fn handleTauriAsset(self: *const ProtocolRouter, req: IncomingSchemeRequest, raw_path: []const u8) RoutedResponse {
        const catalog = self.config.assets orelse {
            return .{
                .status_code = 404,
                .content_type = "text/plain; charset=utf-8",
                .body = core.OwnedBytes.static("Not Found"),
            };
        };

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const head_inject: ?[]const u8 = if (self.config.inject_bootstrap_into_html)
            js_bootstrap.renderInlineHtmlTagAlloc(scratch, .{
                .label = self.config.default_window_label,
                .invoke_key = self.config.invoke_key,
            }) catch null
        else
            null;

        var resolved = catalog.resolve(self.allocator, raw_path, .{
            .range_header = req.header("Range"),
            .spa_fallback = true,
            .html_head_injection = head_inject,
        }) catch {
            return .{
                .status_code = 500,
                .content_type = "text/plain; charset=utf-8",
                .body = core.OwnedBytes.static("Asset Read Error"),
            };
        };
        defer resolved.deinit();

        var resp: RoutedResponse = .{
            .status_code = @backingInt(resolved.status),
            .content_type = resolved.mime_type,
            .accept_ranges = true,
            .csp_header = if (web.mime.isHtml(resolved.mime_type)) self.config.csp else null,
            .body = resolved.body.move(),
        };
        var cr_buf: [64]u8 = undefined;
        if (resolved.contentRangeHeader(&cr_buf)) |cr| {
            @memcpy(resp.content_range_buf[0..cr.len], cr);
            resp.content_range_len = cr.len;
        }
        return resp;
    }

    fn handleFilesystemAsset(self: *const ProtocolRouter, req: IncomingSchemeRequest, raw_path: []const u8) RoutedResponse {
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const trimmed = if (raw_path.len > 1 and raw_path[0] == '/' and raw_path[1] != '/')
            raw_path[1..]
        else
            raw_path;

        const decoded = percentDecodeRawAlloc(scratch, trimmed) catch {
            return .{ .status_code = 400, .content_type = "text/plain", .body = core.OwnedBytes.static("Bad URI") };
        };

        if (decoded.len == 0 or std.mem.indexOfScalar(u8, decoded, 0) != null or containsDotDotSegment(decoded)) {
            return .{
                .status_code = 403,
                .content_type = "text/plain; charset=utf-8",
                .body = core.OwnedBytes.static("Forbidden Path Traversal"),
            };
        }

        var allowed = false;
        for (self.config.asset_allow_globs) |pattern| {
            if (glob.match(pattern, decoded)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) {
            return .{
                .status_code = 403,
                .content_type = "text/plain; charset=utf-8",
                .body = core.OwnedBytes.static("Forbidden Asset Scope"),
            };
        }

        const fs_path = if (!std.fs.path.isAbsolute(decoded) and self.config.asset_root_dir != null)
            (std.fs.path.join(scratch, &.{ self.config.asset_root_dir.?, decoded }) catch {
                return .{ .status_code = 500, .content_type = "text/plain", .body = .empty };
            })
        else
            decoded;

        const file_bytes = Io.Dir.cwd().readFileAlloc(self.io, fs_path, self.allocator, .limited(256 * 1024 * 1024)) catch {
            return .{
                .status_code = 404,
                .content_type = "text/plain; charset=utf-8",
                .body = core.OwnedBytes.static("Asset Not Found"),
            };
        };
        const mime_type = web.mime.detect(decoded, file_bytes);

        if (req.header("Range")) |range_hdr| {
            switch (web.http_range.evaluate(range_hdr, file_bytes.len)) {
                .partial => |r| {
                    defer self.allocator.free(file_bytes);
                    const sub = self.allocator.dupe(u8, r.slice(file_bytes)) catch {
                        return .{ .status_code = 500, .content_type = "text/plain", .body = .empty };
                    };
                    var resp: RoutedResponse = .{
                        .status_code = 206,
                        .content_type = mime_type,
                        .accept_ranges = true,
                        .body = core.OwnedBytes.fromOwnedSlice(self.allocator, sub),
                    };
                    var cr_buf: [64]u8 = undefined;
                    const cr = r.formatContentRange(&cr_buf, file_bytes.len);
                    @memcpy(resp.content_range_buf[0..cr.len], cr);
                    resp.content_range_len = cr.len;
                    return resp;
                },
                .unsatisfiable => {
                    defer self.allocator.free(file_bytes);
                    var resp: RoutedResponse = .{
                        .status_code = 416,
                        .content_type = "text/plain; charset=utf-8",
                        .accept_ranges = true,
                        .body = .empty,
                    };
                    var cr_buf: [48]u8 = undefined;
                    const cr = web.http_range.formatUnsatisfiableContentRange(&cr_buf, file_bytes.len);
                    @memcpy(resp.content_range_buf[0..cr.len], cr);
                    resp.content_range_len = cr.len;
                    return resp;
                },
                .ignore => {},
            }
        }

        return .{
            .status_code = 200,
            .content_type = mime_type,
            .accept_ranges = true,
            .body = core.OwnedBytes.fromOwnedSlice(self.allocator, file_bytes),
        };
    }

    pub fn handlePostMessage(
        self: *const ProtocolRouter,
        host: core.Host,
        window_id: core.WindowId,
        raw_message: []const u8,
    ) void {
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const Envelope = struct {
            cmd: []const u8,
            callback: u32,
            @"error": u32,
            __TAURI_INVOKE_KEY__: []const u8 = "",
        };

        var parsed = std.json.parseFromSlice(Envelope, scratch, raw_message, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        const env = parsed.value;
        if (!constantTimeEql(env.__TAURI_INVOKE_KEY__, self.config.invoke_key)) {
            const err_js = std.fmt.allocPrint(
                scratch,
                "window.__TAURI_INTERNALS__.runCallback({d},{{\"code\":\"ForbiddenInvalidInvokeKey\"}});",
                .{env.@"error"},
            ) catch return;
            host.evalJs(window_id, err_js) catch {};
            return;
        }

        const payload_json = extractFieldRawJson(raw_message, "payload") orelse "{}";
        var call_ctx: core.CallContext = .{ .host = host, .window_id = window_id };
        var rpc_ctx = rpc.Ctx.init(self.io, scratch).withEnv(&call_ctx);

        var out = self.rpc_handler.dispatch(scratch, &rpc_ctx, env.cmd, payload_json);
        defer out.deinit();

        const target_cb = if (out.status == .ok) env.callback else env.@"error";
        var aw: std.Io.Writer.Allocating = .init(scratch);
        defer aw.deinit();
        aw.writer.print("window.__TAURI_INTERNALS__.runCallback({d},", .{target_cb}) catch return;
        if (std.mem.startsWith(u8, out.content_type, "application/json")) {
            aw.writer.writeAll(if (out.body.slice().len > 0) out.body.slice() else "null") catch return;
        } else {
            html_escape.writeJsonString(&aw.writer, out.body.slice(), true) catch return;
        }
        aw.writer.writeAll(");") catch return;
        host.evalJs(window_id, aw.written()) catch {};
    }
};

fn containsDotDotSegment(p: []const u8) bool {
    var i: usize = 0;
    while (i < p.len) {
        while (i < p.len and (p[i] == '/' or p[i] == '\\')) : (i += 1) {}
        const start = i;
        while (i < p.len and p[i] != '/' and p[i] != '\\') : (i += 1) {}
        if (std.mem.eql(u8, p[start..i], "..")) return true;
    }
    return false;
}

fn extractFieldRawJson(doc: []const u8, field_name: []const u8) ?[]const u8 {
    var cursor: rpc.scanner.Cursor = .{ .input = doc };
    var iter = cursor.beginObject(64) catch return null;
    defer cursor.leaveContainer();

    while (true) {
        var scratch_buf: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
        const key_opt = iter.nextKey(fba.allocator()) catch return null;
        const key = key_opt orelse return null;

        cursor.skipWhitespace();
        const val_start = cursor.pos;
        cursor.skipValue(64) catch return null;
        if (std.mem.eql(u8, key.slice, field_name)) {
            return cursor.input[val_start..cursor.pos];
        }
    }
}

test "ProtocolRouter enforces Invoke-Key & Origin, percent-decodes plugin commands, and blocks asset traversal" {
    var rec = core.RecordingHost.init(testing.allocator);
    defer rec.deinit();
    const win = try rec.host().createWindow(.{ .label = "main" });

    const AppCmds = struct {
        pub fn greet(args: struct { who: []const u8 }) []const u8 {
            return args.who;
        }
    };
    const S = rpc.Schema(.{ .root = AppCmds });
    var bound = S.bind(.{});

    const assets: web.Assets = .{
        .entries = &.{
            .{ .path = "/index.html", .bytes = "<html><head></head><body>Hi</body></html>" },
            .{ .path = "/voice.bin", .bytes = "0123456789ABCDEF" },
        },
    };

    const router = ProtocolRouter.init(testing.allocator, testing.io, .{
        .invoke_key = "super-secret-invoke-key",
        .assets = &assets,
        .inject_bootstrap_into_html = true,
        .asset_allow_globs = &.{"allowed/**"},
    }, bound.handler());

    // 1. Wrong Invoke-Key -> 403 Forbidden!
    var bad_key = router.handleRequest(rec.host(), .{
        .window_id = win,
        .method = "POST",
        .uri = "ipc://localhost/greet",
        .headers = &.{.{ .name = "Tauri-Invoke-Key", .value = "wrong-key" }},
        .body = "{\"who\":\"attacker\"}",
    });
    defer bad_key.body.deinit();
    try testing.expectEqual(@as(u16, 403), bad_key.status_code);
    try testing.expectEqualStrings("error", bad_key.tauri_response.?);

    // 2. Evil Origin -> 403 Forbidden even if Invoke-Key somehow leaked!
    var bad_origin = router.handleRequest(rec.host(), .{
        .window_id = win,
        .method = "POST",
        .uri = "ipc://localhost/greet",
        .headers = &.{
            .{ .name = "Tauri-Invoke-Key", .value = "super-secret-invoke-key" },
            .{ .name = "Origin", .value = "https://evil.example" },
        },
        .body = "{\"who\":\"attacker\"}",
    });
    defer bad_origin.body.deinit();
    try testing.expectEqual(@as(u16, 403), bad_origin.status_code);

    // 3. Valid IPC call (Windows sub-origin URL style also works!) -> 200 OK!
    var ok_ipc = router.handleRequest(rec.host(), .{
        .window_id = win,
        .method = "POST",
        .uri = "http://ipc.localhost/greet",
        .headers = &.{
            .{ .name = "Tauri-Invoke-Key", .value = "super-secret-invoke-key" },
            .{ .name = "Origin", .value = "http://tauri.localhost" },
        },
        .body = "{\"who\":\"Z-Ts\"}",
    });
    defer ok_ipc.body.deinit();
    try testing.expectEqual(@as(u16, 200), ok_ipc.status_code);
    try testing.expectEqualStrings("ok", ok_ipc.tauri_response.?);
    try testing.expectEqualStrings("\"Z-Ts\"", ok_ipc.body.slice());

    // 4. `tauri://localhost/deep/route` SPA fallback + inline bootstrap `<script>` + HTTP 206 Range!
    var html_res = router.handleRequest(rec.host(), .{
        .window_id = win,
        .method = "GET",
        .uri = "tauri://localhost/deep/route",
    });
    defer html_res.body.deinit();
    try testing.expectEqual(@as(u16, 200), html_res.status_code);
    try testing.expect(std.mem.indexOf(u8, html_res.body.slice(), "__TAURI_INTERNALS__") != null);

    var range_res = router.handleRequest(rec.host(), .{
        .window_id = win,
        .method = "GET",
        .uri = "tauri://localhost/voice.bin",
        .headers = &.{.{ .name = "Range", .value = "bytes=4-9" }},
    });
    defer range_res.body.deinit();
    try testing.expectEqual(@as(u16, 206), range_res.status_code);
    try testing.expectEqualStrings("456789", range_res.body.slice());

    // 5. `asset://localhost/allowed/../../etc/passwd` path traversal -> 403 Forbidden!
    var trav = router.handleRequest(rec.host(), .{
        .window_id = win,
        .method = "GET",
        .uri = "asset://localhost/allowed%2F..%2F..%2Fetc%2Fpasswd",
    });
    defer trav.body.deinit();
    try testing.expectEqual(@as(u16, 403), trav.status_code);
}
