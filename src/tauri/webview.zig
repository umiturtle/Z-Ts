//! `plugin:webview|*` — multi-window / multi-webview wire commands (`src/tauri/webview.zig`).
//!
//! Implements the exact commands the **unmodified** `@tauri-apps/api` v2 `webviewWindow` /
//! `webview` / `window` packages emit (verified against `@tauri-apps/api@2.9.0`):
//!
//! | JS | Command | Payload |
//! |---|---|---|
//! | `new WebviewWindow(label, opts)` | `plugin:webview\|create_webview_window` | `{ options: { ...opts, label } }` |
//! | `new Window(label, opts)` | `plugin:window\|create` | `{ options: { ...opts, label } }` |
//! | `new Webview(win, label, opts)` | `plugin:webview\|create_webview` | `{ windowLabel, options: { ...opts, label } }` |
//! | `getAllWebviews()` | `plugin:webview\|get_all_webviews` | — → `[{ label, windowLabel }]` |
//! | `getAllWebviewWindows()` | `plugin:window\|get_all_windows` | — → `[label]` |
//!
//! `WebviewWindow` creation goes through `Host.createWindow()` (or the runtime's window factory),
//! so the new window gets the same native backend and per-label bootstrap as the main window on
//! Linux / macOS / Windows — no OS-specific branches in this file.
//!
//! Upstream gates `new Webview()` behind an `unstable` Cargo feature. ziggurats implements it as a
//! **child `<iframe>` inside the parent window**, created through the existing `Host.evalJs`
//! vtable entry. That is one behaviour on all three OSes, needs no new OS object, and makes the
//! webview visible to `getAllWebviews()`, `Webview.getByLabel()` and webview-targeted events.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");
const window_mod = @import("window.zig");

/// Errors surfaced as HTTP 400 by `zts_rpc` when a creation command is malformed or unsafe.
/// Shares the window plugin's error set: both namespaces call `window.specFromOptions()` /
/// `window.openWindow()`, so a new diagnostic there must never be silently lost here.
pub const WebviewError = window_mod.WindowPluginError;

/// `get_all_webviews` wire DTO. `window_label` is encoded as `windowLabel` by `zts_rpc`.
pub const WebviewDto = struct {
    /// Webview label (the JS-visible identifier).
    label: []const u8,
    /// Label of the window hosting the webview.
    window_label: []const u8,
};

const ChildWebview = struct {
    label: []u8,
    window_label: []u8,
    window_id: core.WindowId,
    url: []u8,

    fn deinit(self: *ChildWebview, allocator: Allocator) void {
        allocator.free(self.label);
        allocator.free(self.window_label);
        allocator.free(self.url);
        self.* = undefined;
    }
};

/// Live webviews. Primary webviews are derived from `WindowRegistry` (one per window, same label),
/// so creating a window from JS automatically makes it visible to `getAllWebviews()`. Only child
/// webviews created by `new Webview()` need their own bookkeeping.
pub const WebviewRegistry = struct {
    /// Allocator owning child labels / URLs.
    allocator: Allocator,
    /// IO reactor used by the mutex.
    io: Io,
    /// Windows created by the app or by `plugin:window|create` / `create_webview_window`.
    windows: *window_mod.WindowRegistry,
    /// Guards `children`.
    mu: Io.Mutex = .init,
    /// Webviews attached to an existing window by `new Webview()`.
    children: std.ArrayList(ChildWebview) = .empty,

    /// Creates an empty registry bound to `WindowRegistry`.
    pub fn init(allocator: Allocator, io: Io, windows: *window_mod.WindowRegistry) WebviewRegistry {
        return .{ .allocator = allocator, .io = io, .windows = windows };
    }

    /// Frees every owned child-webview label and URL.
    pub fn deinit(self: *WebviewRegistry) void {
        for (self.children.items) |*child| child.deinit(self.allocator);
        self.children.deinit(self.allocator);
    }

    /// Registers (or replaces) a child webview. Caller owns nothing afterwards.
    pub fn registerChild(
        self: *WebviewRegistry,
        label: []const u8,
        window_label: []const u8,
        window_id: core.WindowId,
        url: []const u8,
    ) Allocator.Error!void {
        const lbl = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(lbl);
        const wlbl = try self.allocator.dupe(u8, window_label);
        errdefer self.allocator.free(wlbl);
        const u = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(u);

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.children.items) |*existing| {
            if (std.mem.eql(u8, existing.label, label)) {
                existing.deinit(self.allocator);
                existing.* = .{ .label = lbl, .window_label = wlbl, .window_id = window_id, .url = u };
                return;
            }
        }
        try self.children.append(self.allocator, .{
            .label = lbl,
            .window_label = wlbl,
            .window_id = window_id,
            .url = u,
        });
    }

    /// Drops every child webview of a closed window.
    pub fn unregisterWindow(self: *WebviewRegistry, id: core.WindowId) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var i: usize = 0;
        while (i < self.children.items.len) {
            if (self.children.items[i].window_id.eql(id)) {
                self.children.items[i].deinit(self.allocator);
                _ = self.children.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Resolves a webview label to the label of the window that hosts it. Primary webviews share
    /// their window's label; child webviews (`new Webview()`) point at their parent window.
    pub fn parentWindowLabel(self: *WebviewRegistry, label: []const u8) ?[]const u8 {
        if (self.windows.resolveId(label, core.WindowId.invalid) != null) return label;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.label, label)) return child.window_label;
        }
        return null;
    }

    /// Whether a webview (primary or child) with this label exists.
    pub fn hasLabel(self: *WebviewRegistry, label: []const u8) bool {
        if (self.windows.resolveId(label, core.WindowId.invalid) != null) return true;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.label, label)) return true;
        }
        return false;
    }

    /// Wire DTOs for every live webview, in creation order (primary windows first).
    pub fn all(self: *WebviewRegistry, allocator: Allocator) Allocator.Error![]const WebviewDto {
        var out: std.ArrayList(WebviewDto) = .empty;
        errdefer out.deinit(allocator);

        self.windows.mu.lockUncancelable(self.io);
        defer self.windows.mu.unlock(self.io);
        for (self.windows.entries.items) |win| {
            try out.append(allocator, .{
                .label = try allocator.dupe(u8, win.label),
                .window_label = try allocator.dupe(u8, win.label),
            });
        }

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.children.items) |child| {
            try out.append(allocator, .{
                .label = try allocator.dupe(u8, child.label),
                .window_label = try allocator.dupe(u8, child.window_label),
            });
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Parses the raw `options` object of a `plugin:webview|*` command.
fn parseOptions(allocator: Allocator, raw: []const u8) WebviewError!std.json.Value {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{}) catch
        return error.MalformedOptions;
    if (parsed != .object) return error.MalformedOptions;
    return parsed;
}

/// JSON-escapes a string as a JS string literal (a JSON string is valid JavaScript).
fn jsString(allocator: Allocator, value: []const u8) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Builds the `document.createElement("iframe")` snippet. All attacker-controlled values go
/// through `jsString`, so `label` / `url` cannot break out of the script string.
fn iframeScript(
    allocator: Allocator,
    label: []const u8,
    url: []const u8,
    opts: std.json.Value,
) WebviewError![]u8 {
    const h = window_mod.JsonHelpers;
    const lbl = try jsString(allocator, label);
    const src = try jsString(allocator, url);
    const x = h.number(opts, &.{"x"}) orelse 0;
    const y = h.number(opts, &.{"y"}) orelse 0;
    const w = h.number(opts, &.{"width"}) orelse 0;
    const ht = h.number(opts, &.{"height"}) orelse 0;
    const style = if (w > 0 and ht > 0)
        try std.fmt.allocPrint(allocator, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;border:0", .{ x, y, w, ht })
    else
        try allocator.dupe(u8, "position:absolute;left:0;top:0;width:100%;height:100%;border:0");
    const css = try jsString(allocator, style);
    return std.fmt.allocPrint(allocator,
        \\(function(){{var l={s},u={s},s={s};var f=document.querySelector("[data-zts-webview-label="+JSON.stringify(l)+"]");if(!f){{f=document.createElement("iframe");f.setAttribute("data-zts-webview-label",l);f.style.cssText=s;document.body.appendChild(f);}}f.src=u;}})()
    , .{ lbl, src, css });
}

/// Resolves a webview label to the parent window and the `Host` that can evaluate JS in it.
const WebviewHostTarget = struct {
    host: core.Host,
    win_id: core.WindowId,
    label: []const u8,
    is_child: bool,
};

fn hostForWebview(ctx: *rpc.Ctx, reg: *WebviewRegistry, label: ?[]const u8) WebviewError!WebviewHostTarget {
    const wanted = label orelse return error.UnknownWindowLabel;
    const parent = reg.parentWindowLabel(wanted) orelse return error.UnknownWindowLabel;
    const win_id = reg.windows.resolveId(parent, core.WindowId.invalid) orelse return error.UnknownWindowLabel;
    const call = ctx.getEnv(core.CallContext) orelse return error.MissingHostContext;
    return .{
        .host = call.host,
        .win_id = win_id,
        .label = wanted,
        .is_child = !std.mem.eql(u8, wanted, parent),
    };
}

/// Runs `code` inside the target webview. Child webviews are `<iframe>`s in the parent window, so
/// the script picks the iframe's `contentWindow` when present and falls back to the window itself.
fn evalInWebview(ctx: *rpc.Ctx, reg: *WebviewRegistry, label: ?[]const u8, code: []const u8) WebviewError!void {
    const t = try hostForWebview(ctx, reg, label);
    const lbl = try jsString(ctx.scratch, t.label);
    const src = try jsString(ctx.scratch, code);
    const script = try std.fmt.allocPrint(ctx.scratch,
        \\(function(){{var f=document.querySelector("[data-zts-webview-label="+JSON.stringify({s})+"]");var w=f&&f.contentWindow?f.contentWindow:window;w.eval({s});}})()
    , .{ lbl, src });
    t.host.evalJs(t.win_id, script) catch |err| switch (err) {
        error.Unsupported, error.WindowNotFound => {},
        else => return err,
    };
}

/// `plugin:webview|*` RPC command namespace (`Schema` key: `.tauri_webview`).
pub const Commands = struct {
    /// Wire prefix shared by every command in this namespace (`plugin:…|`).
    pub const rpc_prefix = "plugin:webview|";
    /// State type `zts_rpc` resolves for this namespace.
    pub const RpcState = WebviewRegistry;

    /// `plugin:webview|create_webview_window` — `new WebviewWindow(label, options)`.
    ///
    /// Upstream uses one label for both the native window and its single webview, so the window
    /// registry alone is enough for `getAllWebviews()` to report it.
    pub fn create_webview_window(
        ctx: *rpc.Ctx,
        reg: *WebviewRegistry,
        args: struct { options: rpc.RawJson },
    ) WebviewError!void {
        const spec = try window_mod.specFromOptions(ctx.scratch, args.options.raw);
        if (reg.hasLabel(spec.label)) return error.DuplicateLabel;
        const call_ctx = ctx.getEnv(core.CallContext);
        const host: ?core.Host = if (call_ctx) |c| c.host else null;
        _ = try window_mod.openWindow(reg.windows, host, spec);
    }

    /// `plugin:webview|create_webview` — `new Webview(window, label, options)`.
    ///
    /// Resolves the parent window by label, then asks the host to evaluate a script that mounts an
    /// `<iframe>` for the child view. A host without `evalJs` (`error.Unsupported`) still records
    /// the webview so `getAllWebviews()` / event targeting stay consistent — e.g. Live Preview.
    pub fn create_webview(
        ctx: *rpc.Ctx,
        reg: *WebviewRegistry,
        args: struct { window_label: ?[]const u8 = null, options: rpc.RawJson },
    ) WebviewError!void {
        const parent_label = args.window_label orelse return error.UnknownWindowLabel;
        const opts = try parseOptions(ctx.scratch, args.options.raw);
        const h = window_mod.JsonHelpers;
        const label = h.string(opts, &.{"label"}) orelse return error.InvalidLabel;
        if (!window_mod.isValidLabel(label)) return error.InvalidLabel;
        if (reg.hasLabel(label)) return error.DuplicateLabel;
        const url = try window_mod.normalizeUrl(ctx.scratch, h.string(opts, &.{"url"}));

        const fallback = core.WindowId.invalid;
        const win_id = reg.windows.resolveId(parent_label, fallback) orelse return error.UnknownWindowLabel;
        const call_ctx = ctx.getEnv(core.CallContext);
        if (call_ctx) |c| {
            const script = try iframeScript(ctx.scratch, label, url, opts);
            c.host.evalJs(win_id, script) catch |err| switch (err) {
                error.Unsupported, error.WindowNotFound => {},
                else => return err,
            };
        }
        try reg.registerChild(label, parent_label, win_id, url);
    }

    /// `plugin:webview|get_all_webviews` — `[{ label, windowLabel }]` for every live webview.
    pub fn get_all_webviews(ctx: *rpc.Ctx, reg: *WebviewRegistry) Allocator.Error![]const WebviewDto {
        return reg.all(ctx.scratch);
    }

    // ---- P1 #6: webview control ------------------------------------------------------------

    /// `plugin:webview|eval` — evaluate JavaScript inside the addressed webview.
    pub fn eval(ctx: *rpc.Ctx, reg: *WebviewRegistry, args: struct {
        label: ?[]const u8 = null,
        value: []const u8,
    }) WebviewError!void {
        try evalInWebview(ctx, reg, args.label, args.value);
    }

    /// `plugin:webview|reload`.
    pub fn reload(ctx: *rpc.Ctx, reg: *WebviewRegistry, args: struct { label: ?[]const u8 = null }) WebviewError!void {
        try evalInWebview(ctx, reg, args.label, "location.reload()");
    }

    /// `plugin:webview|print`.
    pub fn print(ctx: *rpc.Ctx, reg: *WebviewRegistry, args: struct { label: ?[]const u8 = null }) WebviewError!void {
        try evalInWebview(ctx, reg, args.label, "window.print()");
    }

    /// `plugin:webview|set_zoom` — a CSS zoom factor. Rejects non-finite / absurd values before
    /// they ever reach `evalJs`.
    pub fn set_zoom(ctx: *rpc.Ctx, reg: *WebviewRegistry, args: struct {
        label: ?[]const u8 = null,
        value: f64,
    }) WebviewError!void {
        if (!std.math.isFinite(args.value) or args.value < 0.1 or args.value > 5.0) return error.InvalidValue;
        const code = try std.fmt.allocPrint(ctx.scratch, "document.body.style.zoom=\"{d}\";", .{args.value});
        try evalInWebview(ctx, reg, args.label, code);
    }

    /// `plugin:webview|open_devtools`.
    pub fn open_devtools(ctx: *rpc.Ctx, reg: *WebviewRegistry, args: struct { label: ?[]const u8 = null }) WebviewError!void {
        const t = try hostForWebview(ctx, reg, args.label);
        t.host.openDevtools(t.win_id) catch |err| switch (err) {
            error.Unsupported, error.WindowNotFound => {},
            else => return err,
        };
        _ = reg.windows.setDevtoolsOpen(args.label, t.win_id, true);
    }

    /// `plugin:webview|close_devtools` — records the state; WebView2/WebKit/WKWebView expose no
    /// portable "close inspector" call, so the devtools window itself stays under OS control.
    pub fn close_devtools(ctx: *rpc.Ctx, reg: *WebviewRegistry, args: struct { label: ?[]const u8 = null }) WebviewError!void {
        const t = try hostForWebview(ctx, reg, args.label);
        _ = reg.windows.setDevtoolsOpen(args.label, t.win_id, false);
    }

    /// `plugin:webview|is_devtools_open`.
    pub fn is_devtools_open(_: *rpc.Ctx, reg: *WebviewRegistry, args: struct { label: ?[]const u8 = null }) bool {
        return reg.windows.devtoolsOpen(args.label, core.WindowId.invalid);
    }

    /// `plugin:webview|internal_toggle_devtools`.
    pub fn internal_toggle_devtools(ctx: *rpc.Ctx, reg: *WebviewRegistry, args: struct { label: ?[]const u8 = null }) WebviewError!void {
        if (is_devtools_open(ctx, reg, .{ .label = args.label })) {
            try close_devtools(ctx, reg, .{ .label = args.label });
        } else {
            try open_devtools(ctx, reg, .{ .label = args.label });
        }
    }

    /// `plugin:webview|clear_all_browsing_data` — capability-gated no-op. WebKitGTK, WKWebView
    /// and WebView2 have no identical clearing API, so ziggurats never pretends it wiped data;
    /// the command exists for wire compatibility and must be allowed explicitly.
    pub fn clear_all_browsing_data(_: *rpc.Ctx, _: *WebviewRegistry) void {}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestSchema = rpc.Schema(.{
    .tauri_window = window_mod.Commands,
    .tauri_webview = Commands,
});

fn testCtx(allocator: Allocator) rpc.Ctx {
    return rpc.Ctx.init(testing.io, allocator);
}

test "P0-1: label grammar, URL normalisation and option parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try testing.expect(window_mod.isValidLabel("settings"));
    try testing.expect(window_mod.isValidLabel("a-b/c:d_e"));
    try testing.expect(!window_mod.isValidLabel(""));
    try testing.expect(!window_mod.isValidLabel("has space"));
    try testing.expect(!window_mod.isValidLabel("javascript:alert(1)"));
    var too_long: [129]u8 = undefined;
    @memset(&too_long, 'a');
    try testing.expect(!window_mod.isValidLabel(&too_long));

    try testing.expectEqualStrings("tauri://localhost/", try window_mod.normalizeUrl(scratch, null));
    try testing.expectEqualStrings("tauri://localhost/page.html", try window_mod.normalizeUrl(scratch, "/page.html"));
    try testing.expectEqualStrings("https://example.com/x", try window_mod.normalizeUrl(scratch, "https://example.com/x"));
    try testing.expectError(error.InvalidUrl, window_mod.normalizeUrl(scratch, "javascript:alert(1)"));
    try testing.expectError(error.InvalidUrl, window_mod.normalizeUrl(scratch, "file:///etc/passwd"));

    const spec = try window_mod.specFromOptions(scratch,
        \\{"label":"editor","title":"Editor","width":1024,"height":768,"minWidth":400,"minHeight":300,"x":10,"y":20,"resizable":false,"decorations":false,"url":"editor.html","skipTaskbar":true,"unknownFutureOption":42}
    );
    try testing.expectEqualStrings("editor", spec.label);
    try testing.expectEqualStrings("Editor", spec.title);
    try testing.expectEqual(@as(f64, 1024), spec.size.width.v);
    try testing.expectEqual(@as(f64, 768), spec.size.height.v);
    try testing.expectEqual(@as(f64, 400), spec.min_size.?.width.v);
    try testing.expectEqual(@as(f64, 10), spec.position.?.x.v);
    try testing.expect(!spec.resizable);
    try testing.expect(!spec.decorations);
    try testing.expectEqualStrings("tauri://localhost/editor.html", spec.initial_url);

    try testing.expectError(error.InvalidLabel, window_mod.specFromOptions(scratch, "{}"));
    try testing.expectError(error.MalformedOptions, window_mod.specFromOptions(scratch, "not json"));
    try testing.expectError(error.InvalidUrl, window_mod.specFromOptions(scratch,
        \\{"label":"x","url":"data:text/html,hi"}
    ));
}

test "P0-1: new WebviewWindow creates a second window and getAllWebviews reports it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var host = core.RecordingHost.init(testing.allocator);
    defer host.deinit();
    var windows = window_mod.WindowRegistry.init(testing.allocator, testing.io);
    defer windows.deinit();
    var webviews = WebviewRegistry.init(testing.allocator, testing.io, &windows);
    defer webviews.deinit();

    var bound = TestSchema.bind(.{ .tauri_window = &windows, .tauri_webview = &webviews });
    var handler = bound.handler();
    var ctx = testCtx(scratch);
    var call = core.CallContext{ .host = host.host() };
    _ = &call;
    ctx = ctx.withEnv(&call);

    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:webview|create_webview_window",
            \\{"options":{"label":"settings","title":"Settings","width":640,"height":480,"url":"settings.html","center":true}}
        );
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        try testing.expectEqualStrings("null", r.body.slice());
    }
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:window|get_all_windows", "{}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        try testing.expect(std.mem.indexOf(u8, r.body.slice(), "settings") != null);
    }
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:webview|get_all_webviews", "{}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        try testing.expectEqualStrings("[{\"label\":\"settings\",\"windowLabel\":\"settings\"}]", r.body.slice());
    }
    // Duplicate label must be refused, not silently replaced.
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:webview|create_webview_window", "{\"options\":{\"label\":\"settings\"}}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
    // A hostile label is rejected before reaching the host.
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:window|create", "{\"options\":{\"label\":\"<script>\"}}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
}

test "P0-1: new Window and new Webview (child iframe) with error paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var host = core.RecordingHost.init(testing.allocator);
    defer host.deinit();
    var windows = window_mod.WindowRegistry.init(testing.allocator, testing.io);
    defer windows.deinit();
    var webviews = WebviewRegistry.init(testing.allocator, testing.io, &windows);
    defer webviews.deinit();
    var bound = TestSchema.bind(.{ .tauri_window = &windows, .tauri_webview = &webviews });
    var handler = bound.handler();
    var ctx = testCtx(scratch);
    var call = core.CallContext{ .host = host.host() };
    ctx = ctx.withEnv(&call);

    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:window|create", "{\"options\":{\"label\":\"docs\",\"title\":\"Docs\"}}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:webview|create_webview",
            \\{"windowLabel":"docs","options":{"label":"sidebar","url":"side.html","x":0,"y":0,"width":240,"height":600}}
        );
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:webview|get_all_webviews", "{}");
        defer r.deinit();
        try testing.expectEqualStrings(
            "[{\"label\":\"docs\",\"windowLabel\":\"docs\"},{\"label\":\"sidebar\",\"windowLabel\":\"docs\"}]",
            r.body.slice(),
        );
    }
    // evalJs was called with an iframe script containing the label & a safe URL.
    try testing.expect(host.eval_log.items.len >= 1);
    const script = host.eval_log.items[host.eval_log.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, script, "createElement(\"iframe\")") != null);
    try testing.expect(std.mem.indexOf(u8, script, "tauri://localhost/side.html") != null);
    try testing.expect(std.mem.indexOf(u8, script, "<script") == null);

    // Unknown parent window -> 400, no child registered.
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:webview|create_webview", "{\"windowLabel\":\"missing\",\"options\":{\"label\":\"x\"}}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
    // Duplicate webview label -> 400.
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:webview|create_webview", "{\"windowLabel\":\"docs\",\"options\":{\"label\":\"sidebar\"}}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
    // `javascript:` URL -> 400.
    {
        var r = handler.dispatch(testing.allocator, &ctx, "plugin:webview|create_webview", "{\"windowLabel\":\"docs\",\"options\":{\"label\":\"evil\",\"url\":\"javascript:alert(1)\"}}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
    // Missing host context -> 400 (no silent success).
    {
        var no_host = testCtx(scratch);
        var r = handler.dispatch(testing.allocator, &no_host, "plugin:window|create", "{\"options\":{\"label\":\"no-host\"}}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
}

test "P1: window events, scalar setters, monitor/DPI and webview control commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var host = core.RecordingHost.init(testing.allocator);
    defer host.deinit();
    var windows = window_mod.WindowRegistry.init(testing.allocator, testing.io);
    defer windows.deinit();
    var webviews = WebviewRegistry.init(testing.allocator, testing.io, &windows);
    defer webviews.deinit();
    var bus = @import("event.zig").EventBus.init(testing.allocator, testing.io);
    defer bus.deinit();
    var monitors = try @import("monitor.zig").MonitorRegistry.init(testing.allocator, testing.io);
    defer monitors.deinit();

    const win = try host.host().createWindow(.{ .label = "main" });
    try windows.registerWindow(win, .{ .label = "main" });

    const LabelCtx = struct {
        id: core.WindowId,
        fn lookup(ud: ?*anyopaque, alloc: Allocator, wid: core.WindowId) Allocator.Error!?[]u8 {
            _ = ud;
            _ = wid;
            return try alloc.dupe(u8, "main");
        }
    };
    var label_ctx = LabelCtx{ .id = win };
    bus.window_labels = LabelCtx.lookup;
    bus.window_labels_ctx = &label_ctx;
    bus.webview_parent = struct {
        fn parent(ud: ?*anyopaque, label: []const u8) ?[]const u8 {
            const reg: *WebviewRegistry = @ptrCast(@alignCast(ud.?));
            return reg.parentWindowLabel(label);
        }
    }.parent;
    bus.webview_parent_ctx = &webviews;
    windows.events = &bus;
    windows.monitors = &monitors;

    const event_mod = @import("event.zig");
    const P1Schema = rpc.Schema(.{
        .tauri_window = window_mod.Commands,
        .tauri_webview = Commands,
        .tauri_event = event_mod.Commands,
    });
    var bound = P1Schema.bind(.{
        .tauri_window = &windows,
        .tauri_webview = &webviews,
        .tauri_event = &bus,
    });
    var handler = bound.handler();
    var ctx = rpc.Ctx.init(testing.io, scratch);
    var call = core.CallContext{ .host = host.host(), .window_id = win };
    ctx = ctx.withEnv(&call);

    const invoke = struct {
        fn dispatch(h: *rpc.Handler, c: *rpc.Ctx, cmd: []const u8, body: []const u8) core.OutgoingResponse {
            return h.dispatch(testing.allocator, c, cmd, body);
        }
    }.dispatch;

    // 1. A setter emits a native→JS window event through Host.evalJs. Register a listener first
    //    (upstream `listen()` also evaluates a registration snippet, so capture the count).
    {
        var r = invoke(&handler, &ctx, "plugin:event|listen", "{\"event\":\"tauri://window-flags-changed\",\"target\":{\"kind\":\"Any\"},\"handler\":11}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    const evals_before_title = host.eval_log.items.len;
    {
        var r = invoke(&handler, &ctx, "plugin:window|set_title", "{\"value\":\"P1\"}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    try testing.expect(host.eval_log.items.len > evals_before_title);
    const last_eval = host.eval_log.items[host.eval_log.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, last_eval, "tauri://window-flags-changed") != null);

    // 2. Remaining setters record state; invalid enum values are refused.
    {
        var r = invoke(&handler, &ctx, "plugin:window|set_progress_bar", "{\"status\":\"normal\",\"progress\":42}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        try testing.expectEqual(window_mod.ProgressStatus.normal, windows.entries.items[0].extras.progress_status);
        try testing.expectEqual(@as(u8, 42), windows.entries.items[0].extras.progress_value.?);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:window|set_progress_bar", "{\"status\":\"normal\",\"progress\":101}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:window|set_cursor_icon", "{\"value\":\"crosshair\"}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        try testing.expectEqual(window_mod.CursorIcon.crosshair, windows.entries.items[0].extras.cursor_icon);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:window|emit_window_event", "{\"event\":\"tauri://file-drop\",\"payload\":{\"paths\":[\"a.png\"]}}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:window|emit_window_event", "{\"event\":\"evil-event\"}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }

    // 3. Monitor / DPI commands.
    {
        var r = invoke(&handler, &ctx, "plugin:window|available_monitors", "{}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        try testing.expect(std.mem.indexOf(u8, r.body.slice(), "\"default\"") != null);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:window|monitor_from_point", "{\"x\":100,\"y\":100}");
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.body.slice(), "1920") != null);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:window|cursor_position", "{}");
        defer r.deinit();
        try testing.expectEqualStrings("{\"x\":0,\"y\":0}", r.body.slice());
    }

    // 4. Webview control commands.
    {
        var r = invoke(&handler, &ctx, "plugin:webview|eval", "{\"label\":\"main\",\"value\":\"1+1\"}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        try testing.expect(std.mem.indexOf(u8, host.eval_log.items[host.eval_log.items.len - 1], "1+1") != null);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:webview|open_devtools", "{\"label\":\"main\"}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
        var r2 = invoke(&handler, &ctx, "plugin:webview|is_devtools_open", "{\"label\":\"main\"}");
        defer r2.deinit();
        try testing.expectEqualStrings("true", r2.body.slice());
    }
    {
        var r = invoke(&handler, &ctx, "plugin:webview|set_zoom", "{\"label\":\"main\",\"value\":99}");
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.http_code);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:webview|clear_all_browsing_data", "{}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }

    // 5. `once` delivers exactly one event and then drops the listener.
    {
        var r = invoke(&handler, &ctx, "plugin:event|once", "{\"event\":\"p1-once\",\"handler\":7}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    const before = host.eval_log.items.len;
    {
        var r = invoke(&handler, &ctx, "plugin:event|emit", "{\"event\":\"p1-once\",\"payload\":1}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    {
        var r = invoke(&handler, &ctx, "plugin:event|emit", "{\"event\":\"p1-once\",\"payload\":2}");
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r.status);
    }
    try testing.expectEqual(before + 1, host.eval_log.items.len);
}
