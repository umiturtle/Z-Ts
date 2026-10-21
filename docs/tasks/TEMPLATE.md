# Task <ID>: <タイトル>

- **Status**: `in_progress` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `<arena/...>`
- **Scope**: `<変更対象のディレクトリ一覧 例: src/ipc/, docs/architecture/ipc.md>`
- **Upstream Reference**: `<参照した本家コード 例: vendor/tauri/crates/tauri/src/ipc/>`
- **Next Step**: `<コンテキストが今この瞬間に飛んでも次のターンで迷わず実行できる具体的な 1 アクション>`

---

## 1. 目的と完了条件（Definition of Done）

- [ ] 設計メモ / API 仕様の整理
- [ ] 単体テスト（正常系・異常系・境界値・リーク検査 `std.testing.allocator`）の作成とパス
- [ ] `./zigw build test` および `python3 scripts/check-docs.py` のパス
- [ ] 必要な場合 GitHub Actions（Linux Xvfb / macOS / Windows）でのグリーン確認

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

<!-- サブタスク完了・設計決定・デバッグ判明のたびにここを上書き更新すること -->
- **完了したこと**:
  - ...
- **作業中・直前の状態**:
  - ...

---

## 3. 設計判断・技術メモ・ハマりどころ

- ...
