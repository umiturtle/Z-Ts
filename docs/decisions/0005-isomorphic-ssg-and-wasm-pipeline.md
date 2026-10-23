# ADR 0005: 双方向 SSG パイプラインと `wasm32` 同型（Isomorphic）静的サイト出力アーキテクチャ

- **日付**: 2026-10-23
- **ステータス**: 採択（Accepted）
- **関連タスク**: [`M2-01`](../tasks/M2-01-ssg-and-wasm-runtime.md)

---

## 1. 背景と目的

Z-Ts で構築するデスクトップアプリおよび将来の別プロダクト（ビジュアルノベルエンジン・配信/メディア系ツール等）において、次の **2 つの方向の SSG（Static Site Generation）統合** が求められた：

1. **Inbound SSG（フロントエンド SSG 成果物の取り込み）**:
   Astro、Next.js（`output: 'export'`）、SvelteKit（`adapter-static`）、Vite 等が出力した静的ディレクトリ（`dist/` / `out/`、ネストされた `/about/index.html` 等を含む）を、手書きマニフェスト不要で単一実行ファイルまたは Web バンドルへ自動埋め込みしたい。
2. **Outbound SSG（Z-Ts アプリ自体のサーバー不要・静的サイト `dist/` 出力）**:
   同じ Zig バックエンドロジック（`zts_rpc.Schema` + `zts_tauri` コアプラグイン）と無改造の `@tauri-apps/api` v2 フロントエンドから、**バックエンドサーバーを一切必要としない純粋な静的ファイル群（`dist/`：プリレンダリング HTML + `.wasm` + スコープ済み静的アセット + ホスティング設定）** を生成し、GitHub Pages / Cloudflare Pages / Netlify / itch.io 等へそのまま配置可能にしたい。

---

## 2. アーキテクチャ決定事項

### 2.1 4 モード同型（Quad-Target Isomorphic）実行モデル

`zts_foundation` / `zts_web` / `zts_core` / `zts_rpc` / `zts_tauri` がすべて `link_libc = false`（OS・GUI・ソケット非依存）で構成されている利点を活かし、**アプリ側の Zig コマンド実装と TypeScript UI コードを 1 行も分岐させずに** 以下の 4 ターゲットへ出力可能とする：

| 実行ターゲット | `zts_core.Host` 実装 | IPC 経路 | 主な用途 |
| :--- | :--- | :--- | :--- |
| **1. Headless Mock** | `WebviewHost` (`HeadlessMock`) | インメモリ同期/非同期キュー | 0ms 決定論ユニットテスト・CI |
| **2. Native Desktop** | `WebviewHost` (`GTK`/`WKWebView`/`WebView2`) | Custom Scheme (`ipc://`, `tauri://`, `asset://`) | 本番ネイティブ単一実行ファイル配布 |
| **3. Live HTTP Bridge** | `BridgeHost` (`BridgeServer`) | `POST /__zts_ipc__/*` + `SSE` | ブラウザ Live Preview・リモート UI |
| **4. Static Web / SSG** | **`WasmHost` (`zts_wasm`, `wasm32-freestanding`)** | **JS ⇔ Wasm 線形メモリ直接呼び出し + 相対静的アセット** | **サーバーレス静的サイト公開・Web 体験版** |

### 2.2 `zts_wasm`（`src/wasm/`）の最小 FFI 境界設計
- Wasm バイナリサイズとオーバーヘッドを最小化するため、JS ホストからインポートする外部関数を以下の **2 個のみ** に限定する：
  1. `zts_host.zts_host_eval_js(ptr, len)`: `Channel(T)` のフレーム配信・終端通知、`EventBus` のイベント配信、および DOM ウィンドウタイトル等の同期をすべて単一チャネルで処理する。
  2. `zts_host.zts_host_fill_random(ptr, len)`: WebCrypto `crypto.getRandomValues` を `std.Io` VTable の乱数源へ直結する。
- JS → Wasm 呼び出し（`zts_wasm_invoke`）は JSON 文字列と `application/octet-stream` 生バイナリ（`Uint8Array` / `ArrayBuffer`）の双方を Wasm 線形メモリ経由で直接受け渡し、HTTP シリアライズを介さず数マイクロ秒で完結させる。

### 2.3 サブパス配置耐性を持つ `zts_ssg`（`src/ssg/`）静的サイト出力仕様
静的ホスティング（特に GitHub Pages の `https://<user>.github.io/<repo>/` サブパス運用）で頻発する事故を構造的に防ぐため、以下を標準仕様とする：
1. **階層深さに応じた自動相対パス解決**:
   `/`（深さ 0 → `./_zts/app.wasm`）と `/chapters/prologue/`（深さ 2 → `../../_zts/app.wasm`）で、注入されるブートストラップ `<script>` 内の `wasmUrl` および `assetBaseUrl`（`convertFileSrc` 変換先）をページのディレクトリ階層に応じて自動計算する。これによりルート直下でも任意のサブパス配下でも設定変更なしで動作する。
2. **スコープ外アセットのビルド時混入防止**:
   デスクトップ版の `asset://` と同じ `asset_scope_globs`（`zts_foundation.glob`）を SSG エクスポート時にも強制適用し、許可パターン外のファイル（秘密鍵・未公開データ等）が `dist/_zts/assets/` にコピーされることを防ぐ。
3. **ホスティングメタファイルの自動出力**:
   - `.nojekyll`: GitHub Pages の Jekyll 処理により `_zts/`・`_astro/`・`_next/` 等のアンダースコア始まりディレクトリが除外される問題を自動回避する。
   - `_headers`: Cloudflare Pages / Netlify 向けに `Content-Type: application/wasm`、CSP（`wasm-unsafe-eval` 含む）、および必要に応じた COOP/COEP ヘッダを出力する。
   - `404.html`: SPA クライアントサイドルーティングのフォールバックページを生成する。

---

## 3. 明示的なトレードオフと制約事項

- **ブラウザサンドボックス制約**: 静的サイト（SSG + `WasmHost`）としてブラウザ上で動作する場合、OS の任意ネイティブファイルパス直接アクセス・OS ネイティブウィンドウ移動・システムトレイ・画面キャプチャ等の OS 特権 API はブラウザ制約を受ける（`WasmHost` 上では仮想状態更新または `Unsupported` 応答となる）。永続化が必要なアプリ（ゲームのセーブデータ等）は、将来 `M4-02`（ストレージ抽象）で OPFS / IndexedDB バックエンドへ接続する。
