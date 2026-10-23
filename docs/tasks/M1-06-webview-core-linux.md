# Task M1-06: `zts_webview` C ABI コア・Headless Mock・Linux WebKit2GTK 4.1 バックエンド

- **Status**: `done`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `include/zts_webview.h`, `src/webview/`, `src/webview_host.zig`, `src/root.zig`, `build.zig`, `zigw`, `tests/webview/`, `tests/standalone_modules.zig`, `docs/tasks/M1-06-webview-core-linux.md`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/00-overview.md`, `docs/architecture/web-zig-boundary.md`, `docs/decisions/0002-hybrid-architecture-proposal.md`, `docs/decisions/0003-zig-017-runtime-findings.md`
- **Next Step**: `M1-07`（`zts_tauri`: Tauri v2 ワイヤー互換プロトコル、`window.__TAURI_INTERNALS__` JS ブートストラップ、`"__CHANNEL__:<id>"` `Channel(T)`、および標準 `window`/`event`/`path`/`app` コマンドモジュール群）へ進む。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push（並列エージェントとのスコープ分離確立）
- [x] **`include/zts_webview.h` & `src/webview/c_api.zig` + `tests/webview/verify_c_abi.c`**:
  - JSON / RPC / Tauri 仕様に一切依存しないクリーンな 26 関数 C99 / C++17 C ABI（Engine 生成・破棄、`step(.blocking / .poll)`、スレッドセーフ `wakeup` / `request_quit`、Scheme 登録 & ゼロヒープ `initCustom` `complete_request`、Window 操作一式、親ネイティブウィジェット埋め込み、UserScript、`eval_js`、`navigate`、`load_html`、`open_devtools`、JS `postMessage` 受信フック）。
  - 実際に `zig cc -std=c99 -Wall -Wextra -Werror` でコンパイルし `libzts_webview_static.a` とリンク実行する CI 自動テスト（`verify_webview_c_abi`）を Debug / `-DNDEBUG` `ReleaseFast` 両モードで検証。
- [x] **`src/webview/pending.zig`**:
  - OS の生 Request ポインタをメインスレッド専用の `foundation.HandlePool(Entry, .ipc_request)` に厳格隔離し、ワーカースレッドからの遅延応答時に世代不一致（ウィンドウ閉鎖・リロード済み）を安全に破棄・自動解放する仕組みを単体テストで検証。
- [x] **`src/webview/mock.zig` (`HeadlessMock`)**:
  - OS ウィンドウや GUI ライブラリ一切不要（Pure Zig `link_libc = false`、0ms 実行）で、マルチスレッド非同期カスタムスキーム往復・`step(.blocking / .poll)`・UserScript / `evalJs` 記録・キャンセル破棄を完全検証。
- [x] **`src/webview/gtk_bindings.zig` & `src/webview/linux.zig` (`LinuxGtkBackend`)**:
  - `@cImport` / `addTranslateC` 不使用の高速 Pure Zig `extern "c"` バインディング（実ヘッダ 1 対 1 検証済み、コールドビルド <1s）。
  - `g_main_context_iteration` による `step(.blocking / .poll)` と `g_idle_add_full(G_PRIORITY_HIGH)` によるロックフリー `wakeup`。
  - `WebKitURISchemeRequest` の非同期 64 KiB チャンク読み取り（`g_input_stream_read_bytes_async`）による大容量 POST デッドロック防止、および **`g_bytes_new_with_free_func` + `g_memory_input_stream_new_from_bytes`** によるゼロコピー `OwnedBytes` 自動解放連携。
  - トップレベル `GtkWindow` と既存 `GtkContainer*` 子埋め込みの両対応、透過背景 `GdkRGBA`、`AT_DOCUMENT_START` UserScript、`window.webkit.messageHandlers.__zts.postMessage(...)`（文字列 / JSON 自動変換）を実装。
- [x] **自動 E2E 検証 & 3-OS CI オールグリーン**:
  - GitHub Actions `ci-linux`（`xvfb-run` 実 GTK3 ウィンドウ + WebKit2GTK 4.1 レンダラ）上で 96 KiB バイナリ XOR POST 往復・バックグラウンド OS スレッド JSON RPC 往復・UserScript 注入・JS `postMessage`・GPA リーク **0 バイト** を自動検証し、macOS / Windows と合わせて全 3 OS グリーン達成。

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `include/zts_webview.h`、`src/webview/{mod,types,pending,mock,gtk_bindings,linux,c_api}.zig`、`src/webview_host.zig`、`tests/webview/verify_c_abi.c` を実装。
  - ローカルで `-Dgtk=true`（実 `libwebkit2gtk-4.1.so` + `libgtk-3.so` 動的リンク）・`-Dgtk=false`（Pure Zig）・`ReleaseFast` の全 3 構成 × 全 22 ビルドステップ完全通過を確認済み。
