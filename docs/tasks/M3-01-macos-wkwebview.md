# Task M3-01: macOS ネイティブバックエンド（Cocoa + WKWebView）

- **Status**: `done`（Run `#39932834622` で 3/3 OS GREEN・`ci-macos` ネイティブ E2E 実走）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/webview/{macos.zig,macos_shim.m,coords.zig,mod.zig,types.zig}`, `build.zig`, `zigw`, `.github/workflows/ci.yml`, `docs/tasks/M3-01-macos-wkwebview.md`, `docs/architecture/`, `docs/decisions/0006-*.md`
- **Upstream Reference**: `vendor/wry/src/webkitgtk/`（同型の `WKURLSchemeHandler` 相当）, `vendor/tao/src/platform_impl/macos/`, [`docs/architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md)
- **Next Step**: 完了。後続は `M3-02`（Windows `WebView2`）または `M4-02`（Scoped FS）。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `zts_webview` に macOS ネイティブバックエンドを追加し、Linux GTK と **完全に同一の
`zts_core.Host` / `zts_tauri` スタック** が Apple Silicon 実機（GitHub Actions `macos-latest`）で
動作することを E2E で証明する。

- [x] `src/webview/macos_shim.m`（Objective-C、`build.zig` の `addCSourceFile` で `-fobjc-arc` ビルド）:
      `NSApplication` / `NSWindow` / `WKWebView` / `WKURLSchemeHandler` / `WKScriptMessageHandler` を
      C ABI（`zts_macos_*` 33 関数）だけで公開
- [x] `src/webview/macos.zig`: `LinuxGtkBackend` と同一メソッド面の `MacOsBackend`
- [x] `Engine` に `.macos_wk` バリアントを追加（`.auto` は macOS 実機 → `MacOsBackend`、失敗時 `HeadlessMock`）
- [x] **CSS 左上原点 ⇔ Cocoa 左下原点の Y 軸自動変換**（`cssToCocoaY` / `cssToCocoaOrigin`、Linux 上でも単体テスト可能な純関数）
- [x] 透過タイトルバー（`titlebarAppearsTransparent` + `FullSizeContentView`）と `performWindowDragWithEvent:`
- [x] `stopURLSchemeTask:` 競合クラッシュ防止（シム内の生存トークン表 + Zig 側 `PendingTable` の二重世代チェック）
- [x] クロスオリジン `fetch` 対応（`Access-Control-Allow-Origin` / `Access-Control-Expose-Headers` の自動付与）
- [x] Linux / macOS 双方でビルドが通る（Linux ローカル `41/41 steps`、macOS `41/41 steps` / `96/96 tests`）
- [x] GitHub Actions `ci-macos`（arm64）で実ウィンドウ + IPC 往復 + クリーン終了 E2E が通過（Run `#39932834622`）

> **Linux での挙動不変**: `enable_macos` は `target.result.os.tag == .macos` のときだけ true。
> Linux / Windows では `.m` を一切コンパイルせず、`Engine` の `.macos_wk` は `noreturn` 型として
> 存在するだけなので、既存バイナリのサイズ・リンク対象・テスト本数は変わらない。

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **状態**: 実装・検証ともに完了（`done`）。本タスクで触ったのは `src/webview/` と
  `build.zig` / `zigw` / `.github/workflows/ci.yml` / `docs/` のみで、他レイヤーの API は不変。
- **完了したこと**:
  - `src/webview/macos_shim.m`（Objective-C シム・`zts_macos_*` 33 関数・約 1000 行）
  - `src/webview/macos.zig`（`MacOsBackend` 全メソッド + arm64 E2E テスト）
  - `src/webview/coords.zig`（Y 軸変換の純関数 4 つ + 4 テスト、全 OS で実行）
  - `src/webview/mod.zig` の 30+ メソッドへ `.macos_wk` 分岐挿入、`has_native_macos`、`coords` 再公開
  - `build.zig`: `-Dmacos` オプション、`.m` + `-fobjc-arc`、`Cocoa` / `WebKit` / `Foundation`、
    C99 ABI 静的ライブラリ側へのフレームワーク明示
  - `zigw`: `enable_macos=false` スタブ + `quick-test` に `zts_webview` 単体テスト追加
  - `.github/workflows/ci.yml`: `ci-macos` に `OK macos-wk` マーカー検証ステップ
  - `docs/decisions/0006-macos-appkit-wkwebview-backend.md`、`docs/architecture/` 更新
- **次に触る人へ**: macOS 固有コードは `macos_shim.m` と `coords.zig` に閉じている。
  Windows 実装（`M3-02`）は `src/webview/windows.zig` を追加し、`mod.zig` の union に
  `.windows_webview2` を足すだけで、同じ 30+ メソッド面を埋めればよい。

## 3. ローカル検証結果（`Linux x86_64`, Zig 0.17.0）

| コマンド | 結果 |
|---|---|
| `./zigw quick-test` | 全 pass（webview 8 / tauri 9 / wasm 3 / ssg 4 / root 7） |
| `./zigw build test --summary all` | `41/41 steps succeeded`（C99 ABI 厳格テスト含む） |
| `cd examples/counter && ../../zigw build test` | `15/15 steps succeeded; 13/13 tests passed` |
| `./zigw build-obj -target aarch64-macos -Mroot=src/webview/macos.zig` | exit 0（Zig 側のみ・リンクは macOS 必須） |

---

## 4. 設計判断・技術メモ・ハマりどころ

### 4.1 Objective-C は 1 ファイルに閉じ、境界は Flat C ABI だけ

- Zig 0.17 は `@cImport` 廃止。`addTranslateC(<Cocoa.h>)` は毎コールドビルド +50 秒級なので
  `AGENTS.md` §2.3 の禁止事項に該当する。よって **`extern fn zts_macos_*` 33 関数**だけを境界にする。
- `macos_shim.m` は `NSWindow` / `WKWebView` / `WKURLSchemeTask` を保持し、Zig には
  `(window_id: u64, token: u64, copied bytes)` しか渡さない。ARC は `-fobjc-arc`。

### 4.2 `Engine` の 30+ メソッドへ `.macos_wk` を挿入する際の型の罠

- `Engine` は `union(enum)`。`.macos_wk` の型は `if (has_native_macos) *MacOsBackend else noreturn`。
  非 macOS では `noreturn` になるため、各メソッドは
  `if (comptime has_native_macos) b.method(...) else unreachable` で畳む。
- これを忘れると Linux ビルドで `macos.zig` を参照してしまい、`.m` が無い環境でリンクエラーになる。

### 4.3 `step(.blocking)` は 1 秒上限付きの `nextEventMatchingMask:`

```objc
NSDate *until = block ? [NSDate dateWithTimeIntervalSinceNow:1.0] : [NSDate distantPast];
```

`distantFuture` にすると、万一 `postEvent:` の wakeup が届かなかった瞬間に **CI が 6 時間ハング**する。
1 秒上限ならアイドル時の起床は毎秒 1 回（CPU 計測不能レベル）で、`wakeup()` は今も即時復帰する。
E2E 側にも 12 秒の watchdogs（`requestQuit` を投げる）を置き、二重に脱出経路を確保している。

### 4.4 `stopURLSchemeTask:` 競合は 2 層で防ぐ

| 層 | 機構 |
|---|---|
| ObjC | `b.tasks[token]` を生存表にし、`stopURLSchemeTask:` で即削除 → 以後の完了は `nil` で no-op |
| Zig | `pending.PendingTable` の世代付き `RequestId`。窓クローズ / 再読み込みで世代が進み、遅延完了は破棄 |
| 例外 | `didReceiveResponse:` / `didFinish` は `@try/@catch`。WebKit が内部矛盾を投げてもプロセスは落ちない |

### 4.5 CORS preflight（`OPTIONS`）はシムが吸収する（**今回の新発見**）

`tauri://` → `ipc://` の `fetch` は非単純リクエスト（`application/json` / バイナリ body /
独自ヘッダ）なので、**WebKit が `OPTIONS` プリフライトをスキームハンドラへ送る可能性がある**。
アプリ側ハンドラ（`zts_tauri`）は `OPTIONS` を実装していないため、ここを素通しすると
`403` になって全 IPC が壊れる。よって `ZtsAnswerPreflight()` が

```
204 No Content
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS
Access-Control-Allow-Headers: <Access-Control-Request-Headers をエコー、無ければ *>
Access-Control-Max-Age: 86400
```

を返して **Zig へ一切渡さない**（実測: macOS 26 の WebKit はプリフライトを送らなかった＝
`preflights=0`。応答側 CORS ヘッダは必須で、こちらは §5.2 の失敗で証明された）。これにより `examples/counter` のアプリコードは
`OPTIONS` を意識する必要がない（Linux GTK 側は `webkit_security_manager_register_uri_scheme_as_cors_enabled`
が同じ役割を担うため、これまで表面化していなかった）。

### 4.6 `had_windows` フラグで「最後の 1 枚を閉じたらループ終了」を表現

`step()` が `windows.count == 0` で即 false を返すと、`createWindow` 前の最初の `step` で
ループが終わってしまう。`had_windows`（1 枚でも作られたか）を立ててから判定する。
E2E はこの挙動（`closeWindow` 後に `step(.poll) == false`）を明示的に検証している。

### 4.7 静的ライブラリ経由の C99 ABI テストにはフレームワークを明示

`verify_webview_c_abi` は `zts_webview_static`（`.a`）を `linkLibrary` する。静的アーカイブは
フレームワーク情報を運ばないため、macOS では `c_abi_mod` 側にも `Cocoa` / `WebKit` / `Foundation`
を明示的に付ける（モジュール経由のテストは `webview_mod` から伝播することを実験で確認済み）。

### 4.8 Zig 0.17 の C ABI 落とし穴（再発防止）

- `extern fn` の戻り値に **匿名 `struct{...}`** を書くと `comptime` でも強制評価されない。
  → `pub const CocoaFrame = extern struct { ... }` に切り出す。
- `_ = cx;` は「pointless discard」エラー。未使用引数は `null` を渡す（`&cx` を書いた時点で used 扱い）。
- `Handle(.window)` の無効判定は `== .invalid` ではなく **`.isValid()`**（`.invalid` は `@EnumLiteral` 扱いで型不一致）。
- `LogicalPx` は `.init(f64)`（`.px(...)` は存在しない）。

### 4.9 CI に「無言スキップ検出」を入れる

`ci-macos` の 2 ステップ目で `OK macos-wk checks=10 …` を `grep` し、無ければ job を落とす。
`DisplayUnavailable` で `SkipZigTest` した場合もここで確実に検出される。

---

## 5. CI 検証結果（GitHub Actions）

### 5.1 最終 Run `#39932834622` — 3/3 OS ALL GREEN

| ジョブ | 結果 | 実測サマリ |
|---|---|---|
| Linux (Ubuntu 24.04 + Xvfb + WebKit2GTK 4.1) | ✅ success | `41/41 steps`, `96/96 tests`（Debug + ReleaseFast の 2 回） |
| macOS (arm64 + WKWebView) | ✅ success | `41/41 steps`, `96/96 tests` + **`OK macos-wk checks=10 binary=98304 sum=42 screen=1024x674 preflights=0`** |
| Windows (x86_64 + WebView2) | ✅ success | `41/41 steps`, `95/95 tests` |

macOS ジョブのステップ（すべて OK）:

```
Build & test on macOS                                            -> 41/41 steps, 96/96 tests + OK macos-wk ...
Verify the native Cocoa + WKWebView E2E actually ran (M3-01 gate) -> OK macos-wk checks=10 ...
Build & E2E-test the M2-02 counter showcase (desktop/live/SSG)    -> OK desktop / OK live / OK counter-ssg
```

- `examples/counter`（無改造のアプリコード）が macOS でも `15/15 steps` / `13/13 tests`、
  `OK live checks=43` / `OK ssg checks=28` / `OK counter-ssg pages=2 wasm=187360B` と
  **Linux と完全一致**。ネイティブ WKWebView へのリンクを含めて単一バイナリが生成できている。
- `preflights=0`: macOS 26 の WebKit はカスタムスキーム間 `fetch` で `OPTIONS` プリフライトを
  送出しなかった（応答の CORS ヘッダ検査のみ）。シムのプリフライト応答は将来の WebKit /
  実クロスオリジン要求に対する防御として残し、件数を毎回ログに出す。

### 5.2 途中 Run `#39932294008` — 初回 macOS 実ビルドで見つかった 1 件

`macos_shim.m` はこの Run が**初のコンパイル**で、Objective-C は一発でビルドが通り、
E2E も `96 テスト中 95 pass`（ウィンドウ生成・UserScript 注入・96 KiB バイナリ往復・
ワーカースレッドからの JSON 完了まで成功）。唯一の失敗は

```
expected: "*"   found: ""
src/webview/macos.zig:862: try testing.expectEqualStrings("*", parsed.value.cors orelse "");
```

WKWebView は **safelist 外のレスポンスヘッダを `fetch()` から隠す**ため、
`Access-Control-Allow-Origin` を `Access-Control-Expose-Headers` に列挙して解決した（§4.5）。
同時に、Linux ジョブへ誤って挿入していた macOS マーカー検証ステップを `ci-macos` へ移動した。
