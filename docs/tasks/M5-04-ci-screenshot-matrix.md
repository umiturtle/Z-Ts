# Task M5-04: CI テスト項目の拡張 & 3-OS スクリーンショット回帰ギャラリー

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/webview/{types,mod,mock,linux,macos,macos_shim.m,windows,webview2_com,c_api,png}.zig`, `include/zts_webview.h`, `examples/gallery/`, `scripts/verify-screenshots.mjs`, `build.zig`, `.github/workflows/ci.yml`, `docs/tasks/M5-04-ci-screenshot-matrix.md`, `docs/decisions/0009-*.md`, `docs/architecture/zts-webview-backends.md`, `docs/environment/github-actions.md`, `docs/INDEX.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Upstream Reference**: `vendor/wry/src/webview2/mod.rs`（`CapturePreview` 相当の扱いがないことの確認）, `vendor/tao/`, WebKit2GTK `WebKitWebView.h`（`webkit_web_view_get_snapshot`）, `WKWebView.takeSnapshotWithConfiguration:completionHandler:`, `ICoreWebView2::CapturePreview`
- **Next Step**: `src/webview/png.zig`（PNG IHDR 解析 + 最小エンコーダ）と `Capture` 型を `types.zig` に追加し、`mock.zig` で capture の状態機械を TDD する。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 「CI が各 OS で実際に描画した画面を PNG で残し、目視・機械の両方で確認できる」状態にする。同時に、これまで CI で検証できていなかった領域（キャプチャ API・複数パターンの描画・Live Preview / SSG の見た目・スクロール / HiDPI / ダークテーマ）を **テスト項目として追加** する。

- [ ] `zts_webview` に **非同期・poll 駆動のスクリーンショット API** を追加する
  - `Engine.captureWindow(win_id)` / `Engine.takeCapture(win_id)`（`Capture{ bytes, width, height }`、呼び出し側が `deinit()`）
  - 4 バックエンド実装: GTK3（`webkit_web_view_get_snapshot` + cairo PNG ストリーム）、macOS（`takeSnapshotWithConfiguration:` → `NSBitmapImageRep` PNG）、Windows（`ICoreWebView2::CapturePreview` + `SHCreateMemStream`）、Mock（生成 PNG）
  - C ABI: `zts_webview_window_capture` / `zts_webview_capture_take` / `zts_webview_capture_free` + `include/zts_webview.h` の宣言
- [ ] 単体テスト（正常系・異常系・境界値・`std.testing.allocator` リーク 0）
  - `png.zig`: IHDR 解析（正常 / 切り詰め / 不正シグネチャ）、生成 PNG の往復
  - `mock.zig`: capture → take の 1 往復、二重 take、未知ウィンドウ、close 後の take
- [ ] `examples/gallery/`（新規・独立パッケージ）: 1 ウィンドウで **複数パターン** を順に描画し、それぞれ PNG に保存する
  - パターン: `hero-light` / `dashboard-dark` / `typography-cjk` / `scroll-offset` / `hidpi-2x` / `small-viewport` / `wide-viewport` / `js-roundtrip`（`tauri://` スキームへの fetch 往復で DOM が変わる）
  - `zig build screenshots -Dshot-dir=<dir>` で実行、`OK gallery <n> patterns=<n> dir=<dir>` マーカー出力、`SKIP gallery …` は exit 0
  - 各 PNG と一緒に `manifest.json`（パターン名・寸法・期待輝度・SHA-256）を出力する
- [ ] `scripts/verify-screenshots.mjs`（Node 22・依存ゼロ）: PNG を `zlib` でデコードし、寸法一致・非空白（ユニーク色数 / 輝度レンジ）・パターン間の差分・マニフェスト整合を検証して `OK screenshots …` を出力
- [ ] CI のテスト項目を追加する
  - 3 OS すべてで gallery を実行し、PNG を `actions/upload-artifact@v4` で保存（`screenshots-<os>`）
  - `verify-screenshots.mjs` を **ゲート** にする（マーカー必須・失敗時 exit 1）
  - Linux は追加で headless Chrome による Live Preview / SSG `dist/` のブラウザ描画スクリーンショットも取得
  - 既存の M3-01 / M3-02 / M3-03 マーカーゲートは維持
- [ ] `./zigw fmt --check` / `./zigw quick-test` / `./zigw build test` / `python3 scripts/check-docs.py` のパス
- [ ] 3 OS GitHub Actions でグリーン（キャプチャのマーカーが各 OS で実走していること）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - タスクシェード作成（分散ロック宣言）
  - 既存バックエンド調査: `linux.zig`（`GtkWidget*` 直持ち）、`macos_shim.m`（C コールバック + `WKWebView`）、`windows.zig`（`Handler` 共用 vtable + `CapturePreview` スロットは既に予約済み）、`webview2_com.zig`（`ICoreWebView2CapturePreviewCompletedHandler` 未定義）
  - 環境確認: `cairo 1.16.0` / `webkit2gtk-4.1 2.50.6` が利用可能、Zig 0.17 に `std.hash.Crc32` あり
- **作業中・直前の状態**:
  - 実装開始前（ドキュメントのみ）

---

## 3. 設計判断・技術メモ・ハマりどころ

- **poll 駆動にする理由**: 3 バックエンドともキャプチャは非同期（WebKit の snapshot / WKWebView の completion / WebView2 の Invoke）。既存の `completeRequest` と同じく「開始 → `step(.poll)` → 取り出し」の形に揃えると、C ホストのフレームループ（`zts_webview_poll`）にそのまま乗る。ブロッキング API はホスト側のループを止めるので採らない。
- **PNG 固定にする理由**: 3 OS すべてが PNG をネイティブに生成でき、`Capture` に寸法を自己記述できる（IHDR）。JPEG は透過・可逆性・決定性で劣る。
- **`Capture` の所有権**: バックエンドが `allocator` で確保し、`takeCapture` が所有権を呼び出し側へ移す。`closeWindow` / `deinit` 時に未回収分は必ず解放する（`std.testing.allocator` でリーク検査）。
- **既知の罠（M3-02 の再発防止）**: `CapturePreview` は完了ハンドラの `Invoke` が来るまでストリームを読んではならない。`SHCreateMemStream` のストリームは `Seek(0)` してから `Read` する。GTK の `webkit_web_view_get_snapshot` は `GAsyncResult` を `webkit_web_view_get_snapshot_finish` に渡す必要があり、返る `cairo_surface_t*` は呼び出し側が `cairo_surface_destroy` する。
- **CI のスクショは「見た目」だけでは合格にしない**: マーカー + Node 検証（寸法・非空白・パターン間差分）で機械的に判定する。画像は artifact として保存し、`index.html` のコンタクトシートを同梱する。
