#!/usr/bin/env node
// Live Preview（HTTP Bridge）成果物の実プロセス E2E プローブ (`M2-02`)。
//
// Zig 側の `src/live_test.zig` が `BridgeServer` を実ポートで起動し、その base URL を渡します。
// ここではブラウザと同じ経路（HTML 配信 → 埋め込み JS → Cookie + Invoke-Key 付き RPC → SSE）を
// 実際の `fetch` で検証します。
//
// Usage: node tests/live_probe.mjs <base_url>

const baseUrl = (process.argv[2] ?? "").replace(/\/$/, "");
if (baseUrl.length === 0) {
  console.error("Usage: node tests/live_probe.mjs <base_url>");
  process.exit(2);
}

let checks = 0;
function check(condition, message) {
  checks += 1;
  if (!condition) {
    console.error(`live probe FAILED: ${message}`);
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// 1. 埋め込みフロントエンド配信 + `<head>` ブートストラップ注入 + セッション Cookie
// ---------------------------------------------------------------------------
const indexRes = await fetch(`${baseUrl}/`);
check(indexRes.status === 200, `GET / expected 200, got ${indexRes.status}`);
check((indexRes.headers.get("content-type") ?? "").includes("text/html"), "GET / must be text/html");

const setCookie = indexRes.headers.get("set-cookie") ?? "";
check(setCookie.includes("__zts_session="), `missing session cookie: ${setCookie}`);
check(setCookie.includes("HttpOnly") && setCookie.includes("SameSite=Strict"), "cookie must be HttpOnly; SameSite=Strict");
const cookie = setCookie.split(";")[0];

const html = await indexRes.text();
const keyMatch = /const KEY = "([0-9a-f]{64})";/.exec(html);
check(keyMatch !== null, "injected bootstrap is missing the 256-bit Tauri-Invoke-Key");
const invokeKey = keyMatch[1];

check(html.indexOf("<script>") > html.indexOf("<head>"), "bootstrap must be injected inside <head>");
check(html.includes('id="count"'), "embedded frontend index.html must be served");
check(html.includes('src="./app.js"'), "embedded frontend must reference the bundled app.js");

// ---------------------------------------------------------------------------
// 2. バンドル済みフロントエンド（無改造 `@tauri-apps/api` v2）の配信
// ---------------------------------------------------------------------------
const jsRes = await fetch(`${baseUrl}/app.js`);
check(jsRes.status === 200, `GET /app.js expected 200, got ${jsRes.status}`);
check((jsRes.headers.get("content-type") ?? "").includes("javascript"), "app.js must be served as JavaScript");
const appJs = await jsRes.text();
check(appJs.includes("__TAURI_INTERNALS__"), "app.js must contain the unmodified @tauri-apps/api v2 bridge");

const cssRes = await fetch(`${baseUrl}/styles.css`);
check(cssRes.status === 200, "styles.css must be served");
await cssRes.text();

// ---------------------------------------------------------------------------
// 3. RPC 往復（Cookie + Tauri-Invoke-Key + Origin の三重検証を通過）
// ---------------------------------------------------------------------------
async function ipc(command, payload = {}, overrides = {}) {
  const headers = {
    Origin: baseUrl,
    Cookie: cookie,
    "Tauri-Invoke-Key": invokeKey,
    "Content-Type": "application/json",
    ...overrides.headers,
  };
  const res = await fetch(`${baseUrl}/__zts_ipc__/${encodeURIComponent(command)}`, {
    method: "POST",
    headers,
    body: overrides.body ?? JSON.stringify(payload),
  });
  const text = await res.text();
  return { status: res.status, ok: res.headers.get("tauri-response") === "ok", text, json: safeParse(text) };
}

function safeParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

const initial = await ipc("getState");
check(initial.status === 200 && initial.ok, `getState failed: ${initial.status} ${initial.text}`);
check(initial.json.count === 0, `initial count must be 0, got ${JSON.stringify(initial.json)}`);
check(initial.json.step === 1, "initial step must be 1");
check(initial.json.mode === "bridge", `mode must be "bridge", got ${JSON.stringify(initial.json.mode)}`);

for (let i = 1; i <= 3; i += 1) {
  const res = await ipc("increment");
  check(res.ok, `increment #${i} failed: ${res.text}`);
  check(res.json.count === i, `increment #${i} must yield count=${i}, got ${JSON.stringify(res.json)}`);
  check(res.json.mutations === i, `increment #${i} must yield mutations=${i}`);
}

const stepped = await ipc("setStep", { step: 5 });
check(stepped.ok && stepped.json.step === 5, `setStep(5) failed: ${stepped.text}`);
const afterStep = await ipc("increment");
check(afterStep.json.count === 8, `count after setStep(5)+increment must be 8, got ${JSON.stringify(afterStep.json)}`);

// 異常系: 範囲外 step は RPC エラーとして返り、状態は不変。
const badStep = await ipc("setStep", { step: 0 });
check(badStep.status === 500 || badStep.status === 400 || badStep.status === 200, "invalid step must be answered");
check(!badStep.ok, `setStep(0) must fail, got ${badStep.text}`);
check(badStep.text.includes("StepOutOfRange"), `setStep(0) must report StepOutOfRange, got ${badStep.text}`);

const unknown = await ipc("nope");
check(!unknown.ok, "unknown command must fail");

const reset = await ipc("reset");
check(reset.ok && reset.json.count === 0, `reset failed: ${reset.text}`);

// ---------------------------------------------------------------------------
// 4. 三重 CSRF 防御（Cookie / Invoke-Key / Origin のうち 1 つでも欠ければ 403）
// ---------------------------------------------------------------------------
const noKey = await ipc("increment", {}, { headers: { "Tauri-Invoke-Key": "" } });
check(noKey.status === 403, `missing invoke key must be 403, got ${noKey.status}`);

const noCookie = await ipc("increment", {}, { headers: { Cookie: "__zts_session=deadbeef" } });
check(noCookie.status === 403, `tampered cookie must be 403, got ${noCookie.status}`);

const badOrigin = await ipc("increment", {}, { headers: { Origin: "https://evil.example" } });
check(badOrigin.status === 403, `cross-origin POST must be 403, got ${badOrigin.status}`);

const sseWithoutCookie = await fetch(`${baseUrl}/__zts_events__?key=${invokeKey}`);
check(sseWithoutCookie.status === 403, `SSE without cookie must be 403, got ${sseWithoutCookie.status}`);
await sseWithoutCookie.text();

// ---------------------------------------------------------------------------
// 5. SSE: `counter:changed` が実ストリームで配送される
//    ブラウザの `listen()` と同じく `plugin:event|listen` を先に登録する。
// ---------------------------------------------------------------------------
const listen = await ipc("plugin:event|listen", { event: "counter:changed", handler: 4242 });
check(listen.ok, `plugin:event|listen failed: ${listen.text}`);

const abort = new AbortController();
// ブラウザの `EventSource` は独自ヘッダを付けられないため、`?key=` で Invoke-Key を渡す
// (`src/bridge/js_init.zig` の `new EventSource("/__zts_events__?key=" + KEY)` と同一経路)。
const sseRes = await fetch(`${baseUrl}/__zts_events__?key=${invokeKey}`, {
  headers: { Cookie: cookie },
  signal: abort.signal,
});
check(sseRes.status === 200, `SSE expected 200, got ${sseRes.status}`);
const reader = sseRes.body.getReader();
const decoder = new TextDecoder();
let received = "";

const readLoop = (async () => {
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      received += decoder.decode(value, { stream: true });
      if (received.includes("counter:changed")) break;
    }
  } catch {
    // abort による終了は正常系。
  }
})();

// 購読が確立するまで数回 increment を打ち、最初に届いたフレームを検査する（タイムアウト耐性）。
for (let attempt = 0; attempt < 12 && !received.includes("counter:changed"); attempt += 1) {
  await ipc("increment");
  await Promise.race([readLoop, new Promise((resolve) => setTimeout(resolve, 250))]);
}
abort.abort();

// `EventBus` は `Host.evalJs` 経由で `runCallback(...)` を流すため、ブリッジでは `eval` フレームになる
// (`src/bridge/js_init.zig` の `es.addEventListener("eval", ...)` がそのまま実行する)。
function parseSseFrames(text) {
  const frames = [];
  for (const block of text.split("\n\n")) {
    const lines = block.split("\n");
    const eventLine = lines.find((line) => line.startsWith("event: "));
    const dataLines = lines.filter((line) => line.startsWith("data: ")).map((line) => line.slice(6));
    if (eventLine === undefined || dataLines.length === 0) continue;
    frames.push({ event: eventLine.slice(7).trim(), data: dataLines.join("\n") });
  }
  return frames;
}

const frames = parseSseFrames(received);
check(frames.some((frame) => frame.event === "eval"), `SSE must deliver structured \`eval\` frames, got: ${received.slice(0, 240)}`);

const evalScript = frames
  .filter((frame) => frame.event === "eval")
  .map((frame) => {
    try {
      return JSON.parse(frame.data).script ?? "";
    } catch {
      return "";
    }
  })
  .join("\n");

check(evalScript.includes("runCallback("), "eval frame must invoke the registered JS callback (handler 4242)");
check(evalScript.includes('"event":"counter:changed"'), "eval frame must carry counter:changed");
check(/"count":\d+/.test(evalScript), "eval payload must contain the serialized snapshot");

const final = await ipc("getState");
check(final.ok, "final getState must succeed");

console.log(`OK live checks=${checks} count=${final.json.count} mutations=${final.json.mutations}`);
