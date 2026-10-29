# Task M4-04: Tauri 資産移行レイヤ（`tauri.conf.json` インポート & ACL）

- **Status**: `done`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/config_import.zig`, `src/tauri/acl.zig`, `src/tauri/mod.zig`,
  `tests/tauri/`, `docs/architecture/tauri-config-import-acl.md`,
  `docs/decisions/0014-config-import-and-acl.md`, `docs/INDEX.md`,
  `docs/roadmap/m2-m5-platform-and-ecosystem.md`, 本ファイル
- **Upstream Reference**: `tauri` v2.12.4 `crates/tauri-utils/src/config.rs`（`Config` / `AppConfig` /
  `WindowConfig` / `BuildConfig` / `SecurityConfig` / `AssetProtocolConfig`）、
  `crates/tauri-utils/src/acl/capability.rs`（`Capability` / `CapabilityFile` / `PermissionEntry` /
  `CapabilityRemote`）、`crates/tauri/src/ipc/authority.rs`（実行時照合）
- **Next Step**: なし（3 OS CI グリーン）。DoD 外の残作業は §5「フォローアップ」参照。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 既存 Tauri v2 プロジェクトの `src-tauri/tauri.conf.json` と
`src-tauri/capabilities/*.json` を **書き換えずに** Z-Ts が読めるようにし、
移行時に必要なコード変更を「数行（パスを渡すだけ）」に留める。

- [x] `tauri.conf.json`（v2 スキーマ）のパース: `productName` / `version` / `identifier` /
  `build.{devUrl,frontendDist,beforeDevCommand,beforeBuildCommand}` /
  `app.{windows[],security{csp,freezePrototype,capabilities[],assetProtocol{enable,scope}},withGlobalTauri,trayIcon}` /
  `bundle` / `plugins`
  - 未知フィールドは**無視**（前方互換）、型違いは**明示エラー**（フィールドパス付き）
  - `app.windows[]` → `core.WindowSpec`（`label`/`title`/`width`/`height`/`x`/`y`/`min*`/`max*`/
    `resizable`/`decorations`/`transparent`/`alwaysOnTop`/`visible`/`fullscreen`/`devtools`/`theme`/`url`）
- [x] `capabilities/*.json` のパース: `identifier` / `description` / `windows[]` / `webviews[]` /
  `permissions[]`（文字列 or `{identifier, allow, deny}`）/ `platforms[]` / `local` / `remote.urls[]`
  - `CapabilityFile` の 3 形状（単体 / 配列 / `{capabilities:[...]}`）を受ける
- [x] ACL 判定: `Policy.allows(command, window_label, origin)` が
  - コマンド → 権限識別子 → capability の順で解決し、**マッチしなければ deny（fail-closed）**
  - `windows` / `webviews` の glob（`*`, `?`）、`platforms`（`linux`/`macOS`/`windows`）、
    `local` / `remote.urls`（URL パターン）を考慮
  - `plugin:<name>:allow-<kebab-case>` / `plugin:<name>:default` を **実コマンド表から comptime 生成**
- [x] `rpc` への接続（`Router.withAuthCtx` + `Policy.authorizeCtx`）と、拒否時の 403
- [x] 移行ヘルパ `config_import.load(allocator, io, project_dir)` → `{ config, capabilities, warnings }`
  （未対応キー・壊れた capability ファイルを警告として列挙。設定本体の失敗はしない）
- [x] `comptime` 読み込み（`@embedFile` した JSON 文字列を `parse` に渡せる。`FixedBufferAllocator` 併用可）
- [x] 単体テスト（正常系 / 型違い / 未知フィールド / glob / platform / remote / deny / リーク 0）
- [x] `./zigw quick-test` / `./zigw build test -Dgtk=true|false` / `fmt --check` / `check-docs`
- [x] 3 OS CI グリーン（run `40829957744` @ `10a59eb` = 4/4）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 上流スキーマの一次資料を取得し、フィールド名を確定（`config.rs` / `capability.rs`）
  - `config_import.zig`（`Config` / `WindowConfig` / `Security` / `Scope` / `Diagnostics` / `load`）と 5 テスト
  - `acl.zig`（`Capability` / `Permission` / `Policy` / 権限識別子生成 / `fromImported` / `authorizeCtx`）と 6 テスト
  - `rpc.Router.withAuthCtx`（状態付き認可）
  - アーキテクチャ doc / ADR-0014 / INDEX / roadmap 更新
- **作業中・直前の状態**:
  - `quick-test` = `All 56 tests passed`、`build test -Dgtk=false` = `222/224 (2 skipped)`、
    `-Dgtk=true` = `46/46 steps, 99/108 (9 skipped)`、`fmt --check` / `check-docs`(53) OK
  - 3 OS CI = [run `40829957744`](https://github.com/umiturtle/Z-Ts/actions/runs/40829957744)
    @ `10a59eb` の 4 ジョブすべて success（Linux / macOS / Windows / Cross-OS parity）

---

## 3. 設計判断・技術メモ・ハマりどころ

- **ACL は opt-in**: 既存アプリ（と本リポジトリの 200 以上のテスト）は今 ACL を設定していない。
  `Policy` を渡したときだけ `AuthorizeFn` を差し込む。渡さない場合の挙動は現状維持（全許可）。
  これは「移行時にコード書き換えを最小化する」という M4-04 の目的に沿う。
- **権限表は実コマンドから生成**: `rpc.Schema(.{ .fs = fs.Commands, ... }).commands` を comptime で
  走査し、`plugin:fs|read_text_file` → `fs:allow-read-text-file` を機械的に作る。
  手書きの表を持つとコマンド追加時に必ず腐る。
- **deny を allow より優先**（上流 `Authority` と同じ）。同じコマンドに複数 capability が
  マッチした場合、1 つでも deny があれば拒否。
- **`local` / `remote`**: 上流はリクエスト URL がローカル（`tauri://` / `http://tauri.localhost` …）
  か否かで capability を出し分ける。Z-Ts の `rpc.Ctx.origin` をそのまま使う。
- **`$RESOURCE` などのパス変数**は `fs` スコープ側で解決する（`config_import` は生の文字列を返し、
  `zts_foundation`/`tauri.path` の解決関数に渡す）。

---

## 4. 作業ログ

（実装後に追記）

### 2026-10-29 — 実装完了（CI 待ち）

- `config_import.zig`: `parse` が `Parsed{arena, config}` を返し、`load` が `Imported{arena,
  config, capabilities, warnings}` を返す。**未知キーは警告・型違いは `error.InvalidConfig`**。
  `app.windows[]` は `core.WindowSpec` へ（`create: false` は除外、`{"url":…}`/`{"app":…}` も解決）。
- `acl.zig`: `Capability` は `windows` / `webviews` の glob、`platforms`、`local`、`remote.urls`
  を持ち、`Policy.allows` は **deny が allow に勝つ** fail-closed 判定。
- 権限識別子は `permissionIdFor` が wire コマンドから生成（`plugin:fs|read_text_file` →
  `fs:allow-read-text-file`、core 名前空間は `core:window:allow-set-title`）。
  `CorePluginsSchema` の全コマンドについて**一意性**をテストで保証。
- `rpc.Router.withAuthCtx(userdata, fn)` を追加（`withAuth` は後方互換のまま）。

**ハマりどころ（Zig 0.17）**: `inline` は予約語なので union フィールド・構造体フィールドに使えない
→ `inline_json` / `inline_entries`。`bool` という関数名はプリミティブを shadow する → `flag`。
`std.mem.trimRight` は無い → `trimEnd`。`[]const CommandMeta` を実行時 `for` で回すと
comptime-known 要求で落ちる → `inline for`。テストで JSON を `testing.allocator` から
`parseFromSliceLeaky` するとリーク → 専用 arena を持つ。

---

## 5. フォローアップ（DoD 外・別タスクで実施）

1. **権限スコープの実適用**: `{ "identifier": "fs:allow-write-text-file", "allow": [{ "path": "$HOME/**" }] }`
   の `allow` / `deny` を `tauri.fs.Scope` へ変換する（`$RESOURCE` / `$APPDATA` 等の変数解決込み）。
2. **CLI 表示**: `Diagnostics` を整形して `zts migrate <dir>` で出す（警告一覧 + 生成される
   `WindowSpec` のドライラン）。
3. **バンドラ**: `bundle.*`（アイコン・署名・ターゲット別インストーラ）は読み取るだけで未実装。
