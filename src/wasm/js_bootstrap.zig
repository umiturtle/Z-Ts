//! Wasm / Static SSG `@tauri-apps/api` v2 Bootstrap Generator (`src/wasm/js_bootstrap.zig`).
//!
//! Injects a drop-in compatible `window.__TAURI_INTERNALS__`, `window.__ZTS_IPC__`, and
//! `window.__TAURI_EVENT_PLUGIN_INTERNALS__` shim backed directly by a local `.wasm` module
//! instead of native OS WebView custom schemes (`ipc://`) or HTTP servers (`BridgeServer`).
//!
//! Key guarantees:
//! - **Subpath-proof static hosting**: Computes relative URLs (`./_zts/app.wasm` at `/index.html`,
//!   `../../_zts/app.wasm` at `/chapters/prologue/index.html`) so the exported `dist/` folder works
//!   unchanged at domain root (`https://app.example.com/`) OR nested GitHub Pages paths
//!   (`https://user.github.io/my-vn-demo/`).
//! - **Segment-preserving `convertFileSrc`**: Encodes each path segment individually while keeping
//!   `/` directory separators intact so `fetch(convertFileSrc("audio/voice_clip.bin"))` hits real
//!   static CDN files (`./_zts/assets/audio/voice_clip.bin`) with native CDN `206 Partial Content`.
//! - **Supports both streaming HTTP Wasm load AND preloaded `globalThis.__ZTS_WASM_BYTES__`** (for
//!   single-file offline `.html` bundles and zero-server Node `WebAssembly.instantiate` E2E tests!).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const foundation = @import("zts_foundation");
const html_escape = foundation.html_escape;

/// URLs the in-browser `window.__TAURI_INTERNALS__` needs: where the `.wasm` lives and where
/// `convertFileSrc()` should resolve assets. All relative, so `dist/` can be served from any subpath.
pub const WasmBootstrapOptions = struct {
    /// Window / WebView label exposed to `@tauri-apps/api`.
    label: []const u8 = "main",
    /// Relative URL from this HTML page to the compiled `.wasm` binary (e.g. `"./_zts/app.wasm"`).
    wasm_url: []const u8 = "./_zts/app.wasm",
    /// Relative URL prefix for `convertFileSrc(...)` static assets (e.g. `"./_zts/assets/"`).
    asset_base_url: []const u8 = "./_zts/assets/",
    /// POSIX path conventions inside virtualized browser runtime (`"/"` / `":"`).
    sep: []const u8 = "/",
    delimiter: []const u8 = ":",
};

/// Writes `<script>...</script>` initializing `window.__TAURI_INTERNALS__` over WebAssembly.
pub fn writeInlineHtmlTag(writer: *std.Io.Writer, opts: WasmBootstrapOptions) std.Io.Writer.Error!void {
    try writer.writeAll("<script>");
    try writeScript(writer, opts);
    try writer.writeAll("</script>");
}

/// `writeInlineHtmlTag` into a fresh buffer — the form `zts_ssg` uses when it injects the bootstrap
/// into a prerendered page.
pub fn renderInlineHtmlTagAlloc(allocator: Allocator, opts: WasmBootstrapOptions) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeInlineHtmlTag(&aw.writer, opts) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Writes just the JavaScript (no `<script>` tags) that installs `window.__TAURI_INTERNALS__` for the
/// WebAssembly runtime. Safe to call twice: the script returns early when already installed.
pub fn writeScript(writer: *std.Io.Writer, opts: WasmBootstrapOptions) std.Io.Writer.Error!void {
    try writer.writeAll("(() => { if (typeof window === \"undefined\" && typeof globalThis !== \"undefined\") { globalThis.window = globalThis; } if (window.__TAURI_INTERNALS__ && window.__TAURI_INTERNALS__.__ztsReady) return;\n");
    try writer.writeAll("const LABEL=");
    try html_escape.writeJsonString(writer, opts.label, true);
    try writer.writeAll(",WASM_URL=");
    try html_escape.writeJsonString(writer, opts.wasm_url, true);
    try writer.writeAll(",ASSET_BASE=");
    try html_escape.writeJsonString(writer, opts.asset_base_url, true);
    try writer.writeAll(",SEP=");
    try html_escape.writeJsonString(writer, opts.sep, true);
    try writer.writeAll(",DELIM=");
    try html_escape.writeJsonString(writer, opts.delimiter, true);
    try writer.writeAll(";\n");
    try writer.writeAll(wasm_runtime_js_body);
}

const wasm_runtime_js_body =
    \\const callbacks = new Map();
    \\let nextId = 1;
    \\const eventRegistry = Object.create(null);
    \\const directListeners = new Map();
    \\const enc = new TextEncoder();
    \\const dec = new TextDecoder();
    \\let wasmExports = null;
    \\let wasmInitPromise = null;
    \\const TO_IPC_KEY = "__TAURI_TO_IPC_KEY__";
    \\function transformCallback(cb, once = false) {
    \\  const id = nextId++;
    \\  callbacks.set(id, (data) => {
    \\    if (once) callbacks.delete(id);
    \\    return cb && cb(data);
    \\  });
    \\  return id;
    \\}
    \\function unregisterCallback(id) { callbacks.delete(id); }
    \\function runCallback(id, data) {
    \\  const fn = callbacks.get(id);
    \\  if (fn) fn(data);
    \\}
    \\function serializePayload(data) {
    \\  if (data instanceof ArrayBuffer) return { bytes: new Uint8Array(data), isBin: 1 };
    \\  if (ArrayBuffer.isView(data)) return { bytes: new Uint8Array(data.buffer, data.byteOffset, data.byteLength), isBin: 1 };
    \\  if (Array.isArray(data) && data.length > 0 && data.every((n) => typeof n === "number" && Number.isInteger(n) && n >= 0 && n <= 255)) {
    \\    return { bytes: new Uint8Array(data), isBin: 1 };
    \\  }
    \\  const json = JSON.stringify(data === undefined ? {} : data, (_k, v) => {
    \\    if (v && typeof v === "object" && typeof v[TO_IPC_KEY] === "function") return v[TO_IPC_KEY]();
    \\    if (typeof v === "bigint") return v.toString();
    \\    if (v instanceof Uint8Array) {
    \\      let s = "";
    \\      for (let i = 0; i < v.length; i++) s += String.fromCharCode(v[i]);
    \\      return btoa(s);
    \\    }
    \\    return v;
    \\  });
    \\  return { bytes: enc.encode(json), isBin: 0 };
    \\}
    \\function ensureWasm() {
    \\  if (wasmExports) return Promise.resolve(wasmExports);
    \\  if (wasmInitPromise) return wasmInitPromise;
    \\  const imports = {
    \\    zts_host: {
    \\      zts_host_eval_js(ptr, len) {
    \\        if (!wasmExports) return;
    \\        const code = dec.decode(new Uint8Array(wasmExports.memory.buffer, ptr >>> 0, len >>> 0));
    \\        (0, eval)(code);
    \\      },
    \\      zts_host_fill_random(ptr, len) {
    \\        if (!wasmExports) return;
    \\        const view = new Uint8Array(wasmExports.memory.buffer, ptr >>> 0, len >>> 0);
    \\        if (globalThis.crypto && typeof globalThis.crypto.getRandomValues === "function") {
    \\          globalThis.crypto.getRandomValues(view);
    \\        } else {
    \\          for (let i = 0; i < view.length; i++) view[i] = (Math.random() * 256) | 0;
    \\        }
    \\      },
    \\      zts_host_now_ms() {
    \\        return typeof performance !== "undefined" ? performance.now() : Date.now();
    \\      }
    \\    }
    \\  };
    \\  wasmInitPromise = (async () => {
    \\    let inst;
    \\    if (globalThis.__ZTS_WASM_BYTES__) {
    \\      const res = await WebAssembly.instantiate(globalThis.__ZTS_WASM_BYTES__, imports);
    \\      inst = res.instance || res;
    \\    } else if (typeof WebAssembly.instantiateStreaming === "function") {
    \\      try {
    \\        const res = await WebAssembly.instantiateStreaming(fetch(WASM_URL), imports);
    \\        inst = res.instance;
    \\      } catch {
    \\        const resp = await fetch(WASM_URL);
    \\        const buf = await resp.arrayBuffer();
    \\        const res = await WebAssembly.instantiate(buf, imports);
    \\        inst = res.instance;
    \\      }
    \\    } else {
    \\      const resp = await fetch(WASM_URL);
    \\      const buf = await resp.arrayBuffer();
    \\      const res = await WebAssembly.instantiate(buf, imports);
    \\      inst = res.instance;
    \\    }
    \\    wasmExports = inst.exports;
    \\    if (typeof wasmExports.zts_wasm_init === "function") {
    \\      const rc = wasmExports.zts_wasm_init();
    \\      if (rc !== 0) throw new Error("zts_wasm_init failed with code " + rc);
    \\    }
    \\    globalThis.__ZTS_WASM_EXPORTS__ = wasmExports;
    \\    return wasmExports;
    \\  })();
    \\  return wasmInitPromise;
    \\}
    \\async function callWasmRaw(cmd, args) {
    \\  const exp = await ensureWasm();
    \\  const cmdBytes = enc.encode(cmd);
    \\  const { bytes: bodyBytes, isBin } = serializePayload(args);
    \\  const cmdPtr = cmdBytes.length > 0 ? exp.zts_wasm_alloc(cmdBytes.length) : 0;
    \\  const bodyPtr = bodyBytes.length > 0 ? exp.zts_wasm_alloc(bodyBytes.length) : 0;
    \\  if ((cmdBytes.length > 0 && !cmdPtr) || (bodyBytes.length > 0 && !bodyPtr)) {
    \\    if (cmdPtr) exp.zts_wasm_free(cmdPtr, cmdBytes.length);
    \\    if (bodyPtr) exp.zts_wasm_free(bodyPtr, bodyBytes.length);
    \\    throw new Error("Wasm OOM allocating IPC buffers");
    \\  }
    \\  if (cmdBytes.length > 0) new Uint8Array(exp.memory.buffer, cmdPtr >>> 0, cmdBytes.length).set(cmdBytes);
    \\  if (bodyBytes.length > 0) new Uint8Array(exp.memory.buffer, bodyPtr >>> 0, bodyBytes.length).set(bodyBytes);
    \\  let status;
    \\  try {
    \\    status = exp.zts_wasm_invoke(cmdPtr, cmdBytes.length, bodyPtr, bodyBytes.length, isBin);
    \\  } finally {
    \\    if (cmdPtr) exp.zts_wasm_free(cmdPtr, cmdBytes.length);
    \\    if (bodyPtr) exp.zts_wasm_free(bodyPtr, bodyBytes.length);
    \\  }
    \\  const rPtr = exp.zts_wasm_response_ptr() >>> 0;
    \\  const rLen = exp.zts_wasm_response_len() >>> 0;
    \\  const rKind = exp.zts_wasm_response_kind() >>> 0;
    \\  let out;
    \\  try {
    \\    if (rKind === 1) {
    \\      out = exp.memory.buffer.slice(rPtr, rPtr + rLen);
    \\    } else {
    \\      const txt = rLen > 0 ? dec.decode(new Uint8Array(exp.memory.buffer, rPtr, rLen)) : "";
    \\      if (rKind === 0) out = txt.length > 0 ? JSON.parse(txt) : null;
    \\      else out = txt;
    \\    }
    \\  } finally {
    \\    exp.zts_wasm_response_dispose();
    \\  }
    \\  return { ok: status === 1, data: out };
    \\}
    \\function sendIpcMessage(message) {
    \\  const { cmd, callback, error, payload } = message;
    \\  callWasmRaw(cmd, payload).then(
    \\    (res) => runCallback(res.ok ? callback : error, res.data),
    \\    (err) => runCallback(error, err instanceof Error ? err.message : String(err))
    \\  );
    \\}
    \\function invoke(cmd, args = {}, options) {
    \\  return new Promise((resolve, reject) => {
    \\    const isListen = cmd === "plugin:event|listen" && args && typeof args.event === "string" && typeof args.handler === "number";
    \\    const callback = transformCallback((val) => {
    \\      if (isListen) registerEventListener(args.event, val, args.handler, args.target);
    \\      resolve(val);
    \\      unregisterCallback(error);
    \\    }, true);
    \\    const error = transformCallback((err) => {
    \\      reject(err);
    \\      unregisterCallback(callback);
    \\    }, true);
    \\    sendIpcMessage({ cmd, callback, error, payload: args, options });
    \\  });
    \\}
    \\function convertFileSrc(filePath, _protocol = "asset") {
    \\  const clean = String(filePath || "").replace(/\\/g, "/").replace(/^\/+/, "");
    \\  const encoded = clean.split("/").filter(Boolean).map(encodeURIComponent).join("/");
    \\  return ASSET_BASE + encoded;
    \\}
    \\function registerEventListener(eventName, eventId, handlerId, target) {
    \\  let table = eventRegistry[eventName];
    \\  if (!table) { table = Object.create(null); eventRegistry[eventName] = table; }
    \\  table[eventId] = { handlerId, target };
    \\}
    \\function deliverEvent(eventName, payload, targetLabel) {
    \\  if (targetLabel && targetLabel !== LABEL) return;
    \\  const set = directListeners.get(eventName);
    \\  if (set) { for (const fn of set) { try { fn(payload); } catch {} } }
    \\  const table = eventRegistry[eventName];
    \\  if (!table) return;
    \\  for (const key of Object.keys(table)) {
    \\    const id = Number(key);
    \\    const entry = table[id];
    \\    if (entry) runCallback(entry.handlerId, { event: eventName, id, payload });
    \\  }
    \\}
    \\const internals = {
    \\  __ztsReady: true,
    \\  __ztsMode: "wasm",
    \\  ensureWasm,
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
    \\    if (el.getAttribute(ATTR) === "false") return false;
    \\    if (isClickable(el) && el.getAttribute(ATTR) === null) return false;
    \\    const attr = el.getAttribute(ATTR);
    \\    if (attr === null) continue;
    \\    if (attr === "deep") return true;
    \\    if (attr === "" || attr === "true") return el === path[0];
    \\  }
    \\  return false;
    \\}
    \\if (typeof document !== "undefined" && typeof document.addEventListener === "function") {
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

test "Wasm bootstrap escapes hostile strings and preserves subpath relative URLs" {
    const html = try renderInlineHtmlTagAlloc(testing.allocator, .{
        .label = "demo</script>",
        .wasm_url = "../../_zts/app.wasm",
        .asset_base_url = "../../_zts/assets/",
    });
    defer testing.allocator.free(html);

    const inner = html["<script>".len .. html.len - "</script>".len];
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, inner, "</script>"));
    try testing.expect(std.mem.indexOf(u8, inner, "\"../../_zts/app.wasm\"") != null);
    try testing.expect(std.mem.indexOf(u8, inner, "\"../../_zts/assets/\"") != null);
}
