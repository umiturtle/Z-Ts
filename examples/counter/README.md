# Z-Ts Counter — 1 プロジェクト → 3 成果物ショーケース

`Z-Ts` の `M2-02` リファレンス実装です。**同一の Zig アプリケーションコードと同一のフロントエンド
バンドル**から、次の 3 つを生成します。

| # | 成果物 | 生成コマンド | 出力 | 実行基盤 |
|---|---|---|---|---|
| ① | デスクトップ単一バイナリ | `zig build desktop` | `zig-out/bin/counter` | ネイティブ WebView（Linux: GTK3 + WebKit2GTK 4.1 / macOS・Windows: `M3-xx` で追加） |
| ② | Live Preview（ブラウザ） | `zig build live` | `zig-out/bin/counter-live` | 純 Zig HTTP/1.1 + SSE サーバ（`zts_bridge`） |
| ③ | 静的 SSG Web | `zig build dist` | `zig-out/dist/` + `zig-out/bin/counter.wasm` | サーバ不要（GitHub Pages / Cloudflare Pages / Netlify / itch.io） |

```bash
cd examples/counter
zig build                 # ①②③ をまとめて zig-out/ へ
zig build test            # 単体 + 実 TCP E2E + 実 WebAssembly E2E
zig build preview         # Live Preview を 0.0.0.0:8788 で起動
```

> このパッケージはルート `Z-Ts` を **path dependency** として消費します
> （`build.zig.zon` の `z_ts = .{ .path = "../.." }`）。外部プロジェクトが
> `b.dependency("z_ts").module("zts_*")` で standalone モジュール群をそのまま再利用できることの
> 実証も兼ねています。

---

## 1. ディレクトリ構成

```text
examples/counter/
├── build.zig                 # 3 成果物のビルドグラフ（`embedFrontendDir` 同型ヘルパーを含む）
├── build.zig.zon             # ルート Z-Ts への path dependency
├── src/
│   ├── app.zig               # ★ 唯一のアプリ実装（`App(RuntimeMode)` + 単体テスト）
│   ├── desktop.zig           # ① DesktopRuntime + ウィンドウ + `--selftest`
│   ├── live.zig              # ② BridgeServer + BridgeHost (0.0.0.0 / PORT)
│   ├── wasm_app.zig          # ③ wasm32-freestanding (`exportApp(Spec)`)
│   ├── ssg_export.zig        # ③ dist/ エクスポータ
│   └── live_test.zig         # ② の実 TCP 統合テスト
├── web/
│   ├── index.html            # 共通 HTML（`./app.js` を読み込むだけ）
│   ├── main.ts               # 無改造 `@tauri-apps/api` v2 の `invoke` / `listen` のみ
│   ├── styles.css
│   └── tsconfig.json         # strict + `paths` で tests/tauri の依存を共有
├── scripts/build-web.mjs     # tsc --noEmit → esbuild(IIFE) → 埋め込み用ディレクトリ
└── tests/
    ├── live_probe.mjs        # 実 HTTP: HTML / Cookie / Invoke-Key / Origin / CSRF / SSE
    └── ssg_probe.mjs         # 静的 `dist/` + 実 `.wasm` + 最小 DOM で操作 E2E
```

---

## 2. 「分岐 0 行」の仕組み

`src/app.zig` は `RuntimeMode` を comptime パラメータに取る `App(runtime)` を公開するだけで、
成果物ごとの `if (target)` 分岐を持ちません。

```zig
pub fn App(comptime runtime: RuntimeMode) type { ... }
// desktop.zig : const Impl = app.App(.desktop);
// live.zig    : const Impl = app.App(.bridge);
// wasm_app.zig: const Impl = app.App(.wasm);
```

`zts_core.Host` VTable（`evalJs` / `setWindowTitle` / `createWindow` …）の実装だけが成果物ごとに
差し替わります。

| 成果物 | `Host` 実装 | バックエンド → フロントエンド通知 |
|---|---|---|
| ① デスクトップ | `WebviewHost` | WebView の `evalJs`（`ipc://` / `tauri://`） |
| ② Live Preview | `BridgeHost` | Server-Sent Events（`GET /__zts_events__?key=...`） |
| ③ 静的 SSG | `WasmHost` | `zts_host_eval_js` → 線形メモリ経由の `eval` |

フロントエンド（`web/main.ts`）は `invoke("increment")` / `listen("counter:changed")` を呼ぶだけで、
`getState` が返す `mode` フィールドを画面に表示します。**環境判定は JS 側にもありません。**

---

## 3. コマンド一覧（RPC）

| コマンド | 引数 | 戻り値 | 備考 |
|---|---|---|---|
| `getState` | なし | `{ count, step, mutations, mode }` | 副作用なし |
| `increment` | なし | 同上 | `counter:changed` を発火 |
| `decrement` | なし | 同上 | `counter:changed` を発火 |
| `reset` | なし | 同上 | `count` のみ 0 に戻す |
| `setStep` | `{ step }` | 同上 | `1..100` 以外は `StepOutOfRange` |

`i53` の上限（±2^52-1）を超える加減算は `CounterOverflow` を返し、**trap せず状態も変化しません**。

---

## 4. 静的サイト（`zig-out/dist/`）の配信

```text
dist/
├── index.html          # プリレンダリング済み（`__ZTS_SSG_DATA__` に初期状態を注入）
├── app.js              # 無改造 `@tauri-apps/api` v2 を内包した IIFE
├── styles.css
├── 404.html            # クライアントサイドルーティング用フォールバック
├── .nojekyll           # GitHub Pages が `_zts/` を配信できるようにする
├── _headers            # `application/wasm` + immutable キャッシュ（Cloudflare Pages / Netlify）
└── _zts/app.wasm       # wasm32-freestanding アプリ本体（約 184 KB, ReleaseSmall）
```

- ブートストラップ内の `wasmUrl` は **ページ階層からの相対 URL** なので、
  `https://user.github.io/任意のサブパス/` にそのまま置けます。
- `.nojekyll` / `_headers` / `404.html` は `zts_ssg.exportStaticSite` が自動生成します。

---

## 5. テスト（`zig build test`）

| レイヤ | 内容 |
|---|---|
| `src/app.zig` | 正常系・境界値（`step` 0/1/100/101）・`i53` オーバーフロー・未知コマンド・イベント発火・`Instance(Spec)` リーク検査（6 ケース） |
| `src/live_test.zig` | 実 TCP ポートで `BridgeServer` を起動し `tests/live_probe.mjs` を実行（43 チェック） |
| `tests/ssg_probe.mjs` | 静的 `dist/` をファイルシステムから読み、**実 `.wasm` + 最小 DOM** でボタン操作（28 チェック） |
| `counter --selftest` | `HeadlessMock` 上で `tauri://` / `ipc://` を実走（ウィンドウ不要） |

`live_probe.mjs` は実ブラウザと同じ経路（Cookie + `Tauri-Invoke-Key` + `Origin`）に加え、
**三重 CSRF 攻撃（キー欠落 / Cookie 改竄 / クロスオリジン）が全て `403`** になること、
`plugin:event|listen` 登録後に `counter:changed` が SSE で届くことを検証します。
`ssg_probe.mjs` は `__ZTS_SSG_DATA__` のハイドレーション、`convertFileSrc` の相対 URL、
`setStep(101)` の `StepOutOfRange` reject まで確認します。

---

## 6. 制約と次の一手

- `embedFrontendDir` の実装は現状ルート `build.zig` 内の関数のため、このサンプルは同型実装を
  ローカルに持っています。`M5-01` で `src/build_tools/` へ抽出され、依存パッケージから直接
  呼べる公開 API になります。
- デスクトップのネイティブバックエンドは現在 Linux（GTK3 + WebKit2GTK 4.1）のみです。
  macOS (`M3-01`) / Windows (`M3-02`) の実装後、このサンプルはコード変更なしで 3 OS ネイティブに
  なります（`-Dtarget` のクロスコンパイルも同一コマンドのまま）。
- セーブデータ等の永続化は未実装です。`M4-02`（スコープ付き FS）と OPFS/IndexedDB バックエンドの
  導入時に `State.deinit` と `app.zig` の初期化へ追加します。
- 定量ベンチマーク（冷間ビルド時間・バイナリサイズ・起動時間・RSS・IPC レイテンシ）は `M5-03` の
  `bench/` で本家 Rust Tauri と比較します。このサンプルはその **同一機能アプリ** を提供します。
