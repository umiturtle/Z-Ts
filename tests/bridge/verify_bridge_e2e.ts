// Real HTTP/1.1 + Streaming SSE + Triple-CSRF Attack Verification Suite (`M1-05`).
// Executed directly on Node 22+ against a live Zig `BridgeServer` bound to port `0`.
export {};

declare const process: { readonly argv: readonly string[] };

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Bridge assertion failed: ${msg}`);
}

const baseUrl = process.argv[2];
assert(Boolean(baseUrl), "Expected baseUrl argv[2]");
const hostHeader = new URL(baseUrl!).host;

// 1. Fetch `/` -> must inject bootstrap `<script>` into `<head>` AND issue `HttpOnly; SameSite=Strict` cookie!
const indexRes = await fetch(`${baseUrl}/`);
assert(indexRes.status === 200, `Expected 200 for /, got ${indexRes.status}`);

const setCookie = indexRes.headers.get("set-cookie") ?? "";
assert(setCookie.includes("__zts_session="), `Missing __zts_session cookie: ${setCookie}`);
assert(setCookie.includes("HttpOnly") && setCookie.includes("SameSite=Strict"), `Missing cookie security flags: ${setCookie}`);
const cookiePair = setCookie.split(";")[0]!;

const html = await indexRes.text();
const keyMatch = /const KEY = "([0-9a-f]{64})";/.exec(html);
assert(keyMatch !== null, "Injected bootstrap script missing 256-bit hex KEY");
const invokeKey = keyMatch![1]!;
assert(html.indexOf("<script>") > html.indexOf("<head>") && html.indexOf("<script>") < html.indexOf("<title>"), "Script must be injected immediately after <head>");

// 2. SPA fallback (`/dashboard/view` -> 200 HTML) vs missing file asset (`/missing.js` -> 404) & `206 Partial Content` seeking!
const spaRes = await fetch(`${baseUrl}/dashboard/view`, { headers: { Cookie: cookiePair } });
assert(spaRes.status === 200, `SPA route expected 200, got ${spaRes.status}`);
// Subsequent request with valid session cookie MUST NOT re-issue a new random cookie
assert(spaRes.headers.get("set-cookie") === null, "Existing valid session cookie should be reused");
await spaRes.text();

const missingRes = await fetch(`${baseUrl}/missing.js`);
assert(missingRes.status === 404, `Missing static JS expected 404, got ${missingRes.status}`);
await missingRes.text();

const rangeRes = await fetch(`${baseUrl}/media/sample.mp4`, {
  headers: { Range: "bytes=5-17" },
});
assert(rangeRes.status === 206, `Expected 206 Partial Content, got ${rangeRes.status}`);
assert((rangeRes.headers.get("content-range") ?? "").startsWith("bytes 5-17/"), "Expected valid Content-Range header");
assert((await rangeRes.text()) === "VIDEO_PAYLOAD", "206 byte range slice mismatch");

const badRangeRes = await fetch(`${baseUrl}/media/sample.mp4`, {
  headers: { Range: "bytes=99999-199999" },
});
assert(badRangeRes.status === 416, `Expected 416 Range Not Satisfiable, got ${badRangeRes.status}`);
await badRangeRes.text();

// 3. SIX Cross-Site Request Forgery (CSRF) & Hijacking Vectors — EVERY ONE MUST BE REJECTED WITH `403 Forbidden`!
const attackCases: ReadonlyArray<{ readonly name: string; readonly url: string; readonly method: string; readonly headers: Record<string, string> }> = [
  // Attack 1: Missing session Cookie (even with valid Origin + Tauri-Invoke-Key)
  {
    name: "missing Cookie",
    url: `${baseUrl}/__zts_ipc__/addAmount`,
    method: "POST",
    headers: { Origin: baseUrl!, "Tauri-Invoke-Key": invokeKey, "Content-Type": "application/json" },
  },
  // Attack 2: Tampered session Cookie (single-bit flip)
  {
    name: "tampered Cookie",
    url: `${baseUrl}/__zts_ipc__/addAmount`,
    method: "POST",
    headers: {
      Origin: baseUrl!,
      Cookie: cookiePair.slice(0, -1) + (cookiePair.endsWith("0") ? "1" : "0"),
      "Tauri-Invoke-Key": invokeKey,
      "Content-Type": "application/json",
    },
  },
  // Attack 3: Missing `Tauri-Invoke-Key` header (classic browser `<form>` / simple `fetch` CSRF!)
  {
    name: "missing Tauri-Invoke-Key",
    url: `${baseUrl}/__zts_ipc__/addAmount`,
    method: "POST",
    headers: { Origin: baseUrl!, Cookie: cookiePair, "Content-Type": "application/json" },
  },
  // Attack 4: Foreign malicious `Origin` (`https://evil.example`) EVEN WITH stolen Cookie AND stolen Key!
  {
    name: "cross-origin evil.example",
    url: `${baseUrl}/__zts_ipc__/addAmount`,
    method: "POST",
    headers: { Origin: "https://evil.example", Cookie: cookiePair, "Tauri-Invoke-Key": invokeKey, "Content-Type": "application/json" },
  },
  // Attack 5: `Origin: null` sandboxed iframe attack
  {
    name: "null Origin",
    url: `${baseUrl}/__zts_ipc__/addAmount`,
    method: "POST",
    headers: { Origin: "null", Cookie: cookiePair, "Tauri-Invoke-Key": invokeKey, "Content-Type": "application/json" },
  },
  // Attack 6: Unauthenticated SSE eavesdropping attempt (`/__zts_events__` without key / with evil Origin)
  {
    name: "unauthenticated SSE hijack",
    url: `${baseUrl}/__zts_events__?key=${invokeKey}`,
    method: "GET",
    headers: { Origin: "https://evil.example", Cookie: cookiePair },
  },
];

for (const atk of attackCases) {
  const r = await fetch(atk.url, {
    method: atk.method,
    headers: atk.headers,
    body: atk.method === "POST" ? JSON.stringify({ delta: 999 }) : undefined,
  });
  assert(r.status === 403, `CSRF vector '${atk.name}' MUST return 403, got ${r.status}`);
  await r.text();
}

// 4. Open live authenticated SSE stream BEFORE firing RPCs so we observe real-time push frames!
const abortSse = new AbortController();
const sseRes = await fetch(`${baseUrl}/__zts_events__?key=${invokeKey}`, {
  headers: { Origin: `http://${hostHeader}`, Cookie: cookiePair },
  signal: abortSse.signal,
});
assert(sseRes.status === 200, `Expected 200 on authenticated SSE stream, got ${sseRes.status}`);
assert((sseRes.headers.get("content-type") ?? "").startsWith("text/event-stream"), "Expected text/event-stream");

const sseReader = sseRes.body!.getReader();
const decoder = new TextDecoder();
let sseAccum = "";

async function readUntilContains(needle: string): Promise<void> {
  while (!sseAccum.includes(needle)) {
    const chunk = await sseReader.read();
    if (chunk.done) throw new Error(`SSE stream closed before receiving '${needle}'. Got:\n${sseAccum}`);
    sseAccum += decoder.decode(chunk.value, { stream: true });
  }
}

await readUntilContains(": connected\n\n");

// 5. Legitimate Authenticated JSON RPC, Domain Error RPC, Raw Binary (`Uint8Array`) RPC, and Namespaced SSE Push!
const authHeaders = {
  Origin: baseUrl!,
  Cookie: cookiePair,
  "Tauri-Invoke-Key": invokeKey,
  "Content-Type": "application/json",
};

const okAdd = await fetch(`${baseUrl}/__zts_ipc__/addAmount`, {
  method: "POST",
  headers: authHeaders,
  body: JSON.stringify({ delta: 42 }),
});
assert(okAdd.status === 200 && okAdd.headers.get("tauri-response") === "ok", "Expected 200 + Tauri-Response: ok");
assert((await okAdd.json()) === 142, "Expected updated total 142");

const errAdd = await fetch(`${baseUrl}/__zts_ipc__/addAmount`, {
  method: "POST",
  headers: authHeaders,
  body: JSON.stringify({ delta: -5 }),
});
assert(errAdd.status === 400 && errAdd.headers.get("tauri-response") === "error", "Expected 400 + Tauri-Response: error");
assert(((await errAdd.json()) as { code: string }).code === "NegativeDelta", "Expected NegativeDelta error code");

// Raw binary `application/octet-stream` response check
const binRes = await fetch(`${baseUrl}/__zts_ipc__/${encodeURIComponent("blob:png_magic")}`, {
  method: "POST",
  headers: authHeaders,
  body: "",
});
assert(binRes.status === 200 && binRes.headers.get("tauri-response") === "ok", "Expected binary 200 ok");
assert(binRes.headers.get("content-type") === "application/octet-stream", "Expected application/octet-stream");
const pngBytes = new Uint8Array(await binRes.arrayBuffer());
assert(pngBytes.length === 8 && pngBytes[0] === 0x89 && pngBytes[1] === 0x50 && pngBytes[2] === 0x4e && pngBytes[3] === 0x47, "Raw PNG bytes mismatch");

// Trigger `plugin:window|set_title` -> broadcasts `window`, `emit`, and `eval` frames over live SSE!
const winRes = await fetch(`${baseUrl}/__zts_ipc__/${encodeURIComponent("plugin:window|set_title")}`, {
  method: "POST",
  headers: authHeaders,
  body: JSON.stringify({ title: "Live Preview Title!" }),
});
assert(winRes.status === 200, `Expected 200 on window|set_title, got ${winRes.status}`);
await winRes.text();

await readUntilContains('event: window\ndata: {"title":"Live Preview Title!"}\n\n');
await readUntilContains('event: emit\ndata: {"event":"title:updated","payload":{"ok":true}}\n\n');
await readUntilContains('event: eval\ndata: {"script":"globalThis.__ranEval = 1;"}\n\n');

abortSse.abort();

// 6. Execute the ACTUAL `<script>` injected into `<head>` inside a simulated browser global scope
//    and verify `window.__TAURI_INTERNALS__.invoke` & `globalThis.__ZTS_IPC__.invoke` end-to-end!
const scriptMatch = /<script>([\s\S]*?)<\/script>/.exec(html);
assert(scriptMatch !== null, "Missing injected <script> tag");

const origFetch = globalThis.fetch;
try {
  // Emulate browser same-origin URL resolution + automatic cookie jar attachment
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const resolvedUrl = typeof input === "string" && input.startsWith("/") ? `${baseUrl}${input}` : input;
    const mergedHeaders = new Headers(init?.headers);
    mergedHeaders.set("Origin", baseUrl!);
    mergedHeaders.set("Cookie", cookiePair);
    return origFetch(resolvedUrl, { ...init, headers: mergedHeaders });
  }) as typeof fetch;

  // Run the exact injected script body (EventSource intentionally absent here -> clean guard branch)
  const runBootstrap = new Function(scriptMatch![1]!);
  runBootstrap();

  const injectedIpc = (globalThis as Record<string, unknown>)["__ZTS_IPC__"] as {
    invoke: (cmd: string, args?: unknown) => Promise<unknown>;
  };
  const injectedTauri = (globalThis as Record<string, unknown>)["__TAURI_INTERNALS__"] as {
    invoke: (cmd: string, args?: unknown) => Promise<unknown>;
    convertFileSrc: (p: string) => string;
  };
  assert(Boolean(injectedIpc) && injectedIpc === injectedTauri, "Both __ZTS_IPC__ and __TAURI_INTERNALS__ must be installed");

  const sumAfter = await injectedTauri.invoke("addAmount", { delta: 8 });
  assert(sumAfter === 150, `Expected 150 via injected __TAURI_INTERNALS__.invoke, got ${String(sumAfter)}`);

  const rawPng = await injectedIpc.invoke("blob:png_magic");
  assert(rawPng instanceof Uint8Array && rawPng.length === 8 && rawPng[0] === 0x89, "Expected Uint8Array via injected __ZTS_IPC__.invoke");

  let caughtNegative = false;
  try {
    await injectedTauri.invoke("addAmount", { delta: -1 });
  } catch (err) {
    caughtNegative = (err as { code?: string }).code === "NegativeDelta";
  }
  assert(caughtNegative, "Injected bridge invoke() must throw structured Zig error payload");
  assert(injectedTauri.convertFileSrc("bg/opening.png") === "/__zts_asset__/bg%2Fopening.png", "convertFileSrc encoding mismatch");
} finally {
  globalThis.fetch = origFetch;
}

