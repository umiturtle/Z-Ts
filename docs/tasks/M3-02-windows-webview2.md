# Task M3-02: Windows ネイティブバックエンド（`Win32` + DLL 不要 Direct `WebView2`）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/webview/{windows,webview2_com,webview2_loader,win32_bindings}.zig`, `src/webview/mod.zig`, `build.zig`, `zigw`, `.github/workflows/ci.yml`, `docs/tasks/M3-02-windows-webview2.md`, `docs/architecture/`, `docs/decisions/0007-*.md`
- **Upstream Reference**: `vendor/wry/src/webview2/`, [`sumatrapdfreader/sumatrapdf` `ext/webview2/WebView2Loader.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/master/ext/webview2/WebView2Loader.cpp)（MS 純正ローダのクリーンルーム再実装）, `vendor/tao/src/platform_impl/windows/`
- **Next Step**: `src/webview/webview2_com.zig`（`WebView2.h` から機械生成した COM vtable 定義）→ `webview2_loader.zig`（レジストリ探索 + `EmbeddedBrowserWebView.dll` 直接ロード）→ `windows.zig`（`WindowsWebView2Backend`）→ `mod.zig` へ `.windows_webview2` → `ci-windows` で E2E 実走。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `zts_webview` に Windows ネイティブバックエンドを追加し、Linux GTK / macOS WKWebView と
**完全に同一の `zts_core.Host` / `zts_tauri` スタック**が Windows（GitHub Actions `windows-latest`）で
動作することを E2E で証明する。WebView2 SDK の `WebView2Loader.dll` は同梱しない。

- [ ] `src/webview/webview2_com.zig`: `ICoreWebView2` 系 COM インターフェースの vtable を Pure Zig で直定義
      （`@cImport` なし。`WebView2.h` の宣言順と 1:1）
- [ ] `src/webview/webview2_loader.zig`: レジストリ（`EdgeUpdate\Clients\{F3017226-…}`）→
      `<location>\EBWebView\<arch>\EmbeddedBrowserWebView.dll` を `LoadLibraryExW` し、
      `CreateWebViewEnvironmentWithOptionsInternal` を `GetProcAddress` する Pure Zig ローダー
      （`WebView2Loader.dll` 不要）
- [ ] `src/webview/win32_bindings.zig`: `user32` / `gdi32` / `shcore` / `dwmapi` / `shlwapi` の最小 `extern` 群
- [ ] `src/webview/windows.zig`: `LinuxGtkBackend` / `MacOsBackend` と同一メソッド面の `WindowsWebView2Backend`
- [ ] `Engine` に `.windows_webview2` バリアントを追加（`.auto` は Windows 実機 → WebView2、失敗時 `HeadlessMock`）
- [ ] **Per-Monitor DPI Aware v2**: 論理ピクセル ⇔ 物理ピクセル変換（`zts_foundation.geometry` 経由）と `WM_DPICHANGED`
- [ ] **`http://ipc.localhost/*` フィルタ + `ICoreWebView2Deferral`**: メインスレッド STA で
      `CreateWebResourceResponse` を返し、ワーカースレッドからの完了も `PendingTable` 世代チェックで安全に処理
- [ ] `JS → Zig` メッセージ（`window.chrome.webview.postMessage`）と `Zig → JS`（`ExecuteScript`）
- [ ] CORS ヘッダ自動付与（`Access-Control-Allow-Origin: *`）+ `OPTIONS` プリフライト吸収
- [ ] Linux からの `./zigw build -Dtarget=x86_64-windows-gnu` クロスコンパイルが単一 `.exe` を出力
- [ ] GitHub Actions `ci-windows` で実ウィンドウ + IPC 往復 + クリーン終了 E2E が通過

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - タスクシェード作成（分散ロック宣言）
- **作業中・直前の状態**:
  - `WebView2.h` の COM インターフェース宣言順を機械抽出し、Zig vtable を生成する段階

---

## 3. 設計判断・技術メモ・ハマりどころ

（実装中に追記する）
