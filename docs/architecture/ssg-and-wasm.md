# SSG（静的サイト生成）& WebAssembly 同型実行アーキテクチャ

> 対象読者: Z-Ts 上でデスクトップアプリ／Web 体験版／静的サイトの **3 成果物を 1 コードベースから出したい** 開発者・エージェント。
> 意思決定の背景は [`../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`](../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md) を参照。

---

## 1. 4 モード同型（Quad-Target Isomorphism）マトリクス

Z-Ts のアプリコード（Zig コマンド実装 ＋ TypeScript UI）は、**1 行も分岐させずに** 次の 4 つの実行形態へ出力できます。

| # | 実行形態 | `zts_core.Host` 実装 | トランスポート | 起動方法 |
|---|---|---|---|---|
| ① | Headless テスト | `mock.HeadlessMock` | インメモリ | `zig build test`（0ms） |
| ② | ネイティブ・デスクトップ | `webview_host.WebviewHost` | `ipc://` / `tauri://` / `asset://` | 単一実行ファイル |
| ③ | Live HTTP Bridge | `bridge_host.BridgeHost` | `POST /__zts_ipc__/*` + SSE | ローカル HTTP サーバ |
| ④ | **静的 Web / SSG** | **`wasm.host.WasmHost`** | **JS ⇔ Wasm 線形メモリ直呼び出し** | **静的ファイル配信（サーバ不要）** |

④ は `wasm32-freestanding` へコンパイルされ、`dist/` ディレクトリ（HTML + `.wasm` + アセット）だけで動作します。GitHub Pages / Cloudflare Pages / Netlify / itch.io へそのまま配置できます。

---

## 2. Inbound SSG：フロントエンド SSG 出力の取り込み（`embedFrontendDir`）

Astro / Next.js（`output: 'export'`）/ SvelteKit（`adapter-static`）/ Vite の出力ディレクトリを、**手書きマニフェストなし**で `zts_web.Assets` へ埋め込みます。

### 2.1 使い方

```zig
// 消費側プロジェクトの build.zig
const embedded = embedFrontendDir(b, web_mod, .{
    .src_dir = b.path("frontend/dist"),
    .module_name = "embedded_frontend",
});
```

生成モジュール（`@import("embedded_frontend")`）は次の 3 つを公開します。

| シンボル | 型 | 用途 |
|---|---|---|
| `entries` | `[]const zts_web.StaticAsset` | `zts_web.Assets` へそのまま渡せる静的資産表 |
| `sha256_digests` | `[]const []const u8` | CSP ハッシュ / `ETag` / 完全性検証用 |
| `assets` | `zts_web.Assets` | 事前構築済みアセットリゾルバ |

### 2.2 生成規則（決定論性）

- 走査結果は **辞書順（`/_astro/...` < `/docs/guide/index.html` < `/index.html`）** にソートして出力するため、ファイルシステムの inode 順や OS の差異に左右されず、生成ファイルはバイト単位で再現可能です。
- 生成コードは `out_dir/files/<相対パス>` へ正規化コピーしたうえで `@embedFile("files/...")` を出力します。Zig 0.17 はモジュールディレクトリ外への `@embedFile` を禁止するため、また Windows のドライブレター・バックスラッシュを生成コードへ漏らさないための措置です。
- ディレクトリインデックス解決（`/about` → `/about/index.html`）は `zts_web.Assets.resolve` が行うため、**マルチページ SSG がそのまま動きます**（SPA フォールバックとは別経路）。

---

## 3. Outbound SSG：`zts_ssg.exportStaticSite`

```zig
const report = try zts_ssg.exportStaticSite(allocator, io, dist_dir, .{
    .assets = .{ .entries = frontend.entries },
    .wasm_bytes = wasm_binary,          // ① `_zts/app.wasm` として出力
    .prerender_routes = &.{
        .{ .route = "/", .title = "Home" },
        .{
            .route = "/gallery",
            .title = "Gallery",
            .initial_json = "{\"items\":[...]}",   // `<script id="__ZTS_SSG_DATA__">` へ安全に埋込
            .body_html = "<main>...</main>",       // `<div id="app">` へ静的 HTML を注入
        },
    },
    .asset_source_dir = asset_dir,      // 音声・画像などの大容量ランタイム資産
    .asset_scope_globs = &.{ "audio/**" },   // スコープ外（秘密鍵など）は絶対にコピーしない
    .cross_origin_isolated = true,      // `_headers` に COOP/COEP を追加
});
```

### 3.1 出力ツリー

```text
dist/
├── index.html                 # プリレンダリング済み（相対 `./_zts/app.wasm`）
├── gallery/index.html         # ネスト階層（相対 `../_zts/app.wasm`）
├── 404.html                   # クライアントサイドルーティング用フォールバック
├── .nojekyll                  # GitHub Pages が `_zts/` を配信できるようにする
├── _headers                   # Cloudflare Pages / Netlify 用（`application/wasm` + CSP + COOP/COEP）
└── _zts/
    ├── app.wasm               # wasm32-freestanding アプリ本体
    └── assets/audio/bgm.ogg   # `asset_scope_globs` に一致した資産のみ
```

### 3.2 サブパス完全対応（GitHub Pages 対策）

ブートストラップ `<script>` に埋め込む `wasmUrl` / `assetBaseUrl` は、**出力ページの階層深さから相対計算**されます。

| 出力ページ | 深さ | `wasmUrl` |
|---|---|---|
| `dist/index.html` | 0 | `./_zts/app.wasm` |
| `dist/gallery/index.html` | 1 | `../_zts/app.wasm` |
| `dist/chapters/prologue/index.html` | 2 | `../../_zts/app.wasm` |

これにより `https://user.github.io/my-repo/` のようなサブパス配信でも、設定変更なしに動作します。

### 3.3 XSS 対策

`initial_json` は `<`, `>`, `&`, U+2028, U+2029 を `\uXXXX` へエスケープしたうえで `type="application/json"` の `<script>` に格納します。`<title>` / `og:*` / `description` は HTML エスケープされます。

---

## 4. Wasm ABI（`zts_wasm`）

### 4.1 ホスト（JS）→ Wasm エクスポート

| 関数 | シグネチャ | 用途 |
|---|---|---|
| `zts_wasm_init` | `() -> i32` | ランタイム生成（0 = 成功）。ブートストラップが初期化時に自動実行 |
| `zts_wasm_alloc` / `zts_wasm_free` | `(usize) -> ?[*]u8` / `([*]u8, usize) -> void` | 線形メモリの貸し出し |
| `zts_wasm_invoke` | `(cmd_ptr, cmd_len, body_ptr, body_len, is_binary) -> i32` | 単一コマンド呼び出し（1 = `ok`, 0 = `err`, -1 = 致命的） |
| `zts_wasm_response_ptr/len/kind` | `() -> ...` | 直前の応答（`kind`: 0 = JSON, 1 = binary, 2 = text） |
| `zts_wasm_response_dispose` | `() -> void` | 応答バッファ解放 |

### 4.2 Wasm → ホスト（JS）インポート

`imports.zts_host` は **3 関数のみ**です。

| 関数 | 用途 |
|---|---|
| `zts_host_eval_js(ptr, len)` | `Channel<T>` フレーム配送、`EventBus` イベント配送、`document.title` 同期 |
| `zts_host_fill_random(ptr, len)` | `crypto.getRandomValues` を `std.Io` の乱数源へ接続 |
| `zts_host_now_ms()` | `performance.now()` を時計へ接続 |

この 3 関数だけで `zts_tauri` の全標準プラグイン（`window`, `event`, `path`, `app`, `resources`, `Channel<T>`）が、無改造の `@tauri-apps/api` v2 と完全に動作します。

### 4.3 `zts_wasm.Instance(Spec)` の宣言

```zig
pub const Spec = struct {
    pub const UserSchema = DemoOnlySchema;              // rpc.Schema(...)
    pub const UserState = WasmDemoState;                // 任意の状態型
    pub const app_config: tauri.AppConfig = .{ ... };
    pub const path_config: tauri.PathState = .{ ... };
    pub const main_window: core.WindowSpec = .{ ... };
    pub fn initUserState(allocator, plugins, host) !UserState { ... }
    pub fn deinitUserState(state: *UserState) void { ... }
    pub fn bindAll(comptime Full: type, state, plugins) Full.Router { ... }
};

pub const wasm_exports = zts_wasm.exportApp(Spec);   // wasm32 で C ABI を `@export`
pub const panic = std.debug.FullPanic(zts_wasm.host.reportPanic);  // ブラウザ console へパニック出力
```

> **重要（Zig 0.17 の落とし穴）**: `wasm32-freestanding` の実行ファイルは `-rdynamic`
> （`std.Build.Step.Compile.rdynamic = true`）を指定しないと `memory` と `_start` 以外の
> シンボルを一切エクスポートしません。`export` 宣言だけでは不足します。

### 4.4 シングルスレッド `std.Io`

`zts_wasm.io_stub.wasmIo()` が `wasm32-freestanding` 用の `std.Io` VTable を提供します。

- `io.async(...)` は **その場で同期的に実行して `null` を返す**（公式の eager-completion 契約）ため、非同期 Zig コードがそのまま単一スレッドで動きます。
- ファイル / socket / process 系は `error.AccessDenied` などを返します（ブラウザサンドボックスの正しい表現）。
- `randomSecure` / `random` は `zts_host_fill_random` に接続されます。

---

## 5. 制約と将来拡張

- ブラウザ上では OS ネイティブ権限（任意パス読書き・ネイティブウィンドウ移動・画面キャプチャ等）は使えません。`WasmHost` は仮想状態を保持して `Unsupported` を返します。
- セーブデータ等の永続化は将来 `M4-02`（ストレージ抽象）で OPFS / IndexedDB バックエンドへ接続します。
- `embedFrontendDir` は `M5-01` で [`src/build_tools/`](build-tools.md) へ抽出済みです。下流プロジェクトは `dep.builder.path("src/build_tools/embed_main.zig")` で共通行を起動でき（`examples/counter` が実例）、gzip 双子・CSP ハッシュ・マニフェスト生成が 1 箇所に集約されています。

---

## 6. ショーケース実装 `examples/counter/`（`M2-02`）

4 モード同型と双方向 SSG を **1 つのサンプルプロジェクト** から実際に 3 成果物として出す
リファレンスです。詳細は [`../../examples/counter/README.md`](../../examples/counter/README.md)。

```bash
cd examples/counter
zig build            # ①②③ を zig-out/ へ
zig build test       # 単体 + 実 TCP E2E + 実 WebAssembly E2E
```

| # | 成果物 | コマンド | 出力 | `RuntimeMode` / `Host` |
|---|---|---|---|---|
| ① | デスクトップ単一バイナリ | `zig build desktop` | `zig-out/bin/counter` | `.desktop` / `WebviewHost` |
| ② | Live Preview（ブラウザ） | `zig build live` | `zig-out/bin/counter-live` | `.bridge` / `BridgeHost` |
| ③ | 静的 SSG Web | `zig build dist` | `zig-out/dist/` + `counter.wasm` | `.wasm` / `WasmHost` |

### 6.1 「分岐 0 行」の実現方法

アプリ実装は `examples/counter/src/app.zig` の 1 ファイルのみで、`App(comptime runtime: RuntimeMode)`
という comptime パラメータだけが異なります。`src/desktop.zig` / `src/live.zig` / `src/wasm_app.zig` は
それぞれ `App(.desktop)` / `App(.bridge)` / `App(.wasm)` をインスタンス化して入出力を繋ぐだけです。

- フロントエンド `web/main.ts` は無改造 `@tauri-apps/api` v2 の `invoke` / `listen` のみを使用。
- 環境判定は JS 側にも Zig 側にも無く、`getState` が返す `mode` を画面に表示するだけ。
- バックエンド → フロントエンドの `counter:changed` は `Host.evalJs` 一本で、
  ① `WebviewHost`（`ipc://`）/ ② `BridgeHost`（SSE `eval` フレーム）/ ③ `WasmHost`（`zts_host_eval_js`）
  のいずれでも同じ JS が実行される。

### 6.2 外部パッケージとしての消費（path dependency）

`examples/counter/build.zig.zon` はルートを `z_ts = .{ .path = "../.." }` として参照し、
`build.zig` 側は `b.dependency("z_ts", .{ .target = target, .optimize = optimize })` から
`dep.module("zts_web")` … `dep.module("z_ts")` を取得します。これにより
「ルート `build.zig` を変更せずに standalone モジュール群を再利用できる」ことが CI で常時検証されます。

`M5-01` 以降、埋め込みは共通実装（[`build-tools.md`](build-tools.md)）を起動するだけです。
サンプルは `dep.builder.path("src/build_tools/embed_main.zig")` を root にして同じエンベッダを
走らせるため、gzip / CSP / マニフェストのロジックはリポジトリ内に 1 つしかありません
（以前あった `embedFrontendDir` の写しは削除済み）。

### 6.3 実測値（Linux Debug / `-Dwasm-optimize=small`）

| 項目 | 値 |
|---|---|
| `counter.wasm`（`ReleaseSmall`） | 約 184 KB |
| `dist/` 合計 | 約 233 KB |
| `zig build test` | 7 テスト / Live プローブ 43 チェック / SSG プローブ 28 チェック |
| Live Preview 起動 | `counter-live --port 8788 --host 0.0.0.0` → `http://localhost:8788/` |
