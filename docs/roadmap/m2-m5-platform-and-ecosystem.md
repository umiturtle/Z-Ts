# M2〜M5 詳細ロードマップ：統合実証・3 OS ネイティブ・エコシステム・比較ベンチマーク

このドキュメントは、フェーズ M2〜M5（Wave 3〜Wave 5）の実装仕様と完了基準を定めます。

---

## M2：4 モード同型実証 & 双方向 SSG / WebAssembly パイプライン（Wave 3）

### `M2-01`：双方向 SSG パイプライン（`zts_ssg` / `embedFrontendDir`）& `WasmHost` 4 モード同型実証
- **専有スコープ**: `src/wasm/`, `src/ssg/`, `src/root.zig`, `build.zig`, `tests/ssg/`, `docs/decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`
- **内容**:
  1. **Inbound SSG（フロントエンド静的ビルド成果物の自動取り込み）**:
     - `build.zig` 公開ヘルパー `embedFrontendDir` と Pure Zig スキャナ `src/ssg/embed_dir_main.zig` により、Astro / Next.js（`output: 'export'`）/ Vite 等の出力ディレクトリ（`out/`・`dist/`）を再帰走査し、OS 非依存の決定論的ソート済み `@embedFile` `zts_web.Assets` モジュールを自動生成する。
  2. **`zts_wasm`（`wasm32-freestanding` ランタイム & `WasmHost`）**:
     - アプリ側の `zts_rpc.Schema` と `zts_tauri` 標準プラグイン群（`window`, `event`, `path`, `app`, `resources`, `Channel(T)`）を 1 行のコード分岐もなく `wasm32-freestanding` の `.wasm` バイナリへコンパイルし、無改造 `@tauri-apps/api` v2 と線形メモリ直接呼び出しで接続する `WasmHost`・`WasmApp`・`js_bootstrap` を提供する。
  3. **Outbound SSG（サーバー不要・プリレンダリング静的サイト `dist/` エクスポータ `zts_ssg`）**:
     - 静的/動的ルートごとのプリレンダリング（`<title>`・OGP メタタグ・HTML 安全エスケープ済み初期 JSON データ `<script id="__ZTS_SSG_DATA__">`・静的 HTML フラグメント注入）、ディレクトリ階層に応じた相対 URL 自動補正（GitHub Pages サブパス完全対応）、スコープ検査付き `_zts/assets/` 書き出し、および `.nojekyll` / `_headers` / `404.html` 生成を行う。
- **完了条件 (DoD)**:
  - **4 モード完全同型 E2E 実証**: 同一の Zig コマンド実装と無改造 `@tauri-apps/api` v2 スイートが **① `HeadlessMock` / ② `BridgeServer` (HTTP+SSE) / ③ Linux Native `WebKit2GTK 4.1` (`xvfb-run`) / ④ `wasm32-freestanding` 静的 SSG `dist/` (`WebAssembly.instantiate`)** の **全 4 環境** で完全一致動作し、Linux / macOS / Windows 全 3 OS CI でオールグリーンになること。

### `M2-02`：ショーケースサンプルアプリ & ベンチマーク基盤整備
- **専有スコープ**: `examples/counter/`
- **内容**:
  - デスクトップ単一バイナリ・Live Preview・静的 SSG Web 出力（`dist/`）の 3 成果物を 1 つのサンプルプロジェクトから生成できるリファレンス実装を提供する。

---

## M3：macOS / Windows ネイティブ完成 & C ABI 解放（Wave 4 並列）

### `M3-01`：macOS ネイティブバックエンド（`Cocoa` + `WKWebView`）
- **専有スコープ**: `src/webview/{macos.zig,macos_shim.m}`
- **内容**:
  - `./zigw cc`（Clang）でビルドされる約 350 行のクリーンな Objective-C シム + Zig ラッパー。
  - `NSApplication` / `NSWindow`（**CSS 左上原点 ⇔ Cocoa 左下原点の Y 軸自動変換**、透過タイトルバー、`performWindowDragWithEvent`）+ `step(.blocking / .poll)`。
  - `WKURLSchemeHandler` による `ipc://` / `asset://` / `tauri://` 非同期応答（`stopURLSchemeTask` 競合クラッシュを `PendingRequest` 世代チェックで 100% 防止）。
- **完了条件 (DoD)**: GitHub Actions `ci-macos`（Apple Silicon `arm64`）上で実ウィンドウ起動・IPC 往復・クリーン終了 E2E テストが通過すること。

### `M3-02`：Windows ネイティブバックエンド（`Win32` + DLL 不要 Direct `WebView2`）
- **専有スコープ**: `src/webview/{windows,webview2_com,webview2_loader}.zig`
- **内容**:
  - **外部 `WebView2Loader.dll` 不要**: レジストリ / `EBWebView` パスから `EmbeddedBrowserWebView.dll` を直接 `LoadLibraryExW` する Pure Zig ローダー。
  - Win32 ウィンドウ管理（`Per-Monitor DPI Aware v2` 物理⇔論理ピクセル自動変換、ダークタイトルバー、透過コンポジション、フレームレスドラッグ）。
  - `ICoreWebView2` COM VTable 直定義、`http://ipc.localhost/*` フィルタ + `ICoreWebView2Deferral` メインスレッド STA 応答。
- **完了条件 (DoD)**:
  - Linux 上からの `./zigw build -Dtarget=x86_64-windows-gnu` クロスコンパイルが単一 `.exe` を出力すること。
  - GitHub Actions `ci-windows` 上でその単一 `.exe` が DLL 同梱なしで起動し、双方向 IPC E2E テストを通過すること。

### `M3-03`：既存親ウィンドウ埋め込み（Overlay Mode）& C ABI 他言語実証
- **専有スコープ**: `examples/c_embed/`, `src/webview/embed_test.zig`
- **内容**:
  - 既存の `GtkWidget*` / `NSView*` / `HWND` を親として渡し、外部イベントループから毎フレーム `zts_webview_poll()` するだけで動く組み込みモードの検証。
  - 純粋な C コード（`examples/c_embed/main.c`）から `#include "zts_webview.h"` + `libzts_webview` をリンクして動作するサンプルテスト。

---

## M4：デスクトップ拡張モジュール & Tauri 資産移行（Wave 4 並列）

すべて `zts_rpc.Schema` に選択的に追加できる **独立モジュール（未使用時はバイナリサイズ 0 バイト）** として実装します：

- **`M4-01` (`src/tauri/{dialog,clipboard}/`)**: ファイル選択・保存・メッセージダイアログ（GTK FileChooserNative / macOS NSOpenPanel・NSSavePanel / Win32 Common Item Dialog COM）および OS クリップボード読み書き。
- **`M4-02` (`src/tauri/fs/`)**: `OsPath` 対応ファイル読み書き・ディレクトリ走査・ストリーム転送（`std.Io.File` + シンボリックリンク解決によるスコープ外脱出防止）。
- **`M4-03` (`src/tauri/{menu,tray}/`)**: ネイティブアプリケーションメニュー・コンテキストメニュー・システムトレイアイコン。
- **`M4-04` (`src/tauri/{config_import,acl}.zig`)**: 既存 Tauri v2 の `tauri.conf.json` および `capabilities/*.json` を `comptime` / 実行時に読み込み、コード書き換え最小で既存 Tauri フロントエンド資産を移行できる互換レイヤ。

---

## M5：開発者体験 CLI・バンドラ・対本家 Rust Tauri 定量比較（Wave 5）

### `M5-01`：`build.zig` 統合ヘルパー（`embedFrontend` & 自動 `tsgen`）
- **専有スコープ**: `src/build_tools/`
- **内容**: Vite 等の出力ディレクトリ `dist/` を走査して圧縮・CSP ハッシュ付与済みの静的 Zig モジュールを生成するビルドステップと、コンパイルと同時にフロントエンド側へ `bindings.gen.ts` を自動出力するビルドステップ。

### `M5-02`：`zts` CLI ツール（`init` / `dev` / `build`）
- **専有スコープ**: `src/cli/`
- **内容**:
  - `zts init`: 最小構成テンプレート生成（5 秒でビルド完了する初期プロジェクト）。
  - `zts dev`: フロントエンド dev server 起動 ＋ Zig ファイル変更監視＆高速インクリメンタル再起動 ＋ `--browser`（Live Preview モード）オプション。
  - `zts build`: フロントエンドバンドル実行 → 単一実行ファイル生成（クロスコンパイル対応）。

### `M5-03`：3-OS パッケージャ & 対本家 Rust Tauri v2.12.4 ベンチマーク
- **専有スコープ**: `src/bundler/`, `bench/`
- **内容**:
  1. 配布パッケージ生成：Linux `.deb` / AppDir、macOS `.app` バンドル / `.dmg`、Windows アイコン・マニフェスト埋め込み `.exe`。
  2. **GitHub Actions 自動比較ベンチマークスイート (`bench/`)**: 同一機能のアプリを **本家 Rust 版 Tauri (`vendor/tauri`)** と **`Z-Ts`** の両方でビルド・実行し、以下の 6 指標を CI Check Summary に自動出力する：
     - ① クリーンビルド時間（Cold Build Time）
     - ② 1 行変更時のインクリメンタルビルド時間
     - ③ 最終バイナリサイズ（`-O ReleaseSmall` / `ReleaseFast` vs Cargo `--release` strip）
     - ④ ウィンドウ初回描画までの起動時間（Cold Startup Time）
     - ⑤ アイドル時および負荷時の RSS メモリ使用量
     - ⑥ IPC レイテンシ（小 JSON 10,000 往復）& バイナリスループット（64MB Raw 転送）
