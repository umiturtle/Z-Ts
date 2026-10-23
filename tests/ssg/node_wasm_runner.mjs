// Node 22 Serverless WebAssembly Harness for `@tauri-apps/api` v2 (`M2-01`).
//
// Proves the 4th isomorphic target: the **exact same** unmodified `@tauri-apps/api` v2 bundle
// that runs inside native WebKit2GTK and the HTTP bridge now runs against a real
// `wasm32-freestanding` `.wasm` module inside a static `dist/` tree — with **no application
// backend server at all**.
//
// The only HTTP server started here is a dumb *static file host* (serving `dist/` with RFC 9110
// Range support), which is exactly what GitHub Pages / Cloudflare Pages does in production.
//
// Usage: node node_wasm_runner.mjs <distDir> <e2eSuiteBundle.js>

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import vm from "node:vm";
import { webcrypto } from "node:crypto";

const [distDir, bundlePath] = process.argv.slice(2);
if (!distDir || !bundlePath) {
  console.error("Usage: node node_wasm_runner.mjs <distDir> <e2eSuiteBundle.js>");
  process.exit(2);
}

const rootDir = path.resolve(distDir);
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".bin": "application/octet-stream",
  ".ogg": "audio/ogg",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

// 1. Dumb static host with `206 Partial Content` support (static CDN simulation).
const server = http.createServer((req, res) => {
  const urlPath = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
  let filePath = path.join(rootDir, urlPath);
  if (fs.existsSync(filePath) && fs.statSync(filePath).isDirectory()) {
    filePath = path.join(filePath, "index.html");
  }
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    const fallback = path.join(rootDir, "404.html");
    if (fs.existsSync(fallback)) {
      res.writeHead(404, { "Content-Type": "text/html; charset=utf-8" });
      res.end(fs.readFileSync(fallback));
      return;
    }
    res.writeHead(404).end("not found");
    return;
  }

  const body = fs.readFileSync(filePath);
  const contentType = MIME[path.extname(filePath).toLowerCase()] ?? "application/octet-stream";
  const rangeHeader = req.headers.range;

  if (rangeHeader) {
    const m = /^bytes=(\d+)-(\d+)$/.exec(rangeHeader);
    if (m) {
      const start = Number(m[1]);
      const end = Math.min(Number(m[2]), body.length - 1);
      if (start > end || start >= body.length) {
        res.writeHead(416, { "Content-Range": `bytes */${body.length}` }).end();
        return;
      }
      const slice = body.subarray(start, end + 1);
      res.writeHead(206, {
        "Content-Type": contentType,
        "Content-Range": `bytes ${start}-${end}/${body.length}`,
        "Accept-Ranges": "bytes",
      });
      res.end(slice);
      return;
    }
  }

  res.writeHead(200, { "Content-Type": contentType, "Accept-Ranges": "bytes" });
  res.end(body);
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
const baseUrl = `http://127.0.0.1:${port}/`;

// 2. Validate exported static artifacts (pre-render, `.nojekyll`, `_headers`, scope filtering).
const indexHtml = fs.readFileSync(path.join(rootDir, "index.html"), "utf8");
const galleryHtml = fs.readFileSync(path.join(rootDir, "gallery/index.html"), "utf8");

const assertStatic = (cond, message) => {
  if (!cond) {
    console.error(`Static export assertion failed: ${message}`);
    process.exit(1);
  }
};

assertStatic(fs.existsSync(path.join(rootDir, ".nojekyll")), "`.nojekyll` must be emitted");
assertStatic(fs.existsSync(path.join(rootDir, "_headers")), "`_headers` must be emitted");
assertStatic(fs.existsSync(path.join(rootDir, "404.html")), "`404.html` SPA fallback must be emitted");
assertStatic(fs.existsSync(path.join(rootDir, "_zts/app.wasm")), "`_zts/app.wasm` must be emitted");
assertStatic(
  fs.existsSync(path.join(rootDir, "_zts/assets/audio/voice_clip.bin")),
  "scoped asset `audio/voice_clip.bin` must be copied",
);
assertStatic(
  !fs.existsSync(path.join(rootDir, "_zts/assets/secret/private.key")),
  "out-of-scope `secret/private.key` MUST NOT be copied",
);
assertStatic(indexHtml.includes('"./_zts/app.wasm"'), "root page must reference `./_zts/app.wasm`");
assertStatic(
  galleryHtml.includes('"../_zts/app.wasm"'),
  "depth-1 route must reference `../_zts/app.wasm`",
);
assertStatic(
  galleryHtml.includes("<title>Gallery &lt;Z-Ts&gt;</title>"),
  "pre-rendered `<title>` must be HTML-escaped",
);
assertStatic(
  galleryHtml.includes('id="__ZTS_SSG_DATA__"') && !galleryHtml.includes("<script>alert(1)"),
  "pre-rendered JSON must neutralize `</script>` XSS",
);
assertStatic(
  galleryHtml.includes("<main><h1>Gallery</h1>"),
  "static `body_html` fragment must be pre-rendered",
);

const dataMatch = /<script id="__ZTS_SSG_DATA__" type="application\/json">([\s\S]*?)<\/script>/.exec(galleryHtml);
assertStatic(dataMatch !== null, "`__ZTS_SSG_DATA__` JSON payload must be present");
const parsed = JSON.parse(dataMatch[1]);
assertStatic(parsed.xss === "</script><script>alert(1)</script>", "escaped JSON must roundtrip byte-exactly");

// 3. Build a browser-like VM realm (`window`, `document`, `fetch`, `WebAssembly`, WebCrypto).
const wasmBytes = fs.readFileSync(path.join(rootDir, "_zts/app.wasm"));

const sandbox = {
  location: { protocol: "http:", host: `127.0.0.1:${port}`, origin: new URL(baseUrl).origin, href: baseUrl },
  navigator: { userAgent: "Mozilla/5.0 (Serverless-Wasm) Z-Ts-NodeRunner/1.0" },
  document: { title: "Initial", addEventListener() {} },
  fetch: (input, init) => fetch(new URL(String(input), baseUrl), init),
  Headers,
  Request,
  Response,
  URL,
  URLSearchParams,
  TextEncoder,
  TextDecoder,
  WebAssembly,
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
  crypto: { getRandomValues: (arr) => webcrypto.getRandomValues(arr) },
  performance: { now: () => performance.now() },
  setTimeout,
  clearTimeout,
  queueMicrotask,
  console,
  btoa: (s) => Buffer.from(s, "binary").toString("base64"),
  atob: (b) => Buffer.from(b, "base64").toString("binary"),
  Event: class Event {
    constructor(type, init) {
      this.type = type;
      this.detail = init?.detail;
    }
  },
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
};
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
sandbox.__ZTS_WASM_BYTES__ = wasmBytes;

vm.createContext(sandbox);
sandbox.globalThis = sandbox;

// 4. Execute the exact `<head>` bootstrap generated by `zts_wasm.js_bootstrap` from `dist/index.html`.
const bootstrapMatch = /<script>([\s\S]*?)<\/script>/.exec(indexHtml);
assertStatic(bootstrapMatch !== null, "injected WebAssembly bootstrap `<script>` must be present");
vm.runInContext(bootstrapMatch[1], sandbox, { filename: "zts_wasm_bootstrap.js" });

const exportsObj = await sandbox.__TAURI_INTERNALS__.ensureWasm();
assertStatic(typeof exportsObj.zts_wasm_invoke === "function", "`zts_wasm_invoke` must be exported");

// 5. Run the byte-identical `@tauri-apps/api` v2 suite used by WebKit2GTK & the HTTP bridge.
const bundleCode = fs.readFileSync(bundlePath, "utf8");
vm.runInContext(bundleCode, sandbox, { filename: "e2e_suite.bundle.js" });

const summary = await sandbox.ZtsTauriSuite.runSuite({ mode: "wasm" });

if (!summary.ok) {
  console.error("Tauri v2 WebAssembly E2E Suite FAILED:\n" + summary.errorMessage);
  server.close();
  process.exit(1);
}

// 6. Confirm `WasmHost.setWindowTitle` → `document.title` sync survived the final suite mutation.
assertStatic(
  sandbox.document.title === "Z-Ts Verified Window",
  `document.title sync from WasmHost expected "Z-Ts Verified Window", got "${sandbox.document.title}"`,
);

server.close();
console.log(
  `OK wasm checks=${summary.checksRun} streamed=${summary.streamedCount} once=${summary.onceHits} listen=${summary.listenHits}`,
);
