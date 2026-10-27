# Task M3-02: Windows ネイティブバックエンド（`Win32` + DLL 不要 Direct `WebView2`）

- **Status**: `done`（`ci-windows` 実機で E2E GREEN。Run `#40473092476` で macOS / Linux / Windows 3/3）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/webview/{windows,win32,webview2_com,webview2_loader,windows_util}.zig`, `tests/webview/windows_smoke.zig`, `src/webview/mod.zig`, `build.zig`, `zigw`, `scripts/gen-webview2-com.py`, `.github/workflows/ci.yml`, `docs/tasks/M3-02-windows-webview2.md`, `docs/decisions/0007-*.md`
- **Upstream Reference**: `vendor/wry/src/webview2/`, [`sumatrapdfreader/sumatrapdf` `ext/webview2/WebView2Loader.cpp`](https://github.com/sumatrapdfreader/sumatrapdf/blob/master/ext/webview2/WebView2Loader.cpp)（MS 純正ローダのクリーンルーム再実装）, `vendor/tao/src/platform_impl/windows/`
- **Next Step**: `M3-03`（Overlay 埋め込み & C ABI）へ。再検証は
  `gh api "repos/umiturtle/Z-Ts/actions/runs?branch=arena/16ce0c2f-z-ts&per_page=1" --jq '.workflow_runs[0].id'`
  → `timeout 180 bash scripts/ci-logs.sh <run>` で
  ①`OK windows-wv2 checks=…` ②`OK windows-webview2-smoke single-exe=1 …` ③`3/3 GREEN` を確認する。

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
- [x] GitHub Actions `ci-windows` で実ウィンドウ + IPC 往復 + クリーン終了 E2E が通過
      （`tests/webview/windows_e2e.zig` を **standalone exe** として実行。runtime `155.0.4283.62` /
      `preflights=1` / `dpr=1` / `single-exe=1`）

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
- **`ci-windows` 実機で見つけて潰した 4 件（`M3-02` の山場）**:
  1. `AddWebResourceRequestedFilter` の第 3 引数 `ResourceContext` に `-1` を渡していた →
     **`0`（`COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL = 0`）**が正。範囲外の enum はブラウザ側を落とし、
     `exit code 3` + 追加出力なしで静かに死ぬ（`ZTS_WEBVIEW_TRACE=1` の `add_WebResourceRequested hr=0`
     まで出て、続くフィルタ行が出ないことで特定）。
  2. `CreateWebResourceResponse` のヘッダブロックに**末尾改行**を付けていた → WebView2 がブロック**全体**を
     捨てる。ページは描画されるが `Access-Control-Allow-Origin` / `Tauri-Response` が消え、cross-origin
     `fetch` が `TypeError: Failed to fetch`。`\n` 区切り・末尾改行なし（`wry` と同形）に修正。
  3. `cors_pairs` と `preflight_pairs` の両方に `Access-Control-Allow-Origin` → ヘッダ二重化で
     **プリフライトだけ**拒否され、本リクエストが送られない。プリフライト側から ACAO を外した。
  4. `findClientDll` が `path` を `dupe` したまま未解放（`SafeAllocator: leaked`）→ `load` で解放。
- **最終状態**: `./zigw build test --summary all` = **41/41 steps / 35/36 tests（skip 1 = Linux 上の
  レジストリテスト）**、`./zigw quick-test` PASS、`./zigw build -Dtarget=x86_64-windows-gnu` **4/4**、
  `python3 scripts/check-docs.py` 33 files OK、`ci-windows` は `OK windows-wv2 checks=…` を出力して成功。
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
| `e2e: window created` 直後に **exit code 3・追加出力なし** | `AddWebResourceRequestedFilter` に `COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL` を `-1` で渡していた | 正は **`0`**（`ALL = 0`、以降 `DOCUMENT = ALL + 1` …）。範囲外 enum はブラウザ側プロセスを落とす |
| ページは描画されるが `Tauri-Response` が JS から見えず cross-origin `fetch` が `TypeError: Failed to fetch` | `CreateWebResourceResponse` のヘッダブロック末尾に改行を付けた → WebView2 が**ブロック全体を破棄** | `name: value` を `\n` 区切り・**末尾改行なし**で渡す（`wry` と同形） |
| 単純リクエストは通るのにプリフライト後の本リクエストだけ飛ばない | `cors_pairs` と `preflight_pairs` で `Access-Control-Allow-Origin` が**二重** | プリフライト側から ACAO を外す（Chromium は multiple values を拒否し本リクエストを送らない） |
| `error(SafeAllocator): leaked … findClientDll` | `Found.path` を `dupe` したまま未解放 | `load` で `defer allocator.free(found.path)` |

### 3.2 Windows 実機でしか分からない部分をどう検証するか

- **型 / ABI / リンク**: Linux から `-target x86_64-windows-gnu` の `zig build` と、
  10 import lib を付けた `zig test --test-no-exec`（= リンクまで実施）で確認。CI では
  `ci-linux` の「クロスコンパイルゲート」が毎 push で単一 `.exe` を生成する。
- **振る舞い**: `ci-windows` の E2E（`tests/webview/windows_e2e.zig` を **standalone exe** として
  `zig build test` から実行。`OK windows-wv2 checks=… runtime=… preflights=… dpr=… single-exe=1`）と、
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

### 3.3 E2E の切り分けマーカー（次に壊れたときに最初に見る場所）

E2E はページ側で 3 本のプローブを回し、結果を `e2e: report={…}` に残す（`<status>|acao=<header>|tr=<header>`）。
`Access-Control-Allow-Origin` は **CORS-safelisted なレスポンスヘッダではない**ため、成功していても JS からは
読めない（`acao=-`）。判定に使ってよいのは `tr=ok`（= `Access-Control-Expose-Headers` 経由で見えている）と
`200|`（= CORS 検査を通過した）だけで、`acao` の有無でバグを判断しないこと。

| マーカー | 何を証明するか |
|---|---|
| `probeSame=200\|acao=*\|tr=ok` | ヘッダブロックが WebView2 のパーサを通り、独自ヘッダが JS に届く |
| `probeGet=200\|…` | cross-origin **単純リクエスト**（プリフライト無し）が CORS を通る |
| `probePlain=200\|…` | `text/plain` POST（CORS-safelisted）が deferral 経路で完了する |
| `request OPTIONS http://ipc.localhost/ping` の次に `request POST …/ping` | プリフライトが受理され本リクエストが発行された（片方だけなら ACAO 二重化を疑う） |
