#!/usr/bin/env python3
"""Generate `src/webview/webview2_com.zig` from Microsoft's `WebView2.h` (`M3-02`).

Why a generator at all?

* The COM vtable **order** is the ABI. Hand-writing 61 slots for `ICoreWebView2` invites
  off-by-one bugs that only show up as a crash on a Windows runner we cannot attach a debugger to.
* `WebView2.h` is 2.9 MB / 68,921 lines and `@cImport` is gone in Zig 0.17, so we cannot translate
  it at build time without paying a large cold-build penalty (see ADR-0001 / ADR-0007).

So: parse the header once, emit a small auditable Zig file, **commit the output**. Builds stay
dependency-free (no Python, no SDK); regenerating only happens when the WebView2 SDK is bumped.

Usage:
    python3 scripts/gen-webview2-com.py /path/to/WebView2.h [-o src/webview/webview2_com.zig]

`WebView2.h` ships with the WebView2 SDK (NuGet `Microsoft.Web.WebView2`). A copy also lives in
`sumatrapdfreader/sumatrapdf` under `ext/webview2/WebView2.h`, which is where this script was
developed against (same MIDL output as the SDK).

Only the *interface field order* is taken from the header: methods we never call stay as erased
`?*const anyopaque` slots — byte-for-byte the same size, and impossible to call by accident.
"""

from __future__ import annotations

import argparse
import re
import sys

# ---------------------------------------------------------------------------
# Interfaces we expose, and the exact Zig signature of the methods we call.
#
# `*this` is always the first parameter. Everything not listed becomes a placeholder slot.
# ---------------------------------------------------------------------------
INTERFACES: dict[str, dict[str, str]] = {
    "ICoreWebView2Environment": {
        "CreateCoreWebView2Controller": "(this: *ICoreWebView2Environment, parent: ?*anyopaque, handler: ?*anyopaque) callconv(CALL) HResult",
        "CreateWebResourceResponse": (
            "(this: *ICoreWebView2Environment, content: ?*anyopaque, status: i32,"
            " reason: ?[*:0]const u16, headers: ?[*:0]const u16,"
            " response: *?*ICoreWebView2WebResourceResponse) callconv(CALL) HResult"
        ),
    },
    "ICoreWebView2Controller": {
        "put_IsVisible": "(this: *ICoreWebView2Controller, visible: BOOL) callconv(CALL) HResult",
        "put_Bounds": "(this: *ICoreWebView2Controller, bounds: Rect) callconv(CALL) HResult",
        "put_ZoomFactor": "(this: *ICoreWebView2Controller, factor: f64) callconv(CALL) HResult",
        "MoveFocus": "(this: *ICoreWebView2Controller, reason: i32) callconv(CALL) HResult",
        "put_ParentWindow": "(this: *ICoreWebView2Controller, parent: ?*anyopaque) callconv(CALL) HResult",
        "NotifyParentWindowPositionChanged": "(this: *ICoreWebView2Controller) callconv(CALL) HResult",
        "Close": "(this: *ICoreWebView2Controller) callconv(CALL) HResult",
        "get_CoreWebView2": "(this: *ICoreWebView2Controller, out: *?*ICoreWebView2) callconv(CALL) HResult",
    },
    "ICoreWebView2Controller2": {
        "put_DefaultBackgroundColor": "(this: *ICoreWebView2Controller2, value: Color) callconv(CALL) HResult",
    },
    "ICoreWebView2": {
        "get_Settings": "(this: *ICoreWebView2, out: *?*ICoreWebView2Settings) callconv(CALL) HResult",
        "get_Source": "(this: *ICoreWebView2, out: *?PWStr) callconv(CALL) HResult",
        "Navigate": "(this: *ICoreWebView2, uri: [*:0]const u16) callconv(CALL) HResult",
        "NavigateToString": "(this: *ICoreWebView2, html: [*:0]const u16) callconv(CALL) HResult",
        "Reload": "(this: *ICoreWebView2) callconv(CALL) HResult",
        "Stop": "(this: *ICoreWebView2) callconv(CALL) HResult",
        "AddScriptToExecuteOnDocumentCreated": "(this: *ICoreWebView2, script: [*:0]const u16, handler: ?*anyopaque) callconv(CALL) HResult",
        "RemoveScriptToExecuteOnDocumentCreated": "(this: *ICoreWebView2, id: [*:0]const u16) callconv(CALL) HResult",
        "ExecuteScript": "(this: *ICoreWebView2, script: [*:0]const u16, handler: ?*anyopaque) callconv(CALL) HResult",
        "PostWebMessageAsJson": "(this: *ICoreWebView2, json: [*:0]const u16) callconv(CALL) HResult",
        "PostWebMessageAsString": "(this: *ICoreWebView2, message: [*:0]const u16) callconv(CALL) HResult",
        "add_WebMessageReceived": "(this: *ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CALL) HResult",
        "remove_WebMessageReceived": "(this: *ICoreWebView2, token: i64) callconv(CALL) HResult",
        "add_WebResourceRequested": "(this: *ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CALL) HResult",
        "remove_WebResourceRequested": "(this: *ICoreWebView2, token: i64) callconv(CALL) HResult",
        "add_WindowCloseRequested": "(this: *ICoreWebView2, handler: ?*anyopaque, token: *i64) callconv(CALL) HResult",
        "remove_WindowCloseRequested": "(this: *ICoreWebView2, token: i64) callconv(CALL) HResult",
        "AddWebResourceRequestedFilter": "(this: *ICoreWebView2, uri: [*:0]const u16, resource_context: i32) callconv(CALL) HResult",
        "OpenDevToolsWindow": "(this: *ICoreWebView2) callconv(CALL) HResult",
    },
    "ICoreWebView2Settings": {
        "put_IsScriptEnabled": "(this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult",
        "put_IsWebMessageEnabled": "(this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult",
        "put_AreDevToolsEnabled": "(this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult",
        "put_AreDefaultContextMenusEnabled": "(this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult",
        "put_IsStatusBarEnabled": "(this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult",
        "put_AreDefaultScriptDialogsEnabled": "(this: *ICoreWebView2Settings, enabled: BOOL) callconv(CALL) HResult",
    },
    "ICoreWebView2WebResourceRequest": {
        "get_Uri": "(this: *ICoreWebView2WebResourceRequest, out: *?PWStr) callconv(CALL) HResult",
        "get_Method": "(this: *ICoreWebView2WebResourceRequest, out: *?PWStr) callconv(CALL) HResult",
        "get_Content": "(this: *ICoreWebView2WebResourceRequest, out: *?*anyopaque) callconv(CALL) HResult",
        "get_Headers": "(this: *ICoreWebView2WebResourceRequest, out: *?*ICoreWebView2HttpRequestHeaders) callconv(CALL) HResult",
    },
    "ICoreWebView2WebResourceResponse": {
        "put_Content": "(this: *ICoreWebView2WebResourceResponse, stream: ?*anyopaque) callconv(CALL) HResult",
        "put_StatusCode": "(this: *ICoreWebView2WebResourceResponse, status: i32) callconv(CALL) HResult",
        "put_ReasonPhrase": "(this: *ICoreWebView2WebResourceResponse, reason: [*:0]const u16) callconv(CALL) HResult",
    },
    "ICoreWebView2WebResourceRequestedEventArgs": {
        "get_Request": "(this: *ICoreWebView2WebResourceRequestedEventArgs, out: *?*ICoreWebView2WebResourceRequest) callconv(CALL) HResult",
        "put_Response": "(this: *ICoreWebView2WebResourceRequestedEventArgs, response: ?*ICoreWebView2WebResourceResponse) callconv(CALL) HResult",
        "GetDeferral": "(this: *ICoreWebView2WebResourceRequestedEventArgs, out: *?*ICoreWebView2Deferral) callconv(CALL) HResult",
    },
    "ICoreWebView2Deferral": {
        "Complete": "(this: *ICoreWebView2Deferral) callconv(CALL) HResult",
    },
    "ICoreWebView2HttpRequestHeaders": {
        "GetIterator": "(this: *ICoreWebView2HttpRequestHeaders, out: *?*ICoreWebView2HttpHeadersCollectionIterator) callconv(CALL) HResult",
    },
    "ICoreWebView2HttpHeadersCollectionIterator": {
        "GetCurrentHeader": "(this: *ICoreWebView2HttpHeadersCollectionIterator, name: *?PWStr, value: *?PWStr) callconv(CALL) HResult",
        "get_HasCurrentHeader": "(this: *ICoreWebView2HttpHeadersCollectionIterator, out: *BOOL) callconv(CALL) HResult",
        "MoveNext": "(this: *ICoreWebView2HttpHeadersCollectionIterator, out: *BOOL) callconv(CALL) HResult",
    },
    "ICoreWebView2WebMessageReceivedEventArgs": {
        "get_WebMessageAsJson": "(this: *ICoreWebView2WebMessageReceivedEventArgs, out: *?PWStr) callconv(CALL) HResult",
        "TryGetWebMessageAsString": "(this: *ICoreWebView2WebMessageReceivedEventArgs, out: *?PWStr) callconv(CALL) HResult",
    },
    # --- event handlers (4 slots each; `Invoke` is the only interesting one) ---
    "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler": {
        "Invoke": (
            "(this: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, hr: HResult,"
            " env: ?*ICoreWebView2Environment) callconv(CALL) HResult"
        ),
    },
    "ICoreWebView2CreateCoreWebView2ControllerCompletedHandler": {
        "Invoke": (
            "(this: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, hr: HResult,"
            " controller: ?*ICoreWebView2Controller) callconv(CALL) HResult"
        ),
    },
    "ICoreWebView2WebMessageReceivedEventHandler": {
        "Invoke": (
            "(this: *ICoreWebView2WebMessageReceivedEventHandler, sender: ?*ICoreWebView2,"
            " args: ?*ICoreWebView2WebMessageReceivedEventArgs) callconv(CALL) HResult"
        ),
    },
    "ICoreWebView2WebResourceRequestedEventHandler": {
        "Invoke": (
            "(this: *ICoreWebView2WebResourceRequestedEventHandler, sender: ?*ICoreWebView2,"
            " args: ?*ICoreWebView2WebResourceRequestedEventArgs) callconv(CALL) HResult"
        ),
    },
    "ICoreWebView2WindowCloseRequestedEventHandler": {
        "Invoke": (
            "(this: *ICoreWebView2WindowCloseRequestedEventHandler, sender: ?*ICoreWebView2,"
            " args: ?*anyopaque) callconv(CALL) HResult"
        ),
    },
}

HEADER = r'''//! WebView2 COM interfaces — **GENERATED, DO NOT EDIT** (`src/webview/webview2_com.zig`, `M3-02`).
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
'''


def parse_vtables(header: str, name: str) -> list[str]:
    m = re.search(
        r"typedef struct " + re.escape(name) + r"Vtbl\s*\{(.*?)\n\s*END_INTERFACE",
        header,
        re.S,
    )
    if not m:
        sys.exit(f"error: {name}Vtbl not found in the header")
    return re.findall(r"DECLSPEC_XFGVIRT\(\s*[\w:]+,\s*(\w+)\s*\)", m.group(1))


def parse_iid(header: str, name: str) -> str:
    m = re.search(
        r'MIDL_INTERFACE\("([0-9a-fA-F-]{36})"\)\s*\n\s*' + re.escape(name) + r"\s*:",
        header,
    )
    if not m:
        sys.exit(f"error: IID for {name} not found in the header")
    return m.group(1).lower()


def emit(header: str) -> str:
    out: list[str] = [HEADER]

    for name, typed in INTERFACES.items():
        slots = parse_vtables(header, name)
        iid = parse_iid(header, name)

        out.append("")
        out.append(f"/// `{name}` ({len(slots)} vtable slots — order is the ABI).")
        out.append(f"pub const {name} = extern struct {{")
        out.append("    vtable: *const VTable,")
        out.append("")
        out.append("    pub const VTable = extern struct {")
        for slot in slots:
            if slot == "QueryInterface":
                out.append(
                    f"        QueryInterface: *const fn (this: *{name}, riid: *const Guid,"
                    " out: *?*anyopaque) callconv(CALL) HResult,"
                )
            elif slot in ("AddRef", "Release"):
                out.append(f"        {slot}: *const fn (this: *{name}) callconv(CALL) u32,")
            elif slot in typed:
                out.append(f"        {slot}: *const fn {typed[slot]},")
            else:
                out.append(f"        {slot}: ?*const anyopaque,")
        out.append("    };")
        out.append("};")
        out.append("")
        out.append(f'pub const IID_{name} = guid("{iid}");')

    out.append("")
    out.append("// ---------------------------------------------------------------------------")
    out.append("// ABI assertions — the entire point of this file.")
    out.append("// ---------------------------------------------------------------------------")
    out.append("comptime {")
    for name in INTERFACES:
        n = len(parse_vtables(header, name))
        out.append(f"    std.debug.assert(@sizeOf({name}.VTable) == {n} * @sizeOf(usize));")
    out.append("    std.debug.assert(@sizeOf(Guid) == 16);")
    out.append("    std.debug.assert(@sizeOf(Rect) == 16);")
    out.append("    std.debug.assert(@sizeOf(Color) == 4);")
    out.append("}")
    out.append("")
    out.append('test "GUID parser matches the SDK and every IID is 128-bit" {')
    out.append('    const c = guid("76eceacb-0462-4d94-ac83-423a6793775e");')
    out.append("    try std.testing.expectEqual(@as(u32, 0x76eceacb), c.d1);")
    out.append("    try std.testing.expectEqual(@as(u16, 0x0462), c.d2);")
    out.append("    try std.testing.expectEqual(@as(u16, 0x4d94), c.d3);")
    out.append(
        "    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x83, 0x42, 0x3a, 0x67, 0x93, 0x77, 0x5e }, &c.d4);"
    )
    out.append("    try std.testing.expectEqual(c.d1, IID_ICoreWebView2.d1);")
    out.append("    try std.testing.expectEqual(@as(u32, 0x0000_0000), IID_IUnknown.d1);")
    out.append('    try std.testing.expectEqual(@as(u16, 0x0000), IID_IUnknown.d3);')
    out.append('    try std.testing.expectEqual(@as(u8, 0xc0), IID_IUnknown.d4[0]);')
    out.append("}")
    return "\n".join(out) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("header")
    ap.add_argument("-o", "--out", default="src/webview/webview2_com.zig")
    args = ap.parse_args()

    with open(args.header, encoding="utf-8", errors="replace") as fh:
        header = fh.read()

    text = emit(header)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)

    total = sum(len(parse_vtables(header, n)) for n in INTERFACES)
    print(
        f"wrote {args.out}: {len(INTERFACES)} interfaces / {total} vtable slots",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
