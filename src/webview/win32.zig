//! Minimal, auditable Win32 + COM bindings for the Windows backend (`src/webview/win32.zig`, `M3-02`).
//!
//! Same philosophy as `gtk_bindings.zig` / `macos_shim.m` ([`AGENTS.md`](../../AGENTS.md) §2.3):
//! **no `@cImport`, no `addTranslateC`** — only the ~80 functions and 6 structs this backend
//! actually calls are declared here as `extern "...".fn` with `callconv(.winapi)`. A cold
//! cross-compile from Linux stays in the low seconds and no Windows SDK is required.
//!
//! Only `builtin.os.tag == .windows` compiles this file (see `mod.zig`), so `zig test` on
//! Linux/macOS never resolves a single `windows.dll` symbol.

const std = @import("std");

// ---------------------------------------------------------------------------
// Primitive Win32 types
// ---------------------------------------------------------------------------

pub const HANDLE = *anyopaque;
pub const HWND = *anyopaque;
pub const HINSTANCE = *anyopaque;
pub const HMODULE = *anyopaque;
pub const HKEY = *anyopaque;
pub const HBRUSH = *anyopaque;
pub const HCURSOR = *anyopaque;
pub const HICON = *anyopaque;
pub const HMENU = *anyopaque;
pub const HGDIOBJ = *anyopaque;
pub const FARPROC = *const anyopaque;

pub const ATOM = u16;
pub const BOOL = i32;
pub const UINT = u32;
pub const DWORD = u32;
pub const LONG = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const W = [*:0]const u16;

pub fn wideLen(s: W) usize {
    return std.mem.len(s);
}

// ---------------------------------------------------------------------------
// Structs (extern = exact C ABI layout)
// ---------------------------------------------------------------------------

pub const POINT = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub inline fn width(self: RECT) i32 {
        return self.right - self.left;
    }
    pub inline fn height(self: RECT) i32 {
        return self.bottom - self.top;
    }
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT = null,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?W = null,
    lpszClassName: ?W = null,
    hIconSm: ?HICON = null,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

// Constant aliases used below (values from `winuser.h`).
pub const WM_NULL = 0x0000;
pub const WM_DESTROY = 0x0002;
pub const WM_NCDESTROY = 0x0082;
pub const WM_SIZE = 0x0005;
pub const WM_CLOSE = 0x0010;
pub const WM_SHOWWINDOW = 0x0018;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_APP = 0x8000;
pub const WM_ZTS_WAKEUP = WM_APP + 1;

pub const HTCAPTION = 2;

pub const WS_OVERLAPPED = 0x00000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const WS_POPUP = @as(u32, 0x80000000);
pub const WS_CHILD = @as(u32, 0x40000000);
pub const WS_VISIBLE = @as(u32, 0x10000000);
pub const WS_CLIPCHILDREN = @as(u32, 0x02000000);
pub const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_NOREDIRECTIONBITMAP = 0x00200000;

pub const GWLP_USERDATA = -21;

pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_SHOW = 5;
pub const SW_MINIMIZE = 6;
pub const SW_RESTORE = 9;
pub const SW_MAXIMIZE = 3;
pub const SW_SHOWNOACTIVATE = 4;

pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;

pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

pub const PM_NOREMOVE = 0x0000;
pub const PM_REMOVE = 0x0001;

pub const QS_ALLINPUT = 0x04FF;
pub const MWMO_INPUTAVAILABLE = 0x0004;

pub const WAIT_OBJECT_0 = 0x0000;
pub const WAIT_TIMEOUT = 0x0102;
pub const INFINITE = 0xFFFFFFFF;

pub const IDC_ARROW = 32512;
pub const COLOR_WINDOW = 5;

pub const SM_CXSCREEN = 0;
pub const SM_CYSCREEN = 1;

pub const GWL_STYLE = -16;
pub const GWL_EXSTYLE = -20;

// DWM
pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_WINDOW_CORNER_PREFERENCE = 33;
pub const DWMWCP_ROUND = 2;

// Registry
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, 0x80000001))));
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, 0x80000002))));
pub const KEY_QUERY_VALUE = 0x0001;
pub const KEY_WOW64_32KEY = 0x0200;
pub const KEY_WOW64_64KEY = 0x0100;
pub const REG_SZ = 1;
pub const REG_EXPAND_SZ = 2;
pub const ERROR_SUCCESS = 0;
pub const ERROR_MORE_DATA = 234;

pub const LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;

pub const COINIT_APARTMENTTHREADED = 0x2;
pub const COINIT_DISABLE_OLE1DDE = 0x4;

pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

// ---------------------------------------------------------------------------
// user32.dll
// ---------------------------------------------------------------------------

pub extern "user32" fn RegisterClassExW(cls: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(name: W, instance: ?HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name: W,
    window_name: W,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(
    hwnd: HWND,
    after: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: u32,
) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(hwnd: HWND, x: i32, y: i32, w: i32, h: i32, repaint: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: W) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, out: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hwnd: HWND, out: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongW(hwnd: HWND, index: i32) callconv(.winapi) i32;
pub extern "user32" fn SetWindowLongW(hwnd: HWND, index: i32, value: i32) callconv(.winapi) i32;
pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(hwnd: ?HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;
pub extern "user32" fn AdjustWindowRectEx(rect: *RECT, style: u32, menu: BOOL, ex_style: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn ReleaseDC(hwnd: ?HWND, dc: ?*anyopaque) callconv(.winapi) i32;
pub extern "user32" fn InvalidateRect(hwnd: HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// kernel32.dll
// ---------------------------------------------------------------------------

pub extern "kernel32" fn GetModuleHandleW(name: ?W) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn LoadLibraryExW(path: W, file: ?HANDLE, flags: u32) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn LoadLibraryW(path: W) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?FARPROC;
pub extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetModuleFileNameW(module: ?HMODULE, out: [*]u16, cap: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn CreateEventW(
    attrs: ?*anyopaque,
    manual_reset: BOOL,
    initial: BOOL,
    name: ?W,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
pub extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
pub extern "kernel32" fn GetEnvironmentVariableW(name: W, out: [*]u16, cap: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetFileAttributesW(path: W) callconv(.winapi) u32;
pub extern "kernel32" fn GetSystemInfo(info: *SYSTEM_INFO) callconv(.winapi) void;

pub const INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;

pub const SYSTEM_INFO = extern struct {
    processor_architecture: u16,
    reserved: u16,
    page_size: u32,
    minimum_application_address: ?*anyopaque,
    maximum_application_address: ?*anyopaque,
    active_processor_mask: usize,
    number_of_processors: u32,
    processor_type: u32,
    allocation_granularity: u32,
    processor_level: u16,
    processor_revision: u16,
};

pub const PROCESSOR_ARCHITECTURE_AMD64 = 9;
pub const PROCESSOR_ARCHITECTURE_ARM64 = 12;
pub const PROCESSOR_ARCHITECTURE_INTEL = 0;

pub extern "kernel32" fn MsgWaitForMultipleObjectsEx(
    count: u32,
    handles: *const HANDLE,
    milliseconds: u32,
    wake_mask: u32,
    flags: u32,
) callconv(.winapi) u32;

// ---------------------------------------------------------------------------
// advapi32.dll (registry)
// ---------------------------------------------------------------------------

pub extern "advapi32" fn RegOpenKeyExW(
    key: HKEY,
    sub_key: W,
    options: u32,
    sam: u32,
    out: *?HKEY,
) callconv(.winapi) i32;
pub extern "advapi32" fn RegQueryValueExW(
    key: HKEY,
    value_name: W,
    reserved: ?*u32,
    value_type: ?*u32,
    data: ?[*]u8,
    data_size: ?*u32,
) callconv(.winapi) i32;
pub extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;

// ---------------------------------------------------------------------------
// ole32.dll / shlwapi.dll / dwmapi.dll
// ---------------------------------------------------------------------------

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, co_init: u32) callconv(.winapi) i32;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoTaskMemFree(mem: ?*anyopaque) callconv(.winapi) void;

/// `SHCreateMemStream` builds a COM `IStream` over a byte buffer — used for WebView2 response
/// bodies so Zig never has to implement `IStream` by hand.
pub extern "shlwapi" fn SHCreateMemStream(init: ?[*]const u8, cb_init: u32) callconv(.winapi) ?*anyopaque;

pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    attribute: u32,
    value: *const anyopaque,
    size: u32,
) callconv(.winapi) i32;

// ---------------------------------------------------------------------------
// COM `IStream` (only `Read` + `Release` are ever called; the rest keep the ABI layout)
// ---------------------------------------------------------------------------

pub const HResult = i32;

pub const IStream = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: ?*const anyopaque,
        AddRef: ?*const anyopaque,
        Release: *const fn (*IStream) callconv(.winapi) u32,
        Read: *const fn (*IStream, buffer: [*]u8, to_read: u32, read: ?*u32) callconv(.winapi) HResult,
        Write: ?*const anyopaque,
        Seek: ?*const anyopaque,
        SetSize: ?*const anyopaque,
        CopyTo: ?*const anyopaque,
        Commit: ?*const anyopaque,
        Revert: ?*const anyopaque,
        LockRegion: ?*const anyopaque,
        UnlockRegion: ?*const anyopaque,
        Stat: ?*const anyopaque,
        Clone: ?*const anyopaque,
    };
};

comptime {
    // IUnknown(3) + Read/Write/Seek/SetSize/CopyTo/Commit/Revert/LockRegion/UnlockRegion/Stat/Clone
    std.debug.assert(@sizeOf(IStream.VTable) == 14 * @sizeOf(*anyopaque));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub inline fn loword(value: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(value)));
}

pub inline fn hiword(value: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(value)) >> 16);
}

/// Converts a UTF-8 slice into a NUL-terminated UTF-16 buffer owned by `allocator`.
///
/// UTF-16 never needs more code units than the UTF-8 byte count, so one allocation of
/// `utf8.len` units is always sufficient (no quadratic grow loop in the hot IPC path).
pub fn toWide(allocator: std.mem.Allocator, utf8: []const u8) error{ OutOfMemory, InvalidUtf8 }![:0]u16 {
    const buf = try allocator.allocSentinel(u16, utf8.len, 0);
    errdefer allocator.free(buf);
    const len = std.unicode.utf8ToUtf16Le(buf, utf8) catch return error.InvalidUtf8;
    buf[len] = 0;
    return buf[0..len :0];
}

/// Converts a NUL-terminated UTF-16 string into UTF-8 (allocated). Frees `wide` via CoTaskMem if
/// `free_wide` is set (WebView2 getters hand back CoTaskMem strings).
pub fn fromWide(
    allocator: std.mem.Allocator,
    wide: [*:0]const u16,
    free_wide: bool,
) error{ OutOfMemory, InvalidUtf16 }![]u8 {
    defer if (free_wide) CoTaskMemFree(@ptrCast(@constCast(wide)));
    const units = std.mem.span(wide);
    return std.unicode.utf16LeToUtf8Alloc(allocator, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf16,
    };
}

test "toWide / fromWide round-trip ASCII, BMP and astral code points" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "hello", "Z-Ts ウィンドウ", "emoji 🚀 ok", "" };
    for (cases) |case| {
        const wide = try toWide(a, case);
        defer a.free(wide);
        const round = try fromWide(a, wide.ptr, false);
        defer a.free(round);
        try std.testing.expectEqualStrings(case, round);
    }
}

// `win32.zig` only ever compiles on `windows`; this guard keeps accidental Linux compilation loud.
comptime {
    if (@import("builtin").os.tag != .windows) {
        @compileError("win32.zig is Windows-only; import it behind `has_native_windows` in mod.zig");
    }
}
