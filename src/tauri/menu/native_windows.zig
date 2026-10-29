//! Windows native menus via Win32 (`CreateMenu` / `CreatePopupMenu` / `AppendMenuW` / `SetMenu`).
//!
//! The core hands over a **flattened pre-order snapshot** with a `depth` per entry (see
//! `docs/architecture/tauri-menu-tray.md`). `snapshot_wire.zig` validates it and rewrites the
//! platform-specific bits (labels, accelerator text, command ids); this file owns the `HMENU`
//! construction and the activation plumbing:
//!
//! * **Activation** — every window is subclassed (`SetWindowSubclass`), so `WM_COMMAND` arrives
//!   with `LOWORD(wParam)` = the 1-based command id; that id is mapped back to the wire `MenuId`
//!   and pushed into the item's `Channel<string>`. Upstream `muda` does the same thing.
//! * **App menu** — Win32 has no application-wide menu bar: a menu belongs to a window, so
//!   `set_as_app_menu` is applied to every registered window and replayed for windows created
//!   later (identical to the GTK backend's model).
//! * **Popup** — `TrackPopupMenu(TPM_RETURNCMD)` returns the chosen id synchronously, so no
//!   `WM_COMMAND` round trip is involved (also what `muda` does).
//!
//! Everything is process-global, like the Win32 menu API itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const menu = @import("mod.zig");
const wire = @import("snapshot_wire.zig");
const win = @import("../native_win32.zig");

const Error = menu.MenuError;

/// Process-lifetime allocations: an `HMENU` lives until the window (or the process) goes away.
const gpa = std.heap.page_allocator;

pub const max_depth = wire.max_depth;

// ============================================================================
// Win32 surface (hand-declared: no `@cImport`)
// ============================================================================

const CALL: std.builtin.CallingConvention = .winapi;
const HWND = ?*anyopaque;
const HMENU = ?*anyopaque;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const DWORD = u32;
const BOOL = c_int;

const WM_COMMAND: UINT = 0x0111;
const WM_NCDESTROY: UINT = 0x0082;

// `MF_*` / `TPM_*` flags. `MF_ENABLED` and `MF_UNCHECKED` are both 0, hence the OR-only style.
const MF_STRING: UINT = 0x0000;
const MF_POPUP: UINT = 0x0010;
const MF_SEPARATOR: UINT = 0x0800;
const MF_GRAYED: UINT = 0x0001;
const MF_CHECKED: UINT = 0x0008;
const MF_BYCOMMAND: UINT = 0x0000;

const TPM_LEFTALIGN: UINT = 0x0000;
const TPM_RIGHTBUTTON: UINT = 0x0002;
const TPM_RETURNCMD: UINT = 0x0100;

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;

pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const SubclassProc = *const fn (HWND, UINT, WPARAM, LPARAM, usize, usize) callconv(CALL) LRESULT;

const WNDCLASSW = extern struct {
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(CALL) LRESULT,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: ?[*:0]const u16,
};

extern "user32" fn CreateMenu() callconv(CALL) HMENU;
extern "user32" fn CreatePopupMenu() callconv(CALL) HMENU;
extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(CALL) BOOL;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(CALL) BOOL;
extern "user32" fn SetMenu(hWnd: HWND, hMenu: HMENU) callconv(CALL) BOOL;
extern "user32" fn GetMenu(hWnd: HWND) callconv(CALL) HMENU;
extern "user32" fn DrawMenuBar(hWnd: HWND) callconv(CALL) BOOL;
extern "user32" fn GetMenuItemCount(hMenu: HMENU) callconv(CALL) c_int;
extern "user32" fn GetSubMenu(hMenu: HMENU, nPos: c_int) callconv(CALL) HMENU;
extern "user32" fn GetMenuState(hMenu: HMENU, uId: UINT, uFlags: UINT) callconv(CALL) UINT;
extern "user32" fn GetMenuStringW(hMenu: HMENU, uIDItem: UINT, lpString: [*]u16, cchMax: c_int, uFlags: UINT) callconv(CALL) c_int;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: c_int, y: c_int, nReserved: c_int, hWnd: HWND, prcRect: ?*const RECT) callconv(CALL) BOOL;
extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(CALL) BOOL;
extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(CALL) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(CALL) BOOL;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(CALL) LRESULT;
extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) callconv(CALL) u16;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: ?[*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    hWndParent: HWND,
    hMenu: HMENU,
    hInstance: ?*anyopaque,
    lpParam: ?*anyopaque,
) callconv(CALL) HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(CALL) BOOL;
extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(CALL) LRESULT;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(CALL) ?*anyopaque;

extern "comctl32" fn SetWindowSubclass(hWnd: HWND, pfnSubclass: SubclassProc, uIdSubclass: usize, dwRefData: usize) callconv(CALL) BOOL;
extern "comctl32" fn RemoveWindowSubclass(hWnd: HWND, pfnSubclass: SubclassProc, uIdSubclass: usize) callconv(CALL) BOOL;
extern "comctl32" fn DefSubclassProc(hWnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(CALL) LRESULT;

/// Identifies our subclass among whoever else subclasses the window (`muda` also uses one).
const subclass_id: usize = 0x5A_54_53; // "ZTS"

fn loword(value: usize) u16 {
    return @truncate(value);
}

// ============================================================================
// State
// ============================================================================

const Window = struct {
    label: []const u8,
    /// Cleared when the `HWND` dies (`WM_NCDESTROY`), so a late backend call cannot use it.
    hwnd: ?HWND,
    menu: ?HMENU = null,
};

var windows: std.ArrayListUnmanaged(*Window) = .empty;
/// App-wide snapshot, replayed for windows that follow it (they all render their own `HMENU`).
var app_entries: ?[]menu.Entry = null;
/// Per-window snapshots (`set_as_window_menu`), keyed by label.
var window_entries: std.StringHashMapUnmanaged([]menu.Entry) = .empty;
var activator: menu.Activator = .{};

fn freeEntries(entries: []menu.Entry) void {
    for (entries) |entry| {
        gpa.free(entry.id);
        gpa.free(entry.text);
    }
    gpa.free(entries);
}

fn cloneEntries(entries: []const menu.Entry) Error![]menu.Entry {
    const out = gpa.alloc(menu.Entry, entries.len) catch return error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |entry| {
            gpa.free(entry.id);
            gpa.free(entry.text);
        }
        gpa.free(out);
    }
    for (entries, 0..) |entry, i| {
        out[i] = entry;
        out[i].id = gpa.dupe(u8, entry.id) catch return error.OutOfMemory;
        out[i].text = gpa.dupe(u8, entry.text) catch return error.OutOfMemory;
        // `AboutMetadata` owns strings that die with the node; nothing on Win32 reads them.
        if (entry.predefined) |p| switch (p) {
            .About => out[i].predefined = .{ .About = null },
            else => {},
        };
        filled = i + 1;
    }
    return out;
}

fn findWindow(label: []const u8) ?*Window {
    for (windows.items) |entry| {
        if (std.mem.eql(u8, entry.label, label)) return entry;
    }
    return null;
}

fn entriesFor(label: []const u8) ?[]menu.Entry {
    if (window_entries.get(label)) |entries| return entries;
    return app_entries;
}

/// The `MenuId` behind a Win32 command id, in the scope that built the menu.
fn menuIdForCommand(entries: []const menu.Entry, command: u16) ?[]const u8 {
    if (command == 0) return null;
    const index = @as(usize, command) - 1;
    if (index >= entries.len) return null;
    return entries[index].id;
}

// ============================================================================
// HMENU construction
// ============================================================================

/// Builds an `HMENU` from a flattened snapshot. `popup` chooses `CreatePopupMenu` (context menus)
/// over `CreateMenu` (menu bars); otherwise the two are identical.
fn buildMenu(entries: []const menu.Entry, as_popup: bool) Error!HMENU {
    const root = if (as_popup) CreatePopupMenu() else CreateMenu();
    if (root == null) return error.Failed;
    var ok = false;
    defer {
        if (!ok) _ = DestroyMenu(root);
    }

    var shells: [max_depth + 1]?HMENU = @splat(null);
    shells[0] = root;

    for (entries, 0..) |entry, i| {
        if (entry.depth > max_depth) return error.InvalidMenuDepth;
        const depth: usize = entry.depth;
        // Only a `.submenu` opens a level; `entriesFor` cloned this snapshot verbatim, so the
        // same "depth must not skip" rule the wire enforces applies here.
        const parent = shells[depth] orelse return error.InvalidMenuDepth;

        if (entry.predefined != null and entry.predefined.? == .Separator) {
            if (AppendMenuW(parent, MF_SEPARATOR, 0, null) == 0) return error.Failed;
            var d = depth + 1;
            while (d <= max_depth) : (d += 1) shells[d] = null;
            continue;
        }

        const text = try labelFor(entry);
        defer gpa.free(text);

        if (entry.kind == .submenu) {
            const submenu = CreatePopupMenu() orelse return error.Failed;
            if (AppendMenuW(parent, MF_POPUP, @intFromPtr(submenu), text.ptr) == 0) {
                _ = DestroyMenu(submenu);
                return error.Failed;
            }
            if (depth + 1 > max_depth) return error.InvalidMenuDepth;
            shells[depth + 1] = submenu;
            var d = depth + 2;
            while (d <= max_depth) : (d += 1) shells[d] = null;
            continue;
        }

        var flags: UINT = MF_STRING;
        if (!entry.enabled) flags |= MF_GRAYED;
        if (entry.checked) flags |= MF_CHECKED;
        const command = try wire.commandId(i);
        if (AppendMenuW(parent, flags, command, text.ptr) == 0) return error.Failed;
        // A leaf closes every deeper level: the next entry cannot be a child of it.
        var d = depth + 1;
        while (d <= max_depth) : (d += 1) shells[d] = null;
    }

    ok = true;
    return root;
}

/// `&`-encoded label plus the right-aligned accelerator text (`"&New\tCtrl+N"`), as UTF-16.
///
/// Win32 has no per-item shortcut slot, so the text after `\t` is what Windows draws on the right
/// of the row; the actual key press still has to be routed by the host's message loop
/// (`TranslateAcceleratorW`, see `docs/architecture/tauri-menu-tray.md`).
fn labelFor(entry: menu.Entry) Error![:0]u16 {
    const label = wire.labelFor(gpa, wire.textOf(entry), .windows) catch return error.OutOfMemory;
    defer gpa.free(label);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    aw.writer.writeAll(label) catch return error.OutOfMemory;
    if (entry.accelerator) |acc| {
        const accel = wire.acceleratorText(gpa, acc) catch return error.OutOfMemory;
        defer gpa.free(accel);
        if (accel.len > 0) {
            aw.writer.writeByte('\t') catch return error.OutOfMemory;
            aw.writer.writeAll(accel) catch return error.OutOfMemory;
        }
    }
    return win.utf8ToUtf16ZAlloc(gpa, aw.written()) catch error.OutOfMemory;
}

// ============================================================================
// Window attachment
// ============================================================================

fn subclassProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM, uIdSubclass: usize, dwRefData: usize) callconv(CALL) LRESULT {
    _ = uIdSubclass;
    const entry: *Window = @ptrFromInt(dwRefData);
    switch (msg) {
        WM_COMMAND => {
            const command = loword(wparam);
            const entries = entriesFor(entry.label) orelse return DefSubclassProc(hwnd, msg, wparam, lparam);
            if (menuIdForCommand(entries, command)) |id| {
                activator.call(activator.ctx, id);
                return 0;
            }
            return DefSubclassProc(hwnd, msg, wparam, lparam);
        },
        WM_NCDESTROY => {
            _ = RemoveWindowSubclass(hwnd, subclassProc, subclass_id);
            entry.hwnd = null;
            return DefSubclassProc(hwnd, msg, wparam, lparam);
        },
        else => return DefSubclassProc(hwnd, msg, wparam, lparam),
    }
}

/// Replaces `window.menu` with a freshly built menu for its scope and installs it.
fn rebuild(window: *Window) Error!void {
    const hwnd = window.hwnd orelse return error.Unavailable;
    const entries = entriesFor(window.label) orelse return;

    const built = try buildMenu(entries, false);
    errdefer {
        _ = DestroyMenu(built);
    }
    if (SetMenu(hwnd, built) == 0) return error.Failed;
    _ = DrawMenuBar(hwnd);
    if (window.menu) |old| _ = DestroyMenu(old);
    window.menu = built;
}

/// Registers a toplevel `HWND` so menus can be installed on it (applies any menu already set).
pub fn registerWindow(label: []const u8, native: ?*anyopaque) Error!void {
    const hwnd: HWND = native orelse return error.Unsupported;
    if (findWindow(label) != null) return; // idempotent

    const owned = gpa.dupe(u8, label) catch return error.OutOfMemory;
    errdefer gpa.free(owned);

    const window = gpa.create(Window) catch return error.OutOfMemory;
    errdefer gpa.destroy(window);
    window.* = .{ .label = owned, .hwnd = hwnd };

    if (SetWindowSubclass(hwnd, subclassProc, subclass_id, @intFromPtr(window)) == 0) return error.Failed;
    windows.append(gpa, window) catch {
        _ = RemoveWindowSubclass(hwnd, subclassProc, subclass_id);
        return error.OutOfMemory;
    };

    try rebuild(window);
}

/// Forgets a window: detaches the menu and our subclass, then frees the `HMENU` we own.
pub fn unregisterWindow(label: []const u8) void {
    for (windows.items, 0..) |window, i| {
        if (!std.mem.eql(u8, window.label, label)) continue;
        if (window.hwnd) |hwnd| {
            _ = SetMenu(hwnd, null);
            _ = DrawMenuBar(hwnd);
            _ = RemoveWindowSubclass(hwnd, subclassProc, subclass_id);
        }
        if (window.menu) |hmenu| _ = DestroyMenu(hmenu);
        gpa.free(window.label);
        gpa.destroy(window);
        _ = windows.orderedRemove(i);
        break;
    }
    if (window_entries.fetchRemove(label)) |kv| {
        gpa.free(kv.key);
        freeEntries(kv.value);
    }
}

// ============================================================================
// Backend vtable
// ============================================================================

fn applyApp(_: ?*anyopaque, snapshot: menu.Snapshot) Error!void {
    const stored = try cloneEntries(snapshot.entries);
    errdefer freeEntries(stored);

    for (windows.items) |window| {
        if (window_entries.get(window.label) != null) continue; // a window menu wins
        const fresh = try cloneEntries(snapshot.entries);
        defer freeEntries(fresh);
        const built = try buildMenu(fresh, false);
        const hwnd = window.hwnd orelse {
            _ = DestroyMenu(built);
            continue;
        };
        if (SetMenu(hwnd, built) == 0) {
            _ = DestroyMenu(built);
            return error.Failed;
        }
        _ = DrawMenuBar(hwnd);
        if (window.menu) |old| _ = DestroyMenu(old);
        window.menu = built;
    }

    if (app_entries) |old| freeEntries(old);
    app_entries = stored;
}

fn applyWindow(_: ?*anyopaque, window: ?[]const u8, snapshot: menu.Snapshot) Error!void {
    const label = window orelse return applyApp(null, snapshot);

    const stored = try cloneEntries(snapshot.entries);
    errdefer freeEntries(stored);
    const key = gpa.dupe(u8, label) catch return error.OutOfMemory;
    errdefer gpa.free(key);
    if (window_entries.fetchRemove(label)) |kv| {
        gpa.free(kv.key);
        freeEntries(kv.value);
    }
    window_entries.put(gpa, key, stored) catch return error.OutOfMemory;

    if (findWindow(label)) |entry| try rebuild(entry);
}

fn popup(_: ?*anyopaque, window: ?[]const u8, snapshot: menu.Snapshot, at: ?menu.Position) Error!void {
    // `TrackPopupMenu` needs an owner window.
    const label = window orelse return error.Unsupported;
    const entry = findWindow(label) orelse return error.Unavailable;
    const hwnd = entry.hwnd orelse return error.Unavailable;

    const stored = try cloneEntries(snapshot.entries);
    defer freeEntries(stored);

    const hmenu = try buildMenu(stored, true);
    defer {
        _ = DestroyMenu(hmenu);
    }

    var point: POINT = .{ .x = 0, .y = 0 };
    if (at) |position| {
        // `Position` is logical top-left relative to the window's client area.
        point = .{ .x = @intFromFloat(@round(position.x)), .y = @intFromFloat(@round(position.y)) };
        _ = ClientToScreen(hwnd, &point);
    } else if (GetCursorPos(&point) == 0) {
        return error.Failed;
    }

    // Without the foreground the menu does not dismiss when the user clicks elsewhere.
    _ = SetForegroundWindow(hwnd);

    const chosen = TrackPopupMenu(
        hmenu,
        TPM_LEFTALIGN | TPM_RIGHTBUTTON | TPM_RETURNCMD,
        point.x,
        point.y,
        0,
        hwnd,
        null,
    );
    if (chosen > 0) {
        if (menuIdForCommand(stored, @intCast(chosen))) |id| activator.call(activator.ctx, id);
    }
}

fn setActivatorImpl(_: ?*anyopaque, next: menu.Activator) void {
    activator = next;
}

const vtable = menu.Backend.VTable{
    .apply_app_menu = applyApp,
    .apply_window_menu = applyWindow,
    .popup = popup,
    .set_activator = setActivatorImpl,
};

/// The Win32 menu backend. Call `registerWindow` for every toplevel window first.
pub fn backend() menu.Backend {
    return .{ .vtable = &vtable };
}

/// The `HMENU` currently installed on a registered window (tests / hosts).
pub fn menuFor(label: []const u8) ?HMENU {
    const window = findWindow(label) orelse return null;
    return window.menu;
}

// ============================================================================
// Detached menus (tray icons and hosts that own the `HMENU`)
// ============================================================================

/// A popup `HMENU` plus the snapshot it was built from (so a returned command id can be mapped
/// back to its `MenuId`). Activations go through this module's `Activator`.
pub const Detached = struct {
    hmenu: HMENU,
    entries: []menu.Entry,

    pub fn deinit(self: *Detached) void {
        _ = DestroyMenu(self.hmenu);
        freeEntries(self.entries);
        self.* = undefined;
    }

    pub fn idForCommand(self: Detached, command: u16) ?[]const u8 {
        return menuIdForCommand(self.entries, command);
    }
};

pub fn buildDetached(snapshot: menu.Snapshot) Error!Detached {
    const entries = try cloneEntries(snapshot.entries);
    errdefer freeEntries(entries);
    const hmenu = try buildMenu(entries, true);
    return .{ .hmenu = hmenu, .entries = entries };
}

/// Reports an activation to the menu backend's `Activator` (tray items use this).
pub fn fire(id: []const u8) void {
    activator.call(activator.ctx, id);
}

/// Clears the process-global registry (tests keep the fixtures isolated).
pub fn resetForTesting() void {
    for (windows.items) |window| {
        if (window.hwnd) |hwnd| {
            _ = SetMenu(hwnd, null);
            _ = RemoveWindowSubclass(hwnd, subclassProc, subclass_id);
        }
        if (window.menu) |hmenu| _ = DestroyMenu(hmenu);
        gpa.free(window.label);
        gpa.destroy(window);
    }
    windows.clearRetainingCapacity();
    if (app_entries) |old| freeEntries(old);
    app_entries = null;
    var it = window_entries.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        freeEntries(kv.value_ptr.*);
    }
    window_entries.clearRetainingCapacity();
    activator = .{};
}

// ============================================================================
// Tests — these build real HMENUs (Windows CI runs them; other OSes do not compile this file)
// ============================================================================

const testing = std.testing;

fn win32TestWindow() ?HWND {
    const class_name = win.utf8ToUtf16ZAlloc(gpa, "ZtsMenuTestWindow") catch return null;
    defer gpa.free(class_name);
    const title = win.utf8ToUtf16ZAlloc(gpa, "Z-Ts menu test") catch return null;
    defer gpa.free(title);

    var wc = WNDCLASSW{
        .style = 0,
        .lpfnWndProc = testWindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name.ptr,
    };
    // A second test run in the same process would see `ERROR_CLASS_ALREADY_EXISTS`, which is fine.
    _ = RegisterClassW(&wc);
    return CreateWindowExW(0, class_name.ptr, title.ptr, WS_OVERLAPPEDWINDOW, 0, 0, 320, 200, null, null, wc.hInstance, null);
}

fn testWindowProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(CALL) LRESULT {
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn menuString(hmenu: HMENU, item: u32) ![]u8 {
    var buffer: [256]u16 = undefined;
    const len = GetMenuStringW(hmenu, item, &buffer, buffer.len, MF_BYCOMMAND);
    if (len <= 0) return error.NoSuchItem;
    return win.utf16ZToUtf8(testing.allocator, @ptrCast(&buffer));
}

test "win32 menu mirrors the flattened snapshot: nesting, labels, state, accelerator text" {
    resetForTesting();
    defer resetForTesting();

    const hwnd = win32TestWindow() orelse return error.SkipZigTest;
    defer {
        _ = DestroyWindow(hwnd);
    }
    try registerWindow("main", hwnd);

    const entries = [_]menu.Entry{
        .{ .kind = .submenu, .id = "1", .text = "_File", .depth = 0 },
        .{ .kind = .item, .id = "2", .text = "_New", .depth = 1, .accelerator = menu.Accelerator.parse("CmdOrCtrl+N") catch unreachable },
        .{ .kind = .separator, .id = "3", .text = "", .depth = 1, .predefined = .Separator },
        .{ .kind = .item, .id = "4", .text = "E_xit", .depth = 1, .enabled = false, .predefined = .Quit },
        .{ .kind = .submenu, .id = "5", .text = "_View", .depth = 0 },
        .{ .kind = .item, .id = "6", .text = "_Grid", .depth = 1, .item_kind = .Check, .checked = true },
    };
    try backend().applyAppMenu(.{ .entries = &entries });

    // (1) `SetMenu` installed our bar on the window.
    const root = GetMenu(hwnd) orelse return error.NotAttached;
    try testing.expectEqual(root, menuFor("main").?);
    try testing.expectEqual(@as(c_int, 2), GetMenuItemCount(root));

    // (2) `File` holds New / separator / Exit; labels are `&`-encoded with the accelerator text.
    const file = GetSubMenu(root, 0) orelse return error.NoSubmenu;
    try testing.expectEqual(@as(c_int, 3), GetMenuItemCount(file));

    const new_label = try menuString(file, 2);
    defer testing.allocator.free(new_label);
    try testing.expectEqualStrings("&New\tCtrl+N", new_label);

    // (3) The disabled predefined item is greyed, the check item is checked.
    try testing.expect(GetMenuState(file, 4, MF_BYCOMMAND) & MF_GRAYED != 0);
    const view = GetSubMenu(root, 1) orelse return error.NoSubmenu;
    try testing.expect(GetMenuState(view, 6, MF_BYCOMMAND) & MF_CHECKED != 0);

    // (4) Re-applying replaces the bar instead of leaking a second `HMENU`.
    try backend().applyAppMenu(.{ .entries = &entries });
    try testing.expectEqual(@as(c_int, 2), GetMenuItemCount(GetMenu(hwnd).?));
}

test "win32 WM_COMMAND reaches the activator with the wire MenuId" {
    resetForTesting();
    defer resetForTesting();

    const hwnd = win32TestWindow() orelse return error.SkipZigTest;
    defer {
        _ = DestroyWindow(hwnd);
    }
    try registerWindow("main", hwnd);

    const Recorder = struct {
        var ids = [_][]const u8{ "", "", "", "" };
        var count: usize = 0;
        fn record(_: ?*anyopaque, id: []const u8) void {
            if (count < ids.len) ids[count] = id;
            count += 1;
        }
    };
    Recorder.count = 0;
    backend().setActivator(.{ .call = Recorder.record });

    const entries = [_]menu.Entry{
        .{ .kind = .item, .id = "save", .text = "Save", .depth = 0 },
        .{ .kind = .item, .id = "grid", .text = "Grid", .depth = 0, .item_kind = .Check },
    };
    try backend().applyAppMenu(.{ .entries = &entries });

    // A real `WM_COMMAND`, exactly what Windows sends when the item is clicked.
    _ = SendMessageW(hwnd, WM_COMMAND, 1, 0);
    try testing.expectEqual(@as(usize, 1), Recorder.count);
    try testing.expectEqualStrings("save", Recorder.ids[0]);

    _ = SendMessageW(hwnd, WM_COMMAND, 2, 0);
    try testing.expectEqualStrings("grid", Recorder.ids[1]);

    // An id nobody claimed falls through to `DefSubclassProc` and is not reported.
    _ = SendMessageW(hwnd, WM_COMMAND, 4242, 0);
    try testing.expectEqual(@as(usize, 2), Recorder.count);

    // `WM_NCDESTROY` (from `DestroyWindow`) detaches the subclass on its own: after the window is
    // gone, unregistering must stay safe.
    _ = DestroyWindow(hwnd);
    unregisterWindow("main");
    try testing.expect(menuFor("main") == null);

    std.debug.print("OK menu-win32 checks=5\n", .{});
}

test "win32 per-window menus win over the app menu and are replayed on registration" {
    resetForTesting();
    defer resetForTesting();

    const hwnd = win32TestWindow() orelse return error.SkipZigTest;
    defer {
        _ = DestroyWindow(hwnd);
    }

    // Applied before the window exists: registering replays it.
    const per_window = [_]menu.Entry{
        .{ .kind = .item, .id = "only", .text = "Only", .depth = 0 },
    };
    try backend().applyWindowMenu("main", .{ .entries = &per_window });
    try registerWindow("main", hwnd);
    try testing.expectEqual(@as(c_int, 1), GetMenuItemCount(GetMenu(hwnd).?));

    // An app menu must not stomp on a window menu...
    const app_items = [_]menu.Entry{
        .{ .kind = .item, .id = "a", .text = "A", .depth = 0 },
        .{ .kind = .item, .id = "b", .text = "B", .depth = 0 },
    };
    try backend().applyAppMenu(.{ .entries = &app_items });
    try testing.expectEqual(@as(c_int, 1), GetMenuItemCount(GetMenu(hwnd).?));

    // ...but a second window without its own menu follows the app menu.
    const other = win32TestWindow() orelse return error.SkipZigTest;
    defer {
        _ = DestroyWindow(other);
    }
    try registerWindow("other", other);
    try testing.expectEqual(@as(c_int, 2), GetMenuItemCount(GetMenu(other).?));

    unregisterWindow("main");
    try testing.expect(GetMenu(hwnd) == null);
}
