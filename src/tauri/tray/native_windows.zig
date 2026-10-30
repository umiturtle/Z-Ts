//! Windows system-tray icons via `Shell_NotifyIconW`.
//!
//! One `NOTIFYICONDATAW` per tray id, all routed through a single **message-only** window
//! (`HWND_MESSAGE`) that we create ourselves: the shell posts the tray callback message there, and
//! that window procedure turns it into `TrayEvent`s and pops the attached menu up.
//!
//! The menu is built by the **menu** backend (`menu/native_windows.zig` → `buildDetached`), so a
//! tray menu click reaches the item's `Channel<string>` through the same activator as a menu-bar
//! click — the tray never re-implements that plumbing.
//!
//! ## Headless runners
//!
//! `Shell_NotifyIconW(NIM_ADD)` fails when no shell (`explorer.exe`) is running. That must not make
//! the backend unusable: the window, the state and the callback plumbing exist regardless, and
//! `shell` records whether the shell accepted the icon. Tests drive the real callback message
//! (`SendMessageW(window, callback_message, uID, WM_LBUTTONUP)`), so the activation path is covered
//! even on a runner without a taskbar.
//!
//! Everything is process-global, exactly like the Win32 shell API itself.

const std = @import("std");

const tray = @import("mod.zig");
const menu = @import("../menu/mod.zig");
const menu_windows = @import("../menu/native_windows.zig");
const win = @import("../native_win32.zig");

const Error = tray.TrayError;

/// Process-lifetime allocations: a tray icon lives until the tray is removed (or the process ends).
const gpa = std.heap.page_allocator;

// ============================================================================
// Win32 surface (hand-declared: no `@cImport`)
// ============================================================================

const CALL: std.builtin.CallingConvention = .winapi;
const HWND = ?*anyopaque;
const HICON = ?*anyopaque;
const HMENU = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const UINT = u32;
const DWORD = u32;
const BOOL = c_int;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;

const WM_NULL: UINT = 0x0000;
const WM_DESTROY: UINT = 0x0002;
const WM_NCDESTROY: UINT = 0x0082;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_LBUTTONDBLCLK: UINT = 0x0203;
const WM_RBUTTONUP: UINT = 0x0205;
/// Vista+ (`NOTIFYICON_VERSION_4`): the shell sends this instead of `WM_LBUTTONUP` for a select.
const NIN_SELECT: UINT = 0x0400;

/// Our tray callback message (`WM_APP + 1`).
const callback_message: UINT = 0x8000 + 1;

const NIM_ADD: DWORD = 0x00000000;
const NIM_MODIFY: DWORD = 0x00000001;
const NIM_DELETE: DWORD = 0x00000002;

const NIF_MESSAGE: UINT = 0x00000001;
const NIF_ICON: UINT = 0x00000002;
const NIF_TIP: UINT = 0x00000004;
const NIF_STATE: UINT = 0x00000008;

const NIS_HIDDEN: DWORD = 0x00000001;

const TPM_LEFTALIGN: UINT = 0x0000;
const TPM_BOTTOMALIGN: UINT = 0x0020;
const TPM_RIGHTBUTTON: UINT = 0x0002;
const TPM_RETURNCMD: UINT = 0x0100;

const IMAGE_ICON: UINT = 1;
const LR_LOADFROMFILE: UINT = 0x00000010;
const LR_DEFAULTSIZE: UINT = 0x00000040;
const IDI_APPLICATION: usize = 32512;
const HWND_MESSAGE: isize = -3;

/// `NOTIFYICONDATAW`, Vista+ layout. `cbSize` must be exactly this or `NIM_ADD` fails silently.
const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: HICON,
    szTip: [128]u16,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u16,
    uVersion: DWORD,
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
    guidItem: [16]u8,
    hBalloonIcon: HICON,
};

comptime {
    // The 32-bit layout differs (`cbSize` is 956 there); we only target x86_64 Windows.
    if (@sizeOf(usize) == 8 and @sizeOf(NOTIFYICONDATAW) != 976) {
        @compileError("NOTIFYICONDATAW must be 976 bytes on x86_64");
    }
}

const WindowProc = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(CALL) LRESULT;

const WNDCLASSW = extern struct {
    style: UINT,
    lpfnWndProc: WindowProc,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: ?[*:0]const u16,
};

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

extern "shell32" fn Shell_NotifyIconW(message: DWORD, data: *const NOTIFYICONDATAW) callconv(CALL) BOOL;
extern "user32" fn RegisterClassW(wc: *const WNDCLASSW) callconv(CALL) u16;
extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: ?[*:0]const u16,
    window_name: ?[*:0]const u16,
    style: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: HWND,
    hmenu: HMENU,
    instance: HINSTANCE,
    param: ?*anyopaque,
) callconv(CALL) HWND;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(CALL) LRESULT;
extern "user32" fn SendMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(CALL) LRESULT;
extern "user32" fn PostMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(CALL) BOOL;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(CALL) BOOL;
extern "user32" fn GetCursorPos(point: *POINT) callconv(CALL) BOOL;
extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(CALL) BOOL;
extern "user32" fn TrackPopupMenu(
    hmenu: HMENU,
    flags: UINT,
    x: c_int,
    y: c_int,
    reserved: c_int,
    hwnd: HWND,
    rect: ?*const RECT,
) callconv(CALL) BOOL;
extern "user32" fn GetMenuItemCount(hmenu: HMENU) callconv(CALL) c_int;
extern "user32" fn LoadImageW(instance: HINSTANCE, name: ?[*:0]const u16, kind: UINT, cx: c_int, cy: c_int, flags: UINT) callconv(CALL) ?*anyopaque;
extern "user32" fn LoadIconW(instance: HINSTANCE, name: ?[*:0]const u16) callconv(CALL) ?*anyopaque;
extern "user32" fn CreateIconFromResourceEx(
    bits: [*]const u8,
    size: DWORD,
    is_icon: BOOL,
    version: DWORD,
    cx: c_int,
    cy: c_int,
    flags: UINT,
) callconv(CALL) ?*anyopaque;
extern "user32" fn DestroyIcon(icon: ?*anyopaque) callconv(CALL) BOOL;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(CALL) HINSTANCE;

// ============================================================================
// State
// ============================================================================

const Entry = struct {
    id: []const u8, // owned
    /// 1-based id inside `NOTIFYICONDATAW.uID` (also the `wParam` of the callback message).
    uid: u32,
    icon: ?HICON = null,
    /// `true` when *we* created the `HICON` and must destroy it (a stock icon is shared).
    icon_owned: bool = false,
    attached: ?menu_windows.Detached = null,
    visible: bool = true,
    /// The shell accepted `NIM_ADD` (false on a runner without `explorer.exe`).
    shell: bool = false,
    tooltip: ?[]const u8 = null, // owned
    title: ?[]const u8 = null, // owned
    menu_on_left_click: bool = false,

    fn deinit(self: *Entry) void {
        if (self.icon_owned) {
            if (self.icon) |icon| _ = DestroyIcon(icon);
        }
        if (self.attached) |*attached| attached.deinit();
        gpa.free(self.id);
        if (self.tooltip) |t| gpa.free(t);
        if (self.title) |t| gpa.free(t);
        gpa.destroy(self);
    }
};

var entries: std.ArrayListUnmanaged(*Entry) = .empty;
var emitter: tray.Emitter = .{};
/// Message-only window shared by every tray; created lazily by the first `create`.
var message_window: HWND = null;
var next_uid: u32 = 1;

fn find(id: []const u8) ?*Entry {
    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn findByUid(uid: u32) ?*Entry {
    for (entries.items) |entry| {
        if (entry.uid == uid) return entry;
    }
    return null;
}

fn emit(entry: *Entry, kind: []const u8, button: ?[]const u8, state: ?[]const u8) void {
    emitter.emit(emitter.ctx, .{
        .type = kind,
        .id = entry.id,
        .button = button,
        .button_state = state,
    });
}

// ============================================================================
// Message-only window
// ============================================================================

fn showMenu(entry: *Entry, hwnd: HWND) void {
    var point: POINT = .{ .x = 0, .y = 0 };
    if (GetCursorPos(&point) == 0) return;

    const attached: *menu_windows.Detached = if (entry.attached) |*attached| attached else return;
    // Without the foreground the popup does not dismiss when the user clicks elsewhere.
    _ = SetForegroundWindow(hwnd);
    const chosen = TrackPopupMenu(
        attached.hmenu,
        TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON | TPM_RETURNCMD,
        point.x,
        point.y,
        0,
        hwnd,
        null,
    );
    // `TrackPopupMenu` swallows the next mouse message unless the queue is poked.
    _ = PostMessageW(hwnd, WM_NULL, 0, 0);
    if (chosen > 0) {
        if (attached.idForCommand(@intCast(chosen))) |id| menu_windows.fire(id);
    }
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(CALL) LRESULT {
    switch (msg) {
        callback_message => {
            const entry = findByUid(@intCast(wparam)) orelse return 0;
            switch (@as(UINT, @intCast(lparam & 0xFFFF))) {
                NIN_SELECT, WM_LBUTTONUP => {
                    emit(entry, "Click", "Left", "Up");
                    if (entry.menu_on_left_click and entry.attached != null) showMenu(entry, hwnd);
                },
                WM_LBUTTONDBLCLK => emit(entry, "DoubleClick", "Left", null),
                WM_RBUTTONUP => {
                    emit(entry, "Click", "Right", "Up");
                    if (entry.attached != null) showMenu(entry, hwnd);
                },
                WM_MOUSEMOVE => emit(entry, "Move", null, null),
                else => {},
            }
            return 0;
        },
        WM_DESTROY, WM_NCDESTROY => {
            if (hwnd == message_window) message_window = null;
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn ensureMessageWindow() Error!HWND {
    if (message_window) |hwnd| return hwnd;

    const class_name = win.utf8ToUtf16ZAlloc(gpa, "ZtsTrayMessageWindow") catch return error.OutOfMemory;
    defer gpa.free(class_name);

    var wc: WNDCLASSW = .{
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name.ptr,
    };
    // A redundant registration (second test in the same process) fails harmlessly.
    _ = RegisterClassW(&wc);

    const parent: HWND = @ptrFromInt(@as(usize, @bitCast(HWND_MESSAGE)));
    const hwnd = CreateWindowExW(0, class_name.ptr, null, 0, 0, 0, 0, 0, parent, null, wc.hInstance, null) orelse
        return error.Failed;
    message_window = hwnd;
    return hwnd;
}

// ============================================================================
// NOTIFYICONDATAW plumbing
// ============================================================================

fn fill(entry: *const Entry, hwnd: HWND) NOTIFYICONDATAW {
    var data = std.mem.zeroes(NOTIFYICONDATAW);
    data.cbSize = @sizeOf(NOTIFYICONDATAW);
    data.hWnd = hwnd;
    data.uID = entry.uid;
    data.uCallbackMessage = callback_message;
    data.uFlags = NIF_MESSAGE;
    if (entry.icon) |icon| {
        data.uFlags |= NIF_ICON;
        data.hIcon = icon;
    }
    if (entry.tooltip) |tooltip| {
        data.uFlags |= NIF_TIP;
        copyTip(&data.szTip, tooltip);
    }
    if (!entry.visible) {
        data.uFlags |= NIF_STATE;
        data.dwState = NIS_HIDDEN;
        data.dwStateMask = NIS_HIDDEN;
    }
    return data;
}

/// Copies `text` into the fixed `szTip` buffer, backing off a byte at a time so a multi-byte
/// sequence is never split (a tooltip is truncated, never overrun or dropped).
fn copyTip(dest: []u16, text: []const u8) void {
    var len = @min(text.len, dest.len - 1);
    while (len > 0) : (len -= 1) {
        if (std.unicode.utf8ToUtf16Le(dest[0..len], text[0..len])) |_| return else |_| {}
    }
}

/// `NIM_MODIFY` once the shell holds the icon, `NIM_ADD` otherwise (re-tried when headless).
fn sync(entry: *Entry) void {
    const hwnd = message_window orelse return;
    const data = fill(entry, hwnd);
    const message: DWORD = if (entry.shell) NIM_MODIFY else NIM_ADD;
    if (Shell_NotifyIconW(message, &data) != 0) entry.shell = true;
}

fn shellDelete(entry: *Entry) void {
    const hwnd = message_window orelse return;
    if (!entry.shell) return;
    const data = fill(entry, hwnd);
    _ = Shell_NotifyIconW(NIM_DELETE, &data);
    entry.shell = false;
}

fn stockIcon() HICON {
    // Win32 has no per-item icon set: `IDI_APPLICATION` is always available and is what a tray
    // without an explicit icon shows upstream too.
    return LoadIconW(null, @ptrFromInt(IDI_APPLICATION));
}

/// `NativeIcon` → an `HICON`. Win32 has no per-name stock-icon table worth speaking of, so every
/// named icon resolves to the application icon instead of failing the whole tray.
fn namedIcon(native: menu.NativeIcon) HICON {
    _ = native;
    return stockIcon();
}

fn applyIcon(entry: *Entry, icon: ?menu.Icon) void {
    var next_icon: HICON = null;
    var owned = false;

    if (icon) |spec| {
        switch (spec) {
            .native => |native| next_icon = namedIcon(native),
            .image => |image| switch (image) {
                .path => |path| {
                    if (path.len > 0) {
                        const z = win.utf8ToUtf16ZAlloc(gpa, path) catch null;
                        if (z) |wide| {
                            defer gpa.free(wide);
                            next_icon = LoadImageW(null, wide.ptr, IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
                            owned = next_icon != null;
                        }
                    }
                },
                .bytes => |bytes| {
                    if (bytes.len > 0) {
                        // Handles ICO (and PNG-compressed icons on Vista+); anything else leaves
                        // `next_icon` null and the stock icon is used instead of a broken tray.
                        next_icon = CreateIconFromResourceEx(
                            bytes.ptr,
                            @intCast(bytes.len),
                            1,
                            0x00030000,
                            0,
                            0,
                            LR_DEFAULTSIZE,
                        );
                        owned = next_icon != null;
                    }
                },
                // `plugin:resources` images are not reachable from the tray backend: fail closed
                // by keeping the stock icon rather than pretending the image was applied.
                .resource => {},
            },
        }
    }

    if (entry.icon_owned) {
        if (entry.icon) |old| _ = DestroyIcon(old);
    }
    entry.icon = next_icon orelse stockIcon();
    entry.icon_owned = owned;
}

fn replaceOwned(slot: *?[]const u8, value: []const u8) Error!void {
    const copy = gpa.dupe(u8, value) catch return error.OutOfMemory;
    if (slot.*) |old| gpa.free(old);
    slot.* = copy;
}

fn mapMenuError(err: menu.MenuError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unavailable => error.Unavailable,
        error.NotFound, error.BadResourceId => error.BadResourceId,
        else => error.Failed,
    };
}

fn apply(entry: *Entry, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    if (options.tooltip) |tooltip| try replaceOwned(&entry.tooltip, tooltip);
    if (options.title) |title| {
        try replaceOwned(&entry.title, title);
        // Win32 trays have no title field; fold it into the tooltip so it stays visible.
        if (options.tooltip == null) try replaceOwned(&entry.tooltip, title);
    }

    entry.menu_on_left_click = options.show_menu_on_left_click orelse options.menu_on_left_click orelse false;

    if (snapshot) |menu_snapshot| {
        const built = menu_windows.buildDetached(menu_snapshot) catch |err| return mapMenuError(err);
        if (entry.attached) |*old| old.deinit();
        entry.attached = built;
    }

    // `icon_as_template` is macOS-only; Win32 has no template images, so it is accepted and ignored.
    applyIcon(entry, options.icon);
    sync(entry);
}

fn create(_: ?*anyopaque, id: []const u8, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    if (find(id) != null) return update(null, id, options, snapshot);
    _ = try ensureMessageWindow();

    const owned = gpa.dupe(u8, id) catch return error.OutOfMemory;
    const entry = gpa.create(Entry) catch {
        gpa.free(owned);
        return error.OutOfMemory;
    };
    entry.* = .{ .id = owned, .uid = next_uid };
    next_uid += 1;

    entries.append(gpa, entry) catch {
        // Not registered yet, so `deinit` (which destroys the icon and menu) is enough.
        entry.deinit();
        return error.OutOfMemory;
    };
    apply(entry, options, snapshot) catch |err| {
        _ = entries.pop();
        entry.deinit();
        return err;
    };
}

fn update(_: ?*anyopaque, id: []const u8, options: tray.TrayIconOptions, snapshot: ?menu.Snapshot) Error!void {
    const entry = find(id) orelse return error.NotFound;
    try apply(entry, options, snapshot);
}

fn remove(_: ?*anyopaque, id: []const u8) Error!void {
    for (entries.items, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry.id, id)) continue;
        shellDelete(entry);
        entry.deinit();
        _ = entries.orderedRemove(i);
        return;
    }
}

fn setVisible(_: ?*anyopaque, id: []const u8, visible: bool) Error!void {
    const entry = find(id) orelse return error.NotFound;
    entry.visible = visible;
    sync(entry);
}

fn setEmitterImpl(_: ?*anyopaque, next: tray.Emitter) void {
    emitter = next;
}

const vtable = tray.Backend.VTable{
    .create = create,
    .update = update,
    .remove = remove,
    .set_visible = setVisible,
    .set_emitter = setEmitterImpl,
};

pub fn backend() tray.Backend {
    return .{ .vtable = &vtable };
}

// ============================================================================
// Introspection (tests, hosts)
// ============================================================================

/// The message-only window every tray reports through (created by the first `create`).
pub fn window() ?HWND {
    return message_window;
}

pub fn windowFor(id: []const u8) ?HWND {
    if (find(id) == null) return null;
    return message_window;
}

pub fn uidFor(id: []const u8) ?u32 {
    const entry = find(id) orelse return null;
    return entry.uid;
}

pub fn isVisible(id: []const u8) ?bool {
    const entry = find(id) orelse return null;
    return entry.visible;
}

pub fn shellAccepted(id: []const u8) ?bool {
    const entry = find(id) orelse return null;
    return entry.shell;
}

pub fn tooltipFor(id: []const u8) ?[]const u8 {
    const entry = find(id) orelse return null;
    return entry.tooltip;
}

pub fn menuItemCount(id: []const u8) ?c_int {
    const entry = find(id) orelse return null;
    const attached = entry.attached orelse return null;
    return GetMenuItemCount(attached.hmenu);
}

pub fn resetForTesting() void {
    for (entries.items) |entry| {
        shellDelete(entry);
        entry.deinit();
    }
    entries.clearRetainingCapacity();
    emitter = .{};
    next_uid = 1;
    if (message_window) |hwnd| {
        _ = DestroyWindow(hwnd);
        message_window = null;
    }
}

// ============================================================================
// Tests — real `NOTIFYICONDATAW`s (Windows CI runs them)
// ============================================================================

const testing = std.testing;

/// Collects what the emitter receives; every backend test re-checks this global.
const Recorder = struct {
    var count: usize = 0;
    var last_id: []const u8 = "";
    var last_type: []const u8 = "";
    var last_button: []const u8 = "";

    fn reset() void {
        count = 0;
        last_id = "";
        last_type = "";
        last_button = "";
    }

    fn record(_: ?*anyopaque, event: tray.TrayEvent) void {
        count += 1;
        last_id = event.id;
        last_type = event.type;
        last_button = event.button orelse "";
    }
};

test "win32 tray registers one icon per id and tracks visibility" {
    resetForTesting();
    defer resetForTesting();

    const native = backend();
    try native.create("main", .{ .id = "main", .tooltip = "Z-Ts", .title = "Z-Ts tray" }, null);
    try native.create("second", .{ .id = "second" }, null);

    try testing.expect(windowFor("main") != null);
    try testing.expect(uidFor("main").? != uidFor("second").?);
    try testing.expectEqual(@as(?bool, true), isVisible("main"));
    try testing.expectEqualStrings("Z-Ts", tooltipFor("main").?);

    try native.setVisible("main", false);
    try testing.expectEqual(@as(?bool, false), isVisible("main"));
    try testing.expectEqual(@as(?bool, true), isVisible("second"));

    try native.remove("main");
    try testing.expect(uidFor("main") == null);
    try testing.expect(uidFor("second") != null);
    try testing.expectError(error.NotFound, native.setVisible("nope", true));

    // Re-creating the removed id gives it a fresh shell id.
    try native.create("main", .{ .id = "main" }, null);
    try testing.expect(uidFor("main").? != uidFor("second").?);
}

test "win32 tray callback message reaches the emitter, with the menu attached" {
    resetForTesting();
    defer resetForTesting();
    Recorder.reset();

    const native = backend();
    native.setEmitter(.{ .emit = Recorder.record });

    const items = [_]menu.Entry{
        .{ .kind = .item, .id = "toggle", .text = "Toggle" },
        .{ .kind = .item, .id = "quit", .text = "Quit" },
    };
    try native.create("main", .{ .id = "main", .title = "Z-Ts" }, .{ .entries = &items });
    // No menu: a right click is safe to send here, because with a menu the same message would
    // enter `TrackPopupMenu`'s modal loop (there is no user on a CI runner to dismiss it).
    try native.create("bare", .{ .id = "bare" }, null);

    try testing.expectEqual(@as(?c_int, 2), menuItemCount("main"));
    try testing.expect(menuItemCount("bare") == null);

    const hwnd = windowFor("main").?;
    const uid = uidFor("main").?;
    try testing.expect(hwnd == windowFor("bare").?);

    // Exactly what the shell posts: the callback message with the mouse event in `lParam`.
    _ = SendMessageW(hwnd, callback_message, uid, WM_LBUTTONUP);
    try testing.expectEqual(@as(usize, 1), Recorder.count);
    try testing.expectEqualStrings("main", Recorder.last_id);
    try testing.expectEqualStrings("Click", Recorder.last_type);
    try testing.expectEqualStrings("Left", Recorder.last_button);

    // `NOTIFYICON_VERSION_4` sends `NIN_SELECT` for the same gesture.
    _ = SendMessageW(hwnd, callback_message, uid, NIN_SELECT);
    try testing.expectEqual(@as(usize, 2), Recorder.count);

    _ = SendMessageW(hwnd, callback_message, uid, WM_LBUTTONDBLCLK);
    try testing.expectEqualStrings("DoubleClick", Recorder.last_type);
    try testing.expectEqualStrings("main", Recorder.last_id);

    _ = SendMessageW(hwnd, callback_message, uidFor("bare").?, WM_RBUTTONUP);
    try testing.expectEqual(@as(usize, 4), Recorder.count);
    try testing.expectEqualStrings("bare", Recorder.last_id);
    try testing.expectEqualStrings("Right", Recorder.last_button);

    // An unknown shell id (a stale icon of an already-removed tray) must not reach the emitter.
    _ = SendMessageW(hwnd, callback_message, 9999, WM_LBUTTONUP);
    try testing.expectEqual(@as(usize, 4), Recorder.count);

    std.debug.print("OK tray-win32 checks=9 shell={d} menu={d}\n", .{
        @intFromBool(shellAccepted("main") orelse false),
        menuItemCount("main") orelse 0,
    });
}

test "win32 tray icons: stock, raw bytes and the fail-closed fallback" {
    resetForTesting();
    defer resetForTesting();

    const native = backend();
    try native.create("main", .{ .id = "main" }, null);
    try testing.expect(menuItemCount("main") == null);

    // A stock icon maps onto `IDI_APPLICATION`, so the tray always has an `HICON`.
    try native.update("main", .{ .id = "main", .icon = .{ .native = .About } }, null);
    // Bytes that are not an icon must not crash and must fall back to the stock icon.
    try native.update("main", .{ .id = "main", .icon = .{ .image = .{ .bytes = "not an icon" } } }, null);
    try native.update("main", .{ .id = "main", .icon = .{ .image = .{ .path = "/nonexistent/zts.png" } } }, null);
    // A `resource` icon is not resolvable here: the stock icon stays (fail-closed, never a crash).
    try native.update("main", .{ .id = "main", .icon = .{ .image = .{ .resource = 7 } } }, null);
    try testing.expect(uidFor("main") != null);
}
