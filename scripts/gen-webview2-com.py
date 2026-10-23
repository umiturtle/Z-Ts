#!/usr/bin/env python3
"""Generate `src/webview/webview2_com.zig` (COM ABI for WebView2) from Microsoft's `WebView2.h`.

Why generate instead of `@cImport` / `addTranslateC`?
    `AGENTS.md` §2.3 forbids translating Microsoft's 2.9 MB `WebView2.h` on every cold build
    (+50 s per Arena chat). The generated file is ~1 kLOC of pure Zig, links in milliseconds and
    keeps `zts_webview` free of `@cImport` forever.

Why is `WebView2.h` not vendored?
    It is a 2.9 MB third-party artifact. Only the *vtable order* is needed, which this script
    extracts deterministically. Re-run it whenever bumping the WebView2 SDK:

    ```bash
    curl -L -o /tmp/WebView2.h \\
      https://raw.githubusercontent.com/sumatrapdfreader/sumatrapdf/master/ext/webview2/WebView2.h
    python3 scripts/gen-webview2-com.py /tmp/WebView2.h
    ```

Usage:
    python3 scripts/gen-webview2-com.py <path-to-WebView2.h> [-o src/webview/webview2_com.zig]
"""

from __future__ import annotations

import argparse
import re
import sys

# ---------------------------------------------------------------------------
# Interfaces that `windows.zig` / `webview2_loader.zig` actually touch.
# Every method NOT listed here becomes an erased `?*const anyopaque` slot so the
# vtable keeps its exact COM layout while staying auditable.
# ---------------------------------------------------------------------------

# iface -> {method: (params_after_this, ret)}
TYPED: dict[str, dict[str, tuple[str, str]]] = {
    "ICoreWebView2Environment": {
        "CreateCoreWebView2Controller": ("hwnd: ?*anyopaque, handler: ?*anyopaque", "HResult"),
        "CreateWebResourceResponse": (
            "content: ?*anyopaque, status_code: i32, reason: ?[*:0]const u16, "
            "headers: ?[*:0]const u16, response: *?*ICoreWebView2WebResourceResponse",
            "HResult",
        ),
    },
    "ICoreWebView2Controller": {
        "put_IsVisible": ("visible: i32", "HResult"),
        "put_Bounds": ("bounds: Rect", "HResult"),
        "MoveFocus": ("reason: i32", "HResult"),
        "Close": ("", "HResult"),
        "get_CoreWebView2": ("out: *?*ICoreWebView2", "HResult"),
    },
    "ICoreWebView2": {
        "get_Settings": ("out: *?*ICoreWebView2Settings", "HResult"),
        "get_Source": ("out: *?PWStr", "HResult"),
        "Navigate": ("uri: [*:0]const u16", "HResult"),
        "NavigateToString": ("html: [*:0]const u16", "HResult"),
        "AddScriptToExecuteOnDocumentCreated": ("script: [*:0]const u16, handler: ?*anyopaque", "HResult"),
        "ExecuteScript": ("script: [*:0]const u16, handler: ?*anyopaque", "HResult"),
        "PostWebMessageAsJson": ("msg: [*:0]const u16", "HResult"),
        "PostWebMessageAsString": ("msg: [*:0]const u16", "HResult"),
        "add_WebMessageReceived": ("handler: ?*anyopaque, token: *i64", "HResult"),
        "add_WebResourceRequested": ("handler: ?*anyopaque, token: *i64", "HResult"),
        "add_WindowCloseRequested": ("handler: ?*anyopaque, token: *i64", "HResult"),
        "AddWebResourceRequestedFilter": ("uri: [*:0]const u16, resource_context: i32", "HResult"),
        "OpenDevToolsWindow": ("", "HResult"),
        "Reload": ("", "HResult"),
        "Stop": ("", "HResult"),
    },
    "ICoreWebView2Settings": {
        "put_AreDevToolsEnabled": ("value: i32", "HResult"),
        "put_IsStatusBarEnabled": ("value: i32", "HResult"),
        "put_IsScriptEnabled": ("value: i32", "HResult"),
        "put_IsWebMessageEnabled": ("value: i32", "HResult"),
    },
    "ICoreWebView2WebResourceRequest": {
        "get_Uri": ("out: *?PWStr", "HResult"),
        "get_Method": ("out: *?PWStr", "HResult"),
        "get_Content": ("out: *?*anyopaque", "HResult"),
        "get_Headers": ("out: *?*ICoreWebView2HttpRequestHeaders", "HResult"),
    },
    "ICoreWebView2WebResourceResponse": {
        "put_Content": ("stream: ?*anyopaque", "HResult"),
        "put_StatusCode": ("status_code: i32", "HResult"),
        "put_ReasonPhrase": ("reason_phrase: [*:0]const u16", "HResult"),
    },
    "ICoreWebView2WebResourceRequestedEventArgs": {
        "get_Request": ("out: *?*ICoreWebView2WebResourceRequest", "HResult"),
        "put_Response": ("response: ?*ICoreWebView2WebResourceResponse", "HResult"),
        "GetDeferral": ("out: *?*ICoreWebView2Deferral", "HResult"),
    },
    "ICoreWebView2Deferral": {
        "Complete": ("", "HResult"),
    },
    "ICoreWebView2HttpRequestHeaders": {
        "GetIterator": ("out: *?*ICoreWebView2HttpHeadersCollectionIterator", "HResult"),
    },
    "ICoreWebView2HttpHeadersCollectionIterator": {
        "GetCurrentHeader": ("name: *?PWStr, value: *?PWStr", "HResult"),
        "get_HasCurrentHeader": ("out: *i32", "HResult"),
        "MoveNext": ("out: *i32", "HResult"),
    },
    "ICoreWebView2WebMessageReceivedEventArgs": {
        "get_Source": ("out: *?PWStr", "HResult"),
        "get_WebMessageAsJson": ("out: *?PWStr", "HResult"),
        "TryGetWebMessageAsString": ("out: *?PWStr", "HResult"),
    },
    # --- Event handlers: identical shape (IUnknown + Invoke), different payloads -------------
    "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler": {
        "Invoke": ("hresult: HResult, result: ?*ICoreWebView2Environment", "HResult"),
    },
    "ICoreWebView2CreateCoreWebView2ControllerCompletedHandler": {
        "Invoke": ("hresult: HResult, result: ?*ICoreWebView2Controller", "HResult"),
    },
    "ICoreWebView2WebMessageReceivedEventHandler": {
        "Invoke": ("sender: *ICoreWebView2, args: *ICoreWebView2WebMessageReceivedEventArgs", "HResult"),
    },
    "ICoreWebView2WebResourceRequestedEventHandler": {
        "Invoke": ("sender: *ICoreWebView2, args: *ICoreWebView2WebResourceRequestedEventArgs", "HResult"),
    },
    "ICoreWebView2WindowCloseRequestedEventHandler": {
        "Invoke": ("sender: *ICoreWebView2, args: ?*anyopaque", "HResult"),
    },
}


def parse_header(path: str) -> tuple[dict[str, list[str]], dict[str, str]]:
    src = open(path, encoding="utf-8", errors="replace").read().replace("\r\n", "\n")

    vtables: dict[str, list[str]] = {}
    for m in re.finditer(r"typedef struct (\w+)Vtbl\s*\n?\s*\{(.*?)\n\s*\} (\w+)Vtbl;", src, re.S):
        name, body, name2 = m.group(1), m.group(2), m.group(3)
        if name != name2:
            continue
        methods = re.findall(r"STDMETHODCALLTYPE \*(\w+) \)\s*\(", body)
        if methods:
            vtables[name] = methods

    guids: dict[str, str] = {}
    for name in TYPED:
        m = re.search(r'MIDL_INTERFACE\("([0-9A-Fa-f\-]+)"\)\s*\n\s*' + name + r"\s*:", src)
        if m:
            guids[name] = m.group(1)
    return vtables, guids


def emit(vtables: dict[str, list[str]], guids: dict[str, str]) -> str:
    out: list[str] = []
    w = out.append

    w("//! WebView2 COM interfaces — **GENERATED, DO NOT EDIT** (`M3-02`).")
    w("//!")
    w("//! Regenerate with:")
    w("//! ```bash")
    w("//! python3 scripts/gen-webview2-com.py /tmp/WebView2.h")
    w("//! ```")
    w("//!")
    w("//! Only the vtable *order* is taken from Microsoft's header; methods that `zts_webview` never")
    w("//! calls stay as erased `?*const anyopaque` slots, so every struct below is byte-for-byte the")
    w("//! real COM layout (`comptime` size assertions at the bottom prove it).")
    w("")
    w('const std = @import("std");')
    w("")
    w("/// `HRESULT` (`long` on Win32).")
    w("pub const HResult = i32;")
    w("")
    w("pub const S_OK: HResult = 0;")
    w("pub const S_FALSE: HResult = 1;")
    w("pub const E_NOINTERFACE: HResult = @bitCast(@as(u32, 0x80004002));")
    w("pub const E_POINTER: HResult = @bitCast(@as(u32, 0x80004003));")
    w("pub const E_INVALIDARG: HResult = @bitCast(@as(u32, 0x80070057));")
    w("pub const E_OUTOFMEMORY: HResult = @bitCast(@as(u32, 0x8007000E));")
    w("pub const E_FAIL: HResult = @bitCast(@as(u32, 0x80004005));")
    w("pub const E_UNEXPECTED: HResult = @bitCast(@as(u32, 0x8000FFFF));")
    w("")
    w("pub inline fn failed(hr: HResult) bool {")
    w("    return hr < 0;")
    w("}")
    w("")
    w("/// `PWSTR` / `LPWSTR` — CoTaskMem-allocated UTF-16 string owned by the CALLER after a getter.")
    w("pub const PWStr = [*:0]u16;")
    w("")
    w("/// Win32 `RECT` (physical pixels, top-left origin — same convention as CSS).")
    w("pub const Rect = extern struct {")
    w("    left: i32 = 0,")
    w("    top: i32 = 0,")
    w("    right: i32 = 0,")
    w("    bottom: i32 = 0,")
    w("};")
    w("")
    w("pub const Guid = extern struct {")
    w("    d1: u32,")
    w("    d2: u16,")
    w("    d3: u16,")
    w("    d4: [8]u8,")
    w("};")
    w("")
    w("/// Parses a canonical `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` GUID at `comptime`.")
    w("pub fn guid(comptime text: []const u8) Guid {")
    w("    std.debug.assert(text.len == 36);")
    w("    return .{")
    w("        .d1 = parseU32(text[0..8]),")
    w("        .d2 = parseU16(text[9..13]),")
    w("        .d3 = parseU16(text[14..18]),")
    w("        .d4 = .{")
    w("            parseByte(text[19..21]), parseByte(text[21..23]),")
    w("            parseByte(text[24..26]), parseByte(text[26..28]),")
    w("            parseByte(text[28..30]), parseByte(text[30..32]),")
    w("            parseByte(text[32..34]), parseByte(text[34..36]),")
    w("        },")
    w("    };")
    w("}")
    w("")
    w("fn parseByte(comptime s: []const u8) u8 {")
    w("    return (hexDigit(s[0]) << 4) | hexDigit(s[1]);")
    w("}")
    w("")
    w("fn hexDigit(c: u8) u8 {")
    w("    return switch (c) {")
    w("        '0'...'9' => c - '0',")
    w("        'a'...'f' => c - 'a' + 10,")
    w("        'A'...'F' => c - 'A' + 10,")
    w("        else => @compileError(\"invalid hex digit\"),")
    w("    };")
    w("}")
    w("")
    w("fn parseU16(comptime s: []const u8) u16 {")
    w("    var out: u16 = 0;")
    w("    for (s) |c| {")
    w("        if (c == '-') continue;")
    w("        out = out * 16 + hexDigit(c);")
    w("    }")
    w("    return out;")
    w("}")
    w("")
    w("fn parseU32(comptime s: []const u8) u32 {")
    w("    var out: u32 = 0;")
    w("    for (s) |c| {")
    w("        if (c == '-') continue;")
    w("        out = out * 16 + hexDigit(c);")
    w("    }")
    w("    return out;")
    w("}")
    w("")

    for name in TYPED:
        if name not in vtables:
            sys.exit(f"error: interface {name} not found in the header")
        methods = vtables[name]
        typed = TYPED[name]
        missing = set(typed) - set(methods)
        if missing:
            sys.exit(f"error: {name} lacks {sorted(missing)} — header/SDK mismatch?")
        w(f"pub const {name} = extern struct {{")
        w("    vtable: *const VTable,")
        w("")
        w("    pub const VTable = extern struct {")
        for idx, m in enumerate(methods):
            if idx == 0:
                w(f"        QueryInterface: *const fn (*{name}, *const Guid, out: ?*?*anyopaque) callconv(.winapi) HResult,")
            elif idx == 1:
                w(f"        AddRef: *const fn (*{name}) callconv(.winapi) u32,")
            elif idx == 2:
                w(f"        Release: *const fn (*{name}) callconv(.winapi) u32,")
            elif m in typed:
                params, ret = typed[m]
                w(f"        {m}: *const fn (*{name}{', ' if params else ''}{params}) callconv(.winapi) {ret},")
            else:
                w(f"        {m}: ?*const anyopaque,")
        w("    };")
        w("")
        w("    pub inline fn vt(self: *const " + name + ") *const VTable {")
        w("        return self.vtable;")
        w("    }")
        w("};")
        w(f"pub const IID_{name} = guid(\"{guids[name]}\");")
        w("")

    w("// ---------------------------------------------------------------------------")
    w("// Layout proof: every vtable slot is one pointer wide, in header order.")
    w("// ---------------------------------------------------------------------------")
    w("comptime {")
    for name in TYPED:
        n = len(vtables[name])
        w(f"    std.debug.assert(@sizeOf({name}.VTable) == {n} * @sizeOf(*anyopaque));")
    w("}")
    w("")
    w("test \"GUID parsing matches the SDK's IID literals\" {")
    w("    const c = guid(\"76eceacb-0462-4d94-ac83-423a6793775e\");")
    w("    try std.testing.expectEqual(@as(u32, 0x76eceacb), c.d1);")
    w("    try std.testing.expectEqual(@as(u16, 0x0462), c.d2);")
    w("    try std.testing.expectEqual(@as(u16, 0x4d94), c.d3);")
    w("    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x83, 0x42, 0x3a, 0x67, 0x93, 0x77, 0x5e }, &c.d4);")
    w("    try std.testing.expectEqual(IID_ICoreWebView2.d1, c.d1);")
    w("}")
    w("")
    return "\n".join(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("header", help="path to Microsoft's WebView2.h")
    ap.add_argument("-o", "--out", default="src/webview/webview2_com.zig")
    args = ap.parse_args()

    vtables, guids = parse_header(args.header)
    missing_guids = [n for n in TYPED if n not in guids]
    if missing_guids:
        sys.exit(f"error: missing IIDs for {missing_guids}")

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(emit(vtables, guids))
    print(f"wrote {args.out} ({len(TYPED)} interfaces)")


if __name__ == "__main__":
    main()
