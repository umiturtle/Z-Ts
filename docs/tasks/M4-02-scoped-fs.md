# Task M4-02: スコープ付きファイルシステムプラグイン（`src/tauri/fs/`）

- **Status**: `in_progress` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/fs/`（`mod.zig` / `scope.zig` / `commands.zig`）, `src/tauri/mod.zig`, `docs/tasks/M4-02-scoped-fs.md`, `docs/architecture/tauri-fs-plugin.md`, `docs/decisions/0011-scoped-fs-plugin.md`, `docs/INDEX.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Upstream Reference**: `@tauri-apps/plugin-fs` v2（`plugins-workspace/plugins/fs/src/commands.rs` / `guest-js/index.ts`）
- **Next Step**: `src/tauri/fs/scope.zig` に「字句正規化 → シンボリックリンク解決 → ルート包含判定」を実装し、`./zigw quick-test` で単体テストを通す。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: Tauri v2 の `plugin:fs|*` を Pure Zig（`link_libc = false`）で再実装し、
**シンボリックリンク経由のスコープ脱出を構造的に不可能**にする。

- [ ] `OsPath`（WTF-8 / 非 UTF-8）対応のパス解決（`src/tauri/path.zig` の正規化・`BaseDirectory` を再利用）
- [ ] スコープ判定: 字句正規化 → シンボリックリンク解決（ホップ上限あり）→ ルート包含判定
- [ ] 読み書き・ディレクトリ走査・メタデータ・リソース（`rid`）ベースのストリーム入出力
- [ ] 単体テスト: 正常系 / `..` 脱出 / シンボリックリンク脱出 / リンク内包 / Windows 形式パス / リーク検査
- [ ] `./zigw quick-test` / `./zigw build test` / `python3 scripts/check-docs.py` / `./zigw fmt --check` のパス
- [ ] 3 OS CI グリーン

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 上流 `commands.rs` / `guest-js/index.ts` のワイヤ仕様を確認（コマンド名・引数・戻り値・`FileInfo` フィールド名）。
  - タスクシェード（ロック）作成。
- **作業中・直前の状態**:
  - `scope.zig` の実装に着手したところ。

---

## 3. 設計判断・技術メモ・ハマりどころ

（実装しながら追記する）
