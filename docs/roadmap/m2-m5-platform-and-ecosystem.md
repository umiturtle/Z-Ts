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
- **実装**: [`../../examples/counter/README.md`](../../examples/counter/README.md)
  （`zig build` / `zig build desktop` / `zig build live` / `zig build dist` / `zig build test`、設計は
  [`../architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md) §6）。

---

## M3：macOS / Windows ネイティブ完成 & C ABI 解放（Wave 4 並列）

### `M3-01`：macOS ネイティブバックエンド（`Cocoa` + `WKWebView`）
- **専有スコープ**: `src/webview/{macos.zig,macos_shim.m}`
- **内容**:
  - `./zigw cc`（Clang）でビルドされる約 350 行のクリーンな Objective-C シム + Zig ラッパー。
  - `NSApplication` / `NSWindow`（**CSS 左上原点 ⇔ Cocoa 左下原点の Y 軸自動変換**、透過タイトルバー、`performWindowDragWithEvent`）+ `step(.blocking / .poll)`。
  - `WKURLSchemeHandler` による `ipc://` / `asset://` / `tauri://` 非同期応答（`stopURLSchemeTask` 競合クラッシュを `PendingRequest` 世代チェックで 100% 防止）。
- **完了条件 (DoD)**: GitHub Actions `ci-macos`（Apple Silicon `arm64`）上で実ウィンドウ起動・IPC 往復・クリーン終了 E2E テストが通過すること。
- **実装**: [`../decisions/0006-macos-appkit-wkwebview-backend.md`](../decisions/0006-macos-appkit-wkwebview-backend.md) /
  [`../tasks/M3-01-macos-wkwebview.md`](../tasks/M3-01-macos-wkwebview.md)
  （Objective-C は `src/webview/macos_shim.m` 1 ファイル・`zts_macos_*` 33 関数の Flat C ABI に集約し、
  `@cImport` / `addTranslateC` は不採用。Y 軸変換は `src/webview/coords.zig` の純関数として全 OS で単体テスト。
  Run `#39932834622` で 3/3 OS GREEN、macOS は `OK macos-wk checks=10 binary=98304 sum=42 screen=1024x674 preflights=0`。）

### `M3-02`：Windows ネイティブバックエンド（`Win32` + DLL 不要 Direct `WebView2`）
- **専有スコープ**: `src/webview/{windows,webview2_com,webview2_loader}.zig`
- **内容**:
  - **外部 `WebView2Loader.dll` 不要**: レジストリ / `EBWebView` パスから `EmbeddedBrowserWebView.dll` を直接 `LoadLibraryExW` する Pure Zig ローダー。
  - Win32 ウィンドウ管理（`Per-Monitor DPI Aware v2` 物理⇔論理ピクセル自動変換、ダークタイトルバー、透過コンポジション、フレームレスドラッグ）。
  - `ICoreWebView2` COM VTable 直定義、`http://ipc.localhost/*` フィルタ + `ICoreWebView2Deferral` メインスレッド STA 応答。
- **完了条件 (DoD)**:
  - Linux 上からの `./zigw build -Dtarget=x86_64-windows-gnu` クロスコンパイルが単一 `.exe` を出力すること。
  - GitHub Actions `ci-windows` 上でその単一 `.exe` が DLL 同梱なしで起動し、双方向 IPC E2E テストを通過すること。
- **実装**: [`../decisions/0007-windows-win32-webview2.md`](../decisions/0007-windows-win32-webview2.md) /
  [`../tasks/M3-02-windows-webview2.md`](../tasks/M3-02-windows-webview2.md)
  （`WebView2Loader.dll` 非同梱・レジストリから `EmbeddedBrowserWebView.dll` を直接ロード。COM vtable は
  `scripts/gen-webview2-com.py` が `WebView2.h` から生成し 17 IF / 217 スロットを `@sizeOf` で断言。
  E2E は **standalone exe** `tests/webview/windows_e2e.zig` で、WebView2 `155.0.4283.62` 上
  `OK windows-wv2 checks=19 runtime=155.0.4283.62 preflights=1 dpr=1.00 single-exe=1`。）

### `M3-03`：既存親ウィンドウ埋め込み（Overlay Mode）& C ABI 他言語実証
- **専有スコープ**: `examples/c_embed/`, `src/webview/embed_test.zig`
- **内容**:
  - 既存の `GtkWidget*` / `NSView*` / `HWND` を親として渡し、外部イベントループから毎フレーム `zts_webview_poll()` するだけで動く組み込みモードの検証。
  - 純粋な C コード（`examples/c_embed/main.c`）から `#include "zts_webview.h"` + `libzts_webview` をリンクして動作するサンプルテスト。
- **実装**: [`../decisions/0008-overlay-embedding-and-c-abi.md`](../decisions/0008-overlay-embedding-and-c-abi.md) /
  [`../architecture/zts-webview-backends.md`](../architecture/zts-webview-backends.md) /
  [`../tasks/M3-03-overlay-embed-c-abi.md`](../tasks/M3-03-overlay-embed-c-abi.md)
  （`zts_webview_poll` + `zts_webview_window_fit_parent` を C ABI に追加。`WindowConfig.size` は埋め込み時に
  無視され、3 バックエンドとも **親のクライアント領域** を埋める。Run `#40503143705` で 3/3 GREEN、
  `OK c-embed host=gtk3|cocoa|win32 checks=9 structural=1 child=520x380 pong=1`。）

---

## M4：デスクトップ拡張モジュール & Tauri 資産移行（Wave 4 並列）

すべて `zts_rpc.Schema` に選択的に追加できる **独立モジュール（未使用時はバイナリサイズ 0 バイト）** として実装します：

- **`M4-01` (`src/tauri/{dialog,clipboard}/` + `src/tauri/native*`)**: ファイル選択・保存・メッセージダイアログ（GTK FileChooserNative / macOS NSOpenPanel・NSSavePanel / Win32 Common Item Dialog COM）および OS クリップボード読み書き。
  - **実装**: [`../architecture/tauri-dialog-clipboard.md`](../architecture/tauri-dialog-clipboard.md) / **設計判断**: [`../decisions/0012-dialog-and-clipboard-backends.md`](../decisions/0012-dialog-and-clipboard-backends.md) / **タスク**: [`../tasks/M4-01-dialog-clipboard.md`](../tasks/M4-01-dialog-clipboard.md)
  - ワイヤ層（`zts_tauri`）は Pure Zig のままバックエンド vtable + Mock を持ち、実 OS 実装は `zts_tauri_native` に隔離。選択されたパスは **`plugin:fs` のスコープへ動的に付与** される（本家 `tauri-plugin-fs` と同じ挙動）。
- **`M4-02` (`src/tauri/fs/`)**: `OsPath` 対応ファイル読み書き・ディレクトリ走査・ストリーム転送（`std.Io.File` + シンボリックリンク解決によるスコープ外脱出防止）。
  - **実装**: [`../architecture/tauri-fs-plugin.md`](../architecture/tauri-fs-plugin.md) / **設計判断**: [`../decisions/0011-scoped-fs-plugin.md`](../decisions/0011-scoped-fs-plugin.md) / **タスク**: [`../tasks/M4-02-scoped-fs.md`](../tasks/M4-02-scoped-fs.md)
  - `plugin:fs|*` 全 20 コマンド（`read_text_file` / `write_file` / `read_dir` / `stat` / `open`+`read`+`write`+`seek` …）。`rid` は既存 `ResourceTable` に載せるため偽造・二重 close は `BadResourceId`。
  - スコープ判定は **字句正規化 → シンボリックリンク解決（40 ホップ上限）→ 成分単位の包含判定**。`/srv/app` は `/srv/app-evil` を含まず、`root/link -> /etc` 経由の脱出は `OutOfScope`。
- **`M4-03` (`src/tauri/{menu,tray}/`)**: ネイティブアプリケーションメニュー・コンテキストメニュー・システムトレイアイコン。
  - **実装**: [`../architecture/tauri-menu-tray.md`](../architecture/tauri-menu-tray.md) / **設計判断**: [`../decisions/0013-menu-and-tray-backends.md`](../decisions/0013-menu-and-tray-backends.md) / **タスク**: [`../tasks/M4-03-menu-tray.md`](../tasks/M4-03-menu-tray.md)
  - wire 層（`plugin:menu` 22 + `plugin:tray` 12 コマンド）・メニューツリー・`plugin:resources` 連携・`Channel` 通知・アクセラレータパーサは Pure Zig で完成し、`withCorePlugins` の 7 コアプラグインに統合済み。
  - 上流 `@tauri-apps/api` 2.12.4 の `menu` / `tray` を無改変で Node bridge と実 WebKit2GTK の両方で E2E 検証。
  - GTK3 ネイティブ描画（`GtkMenuBar` / `GtkStatusIcon`）は実装済み。AppKit / Win32 のメニューは `M4-05`、トレイは `M4-06` で実装済み（3 OS パリティ達成）。
- **`M4-04` (`src/tauri/{config_import,acl}.zig`)**: 既存 Tauri v2 の `tauri.conf.json` および `capabilities/*.json` を `comptime` / 実行時に読み込み、コード書き換え最小で既存 Tauri フロントエンド資産を移行できる互換レイヤ。
  - **実装**: [`../architecture/tauri-config-import-acl.md`](../architecture/tauri-config-import-acl.md) / **設計判断**: [`../decisions/0014-config-import-and-acl.md`](../decisions/0014-config-import-and-acl.md) / **タスク**: [`../tasks/M4-04-config-import-acl.md`](../tasks/M4-04-config-import-acl.md)
  - `config_import` は `productName` / `identifier` / `app.windows[]`（→ `core.WindowSpec`）/ `security.{csp,assetProtocol.scope,capabilities}` / `build` / `bundle` / `plugins` を読み、未知キーは警告・型違いはパス付きエラー。
  - `acl` は `capabilities/*.json`（単体 / 配列 / `{capabilities:[…]}`）を解析し、**コマンド名から機械生成した権限識別子**で deny > allow の fail-closed 判定を行う。`Policy` を `withAuthCtx` に渡したときだけ有効（opt-in）。

---

## M5：開発者体験 CLI・バンドラ・対本家 Rust Tauri 定量比較（Wave 5）

### `M5-01`：`build.zig` 統合ヘルパー（`embedFrontend` & 自動 `tsgen`）
- **専有スコープ**: `src/build_tools/`
- **内容**: Vite 等の出力ディレクトリ `dist/` を走査して圧縮・CSP ハッシュ付与済みの静的 Zig モジュールを生成するビルドステップと、コンパイルと同時にフロントエンド側へ `bindings.gen.ts` を自動出力するビルドステップ。
- **実装**: [`../architecture/build-tools.md`](../architecture/build-tools.md) / **設計判断**: [`../decisions/0017-build-tools.md`](../decisions/0017-build-tools.md) / **タスク**: [`../tasks/M5-01-build-tools.md`](../tasks/M5-01-build-tools.md)
  - `src/build_tools/{mod,assets,embed_main,tsgen_main}.zig` の 3 層。`mod.zig` は `std.Build` のみ、`assets.zig` は `std` のみ（＝全 OS で単体テスト可能）、残り 2 つはビルド時に走る CLI。
  - `embedFrontend` の生成物は `M2-01` の上位互換（`entries` / `assets` / `sha256_digests` に `gzip_entries` と `csp_hashes` を追加）。gzip は `MTIME=0` / `OS=Unix` 固定で**どの OS でも同一バイト列**、元より大きくなるファイルは `.gz` を作らない。
  - CSP は**インライン**の `<script>` / `<style>` 本文のみをハッシュ化（外部 script は対象外、引用符内の `>` でタグを打ち切らない）。
  - `tsgenBindings` は生成（`captureStdOut` → `addUpdateSourceFiles`）と検証（`--check`、**キャッシュ無効化**付き）の 2 モード。`zig build test` が検証に依存するので、再生成忘れは CI で落ちる。
  - `examples/counter/build.zig` の写し実装（約 40 行）を削除し、`dep.builder.path("src/build_tools/embed_main.zig")` で共通実装を起動する形にした。

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

### `M5-04`（追加タスク）：CI テスト項目の拡張 & 3-OS スクリーンショット回帰ギャラリー
- **専有スコープ**: `src/webview/{types,mod,mock,linux,macos,macos_shim.m,windows,webview2_com,c_api,png}.zig`, `include/zts_webview.h`, `examples/gallery/`, `scripts/verify-screenshots.mjs`, `.github/workflows/ci.yml`
- **タスクファイル**: [`../tasks/M5-04-ci-screenshot-matrix.md`](../tasks/M5-04-ci-screenshot-matrix.md) / **設計判断**: [`../decisions/0009-screenshot-capture-and-ci-gallery.md`](../decisions/0009-screenshot-capture-and-ci-gallery.md)
- **内容**:
  1. `zts_webview` に poll 駆動のスクリーンショット API（`captureWindow` / `takeCapture`、PNG 固定）を追加。GTK は `webkit_web_view_get_snapshot`、Cocoa は `takeSnapshotWithConfiguration:`、WebView2 は `CapturePreview`、Mock は決定的な合成 PNG。
  2. C ABI に `zts_webview_window_capture` / `zts_webview_capture_take` / `zts_webview_capture_free` と `zts_capture_t` を追加（所有権は呼び出し側へ移動）。
  3. `examples/gallery` が 8 パターン（light / dark / CJK / scroll / JS 往復 / HiDPI / wide / compact）を撮り、`manifest.json`（実ビューポート・バイト数・メッセージ数・SHA-256）を書く。
  4. `scripts/verify-screenshots.mjs` が依存ゼロで PNG を展開し、寸法・非空白（ユニーク色数 / 輝度レンジ）・テーマ別平均輝度・中心画素・manifest 整合を検証。`index.html` のコンタクトシートも生成。
  5. CI 3 OS に「gallery 実行 → マーカーゲート → artifact 保存（`screenshots-<os>`）」を追加。Linux はさらに Live Preview（`counter-live`）と SSG `dist/` を headless Chrome で撮影。
- **完了条件（DoD）**: 3 OS の CI で `OK gallery host=<gtk3|cocoa|win32> patterns=8 captured=8` と `OK screenshots …` が出ること。`--require-native` により mock フォールバックは失敗扱い。

### `M5-05`（追加タスク）：OS 間パリティ & 9 フレームワーク比較
- **専有スコープ**: `examples/gallery/`, `examples/frameworks/`, `scripts/{build-fonts.py,gen-framework-demos.mjs,check-font-coverage.mjs,compare-screenshots.mjs,lib/png.mjs}`, `.github/workflows/ci.yml`
- **タスクファイル**: [`../tasks/M5-05-framework-os-parity.md`](../tasks/M5-05-framework-os-parity.md) / **設計判断**: [`../decisions/0010-cross-os-pixel-parity.md`](../decisions/0010-cross-os-pixel-parity.md) / **設計**: [`../architecture/screenshot-parity.md`](../architecture/screenshot-parity.md)
- **内容**:
  1. **Linux の文字化けを根絶**: Noto Sans/Serif JP + JetBrains Mono を使う文字だけにサブセット化して同梱し、`/zts/fonts/*` として 3 OS に同一バイト列を配信。`check-font-coverage.mjs` で収録外の文字を CI で落とす。
  2. **レイアウト指紋**: `load` + `document.fonts.ready` 後の要素矩形（≤1px 丸め）と `font_ok` を `manifest.json` に記録し、OS 間で ≤1px 一致を強制。
  3. **画素比較**: 依存ゼロの PNG デコーダで全画素差分・背景色（厳密）・平均輝度を比較（`--max-diff 0.12` / `--max-mad 8`。構造は行数完全一致 + ボックス ±1px で厳密に縛る）。
  4. **9 フレームワーク**（Angular / Solid / Svelte / SolidStart / Next.js / Nuxt / Astro / SvelteKit / React）を各 CLI で実ビルドし、同一 DOM・同一文言の画面を `tauri://localhost/fw/<name>/` で配信して撮影。
  5. **`ci-parity` ジョブ**: 3 OS の artifact をまとめて比較し `OK parity …` をマーカーにする。
- **完了条件（DoD）**: `OK gallery host=<gtk3|cocoa|win32> patterns=17 captured=17` と `OK parity hosts=… patterns=17 …` が同一 Run で出ること。
- **結果（2025-10-28, run `40634580935`）**: 4 ジョブ（Linux / macOS / Windows / parity）すべて green。
  `OK parity hosts=gtk3,cocoa,win32 patterns=17 comparisons=34 layout=ok pixels=max:9.77% mad:6.07`。

