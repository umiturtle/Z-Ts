# Task M3-01: macOS ネイティブバックエンド（Cocoa + WKWebView）

- **Status**: `in_progress`（実装完了・`ci-macos` 実測待ち）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/webview/{macos.zig,macos_shim.m,coords.zig,mod.zig,types.zig}`, `build.zig`, `zigw`, `.github/workflows/ci.yml`, `docs/tasks/M3-01-macos-wkwebview.md`, `docs/architecture/`, `docs/decisions/0006-*.md`
- **Upstream Reference**: `vendor/wry/src/webkitgtk/`（同型の `WKURLSchemeHandler` 相当）, `vendor/tao/src/platform_impl/macos/`, [`docs/architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md)
- **Next Step**: `gh run list --branch arena/16ce0c2f-z-ts` で `ci-macos` の結果確認 → 落ちたら `scripts/ci-logs.sh <run-id>` で ObjC コンパイルエラーを取得して修正 → GREEN 後に §5 を埋めて `done` 化。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `zts_webview` に macOS ネイティブバックエンドを追加し、Linux GTK と **完全に同一の
`zts_core.Host` / `zts_tauri` スタック** が Apple Silicon 実機（GitHub Actions `macos-latest`）で
動作することを E2E で証明する。

- [x] `src/webview/macos_shim.m`（Objective-C、`build.zig` の `addCSourceFile` で `-fobjc-arc` ビルド）:
      `NSApplication` / `NSWindow` / `WKWebView` / `WKURLSchemeHandler` / `WKScriptMessageHandler` を
      C ABI（`zts_macos_*` 31 関数）だけで公開
- [x] `src/webview/macos.zig`: `LinuxGtkBackend` と同一メソッド面の `MacOsBackend`
- [x] `Engine` に `.macos_wk` バリアントを追加（`.auto` は macOS 実機 → `MacOsBackend`、失敗時 `HeadlessMock`）
- [x] **CSS 左上原点 ⇔ Cocoa 左下原点の Y 軸自動変換**（`cssToCocoaY` / `cssToCocoaOrigin`、Linux 上でも単体テスト可能な純関数）
- [x] 透過タイトルバー（`titlebarAppearsTransparent` + `FullSizeContentView`）と `performWindowDragWithEvent:`
- [x] `stopURLSchemeTask:` 競合クラッシュ防止（シム内の生存トークン表 + Zig 側 `PendingTable` の二重世代チェック）
- [x] クロスオリジン `fetch` 対応（`Access-Control-Allow-Origin` / `Access-Control-Expose-Headers` の自動付与）
- [ ] Linux / macOS 双方でビルドが通る（Linux 側はローカル実測済み、macOS 側は `ci-macos` で確定）
- [ ] GitHub Actions `ci-macos`（arm64）で実ウィンドウ + IPC 往復 + クリーン終了 E2E が通過

> **Linux での挙動不変**: `enable_macos` は `target.result.os.tag == .macos` のときだけ true。
> Linux / Windows では `.m` を一切コンパイルせず、`Engine` の `.macos_wk` は `noreturn` 型として
> 存在するだけなので、既存バイナリのサイズ・リンク対象・テスト本数は変わらない。

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - タスクシェード作成（分散ロック宣言）→ commit `27b9c60`
  - `src/webview/macos_shim.m`（Objective-C シム・全 API 実装＋自己防御）
  - `src/webview/macos.zig`（`MacOsBackend` 全メソッド + arm64 E2E テスト）
  - `src/webview/coords.zig`（Y 軸変換 4 純関数 + 4 テスト）
  - `src/webview/mod.zig` の 30+ メソッドへ `.macos_wk` 分岐挿入、`has_native_macos`、`coords` 再公開
  - `build.zig`: `-Dmacos` オプション、`.m` + `-fobjc-arc`、`Cocoa` / `WebKit` / `Foundation`
  - `zigw`: `enable_macos=false` スタブ + `quick-test` に `zts_webview` 単体テスト追加
  - `.github/workflows/ci.yml`: `OK macos-wk` マーカー検証ステップ（無言スキップ防止）
  - `docs/decisions/0006-macos-appkit-wkwebview-backend.md`
- **検証済み（Linux コンテナ）**:
  - `./zigw quick-test` → webview 8/8（`coords` 4 含む）・tauri 9/9・wasm 3/3・ssg 4/4・root 7/7 全 pass
  - `./zigw build test` → `41/41 steps succeeded`、`examples/counter` → `15/15 steps` / `13/13 tests`
  - `./zigw build-obj -target aarch64-macos … -Mroot=src/webview/macos.zig` → exit 0（Zig 側の型検査は arm64 で通る）
- **未検証**: `macos_shim.m` は Linux に ObjC ツールチェーンが無いため **一度もコンパイルしていない**。
  macOS CI の E2E が初ビルドになる（`errors & dead ends` 参照）。

---

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
  `AGENTS.md` §2.3 の禁止事項に該当する。よって **`extern fn zts_macos_*` 31 関数**だけを境界にする。
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
独自ヘッダ）なので、WebKit は **本物の `OPTIONS` プリフライトをスキームハンドラへ送る**。
アプリ側ハンドラ（`zts_tauri`）は `OPTIONS` を実装していないため、ここを素通しすると
`403` になって全 IPC が壊れる。よって `ZtsAnswerPreflight()` が

```
204 No Content
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS
Access-Control-Allow-Headers: <Access-Control-Request-Headers をエコー、無ければ *>
Access-Control-Max-Age: 86400
```

を返して **Zig へ一切渡さない**。これにより `examples/counter` のアプリコードは
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

（`ci-macos` 実走後に記入）
