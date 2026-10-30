# ADR 0007: Win32 + Direct `WebView2` による Windows ネイティブバックエンド

- **日付**: 2026-10-23
- **ステータス**: 採択（Accepted）
- **関連タスク**: [`M3-02`](../tasks/M3-02-windows-webview2.md)

---

## 1. 背景

`zts_webview` は M1-06 で Linux GTK3 + WebKit2GTK 4.1、M3-01 で macOS Cocoa + WKWebView の
ネイティブバックエンドを持った（[`ADR-0006`](0006-macos-appkit-wkwebview-backend.md)）。残るは Windows だが、
macOS 以上に「素直な Zig」から遠い要素が 3 つある：

1. **`WebView2Loader.dll` が SDK の必須同梱物**とされている。Z-Ts の「追加配布物ゼロ」という
   ポリシー（`include/` と 1 つの `.exe` 以外を配らない）に反する。
2. **`ICoreWebView2*` は COM**。Zig 0.17 は `@cImport` を廃止しており、296 個の
   `MIDL_INTERFACE` を持つ 2.9 MB の `WebView2.h` を `addTranslateC` で取り込むと
   コールドビルドが数十秒伸びる（[`ADR-0001`](0001-zig-017-and-sharded-agent-workflow.md)）。
3. **カスタム URI スキームが存在しない**（`registerScheme` 相当の API がない）。Tauri の
   `tauri://` / `ipc://` / `asset://` は `http://<proto>.localhost/` に読み替えて
   `WebResourceRequested` で横取りするしかない。さらに、そのコールバックは
   **メインスレッド STA で `ICoreWebView2Deferral` を保持したまま**非同期完了させる必要がある。

---

## 2. 決定事項

### 2.1 `WebView2Loader.dll` を同梱せず、`EmbeddedBrowserWebView.dll` を直接ロードする

`src/webview/webview2_loader.zig` は Microsoft 純正ローダ（`WebView2Loader.cpp`）と同じ探索順を
Pure Zig で再実装する：

| 順序 | キー / 環境変数 | 用途 |
|---|---|---|
| 1 | `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` | 固定バージョン配備（`RUNTIME_TYPE_FIXED`） |
| 2 | `HKCU` → `HKLM\SOFTWARE\Microsoft\EdgeUpdate\ClientState\{GUID}` → `EBWebView` | インストーラが書く正規パス |
| 3 | `HKCU` → `HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\{GUID}` → `location` + `pv` | 旧レイアウト |
| 4 | Stable → Beta → Dev → Canary のフォールバック | 開発機 |

クライアント DLL は `<location>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`（`x64` / `x86` / `arm64`）。
`LoadLibraryExW(..., LOAD_WITH_ALTERED_SEARCH_PATH)` で読み、エクスポート
`CreateWebViewEnvironmentWithOptionsInternal(fromClientDll=TRUE, runtimeType, userDataFolder, options, handler)`
を `GetProcAddress` する。アンロードは Microsoft 純正と同じく
**`DllCanUnloadNow` が存在するときだけ** `FreeLibrary`。

- チャネル GUID・パッケージファミリ・最小バージョン（`86.0.616.0`）・アーキテクチャ名は
  `src/webview/windows_util.zig` に外出しし、**Win32 非依存の単体テスト**（9 本）で全 OS CI が検証する。
- これにより、配布物は **1 つの `.exe` だけ**。`zig-out/bin/` に DLL が現れたら CI が失敗する。

### 2.2 COM vtable はビルド時生成ではなく「生成スクリプト + コミット済み `.zig`」

`scripts/gen-webview2-com.py` が `WebView2.h` の宣言順を正規表現で読み、
`src/webview/webview2_com.zig`（16 インターフェース、505 行）を出力する。

- **生成物はコミットする**（ビルド時に Python も SDK も要求しない＝コールドスタート 0 秒）。
- 手書き部分は「どの引数を型付きにするか」の `TYPED` 辞書だけ。未使用メソッドは
  `?*const anyopaque` に潰し、使用メソッドだけ正確な `callconv(.winapi)` シグネチャを持つ。
- スロット数は `comptime` で断言（`ICoreWebView2` = 61 スロット、`ICoreWebView2Controller` = 26 など）。
- IID は `comptime guid()` でパースし、GUID パース自体のテストが **Linux / macOS CI でも走る**
  （`zts_webview` が `webview2_com` を無条件に参照するため）。

```
ICoreWebView2Environment  8   ICoreWebView2                   61
ICoreWebView2Controller  26   ICoreWebView2Settings           21
ICoreWebView2Deferral     4   ICoreWebView2WebResourceRequest  5
… + 5 種のイベントハンドラ / 完了ハンドラ（各 4 スロット）
```

### 2.3 `tauri://` は `http://tauri.localhost` に正規化し、既存の `ProtocolRouter` を再利用する

`js_bootstrap.zig` は既に Windows 向けに `convertFileSrc()` が
`http://<proto>.localhost/<pct>` を返す分岐を持っている。したがって Zig 側は

- `AddWebResourceRequestedFilter("http://tauri.localhost/*")` / `http://ipc.localhost/*` / `http://asset.localhost/*`
- `get_Uri()` を `windows_util.classify()` で判定（`tauri://localhost/...` の綴りも受理）
- `SchemeRequest.uri` には **`http://` 形式のまま**渡す

だけでよく、`zts_tauri.ProtocolRouter` も `examples/counter` も **1 行も変えない**。
`navigate()` に渡された `tauri://` URL は `windows_util.toWebView2Url()` で書き換える
（`https://…` など外部 URL はバイト単位でそのまま通す）。

### 2.4 `ICoreWebView2Deferral` の所有権はメインスレッドの表に閉じ込める

```
WebResourceRequested (STA)
   ├─ get_Deferral() → AddRef(args) → deferred[token] = { args, deferral }
   ├─ リクエストをコピー（URI / method / headers / IStream 本文）して Zig ハンドラへ
   │     └─ 別スレッドで completeRequest() → CompletionQueue.push()（値コピー）
   └─ step() の drainCompletions()
         ├─ PendingTable.take(request_id)  ← 世代チェックで「キャンセル済み」を弾く
         ├─ env.CreateWebResourceResponse(SHCreateMemStream(body), …)
         ├─ args.put_Response(r) → deferral.Complete() → Release
         └─ ヘッダには CORS（`Access-Control-Allow-Origin: *` /
            `Access-Control-Expose-Headers: Tauri-Response,…`）を必ず付与
```

- `OPTIONS` は Zig まで届けず、その場で **204 + `Access-Control-Allow-Headers: *`** を返す
  （macOS シムと同じポリシー）。
- 生の COM ポインタがワーカースレッドへ渡ることは一度もない。ワーカーが見るのは
  `(backend, token)` とバイト列だけ。

### 2.5 ステップ駆動イベントループは `MsgWaitForMultipleObjectsEx` で実装する

`step(.blocking)` は自動リセットイベントを 1 秒上限で待ち、`PeekMessage` → `DispatchMessageW`
で STA のメッセージを回す。`wakeup()` は `SetEvent`。したがって

- 呼び出し側の `defer` スコープ（`std.testing.allocator` のリーク検出）が切れない、
- 60/120 fps のゲームループは `.poll` でそのまま統合できる、
- `createWindow()` は即座に `WindowId` を返し、WebView2 コントローラの完了（非同期）後に
  queued の UserScript / URL / HTML を適用する、

という Linux / macOS と同じ契約を保つ。

### 2.6 Per-Monitor DPI Aware v2 は `windows_util` の純関数 + `WM_DPICHANGED` で扱う

`GetDpiForWindow`（user32）を一次ソースにし、`BASE_DPI = 96` で
`logicalToPhysical` / `physicalToLogical` を適用する。`WM_DPICHANGED` では
推奨 RECT をそのまま採用し、`put_Bounds` を再計算する。DPI スケーリングの算術は
`windows_util.zig` の単体テスト（100/125/150/200 %、負座標）で Linux CI でも検証される。

### 2.7 `WebResourceRequested` の 3 つの実機契約（CI でしか分からなかった点）

いずれも「コンパイルは通る・`put_Response` の `HRESULT` は `S_OK`・しかしブラウザは動かない」という
無言の失敗になるため、コードと単体テストで固定する。

1. **`ResourceContext` は `0`。** `AddWebResourceRequestedFilter(pattern, COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)`
   の `ALL` は `0`（`DOCUMENT = ALL + 1` …）。`-1` を渡すと範囲外の enum としてブラウザ側プロセスが落ち、
   ホストは `exit code 3` で無言終了する。`windows.zig` の `resource_context_all` を参照。
2. **ヘッダブロックは `name: value` を `\n` で区切り、末尾に改行を付けない。**
   `CreateWebResourceResponse(stream, status, reason, headers, …)` の `headers` を末尾改行で終えると
   WebView2 は**ブロック全体**を捨てる。ナビゲーションは成功するためページは描画され、
   `Access-Control-Allow-Origin` / `Tauri-Response` だけが静かに消える（→ cross-origin `fetch` が
   `TypeError: Failed to fetch`）。`appendHeaderLine` とその単体テストが契約。
3. **`Access-Control-Allow-Origin` は 1 レスポンスに 1 個。** プリフライト応答で
   `cors_pairs` と `preflight_pairs` の両方が ACAO を持つと二重になり、Chromium は
   `multiple values` を理由にプリフライトを拒否して本リクエストを送らない（単純リクエストは通るので
   原因が見えにくい）。`preflight_pairs` は「`cors_pairs` に無いものだけ」を持つ。

なお `Access-Control-Allow-Origin` は CORS-safelisted なレスポンスヘッダではないため、
**成功していてもページ JS からは読めない**。E2E は `Tauri-Response`（`Access-Control-Expose-Headers`
経由）で CORS 通過を判定している。

---

## 3. 却下した代替案

| 代替案 | 却下理由 |
|---|---|
| `WebView2Loader.dll` を同梱 | 追加配布物が増え、バージョン不整合（SDK と実行時ランタイム）で起動失敗する典型パターンを抱える |
| `addTranslateC(WebView2.h)` | `@cImport` 廃止後の Zig 0.17 でコールドビルド +数十秒。2.9 MB のヘッダを毎回パースする |
| `wry` / C++ シムの再利用 | Rust / C++ ツールチェーンが必須になり「Pure Zig・単一バイナリ」の前提が崩れる |
| `tao` 相当のウィンドウ管理を丸ごと移植 | 不要。`CreateWindowExW` + `WndProc` で足りる範囲だけを `win32.zig` に書く |
| `webview2-sys` 相当の自動バインディングをビルド時に生成 | Python / SDK がビルド環境に必要になる。生成物コミットで 0 秒を選ぶ |

---

## 4. 結果とトレードオフ

**実測値（`ci-windows`, `windows-latest`, WebView2 Evergreen `155.0.4283.62`）**

| 項目 | 値 |
|---|---|
| E2E マーカー | `OK windows-wv2 checks=19 runtime=155.0.4283.62 preflights=1 dpr=1.00 single-exe=1` |
| スモーク | `OK windows-webview2-smoke single-exe=1 report={"dpr":1,"w":520,"h":320,"ua":true}`（インストール済み `.exe` を直接起動） |
| 単一バイナリ | `zig-out/bin/zts_webview2_smoke.exe` 2.5 MB / DLL 0 件（`WebView2Loader.dll` 非同梱） |
| テスト | `ci-windows` 43/43 steps・112/112 tests + E2E、Linux ホスト `./zigw build test --summary all` 41/41 steps / 35/36 tests（skip 1 = レジストリ読み取り） |
| クロスビルド | Linux → `./zigw build -Dtarget=x86_64-windows-gnu` **4/4** |

**得られたもの**
- Windows でも `zts_core.Host` / `zts_tauri` / `DesktopRuntime` / `examples/counter` がゼロ変更で動く
  （`.windows_webview2` バリアントは `Engine` の中だけ）。
- 配布物は単一 `.exe`。`WebView2Loader.dll` 参照はバイナリの文字列検査でも 0 件。
- Linux ホストから `./zigw build -Dtarget=x86_64-windows-gnu` が通るため、Windows ランナーが
  無い環境（Arena サンドボックス）でも型・ABI・リンクの破壊を即検出できる。
- `windows_util`（8 テスト）+ `win32`（3）+ `webview2_com` の GUID テスト + `windows.zig` の純ロジック
  4 テストが **全 OS の CI** で走る（ヘッダブロックとプリフライトの契約もここで回帰検出）。

**受け入れたコスト**
- `AddScriptToExecuteOnDocumentCreated` には `null` ではなく **no-op ハンドラ**を渡す
  （`null` は WebView2 が `E_POINTER` 相当で拒否し、注入が静かに失敗するため）。
  スクリプト注入の成否は「その後ページが動くこと」でしか確認できない。
- `CreateWebResourceResponse` は本文を `SHCreateMemStream` に載せるため、
  **64 MiB 超の単一レスポンスはメモリに載る**（macOS シムと同じ制約）。
- `WebView2` ランタイムが無い環境では `error.DisplayUnavailable` を返し、`.auto` は
  `HeadlessMock` にフォールバックする。CI は Evergreen を導入したうえで
  `OK windows-wv2 checks=` の痕跡検証を行い、無言スキップを防いでいる（チェック数はゲートしない）。
- COM ハンドラは `refs` を非アトミックに増減している。WebView2 は全コールバックを
  STA（単一スレッド）で配送するため意図的にそうしており、他スレッドから `AddRef` する
  拡張（`M3-03` の埋め込みモード等）を入れる際は `Interlocked` 化が必要。
- E2E は standalone exe（`zig build test` の `run` ステップ）。Zig のテストランナーに
  COM/ブラウザコールバックを同居させるとクラッシュが「1 crash」に丸められて原因が消えるため、
  意図的にテストブロックへ戻さない。
