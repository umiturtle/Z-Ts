# Static export (`zts_ssg` + `zts_wasm`)

> **Audience**: readers who want a `dist/` with **no server** from the same Zig code.
> API: [`zts_ssg`](../../../api/zts_ssg/index.html) and [`zts_wasm`](../../../api/zts_wasm/index.html).

`examples/counter` builds **three artefacts** from one app.

| Artefact | Runs on | State kept in | Package |
|---|---|---|---|
| `desktop` | the OS WebView | the process | [`zts_webview`](../../../api/zts_webview/index.html) |
| `preview` | a browser over HTTP/SSE | the Zig process | [`zts_bridge`](../../../api/zts_bridge/index.html) |
| `dist` | **any static host** | the browser (WASM) | this page |

`dist` is a directory of "HTML + JS + fonts + `app.wasm`". No server, no Node.

---

## 1. Three steps

```zig
// ① turn the frontend into a Zig module (build.zig)
const frontend = zts_build.embedFrontend(b, .{
    .src_dir = b.path("web/dist"),       // Vite / Astro / Next out — anything
    .web_mod = web_mod,                  // zts_web
});
```

```zig
// ② build the app for wasm32-freestanding and expose the C ABI from a Spec
pub const Spec = struct {
    pub const UserSchema = Schema;
    pub const UserState = State;
    pub const app_config: tauri.AppConfig = .{ … };
    pub const path_config: tauri.PathState = .{ … };
    pub const main_window: core.WindowSpec = .{ … };

    pub fn initUserState(… ) !State { … }
    pub fn bindAll(comptime Full: type, state: *State, plugins: *tauri.CorePluginStates) Full.Router { … }
};

comptime {
    _ = zts_wasm.exportApp(Spec);        // → _zts_invoke / _zts_alloc / _zts_free …
}
```

```zig
// ③ write dist/
const report = try ssg.exportStaticSite(allocator, io, dist_dir, .{
    .assets = frontend.assets,
    .wasm_bytes = wasm_bytes,            // zig-out/bin/app.wasm
    .prerender_routes = &.{
        .{ .route = "/", .title = "My App", .initial_json = "{\"count\":0}" },
    },
});
```

[`exportStaticSite`](../../../api/zts_ssg/exporter.html#exportStaticSite) writes:

| Output | Contents |
|---|---|
| `index.html` and friends | the frontend copied out of `assets`, rewritten to relative paths per route |
| `_zts/app.wasm` | `wasm_bytes` (skipped when null) |
| `_zts/*.js` | glue that loads the WASM and satisfies `window.__TAURI_INTERNALS__` |
| `404.html` | SPA fallback (`emit_spa_404`, true by default) |
| `.nojekyll` | lets GitHub Pages serve `_zts/` (`emit_nojekyll`, true by default) |
| `_headers` | `Content-Type: application/wasm` and friends for Cloudflare Pages / Netlify (`emit_headers_file`, true by default) |

---

## 2. `ExportOptions`

Defined as [`ExportOptions`](../../../api/zts_ssg/exporter.html#ExportOptions). The defaults are
right about 90% of the time.

| Field | Default | When to touch it |
|---|---|---|
| `assets` | — | the `Assets` returned by `embedFrontend` (required) |
| `window_label` | `"main"` | the label `@tauri-apps/api` sees |
| `wasm_bytes` | `null` | the `wasm32-freestanding` binary of your app |
| `prerender_routes` | `&.{}` | routes to pre-generate (below) |
| `asset_source_dir` | `null` | copy large files that should not be embedded (audio, images) |
| `asset_scope_globs` | `&.{}` | globs for that copy (`audio/**`) |
| `emit_spa_404` | `true` | write `404.html` |
| `emit_nojekyll` | `true` | write `.nojekyll` |
| `emit_headers_file` | `true` | write `_headers` |
| `cross_origin_isolated` | `false` | add COOP/COEP (when you need `SharedArrayBuffer`) |

### Prerendering

[`PrerenderRoute`](../../../api/zts_ssg/exporter.html#PrerenderRoute) writes HTML that is final
before any JS runs. `initial_json` is embedded as
`<script id="__ZTS_SSG_DATA__" type="application/json">`, with `<`, `>`, `&`, U+2028 and U+2029
all escaped, so **`</script>` injection is impossible**.

```zig
.{
    .route = "/about",
    .template_route = "/index.html",   // a template inside assets (defaults to route itself)
    .title = "About",
    .description = "…",
    .initial_json = "{\"user\":null}",
    .body_html = "<h1>About</h1>",     // injected straight into #app
}
```

`route` is a **clean URL** (`/chapters/prologue` → `chapters/prologue/index.html`). The conversion
is [`routeToOutputSubPathAlloc`](../../../api/zts_ssg/exporter.html#routeToOutputSubPathAlloc);
the per-page prefix back to the root comes from
[`relativeRootPrefixAlloc`](../../../api/zts_ssg/exporter.html#relativeRootPrefixAlloc). **Subpath
hosting (`https://example.com/app/`) does not break.**

---

## 3. The WASM contract (`zts_wasm`)

The browser only ever calls the C ABI. See
[`exportApp`](../../../api/zts_wasm/runtime.html#exportApp) for the full list. Three points matter.

1. **Strings cross on linear memory** (allocate with `_zts_alloc` → call → `_zts_free`).
2. **Only the last response is kept** (`Instance.last_response`). There is no "return a list" API.
3. **Host calls go through `WasmHost`.** `evalJs` lands on `EvalHook`, so tests can set
   `inst.wasm_host.eval_hook = .{ .callFn = … }` and assert on the JS your backend emitted.

```zig
const inst = try zts_wasm.Instance(Spec).create(testing.allocator);
defer inst.destroy();

try testing.expectEqual(@as(i32, 1), inst.invokeRaw("increment", "{}", false));
try testing.expectEqualStrings("{\"count\":1,…}", inst.last_response.body.slice());
```

`Instance(Spec)` also runs **natively**, so your project's `zig build test` can exercise the WASM
build without a browser — that is how the three artefacts are diff-tested.

---

## 4. Hosting notes

| Host | What it needs | Why |
|---|---|---|
| GitHub Pages | `.nojekyll` (written by default) | stops Jekyll from ignoring `_zts/` |
| Cloudflare Pages / Netlify | `_headers` (written by default) | the `.wasm` MIME type and CSP |
| a subpath (`/app/`) | nothing | every URL is relativised |
| S3 and friends | an `index.html` of your choosing | turn off `emit_spa_404` and ship your own 404 |

### Serving the embedded gzip twins

`embedFrontend` generates a **deterministic gzip twin** per file (`gzip_entries`) and the generated
`assets: web.Assets` consumes it. Both the desktop `tauri://` / `isolation://` router and the Live
Preview HTTP server negotiate `Accept-Encoding` and return the same bytes.

```
Accept-Encoding: gzip, deflate   →  Content-Encoding: gzip + gzip twin
Accept-Encoding: gzip;q=0        →  raw bytes (explicit refusal)
(no header)                      →  raw bytes
Range: bytes=0-1023              →  206 over the raw bytes (Range disables compression)
```

| Rule | Why |
|---|---|
| always send `Vary: Accept-Encoding` | two representations exist, so caches must key on it |
| skip twins larger than the original | never make a tiny JS file bigger |
| no gzip after `<head>` injection | injection changes the bytes, so the pre-computed twin no longer matches |
| fixed `MTIME=0` / `OS=Unix` | byte-identical on all three OSes; screenshot and hash comparisons stay stable |

```zig
const frontend = @import("embedded_frontend");
const app_assets = frontend.assets;  // carries BOTH .entries and .gzip_entries

var res = try app_assets.resolve(allocator, "/index.html", .{
    .accept_encoding = "gzip",
});
defer res.deinit();
// res.content_encoding == "gzip", res.vary_accept_encoding == true
```


---

## 5. Usual traps

| Symptom | Cause and fix |
|---|---|
| blank page from `dist/` | `wasm_bytes` was not passed, so `_zts/app.wasm` is missing |
| `_next/` or `_astro/` 404s | `.nojekyll` was removed; check `emit_nojekyll: true` |
| WASM refuses to start on MIME | `_headers` is not being served (`emit_headers_file`) |
| the 404 page is plain HTML | SPA router and `404.html` disagree; disable `emit_spa_404` and own it |
| `SharedArrayBuffer` unavailable | set `cross_origin_isolated: true` to add COOP/COEP |

---

## Next

- API: [`zts_ssg`](../../../api/zts_ssg/index.html) / [`exporter`](../../../api/zts_ssg/exporter.html) /
  [`zts_wasm`](../../../api/zts_wasm/index.html) / [`runtime`](../../../api/zts_wasm/runtime.html)
- A working example: [`examples/counter/README.md`](../../../../examples/counter/README.md)
- Build integration: [`docs/architecture/build-tools.md`](../../../architecture/build-tools.md) (`embedFrontend`)
- Internals: [`docs/architecture/ssg-and-wasm.md`](../../../architecture/ssg-and-wasm.md) /
  [`docs/decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`](../../../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md)

## The configuration is checked by the compiler

Field names in `ExportOptions` are protected by CI compiling the block below. Rename a field and
this example fails first.

```zig check
const std = @import("std");
const ssg = @import("zts_ssg");

test "ExportOptions field names" {
    const options: ssg.ExportOptions = .{
        .assets = undefined,
        .wasm_bytes = null,
        .prerender_routes = &.{
            .{ .route = "/about", .title = "About", .initial_json = null },
        },
        .emit_spa_404 = true,
        .emit_nojekyll = true,
    };
    try std.testing.expectEqualStrings("/about", options.prerender_routes[0].route);
}
```

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
