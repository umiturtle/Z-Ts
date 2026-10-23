// Node 22 Live HTTP + Cookie + Server-Sent Events Harness for `@tauri-apps/api` v2 (`M1-07`).
//
// Connects to a live Zig `BridgeServer` + `BridgeHost`, extracts the real injected `<head>`
// bootstrap script + `HttpOnly` `__zts_session` cookie, streams `/__zts_events__` (SSE) in real time
// to evaluate `eval` frames (`Channel<T>` & `plugin:event|*`), and executes the exact same bundled
// `@tauri-apps/api` v2 suite that runs inside native WebKit2GTK!

import fs from "node:fs";
import vm from "node:vm";

const [baseUrl, bundlePath] = process.argv.slice(2);
if (!baseUrl || !bundlePath) {
  console.error("Usage: node node_runner.mjs <baseUrl> <bundlePath>");
  process.exit(2);
}

const originUrl = new URL(baseUrl);

// 1. Fetch `/` to obtain session cookie + exact injected `<script>...</script>` from `src/bridge/js_init.zig`
const pageRes = await fetch(`${baseUrl}/`);
if (pageRes.status !== 200) {
  throw new Error(`Expected 200 on /, got ${pageRes.status}`);
}
const setCookie = pageRes.headers.get("set-cookie") ?? "";
const cookiePair = setCookie.split(";")[0];
if (!cookiePair || !cookiePair.startsWith("__zts_session=")) {
  throw new Error(`Missing __zts_session cookie: ${setCookie}`);
}
const html = await pageRes.text();
const scriptMatch = /<script>([\s\S]*?)<\/script>/.exec(html);
if (!scriptMatch) {
  throw new Error("Injected <head> bootstrap <script> not found in HTML");
}
const bootstrapJs = scriptMatch[1];

// 2. Minimal browser-compatible `fetch` + `EventSource` shim injecting `Origin` + `Cookie` headers
//    so `BridgeServer`'s triple-CSRF guard sees an authentic same-origin browser session.
const sseAbort = new AbortController();

function browserFetch(input, init = {}) {
  const target = typeof input === "string" ? new URL(input, baseUrl).toString() : input.toString();
  const headers = new Headers(init.headers || {});
  headers.set("Origin", originUrl.origin);
  headers.set("Cookie", cookiePair);
  return fetch(target, { ...init, headers });
}

class LiveSseEventSource {
  constructor(relPath) {
    this.listeners = new Map();
    const fullUrl = new URL(relPath, baseUrl).toString();
    this._pump(fullUrl);
  }

  addEventListener(type, fn) {
    const arr = this.listeners.get(type) ?? [];
    arr.push(fn);
    this.listeners.set(type, arr);
  }

  async _pump(url) {
    try {
      const res = await fetch(url, {
        headers: {
          Origin: originUrl.origin,
          Cookie: cookiePair,
          Accept: "text/event-stream",
        },
        signal: sseAbort.signal,
      });
      if (!res.ok || !res.body) return;
      const decoder = new TextDecoder();
      let buf = "";
      for await (const chunk of res.body) {
        buf += decoder.decode(chunk, { stream: true });
        let sepIdx;
        while ((sepIdx = buf.indexOf("\n\n")) !== -1) {
          const rawBlock = buf.slice(0, sepIdx);
          buf = buf.slice(sepIdx + 2);
          let evType = "message";
          const dataLines = [];
          for (const line of rawBlock.split("\n")) {
            if (line.startsWith("event:")) evType = line.slice(6).trim();
            else if (line.startsWith("data:")) dataLines.push(line.slice(5).trimStart());
          }
          if (dataLines.length > 0) {
            const cbs = this.listeners.get(evType) ?? [];
            const evObj = { data: dataLines.join("\n") };
            for (const cb of cbs) cb(evObj);
          }
        }
      }
    } catch {
      // Closed cleanly via `sseAbort.abort()` on suite completion
    }
  }
}

// 3. Execute injected bootstrap + `@tauri-apps/api` v2 IIFE bundle in a clean `window` realm
const sandboxWindow = {
  location: {
    protocol: originUrl.protocol,
    host: originUrl.host,
    origin: originUrl.origin,
    href: `${baseUrl}/`,
  },
  navigator: { userAgent: "Mozilla/5.0 (X11; Linux x86_64) Z-Ts-NodeRunner/1.0" },
  document: { title: "Initial", addEventListener() {} },
  fetch: browserFetch,
  Headers,
  Request,
  Response,
  URL,
  URLSearchParams,
  TextEncoder,
  TextDecoder,
  Uint8Array,
  ArrayBuffer,
  DataView,
  Int8Array,
  Uint8ClampedArray,
  Int16Array,
  Uint16Array,
  Int32Array,
  Uint32Array,
  Float32Array,
  Float64Array,
  BigInt64Array,
  BigUint64Array,
  EventSource: LiveSseEventSource,
  CustomEvent: class CustomEvent {
    constructor(type, init) {
      this.type = type;
      this.detail = init?.detail;
    }
  },
  dispatchEvent() {
    return true;
  },
  addEventListener() {},
  removeEventListener() {},
  setTimeout,
  clearTimeout,
  console,
  btoa: (s) => Buffer.from(s, "binary").toString("base64"),
  atob: (b) => Buffer.from(b, "base64").toString("binary"),
};
sandboxWindow.window = sandboxWindow;
sandboxWindow.self = sandboxWindow;
sandboxWindow.globalThis = sandboxWindow;

vm.createContext(sandboxWindow);
vm.runInContext(bootstrapJs, sandboxWindow, { filename: "zts_bridge_init.js" });

// Allow SSE connection handshake to establish before firing streaming commands
await new Promise((r) => setTimeout(r, 60));

const bundleCode = fs.readFileSync(bundlePath, "utf8");
vm.runInContext(bundleCode, sandboxWindow, { filename: "e2e_suite.bundle.js" });

const summary = await sandboxWindow.ZtsTauriSuite.runSuite({ mode: "bridge" });
sseAbort.abort();

if (!summary.ok) {
  console.error("Tauri v2 E2E Suite FAILED:", summary.errorMessage);
  process.exit(1);
}
console.log(`OK checks=${summary.checksRun} streamed=${summary.streamedCount}`);
