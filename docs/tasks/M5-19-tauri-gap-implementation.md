# Task M5-19: Tauri 機能ギャップを P0→P1→P2 の順に実装する

- **Status**: `in_progress`
- **Branch**: `arena/e54ae0fb-z-ts`（main `63e9073` 起点 = PR #18 マージ後）
- **Scope**: `src/tauri/{acl,config_import,protocol,js_bootstrap,window,event,app,path,fs/scope}.zig`,
  `src/core/{host,assets}.zig`, `src/rpc/ctx.zig`, `src/bridge/server.zig`,
  `src/build_tools/assets.zig`, `src/cli/{args,migrate}.zig`, `src/bundler/*`, `src/tauri/plugins/`（新規）,
  `docs/learn/{ja,en}/concepts/security.md`, `docs/learn/{ja,en}/guides/plugins.md`,
  `docs/reference/cli{,.en}.md`, `docs/architecture/tauri-feature-gap{,.en}.md`,
  `docs/INDEX{,.en}.md`, `scripts/check-docs.py`, `scripts/doc-sync.json`
- **Upstream Reference**: [`../architecture/tauri-feature-gap.md`](../architecture/tauri-feature-gap.md)
  （P0/P1/P2 の定義と理念の判断基準）／ [`../reference/tauri-usage.md`](../reference/tauri-usage.md)
- **Next Step**: P0-2（capability scope の実適用）から着手。順序を守り、各項目で
  `./zigw quick-test`（または対象モジュールのテスト）を通してから次へ進む。

---

## 1. 依頼と完了条件

> 「**P0-2 → P0-3 → P0-1 → P0-4 → P0-5 → P1 → P2** を順に実装して」

- [x] **P0-2** capability の scope を `Policy` → `rpc.Ctx` → `plugin:fs` で実適用する
- [x] **P0-3** `app.security.pattern: "isolation"`（暗号化 iframe）
- [x] **P0-1** JS からの `WebviewWindow` 生成（複数ウィンドウ）
- [x] **P0-4** 生成済み `gzip_entries` を実際に配信する
- [x] **P0-5** `zts migrate`
- [x] **P1** webview コマンド / ウィンドウイベント / 残り setter / Monitor・DPI / 未適用 config フィールド / `once` / `asset://` scope の実行時更新
- [x] **P2** 公式プラグイン群・配布形式のうち理念に反しないもの
- [x] 各項目に単体テスト（`std.testing.allocator`、正常系・異常系・境界値）
- [x] 日英の読者向け Doc を更新、ルール 11（索引網羅）と規約 13（同期台帳）を維持
- [x] `./zigw quick-test` / `build test` / `doctest` / `fmt --check` / `docs-check` / 3 OS CI が緑
- [ ] PR は 1 本だけ

## 2. 実装順序の理由（再掲）

| 順 | ID | 内容 | なぜこの位置か |
|---|---|---|---|
| 1 | P0-2 | ACL scope | 他の機能を増やすほど「許可したつもりが全コマンドが通る」危険が広がる。**先在する穴** |
| 2 | P0-3 | isolation | セキュリティ境界。AES-GCM は Pure Zig で用意できる |
| 3 | P0-1 | multi-window | ここまでで安全性が固まってからウィンドウを増やす |
| 4 | P0-4 | gzip 配信 | 生成済みの死にデータを解消。工数小・効果大 |
| 5 | P0-5 | `zts migrate` | 移行導線 |
| 6 | P1 | window/webview の残り | 互換性の幅を広げる |
| 7 | P2 | プラグイン群 | 最後。外部依存を持ち込まない範囲のみ |

## 3. 設計メモ（進捗とともに更新）

### 3.1 理念（変えてはいけない制約）

1. Pure Zig、`link_libc = false`（`zts_tauri` 厳守）
2. `@tauri-apps/api` v2 無改変 → **上流と同じコマンド名**を足す
3. ターゲット別分岐 0 行（成果物差は comptime `RuntimeMode` / `Host` で表現）
4. `zts_webview` は `zts_foundation` のみ依存
5. 決定性（時刻・乱数・ファイル順に依存しない）
6. 3 OS 同一挙動（未対応は `error.Unavailable` で fail-closed、黙って成功しない）
7. 単一バイナリ・内部と読者 Doc の分離

### 3.2 共通実装パターン

- 新しい OS 機能は **`core.Host` の vtable に 1 メソッド追加 → `RecordingHost`（Mock）で
  テスト → 3 OS の `native_*.zig` で実装／`Unavailable`**。アプリコードに `if (builtin.os.tag)`
  を書かない。
- 新しいコマンドは `Commands` struct に `pub fn` を足すだけ（`Schema` が comptime で
  `invoke("…")` に登録）。引数に状態があるときは `pub const RpcState = State;` が必要。
- 新プラグインは `src/tauri/<name>/` に独立モジュールを作り、`CorePluginsSchema` に
  アルファベット順で 1 行足す。テストは `src/tauri/<name>/mod.zig` に置く。
- Doc は日英 2 言語。ルール 11 が `docs/INDEX{,.en}.md` の網羅を検査する。

## 4. 進捗チェックポイント

- **完了**: 現状復元・タスク票／分散ロック、**P0-2**。
  - `rpc.Ctx.acl_scope_json`（opaque JSON、`zts_rpc` は型を知らない）
  - `Policy.scopeJsonFor()` が「そのコマンドを許可した権限」の scope だけを収集。
    scope 無しの権限が 1 つでもあれば制限なし（Tauri `CommandScope` と同じ）
  - `Policy.authorizeCtx()` が `authorize_ctx_fn` の `*Ctx`（mutable）で付与
  - `scopeAllowsPath` / `scopeAllowsUrl`: `deny` 優先、`allow` は union、`globMatch` を再利用
  - `plugin:fs|*` の全 19 経路を `resolveScoped()` に集約（既存 `FsScope` と併用）
  - テスト: `quick-test` の tauri モジュール 67 件（+3: scope allow / deny / unscoped と
    fs の E2E）。日英 `concepts/security.md` にルール表を追加
- **完了**: **P0-3** `app.security.pattern: "isolation"`。
  - `src/tauri/isolation.zig`: `std.crypto.aead.aes_gcm.Aes256Gcm`（Pure Zig）で
    `seal` / `open`。AAD をバージョン固定、nonce 12 byte / tag 16 byte、`keyFor()` は
    `keyHex` 優先・`identifier` からの決定論的導出
  - `config_import.Security.pattern`: 文字列 / `{use,options}` 両対応、`dir` と `keyHex`、
    未知の `use` は診断付き `InvalidConfig`（黙って平文に落とさない）
  - `js_bootstrap`: `ISOKEY` と `__TAURI_ISOLATION_HOOK__`、WebCrypto で本文ごと暗号化。
    平文フォールバックを **禁止**（`IsolationTransportUnavailable`）
  - `protocol`: `isolation_key` が設定されていたら `ipc://` 本文を復号してから dispatch。
    平文 / 別鍵 / 改ざんは 403 `ForbiddenIsolationEnvelope`。`isolation://localhost/` は
    埋め込みアセットの `/isolation/` を配信（Windows の `.localhost` 形も対応）
  - `app_runtime.DesktopConfig.isolation_key` で実アプリに配線、スキーム登録と
    `openWindow()` のブートストラップへ鍵を注入
  - テスト: tauri 73 件（+6: 暗号ラウンドトリップ / 改ざん / 鍵決定性、config、
    protocol E2E、bootstrap）。`fmt --check` / `check-docs` / `docs-check` / `build test` 緑
  - 日英 `concepts/security.md` に設定例・ルール表・限界を追加、gap レポートに進捗注記
- **完了**: **P0-1** JS からの `WebviewWindow` 生成（複数ウィンドウ）。
  - 上流 `@tauri-apps/api@2.9.0` の実コマンドを確認:
    `plugin:webview|create_webview_window` / `plugin:window|create` /
    `plugin:webview|create_webview` / `plugin:webview|get_all_webviews`（`[{label,windowLabel}]`）
  - `src/tauri/webview.zig` 新規。`WebviewRegistry` は「1 ウィンドウ = 1 主 WebView」を
    `WindowRegistry` から導出し、子 WebView だけを保持。`new Webview()` は既存の
    `Host.evalJs` で親ウィンドウに `<iframe>` を生成（OS 分岐 0 行・3 OS 同一挙動）
  - `window.zig` に `RawJson` ベースの `specFromOptions()`（未実装オプションは無視）、
    `isValidLabel()` / `normalizeUrl()`、`openWindow()` ファクトリ、
    `plugin:window|create` を追加。`DesktopRuntime` がファクトリを配線し、
    JS 生成ウィンドウにも label 専用ブートストラップを注入
  - `acl.zig`: `webview` を core plugin に追加、作成コマンドは `core:default` を
    **除外**して明示 permission を要求（上流 `core:webview:allow-create-webview-window` 準拠）
  - テスト: tauri 77 件（+4）、root 8 件（+1）。正常／異常／境界（label 長・重複・
    `javascript:` URL・Host 無し・Runtime 経由の E2E）
  - 日英 `guides/plugins.md` にコマンド表・設定例・capability 注意を追加、gap レポート更新
- **完了**: **P0-4** 生成済み `gzip_entries` の配信。
  - `web.Assets.gzip_entries`（`entries` と index 対応）、`ResolveOptions.accept_encoding`、
    `AssetResponse.content_encoding` / `vary_accept_encoding`、`pub fn acceptsGzip()`
    （`q=0` と `*` を RFC 9110 準拠で解釈）
  - 双子が元より小さい時だけ採用。`<head>` 注入後・`Range` 付き・`gzip;q=0` は非圧縮。
    `Range` は常に非圧縮表現の 206。`Vary: Accept-Encoding` を付与
  - `renderManifest` が `assets: web.Assets = .{ .entries = entries, .gzip_entries = gzip_entries }`
    を出力 → **死にデータを解消**
  - `protocol.RoutedResponse` と `bridge.BridgeServer` が `Content-Encoding` / `Vary` を送出。
    デスクトップ 3 OS と Live Preview で同一経路
  - テスト: `zts_web` 2 本、`zts_tauri` 1 本、`embedded_consumer` 1 本、
    manifest 検査 1  assertions 追加。`build test` 210/210 緑
  - 日英 `guides/static-site.md` に交渉表、`decisions/0017` の残課題を解消済みに更新
- **完了**: **P0-5** `zts migrate`。
  - `src/cli/migrate.zig` 新規（pure、`zts_*` import 無し）: `tauri.conf.json` の必要項目を
    `std.json.Value` で読み、決定論的な `Plan`（生成ファイル・警告・日英 `MIGRATION.md`）を返す
  - `src/cli/args.zig` に `migrate` コマンド（`--dir` / `--name` / `--zts-path` / `--force` /
    `--dry-run`）、`src/cli/main.zig` に IO だけの `runMigrate()`
  - コピー: `tauri.conf.json` → `src-tauri/`、frontendDist → `web/`、capabilities、icons、
    `zts init` テンプレート。`web/index.html` は upsert で移行物が優先。unsafe path は拒否
  - Rust `#[tauri::command]` は翻訳せず `MIGRATION.md` に列挙（安全な自動変換が無いため）
  - 元プロジェクトは変更せず隣に新規生成。`--dry-run` は 1 ファイルも書かない
  - テスト: CLI 62 件（+5: 引数・config 正常/異常・パス安全性・plan 決定性）。
    fixture で `zts migrate --dry-run` / 実生成・fingerprint patch まで E2E 確認
  - 日英 `guides/migrate-from-tauri.md` に §0、`reference/cli{,.en}.md` にコマンド節を追加
- **完了**: **P1**（7 項目すべて）。
  - #6 `src/tauri/webview.zig` に `eval` / `reload` / `print` / `set_zoom` /
    `open_devtools` / `close_devtools` / `is_devtools_open` / `internal_toggle_devtools` /
    `clear_all_browsing_data`。すべて既存 `Host.evalJs` / `openDevtools` 経由で OS 分岐 0 行
  - #7 `WindowRegistry.events` と `emitWindowEvent()`。17 個の既存 setter が
    `tauri://resize` / `move` / `focus` / `close-requested` 等を emit。許可リスト付き
    `plugin:window|emit_window_event` で `file-drop` / `page-load` / `navigation` も配送
  - #8 `WindowExtras`（スカラ値のみ・リーク不能）＋ 17 本の残り setter。不正な enum /
    範囲外の値は 400
  - #9 `src/tauri/monitor.zig`（`MonitorRegistry` + provider vtable）。既定は決定論的
    1920×1080 @1.0、実ディスプレイは差し替え。`window.Commands` に 5 コマンド
  - #10 `core.WindowSpec` / `webview.WindowConfig` に 14 フィールド追加し、
    `config_import.toWindowSpec()` で**破棄を解消**。`windowEffects` は JSON のまま保持
  - #11 `plugin:event|once`（初回配送で自動解除）と `emitTo({kind:"Webview"})` の
    親ウィンドウ解決（`CorePluginStates` が配線）
  - #12 `src/tauri/asset_scope.zig`（mutex 付き grant + JSON 永続化 + restore）。
    `ProtocolConfig.asset_scope` と `FsState.withAssetScope()` で共有し、
    `plugin:fs|asset_scope_*` 4 コマンドから更新
  - `acl.zig`: `eval` / browsing data / イベント偽装 / scope 変更は `*_default` から除外し
    明示 permission を要求
  - テスト: tauri 86 件（+9）、`build test` 緑。日英 `guides/plugins.md` に §6 を追加
- **完了**: **P2**。
  - `src/tauri/plugins.zig` 新規（**`CorePluginsSchema` に入れない**独立モジュール群）:
    `store` / `log` / `os` / `process` / `cli` / `window-state` / `opener` /
    `single-instance` / `notification` / `positioner` の 10 名前空間を 1 つの `PluginState` で共有
  - `opener` は provider 方式（未設定なら `Unsupported`）、`notification` はアプリ内
    `zts:event`＋リング、`single-instance` は排他ロックファイル、いずれも 3 OS 同一挙動
  - `os` は `builtin` のみ。カーネル版数・ロケールは読まない（パリティ維持）。
    `process|exit` は `Host.requestQuit()` に委譲しプロセスを殺さない
  - `src/bundler/icns.zig`: Pure Zig の `.icns` 生成＋パーサ。`iconutil` 不要、決定論的。
    `packaging-and-bench.md` の「未対応」を解消済みに更新
  - TLS / DB / OS フック / 外部ツールが必要な機能は **理由付きで除外**（日英ガイド §7 / gap §4）
  - `acl.zig`: 副作用のある P2 コマンドを `*_default` から除外
  - テスト: tauri 89 件、bundler 37 件（+2）。正常・異常・境界・永続化・再起動を検証
- **作業中**: なし。
- **未着手**: なし。**PR 1 本を作成して CI を確認するのみ**。
