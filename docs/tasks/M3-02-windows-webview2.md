# Task M3-02: Windows ネイティブバックエンド（`Win32` + DLL 不要 Direct `WebView2`）

- **Status**: `in_progress`（実装・ローカル検証は完了。残りは `ci-windows` 実機 GREEN の確認のみ）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/webview/{windows,win32,webview2_com,webview2_loader,windows_util}.zig`, `tests/webview/windows_smoke.zig`, `src/webview/mod.zig`, `build.zig`, `zigw`, `scripts/gen-webview2-com.py`, `.github/workflows/ci.yml`, `docs/tasks/M3-02-windows-webview2.md`, `docs/decisions/0007-*.md`
- **Upstream Reference**: `vendor/wry/src/webview2/`, [`sumatrapdfreader/sumatrapdf` `ext/webview2/WebView2Loader.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/master/ext/webview2/WebView2Loader.cpp)（MS 純正ローダのクリーンルーム再実装）, `vendor/tao/src/platform_impl/windows/`
- **Next Step**: `gh run list` で最新 run を取り、`scripts/ci-logs.sh <run>` の `ci-windows` に
  ①`OK windows-wv2 checks=12 …` ②`OK windows-webview2-smoke single-exe=1 …` ③`3/3 GREEN`
  が揃えば DoD を全チェックし `ADR-0007 §4` に実測値を記入して `done` 化する。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `zts_webview` に Windows ネイティブバックエンドを追加し、Linux GTK / macOS WKWebView と
**完全に同一の `zts_core.Host` / `zts_tauri` スタック**が Windows（GitHub Actions `windows-latest`）で
動作することを E2E で証明する。WebView2 SDK の `WebView2Loader.dll` は同梱しない。

- [x] `src/webview/webview2_com.zig`: `ICoreWebView2` 系 COM インターフェースの vtable を Pure Zig で直定義
      （`@cImport` なし。`WebView2.h` の宣言順と 1:1 / **17 IF・217 スロット**を生成器が出力・`@sizeOf` 断言付き）
- [x] `src/webview/webview2_loader.zig`: レジストリ 4 段探索 →
      `<runtime>\EBWebView\<arch>\EmbeddedBrowserWebView.dll` を `LoadLibraryExW` し、
      `CreateWebViewEnvironmentWithOptionsInternal` を `GetProcAddress` する Pure Zig ローダー
      （`WebView2Loader.dll` 不要）
- [x] `src/webview/win32.zig`: `user32` / `kernel32` / `ole32` / `shlwapi` / `dwmapi` / `advapi32` の最小 `extern` 群
      （`WNDCLASSEXW` / `CREATESTRUCTW` / `MSG` / `MINMAXINFO` / `IStream` 14 スロット）
- [x] `src/webview/windows.zig`: `LinuxGtkBackend` / `MacOsBackend` と同一メソッド面の `WindowsWebView2Backend`
- [x] `Engine` に `.windows_webview2` バリアントを追加（`.auto` は Windows 実機 → WebView2、失敗時 `HeadlessMock`）
- [x] **Per-Monitor DPI Aware v2**: `SetProcessDpiAwarenessContext(-4)` + `GetDpiForWindow` + `WM_DPICHANGED` +
      論理 ⇔ 物理変換（`zts_foundation.geometry` 経由）
- [x] **ダークタイトルバー / 角丸 / フレームレスドラッグ**: `DwmSetWindowAttribute`（`DWMWA_USE_IMMERSIVE_DARK_MODE`,
      `DWMWA_WINDOW_CORNER_PREFERENCE`）、`WM_NCLBUTTONDOWN` + `HTCAPTION`、`WS_EX_LAYERED` + `Controller2` 透過
- [x] **`http://ipc.localhost/*` フィルタ + `ICoreWebView2Deferral`**: メインスレッド STA で
      `CreateWebResourceResponse` を返し、ワーカースレッドからの完了も `PendingTable` 世代チェックで安全に処理
- [x] `JS → Zig` メッセージ（`window.chrome.webview.postMessage`）と `Zig → JS`（`ExecuteScript`）
- [x] CORS ヘッダ自動付与（`Access-Control-Allow-*` + `Access-Control-Expose-Headers: Tauri-Response, …`）
      + `OPTIONS` プリフライト吸収（204）
- [x] Linux からの `./zigw build -Dtarget=x86_64-windows-gnu` クロスコンパイルが単一 `.exe` を出力
      （`zig-out/bin/zts_webview2_smoke.exe` 2.4 MB / DLL 0 件。CI ゲートで常時監視）
- [ ] GitHub Actions `ci-windows` で実ウィンドウ + IPC 往復 + クリーン終了 E2E が通過

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと（実装）**:
  - `scripts/gen-webview2-com.py`: `WebView2.h` を `DECLSPEC_XFGVIRT` ベースで解析し、**17 IF / 217 スロット**を
    生成（`CALL` 定数、comptime `guid()`、`IID_IUnknown`、`@sizeOf(VTable)` 断言、GUID テスト）。
    `python3 scripts/gen-webview2-com.py <WebView2.h> -o src/webview/webview2_com.zig` で再生成。
  - `src/webview/win32.zig`: 型 + 定数 + 6 DLL の extern + `toWide`/`fromWide`（**3 テスト / 全 OS で実行**）。
  - `src/webview/windows_util.zig`: OS 非依存ヘルパ（**8 テスト / 全 OS**）。
  - `src/webview/webview2_loader.zig`: 4 段探索 + `LoadLibraryExW` + `DllCanUnloadNow` 判定 + 実レジストリ読み取りテスト。
  - `src/webview/windows.zig`: `WindowsWebView2Backend` 本体 + COM ハンドラ 5 種の手書き vtable +
    **E2E テスト 1 本**（`OK windows-wv2 checks=12 …` を出力）+ 純ロジックテスト 2 本。
  - `tests/webview/windows_smoke.zig`: 単一 `.exe` 配備証明用のスモーク実行ファイル。
  - `build.zig`: `-Dwindows` フラグ、Win32 import lib 10 個（**`.use_pkg_config = .no`**）、
    `zts_webview2_smoke` の install。
  - `ci.yml`: `ci-linux` に Linux→Windows クロスコンパイルゲート、`ci-windows` に WebView2 Evergreen 導入 +
    E2E マーカー検証 + 単一 `.exe` 起動ゲート。
- **ローカル実測（Linux ホスト）**:
  - `./zigw quick-test`: `zts_webview` **22 pass / 2 skip**（skip = Windows 専用 2 本）。
  - `./zigw build test --summary all`: 全ステップ成功。
  - `./zigw build -Dtarget=x86_64-windows-gnu --summary all`: **4/4**。
  - `zig test -target x86_64-windows-gnu`（10 import lib 付き）: `windows.zig` のテストが **リンクまで通る**（x86_64 / aarch64 両方）。
  - `python3 scripts/check-docs.py`: 33 files OK。
- **残作業**: `ci-windows` の実走確認 → 本書の DoD チェック + `done` 化 + `ADR-0007 §4` 実測値記入。

---

## 3. 設計判断・技術メモ・ハマりどころ

**設計判断は [`ADR-0007`](../decisions/0007-windows-win32-webview2.md) に集約**（ローダ探索順、
COM vtable の生成方針、`tauri://` → `http://tauri.localhost` 正規化、deferral 所有権、ステップ駆動）。

### 3.1 Zig 0.17 固有のハマりどころ（再発防止）

| 症状 | 原因 | 対策 |
|---|---|---|
| `binary operator '**' has whitespace …` | Zig 0.17 で配列繰り返し `**` が廃止 | `[64]u8 = @splat(0)` |
| `extern structs cannot contain fields of type '…HandlerKind'` | `extern struct` の enum フィールドはタグ型を推論できない | `enum(u32) { … }` |
| `invalid format string 'vx'` | `{vx}` は存在しない | `{x}` |
| `error{DanglingSurrogateHalf,…}` が `error{InvalidUtf16}` に合わない | `utf16LeToUtf8Alloc` のサロゲート系エラー | `catch \|e\| switch (e) { error.OutOfMemory => …, else => error.InvalidUtf16 }` |
| `@compileError` が「到達しない」はずの `else` で発火 | `hexDigit(c: u8)` の `switch` は `c` が comptime-known でも全 prong を解析する | `fn hexDigit(comptime c: u8)` + `inline for` |
| GUID の 4 ブロック目が `invalid hex digit` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` の index 23 が 4 本目の `-` | `parseByte(text[21..23])` の次は `text[24..26]`（1 文字スキップ） |
| `callconv(.winapi)` が macOS で落ちる | `aarch64_aapcs_win` は LLVM 非対応 | `pub const CC = if (windows) .winapi else .c` |
| `type '?*const anyopaque' not a function` | 生成器は未使用メソッドを消去する | `remove_WebMessageReceived` 等を使うなら生成器の `TYPED` に型を足す |
| `duplicate switch value '204'` | range と単値の重複 | `else => "OK"` に寄せる |
| `@bitCast(comptime_int)` 不可 | ビット幅未確定 | `@bitCast(@as(u32, …))` / `styleBits()` ヘルパ |
| `declarations are not allowed between container fields` | struct 内でフィールド宣言の後に宣言を置いた | フィールドを全て先頭にまとめる |
| `expected type '*T', found '*const *T'` | `HandlePool(T).get()` は `?*const T` を返す | `@constCast(slot.*)`（値型が `*WinWindow` のため二重参照） |
| `free of invalid memory len=22 align=2`（Windows 実機 panic） | `allocSentinel(u16, utf8.len, 0)` の**部分スライス**を返して `free` した | `calcUtf16LeLen` で**実長**を取ってから確保する（`Allocator.free` は `slice.len` からサイズを逆算する） |
| `Can't find …pkg-config.BAT on PATH`（Windows runner） | Zig の `linkSystemLibrary` は既定で `pkg-config` を呼ぶ | `.use_pkg_config = .no` を明示 |

### 3.2 Windows 実機でしか分からない部分をどう検証するか

- **型 / ABI / リンク**: Linux から `-target x86_64-windows-gnu` の `zig build` と、
  10 import lib を付けた `zig test --test-no-exec`（= リンクまで実施）で確認。CI では
  `ci-linux` の「クロスコンパイルゲート」が毎 push で単一 `.exe` を生成する。
- **振る舞い**: `ci-windows` の E2E（`windows.zig` 内のテスト、`OK windows-wv2 checks=12 runtime=… preflights=…`）と、
  インストール済み `.exe` を直接起動するスモーク（`OK windows-webview2-smoke single-exe=1 …`）。
  どちらもマーカー欠落 = ジョブ失敗にして無言スキップを防ぐ（`windows-latest` には WebView2 Runtime が
  入っていないため、ワークフロー側で Evergreen を導入してから走らせる）。
- **純ロジック**: `windows_util.zig`（8）+ `win32.zig`（3）+ `webview2_com.zig` の GUID テスト +
  `windows.zig` の `classifyVirtualOrigin` / `styleBits` が **Linux / macOS CI でも走る**
  （`mod.zig` のテストブロックが Windows 3 ファイルを無条件 import し、`.winapi` は `CC` で吸収）。
- **E2E が証明する経路**: HWND 生成 → 環境 → コントローラ → `tauri://` ナビゲーション
  （`http://tauri.localhost` 書き換え + `WebResourceRequested` フィルタ）→ ページ内 JS の
  `fetch('http://ipc.localhost/ping')`（`application/json` POST = **CORS プリフライト発生**）→
  `OPTIONS` を Zig に渡さず 204 で吸収 → **ワーカースレッドから `completeRequest`** →
  `ICoreWebView2Deferral::Complete` → `postMessage` で Zig に復帰 → 窓を閉じて `step()` が false。
