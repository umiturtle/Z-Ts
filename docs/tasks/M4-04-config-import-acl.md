# Task M4-04: Tauri 資産移行レイヤ（`tauri.conf.json` インポート & ACL）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/config_import.zig`, `src/tauri/acl.zig`, `src/tauri/mod.zig`,
  `tests/tauri/`, `docs/architecture/tauri-config-import-acl.md`,
  `docs/decisions/0014-config-import-and-acl.md`, `docs/INDEX.md`,
  `docs/roadmap/m2-m5-platform-and-ecosystem.md`, 本ファイル
- **Upstream Reference**: `tauri` v2.12.4 `crates/tauri-utils/src/config.rs`（`Config` / `AppConfig` /
  `WindowConfig` / `BuildConfig` / `SecurityConfig` / `AssetProtocolConfig`）、
  `crates/tauri-utils/src/acl/capability.rs`（`Capability` / `CapabilityFile` / `PermissionEntry` /
  `CapabilityRemote`）、`crates/tauri/src/ipc/authority.rs`（実行時照合）
- **Next Step**: `config_import.zig` の `Config` / `WindowConfig` パーサを実装 → `acl.zig` の
  `Capability` + `Policy` → `rpc.AuthorizeFn` への接続 → docs → 3 OS CI。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 既存 Tauri v2 プロジェクトの `src-tauri/tauri.conf.json` と
`src-tauri/capabilities/*.json` を **書き換えずに** Z-Ts が読めるようにし、
移行時に必要なコード変更を「数行（パスを渡すだけ）」に留める。

- [ ] `tauri.conf.json`（v2 スキーマ）のパース: `productName` / `version` / `identifier` /
  `build.{devUrl,frontendDist,beforeDevCommand,beforeBuildCommand}` /
  `app.{windows[],security{csp,freezePrototype,capabilities[],assetProtocol{enable,scope}},withGlobalTauri,trayIcon}` /
  `bundle` / `plugins`
  - 未知フィールドは**無視**（前方互換）、型違いは**明示エラー**（フィールドパス付き）
  - `app.windows[]` → `core.WindowSpec`（`label`/`title`/`width`/`height`/`x`/`y`/`min*`/`max*`/
    `resizable`/`decorations`/`transparent`/`alwaysOnTop`/`visible`/`fullscreen`/`devtools`/`theme`/`url`）
- [ ] `capabilities/*.json` のパース: `identifier` / `description` / `windows[]` / `webviews[]` /
  `permissions[]`（文字列 or `{identifier, allow, deny}`）/ `platforms[]` / `local` / `remote.urls[]`
  - `CapabilityFile` の 3 形状（単体 / 配列 / `{capabilities:[...]}`）を受ける
- [ ] ACL 判定: `Policy.allow(command, window_label, origin)` が
  - コマンド → 権限識別子 → capability の順で解決し、**マッチしなければ deny（fail-closed）**
  - `windows` / `webviews` の glob（`*`, `?`）、`platforms`（`linux`/`macOS`/`windows`）、
    `local` / `remote.urls`（URL パターン）を考慮
  - `plugin:<name>:allow-<kebab-case>` / `plugin:<name>:default` を **実コマンド表から comptime 生成**
- [ ] `rpc.AuthorizeFn` への接続ヘルパ（`acl.guard(...)`）と、拒否時の 403
- [ ] 移行ヘルパ `migrate(allocator, io, project_dir)` → `{ config, capabilities, warnings }`
  （未対応キー・未知の権限識別子を警告として列挙。失敗はしない）
- [ ] `comptime` 読み込み（`@embedFile` + `FixedBufferAllocator`）でビルド時に構成を確定できる
- [ ] 単体テスト（正常系 / 型違い / 未知フィールド / glob / platform / remote / deny / リーク 0）
- [ ] `./zigw quick-test` / `./zigw build test -Dgtk=true|false` / `fmt --check` / `check-docs`
- [ ] 3 OS CI グリーン

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 上流スキーマの一次資料を取得し、フィールド名を確定（`config.rs` / `capability.rs`）
  - 本タスクシートの作成
- **作業中・直前の状態**:
  - `config_import.zig` 未着手

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
