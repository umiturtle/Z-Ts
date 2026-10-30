//! `plugin:dialog|*` — Native File & Message Dialogs (`@tauri-apps/plugin-dialog` v2 wire compatible).
//!
//! Wire-compatible with `plugins-workspace/plugins/dialog`:
//! - `plugin:dialog|open`    `{ options: OpenDialogOptions }` → `string | string[] | null`
//! - `plugin:dialog|save`    `{ options: SaveDialogOptions }` → `string | null`
//! - `plugin:dialog|message` `{ message, title?, kind?, buttons? }` → `"Ok" | "Yes" | "No" | "Cancel" | <custom label>`
//!
//! The OS call itself lives behind [`Backend`], a 3-function vtable, so this file stays Pure Zig
//! (`link_libc = false`, no GTK / Cocoa / Win32). `zts_tauri_native` supplies the real backends and
//! `Mock` below supplies a deterministic one for unit tests.
//!
//! Two upstream behaviours are reproduced deliberately:
//! 1. **`OpenResponse` is untagged**: a single pick is a bare string, `multiple` is an array, and a
//!    cancelled dialog is `null`. The command emits already-serialized JSON ([`rpc.RawJson`]).
//! 2. **Picked paths are granted to the FS scope** ([`DialogState.scope`]), which is how upstream
//!    lets `plugin:fs|read_text_file` open a file the user just chose.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_foundation");
const rpc = @import("zts_rpc");

const fs = @import("../fs/mod.zig");
const path = @import("../path.zig");

pub const DialogError = error{
    /// No usable native backend (headless session, GTK unavailable, ...).
    Unavailable,
    /// The platform reported a failure while presenting the dialog.
    Failed,
    /// A picked path could not be granted to the FS scope.
    ScopeRejected,
    OutOfMemory,
};

// ============================================================================
// Wire types
// ============================================================================

/// One entry of a file-type dropdown (`{ name: "Images", extensions: ["png", "jpg"] }`). Extensions
/// are given without the dot, exactly as `@tauri-apps/plugin-dialog` expects.
pub const DialogFilter = struct {
    name: []const u8,
    extensions: []const []const u8,
};

/// `@tauri-apps/plugin-dialog` `OpenDialogOptions` (`camelCase` on the wire).
pub const OpenDialogOptions = struct {
    title: ?[]const u8 = null,
    filters: []const DialogFilter = &.{},
    multiple: bool = false,
    directory: bool = false,
    default_path: ?[]const u8 = null,
    /// Only meaningful with `directory`: grant sub-directories to the FS scope as well.
    recursive: bool = false,
    can_create_directories: ?bool = null,
    /// Mobile-only hint; the desktop backends ignore it (kept so the wire shape survives).
    picker_mode: ?[]const u8 = null,
    /// Mobile-only (`"copy"` / `"scoped"`); ignored on desktop.
    file_access_mode: ?[]const u8 = null,
};

/// `@tauri-apps/plugin-dialog` `SaveDialogOptions` (`camelCase` on the wire).
pub const SaveDialogOptions = struct {
    title: ?[]const u8 = null,
    filters: []const DialogFilter = &.{},
    default_path: ?[]const u8 = null,
    can_create_directories: ?bool = null,
};

/// Icon/severity of a message box. Parsing is case-insensitive and unknown values fall back to
/// `.info`, matching the upstream deserializer instead of rejecting the request.
pub const MessageDialogKind = enum {
    info,
    warning,
    @"error",

    /// Upstream deserializes case-insensitively and falls back to `info` for unknown values.
    pub fn parse(raw: []const u8) MessageDialogKind {
        if (std.ascii.eqlIgnoreCase(raw, "warning")) return .warning;
        if (std.ascii.eqlIgnoreCase(raw, "error")) return .@"error";
        return .info;
    }
};

/// One label on a message dialog. `id` is the wire result reported back to the webview.
pub const Button = struct {
    id: []const u8,
    label: []const u8,
};

/// `@tauri-apps/plugin-dialog` `MessageDialogButtons`.
///
/// Serialized by serde in its **externally tagged** form, which mixes three shapes:
/// `"Ok" | "OkCancel" | "YesNo" | "YesNoCancel"`, `{"OkCustom":"label"}` and
/// `{"OkCancelCustom":["ok","cancel"]}` / `{"YesNoCancelCustom":[...]}`.
/// That mix cannot be expressed by any single `zts_rpc` union style, so this type carries an
/// explicit `jsonParse` / `jsonStringify` hook.
pub const MessageDialogButtons = struct {
    ok: ?[]const u8 = null,
    cancel: ?[]const u8 = null,
    yes: ?[]const u8 = null,
    no: ?[]const u8 = null,

    pub const default_ok = MessageDialogButtons{ .ok = "Ok" };
    pub const default_ok_cancel = MessageDialogButtons{ .ok = "Ok", .cancel = "Cancel" };
    pub const default_yes_no = MessageDialogButtons{ .yes = "Yes", .no = "No" };
    pub const default_yes_no_cancel = MessageDialogButtons{ .yes = "Yes", .no = "No", .cancel = "Cancel" };

    pub fn isDefault(self: MessageDialogButtons) bool {
        return std.meta.eql(self, default_ok) or
            std.meta.eql(self, default_ok_cancel) or
            std.meta.eql(self, default_yes_no) or
            std.meta.eql(self, default_yes_no_cancel);
    }

    /// Buttons in the order a native dialog should present them (`yes/no/ok` then `cancel`).
    pub fn labels(self: MessageDialogButtons, out: *[3]Button) []const Button {
        var n: usize = 0;
        // Upstream reports the *label* of the pressed button: with default buttons that is
        // exactly "Yes" / "No" / "Ok" / "Cancel", and with custom labels `ask()`/`confirm()`
        // compare the result against the label the caller passed in.
        if (self.yes) |label| {
            out[n] = .{ .id = label, .label = label };
            n += 1;
        }
        if (self.no) |label| {
            out[n] = .{ .id = label, .label = label };
            n += 1;
        }
        if (self.ok) |label| {
            out[n] = .{ .id = label, .label = label };
            n += 1;
        }
        if (self.cancel) |label| {
            out[n] = .{ .id = label, .label = label };
            n += 1;
        }
        return out[0..n];
    }

    pub fn jsonStringify(self: MessageDialogButtons, jw: anytype) !void {
        if (std.meta.eql(self, default_ok)) return jw.writeAll("\"Ok\"");
        if (std.meta.eql(self, default_ok_cancel)) return jw.writeAll("\"OkCancel\"");
        if (std.meta.eql(self, default_yes_no)) return jw.writeAll("\"YesNo\"");
        if (std.meta.eql(self, default_yes_no_cancel)) return jw.writeAll("\"YesNoCancel\"");

        if (self.ok != null and self.cancel != null and self.yes == null and self.no == null) {
            try jw.writeAll("{\"OkCancelCustom\":[");
            try jw.print("\"{s}\",\"{s}\"", .{ self.ok.?, self.cancel.? });
            return jw.writeAll("]}");
        }
        if (self.yes != null and self.no != null and self.cancel != null and self.ok == null) {
            try jw.writeAll("{\"YesNoCancelCustom\":[");
            try jw.print("\"{s}\",\"{s}\",\"{s}\"", .{ self.yes.?, self.no.?, self.cancel.? });
            return jw.writeAll("]}");
        }
        try jw.writeAll("{\"OkCustom\":");
        try jw.print("\"{s}\"", .{self.ok.?});
        return jw.writeAll("}");
    }

    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !MessageDialogButtons {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse 4096);
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.mem.eql(u8, s, "Ok")) return default_ok;
                if (std.mem.eql(u8, s, "OkCancel")) return default_ok_cancel;
                if (std.mem.eql(u8, s, "YesNo")) return default_yes_no;
                if (std.mem.eql(u8, s, "YesNoCancel")) return default_yes_no_cancel;
                return error.UnknownField;
            },
            .object_begin => {},
            else => return error.UnexpectedToken,
        }

        const key_tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse 4096);
        const key = switch (key_tok) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };

        var out: MessageDialogButtons = .{};
        if (std.mem.eql(u8, key, "OkCustom")) {
            out.ok = try parseString(allocator, source, options);
        } else if (std.mem.eql(u8, key, "OkCancelCustom")) {
            var buf: [2][]const u8 = undefined;
            try parseStringTuple(allocator, source, options, &buf);
            out.ok = buf[0];
            out.cancel = buf[1];
        } else if (std.mem.eql(u8, key, "YesNoCancelCustom")) {
            var buf: [3][]const u8 = undefined;
            try parseStringTuple(allocator, source, options, &buf);
            out.yes = buf[0];
            out.no = buf[1];
            out.cancel = buf[2];
        } else {
            return error.UnknownField;
        }

        // Consume the remaining object members (serde only ever emits one, but be tolerant).
        while (true) {
            const next = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse 4096);
            switch (next) {
                .object_end => break,
                else => continue,
            }
        }
        return out;
    }

    fn parseString(allocator: Allocator, source: anytype, options: std.json.ParseOptions) ![]const u8 {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse 4096);
        return switch (tok) {
            .string, .allocated_string => |s| s,
            else => error.UnexpectedToken,
        };
    }

    fn parseStringTuple(
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
        out: [][]const u8,
    ) !void {
        const begin = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse 4096);
        if (begin != .array_begin) return error.UnexpectedToken;
        for (out) |*slot| slot.* = try parseString(allocator, source, options);
        const end = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse 4096);
        if (end != .array_end) return error.UnexpectedToken;
    }
};

/// A message box: title, body, severity and which buttons to show.
pub const MessageRequest = struct {
    title: ?[]const u8 = null,
    message: []const u8,
    kind: MessageDialogKind = .info,
    buttons: MessageDialogButtons = .default_ok,
};

/// Result of an `open` / `save` request. `paths.len == 0` means the user cancelled.
pub const Selection = struct {
    /// Canonical absolute paths, allocated with the allocator passed to the backend.
    paths: []const []const u8 = &.{},

    pub fn cancelled(self: Selection) bool {
        return self.paths.len == 0;
    }
};

pub const BackendError = DialogError;

// ============================================================================
// Backend interface
// ============================================================================

/// Pluggable native implementation. Single-threaded by contract: RPC dispatch is serialized by
/// the host event loop, so backends may keep mutable state behind `ctx` without locking.
pub const Backend = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ctx: ?*anyopaque, allocator: Allocator, options: OpenDialogOptions) BackendError!Selection,
        save: *const fn (ctx: ?*anyopaque, allocator: Allocator, options: SaveDialogOptions) BackendError!Selection,
        message: *const fn (ctx: ?*anyopaque, allocator: Allocator, request: MessageRequest) BackendError![]const u8,
    };

    pub fn open(self: Backend, allocator: Allocator, options: OpenDialogOptions) BackendError!Selection {
        return self.vtable.open(self.ctx, allocator, options);
    }

    pub fn save(self: Backend, allocator: Allocator, options: SaveDialogOptions) BackendError!Selection {
        return self.vtable.save(self.ctx, allocator, options);
    }

    pub fn message(self: Backend, allocator: Allocator, request: MessageRequest) BackendError![]const u8 {
        return self.vtable.message(self.ctx, allocator, request);
    }
};

// ============================================================================
// Mock backend
// ============================================================================

/// Deterministic backend for unit tests and headless environments.
///
/// Queue results with [`Mock.pick`] / [`Mock.answer`] before invoking; every call is recorded so
/// tests can assert *what* the webview asked for, not just what came back.
pub const Mock = struct {
    allocator: Allocator,
    /// Paths returned by the next `open` / `save` call (`null` = cancelled).
    next_paths: ?[]const []const u8 = null,
    /// Label returned by the next `message` call.
    next_label: []const u8 = "Ok",
    /// Set to make the next call fail with this error.
    next_error: ?BackendError = null,

    open_calls: usize = 0,
    save_calls: usize = 0,
    message_calls: usize = 0,
    last_open: ?OpenDialogOptions = null,
    last_save: ?SaveDialogOptions = null,
    last_message: ?MessageRequest = null,

    pub fn init(allocator: Allocator) Mock {
        return .{ .allocator = allocator };
    }

    pub fn backend(self: *Mock) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Backend.VTable{
        .open = openImpl,
        .save = saveImpl,
        .message = messageImpl,
    };

    fn asMock(ctx: ?*anyopaque) *Mock {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn selection(self: *Mock) BackendError!Selection {
        if (self.next_error) |err| {
            self.next_error = null;
            return err;
        }
        const paths = self.next_paths orelse return .{};
        self.next_paths = null;
        return .{ .paths = paths };
    }

    fn openImpl(ctx: ?*anyopaque, allocator: Allocator, options: OpenDialogOptions) BackendError!Selection {
        _ = allocator;
        const self = asMock(ctx);
        self.open_calls += 1;
        self.last_open = options;
        return self.selection();
    }

    fn saveImpl(ctx: ?*anyopaque, allocator: Allocator, options: SaveDialogOptions) BackendError!Selection {
        _ = allocator;
        const self = asMock(ctx);
        self.save_calls += 1;
        self.last_save = options;
        return self.selection();
    }

    fn messageImpl(ctx: ?*anyopaque, allocator: Allocator, request: MessageRequest) BackendError![]const u8 {
        _ = allocator;
        const self = asMock(ctx);
        self.message_calls += 1;
        self.last_message = request;
        if (self.next_error) |err| {
            self.next_error = null;
            return err;
        }
        return self.next_label;
    }
};

// ============================================================================
// RPC state & commands
// ============================================================================

/// State behind `plugin:dialog`. Holds the platform backend and, optionally, the FS scope that every
/// picked path is granted to — that grant is what lets `plugin:fs` open the file the user chose
/// without widening the static scope.
pub const DialogState = struct {
    allocator: Allocator,
    io: Io,
    backend: Backend,
    /// When set, every picked path is granted to this scope (upstream `plugin:fs` behaviour).
    scope: ?*fs.Scope = null,

    pub fn init(allocator: Allocator, io: Io, backend: Backend) DialogState {
        return .{ .allocator = allocator, .io = io, .backend = backend };
    }

    pub fn withScope(self: DialogState, scope: *fs.Scope) DialogState {
        var copy = self;
        copy.scope = scope;
        return copy;
    }

    fn grant(self: *DialogState, paths: []const []const u8, recursive: bool) BackendError!void {
        const scope = self.scope orelse return;
        for (paths) |p| {
            scope.addRoot(self.io, p, recursive) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ScopeRejected,
            };
        }
    }
};

fn writeJsonPathList(writer: *std.Io.Writer, paths: []const []const u8) DialogError!void {
    writer.writeByte('[') catch return error.OutOfMemory;
    for (paths, 0..) |p, i| {
        if (i > 0) writer.writeByte(',') catch return error.OutOfMemory;
        core.html_escape.writeJsonString(writer, p, false) catch return error.OutOfMemory;
    }
    writer.writeByte(']') catch return error.OutOfMemory;
}

/// `plugin:dialog|*` RPC command namespace (`Schema` key: `.dialog`).
pub const Commands = struct {
    pub const rpc_prefix = "plugin:dialog|";
    pub const RpcState = DialogState;

    /// `open()` — returns `string`, `string[]`, or `null` (untagged, exactly like upstream).
    pub fn open(ctx: *rpc.Ctx, state: *DialogState, args: struct { options: OpenDialogOptions }) DialogError!rpc.RawJson {
        const selection = try state.backend.open(ctx.scratch, args.options);
        if (selection.cancelled()) return rpc.RawJson.init("null");

        try state.grant(selection.paths, args.options.directory and args.options.recursive);

        var aw: std.Io.Writer.Allocating = .init(ctx.scratch);
        defer aw.deinit();
        if (args.options.multiple) {
            try writeJsonPathList(&aw.writer, selection.paths);
        } else {
            core.html_escape.writeJsonString(&aw.writer, selection.paths[0], false) catch return error.OutOfMemory;
        }
        return rpc.RawJson.init(aw.written());
    }

    /// `save()` — returns `string` or `null`.
    pub fn save(ctx: *rpc.Ctx, state: *DialogState, args: struct { options: SaveDialogOptions }) DialogError!rpc.RawJson {
        const selection = try state.backend.save(ctx.scratch, args.options);
        if (selection.cancelled()) return rpc.RawJson.init("null");
        try state.grant(selection.paths, false);

        var aw: std.Io.Writer.Allocating = .init(ctx.scratch);
        defer aw.deinit();
        core.html_escape.writeJsonString(&aw.writer, selection.paths[0], false) catch return error.OutOfMemory;
        return rpc.RawJson.init(aw.written());
    }

    /// `message()` — returns the id of the pressed button (`"Ok"` / `"Cancel"` / custom label).
    pub fn message(ctx: *rpc.Ctx, state: *DialogState, args: struct {
        message: []const u8,
        title: ?[]const u8 = null,
        kind: ?[]const u8 = null,
        buttons: ?MessageDialogButtons = null,
    }) DialogError![]const u8 {
        const request = MessageRequest{
            .title = args.title,
            .message = args.message,
            .kind = if (args.kind) |k| MessageDialogKind.parse(k) else .info,
            .buttons = args.buttons orelse MessageDialogButtons.default_ok,
        };
        return state.backend.message(ctx.scratch, request);
    }
};

test {
    _ = Commands;
}

// ============================================================================
// Tests
// ============================================================================

const fs_commands = fs.commands;
const clipboard = @import("../clipboard/mod.zig");

const TestSchema = rpc.Schema(.{
    .dialog = Commands,
    .fs = fs_commands.Commands,
    .clipboard = clipboard.Commands,
});

const Fixture = struct {
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    arena: std.heap.ArenaAllocator,
    mock: Mock,
    scope: fs.Scope = undefined,
    resources: fs_commands.FsState = undefined,
    res_table: @import("../resources.zig").ResourceTable = undefined,
    paths: @import("../path.zig").PathState = undefined,
    fs_state: fs_commands.FsState = undefined,
    dialog_state: DialogState = undefined,
    clip_mock: clipboard.Mock = undefined,
    clip_state: clipboard.ClipboardState = undefined,

    fn create() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        const len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..len];
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.mock = Mock.init(testing.allocator);

        // Only `<tmp>/allowed` is in scope: a pick from `<tmp>/picked` must be granted by the dialog.
        const allowed_root = try path.joinWithStyle(testing.allocator, path.PathStyle.current(), &.{ self.root, "allowed" });
        defer testing.allocator.free(allowed_root);
        self.scope = try fs.Scope.initCanonical(testing.allocator, testing.io, @import("../path.zig").PathStyle.current(), &.{
            .{ .path = allowed_root },
        });
        self.res_table = @import("../resources.zig").ResourceTable.init(testing.allocator, testing.io);
        self.paths = .{ .cwd = self.root, .temp_dir = self.root };
        self.fs_state = fs_commands.FsState.init(testing.allocator, testing.io, self.scope, &self.res_table, &self.paths);
        self.dialog_state = DialogState.init(testing.allocator, testing.io, self.mock.backend()).withScope(&self.fs_state.scope);

        self.clip_mock = clipboard.Mock.init(testing.allocator);
        self.clip_state = clipboard.ClipboardState.init(testing.allocator, self.clip_mock.backend());
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.clip_mock.deinit();
        self.fs_state.deinit();
        self.res_table.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    fn invoke(self: *Fixture, command: []const u8, payload: []const u8) !Response {
        _ = self.arena.reset(.retain_capacity);
        var router = TestSchema.bind(.{
            .dialog = &self.dialog_state,
            .fs = &self.fs_state,
            .clipboard = &self.clip_state,
        });
        var handler = router.handler();
        var ctx = rpc.Ctx.init(testing.io, self.arena.allocator());
        return .{ .resp = handler.dispatch(testing.allocator, &ctx, command, payload) };
    }

    fn absPath(self: *Fixture, scratch: Allocator, sub: []const u8) ![]const u8 {
        return path.joinWithStyle(scratch, path.PathStyle.current(), &.{ self.root, sub });
    }

    /// Serializes `{"path": <p>}` (plus optional leading `extra` members) with the path properly
    /// JSON-escaped: Windows separators are `\\`, which would otherwise produce invalid JSON (or be
    /// read back as an escape sequence) when interpolated naively.
    fn pathPayload(buf: []u8, p: []const u8, extra: []const u8) ![]const u8 {
        var fbs = std.Io.Writer.fixed(buf);
        const w = &fbs;
        try w.writeByte('{');
        if (extra.len > 0) {
            try w.writeAll(extra);
            try w.writeByte(',');
        }
        try w.writeAll("\"path\":");
        try core.html_escape.writeJsonString(w, p, false);
        try w.writeByte('}');
        return w.buffered();
    }

    const Response = struct {
        resp: core.OutgoingResponse,

        fn deinit(self: *Response) void {
            self.resp.deinit();
        }
        fn body(self: *const Response) []const u8 {
            return self.resp.body.slice();
        }
        fn expectOk(self: *const Response) !void {
            try testing.expectEqual(core.IpcStatus.ok, self.resp.status);
        }
        fn expectCode(self: *const Response, code: []const u8) !void {
            try testing.expectEqual(@as(u16, 400), self.resp.http_code);
            const expected = try std.fmt.allocPrint(testing.allocator, "{{\"code\":\"{s}\"}}", .{code});
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, self.body());
        }
    };
};

test "plugin:dialog|open returns an untagged string, an array for multiple, and null when cancelled" {
    var f = try Fixture.create();
    defer f.destroy();

    var scratch_buf: [std.fs.max_path_bytes]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);
    const picked = try f.absPath(scratch.allocator(), "photo.png");

    // Single pick → bare JSON string.
    f.mock.next_paths = &.{picked};
    {
        var r = try f.invoke("plugin:dialog|open", "{\"options\":{\"multiple\":false}}");
        defer r.deinit();
        try r.expectOk();
        try testing.expect(std.mem.endsWith(u8, r.body(), "photo.png\""));
        try testing.expect(r.body()[0] == '"');
    }
    try testing.expectEqual(@as(usize, 1), f.mock.open_calls);

    // Multiple picks → JSON array.
    f.mock.next_paths = &.{ picked, picked };
    {
        var r = try f.invoke("plugin:dialog|open", "{\"options\":{\"multiple\":true}}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqual(@as(u8, '['), r.body()[0]);
        try testing.expectEqual(@as(u8, ']'), r.body()[r.body().len - 1]);
    }

    // Cancelled → null.
    f.mock.next_paths = null;
    {
        var r = try f.invoke("plugin:dialog|open", "{\"options\":{}}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("null", r.body());
    }
}

test "plugin:dialog|open decodes filters, title and directory into the native options" {
    var f = try Fixture.create();
    defer f.destroy();

    f.mock.next_paths = null;
    var r = try f.invoke("plugin:dialog|open",
        \\{"options":{"title":"Pick an image","directory":false,"multiple":true,
        \\ "filters":[{"name":"Images","extensions":["png","jpg"]},{"name":"All","extensions":["*"]}],
        \\ "defaultPath":"/tmp/start","canCreateDirectories":true}}
    );
    defer r.deinit();
    try r.expectOk();

    const seen = f.mock.last_open.?;
    try testing.expectEqualStrings("Pick an image", seen.title.?);
    try testing.expect(seen.multiple);
    try testing.expect(!seen.directory);
    try testing.expectEqualStrings("/tmp/start", seen.default_path.?);
    try testing.expectEqual(true, seen.can_create_directories.?);
    try testing.expectEqual(@as(usize, 2), seen.filters.len);
    try testing.expectEqualStrings("Images", seen.filters[0].name);
    try testing.expectEqual(@as(usize, 2), seen.filters[0].extensions.len);
    try testing.expectEqualStrings("jpg", seen.filters[0].extensions[1]);
}

test "plugin:dialog|message reports the pressed button and parses every serde buttons shape" {
    var f = try Fixture.create();
    defer f.destroy();

    {
        f.mock.next_label = "Ok";
        var r = try f.invoke("plugin:dialog|message", "{\"message\":\"Saved\"," ++ "\"kind\":\"WARNING\",\"buttons\":\"Ok\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("\"Ok\"", r.body());
        try testing.expectEqual(MessageDialogKind.warning, f.mock.last_message.?.kind);
    }
    {
        f.mock.next_label = "Accept";
        var r = try f.invoke("plugin:dialog|message", "{\"message\":\"Continue?\",\"buttons\":{\"OkCancelCustom\":[\"Accept\",\"Decline\"]}}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("\"Accept\"", r.body());

        var labels_buf: [3]Button = undefined;
        const labels = f.mock.last_message.?.buttons.labels(&labels_buf);
        try testing.expectEqual(@as(usize, 2), labels.len);
        try testing.expectEqualStrings("Accept", labels[0].id);
        try testing.expectEqualStrings("Decline", labels[1].id);
    }
    {
        // Unknown kind falls back to `info` (upstream behaviour), unknown button shape is rejected.
        f.mock.next_label = "Cancel";
        var ok = try f.invoke("plugin:dialog|message", "{\"message\":\"x\",\"kind\":\"nonsense\",\"buttons\":\"YesNoCancel\"}");
        defer ok.deinit();
        try ok.expectOk();
        try testing.expectEqual(MessageDialogKind.info, f.mock.last_message.?.kind);
        var three: [3]Button = undefined;
        try testing.expectEqual(@as(usize, 3), f.mock.last_message.?.buttons.labels(&three).len);

        var bad = try f.invoke("plugin:dialog|message", "{\"message\":\"x\",\"buttons\":{\"Bogus\":[\"a\"]}}");
        defer bad.deinit();
        try testing.expectEqual(@as(u16, 400), bad.resp.http_code);
    }
    {
        var r = try f.invoke("plugin:dialog|message", "{\"message\":\"x\",\"buttons\":{\"YesNoCancelCustom\":[\"Y\",\"N\",\"C\"]}}");
        defer r.deinit();
        try r.expectOk();
        var labels_buf: [3]Button = undefined;
        const labels = f.mock.last_message.?.buttons.labels(&labels_buf);
        try testing.expectEqualStrings("Y", labels[0].id);
        try testing.expectEqualStrings("N", labels[1].id);
        try testing.expectEqualStrings("C", labels[2].id);
    }
}

test "dialog picks are granted to the FS scope, so plugin:fs can read what the user just chose" {
    var f = try Fixture.create();
    defer f.destroy();

    // Pick a file outside the initial scope (`<tmp>/picked/secret.txt`).
    try f.tmp.dir.createDir(testing.io, "picked", .default_dir);
    {
        const file = try f.tmp.dir.createFile(testing.io, "picked/secret.txt", .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "dialog granted me");
    }

    var scratch_buf: [std.fs.max_path_bytes]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);
    const picked = try f.absPath(scratch.allocator(), "picked/secret.txt");

    // Before the pick the path is out of scope...
    {
        var payload_buf: [1024]u8 = undefined;
        const payload = try Fixture.pathPayload(&payload_buf, picked, "");
        var r = try f.invoke("plugin:fs|read_text_file", payload);
        defer r.deinit();
        try r.expectCode("OutOfScope");
    }

    // ...the dialog grants it...
    f.mock.next_paths = &.{picked};
    {
        var r = try f.invoke("plugin:dialog|open", "{\"options\":{}}");
        defer r.deinit();
        try r.expectOk();
    }

    // ...and now the same call succeeds.
    {
        var payload_buf: [1024]u8 = undefined;
        const payload = try Fixture.pathPayload(&payload_buf, picked, "");
        var r = try f.invoke("plugin:fs|read_text_file", payload);
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("\"dialog granted me\"", r.body());
    }
}

test "plugin:dialog|save writes through the granted path" {
    var f = try Fixture.create();
    defer f.destroy();

    var scratch_buf: [std.fs.max_path_bytes]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);
    const target = try f.absPath(scratch.allocator(), "out.txt");

    f.mock.next_paths = &.{target};
    {
        var r = try f.invoke("plugin:dialog|save", "{\"options\":{\"title\":\"Save\",\"defaultPath\":\"out.txt\"}}");
        defer r.deinit();
        try r.expectOk();
        try testing.expect(r.body()[0] == '"');
    }
    try testing.expectEqual(@as(usize, 1), f.mock.save_calls);
    try testing.expectEqualStrings("out.txt", f.mock.last_save.?.default_path.?);

    var payload_buf: [1024]u8 = undefined;
    const payload = try Fixture.pathPayload(&payload_buf, target, "\"data\":\"written\"");
    var r = try f.invoke("plugin:fs|write_text_file", payload);
    defer r.deinit();
    try r.expectOk();
}

test "Fixture.pathPayload escapes Windows separators so plugin:fs parses the payload" {
    // A Windows path is full of `\`, which must be escaped or the JSON is rejected with
    // `SyntaxError` before the FS layer ever sees it (this bit the first M4-01 CI run).
    const win_path = "C:\\Users\\runner\\AppData\\Local\\Temp\\picked.txt";
    var buf: [256]u8 = undefined;
    const payload = try Fixture.pathPayload(&buf, win_path, "");
    try testing.expectEqualStrings(
        "{\"path\":\"C:\\\\Users\\\\runner\\\\AppData\\\\Local\\\\Temp\\\\picked.txt\"}",
        payload,
    );
}

test "plugin:clipboard-manager round-trips text and html through the RPC layer" {
    var f = try Fixture.create();
    defer f.destroy();

    {
        var r = try f.invoke("plugin:clipboard-manager|read_text", "{}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("\"\"", r.body());
    }
    {
        var r = try f.invoke("plugin:clipboard-manager|write_text", "{\"text\":\"コピー\",\"label\":\"ignored\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("null", r.body());
    }
    {
        var r = try f.invoke("plugin:clipboard-manager|read_text", "{}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("\"コピー\"", r.body());
    }
    {
        var r = try f.invoke("plugin:clipboard-manager|write_html", "{\"html\":\"<b>hi</b>\",\"altText\":\"hi\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqualStrings("<b>hi</b>", f.clip_mock.html);
        try testing.expectEqualStrings("hi", f.clip_mock.alt_text);
    }
    {
        var r = try f.invoke("plugin:clipboard-manager|write_secret", "{\"text\":\"hunter2\"}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqual(@as(usize, 1), f.clip_mock.secret_writes);
        try testing.expectEqualStrings("hunter2", f.clip_mock.text);
    }
    {
        var r = try f.invoke("plugin:clipboard-manager|clear", "{}");
        defer r.deinit();
        try r.expectOk();
        try testing.expectEqual(@as(usize, 1), f.clip_mock.clear_calls);
        try testing.expectEqualStrings("", f.clip_mock.text);
    }
}

test "clipboard errors surface as HTTP 400 with a stable code" {
    var f = try Fixture.create();
    defer f.destroy();

    f.clip_mock.fail_next = error.Unavailable;
    var r = try f.invoke("plugin:clipboard-manager|write_text", "{\"text\":\"x\"}");
    defer r.deinit();
    try testing.expectEqual(@as(u16, 400), r.resp.http_code);
    try testing.expectEqualStrings("{\"code\":\"Unavailable\"}", r.body());
}
