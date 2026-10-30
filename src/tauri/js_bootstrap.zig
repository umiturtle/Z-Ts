//! Tauri v2 Wire-Compatible JavaScript Bootstrap Generator (`src/tauri/js_bootstrap.zig`).
//!
//! Produces a self-contained (~2.8 KiB) initialization script injected at `AT_DOCUMENT_START`
//! (via `WebKitUserContentManager` / `WKUserScript` / `AddScriptToExecuteOnDocumentCreated`)
//! so **unmodified official `@tauri-apps/api` v2 packages** (`core`, `event`, `window`,
//! `webview`, `dpi`, `path`, `app`) run natively at full speed:
//!
//! 1. `window.isTauri = true`
//! 2. `window.__TAURI_INTERNALS__`:
//!    - `invoke`, `transformCallback`, `unregisterCallback`, `runCallback`, `callbacks`
//!    - `convertFileSrc` (`<scheme>://localhost/<encoded>` on Linux/macOS, `http://<scheme>.localhost/<encoded>` on Windows)
//!    - `ipc` & `postMessage` (Custom Protocol `POST ipc://...` with automatic fallback to `window.__ztsPostMessage`)
//!    - `metadata.{currentWindow, currentWebview}` & `plugins.path.{sep, delimiter}`
//! 3. `window.__TAURI_EVENT_PLUGIN_INTERNALS__.unregisterListener` + `window.__ztsRegisterEvent` / `window.__ztsDeliverEvent`
//! 4. Cross-platform frameless drag delegation for BOTH `[data-tauri-drag-region]` (`""`, `"true"`, `"deep"`, `"false"`,
//!    interactive element exclusion, double-click `internal_toggle_maximize`) AND CSS `-webkit-app-region: drag` (`M1-07` / Boundary #10).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const foundation = @import("zts_foundation");
const html_escape = foundation.html_escape;

/// Which OS convention the injected bootstrap script should follow. Windows resolves custom schemes
/// through `http://<scheme>.localhost/…`, the other two use `<scheme>://localhost/…`; the page must be
/// told which one it is talking to.
pub const OsTarget = enum {
    /// Linux (`linux` in the injected API).
    linux,
    /// macOS (`macos`).
    macos,
    /// Windows (`windows`).
    windows,

    /// The platform the bootstrap should report.
    pub fn current() OsTarget {
        return switch (builtin.os.tag) {
            .macos => .macos,
            .windows => .windows,
            else => .linux,
        };
    }

    /// The `platform()` string upstream returns.
    pub fn asTauriName(self: OsTarget) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
        };
    }

    /// `\` on Windows, `/` elsewhere.
    pub fn pathSep(self: OsTarget) []const u8 {
        return switch (self) {
            .windows => "\\",
            .linux, .macos => "/",
        };
    }

    /// `;` on Windows, `:` elsewhere.
    pub fn pathDelimiter(self: OsTarget) []const u8 {
        return switch (self) {
            .windows => ";",
            .linux, .macos => ":",
        };
    }
};

/// Inputs for the injected `window.__TAURI_INTERNALS__` script. `invoke_key` is the per-launch CSRF
/// secret; everything else adapts the script to the current window and OS.
pub const BootstrapOptions = struct {
    /// Window / Webview label reported through `getCurrentWindow().label`.
    label: []const u8 = "main",
    /// Target OS convention (`asset://localhost/...` vs `http://asset.localhost/...` & path separators).
    os: OsTarget = OsTarget.current(),
    /// Base scheme used on Windows sub-origin routing (`http://<protocol>.localhost/...`).
    protocol_scheme: []const u8 = "http",
    /// Secret per-launch key sent in `Tauri-Invoke-Key` on every IPC call.
    invoke_key: []const u8,
};

/// Writes the raw JavaScript initialization body (without `<script>` wrapper tags) for `addInitScript`.
pub fn writeScript(writer: *std.Io.Writer, opts: BootstrapOptions) std.Io.Writer.Error!void {
    try writer.writeAll(";(function(){if(window.__TAURI_INTERNALS__&&window.__TAURI_INTERNALS__.__ztsReady)return;");
    try writer.writeAll("const LABEL=");
    try html_escape.writeJsonString(writer, opts.label, true);
    try writer.writeAll(",OS=");
    try html_escape.writeJsonString(writer, opts.os.asTauriName(), true);
    try writer.writeAll(",PROTO=");
    try html_escape.writeJsonString(writer, opts.protocol_scheme, true);
    try writer.writeAll(",KEY=");
    try html_escape.writeJsonString(writer, opts.invoke_key, true);
    try writer.writeAll(",SEP=");
    try html_escape.writeJsonString(writer, opts.os.pathSep(), true);
    try writer.writeAll(",DELIM=");
    try html_escape.writeJsonString(writer, opts.os.pathDelimiter(), true);
    try writer.writeAll(";\n");
    try writer.writeAll(bootstrap_body_js);
}

/// Allocates the raw JavaScript initialization script suitable for `Engine.addInitScript`.
pub fn renderScriptAlloc(allocator: Allocator, opts: BootstrapOptions) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    writeScript(&aw.writer, opts) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Allocates an inline `<script>...</script>` block suitable for HTML `<head>` injection.
pub fn renderInlineHtmlTagAlloc(allocator: Allocator, opts: BootstrapOptions) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    aw.writer.writeAll("<script>") catch return error.OutOfMemory;
    writeScript(&aw.writer, opts) catch return error.OutOfMemory;
    aw.writer.writeAll("</script>") catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const bootstrap_body_js =
    \\const TO_IPC = "__TAURI_TO_IPC_KEY__";
    \\const callbacks = new Map();
    \\let fallbackSeq = 1;
    \\function uid() {
    \\  if (typeof crypto !== "undefined" && crypto.getRandomValues) {
    \\    const buf = new Uint32Array(1);
    \\    let id = 0;
    \\    do {
    \\      crypto.getRandomValues(buf);
    \\      id = buf[0] >>> 0;
    \\    } while (id === 0 || callbacks.has(id));
    \\    return id;
    \\  }
    \\  while (callbacks.has(fallbackSeq)) fallbackSeq = (fallbackSeq + 1) >>> 0 || 1;
    \\  return fallbackSeq++;
    \\}
    \\function convertFileSrc(filePath, protocol = "asset") {
    \\  const p = encodeURIComponent(filePath);
    \\  return OS === "windows" || OS === "android"
    \\    ? `${PROTO}://${protocol}.localhost/${p}`
    \\    : `${protocol}://localhost/${p}`;
    \\}
    \\function transformCallback(callback, once = false) {
    \\  const id = uid();
    \\  callbacks.set(id, (data) => {
    \\    if (once) callbacks.delete(id);
    \\    return callback && callback(data);
    \\  });
    \\  return id;
    \\}
    \\function unregisterCallback(id) {
    \\  callbacks.delete(id);
    \\}
    \\function runCallback(id, data) {
    \\  const cb = callbacks.get(id);
    \\  if (cb) cb(data);
    \\}
    \\function processIpcPayload(payload) {
    \\  if (payload instanceof ArrayBuffer || ArrayBuffer.isView(payload) || Array.isArray(payload)) {
    \\    const bytes = payload instanceof ArrayBuffer
    \\      ? new Uint8Array(payload)
    \\      : ArrayBuffer.isView(payload)
    \\        ? new Uint8Array(payload.buffer, payload.byteOffset, payload.byteLength)
    \\        : new Uint8Array(payload);
    \\    return { contentType: "application/octet-stream", data: bytes };
    \\  }
    \\  const data = JSON.stringify(payload === undefined ? {} : payload, (_k, val) => {
    \\    if (val instanceof Map) return Object.fromEntries(val.entries());
    \\    if (val instanceof Uint8Array) return Array.from(val);
    \\    if (val instanceof ArrayBuffer) return Array.from(new Uint8Array(val));
    \\    if (typeof val === "object" && val !== null && TO_IPC in val) {
    \\      return val[TO_IPC]();
    \\    }
    \\    return val;
    \\  });
    \\  return { contentType: "application/json", data };
    \\}
    \\let customProtocolFailed = false;
    \\function postViaNativeBridge(rawObj) {
    \\  const encoded = JSON.stringify(rawObj);
    \\  if (typeof window.__ztsPostMessage === "function") {
    \\    window.__ztsPostMessage(encoded);
    \\  } else if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.__zts) {
    \\    window.webkit.messageHandlers.__zts.postMessage(encoded);
    \\  } else if (window.chrome && window.chrome.webview) {
    \\    window.chrome.webview.postMessage(encoded);
    \\  } else if (window.ipc && typeof window.ipc.postMessage === "function") {
    \\    window.ipc.postMessage(encoded);
    \\  }
    \\}
    \\function sendIpcMessage(message) {
    \\  const { cmd, callback, error, payload, options } = message;
    \\  if (!customProtocolFailed) {
    \\    const { contentType, data } = processIpcPayload(payload);
    \\    const headers = new Headers((options && options.headers) || {});
    \\    headers.set("Content-Type", contentType);
    \\    headers.set("Tauri-Callback", String(callback));
    \\    headers.set("Tauri-Error", String(error));
    \\    headers.set("Tauri-Invoke-Key", KEY);
    \\    fetch(convertFileSrc(cmd, "ipc"), { method: "POST", body: data, headers })
    \\      .then((res) => {
    \\        const isOk = (res.headers.get("Tauri-Response") || (res.ok ? "ok" : "error")) === "ok";
    \\        const cbId = isOk ? callback : error;
    \\        const ct = (res.headers.get("content-type") || "").split(",")[0].split(";")[0].trim();
    \\        if (ct === "application/json") return res.json().then((r) => [cbId, r]);
    \\        if (ct === "text/plain") return res.text().then((r) => [cbId, r]);
    \\        return res.arrayBuffer().then((r) => [cbId, r]);
    \\      })
    \\      .then(
    \\        ([cbId, out]) => runCallback(cbId, out),
    \\        () => {
    \\          customProtocolFailed = true;
    \\          sendIpcMessage(message);
    \\        }
    \\      );
    \\  } else {
    \\    postViaNativeBridge({
    \\      cmd,
    \\      callback,
    \\      error,
    \\      payload,
    \\      __TAURI_INVOKE_KEY__: KEY
    \\    });
    \\  }
    \\}
    \\function invoke(cmd, payload = {}, options) {
    \\  return new Promise((resolve, reject) => {
    \\    const callback = transformCallback((r) => {
    \\      if (cmd === "plugin:event|listen" && payload && typeof payload.event === "string") {
    \\        registerEventListener(payload.event, r, payload.handler, payload.target);
    \\      }
    \\      resolve(r);
    \\      unregisterCallback(error);
    \\    }, true);
    \\    const error = transformCallback((e) => {
    \\      reject(e);
    \\      unregisterCallback(callback);
    \\    }, true);
    \\    sendIpcMessage({ cmd, callback, error, payload, options });
    \\  });
    \\}
    \\const eventRegistry = Object.create(null);
    \\const directListeners = new Map();
    \\function registerEventListener(eventName, eventId, handlerId, target) {
    \\  if (!eventRegistry[eventName]) eventRegistry[eventName] = Object.create(null);
    \\  eventRegistry[eventName][eventId] = { handlerId, target };
    \\}
    \\function deliverEvent(eventName, payload, eventIds) {
    \\  const direct = directListeners.get(eventName);
    \\  if (direct) for (const fn of direct) fn(payload);
    \\  const table = eventRegistry[eventName];
    \\  if (!table) return;
    \\  const ids = Array.isArray(eventIds) ? eventIds : Object.keys(table).map(Number);
    \\  for (const id of ids) {
    \\    const entry = table[id];
    \\    if (entry) runCallback(entry.handlerId, { event: eventName, id, payload });
    \\  }
    \\}
    \\const internals = {
    \\  __ztsReady: true,
    \\  invoke,
    \\  transformCallback,
    \\  unregisterCallback,
    \\  runCallback,
    \\  callbacks,
    \\  convertFileSrc,
    \\  postMessage: sendIpcMessage,
    \\  ipc: Object.freeze((msg) => sendIpcMessage(msg)),
    \\  metadata: {
    \\    currentWindow: { label: LABEL },
    \\    currentWebview: { label: LABEL, windowLabel: LABEL }
    \\  },
    \\  plugins: {
    \\    path: { sep: SEP, delimiter: DELIM }
    \\  },
    \\  onEvent(eventName, fn) {
    \\    let set = directListeners.get(eventName);
    \\    if (!set) { set = new Set(); directListeners.set(eventName, set); }
    \\    set.add(fn);
    \\    return () => set.delete(fn);
    \\  }
    \\};
    \\window.isTauri = true;
    \\window.__ztsRegisterEvent = registerEventListener;
    \\window.__ztsDeliverEvent = deliverEvent;
    \\Object.defineProperty(window, "__TAURI_INTERNALS__", { value: internals, configurable: true });
    \\Object.defineProperty(window, "__ZTS_IPC__", { value: internals, configurable: true });
    \\Object.defineProperty(window, "__TAURI_EVENT_PLUGIN_INTERNALS__", {
    \\  value: {
    \\    unregisterListener(eventName, eventId) {
    \\      const table = eventRegistry[eventName];
    \\      if (table && table[eventId]) {
    \\        unregisterCallback(table[eventId].handlerId);
    \\        delete table[eventId];
    \\      }
    \\    }
    \\  },
    \\  configurable: true
    \\});
    \\window.addEventListener("zts:event", (ev) => {
    \\  if (ev && ev.detail && typeof ev.detail.event === "string") {
    \\    deliverEvent(ev.detail.event, ev.detail.payload, null);
    \\  }
    \\});
    \\const ATTR = "data-tauri-drag-region";
    \\const CLICKABLE = new Set(["A", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "LABEL", "SUMMARY"]);
    \\const ROLES = new Set(["button", "link", "menuitem", "tab", "checkbox", "radio", "switch", "option"]);
    \\function isClickable(el) {
    \\  return (
    \\    CLICKABLE.has(el.tagName) ||
    \\    (el.hasAttribute("contenteditable") && el.getAttribute("contenteditable") !== "false") ||
    \\    (el.hasAttribute("tabindex") && el.getAttribute("tabindex") !== "-1") ||
    \\    ROLES.has(el.getAttribute("role"))
    \\  );
    \\}
    \\function isDragTarget(path) {
    \\  for (const el of path) {
    \\    if (!(el instanceof HTMLElement)) continue;
    \\    const attr = el.getAttribute(ATTR);
    \\    if (attr === "false") return false;
    \\    if (typeof getComputedStyle === "function") {
    \\      const reg = getComputedStyle(el).webkitAppRegion;
    \\      if (reg === "no-drag") return false;
    \\      if (reg === "drag" && !isClickable(el)) return true;
    \\    }
    \\    if (isClickable(el) && attr === null) return false;
    \\    if (attr === null) continue;
    \\    if (attr === "deep") return true;
    \\    if (attr === "" || attr === "true") return el === path[0];
    \\  }
    \\  return false;
    \\}
    \\if (typeof document !== "undefined") {
    \\  document.addEventListener("mousedown", (e) => {
    \\    if (e.button === 0 && (e.detail === 1 || e.detail === 2) && isDragTarget(e.composedPath())) {
    \\      e.preventDefault();
    \\      e.stopImmediatePropagation();
    \\      const cmd = e.detail === 2 ? "internal_toggle_maximize" : "start_dragging";
    \\      invoke("plugin:window|" + cmd);
    \\    }
    \\  });
    \\}
    \\})();
;

test "js_bootstrap escapes hostile labels against </script> XSS and switches OS scheme convention" {
    const html_tag = try renderInlineHtmlTagAlloc(testing.allocator, .{
        .label = "evil</script><script>alert(1)//",
        .os = .windows,
        .invoke_key = "secret-key-123",
    });
    defer testing.allocator.free(html_tag);

    try testing.expect(std.mem.startsWith(u8, html_tag, "<script>"));
    try testing.expect(std.mem.endsWith(u8, html_tag, "</script>"));
    // Inner body must NEVER contain a literal closing `</script>` tag!
    const inner = html_tag["<script>".len .. html_tag.len - "</script>".len];
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, inner, "</script>"));
    try testing.expect(std.mem.indexOf(u8, inner, "\"windows\"") != null);
    try testing.expect(std.mem.indexOf(u8, inner, "SEP=\"\\\\\"") != null);
}
