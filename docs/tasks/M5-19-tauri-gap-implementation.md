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
- [ ] **P0-4** 生成済み `gzip_entries` を実際に配信する
- [ ] **P0-5** `zts migrate`
- [ ] **P1** webview コマンド / ウィンドウイベント / 残り setter / Monitor・DPI / 未適用 config フィールド / `once` / `asset://` scope の実行時更新
- [ ] **P2** 公式プラグイン群・配布形式のうち理念に反しないもの
- [ ] 各項目に単体テスト（`std.testing.allocator`、正常系・異常系・境界値）
- [ ] 日英の読者向け Doc を更新、ルール 11（索引網羅）と規約 13（同期台帳）を維持
- [ ] `./zigw quick-test` / `build test` / `doctest` / `fmt --check` / `docs-check` / 3 OS CI が緑
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
- **作業中**: **P0-4** 生成済み `gzip_entries` を実際に配信する。
- **未着手**: P0-5 / P1 / P2。
