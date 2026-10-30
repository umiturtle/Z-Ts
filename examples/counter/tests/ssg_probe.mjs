#!/usr/bin/env node
// 静的 SSG 成果物（`dist/`）の実 WebAssembly E2E プローブ (`M2-02`)。
//
// サーバを一切立てずに `dist/` をファイルシステムから読み、`index.html` の
// `<head>` ブートストラップ → `app.js`（無改造 `@tauri-apps/api` v2）→ `_zts/app.wasm`
// の順に実行して、**実際の DOM 操作でカウンタが動く** ことを検証します。
//
// Usage: node tests/ssg_probe.mjs <dist_dir>

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { webcrypto } from "node:crypto";

const distDir = path.resolve(process.argv[2] ?? "");
if (process.argv[2] === undefined) {
  console.error("Usage: node tests/ssg_probe.mjs <dist_dir>");
  process.exit(2);
}

let checks = 0;
function check(condition, message) {
  checks += 1;
  if (!condition) {
    console.error(`ssg probe FAILED: ${message}`);
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// 1. 静的サイト構成（サブパス配信に必要なファイル群）
// ---------------------------------------------------------------------------
const indexPath = path.join(distDir, "index.html");
check(fs.existsSync(indexPath), "dist/index.html must exist");
check(fs.existsSync(path.join(distDir, ".nojekyll")), ".nojekyll must be emitted for GitHub Pages");
check(fs.existsSync(path.join(distDir, "_headers")), "_headers must be emitted for Cloudflare Pages / Netlify");
check(fs.existsSync(path.join(distDir, "404.html")), "404.html must be emitted");
check(fs.existsSync(path.join(distDir, "_zts/app.wasm")), "_zts/app.wasm must be emitted");
check(fs.existsSync(path.join(distDir, "app.js")), "app.js must be copied into dist/");
check(fs.existsSync(path.join(distDir, "styles.css")), "styles.css must be copied into dist/");

const headersFile = fs.readFileSync(path.join(distDir, "_headers"), "utf8");
check(headersFile.includes("application/wasm"), "_headers must set application/wasm");
check(headersFile.includes("Cache-Control: public, max-age=31536000, immutable"), "_headers must mark the wasm bundle immutable");

const html = fs.readFileSync(indexPath, "utf8");
check(html.includes('"./_zts/app.wasm"'), "root page must reference the relative `./_zts/app.wasm`");
check(html.includes('id="__ZTS_SSG_DATA__"'), "pre-rendered `__ZTS_SSG_DATA__` payload must be injected");
check(/<title>Z-Ts Counter/.test(html), "pre-rendered <title> must be present");
check(html.indexOf("<script>") > html.indexOf("<head>"), "wasm bootstrap must be injected inside <head>");

const ssgData = /<script id="__ZTS_SSG_DATA__" type="application\/json">([\s\S]*?)<\/script>/.exec(html);
check(ssgData !== null, "`__ZTS_SSG_DATA__` element must be parseable");
const prerendered = JSON.parse(ssgData[1]);
check(prerendered.mode === "wasm" && prerendered.count === 0, "pre-rendered snapshot must match the wasm initial state");

// ---------------------------------------------------------------------------
// 2. 最小 DOM シム（`dist/index.html` の id を全て実体化する）
// ---------------------------------------------------------------------------
class FakeElement {
  constructor(id, tagName, textContent) {
    this.id = id;
    this.tagName = tagName.toUpperCase();
    this.textContent = textContent;
    this.dataset = {};
    this.value = "";
    this._attrs = {};
    this._listeners = new Map();
  }

  addEventListener(type, fn) {
    const set = this._listeners.get(type) ?? new Set();
    set.add(fn);
    this._listeners.set(type, set);
  }

  removeEventListener(type, fn) {
    this._listeners.get(type)?.delete(fn);
  }

  dispatch(type) {
    const event = { type, target: this, preventDefault() {}, stopPropagation() {} };
    for (const fn of this._listeners.get(type) ?? []) fn(event);
  }

  click() {
    this.dispatch("click");
  }

  setAttribute(name, value) {
    this._attrs[name] = String(value);
  }

  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
  }

  hasAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this._attrs, name);
  }

  focus() {}
}

const stripTags = (value) => value.replace(/<[^>]*>/g, "").trim();
const elements = new Map();

// この HTML の `id` はすべてリーフ要素（`<b>`, `<span>`, `<p>`, `<button>`, `<input>`, `<script>`）に
// 付いているため、開始タグ直後から対応する終了タグまでを textContent として取り出せば十分。
for (const match of html.matchAll(/<([a-zA-Z][a-zA-Z0-9-]*)\b([^>]*?)\bid="([^"]+)"([^>]*)>/g)) {
  const tag = match[1];
  const attrs = match[0];
  const id = match[3];
  const tagEnd = match.index + attrs.length;
  const lower = tag.toLowerCase();

  if (lower === "input") {
    const el = new FakeElement(id, tag, "");
    const valueMatch = /\bvalue="([^"]*)"/.exec(attrs);
    if (valueMatch !== null) el.value = valueMatch[1];
    elements.set(id, el);
    continue;
  }

  if (lower === "script") {
    const close = html.indexOf("</script>", tagEnd);
    elements.set(id, new FakeElement(id, tag, close === -1 ? "" : html.slice(tagEnd, close)));
    continue;
  }

  const close = html.indexOf(`</${tag}>`, tagEnd);
  const inner = close === -1 ? "" : html.slice(tagEnd, close);
  elements.set(id, new FakeElement(id, tag, stripTags(inner).split("\n")[0].trim()));
}

check(elements.has("count") && elements.has("increment") && elements.has("mode"), "DOM ids from index.html must be materialized");

const documentShim = {
  title: "Z-Ts Counter",
  baseURI: "http://127.0.0.1/",
  readyState: "complete",
  getElementById: (id) => elements.get(id) ?? null,
  querySelector: (selector) => (selector.startsWith("#") ? elements.get(selector.slice(1)) ?? null : null),
  querySelectorAll: () => [],
  createElement: (tag) => new FakeElement("", tag, ""),
  addEventListener() {},
  removeEventListener() {},
};

// ---------------------------------------------------------------------------
// 3. `dist/` を直接読む fetch シム（静的 CDN の代替）
// ---------------------------------------------------------------------------
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
};

const baseUrl = "http://127.0.0.1/";
const localFetch = async (input) => {
  const url = new URL(String(input), baseUrl);
  let route = decodeURIComponent(url.pathname);
  if (route.endsWith("/")) route += "index.html";
  const filePath = path.resolve(distDir, `.${route}`);
  if (!filePath.startsWith(distDir) || !fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    return new Response("not found", { status: 404 });
  }
  return new Response(fs.readFileSync(filePath), {
    status: 200,
    headers: { "Content-Type": MIME[path.extname(filePath).toLowerCase()] ?? "application/octet-stream" },
  });
};

const sandbox = {
  location: { protocol: "http:", host: "127.0.0.1", origin: "http://127.0.0.1", href: baseUrl },
  navigator: { userAgent: "Z-Ts-Counter-SSG-Probe/1.0" },
  document: documentShim,
  fetch: localFetch,
  Headers,
  Request,
  Response,
  URL,
  URLSearchParams,
  TextEncoder,
  TextDecoder,
  WebAssembly,
  Uint8Array,
  Uint8ClampedArray,
  Int8Array,
  Int16Array,
  Uint16Array,
  Int32Array,
  Uint32Array,
  Float32Array,
  Float64Array,
  BigInt64Array,
  BigUint64Array,
  ArrayBuffer,
  DataView,
  crypto: { getRandomValues: (arr) => webcrypto.getRandomValues(arr) },
  performance: { now: () => performance.now() },
  setTimeout,
  clearTimeout,
  queueMicrotask,
  console,
  btoa: (value) => Buffer.from(String(value), "binary").toString("base64"),
  atob: (value) => Buffer.from(String(value), "base64").toString("binary"),
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
  addEventListener() {},
  removeEventListener() {},
  dispatchEvent() {
    return true;
  },
};

sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
sandbox.globalThis = sandbox;

// ---------------------------------------------------------------------------
// 4. `index.html` の実行順序をそのまま再現（bootstrap → app.js）
// ---------------------------------------------------------------------------
let inlineScripts = 0;
let externalScripts = 0;
for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)) {
  const attrs = match[1];
  const inline = match[2];
  // `type="application/json"`（`__ZTS_SSG_DATA__`）はデータであって実行対象ではない。
  const typeMatch = /\btype="([^"]+)"/.exec(attrs);
  const isJsonData = typeMatch !== null && typeMatch[1].includes("json");
  const src = /\bsrc="([^"]+)"/.exec(attrs);
  if (isJsonData) continue;
  if (src !== null) {
    const file = path.join(distDir, src[1].replace(/^\.\//, ""));
    check(fs.existsSync(file), `referenced script ${src[1]} must exist in dist/`);
    vm.runInContext(fs.readFileSync(file, "utf8"), sandbox, { filename: src[1] });
    externalScripts += 1;
  } else if (inline.trim().length > 0) {
    vm.runInContext(inline, sandbox, { filename: "dist-inline-bootstrap.js" });
    inlineScripts += 1;
  }
}
check(inlineScripts >= 1, "wasm bootstrap inline script must run");
check(externalScripts === 1, "exactly one bundled app.js script must run");

const waitFor = async (predicate, label, timeoutMs = 8000) => {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${label}`);
};

const countText = () => elements.get("count").textContent;
const eventsText = () => elements.get("events").textContent;

// ---------------------------------------------------------------------------
// 5. WebAssembly 起動 → ハイドレーション → 操作
// ---------------------------------------------------------------------------
// `#mode` はプリレンダリング済み JSON でも "wasm" になるため、実 RPC 往復（getState）の完了を示す
// ステータス文言でブート完了を判定する。
await waitFor(() => elements.get("status").textContent.startsWith("connected"), "wasm runtime boot (getState)");
check(elements.get("mode").textContent === "wasm", `mode must be wasm, got ${elements.get("mode").textContent}`);
check(countText() === "0", `initial count must be 0, got ${countText()}`);
check(documentShim.title.includes("(wasm)"), `document.title must reflect the wasm mode: ${documentShim.title}`);
check(typeof sandbox.__TAURI_INTERNALS__.ensureWasm === "function", "bootstrap must expose ensureWasm()");

const clickAndWait = async (id, expectedCount, expectedEvents) => {
  elements.get(id).click();
  await waitFor(() => countText() === String(expectedCount), `${id} -> count ${expectedCount}`);
  await waitFor(
    () => eventsText() === String(expectedEvents),
    `${id} -> ${expectedEvents} counter:changed events (status: ${elements.get("status").textContent})`,
  );
};

await clickAndWait("increment", 1, 1);
await clickAndWait("increment", 2, 2);
await clickAndWait("increment", 3, 3);
await clickAndWait("decrement", 2, 4);

elements.get("step-input").value = "5";
elements.get("apply-step").click();
await waitFor(() => elements.get("step").textContent === "5", "setStep(5)");
await waitFor(() => eventsText() === "5", "setStep(5) event");

await clickAndWait("increment", 7, 6);
await clickAndWait("reset", 0, 7);

check(elements.get("mutations").textContent === "7", `mutations must be 7, got ${elements.get("mutations").textContent}`);
check(documentShim.title.includes("— 0"), "document.title must track the counter value");

// 範囲外 step は RPC エラーとして reject され、状態は変化しない。
const rejected = await sandbox.__TAURI_INTERNALS__.invoke("setStep", { step: 101 }).then(
  () => false,
  (error) => JSON.stringify(error).includes("StepOutOfRange"),
);
check(rejected, "setStep(101) must reject with StepOutOfRange over WebAssembly");
check(elements.get("step").textContent === "5", "rejected setStep must not mutate the step");

// 静的アセット API（`convertFileSrc`）も同一バンドルで動く。
check(
  sandbox.__TAURI_INTERNALS__.convertFileSrc("audio/click.ogg") === "./_zts/assets/audio/click.ogg",
  "convertFileSrc must produce subpath-safe relative asset URLs",
);

console.log(
  `OK ssg checks=${checks} count=${countText()} step=${elements.get("step").textContent} events=${eventsText()} wasm=${fs.statSync(path.join(distDir, "_zts/app.wasm")).size}B`,
);
