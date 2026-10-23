//! WebView2 COM interfaces — **GENERATED, DO NOT EDIT** (`M3-02`).
//!
//! Regenerate with:
//! ```bash
//! python3 scripts/gen-webview2-com.py /tmp/WebView2.h
//! ```
//!
//! Only the vtable *order* is taken from Microsoft's header; methods that `zts_webview` never
//! calls stay as erased `?*const anyopaque` slots, so every struct below is byte-for-byte the
//! real COM layout (`comptime` size assertions at the bottom prove it).

const std = @import("std");
const builtin = @import("builtin");

/// `callconv(CC)` only exists for Windows targets, but this file is analyzed on every OS
/// (so the slot-count assertions and the GUID test run in all CI jobs). `.c` is ABI-identical
/// for these four-pointer vtables on non-Windows hosts.
pub const CC: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

/// `HRESULT` (`long` on Win32).
pub const HResult = i32;

pub const S_OK: HResult = 0;
pub const S_FALSE: HResult = 1;
pub const E_NOINTERFACE: HResult = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HResult = @bitCast(@as(u32, 0x80004003));
pub const E_INVALIDARG: HResult = @bitCast(@as(u32, 0x80070057));
pub const E_OUTOFMEMORY: HResult = @bitCast(@as(u32, 0x8007000E));
pub const E_FAIL: HResult = @bitCast(@as(u32, 0x80004005));
pub const E_UNEXPECTED: HResult = @bitCast(@as(u32, 0x8000FFFF));

pub inline fn failed(hr: HResult) bool {
    return hr < 0;
}

/// `PWSTR` / `LPWSTR` — CoTaskMem-allocated UTF-16 string owned by the CALLER after a getter.
pub const PWStr = [*:0]u16;

/// Win32 `RECT` (physical pixels, top-left origin — same convention as CSS).
pub const Rect = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

pub const Guid = extern struct {
    d1: u32,
    d2: u16,
    d3: u16,
    d4: [8]u8,
};

/// Parses a canonical `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` GUID at `comptime`.
pub fn guid(comptime text: []const u8) Guid {
    std.debug.assert(text.len == 36);
    return .{
        .d1 = parseU32(text[0..8]),
        .d2 = parseU16(text[9..13]),
        .d3 = parseU16(text[14..18]),
        // `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`: index 23 is the fourth dash and must be skipped.
        .d4 = .{
            parseByte(text[19..21]), parseByte(text[21..23]),
            parseByte(text[24..26]), parseByte(text[26..28]),
            parseByte(text[28..30]), parseByte(text[30..32]),
            parseByte(text[32..34]), parseByte(text[34..36]),
        },
    };
}

fn parseByte(comptime s: []const u8) u8 {
    return (hexDigit(s[0]) << 4) | hexDigit(s[1]);
}

fn hexDigit(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("invalid hex digit"),
    };
}

fn parseU16(comptime s: []const u8) u16 {
    var out: u16 = 0;
    inline for (s) |c| {
        if (c == '-') continue;
        out = out * 16 + hexDigit(c);
    }
    return out;
}

fn parseU32(comptime s: []const u8) u32 {
    var out: u32 = 0;
    inline for (s) |c| {
        if (c == '-') continue;
        out = out * 16 + hexDigit(c);
    }
    return out;
}

pub const ICoreWebView2Environment = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Environment, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2Environment) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2Environment) callconv(CC) u32,
        CreateCoreWebView2Controller: *const fn (*ICoreWebView2Environment, hwnd: ?*anyopaque, handler: ?*anyopaque) callconv(CC) HResult,
        CreateWebResourceResponse: *const fn (*ICoreWebView2Environment, content: ?*anyopaque, status_code: i32, reason: ?[*:0]const u16, headers: ?[*:0]const u16, response: *?*ICoreWebView2WebResourceResponse) callconv(CC) HResult,
        get_BrowserVersionString: ?*const anyopaque,
        add_NewBrowserVersionAvailable: ?*const anyopaque,
        remove_NewBrowserVersionAvailable: ?*const anyopaque,
    };

    pub inline fn vt(self: *const ICoreWebView2Environment) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2Environment = guid("b96d755e-0319-4e92-a296-23436f46a1fc");

pub const ICoreWebView2Controller = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Controller, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2Controller) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2Controller) callconv(CC) u32,
        get_IsVisible: ?*const anyopaque,
        put_IsVisible: *const fn (*ICoreWebView2Controller, visible: i32) callconv(CC) HResult,
        get_Bounds: ?*const anyopaque,
        put_Bounds: *const fn (*ICoreWebView2Controller, bounds: Rect) callconv(CC) HResult,
        get_ZoomFactor: ?*const anyopaque,
        put_ZoomFactor: ?*const anyopaque,
        add_ZoomFactorChanged: ?*const anyopaque,
        remove_ZoomFactorChanged: ?*const anyopaque,
        SetBoundsAndZoomFactor: ?*const anyopaque,
        MoveFocus: *const fn (*ICoreWebView2Controller, reason: i32) callconv(CC) HResult,
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
        Close: *const fn (*ICoreWebView2Controller) callconv(CC) HResult,
        get_CoreWebView2: *const fn (*ICoreWebView2Controller, out: *?*ICoreWebView2) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2Controller) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2Controller = guid("4d00c0d1-9434-4eb6-8078-8697a560334f");

pub const ICoreWebView2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2) callconv(CC) u32,
        get_Settings: *const fn (*ICoreWebView2, out: *?*ICoreWebView2Settings) callconv(CC) HResult,
        get_Source: *const fn (*ICoreWebView2, out: *?PWStr) callconv(CC) HResult,
        Navigate: *const fn (*ICoreWebView2, uri: [*:0]const u16) callconv(CC) HResult,
        NavigateToString: *const fn (*ICoreWebView2, html: [*:0]const u16) callconv(CC) HResult,
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
        AddScriptToExecuteOnDocumentCreated: *const fn (*ICoreWebView2, script: [*:0]const u16, handler: ?*anyopaque) callconv(CC) HResult,
        RemoveScriptToExecuteOnDocumentCreated: ?*const anyopaque,
        ExecuteScript: *const fn (*ICoreWebView2, script: [*:0]const u16, handler: ?*anyopaque) callconv(CC) HResult,
        CapturePreview: ?*const anyopaque,
        Reload: *const fn (*ICoreWebView2) callconv(CC) HResult,
        PostWebMessageAsJson: *const fn (*ICoreWebView2, msg: [*:0]const u16) callconv(CC) HResult,
        PostWebMessageAsString: *const fn (*ICoreWebView2, msg: [*:0]const u16) callconv(CC) HResult,
        add_WebMessageReceived: *const fn (*ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CC) HResult,
        remove_WebMessageReceived: *const fn (*ICoreWebView2, token: i64) callconv(CC) HResult,
        CallDevToolsProtocolMethod: ?*const anyopaque,
        get_BrowserProcessId: ?*const anyopaque,
        get_CanGoBack: ?*const anyopaque,
        get_CanGoForward: ?*const anyopaque,
        GoBack: ?*const anyopaque,
        GoForward: ?*const anyopaque,
        GetDevToolsProtocolEventReceiver: ?*const anyopaque,
        Stop: *const fn (*ICoreWebView2) callconv(CC) HResult,
        add_NewWindowRequested: ?*const anyopaque,
        remove_NewWindowRequested: ?*const anyopaque,
        add_DocumentTitleChanged: ?*const anyopaque,
        remove_DocumentTitleChanged: ?*const anyopaque,
        get_DocumentTitle: ?*const anyopaque,
        AddHostObjectToScript: ?*const anyopaque,
        RemoveHostObjectFromScript: ?*const anyopaque,
        OpenDevToolsWindow: *const fn (*ICoreWebView2) callconv(CC) HResult,
        add_ContainsFullScreenElementChanged: ?*const anyopaque,
        remove_ContainsFullScreenElementChanged: ?*const anyopaque,
        get_ContainsFullScreenElement: ?*const anyopaque,
        add_WebResourceRequested: *const fn (*ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CC) HResult,
        remove_WebResourceRequested: *const fn (*ICoreWebView2, token: i64) callconv(CC) HResult,
        AddWebResourceRequestedFilter: *const fn (*ICoreWebView2, uri: [*:0]const u16, resource_context: i32) callconv(CC) HResult,
        RemoveWebResourceRequestedFilter: ?*const anyopaque,
        add_WindowCloseRequested: *const fn (*ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CC) HResult,
        remove_WindowCloseRequested: *const fn (*ICoreWebView2, token: i64) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2 = guid("76eceacb-0462-4d94-ac83-423a6793775e");

pub const ICoreWebView2Settings = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Settings, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2Settings) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2Settings) callconv(CC) u32,
        get_IsScriptEnabled: ?*const anyopaque,
        put_IsScriptEnabled: *const fn (*ICoreWebView2Settings, value: i32) callconv(CC) HResult,
        get_IsWebMessageEnabled: ?*const anyopaque,
        put_IsWebMessageEnabled: *const fn (*ICoreWebView2Settings, value: i32) callconv(CC) HResult,
        get_AreDefaultScriptDialogsEnabled: ?*const anyopaque,
        put_AreDefaultScriptDialogsEnabled: ?*const anyopaque,
        get_IsStatusBarEnabled: ?*const anyopaque,
        put_IsStatusBarEnabled: *const fn (*ICoreWebView2Settings, value: i32) callconv(CC) HResult,
        get_AreDevToolsEnabled: ?*const anyopaque,
        put_AreDevToolsEnabled: *const fn (*ICoreWebView2Settings, value: i32) callconv(CC) HResult,
        get_AreDefaultContextMenusEnabled: ?*const anyopaque,
        put_AreDefaultContextMenusEnabled: ?*const anyopaque,
        get_AreHostObjectsAllowed: ?*const anyopaque,
        put_AreHostObjectsAllowed: ?*const anyopaque,
        get_IsZoomControlEnabled: ?*const anyopaque,
        put_IsZoomControlEnabled: ?*const anyopaque,
        get_IsBuiltInErrorPageEnabled: ?*const anyopaque,
        put_IsBuiltInErrorPageEnabled: ?*const anyopaque,
    };

    pub inline fn vt(self: *const ICoreWebView2Settings) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2Settings = guid("e562e4f0-d7fa-43ac-8d71-c05150499f00");

pub const ICoreWebView2WebResourceRequest = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceRequest, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2WebResourceRequest) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2WebResourceRequest) callconv(CC) u32,
        get_Uri: *const fn (*ICoreWebView2WebResourceRequest, out: *?PWStr) callconv(CC) HResult,
        put_Uri: ?*const anyopaque,
        get_Method: *const fn (*ICoreWebView2WebResourceRequest, out: *?PWStr) callconv(CC) HResult,
        put_Method: ?*const anyopaque,
        get_Content: *const fn (*ICoreWebView2WebResourceRequest, out: *?*anyopaque) callconv(CC) HResult,
        put_Content: ?*const anyopaque,
        get_Headers: *const fn (*ICoreWebView2WebResourceRequest, out: *?*ICoreWebView2HttpRequestHeaders) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2WebResourceRequest) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2WebResourceRequest = guid("97055cd4-512c-4264-8b5f-e3f446cea6a5");

pub const ICoreWebView2WebResourceResponse = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceResponse, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2WebResourceResponse) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2WebResourceResponse) callconv(CC) u32,
        get_Content: ?*const anyopaque,
        put_Content: *const fn (*ICoreWebView2WebResourceResponse, stream: ?*anyopaque) callconv(CC) HResult,
        get_Headers: ?*const anyopaque,
        get_StatusCode: ?*const anyopaque,
        put_StatusCode: *const fn (*ICoreWebView2WebResourceResponse, status_code: i32) callconv(CC) HResult,
        get_ReasonPhrase: ?*const anyopaque,
        put_ReasonPhrase: *const fn (*ICoreWebView2WebResourceResponse, reason_phrase: [*:0]const u16) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2WebResourceResponse) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2WebResourceResponse = guid("aafcc94f-fa27-48fd-97df-830ef75aaec9");

pub const ICoreWebView2WebResourceRequestedEventArgs = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2WebResourceRequestedEventArgs) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2WebResourceRequestedEventArgs) callconv(CC) u32,
        get_Request: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, out: *?*ICoreWebView2WebResourceRequest) callconv(CC) HResult,
        get_Response: ?*const anyopaque,
        put_Response: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, response: ?*ICoreWebView2WebResourceResponse) callconv(CC) HResult,
        GetDeferral: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, out: *?*ICoreWebView2Deferral) callconv(CC) HResult,
        get_ResourceContext: ?*const anyopaque,
    };

    pub inline fn vt(self: *const ICoreWebView2WebResourceRequestedEventArgs) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2WebResourceRequestedEventArgs = guid("453e667f-12c7-49d4-be6d-ddbe7956f57a");

pub const ICoreWebView2Deferral = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Deferral, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2Deferral) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2Deferral) callconv(CC) u32,
        Complete: *const fn (*ICoreWebView2Deferral) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2Deferral) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2Deferral = guid("c10e7f7b-b585-46f0-a623-8befbf3e4ee0");

pub const ICoreWebView2HttpRequestHeaders = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2HttpRequestHeaders, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2HttpRequestHeaders) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2HttpRequestHeaders) callconv(CC) u32,
        GetHeader: ?*const anyopaque,
        GetHeaders: ?*const anyopaque,
        Contains: ?*const anyopaque,
        SetHeader: ?*const anyopaque,
        RemoveHeader: ?*const anyopaque,
        GetIterator: *const fn (*ICoreWebView2HttpRequestHeaders, out: *?*ICoreWebView2HttpHeadersCollectionIterator) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2HttpRequestHeaders) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2HttpRequestHeaders = guid("e86cac0e-5523-465c-b536-8fb9fc8c8c60");

pub const ICoreWebView2HttpHeadersCollectionIterator = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2HttpHeadersCollectionIterator, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2HttpHeadersCollectionIterator) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2HttpHeadersCollectionIterator) callconv(CC) u32,
        GetCurrentHeader: *const fn (*ICoreWebView2HttpHeadersCollectionIterator, name: *?PWStr, value: *?PWStr) callconv(CC) HResult,
        get_HasCurrentHeader: *const fn (*ICoreWebView2HttpHeadersCollectionIterator, out: *i32) callconv(CC) HResult,
        MoveNext: *const fn (*ICoreWebView2HttpHeadersCollectionIterator, out: *i32) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2HttpHeadersCollectionIterator) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2HttpHeadersCollectionIterator = guid("0702fc30-f43b-47bb-ab52-a42cb552ad9f");

pub const ICoreWebView2WebMessageReceivedEventArgs = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2WebMessageReceivedEventArgs) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2WebMessageReceivedEventArgs) callconv(CC) u32,
        get_Source: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, out: *?PWStr) callconv(CC) HResult,
        get_WebMessageAsJson: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, out: *?PWStr) callconv(CC) HResult,
        TryGetWebMessageAsString: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, out: *?PWStr) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2WebMessageReceivedEventArgs) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2WebMessageReceivedEventArgs = guid("0f99a40c-e962-4207-9e92-e3d542eff849");

pub const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(CC) u32,
        Invoke: *const fn (*ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, hresult: HResult, result: ?*ICoreWebView2Environment) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = guid("4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d");

pub const ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(CC) u32,
        Invoke: *const fn (*ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, hresult: HResult, result: ?*ICoreWebView2Controller) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = guid("6c4819f3-c9b7-4260-8127-c9f5bde7f68c");

pub const ICoreWebView2WebMessageReceivedEventHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebMessageReceivedEventHandler, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2WebMessageReceivedEventHandler) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2WebMessageReceivedEventHandler) callconv(CC) u32,
        Invoke: *const fn (*ICoreWebView2WebMessageReceivedEventHandler, sender: *ICoreWebView2, args: *ICoreWebView2WebMessageReceivedEventArgs) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2WebMessageReceivedEventHandler) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2WebMessageReceivedEventHandler = guid("57213f19-00e6-49fa-8e07-898ea01ecbd2");

pub const ICoreWebView2WebResourceRequestedEventHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceRequestedEventHandler, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2WebResourceRequestedEventHandler) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2WebResourceRequestedEventHandler) callconv(CC) u32,
        Invoke: *const fn (*ICoreWebView2WebResourceRequestedEventHandler, sender: *ICoreWebView2, args: *ICoreWebView2WebResourceRequestedEventArgs) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2WebResourceRequestedEventHandler) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2WebResourceRequestedEventHandler = guid("ab00b74c-15f1-4646-80e8-e76341d25d71");

pub const ICoreWebView2WindowCloseRequestedEventHandler = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WindowCloseRequestedEventHandler, *const Guid, out: ?*?*anyopaque) callconv(CC) HResult,
        AddRef: *const fn (*ICoreWebView2WindowCloseRequestedEventHandler) callconv(CC) u32,
        Release: *const fn (*ICoreWebView2WindowCloseRequestedEventHandler) callconv(CC) u32,
        Invoke: *const fn (*ICoreWebView2WindowCloseRequestedEventHandler, sender: *ICoreWebView2, args: ?*anyopaque) callconv(CC) HResult,
    };

    pub inline fn vt(self: *const ICoreWebView2WindowCloseRequestedEventHandler) *const VTable {
        return self.vtable;
    }
};
pub const IID_ICoreWebView2WindowCloseRequestedEventHandler = guid("5c19e9e0-092f-486b-affa-ca8231913039");

// ---------------------------------------------------------------------------
// Layout proof: every vtable slot is one pointer wide, in header order.
// ---------------------------------------------------------------------------
comptime {
    std.debug.assert(@sizeOf(ICoreWebView2Environment.VTable) == 8 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2Controller.VTable) == 26 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2.VTable) == 61 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2Settings.VTable) == 21 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2WebResourceRequest.VTable) == 10 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2WebResourceResponse.VTable) == 10 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2WebResourceRequestedEventArgs.VTable) == 8 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2Deferral.VTable) == 4 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2HttpRequestHeaders.VTable) == 9 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2HttpHeadersCollectionIterator.VTable) == 6 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2WebMessageReceivedEventArgs.VTable) == 6 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler.VTable) == 4 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler.VTable) == 4 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2WebMessageReceivedEventHandler.VTable) == 4 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2WebResourceRequestedEventHandler.VTable) == 4 * @sizeOf(*anyopaque));
    std.debug.assert(@sizeOf(ICoreWebView2WindowCloseRequestedEventHandler.VTable) == 4 * @sizeOf(*anyopaque));
}

test "GUID parsing matches the SDK's IID literals" {
    const c = guid("76eceacb-0462-4d94-ac83-423a6793775e");
    try std.testing.expectEqual(@as(u32, 0x76eceacb), c.d1);
    try std.testing.expectEqual(@as(u16, 0x0462), c.d2);
    try std.testing.expectEqual(@as(u16, 0x4d94), c.d3);
    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x83, 0x42, 0x3a, 0x67, 0x93, 0x77, 0x5e }, &c.d4);
    try std.testing.expectEqual(IID_ICoreWebView2.d1, c.d1);
}
