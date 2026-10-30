//! Embedded HTTP/1.1 + RPC + SSE Bridge Server (`src/bridge/server.zig`).
//!
//! Pure Zig (`std.Io.net` + `std.http.Server`, `link_libc = false`) live transport that serves:
//! - `GET` / `HEAD` `/*` -> Static/dynamic assets via `zts_web.Assets` with automatic `<head>`
//!   bootstrap `<script>` injection, `HttpOnly; SameSite=Strict` session cookie issuance, SPA
//!   fallback, and full RFC 9110 `206 Partial Content` / `416` media byte-range streaming.
//! - `POST /__zts_ipc__/<cmd>` -> Triple-verified (`Origin` + `Cookie` + `Tauri-Invoke-Key`)
//!   RPC dispatch into `zts_rpc.Handler` (JSON & raw `application/octet-stream`, `Tauri-Response: ok|error`).
//! - `GET /__zts_events__` -> Authenticated real-time Server-Sent Events (`emit`, `eval`, `window`, custom).
//!
//! Depends ONLY on `zts_foundation`, `zts_web`, and `zts_rpc` — zero OS GUI / WebView dependencies,
//! so external engines and streaming/overlay tools can link `zts_bridge` standalone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const testing = std.testing;

const foundation = @import("zts_foundation");
const web = @import("zts_web");
const rpc = @import("zts_rpc");

const auth = @import("auth.zig");
const js_init = @import("js_init.zig");
const sse = @import("sse.zig");

/// Path prefix of the RPC endpoint (`POST /__zts_ipc__/<command>`). A distinct prefix means the
/// router can never shadow a real asset.
pub const ipc_prefix = "/__zts_ipc__/";
/// Path of the Server-Sent-Events stream (`GET /__zts_events__`) that carries `emit()` traffic from
/// the Zig side to the browser.
pub const sse_path = "/__zts_events__";

/// `BridgeServer` settings. `port = 0` asks the OS for a free port, which is what tests use to avoid
/// collisions; the preview server binds `0.0.0.0` so a container can publish it.
pub const Config = struct {
    /// Bind IP literal (`"127.0.0.1"` for local desktop/tests; `"0.0.0.0"` for container/cloud previews).
    host: []const u8 = "127.0.0.1",
    /// TCP port (`0` selects an OS-assigned ephemeral port queryable via `server.port()`).
    port: u16 = 0,
    /// Embedded / filesystem Web asset table (`206` Range + SPA routing).
    assets: web.Assets = .{},
    /// Optional type-erased RPC command router (`zts_rpc.Schema(...).bind(...).handler()`).
    rpc_handler: ?rpc.Handler = null,
    /// Cross-origin protection policy (defaults to `.same_host`).
    origin_policy: auth.OriginPolicy = .same_host,
    /// Maximum accepted request payload size in bytes (default: 16 MiB).
    max_body_bytes: usize = 16 * 1024 * 1024,
    /// Optional domain-specific environment pointer injected into every `rpc.Ctx` (`Ctx.withEnv`).
    env_ptr: ?*anyopaque = null,
    env_type_id: usize = 0,

    /// Returns a copy of `Config` that injects `ptr` (`*T`) into every `rpc.Ctx`.
    pub fn withEnv(self: Config, ptr: anytype) Config {
        var dummy = rpc.Ctx{ .io = undefined, .scratch = undefined };
        dummy = dummy.withEnv(ptr);
        var copy = self;
        copy.env_ptr = dummy.env_ptr;
        copy.env_type_id = dummy.env_type_id;
        return copy;
    }
};

const ExtractedHeaders = struct {
    origin: ?[]const u8 = null,
    host: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    invoke_key: ?[]const u8 = null,
    range: ?[]const u8 = null,
};

/// The Live Preview server: static assets + `206` range + `ipc://` RPC + SSE, all in pure Zig with no
/// libc. Runs the same command handlers as the desktop app, so `zig build preview` exercises the real
/// code path.
pub const BridgeServer = struct {
    allocator: Allocator,
    io: Io,
    config: Config,
    security: auth.SecurityState,
    bootstrap_html: []u8,
    sse_hub: sse.SseHub,
    conn_mu: Io.Mutex = .init,
    conn_done: Io.Condition = .init,
    active_workers: usize = 0,
    active_conns: foundation.HandlePool(Io.net.Stream, .bridge_conn) = .empty,
    net_server: Io.net.Server,
    bound_port: u16,
    stopping: std.atomic.Value(bool) = .init(false),
    stopped: bool = false,
    accept_thread: std.Thread = undefined,

    /// Allocates, binds, and starts the dedicated accept OS thread immediately.
    /// Spawns lightweight OS threads per connection so long-lived SSE streams (`EventSource`)
    /// and HTTP/1.1 Keep-Alive pools NEVER starve low-core (`2 vCPU`) `std.Io.Threaded` pools!
    pub fn start(allocator: Allocator, io: Io, config: Config) !*BridgeServer {
        const bind_addr = try Io.net.IpAddress.parse(config.host, config.port);
        var net_srv = try bind_addr.listen(io, .{
            .reuse_address = config.port != 0,
            .mode = .stream,
            .protocol = .tcp,
        });
        errdefer net_srv.deinit(io);

        const actual_port = net_srv.socket.address.getPort();
        const security = auth.SecurityState.initRandom(io, config.origin_policy);
        const bootstrap_html = try js_init.allocBootstrapScript(allocator, &security.invoke_key);
        errdefer allocator.free(bootstrap_html);

        const self = try allocator.create(BridgeServer);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .security = security,
            .bootstrap_html = bootstrap_html,
            .sse_hub = sse.SseHub.init(allocator),
            .net_server = net_srv,
            .bound_port = actual_port,
        };

        self.accept_thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, acceptLoop, .{self});
        return self;
    }

    /// Gracefully wakes the accept thread + all active HTTP Keep-Alive & SSE streams, joins all
    /// worker threads deterministically, and releases all server memory and file descriptors.
    pub fn stopAndDeinit(self: *BridgeServer) void {
        const io = self.io;
        if (!self.stopped) {
            self.stopped = true;
            self.stopping.store(true, .release);

            // 1. Unblock all active SSE client writers AND Keep-Alive readers immediately.
            self.sse_hub.closeAll(io);
            {
                self.conn_mu.lockUncancelable(io);
                defer self.conn_mu.unlock(io);
                var it = self.active_conns.iterator();
                while (it.next()) |slot| {
                    slot.value_ptr.*.shutdown(io, .both) catch {};
                }
            }

            // 2. Wake blocking `accept()` reliably across Linux, macOS, AND Windows Winsock2
            //    via a fast loopback poke and join `accept_thread` BEFORE closing the listener
            //    handle (preventing Windows AFD `NTSTATUS=0xc0000008 INVALID_HANDLE` noise).
            const wake_addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.bound_port) };
            if (wake_addr.connect(io, .{ .mode = .stream })) |wake_stream| {
                wake_stream.close(io);
                self.accept_thread.join();
                self.net_server.socket.close(io);
            } else |_| {
                self.net_server.socket.close(io);
                self.accept_thread.join();
            }
        }

        self.active_conns.deinit(self.allocator);
        self.sse_hub.deinit();
        self.allocator.free(self.bootstrap_html);
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    pub inline fn port(self: *const BridgeServer) u16 {
        return self.bound_port;
    }

    /// Attaches or updates the RPC handler after server creation.
    pub fn setRpcHandler(self: *BridgeServer, handler: rpc.Handler) void {
        self.config.rpc_handler = handler;
    }

    /// Attaches a typed environment pointer (`*T`) injected into every incoming `rpc.Ctx`.
    pub fn setEnv(self: *BridgeServer, ptr: anytype) void {
        self.config = self.config.withEnv(ptr);
    }

    pub fn baseUrl(self: *const BridgeServer, buf: *[64]u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.bound_port}) catch unreachable;
    }

    pub inline fn sessionToken(self: *const BridgeServer) *const [auth.token_hex_len]u8 {
        return &self.security.session_token;
    }

    pub inline fn invokeKey(self: *const BridgeServer) *const [auth.token_hex_len]u8 {
        return &self.security.invoke_key;
    }

    pub fn emitEvent(self: *BridgeServer, event_name: []const u8, json_payload: []const u8) Allocator.Error!usize {
        return self.sse_hub.publishEmit(self.io, event_name, json_payload);
    }

    pub fn evalJs(self: *BridgeServer, js_source: []const u8) Allocator.Error!usize {
        return self.sse_hub.publishEval(self.io, js_source);
    }

    pub fn broadcastWindowTitle(self: *BridgeServer, title: []const u8) Allocator.Error!usize {
        return self.sse_hub.publishWindowTitle(self.io, title);
    }

    pub fn broadcastRawSse(self: *BridgeServer, event_type: []const u8, data: []const u8) Allocator.Error!usize {
        return self.sse_hub.publishRaw(self.io, event_type, data);
    }

    fn acceptLoop(self: *BridgeServer) void {
        defer {
            self.conn_mu.lockUncancelable(self.io);
            while (self.active_workers > 0) {
                self.conn_done.waitUncancelable(self.io, &self.conn_mu);
            }
            self.conn_mu.unlock(self.io);
        }

        while (!self.stopping.load(.acquire)) {
            const stream = self.net_server.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => break,
            };

            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                break;
            }

            self.conn_mu.lockUncancelable(self.io);
            const conn_id = self.active_conns.acquire(self.allocator, stream) catch {
                self.conn_mu.unlock(self.io);
                stream.close(self.io);
                continue;
            };
            self.active_workers += 1;
            self.conn_mu.unlock(self.io);

            if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, handleConnection, .{ self, stream, conn_id })) |t| {
                t.detach();
            } else |_| {
                self.conn_mu.lockUncancelable(self.io);
                _ = self.active_conns.release(conn_id) catch {};
                self.active_workers -= 1;
                if (self.active_workers == 0) self.conn_done.broadcast(self.io);
                self.conn_mu.unlock(self.io);
                stream.close(self.io);
            }
        }
    }

    fn handleConnection(
        self: *BridgeServer,
        stream: Io.net.Stream,
        conn_id: foundation.Handle(.bridge_conn),
    ) void {
        defer {
            stream.close(self.io);
            self.conn_mu.lockUncancelable(self.io);
            _ = self.active_conns.release(conn_id) catch {};
            self.active_workers -= 1;
            if (self.active_workers == 0) self.conn_done.broadcast(self.io);
            self.conn_mu.unlock(self.io);
        }

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var net_reader = stream.reader(self.io, &read_buf);
        var net_writer = stream.writer(self.io, &write_buf);
        var http_server = http.Server.init(&net_reader.interface, &net_writer.interface);

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();

        while (!self.stopping.load(.acquire)) {
            _ = scratch_arena.reset(.retain_capacity);
            const scratch = scratch_arena.allocator();

            var req = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => return,
            };

            // Copy request metadata BEFORE reading body (`readerExpectContinue` invalidates `req.head` strings!).
            const method = req.head.method;
            const content_length = req.head.content_length;
            const target = scratch.dupe(u8, req.head.target) catch return;
            const hdrs = extractHeaders(scratch, &req) catch return;

            const keep_alive = self.routeRequest(stream, &req, scratch, method, content_length, target, hdrs) catch return;
            if (!keep_alive) return;
        }
    }

    fn extractHeaders(scratch: Allocator, req: *http.Server.Request) Allocator.Error!ExtractedHeaders {
        var out: ExtractedHeaders = .{};
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
                out.origin = try scratch.dupe(u8, h.value);
            } else if (std.ascii.eqlIgnoreCase(h.name, "host")) {
                out.host = try scratch.dupe(u8, h.value);
            } else if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
                out.cookie = try scratch.dupe(u8, h.value);
            } else if (std.ascii.eqlIgnoreCase(h.name, "tauri-invoke-key") or std.ascii.eqlIgnoreCase(h.name, "x-zts-invoke-key")) {
                out.invoke_key = try scratch.dupe(u8, h.value);
            } else if (std.ascii.eqlIgnoreCase(h.name, "range")) {
                out.range = try scratch.dupe(u8, h.value);
            }
        }
        return out;
    }

    fn routeRequest(
        self: *BridgeServer,
        stream: Io.net.Stream,
        req: *http.Server.Request,
        scratch: Allocator,
        method: http.Method,
        content_length: ?u64,
        raw_target: []const u8,
        hdrs: ExtractedHeaders,
    ) !bool {
        const path_only = if (std.mem.indexOfScalar(u8, raw_target, '?')) |q| raw_target[0..q] else raw_target;

        // 1. Real-time Server-Sent Events stream (`GET /__zts_events__`)
        if (std.mem.eql(u8, path_only, sse_path)) {
            if (method != .GET) {
                try req.respond("{\"code\":\"MethodNotAllowed\"}", .{
                    .status = .method_not_allowed,
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
                });
                return false;
            }
            if (!self.security.verifySseRequest(raw_target, hdrs.origin, hdrs.host, hdrs.cookie, hdrs.invoke_key)) {
                try respondForbidden(req);
                return false;
            }
            try self.serveSseStream(stream, req);
            return false;
        }

        // 2. Authenticated RPC Command Endpoint (`POST /__zts_ipc__/<cmd>`)
        if (std.mem.startsWith(u8, path_only, ipc_prefix)) {
            if (method != .POST) {
                try req.respond("{\"code\":\"MethodNotAllowed\"}", .{
                    .status = .method_not_allowed,
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
                });
                return false;
            }

            // Triple CSRF defense BEFORE allocating/reading a single byte of request body!
            if (!self.security.verifyIpcRequest(hdrs.origin, hdrs.host, hdrs.cookie, hdrs.invoke_key)) {
                try respondForbidden(req);
                return false;
            }

            if (content_length) |cl| {
                if (cl > self.config.max_body_bytes) {
                    try req.respond("{\"code\":\"PayloadTooLarge\"}", .{
                        .status = .payload_too_large,
                        .keep_alive = false,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "application/json" },
                            .{ .name = "tauri-response", .value = "error" },
                        },
                    });
                    return false;
                }
            }

            const encoded_cmd = path_only[ipc_prefix.len..];
            var cmd_buf: [512]u8 = undefined;
            const cmd_name = auth.percentDecodeSegment(&cmd_buf, encoded_cmd) catch {
                try req.respond("{\"code\":\"BadCommandEncoding\"}", .{
                    .status = .bad_request,
                    .keep_alive = false,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                        .{ .name = "tauri-response", .value = "error" },
                    },
                });
                return false;
            };

            const handler = self.config.rpc_handler orelse {
                try req.respond("{\"code\":\"NoRpcHandler\"}", .{
                    .status = .not_found,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                        .{ .name = "tauri-response", .value = "error" },
                    },
                });
                return true;
            };

            var body_read_buf: [4096]u8 = undefined;
            const body_reader = try req.readerExpectContinue(&body_read_buf);
            const body_bytes = body_reader.allocRemaining(scratch, .limited(self.config.max_body_bytes)) catch |err| switch (err) {
                error.StreamTooLong => {
                    try req.respond("{\"code\":\"PayloadTooLarge\"}", .{
                        .status = .payload_too_large,
                        .keep_alive = false,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "application/json" },
                            .{ .name = "tauri-response", .value = "error" },
                        },
                    });
                    return false;
                },
                else => return err,
            };

            var rpc_ctx = rpc.Ctx{
                .io = self.io,
                .scratch = scratch,
                .origin = hdrs.origin orelse "",
                .raw_body = body_bytes,
                .env_ptr = self.config.env_ptr,
                .env_type_id = self.config.env_type_id,
            };

            var rpc_resp = handler.dispatch(self.allocator, &rpc_ctx, cmd_name, body_bytes);
            defer rpc_resp.deinit();

            const tauri_status_hdr = if (rpc_resp.status == .ok) "ok" else "error";
            const http_status: http.Status = @fromBackingInt(@intCast(rpc_resp.http_code));

            try req.respond(rpc_resp.body.slice(), .{
                .status = http_status,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = rpc_resp.content_type },
                    .{ .name = "tauri-response", .value = tauri_status_hdr },
                    .{ .name = "cache-control", .value = "no-store" },
                },
            });
            return true;
        }

        // 3. Static / Embedded / Fallback Web Assets + `206` Media Streaming (`GET` / `HEAD`)
        if (method != .GET and method != .HEAD) {
            try req.respond("Method Not Allowed", .{
                .status = .method_not_allowed,
                .keep_alive = false,
            });
            return false;
        }

        var asset_resp = try self.config.assets.resolve(self.allocator, path_only, .{
            .range_header = hdrs.range,
            .spa_fallback = true,
            .html_head_injection = self.bootstrap_html,
        });
        defer asset_resp.deinit();

        var hdr_list: [5]http.Header = undefined;
        var hdr_count: usize = 0;

        hdr_list[hdr_count] = .{ .name = "content-type", .value = asset_resp.mime_type };
        hdr_count += 1;
        hdr_list[hdr_count] = .{ .name = "accept-ranges", .value = "bytes" };
        hdr_count += 1;

        var cookie_buf: [160]u8 = undefined;
        if (!self.security.hasValidSessionCookie(hdrs.cookie)) {
            hdr_list[hdr_count] = .{
                .name = "set-cookie",
                .value = self.security.setCookieHeaderValue(&cookie_buf),
            };
            hdr_count += 1;
        }

        var range_buf: [64]u8 = undefined;
        if (asset_resp.contentRangeHeader(&range_buf)) |cr_val| {
            hdr_list[hdr_count] = .{ .name = "content-range", .value = cr_val };
            hdr_count += 1;
        }

        const status_enum: http.Status = @fromBackingInt(@intCast(@backingInt(asset_resp.status)));
        try req.respond(asset_resp.body.slice(), .{
            .status = status_enum,
            .extra_headers = hdr_list[0..hdr_count],
        });
        return true;
    }

    fn serveSseStream(self: *BridgeServer, stream: Io.net.Stream, req: *http.Server.Request) !void {
        const sub = self.sse_hub.subscribe(self.io, stream) catch return;
        defer self.sse_hub.unsubscribe(self.io, sub.id);

        var sse_buf: [1024]u8 = undefined;
        var bw = try req.respondStreaming(&sse_buf, .{
            .respond_options = .{
                .status = .ok,
                .keep_alive = false,
                .transfer_encoding = .none,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
                    .{ .name = "cache-control", .value = "no-cache, no-store" },
                    .{ .name = "x-accel-buffering", .value = "no" },
                },
            },
        });

        try bw.writer.writeAll(": connected\n\n");
        try bw.writer.flush();
        try bw.flush();

        while (sub.entry.queue.waitPop(self.io) catch null) |frame| {
            defer self.allocator.free(frame);
            bw.writer.writeAll(frame) catch break;
            bw.writer.flush() catch break;
            bw.flush() catch break;
        }
    }

    fn respondForbidden(req: *http.Server.Request) !void {
        try req.respond("{\"code\":\"Forbidden\"}", .{
            .status = .forbidden,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "tauri-response", .value = "error" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    }
};

// ============================================================================
// End-to-End Integration Test Suite (Live TCP Ephemeral Port + Node `fetch` + SSE + CSRF)
// ============================================================================

test "BridgeServer E2E on port 0: HTML bootstrap injection, 206 media seeking, JSON/Binary RPC, live SSE & 6 CSRF attacks -> 403" {
    const AppState = struct {
        total: i53 = 100,
    };

    const BridgeRef = struct {
        srv: ?*BridgeServer = null,
    };

    const AppCmds = struct {
        pub fn add_amount(state: *AppState, args: struct { delta: i53 }) error{NegativeDelta}!i53 {
            if (args.delta < 0) return error.NegativeDelta;
            state.total += args.delta;
            return state.total;
        }
    };

    const BlobPlugin = struct {
        pub const rpc_prefix = "blob:";

        pub fn png_magic() rpc.Bytes {
            return .init("\x89PNG\r\n\x1a\n");
        }
    };

    const WindowPlugin = struct {
        pub const rpc_prefix = "plugin:window|";

        pub fn set_title(ctx: *rpc.Ctx, args: struct { title: []const u8 }) !void {
            const ref = try ctx.requireEnv(BridgeRef);
            if (ref.srv) |srv| {
                _ = try srv.broadcastWindowTitle(args.title);
                _ = try srv.emitEvent("title:updated", "{\"ok\":true}");
                _ = try srv.evalJs("globalThis.__ranEval = 1;");
            }
        }
    };

    const TestRpc = rpc.Schema(.{
        .app = .{ .State = AppState, .Cmds = AppCmds },
        .blob = BlobPlugin,
        .window = WindowPlugin,
    });

    var state = AppState{};
    var ref = BridgeRef{};
    var router = TestRpc.bind(.{ .app = &state });

    const static_entries: []const web.StaticAsset = &.{
        .{
            .path = "/index.html",
            .bytes = "<!doctype html><html><head><title>Z-Ts Bridge</title></head><body><h1>Hello</h1></body></html>",
        },
        .{
            .path = "/media/sample.mp4",
            .bytes = "AAAA_VIDEO_PAYLOAD_0123456789_ZZZZ",
        },
    };

    const srv = try BridgeServer.start(
        testing.allocator,
        testing.io,
        (Config{
            .host = "127.0.0.1",
            .port = 0, // Ephemeral OS port!
            .assets = .{ .entries = static_entries },
            .rpc_handler = router.handler(),
        }).withEnv(&ref),
    );
    defer srv.stopAndDeinit();
    ref.srv = srv;

    try testing.expect(srv.port() > 0);

    var url_buf: [64]u8 = undefined;
    const base_url = srv.baseUrl(&url_buf);

    // Run real Node.js `v22` client executing real HTTP/1.1 `fetch`, `ReadableStream` SSE, and CSRF attack vectors!
    const res = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "node", "tests/bridge/verify_bridge_e2e.ts", base_url },
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("\n=== Bridge E2E FAILED ===\nstdout:\n{s}\nstderr:\n{s}\n", .{ res.stdout, res.stderr });
        return error.BridgeE2eFailed;
    }

    try testing.expectEqual(@as(i53, 150), state.total);
}
