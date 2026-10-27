//! WebView2 COM interfaces — **GENERATED, DO NOT EDIT** (`src/webview/webview2_com.zig`, `M3-02`).
//!
//! Source: Microsoft's `WebView2.h` (MIDL output). Regenerate with:
//!   `python3 scripts/gen-webview2-com.py /path/to/WebView2.h`
//!
//! Only the vtable **field order** is taken from the header — methods `zts_webview` never calls are
//! erased to `?*const anyopaque` slots, so every struct below is byte-identical to the real COM
//! layout while staying impossible to call by accident. `comptime` size assertions at the bottom
//! prove it.
//!
//! `callconv(.winapi)` only exists on Windows targets; `CALL` keeps this file analyzable on every
//! host so the assertions and the GUID test run in all CI jobs (see ADR-0007).

const std = @import("std");
const builtin = @import("builtin");

/// `winapi` on Windows, the C convention everywhere else (ABI-identical for pointer-only vtables).
const CALL: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const HResult = i32;
pub const S_OK: HResult = 0;
pub const S_FALSE: HResult = 1;
pub const E_NOINTERFACE: HResult = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HResult = @bitCast(@as(u32, 0x80004003));
pub const E_INVALIDARG: HResult = @bitCast(@as(u32, 0x80070057));
pub const E_FAIL: HResult = @bitCast(@as(u32, 0x80004005));
pub const E_OUTOFMEMORY: HResult = @bitCast(@as(u32, 0x8007000E));
pub const REGDB_E_CLASSNOTREG: HResult = @bitCast(@as(u32, 0x80040154));

pub inline fn failed(hr: HResult) bool {
    return hr < 0;
}

pub inline fn succeeded(hr: HResult) bool {
    return hr >= 0;
}

/// `BOOL`
pub const BOOL = i32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

/// `LPWSTR` — CoTaskMem-allocated by a COM getter, freed by the caller via `CoTaskMemFree`.
pub const PWStr = [*:0]u16;

/// `HWND` (opaque here; `win32.zig` owns the real type).
pub const HWND = ?*anyopaque;

/// Win32 `RECT` (physical pixels, top-left origin — same convention as CSS).
pub const Rect = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

/// `COREWEBVIEW2_COLOR` (`BYTE A, R, G, B`).
pub const Color = extern struct {
    A: u8 = 255,
    R: u8 = 255,
    G: u8 = 255,
    B: u8 = 255,
};

pub const transparent = Color{ .A = 0, .R = 0, .G = 0, .B = 0 };

/// `GUID` / `IID` / `CLSID`.
pub const Guid = extern struct {
    d1: u32,
    d2: u16,
    d3: u16,
    d4: [8]u8,
};

/// Parses the canonical `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` form at `comptime`.
pub fn guid(comptime text: []const u8) Guid {
    std.debug.assert(text.len == 36);
    return .{
        .d1 = parseHexInt(u32, text[0..8]),
        .d2 = parseHexInt(u16, text[9..13]),
        .d3 = parseHexInt(u16, text[14..18]),
        .d4 = .{
            parseHexByte(text[19..21]), parseHexByte(text[21..23]),
            // index 23 is the fourth '-' and must be skipped.
            parseHexByte(text[24..26]), parseHexByte(text[26..28]),
            parseHexByte(text[28..30]), parseHexByte(text[30..32]),
            parseHexByte(text[32..34]), parseHexByte(text[34..36]),
        },
    };
}

fn parseHexByte(comptime text: []const u8) u8 {
    return (hexDigit(text[0]) << 4) | hexDigit(text[1]);
}

fn parseHexInt(comptime T: type, comptime text: []const u8) T {
    var out: T = 0;
    inline for (text) |c| {
        if (c == '-') continue;
        out = out * 16 + hexDigit(c);
    }
    return out;
}

fn hexDigit(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("invalid hex digit in GUID literal"),
    };
}

pub const IID_IUnknown = guid("00000000-0000-0000-c000-000000000046");

/// Any COM object is `{ vtable }` — used for `QueryInterface` casts.
pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *IUnknown, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *IUnknown) callconv(CALL) u32,
        Release: *const fn (this: *IUnknown) callconv(CALL) u32,
    };
};

/// `ICoreWebView2Environment` (8 vtable slots — order is the ABI).
pub const ICoreWebView2Environment = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2Environment, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2Environment) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2Environment) callconv(CALL) u32,
        CreateCoreWebView2Controller: *const fn (this: *ICoreWebView2Environment, parent: ?*anyopaque, handler: ?*anyopaque) callconv(CALL) HResult,
        CreateWebResourceResponse: *const fn (this: *ICoreWebView2Environment, content: ?*anyopaque, status: i32, reason: ?[*:0]const u16, headers: ?[*:0]const u16, response: *?*ICoreWebView2WebResourceResponse) callconv(CALL) HResult,
        get_BrowserVersionString: ?*const anyopaque,
        add_NewBrowserVersionAvailable: ?*const anyopaque,
        remove_NewBrowserVersionAvailable: ?*const anyopaque,
    };
};

pub const IID_ICoreWebView2Environment = guid("b96d755e-0319-4e92-a296-23436f46a1fc");

/// `ICoreWebView2Controller` (26 vtable slots — order is the ABI).
pub const ICoreWebView2Controller = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2Controller, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2Controller) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2Controller) callconv(CALL) u32,
        get_IsVisible: ?*const anyopaque,
        put_IsVisible: *const fn (this: *ICoreWebView2Controller, visible: BOOL) callconv(CALL) HResult,
        get_Bounds: ?*const anyopaque,
        put_Bounds: *const fn (this: *ICoreWebView2Controller, bounds: Rect) callconv(CALL) HResult,
        get_ZoomFactor: ?*const anyopaque,
        put_ZoomFactor: *const fn (this: *ICoreWebView2Controller, factor: f64) callconv(CALL) HResult,
        add_ZoomFactorChanged: ?*const anyopaque,
        remove_ZoomFactorChanged: ?*const anyopaque,
        SetBoundsAndZoomFactor: ?*const anyopaque,
        MoveFocus: *const fn (this: *ICoreWebView2Controller, reason: i32) callconv(CALL) HResult,
        add_MoveFocusRequested: ?*const anyopaque,
        remove_MoveFocusRequested: ?*const anyopaque,
        add_GotFocus: ?*const anyopaque,
        remove_GotFocus: ?*const anyopaque,
        add_LostFocus: ?*const anyopaque,
        remove_LostFocus: ?*const anyopaque,
        add_AcceleratorKeyPressed: ?*const anyopaque,
        remove_AcceleratorKeyPressed: ?*const anyopaque,
        get_ParentWindow: ?*const anyopaque,
        put_ParentWindow: *const fn (this: *ICoreWebView2Controller, parent: ?*anyopaque) callconv(CALL) HResult,
        NotifyParentWindowPositionChanged: *const fn (this: *ICoreWebView2Controller) callconv(CALL) HResult,
        Close: *const fn (this: *ICoreWebView2Controller) callconv(CALL) HResult,
        get_CoreWebView2: *const fn (this: *ICoreWebView2Controller, out: *?*ICoreWebView2) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2Controller = guid("4d00c0d1-9434-4eb6-8078-8697a560334f");

/// `ICoreWebView2Controller2` (28 vtable slots — order is the ABI).
pub const ICoreWebView2Controller2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2Controller2, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2Controller2) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2Controller2) callconv(CALL) u32,
        get_IsVisible: ?*const anyopaque,
        put_IsVisible: ?*const anyopaque,
        get_Bounds: ?*const anyopaque,
        put_Bounds: ?*const anyopaque,
        get_ZoomFactor: ?*const anyopaque,
        put_ZoomFactor: ?*const anyopaque,
        add_ZoomFactorChanged: ?*const anyopaque,
        remove_ZoomFactorChanged: ?*const anyopaque,
        SetBoundsAndZoomFactor: ?*const anyopaque,
        MoveFocus: ?*const anyopaque,
        add_MoveFocusRequested: ?*const anyopaque,
        remove_MoveFocusRequested: ?*const anyopaque,
        add_GotFocus: ?*const anyopaque,
        remove_GotFocus: ?*const anyopaque,
        add_LostFocus: ?*const anyopaque,
        remove_LostFocus: ?*const anyopaque,
        add_AcceleratorKeyPressed: ?*const anyopaque,
        remove_AcceleratorKeyPressed: ?*const anyopaque,
        get_ParentWindow: ?*const anyopaque,
        put_ParentWindow: ?*const anyopaque,
        NotifyParentWindowPositionChanged: ?*const anyopaque,
        Close: ?*const anyopaque,
        get_CoreWebView2: ?*const anyopaque,
        get_DefaultBackgroundColor: ?*const anyopaque,
        put_DefaultBackgroundColor: *const fn (this: *ICoreWebView2Controller2, value: Color) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2Controller2 = guid("c979903e-d4ca-4228-92eb-47ee3fa96eab");

/// `ICoreWebView2` (61 vtable slots — order is the ABI).
pub const ICoreWebView2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2) callconv(CALL) u32,
        get_Settings: *const fn (this: *ICoreWebView2, out: *?*ICoreWebView2Settings) callconv(CALL) HResult,
        get_Source: *const fn (this: *ICoreWebView2, out: *?PWStr) callconv(CALL) HResult,
        Navigate: *const fn (this: *ICoreWebView2, uri: [*:0]const u16) callconv(CALL) HResult,
        NavigateToString: *const fn (this: *ICoreWebView2, html: [*:0]const u16) callconv(CALL) HResult,
        add_NavigationStarting: ?*const anyopaque,
        remove_NavigationStarting: ?*const anyopaque,
        add_ContentLoading: ?*const anyopaque,
        remove_ContentLoading: ?*const anyopaque,
        add_SourceChanged: ?*const anyopaque,
        remove_SourceChanged: ?*const anyopaque,
        add_HistoryChanged: ?*const anyopaque,
        remove_HistoryChanged: ?*const anyopaque,
        add_NavigationCompleted: ?*const anyopaque,
        remove_NavigationCompleted: ?*const anyopaque,
        add_FrameNavigationStarting: ?*const anyopaque,
        remove_FrameNavigationStarting: ?*const anyopaque,
        add_FrameNavigationCompleted: ?*const anyopaque,
        remove_FrameNavigationCompleted: ?*const anyopaque,
        add_ScriptDialogOpening: ?*const anyopaque,
        remove_ScriptDialogOpening: ?*const anyopaque,
        add_PermissionRequested: ?*const anyopaque,
        remove_PermissionRequested: ?*const anyopaque,
        add_ProcessFailed: ?*const anyopaque,
        remove_ProcessFailed: ?*const anyopaque,
        AddScriptToExecuteOnDocumentCreated: *const fn (this: *ICoreWebView2, script: [*:0]const u16, handler: ?*anyopaque) callconv(CALL) HResult,
        RemoveScriptToExecuteOnDocumentCreated: *const fn (this: *ICoreWebView2, id: [*:0]const u16) callconv(CALL) HResult,
        ExecuteScript: *const fn (this: *ICoreWebView2, script: [*:0]const u16, handler: ?*anyopaque) callconv(CALL) HResult,
        CapturePreview: *const fn (this: *ICoreWebView2, image_format: i32, stream: ?*IStream, handler: ?*anyopaque) callconv(CALL) HResult,
        Reload: *const fn (this: *ICoreWebView2) callconv(CALL) HResult,
        PostWebMessageAsJson: *const fn (this: *ICoreWebView2, json: [*:0]const u16) callconv(CALL) HResult,
        PostWebMessageAsString: *const fn (this: *ICoreWebView2, message: [*:0]const u16) callconv(CALL) HResult,
        add_WebMessageReceived: *const fn (this: *ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CALL) HResult,
        remove_WebMessageReceived: *const fn (this: *ICoreWebView2, token: i64) callconv(CALL) HResult,
        CallDevToolsProtocolMethod: ?*const anyopaque,
        get_BrowserProcessId: ?*const anyopaque,
        get_CanGoBack: ?*const anyopaque,
        get_CanGoForward: ?*const anyopaque,
        GoBack: ?*const anyopaque,
        GoForward: ?*const anyopaque,
        GetDevToolsProtocolEventReceiver: ?*const anyopaque,
        Stop: *const fn (this: *ICoreWebView2) callconv(CALL) HResult,
        add_NewWindowRequested: ?*const anyopaque,
        remove_NewWindowRequested: ?*const anyopaque,
        add_DocumentTitleChanged: ?*const anyopaque,
        remove_DocumentTitleChanged: ?*const anyopaque,
        get_DocumentTitle: ?*const anyopaque,
        AddHostObjectToScript: ?*const anyopaque,
        RemoveHostObjectFromScript: ?*const anyopaque,
        OpenDevToolsWindow: *const fn (this: *ICoreWebView2) callconv(CALL) HResult,
        add_ContainsFullScreenElementChanged: ?*const anyopaque,
        remove_ContainsFullScreenElementChanged: ?*const anyopaque,
        get_ContainsFullScreenElement: ?*const anyopaque,
        add_WebResourceRequested: *const fn (this: *ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CALL) HResult,
        remove_WebResourceRequested: *const fn (this: *ICoreWebView2, token: i64) callconv(CALL) HResult,
        AddWebResourceRequestedFilter: *const fn (this: *ICoreWebView2, uri: [*:0]const u16, resource_context: i32) callconv(CALL) HResult,
        RemoveWebResourceRequestedFilter: ?*const anyopaque,
        add_WindowCloseRequested: *const fn (this: *ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CALL) HResult,
        remove_WindowCloseRequested: *const fn (this: *ICoreWebView2, token: i64) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2 = guid("76eceacb-0462-4d94-ac83-423a6793775e");

/// `COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT` — `PNG = 0`, `JPEG = 1`.
pub const COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG: i32 = 0;

/// `IStream` (`objidl.h`), 13 vtable slots. Only `Seek` + `Read` are typed because that is all a
/// `CapturePreview` buffer needs; the rest stay opaque so the *offsets* stay ABI-exact.
pub const IStream = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *IStream, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *IStream) callconv(CALL) u32,
        Release: *const fn (this: *IStream) callconv(CALL) u32,
        Read: *const fn (this: *IStream, buf: ?*anyopaque, to_read: u32, read: ?*u32) callconv(CALL) HResult,
        Write: ?*const anyopaque,
        /// `LARGE_INTEGER` / `ULARGE_INTEGER` are 64-bit values passed by value on x86_64 & arm64.
        Seek: *const fn (this: *IStream, move: i64, origin: u32, new_pos: ?*u64) callconv(CALL) HResult,
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

pub const STREAM_SEEK_SET: u32 = 0;
pub const STREAM_SEEK_END: u32 = 2;

/// `ICoreWebView2CapturePreviewCompletedHandler` (4 vtable slots — order is the ABI).
pub const ICoreWebView2CapturePreviewCompletedHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2CapturePreviewCompletedHandler, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2CapturePreviewCompletedHandler) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2CapturePreviewCompletedHandler) callconv(CALL) u32,
        Invoke: *const fn (this: *ICoreWebView2CapturePreviewCompletedHandler, error_code: HResult) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2CapturePreviewCompletedHandler = guid("697e05e9-3d8f-45fa-96f4-8ffe1ededaf5");

/// `ICoreWebView2Settings` (21 vtable slots — order is the ABI).
pub const ICoreWebView2Settings = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2Settings, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2Settings) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2Settings) callconv(CALL) u32,
        get_IsScriptEnabled: ?*const anyopaque,
        put_IsScriptEnabled: *const fn (this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult,
        get_IsWebMessageEnabled: ?*const anyopaque,
        put_IsWebMessageEnabled: *const fn (this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult,
        get_AreDefaultScriptDialogsEnabled: ?*const anyopaque,
        put_AreDefaultScriptDialogsEnabled: *const fn (this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult,
        get_IsStatusBarEnabled: ?*const anyopaque,
        put_IsStatusBarEnabled: *const fn (this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult,
        get_AreDevToolsEnabled: ?*const anyopaque,
        put_AreDevToolsEnabled: *const fn (this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult,
        get_AreDefaultContextMenusEnabled: ?*const anyopaque,
        put_AreDefaultContextMenusEnabled: *const fn (this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult,
        get_AreHostObjectsAllowed: ?*const anyopaque,
        put_AreHostObjectsAllowed: ?*const anyopaque,
        get_IsZoomControlEnabled: ?*const anyopaque,
        put_IsZoomControlEnabled: ?*const anyopaque,
        get_IsBuiltInErrorPageEnabled: ?*const anyopaque,
        put_IsBuiltInErrorPageEnabled: ?*const anyopaque,
    };
};

pub const IID_ICoreWebView2Settings = guid("e562e4f0-d7fa-43ac-8d71-c05150499f00");

/// `ICoreWebView2WebResourceRequest` (10 vtable slots — order is the ABI).
pub const ICoreWebView2WebResourceRequest = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2WebResourceRequest, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2WebResourceRequest) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2WebResourceRequest) callconv(CALL) u32,
        get_Uri: *const fn (this: *ICoreWebView2WebResourceRequest, out: *?PWStr) callconv(CALL) HResult,
        put_Uri: ?*const anyopaque,
        get_Method: *const fn (this: *ICoreWebView2WebResourceRequest, out: *?PWStr) callconv(CALL) HResult,
        put_Method: ?*const anyopaque,
        get_Content: *const fn (this: *ICoreWebView2WebResourceRequest, out: *?*anyopaque) callconv(CALL) HResult,
        put_Content: ?*const anyopaque,
        get_Headers: *const fn (this: *ICoreWebView2WebResourceRequest, out: *?*ICoreWebView2HttpRequestHeaders) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2WebResourceRequest = guid("97055cd4-512c-4264-8b5f-e3f446cea6a5");

/// `ICoreWebView2WebResourceResponse` (10 vtable slots — order is the ABI).
pub const ICoreWebView2WebResourceResponse = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2WebResourceResponse, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2WebResourceResponse) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2WebResourceResponse) callconv(CALL) u32,
        get_Content: ?*const anyopaque,
        put_Content: *const fn (this: *ICoreWebView2WebResourceResponse, stream: ?*anyopaque) callconv(CALL) HResult,
        get_Headers: ?*const anyopaque,
        get_StatusCode: ?*const anyopaque,
        put_StatusCode: *const fn (this: *ICoreWebView2WebResourceResponse, status: i32) callconv(CALL) HResult,
        get_ReasonPhrase: ?*const anyopaque,
        put_ReasonPhrase: *const fn (this: *ICoreWebView2WebResourceResponse, reason: [*:0]const u16) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2WebResourceResponse = guid("aafcc94f-fa27-48fd-97df-830ef75aaec9");

/// `ICoreWebView2WebResourceRequestedEventArgs` (8 vtable slots — order is the ABI).
pub const ICoreWebView2WebResourceRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2WebResourceRequestedEventArgs, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2WebResourceRequestedEventArgs) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2WebResourceRequestedEventArgs) callconv(CALL) u32,
        get_Request: *const fn (this: *ICoreWebView2WebResourceRequestedEventArgs, out: *?*ICoreWebView2WebResourceRequest) callconv(CALL) HResult,
        get_Response: ?*const anyopaque,
        put_Response: *const fn (this: *ICoreWebView2WebResourceRequestedEventArgs, response: ?*ICoreWebView2WebResourceResponse) callconv(CALL) HResult,
        GetDeferral: *const fn (this: *ICoreWebView2WebResourceRequestedEventArgs, out: *?*ICoreWebView2Deferral) callconv(CALL) HResult,
        get_ResourceContext: ?*const anyopaque,
    };
};

pub const IID_ICoreWebView2WebResourceRequestedEventArgs = guid("453e667f-12c7-49d4-be6d-ddbe7956f57a");

/// `ICoreWebView2Deferral` (4 vtable slots — order is the ABI).
pub const ICoreWebView2Deferral = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2Deferral, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2Deferral) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2Deferral) callconv(CALL) u32,
        Complete: *const fn (this: *ICoreWebView2Deferral) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2Deferral = guid("c10e7f7b-b585-46f0-a623-8befbf3e4ee0");

/// `ICoreWebView2HttpRequestHeaders` (9 vtable slots — order is the ABI).
pub const ICoreWebView2HttpRequestHeaders = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2HttpRequestHeaders, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2HttpRequestHeaders) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2HttpRequestHeaders) callconv(CALL) u32,
        GetHeader: ?*const anyopaque,
        GetHeaders: ?*const anyopaque,
        Contains: ?*const anyopaque,
        SetHeader: ?*const anyopaque,
        RemoveHeader: ?*const anyopaque,
        GetIterator: *const fn (this: *ICoreWebView2HttpRequestHeaders, out: *?*ICoreWebView2HttpHeadersCollectionIterator) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2HttpRequestHeaders = guid("e86cac0e-5523-465c-b536-8fb9fc8c8c60");

/// `ICoreWebView2HttpHeadersCollectionIterator` (6 vtable slots — order is the ABI).
pub const ICoreWebView2HttpHeadersCollectionIterator = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2HttpHeadersCollectionIterator, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2HttpHeadersCollectionIterator) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2HttpHeadersCollectionIterator) callconv(CALL) u32,
        GetCurrentHeader: *const fn (this: *ICoreWebView2HttpHeadersCollectionIterator, name: *?PWStr, value: *?PWStr) callconv(CALL) HResult,
        get_HasCurrentHeader: *const fn (this: *ICoreWebView2HttpHeadersCollectionIterator, out: *BOOL) callconv(CALL) HResult,
        MoveNext: *const fn (this: *ICoreWebView2HttpHeadersCollectionIterator, out: *BOOL) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2HttpHeadersCollectionIterator = guid("0702fc30-f43b-47bb-ab52-a42cb552ad9f");

/// `ICoreWebView2WebMessageReceivedEventArgs` (6 vtable slots — order is the ABI).
pub const ICoreWebView2WebMessageReceivedEventArgs = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2WebMessageReceivedEventArgs, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2WebMessageReceivedEventArgs) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2WebMessageReceivedEventArgs) callconv(CALL) u32,
        get_Source: ?*const anyopaque,
        get_WebMessageAsJson: *const fn (this: *ICoreWebView2WebMessageReceivedEventArgs, out: *?PWStr) callconv(CALL) HResult,
        TryGetWebMessageAsString: *const fn (this: *ICoreWebView2WebMessageReceivedEventArgs, out: *?PWStr) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2WebMessageReceivedEventArgs = guid("0f99a40c-e962-4207-9e92-e3d542eff849");

/// `ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler` (4 vtable slots — order is the ABI).
pub const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(CALL) u32,
        Invoke: *const fn (this: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, hr: HResult, env: ?*ICoreWebView2Environment) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = guid("4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d");

/// `ICoreWebView2CreateCoreWebView2ControllerCompletedHandler` (4 vtable slots — order is the ABI).
pub const ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(CALL) u32,
        Invoke: *const fn (this: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, hr: HResult, controller: ?*ICoreWebView2Controller) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = guid("6c4819f3-c9b7-4260-8127-c9f5bde7f68c");

/// `ICoreWebView2WebMessageReceivedEventHandler` (4 vtable slots — order is the ABI).
pub const ICoreWebView2WebMessageReceivedEventHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2WebMessageReceivedEventHandler, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2WebMessageReceivedEventHandler) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2WebMessageReceivedEventHandler) callconv(CALL) u32,
        Invoke: *const fn (this: *ICoreWebView2WebMessageReceivedEventHandler, sender: ?*ICoreWebView2, args: ?*ICoreWebView2WebMessageReceivedEventArgs) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2WebMessageReceivedEventHandler = guid("57213f19-00e6-49fa-8e07-898ea01ecbd2");

/// `ICoreWebView2WebResourceRequestedEventHandler` (4 vtable slots — order is the ABI).
pub const ICoreWebView2WebResourceRequestedEventHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2WebResourceRequestedEventHandler, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2WebResourceRequestedEventHandler) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2WebResourceRequestedEventHandler) callconv(CALL) u32,
        Invoke: *const fn (this: *ICoreWebView2WebResourceRequestedEventHandler, sender: ?*ICoreWebView2, args: ?*ICoreWebView2WebResourceRequestedEventArgs) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2WebResourceRequestedEventHandler = guid("ab00b74c-15f1-4646-80e8-e76341d25d71");

/// `ICoreWebView2WindowCloseRequestedEventHandler` (4 vtable slots — order is the ABI).
pub const ICoreWebView2WindowCloseRequestedEventHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *ICoreWebView2WindowCloseRequestedEventHandler, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *ICoreWebView2WindowCloseRequestedEventHandler) callconv(CALL) u32,
        Release: *const fn (this: *ICoreWebView2WindowCloseRequestedEventHandler) callconv(CALL) u32,
        Invoke: *const fn (this: *ICoreWebView2WindowCloseRequestedEventHandler, sender: ?*ICoreWebView2, args: ?*anyopaque) callconv(CALL) HResult,
    };
};

pub const IID_ICoreWebView2WindowCloseRequestedEventHandler = guid("5c19e9e0-092f-486b-affa-ca8231913039");

// ---------------------------------------------------------------------------
// ABI assertions — the entire point of this file.
// ---------------------------------------------------------------------------
comptime {
    std.debug.assert(@sizeOf(ICoreWebView2Environment.VTable) == 8 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2Controller.VTable) == 26 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2Controller2.VTable) == 28 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2.VTable) == 61 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2Settings.VTable) == 21 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2WebResourceRequest.VTable) == 10 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2WebResourceResponse.VTable) == 10 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2WebResourceRequestedEventArgs.VTable) == 8 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2Deferral.VTable) == 4 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2HttpRequestHeaders.VTable) == 9 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2HttpHeadersCollectionIterator.VTable) == 6 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2WebMessageReceivedEventArgs.VTable) == 6 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler.VTable) == 4 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler.VTable) == 4 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2CapturePreviewCompletedHandler.VTable) == 4 * @sizeOf(usize));
    std.debug.assert(@sizeOf(IStream.VTable) == 14 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2WebMessageReceivedEventHandler.VTable) == 4 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2WebResourceRequestedEventHandler.VTable) == 4 * @sizeOf(usize));
    std.debug.assert(@sizeOf(ICoreWebView2WindowCloseRequestedEventHandler.VTable) == 4 * @sizeOf(usize));
    std.debug.assert(@sizeOf(Guid) == 16);
    std.debug.assert(@sizeOf(Rect) == 16);
    std.debug.assert(@sizeOf(Color) == 4);
}

test "capture API: PNG format id, handler IID and vtable slot counts are pinned" {
    try std.testing.expectEqual(@as(i32, 0), COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG);
    // `{697E05E9-3D8F-45FA-96F4-8FFE1EDEDAF5}` from the WebView2 SDK header.
    const iid = IID_ICoreWebView2CapturePreviewCompletedHandler;
    try std.testing.expectEqual(@as(u32, 0x697e05e9), iid.d1);
    try std.testing.expectEqual(@as(u16, 0x3d8f), iid.d2);
    try std.testing.expectEqual(@as(u16, 0x45fa), iid.d3);
    try std.testing.expectEqualSlices(u8, &.{ 0x96, 0xf4, 0x8f, 0xfe, 0x1e, 0xde, 0xda, 0xf5 }, &iid.d4);
}

test "GUID parser matches the SDK and every IID is 128-bit" {
    const c = guid("76eceacb-0462-4d94-ac83-423a6793775e");
    try std.testing.expectEqual(@as(u32, 0x76eceacb), c.d1);
    try std.testing.expectEqual(@as(u16, 0x0462), c.d2);
    try std.testing.expectEqual(@as(u16, 0x4d94), c.d3);
    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x83, 0x42, 0x3a, 0x67, 0x93, 0x77, 0x5e }, &c.d4);
    try std.testing.expectEqual(c.d1, IID_ICoreWebView2.d1);
    try std.testing.expectEqual(@as(u32, 0x0000_0000), IID_IUnknown.d1);
    try std.testing.expectEqual(@as(u16, 0x0000), IID_IUnknown.d3);
    try std.testing.expectEqual(@as(u8, 0xc0), IID_IUnknown.d4[0]);
}
