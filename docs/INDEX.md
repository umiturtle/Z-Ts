# Z-Ts ドキュメント索引（Documentation Hub）

`Z-Ts` では、**エージェントの定期的な記憶リセット（Context Compaction）への耐性** と **複数エージェントの同時並列開発（Git コンフリクトゼロ）** を両立するため、用途ごとに Markdown ファイルを厳格に分離しています。

---

## ディレクトリマップ

| パス | 役割 | 更新頻度・競合リスク |
|---|---|---|
| [`../AGENTS.md`](../AGENTS.md) | 全エージェント必読のエントリーポイント・運用ルール | 低頻度（進捗追記禁止） |
| [`architecture/00-overview.md`](architecture/00-overview.md) | Z-Ts 全体 6 層アーキテクチャ・上流 `vendor/` 対応マップ・モジュール境界契約 | 中頻度（全体方針変更時） |
| `architecture/<module>.md` | 各サブシステム詳細設計（例: `config.md`, `ipc.md`, `acl.md`, `window-linux.md`） | モジュール単位で完全独立 |
| [`roadmap/milestones.md`](roadmap/milestones.md) | マイルストーン（M0〜M6）の定義と並列依存グラフ | 低頻度（進捗は `tasks/` で管理） |
| [`tasks/TEMPLATE.md`](tasks/TEMPLATE.md) | 1タスク＝1ファイルの作業計画＆記憶チェックポイント標準テンプレート | テンプレート |
| `tasks/<ID>-<slug>.md` | 個別タスクの進捗・設計メモ・次の1手（例: [`tasks/M0-01-bootstrap.md`](tasks/M0-01-bootstrap.md)） | **担当ブランチ専有（競合ゼロ）** |
| `decisions/<NNNN>-<slug>.md` | アーキテクチャ意思決定記録（ADR）（例: [`decisions/0001-zig-017-and-sharded-agent-workflow.md`](decisions/0001-zig-017-and-sharded-agent-workflow.md)） | **新規ファイル追加のみ（競合ゼロ）** |
| [`environment/arena-and-caching.md`](environment/arena-and-caching.md) | 毎チャットキャッシュ揮発対策・LLVM 同梱検証・高速ビルド規約 | 環境変更時のみ |
| [`environment/github-actions.md`](environment/github-actions.md) | GitHub Actions 3 OS マトリクス・キャッシュ自動配信・ベンチ/差分テスト運用 | CI 変更時のみ |
| [`reference/tauri-usage.md`](reference/tauri-usage.md) | Tauri v2 の使い方リファレンス（Rust/JS API・設定・Capabilities） | リファレンス（追記のみ） |
| [`reference/tauri-internals.md`](reference/tauri-internals.md) | Tauri v2 内部実装の完全解剖（IPC プロトコル・マクロ・10個の内蔵 Plugin・OS 層） | リファレンス（追記のみ） |
