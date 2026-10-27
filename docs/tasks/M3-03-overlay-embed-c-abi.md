# Task M3-03: 親ウィンドウ Overlay 埋め込み & C ABI 他言語実証

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `examples/c_embed/`, `src/webview/embed_test.zig`, `src/webview/{mod,c_api,types,mock,linux,macos,windows}.zig`, `include/zts_webview.h`, `build.zig`, `.github/workflows/ci.yml`, `docs/tasks/M3-03-overlay-embed-c-abi.md`, `docs/decisions/0008-*.md`, `docs/architecture/zts-webview-backends.md`
- **Upstream Reference**: `vendor/tao/src/platform_impl/{linux,macos,windows}/`（既存 `GtkWidget*` / `NSView*` / `HWND` を親として受け取る埋め込み経路）、`vendor/wry/src/webview2/mod.rs`（`put_ParentWindow` 相当）
- **Next Step**: `src/webview/types.zig` の `WindowConfig` に埋め込み既定値（親のクライアント領域へフィット）を追加し、続いて `include/zts_webview.h` + `src/webview/c_api.zig` に `zts_webview_poll` / `zts_webview_window_fit_parent` を追加、`examples/c_embed/main.c` を書いて `./zigw build -Dtarget=x86_64-windows-gnu` と Linux 実走で確認する。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 既存アプリ（GTK / AppKit / Win32 の自前ウィンドウと自前イベントループ）へ `zts_webview` を
**子ウィンドウとして重ねる（Overlay）** 経路を完成させ、その利用面である C ABI を
**「純粋な C プログラムが `#include "zts_webview.h"` + `libzts_webview` のリンクだけで動かす」**
ことによって実証する。`M1-06` で定義だけ済んでいた C ABI に、外部ループ統合に必要な
`zts_webview_poll()` と `zts_webview_window_fit_parent()` を追加する。

- [ ] `zts_webview_poll(engine)`（= `zts_webview_step(engine, ZTS_STEP_POLL)`）と
      `zts_webview_window_fit_parent(engine, win)`（親のクライアント領域へ子を再フィット）を C ABI に追加
- [ ] 3 バックエンドで埋め込みモードの契約を統一: 子は親のクライアント領域を埋める /
      `closeWindow` は子だけを破棄し **親は破棄しない** / `nativeHandle` は埋め込み時のみ WebView 側を返す
- [ ] `src/webview/embed_test.zig`: 契約テスト（Mock で全 OS）+ Linux GTK 実ウィンドウ埋め込み E2E
- [ ] `examples/c_embed/main.c`: 純粋な C99（`gtk+3.0` / Cocoa ランタイム / `user32` のみで親ウィンドウを作り、
      自前ループから `zts_webview_poll` を叩く）+ `README.md`
- [ ] `build.zig`: `zts_c_embed` を C ソースから `libzts_webview` へ静的リンクして install
- [ ] `.github/workflows/ci.yml`: 3 OS で `zts_c_embed` を**実行**し、`OK c-embed …` マーカーをゲート化
- [ ] `./zigw quick-test` / `./zigw build test` / `python3 scripts/check-docs.py` がパス
- [ ] GitHub Actions 3/3 GREEN（Run 番号を本書と ADR に記録）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 調査: `include/zts_webview.h` は 26 関数 + `zts_window_desc_t.parent_native_handle` まで定義済み（`M1-06`）。
    `c_api.zig` はその全てを実装済みで、`tests/webview/verify_c_abi.c` が厳格 C99 でリンク・実行する。
  - 調査: 3 バックエンドとも `parent_native_handle` の受け口は既にある
    （Linux = `gtk_container_add` / macOS = `[parent addSubview:]` / Windows = `WS_CHILD` の子 HWND）。
- **作業中・直前の状態**:
  - これから埋め込み既定値（フィット）と C ABI の 2 関数を追加する。

---

## 3. 設計判断・技術メモ・ハマりどころ

（実装しながら追記）
