# Task M3-03: 親ウィンドウ Overlay 埋め込み & C ABI 他言語実証

- **Status**: `done`（Run [`#40503143705`](https://github.com/umiturtle/Z-Ts/actions/runs/40503143705) で 3/3 GREEN）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `examples/c_embed/`, `src/webview/embed_test.zig`, `src/webview/{mod,c_api,types,mock,linux,macos,windows}.zig`, `include/zts_webview.h`, `build.zig`, `.github/workflows/ci.yml`, `docs/tasks/M3-03-overlay-embed-c-abi.md`, `docs/decisions/0008-*.md`, `docs/architecture/zts-webview-backends.md`
- **Upstream Reference**: `vendor/tao/src/platform_impl/{linux,macos,windows}/`（既存 `GtkWidget*` / `NSView*` / `HWND` を親として受け取る埋め込み経路）、`vendor/wry/src/webview2/mod.rs`（`put_ParentWindow` 相当）
- **Next Step**: `M4-02`（Scoped FS）または `M4-01`（Dialog / Clipboard）へ。`M3-03` の成果物を触る場合は
  ①`./zigw build test --summary all` で `OK c-embed`（ローカルは SKIP 可）②`python3 scripts/check-docs.py`
  ③CI の 3 ゲート（`OK c-embed host=gtk3|win32|cocoa` と `OK embed-gtk structural=1`）を確認する。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 既存アプリ（GTK / AppKit / Win32 の自前ウィンドウと自前イベントループ）へ `zts_webview` を
**子ウィンドウとして重ねる（Overlay）** 経路を完成させ、その利用面である C ABI を
**「純粋な C プログラムが `#include "zts_webview.h"` + `libzts_webview` のリンクだけで動かす」**
ことによって実証する。`M1-06` で定義だけ済んでいた C ABI に、外部ループ統合に必要な
`zts_webview_poll()` と `zts_webview_window_fit_parent()` を追加する。

- [x] `zts_webview_poll(engine)`（= `zts_webview_step(engine, ZTS_STEP_POLL)`）と
      `zts_webview_window_fit_parent(engine, win)`（親のクライアント領域へ子を再フィット）を C ABI に追加
- [x] 3 バックエンドで埋め込みモードの契約を統一: 子は親のクライアント領域を埋める /
      `closeWindow` は子だけを破棄し **親は破棄しない** / `nativeHandle` は埋め込み時のみ WebView 側を返す
- [x] `src/webview/embed_test.zig`: 契約テスト（Mock で全 OS）+ Linux GTK 実ウィンドウ埋め込み E2E
- [x] `examples/c_embed/main.c`: 純粋な C99（`gtk+3.0` / Cocoa ランタイム / `user32` のみで親ウィンドウを作り、
      自前ループから `zts_webview_poll` を叩く）+ `README.md`
- [x] `build.zig`: `zts_c_embed` を C ソースから `libzts_webview` へ静的リンクして install
      （`zig build test` の `run` ステップに接続済み）
- [x] `.github/workflows/ci.yml`: 3 OS で `zts_c_embed` を**実行**し、`OK c-embed …` マーカーをゲート化
      （Linux は `OK embed-gtk structural=1` もゲート）
- [x] `./zigw quick-test` / `./zigw build test` / `python3 scripts/check-docs.py` がパス
- [x] GitHub Actions 3/3 GREEN（Run `#40503143705`）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと（実装）**:
  - `types.WindowConfig.parent_native_handle` の意味を「Overlay 埋め込み」に確定
    （`size` は無視、親のクライアント領域を埋める、toplevel を作らない）。
  - `linux.zig`: `LinuxWindow.parent` を保持し、子に `hexpand/vexpand`、`fitParent()` は
    親の allocation を `gtk_widget_set_size_request` に反映。`nativeHandle` は埋め込み時に WebView。
  - `macos_shim.m`: `ZtsWindow.parentView`（weak）+ 生成時に `webview.frame = parent.bounds`、
    `zts_macos_window_fit_parent()` を追加、`zts_macos_window_native()` は埋め込み時に `WKWebView` を返す。
  - `windows.zig`: `WS_CHILD` を **親の `GetClientRect`** で生成、`fitParent()` は `SetWindowPos`。
  - `mock.zig`: `fit_count` を記録する `fitParent()`（契約テスト用）。
  - `Engine.fitParent()`（`mod.zig`）+ `zts_webview_poll` / `zts_webview_window_fit_parent`（ヘッダ & `c_api.zig`）。
  - `src/webview/embed_test.zig`: Mock 契約 4 本（全 OS）+ GTK 実埋め込み 1 本（Xvfb、`OK embed-gtk structural=1`）。
  - `examples/c_embed/main.c`（純 C99）+ `README.md`、`build.zig` の `zts_c_embed`、CI の 3 ゲート。
- **実測値（Run [`#40503143705`](https://github.com/umiturtle/Z-Ts/actions/runs/40503143705)）**:
  - Linux: `OK c-embed host=gtk3 checks=9 structural=1 child=520x380 pong=1 frames=43`
  - macOS: `OK c-embed host=cocoa checks=9 structural=1 child=520x380 pong=1 frames=197`
  - Windows: `OK c-embed host=win32 checks=9 structural=1 child=520x380 pong=1 frames=138`
  - `./zigw quick-test` PASS / `./zigw build test --summary all` **43/43** / `check-docs.py` 35 files OK。

---

## 3. 設計判断・技術メモ・ハマりどころ

（実装しながら追記）
### 3.1 ハマりどころ（実機でしか出ないもの）

| 症状 | 原因 | 対策 |
|---|---|---|
| GTK / Cocoa だけページの JS が走らない（`messages=0`, `schemes=0`） | ホストのポンプが即戻るので 6000 フレームを数ミリ秒で消費し、WebKit の web プロセス起動前にループが終了 | `host_frame_wait()`（`g_usleep(1000)` / `Sleep(1)` / `+[NSThread sleepForTimeInterval:]`）で 1 フレーム 1 ms。Windows だけ通っていたのは `Sleep(1)` が既にあったため |
| GTK でホストの resize が反映されない | 同上（イベントを処理する時間が無い） | 上記 + `check(resized_host.w <= 528 …)` でホスト側の縮小も検証 |
| `type '**windows.WinWindow' does not support field access` | `HandlePool.getPtr()` は `?*const T` を返す（値型が `*WinWindow` なので二重参照） | `w.*.parent` / `w.*.hwnd`（`@constCast` でも可） |
| `usleep` が `-std=c99` で未宣言 | glibc の機能テストマクロ | GTK は `g_usleep`、Cocoa は `objc_msgSend` 経由の `+[NSThread sleepForTimeInterval:]`（POSIX マクロを持ち込まない） |
| ヘッドレス機で `zig build test` が落ちる | `zts_c_embed` が 77 で終了 | `EXIT_SKIP = 0` + `SKIP c-embed …` を出力し、**CI は `OK c-embed` マーカーで判定** |
