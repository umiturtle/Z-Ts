//! `plugin:clipboard-manager|*` — OS Clipboard (`@tauri-apps/plugin-clipboard-manager` v2 wire compatible).
//!
//! Commands (exact upstream argument shapes):
//! - `write_text`   `{ text, label? }` → `null`
//! - `read_text`    `{}` → `string` (empty when the clipboard holds no text)
//! - `write_html`   `{ html, altText? }` → `null`
//! - `clear`        `{}` → `null`
//! - `write_secret` `{ text }` → `null` (desktop: same write, marked "concealed" where the OS allows)
//!
//! Like `dialog`, the OS call sits behind a 2-function-per-direction vtable ([`Backend`]) so this
//! file stays Pure Zig and `zts_tauri_native` provides GTK / NSPasteboard / Win32 implementations.
//!
//! **Not implemented:** `write_image` / `read_image`. Both need image decoding on the Zig side
//! (`src/webview/png.zig` encodes but does not decode); `plugin:fs`-style rids are already ready,
//! so adding them later is additive. See ADR-0012 §4.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const rpc = @import("zts_rpc");

pub const ClipboardError = error{
    /// No usable native backend (headless session with no clipboard owner, GTK unavailable, ...).
    Unavailable,
    /// The OS refused the operation (clipboard locked by another process, ...).
    Failed,
    OutOfMemory,
};

/// Pluggable native clipboard. All returned slices are allocated with the caller's allocator.
pub const Backend = struct {
    /// Opaque pointer handed back to every vtable entry.
    ctx: ?*anyopaque = null,
    /// The platform implementation; `Mock` keeps everything in memory.
    vtable: *const VTable,

    /// The operations a platform clipboard must provide.
    pub const VTable = struct {
        /// Returns the plain-text contents, allocated from `allocator`.
        read_text: *const fn (ctx: ?*anyopaque, allocator: Allocator) ClipboardError![]const u8,
        write_text: *const fn (ctx: ?*anyopaque, text: []const u8) ClipboardError!void,
        read_html: *const fn (ctx: ?*anyopaque, allocator: Allocator) ClipboardError![]const u8,
        write_html: *const fn (ctx: ?*anyopaque, html: []const u8, alt_text: ?[]const u8) ClipboardError!void,
        clear: *const fn (ctx: ?*anyopaque) ClipboardError!void,
        /// Same payload as `write_text`, but asked to mark the content as confidential where the
        /// platform supports it (`NSPasteboardContentsConcealed`,
        /// `ExcludeClipboardContentFromMonitorProcessing` on Windows).
        write_secret: *const fn (ctx: ?*anyopaque, text: []const u8) ClipboardError!void,
    };

    /// Returns the plain-text clipboard contents, allocated from `allocator`.
    pub fn readText(self: Backend, allocator: Allocator) ClipboardError![]const u8 {
        return self.vtable.read_text(self.ctx, allocator);
    }
    /// Replaces the clipboard with plain text.
    pub fn writeText(self: Backend, text: []const u8) ClipboardError!void {
        return self.vtable.write_text(self.ctx, text);
    }
    /// Returns the HTML flavour, allocated from `allocator`.
    pub fn readHtml(self: Backend, allocator: Allocator) ClipboardError![]const u8 {
        return self.vtable.read_html(self.ctx, allocator);
    }
    /// Writes HTML plus its plain-text fallback.
    pub fn writeHtml(self: Backend, html: []const u8, alt_text: ?[]const u8) ClipboardError!void {
        return self.vtable.write_html(self.ctx, html, alt_text);
    }
    /// Empties the clipboard.
    pub fn clear(self: Backend) ClipboardError!void {
        return self.vtable.clear(self.ctx);
    }
    /// Writes text the OS may mark as confidential (`Concealed` on macOS).
    pub fn writeSecret(self: Backend, text: []const u8) ClipboardError!void {
        return self.vtable.write_secret(self.ctx, text);
    }
};

/// In-memory clipboard for unit tests and headless hosts.
///
/// Owns every string it stores, so tests can free the backing arena and still keep the mock alive.
pub const Mock = struct {
    /// Allocator that owns `text`, `html` and `alt_text`.
    allocator: Allocator,
    /// Current plain-text contents.
    text: []const u8 = "",
    /// Current HTML flavour.
    html: []const u8 = "",
    /// Plain-text fallback of the last `writeHtml`.
    alt_text: []const u8 = "",
    /// How many `write_secret` calls were made.
    secret_writes: usize = 0,
    /// How many `clear` calls were made.
    clear_calls: usize = 0,
    /// Set to make the next call fail, so error paths can be tested.
    fail_next: ?ClipboardError = null,

    /// Creates an empty clipboard.
    pub fn init(allocator: Allocator) Mock {
        return .{ .allocator = allocator };
    }

    /// Frees the stored text, HTML and fallback.
    pub fn deinit(self: *Mock) void {
        if (self.text.len > 0) self.allocator.free(self.text);
        if (self.html.len > 0) self.allocator.free(self.html);
        if (self.alt_text.len > 0) self.allocator.free(self.alt_text);
        self.* = undefined;
    }

    /// The `Backend` view of `self`.
    pub fn backend(self: *Mock) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Backend.VTable{
        .read_text = readTextImpl,
        .write_text = writeTextImpl,
        .read_html = readHtmlImpl,
        .write_html = writeHtmlImpl,
        .clear = clearImpl,
        .write_secret = writeSecretImpl,
    };

    fn asMock(ctx: ?*anyopaque) *Mock {
        return @ptrCast(@alignCast(ctx.?));
    }

    /// Owned copy for the mock's internal storage (freed in `deinit`).
    fn dup(self: *Mock, src: []const u8) ClipboardError![]const u8 {
        if (src.len == 0) return "";
        return self.allocator.dupe(u8, src) catch error.OutOfMemory;
    }

    /// Copy handed to the caller, allocated from *their* allocator as the contract requires.
    fn dupFor(allocator: Allocator, src: []const u8) ClipboardError![]const u8 {
        if (src.len == 0) return "";
        return allocator.dupe(u8, src) catch error.OutOfMemory;
    }

    fn takeFailure(self: *Mock) ?ClipboardError {
        if (self.fail_next) |err| {
            self.fail_next = null;
            return err;
        }
        return null;
    }

    fn readTextImpl(ctx: ?*anyopaque, allocator: Allocator) ClipboardError![]const u8 {
        const self = asMock(ctx);
        if (self.takeFailure()) |err| return err;
        return dupFor(allocator, self.text);
    }

    fn writeTextImpl(ctx: ?*anyopaque, text: []const u8) ClipboardError!void {
        const self = asMock(ctx);
        if (self.takeFailure()) |err| return err;
        if (self.text.len > 0) self.allocator.free(self.text);
        self.text = try self.dup(text);
    }

    fn readHtmlImpl(ctx: ?*anyopaque, allocator: Allocator) ClipboardError![]const u8 {
        const self = asMock(ctx);
        if (self.takeFailure()) |err| return err;
        return dupFor(allocator, self.html);
    }

    fn writeHtmlImpl(ctx: ?*anyopaque, html: []const u8, alt_text: ?[]const u8) ClipboardError!void {
        const self = asMock(ctx);
        if (self.takeFailure()) |err| return err;
        if (self.html.len > 0) self.allocator.free(self.html);
        self.html = try self.dup(html);
        if (self.alt_text.len > 0) self.allocator.free(self.alt_text);
        self.alt_text = try self.dup(alt_text orelse "");
    }

    fn clearImpl(ctx: ?*anyopaque) ClipboardError!void {
        const self = asMock(ctx);
        if (self.takeFailure()) |err| return err;
        if (self.text.len > 0) self.allocator.free(self.text);
        if (self.html.len > 0) self.allocator.free(self.html);
        if (self.alt_text.len > 0) self.allocator.free(self.alt_text);
        self.text = "";
        self.html = "";
        self.alt_text = "";
        self.clear_calls += 1;
    }

    fn writeSecretImpl(ctx: ?*anyopaque, text: []const u8) ClipboardError!void {
        const self = asMock(ctx);
        self.secret_writes += 1;
        return writeTextImpl(ctx, text);
    }
};

/// State behind `plugin:clipboard-manager`: the platform backend (X11/Wayland, `NSPasteboard`,
/// Win32 clipboard) plus the allocator used for the strings it hands back.
pub const ClipboardState = struct {
    /// Allocator used for reads (freed by the caller's scratch arena).
    allocator: Allocator,
    /// Platform clipboard implementation.
    backend: Backend,

    /// Creates state backed by `backend`.
    pub fn init(allocator: Allocator, backend: Backend) ClipboardState {
        return .{ .allocator = allocator, .backend = backend };
    }
};

/// `plugin:clipboard-manager|*` RPC command namespace (`Schema` key: `.clipboard`).
pub const Commands = struct {
    /// Every command in this namespace starts with this prefix.
    pub const rpc_prefix = "plugin:clipboard-manager|";
    /// The state type `zts_rpc` resolves per app; identical to `ClipboardState` here.
    pub const RpcState = ClipboardState;

    /// `plugin:clipboard-manager|write_text` — replaces the clipboard with text.
    pub fn write_text(ctx: *rpc.Ctx, state: *ClipboardState, args: struct { text: []const u8, label: ?[]const u8 = null }) ClipboardError!void {
        _ = ctx;
        _ = args.label; // Desktop: upstream ignores the label outside mobile.
        try state.backend.writeText(args.text);
    }

    /// `plugin:clipboard-manager|read_text` — the current plain-text contents.
    pub fn read_text(ctx: *rpc.Ctx, state: *ClipboardState, args: struct {}) ClipboardError![]const u8 {
        _ = args;
        return state.backend.readText(ctx.scratch);
    }

    /// `plugin:clipboard-manager|write_html` — writes HTML and its fallback.
    pub fn write_html(ctx: *rpc.Ctx, state: *ClipboardState, args: struct { html: []const u8, alt_text: ?[]const u8 = null }) ClipboardError!void {
        _ = ctx;
        try state.backend.writeHtml(args.html, args.alt_text);
    }

    /// `plugin:clipboard-manager|clear` — empties the clipboard.
    pub fn clear(ctx: *rpc.Ctx, state: *ClipboardState, args: struct {}) ClipboardError!void {
        _ = ctx;
        _ = args;
        try state.backend.clear();
    }

    /// `plugin:clipboard-manager|write_secret` — writes confidential text.
    pub fn write_secret(ctx: *rpc.Ctx, state: *ClipboardState, args: struct { text: []const u8 }) ClipboardError!void {
        _ = ctx;
        try state.backend.writeSecret(args.text);
    }
};

test {
    _ = Commands;
}
