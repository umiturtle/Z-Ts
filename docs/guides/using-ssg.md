# 静的サイト書き出しの使い方（`zts_ssg` + `zts_wasm`）

> **対象読者**: 同じ Zig コードから「サーバ不要の `dist/`」を出したい人。
> API は [`../api/zts_ssg/index.html`](../api/zts_ssg/index.html) と
> [`../api/zts_wasm/index.html`](../api/zts_wasm/index.html)。

`examples/counter` は 1 つのアプリから **3 つの成果物**を作ります。

| 成果物 | 動く場所 | 状態の保持 | 実装 |
|---|---|---|---|
| `desktop` | OS の WebView | プロセス内 | [`zts_webview`](../api/zts_webview/index.html) |
| `preview` | ブラウザ + HTTP/SSE | Zig プロセス内 | [`zts_bridge`](../api/zts_bridge/index.html) |
| `dist` | **静的ホスティング** | ブラウザ内（WASM） | このページ |

`dist` は「HTML + JS + フォント + `app.wasm`」だけのディレクトリです。サーバも Node も要りません。

---

## 1. 3 ステップ

```zig
// ① フロントエンドを Zig モジュールにする（build.zig、M5-01）
const frontend = zts_build.embedFrontend(b, .{
    .src_dir = b.path("web/dist"),       // Vite / Astro / Next out のどれでも
    .web_mod = web_mod,                  // zts_web
});
```

```zig
// ② アプリを wasm32-freestanding でビルドし、Spec から C ABI を公開する
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
// ③ dist/ を書き出す
const report = try ssg.exportStaticSite(allocator, io, dist_dir, .{
    .assets = frontend.assets,
    .wasm_bytes = wasm_bytes,            // zig-out/bin/app.wasm
    .prerender_routes = &.{
        .{ .route = "/", .title = "My App", .initial_json = "{\"count\":0}" },
    },
});
```

[`exportStaticSite`](../api/zts_ssg/exporter.html#exportStaticSite) は次のものを書きます。

| 出力 | 内容 |
|---|---|
| `index.html` ほか | `assets` からコピーしたフロントエンド（ルートごとに相対パスへ書き換え） |
| `_zts/app.wasm` | `wasm_bytes`（無ければ書きません） |
| `_zts/*.js` | WASM を読み込むグルー（`window.__TAURI_INTERNALS__` を満たす） |
| `404.html` | SPA フォールバック（`emit_spa_404`、既定 true） |
| `.nojekyll` | GitHub Pages が `_zts/` を配信できるように（`emit_nojekyll`、既定 true） |
| `_headers` | Cloudflare Pages / Netlify 用の `Content-Type: application/wasm` ほか（`emit_headers_file`、既定 true） |

---

## 2. `ExportOptions`

定義は [`ExportOptions`](../api/zts_ssg/exporter.html#ExportOptions)。既定値のままでも 9 割方動きます。

| フィールド | 既定 | 使いどころ |
|---|---|---|
| `assets` | — | `embedFrontend` が返す `Assets`（必須） |
| `window_label` | `"main"` | `@tauri-apps/api` に見せるラベル |
| `wasm_bytes` | `null` | アプリの `wasm32-freestanding` バイナリ |
| `prerender_routes` | `&.{}` | 事前生成するルート（下記） |
| `asset_source_dir` | `null` | 埋め込みに含めない大物（音声・画像）をコピー |
| `asset_scope_globs` | `&.{}` | そのコピー対象の glob（`audio/**` など） |
| `emit_spa_404` | `true` | `404.html` を出す |
| `emit_nojekyll` | `true` | `.nojekyll` を出す |
| `emit_headers_file` | `true` | `_headers` を出す |
| `cross_origin_isolated` | `false` | COOP/COEP を付ける（SharedArrayBuffer を使うとき） |

### プリレンダリング

[`PrerenderRoute`](../api/zts_ssg/exporter.html#PrerenderRoute) は「JS が動き出す前に確定している HTML」を
書きます。`initial_json` は `<script id="__ZTS_SSG_DATA__" type="application/json">` として埋め込まれ、
`<` `>` `&` U+2028/U+2029 がすべてエスケープされるので、**`</script>` インジェクションは起きません**。

```zig
.{
    .route = "/about",
    .template_route = "/index.html",   // assets 内のテンプレート（省略時は route 自身）
    .title = "About",
    .description = "…",
    .initial_json = "{\"user\":null}",
    .body_html = "<h1>About</h1>",     // #app の中に直接入る
}
```

`route` は**クリーン URL** です（`/chapters/prologue` → `chapters/prologue/index.html`）。
変換は [`routeToOutputSubPathAlloc`](../api/zts_ssg/exporter.html#routeToOutputSubPathAlloc)、
各ページからルートへの相対プレフィックスは
[`relativeRootPrefixAlloc`](../api/zts_ssg/exporter.html#relativeRootPrefixAlloc) が作ります。
**サブパス配信（`https://example.com/app/`）でも壊れません。**

---

## 3. WASM 側の約束（`zts_wasm`）

ブラウザから呼ばれるのは C ABI だけです。`exportApp(Spec)` が公開する関数は
[`exportApp`](../api/zts_wasm/runtime.html#exportApp) を参照してください。要点は 3 つ。

1. **文字列は線形メモリ上で受け渡し**する（`_zts_alloc` で確保 → 呼ぶ → `_zts_free`）。
2. **レスポンスは最後の 1 件だけ保持**する（`Instance.last_response`）。大量に返す API は作りません。
3. **ホスト呼び出しは `WasmHost` 経由**。`evalJs` は `EvalHook` に落ちるので、
   テストでは `inst.wasm_host.eval_hook = .{ .callFn = … }` で
   「バックエンドから出た JS」を検証できます。

```zig
const inst = try zts_wasm.Instance(Spec).create(testing.allocator);
defer inst.destroy();

try testing.expectEqual(@as(i32, 1), inst.invokeRaw("increment", "{}", false));
try testing.expectEqualStrings("{\"count\":1,…}", inst.last_response.body.slice());
```

`Instance(Spec)` は**ネイティブでも動きます**。つまり `zig build test` の中で、
ブラウザを起動せずに「WASM 版のアプリ」を同じテストから叩けます（3 成果物の差分テストの正体）。

---

## 4. 配信先ごとの注意

| 配信先 | 必要なもの | 理由 |
|---|---|---|
| GitHub Pages | `.nojekyll`（既定で出力） | `_zts/` を Jekyll が無視するのを防ぐ |
| Cloudflare Pages / Netlify | `_headers`（既定で出力） | `.wasm` の MIME と CSP |
| サブパス（`/app/`） | なし | すべての URL が相対化される |
| S3 など | `index.html` の他希望 | `emit_spa_404` を切って自前の 404 を置く |

---

## 5. つまずきどころ

| 症状 | 原因と対処 |
|---|---|
| `dist/` で真っ白 | `wasm_bytes` を渡し忘れ（`_zts/app.wasm` が無い）。 |
| `_next/` や `_astro/` が 404 | `.nojekyll` が消されている。`emit_nojekyll: true` を確認。 |
| MIME エラーで WASM が動かない | `_headers` を配信していない（`emit_headers_file`）。 |
| 404 ページだけ素の HTML | SPA ルータと `404.html` の二重管理。`emit_spa_404` を切って自前にする。 |
| SharedArrayBuffer が使えない | `cross_origin_isolated: true` で COOP/COEP を付ける。 |

---

## 次に読むもの

- API: [`zts_ssg`](../api/zts_ssg/index.html) / [`exporter`](../api/zts_ssg/exporter.html) /
  [`zts_wasm`](../api/zts_wasm/index.html) / [`runtime`](../api/zts_wasm/runtime.html)
- 実例: [`../../examples/counter/README.md`](../../examples/counter/README.md)
- API ページの読み方: [`using-the-api-reference.md`](using-the-api-reference.md)
- ビルド統合: [`../architecture/build-tools.md`](../architecture/build-tools.md)（`embedFrontend`）
- 内部資料: [`../architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md) /
  [`../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`](../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md)
