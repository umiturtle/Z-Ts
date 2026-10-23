# Task M1-06: `zts_webview` C ABI コア・Headless Mock・Linux WebKit2GTK 4.1 バックエンド

- **Status**: `in_progress`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `include/zts_webview.h`, `src/webview/`, `src/root.zig`, `build.zig`, `zigw`, `tests/standalone_modules.zig`, `docs/tasks/M1-06-webview-core-linux.md`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/00-overview.md`, `docs/architecture/web-zig-boundary.md`, `docs/decisions/0002-hybrid-architecture-proposal.md`, `docs/decisions/0003-zig-017-runtime-findings.md`
- **Next Step**: 単体切り出し可能な公開モジュール `zts_webview`（C ABI `include/zts_webview.h` + `src/webview/c_api.zig`・`HeadlessMock`・`PendingRequest` 世代ハンドル隔離・Pure Zig `extern "c"` `linux.zig` GTK3 + WebKit2GTK 4.1 バックエンド）を実装し、ローカル `HeadlessMock` テスト・ローカル sysroot リンク検証・GitHub Actions `ci-linux`（`xvfb-run` 実 GTK3/WebKit2GTK E2E）+ 3-OS CI オールグリーンを達成する。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push（並列エージェントとのスコープ分離確立）
- [ ] **`include/zts_webview.h` & `src/webview/c_api.zig`**:
  - JSON / RPC / Tauri 仕様に一切依存しないクリーンな C ABI 定義（約 25 関数：Engine 生成・破棄、`step(.blocking / .poll)`、スレッドセーフ `wakeup` / `request_quit`、マルチウィンドウ生成・操作・ドラッグ開始・子 Widget/View/HWND アタッチ、Custom URI Scheme 非同期リクエストコールバック & `complete_request`、UserScript 注入、`eval_js`、`navigate`、`open_devtools`、JS `postMessage` 受信フック）。
  - C / C++ / Rust / ゲームエンジン（SDL3 / GLFW / 独自 C コア）からも単体共有/静的ライブラリとして直接リンク可能。
- [ ] **`src/webview/pending.zig`**:
  - OS の生 Request ポインタ（`WebKitURISchemeRequest*` / `WKURLSchemeTask` / `ICoreWebView2WebResourceRequestedEventArgs*`）をメインスレッド専用の `foundation.HandlePool(PendingSlot, .ipc_request)` に厳格隔離。
  - ワーカースレッドからは `RequestId`（53-bit 世代ハンドル）と `OutgoingResponse`（`OwnedBytes` 完了コールバック付き）のみを MPSC キュー + `wakeup` で返却し、ページリロード等でキャンセル済みの世代不一致応答を安全に破棄・自動解放する（ABA / Use-After-Free 物理ゼロ保証）。
- [ ] **`src/webview/mock.zig` (`HeadlessMock`)**:
  - OS ウィンドウや GUI ライブラリ一切不要（Pure Zig `link_libc = false`、Linux / macOS / Windows 全環境で 0ms 動作）で、マルチウィンドウ操作・Custom URI Scheme 非同期 POST/GET 往復・UserScript 履歴・`eval_js` 履歴・JS → Zig メッセージ・`step(.poll / .blocking)` & 他スレッド `wakeup`・キャンセル済みリクエスト破棄まで 100% 検証できるテストバックエンド + `zts_core.Host` VTable 実装。
- [ ] **`src/webview/linux.zig` (`GTK3 + WebKit2GTK 4.1` ネイティブバックエンド)**:
  - `@cImport` / `addTranslateC` 不使用の高速 Pure Zig `extern "c"` バインディング（コールドビルド <2 秒維持）。
  - `g_main_context_iteration` による `step(.blocking)` / `step(.poll)` 制御 & `g_idle_add_full`（`G_PRIORITY_HIGH`）による任意スレッドからのロックフリー `wakeup`。
  - カスタム URI スキーム（`tauri://`, `ipc://`, `asset://` 等任意登録対応）登録：
    - `WebKitURISchemeRequest` から HTTP メソッド・ヘッダ（`SoupMessageHeaders`）・URI を抽出し、ボディがある場合は **`g_input_stream_read_bytes_async` を非同期チェーン読み取り** することで大容量 POST 時の IPC パイプ詰まりデッドロックを完全回避！
    - 応答時は **`WebKitURISchemeResponse`**（HTTP ステータスコード `200`/`206`/`400`/`403`/`404` + カスタム応答ヘッダ `Tauri-Response`, `Content-Range`, `Access-Control-Allow-Origin` 等完全付与！）と **`g_memory_input_stream_new_from_data(..., GDestroyNotify)`** を組み合わせ、WebKit がストリームを読み終えた瞬間に `OwnedBytes.deinit()` を自動発火させるゼロコピー応答！
  - `WebKitUserContentManager` による `AT_DOCUMENT_START` UserScript 注入 & `script-message-received:__zts` ネイティブ `window.webkit.messageHandlers.__zts.postMessage(...)` 高速チャネル登録！
  - 透過背景（`gdk_screen_get_rgba_visual` + `webkit_web_view_set_background_color`）、ウィンドウ装飾・リサイズ・フルスクリーン・最前面・`gtk_window_begin_move_drag` タイトルバードラッグ・既存 `GtkContainer` 子埋め込みまで完備！
- [ ] **自動 E2E 検証 & 3-OS CI オールグリーン**:
  - ローカル: `HeadlessMock` 単体テスト・マルチスレッド非同期カスタムスキーム往復テスト・C ABI ラウンドトリップテスト・ローカル Linux sysroot リンク検証すべてパス。
  - GitHub Actions `ci-linux` (`xvfb-run`): 実 GTK3 ウィンドウ + 実 WebKit2GTK 4.1 レンダラプロセス上で HTML 描画 → `tauri://` / `ipc://` 双方向 JSON & 生バイナリ (`Uint8Array`) 往復 → JS `postMessage` → `step()` クリーン終了（GPA メモリリーク **0 バイト**）が自動テストで完全通過し、macOS / Windows と合わせて 3 OS オールグリーンを達成する！

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `M1-01`〜`M1-05` 完了済み（PR #6, Commit `f0cc3dd`, 3-OS CI `#39897035963` GREEN）。
  - ローカル Linux sysroot (`gtk+-3.0: 3.24.38`, `webkit2gtk-4.1: 2.50.6`) 展開完了。
  - `M1-06` タスクファイル作成 & ロック取得。
