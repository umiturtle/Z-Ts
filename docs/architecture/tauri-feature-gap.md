# Tauri v2 機能ギャップ — 「実装すべきもの」の整理

> **内部資料です。** アプリ作者が読む必要はありません。上流 API の全体像は
> [`../reference/tauri-usage.md`](../reference/tauri-usage.md)、内部実装の解剖は
> [`../reference/tauri-internals.md`](../reference/tauri-internals.md)。
> English: [`tauri-feature-gap.en.md`](tauri-feature-gap.en.md)

このページは「上流 Tauri v2 が出来て、ziggurats がまだ出来ないこと」を洗い出し、
**このプロジェクトの理念に反さず、かつ実装する価値があるもの**だけを優先度付きで並べたものです。
単なる未実装一覧ではありません。§4 に「やらないもの」とその理由も明記します。

---

## 1. 判断基準（理念）

[`../decisions/0002-hybrid-architecture-proposal.md`](../decisions/0002-hybrid-architecture-proposal.md) と
`AGENTS.md` から、機能を採否するときの制約を再掲します。

| # | 理念 | 何が弾かれるか |
|---|---|---|
| 1 | **Pure Zig・`link_libc = false`**（`zts_tauri` は特に厳守） | C ランタイム共有ライブラリ必須の機能 |
| 2 | `@tauri-apps/api` v2 を**無改変**で使う | JS 側に独自 API を生やす案 |
| 3 | **ターゲット別分岐 0 行**（成果物差は comptime パラメータで表現） | `if (target)` を増やす実装 |
| 4 | `zts_webview` は `zts_foundation` に**のみ**依存 | WebView 層に上位モジュールを混ぜる設計 |
| 5 | 時刻・乱数・ファイル順に依存しない**決定性** | ビルドごとに変わる成果物 |
| 6 | 3 OS（Linux/macOS/Windows）で**同じ挙動** | 1 OS だけで動く便利機能 |
| 7 | 1 アプリ → 3 成果物、配布物は**単一バイナリ** | 実行時に外部 DLL/同梱ディレクトリを要求する機能 |
| 8 | 内部仕様と読者向け Doc を分離 | `///` に設計理由を書く／内部ページを学習動線に混ぜる |

「Tauri にあるから作る」は採用理由になりません。**同じことを Pure Zig で、3 OS 同じ形で
実現できるか**が唯一の採否基準です。

---

## 2. 現状の対応状況（ギャップを測る基準）

| 領域 | 実装済み | 置き場所 |
|---|---|---|
| IPC / コマンド | `invoke`、同期・非同期相当、`*Ctx` / `*State` 注入、`error{}` → TS Union | `src/rpc/` |
| 生バイナリ | `Bytes` / `application/octet-stream`、`RawJson`、`Channel<T>` | `src/rpc/codec.zig`, `src/tauri/channel.zig` |
| イベント | `emit` / `emit_to` / `listen` / `unlisten`、`EventTarget` | `src/tauri/event.zig` |
| リソース | `ResourceTable`（整数 rid、`plugin:resources|close`） | `src/tauri/resources.zig` |
| コアプラグイン | window / event / path / app / resources / menu / tray（7 つ、`withCorePlugins`） | `src/tauri/mod.zig` |
| ウィンドウ操作 | 約 40 コマンド（size/position/fullscreen/min/max/show/hide/close/is_*/set_* の主要どころ） | `src/tauri/window.zig` |
| 設定 | `tauri.conf.json` の主要キー、`capabilities/*.json` の Platform/Window/Origin 判定 | `src/tauri/{config_import,acl}.zig` |
| ACL | `Policy.allows` / `grantingCapability`、permission 識別子の glob 解決 | `src/tauri/acl.zig` |
| FS / Dialog / Clipboard | scoped FS（path 正規化 + シンボリック脱出防止）、3 OS ネイティブ | `src/tauri/{fs,dialog,clipboard}/` |
| メニュー / トレイ | 3 OS ネイティブ描画、アクセラレータ、スナップッシュット | `src/tauri/{menu,tray}/` |
| プロトコル | `tauri://` / `ipc://` / `asset://`、`convertFileSrc`、CSP、206 Range | `src/tauri/{protocol,js_bootstrap}.zig`, `src/core/assets.zig` |
| 3 成果物 | desktop / Live Preview / 静的 SSG | `src/{webview,bridge,wasm,ssg}/` |

---

## 3. 実装すべきもの（理念に反しない）

### P0 — 互換性・セキュリティの穴。次に手を付けるならここ

| # | Tauri v2 の機能 | ziggurats の現状 | なぜ理念に反しないか | 置き場所 | 検証 |
|---|---|---|---|---|---|
| 1 | `new WebviewWindow(label, opts)` / `WebviewWindow.getByLabel()`（**JS から 2 枚目のウィンドウを作る**） | `core.Host.createWindow()` と `WindowRegistry.registerWindow()` はあるが、**JS 側コマンドが無い**。`config_import` の `create: false` も未適用 | Host 契約が既に純 Zig で提供している。コマンドを 1 本足すだけ。OS 分岐は既存バックエンドが吸収する | `src/tauri/window.zig`（`create` コマンド）＋ `src/tauri/config_import.zig`（`create:false`） | `RecordingHost` で 2 ウィンドウ生成・label 解決・close まで |
| 2 | capability の **scope を実際に適用**（`{"identifier":"fs:allow-read","allow":[{"path":"$APPDATA/**"}]}`） | `Permission.scope_json` として JSON を保持するが `Policy.allows()` は**識別子しか見ていない**。`FsScope` は config 由来の scope だけを守る | JSON 解釈は `std.json` のみ。パス評価は `src/tauri/fs/scope.zig` の純 Zig 実装を再利用できる | `src/tauri/acl.zig` ＋ `src/rpc/ctx.zig`（`Ctx` に grant 済み scope を載せる） | scope 外パスが `error.Forbidden` になる表（ja/en 両方のガイドで説明） |
| 3 | `app.security.pattern: "isolation"`（暗号化 iframe による IPC 隔離） | `config_import.zig` が `pattern` と `dangerousDisableAssetCspModification` を **明示的に無視** | `std.crypto.aead.aes_gcm` は Pure Zig。鍵はビルド時生成（決定性のため固定 seed or 埋め込み） | `src/tauri/protocol.zig` ＋ `src/tauri/js_bootstrap.zig` | 隔離 iframe 外からの `invoke` が復号できず拒否される E2E |
| 4 | `gzip`  twins の**配信**（`Content-Encoding: gzip`） | `embedFrontend` が `gzip_entries` / `csp_hashes` を生成しているのに `zts_web.Assets` に受け皿が無く**死にデータ** | `AssetResponse` に `content_encoding` を 1 フィールド足すだけ。生成側は既に決定的 | `src/core/assets.zig`, `src/build_tools/assets.zig`, `src/tauri/protocol.zig` | `Accept-Encoding: gzip` で bytes が縮む／206 と共存する |
| 5 | `zts migrate`（既存 `src-tauri/` を ziggurats プロジェクトへ変換） | [`migrate-from-tauri.md`](../learn/ja/guides/migrate-from-tauri.md) は**手作業の手順書** only。CLI コマンドが無い | `config_import` が既に `tauri.conf.json` を読める。ファイル生成は `src/cli/template.zig` の延長。外部依存 0 | `src/cli/{args,migrate}.zig` | 上流 helloworld の `src-tauri/` を食わせて `zts build` が通る |


> **進捗（M5-19 / 2026-10-21）**: P0-2 と P0-3 は実装済み。残りは
> [タスク票](../tasks/M5-19-tauri-gap-implementation.md) のチェックポイントを参照してください。
> P0-2 は [権限ごとの scope](../learn/ja/concepts/security.md)、P0-3 は
> [isolation パターン](../learn/ja/concepts/security.md) に使い方があります。

### P1 — アプリ作者が「Tauri と同じ書き方」をするときに効く

| # | Tauri v2 の機能 | 現状 | 置き場所 |
|---|---|---|---|
| 6 | Webview 制御: `eval` / `reload` / `openDevtools` / `closeDevtools` / `isDevtoolsOpen` / `print` / `setZoom` / `clearAllBrowsingData` | `core.Host.evalJs` / `openDevtools` / `navigate` はあるが **`plugin:webview|*` コマンドが無い** | `src/tauri/window.zig` に webview コマンド群を追加 |
| 7 | ウィンドウイベント: `onResized` / `onMoved` / `onCloseRequested` / `onFocusChanged` / `onScaleChanged` / `onFileDrop` / `onThemeChanged` / `onPageLoad` / `onNavigation` | `EventBus` はあるが native → JS のイベント種別が限定的。`config_import` の `onNavigation` 相当も未配線 | `src/tauri/event.zig`, `src/webview/` |
| 8 | 残りの window setter: `setIcon` / `setTheme` / `setSkipTaskbar` / `setProgressBar` / `setBadgeCount` / `setCursorIcon` / `setCursorPosition` / `setCursorGrab` / `setCursorVisible` / `setIgnoreCursorEvents` / `center` / `requestUserAttention` / `setContentProtected` / `setVisibleOnAllWorkspaces` / `setShadow` / `setEffects` / `setBackgroundColor` | `WindowSpec` に `background_color` / `theme` などはあるが setter コマンドが無い | `src/tauri/window.zig`, `src/core/host.zig` |
| 9 | Monitor / DPI: `currentMonitor` / `primaryMonitor` / `availableMonitors` / `monitorFromPoint` / `cursorPosition` | `scale_factor` のみ | `src/webview/{types,linux,macos,windows}.zig` |
| 10 | `tauri.conf.json` の未適用フィールド: `center` / `maximized` / `skipTaskbar` / `titleBarStyle` / `hiddenTitle` / `userAgent` / `alwaysOnBottom` / `focus` / `dragDropEnabled` / `zoomHotkeysEnabled` / `windowEffects` / `contentProtected` / `tabbingIdentifier` | `WindowConfig` には**パース済み**だが `toWindowSpec()` が落としている（＝握りつぶし） | `src/tauri/config_import.zig`, `src/core/host.zig` |
| 11 | `plugin:event` の `once` / `emitTo` の webview 単位ターゲット | `emit_to` は window label 単位 | `src/tauri/event.zig` |
| 12 | `asset://` scope の実行時更新（`plugin:fs` の dialog grant を persist） | 初期 scope のみ。`persisted-scope` 相当が無い | `src/tauri/fs/scope.zig` |

### P2 — あると嬉しいが、P0/P1 の後

| # | 公式プラグイン | 実装難易度と理念適合 | 備考 |
|---|---|---|---|
| 13 | `opener` / `shell`（URL・ファイルを既定アプリで開く） | 低。`std.process.run` で `xdg-open` / `open` / `cmd /c start` を呼ぶだけ（CLI の `openBrowser` と同じ方式）。`link_libc` 不要 | 外部プロセスを spawn するので capability 必須 |
| 14 | `store`（JSON KV）/ `window-state`（位置・サイズの永続化）/ `log` / `os` / `process` / `cli` | 低〜中。すべて `std.fs` + `std.json` + `builtin` で完結 | 保存先は `PathState` の `$APPDATA` / `$APP_CONFIG` を流用 |
| 15 | `single-instance` / `deep-link` / `autostart` | 中。ロックファイル／`.desktop`／plist／レジストリ書き込み。3 OS で同じ API にまとめる設計が要る | OS 固有処理は既存の `native_*.zig` 境界に閉じ込める |
| 16 | `global-shortcut` / `notification` / `positioner` | 中〜高。OS のホットキー／通知 API への `extern fn` 追加 | `link_libc = false` を保つなら Pure Zig バインディング必須 |
| 17 | `.icns` / コード署名 / notarytool / MSI / NSIS / AppImage | 設計で**意図的に先送り**済み（[`packaging-and-bench.md`](packaging-and-bench.md) §5）。`hdiutil` 同様の外部ツール呼び出しに留まるなら P2 で可 | 「純 Zig で書く価値がない」判断を覆す理由は今のところ無い |

### 推奨順序

```text
P0-2 (ACL scope) → P0-3 (isolation) → P0-1 (multi-window) → P0-4 (gzip) → P0-5 (migrate)
   ↓ ここまでで「上流と同じ安全性・同じ書き方」になる
P1-6/7/8/9/10（window/webview の残り）→ P1-11/12
   ↓
P2（プラグイン群・配布形式）
```

**なぜ ACL scope が最初か**: 他の機能を増やすほど「許可したつもりが全コマンドが通る」危険が広がるため。
`Policy.allows()` が scope を見ない今の状態は、機能追加ではなく**先在する穴**です。
P0-4 は「生成しているのに使っていない」死にデータの解消なので、工数に対して効果が大きい。

---

## 4. やらないもの（理念に反する／スコープ外）

| 機能 | やらない理由 |
|---|---|
| `plugin-http` / `websocket` / `upload` / `updater` | TLS スタックが要る。Pure Zig の `std` に TLS クライアントは無く、OpenSSL / Rust `reqwest` を持ち込むと #1・#7 を壊す。将来 `zts_http` を**独立パッケージ**として作るなら別議論 |
| `sql` / `stronghold` | DB エンジン／暗号ライブラリの外部依存。#1 に反する |
| `biometric` / `nfc` / `haptics` / `geolocation` / `barcode-scanner` / `torch` | モバイル専用。このプロジェクトは 3 デスクトップ OS 対象（#6） |
| iOS / Android バックエンド | 同上 |
| Tokio 的な非同期ランタイムの移植 | `std.Io` で足りる。ランタイムを 1 つ増やすのは #1・#3 に反する |
| `@tauri-apps/api` への独自メソッド追加 | #2。足りない機能は**コマンド名を上流と揃えて** Zig 側に足す |
| `WebView2` を C++/COM で包む | 既に Pure Zig の `extern fn` バインディングがある（#4） |
| `if (windows) …` をアプリコードに増やす | #3。`RuntimeMode` / `Host` の comptime 差し替えで表現する |
| 内部設計ページを学習パスに混ぜる | #8。このページも `architecture/` に置き、読者向け索引からは 1 本だけ導線を張る |

---

## 5. 根拠

- 上流 API 一覧: [`../reference/tauri-usage.md`](../reference/tauri-usage.md) /
  [`../reference/tauri-internals.md`](../reference/tauri-internals.md)
- 公式プラグイン一覧: `github.com/tauri-apps/plugins-workspace` /
  `v2.tauri.app/plugin/`（2026-07 時点）
- 実装側: `src/tauri/{mod,window,event,path,app,resources,acl,config_import,protocol,channel}.zig`,
  `src/core/{host,assets}.zig`, `src/rpc/{ctx,codec}.zig`, `src/cli/args.zig`
- 理念: [`../decisions/0002-hybrid-architecture-proposal.md`](../decisions/0002-hybrid-architecture-proposal.md),
  [`../architecture/00-overview.md`](00-overview.md), `AGENTS.md`

> **数値を手で書かない**: 対応率や「何コマンド実装済み」は `zig build docs` の
> `api_decls` / `api_members` を正とすること。このページは**定性リスト**に徹します。
