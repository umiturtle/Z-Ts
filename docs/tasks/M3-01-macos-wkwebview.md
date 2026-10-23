# Task M3-01: macOS ネイティブバックエンド（Cocoa + WKWebView）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/webview/{macos.zig,macos_shim.m,mod.zig,types.zig}`, `build.zig`, `zigw`, `.github/workflows/ci.yml`, `docs/tasks/M3-01-macos-wkwebview.md`, `docs/architecture/`, `docs/decisions/0006-*.md`
- **Upstream Reference**: `vendor/wry/src/webkitgtk/`（同型の `WKURLSchemeHandler` 相当）, `vendor/tao/src/platform_impl/macos/`, [`docs/architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md)
- **Next Step**: `src/webview/macos_shim.m`（Cocoa/WKWebView シム）→ `src/webview/macos.zig`（`Engine` へ `.macos_wk` 追加）→ `build.zig` の macOS リンク設定 → `ci-macos` で E2E 実走。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `zts_webview` に macOS ネイティブバックエンドを追加し、Linux GTK と **完全に同一の
`zts_core.Host` / `zts_tauri` スタック** が Apple Silicon 実機（GitHub Actions `macos-latest`）で
動作することを E2E で証明する。

- [ ] `src/webview/macos_shim.m`（Objective-C、`./zigw cc` でビルド）: `NSApplication` / `NSWindow` /
      `WKWebView` / `WKURLSchemeHandler` / `WKScriptMessageHandler` を C ABI だけで公開
- [ ] `src/webview/macos.zig`: `LinuxGtkBackend` と同一メソッド面の `MacOsBackend`
- [ ] `Engine` に `.macos_wk` バリアントを追加（`.auto` は macOS 実機 → `MacOsBackend`、失敗時 `HeadlessMock`）
- [ ] **CSS 左上原点 ⇔ Cocoa 左下原点の Y 軸自動変換**（`cssToCocoaOriginY`、Linux 上でも単体テスト可能な純関数）
- [ ] 透過タイトルバー（`titlebarAppearsTransparent` + `FullSizeContentView`）と `performWindowDragWithEvent:`
- [ ] `stopURLSchemeTask:` 競合クラッシュ防止（シム内の生存トークン表 + Zig 側 `PendingTable` の二重世代チェック）
- [ ] クロスオリジン `fetch` 対応（`Access-Control-Allow-Origin` / `Access-Control-Expose-Headers` の自動付与）
- [ ] Linux / macOS 双方でビルドが通る（`-Dmacos` 未指定の Linux では `.m` を一切コンパイルしない）
- [ ] GitHub Actions `ci-macos`（arm64）で実ウィンドウ + IPC 往復 + クリーン終了 E2E が通過

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - タスクシェード作成（分散ロック宣言）
- **作業中・直前の状態**:
  - `src/webview/macos_shim.m` と `src/webview/macos.zig` の実装中

---

## 3. 設計判断・技術メモ・ハマりどころ

（実装中に追記する）
