# ブランチ運用（gitflow）

> **対象読者**: このリポジトリに変更を出す人・リリースを切る人。
> **前提**: `main` と `develop` はリポジトリのオーナーが作ります。

このリポジトリは **gitflow** のブランチモデルに従います。ブランチそのものを作るのは
オーナー（人間）で、並列で動く Arena エージェントは `arena/*` の 1 本だけにコミットします。
命名規則は [`scripts/gitflow.sh`](../../scripts/gitflow.sh) が検証し、CI が毎回 `--self-test` で
表ごと確認します（規約 21）。

## ブランチの役割

| ブランチ | 役割 | マージ先 | タグ |
|---|---|---|---|
| `main` | 公開済み。常にリリース可能な状態 | — | `vX.Y.Z` をここに打つ |
| `develop` | 次期リリースの統合 | `main` | 打たない |
| `feature/<slug>` | 1 つの変更単位 | `develop` へ PR | 打たない |
| `release/<x.y.z>` | バージョン固定・最終調整 | `main`（後で `develop` へ戻す） | `main` に `v<x.y.z>` |
| `hotfix/<x.y.z>` | 公開済みバージョンの緊急修正 | `main`（後で `develop` へ戻す） | `main` に `v<x.y.z>` |
| `arena/<agent>` | Arena エージェントの作業ブランチ | オーナーが選んだ base | 打たない |

`<slug>` は小文字英数字と `._-`、`<x.y.z>` は SemVer（`1.0.0-beta.1` のような pre-release も可）。
`beta-1.0` のような文字列は Zig の `build.zig.zon` に書けないので使いません。

## 命名を検証する

```bash
bash scripts/gitflow.sh --check feature/window-state
bash scripts/gitflow.sh --check release/0.1.1
bash scripts/gitflow.sh                 # 現在のブランチと推奨 base を表示
bash scripts/gitflow.sh --self-test     # CI が実行する命名テーブル
```

このスクリプトは**ブランチを作りません**。作るのは常にオーナーです。エージェントは
PR の **base** をオーナーが作った `develop` に合わせることだけできます（`--base develop`）。

## リリース手順

バージョンの正本は `build.zig.zon` の `.version` 1 箇所です。CLI のバージョン、配布 URL、
アーカイブ名、同期台帳は規約 20 がすべて同じ値か検査します。

1. `develop` を `main` へマージし、3 OS CI が緑であることを確認する。
2. `build.zig.zon` の `.version` を確認する（例: `0.1.1`）。
3. `main` のマージコミットにタグを打つ:

   ```bash
   git tag v0.1.1 <main のコミット>
   git push origin v0.1.1
   ```

4. [`Release`](../../.github/workflows/release.yml) ワークフローが `v*` で発火し、
   ソースアーカイブ → `zig fetch` ハッシュ → 3 OS の `zts` バイナリ → `SHA256SUMS` →
   GitHub Release を公開する。アーカイブは公開前に別パッケージからの import も検証される。
5. 公開 URL から依存を張り直して確認する:

   ```bash
   zig fetch --save=z_ts https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz
   ```

`--verify-tag` を使うため、タグは必ず **先に** push します。`workflow_dispatch` は
`github.ref_name` がブランチ名になるのでリリースには使いません。

## CI が反応するブランチ

[`ci.yml`](../../.github/workflows/ci.yml) の `push.branches` は `main` / `develop` /
`feature/**` / `release/**` / `hotfix/**` / `arena/**`。どのブランチに push しても同じ
3 OS マトリクスが走ります。Pages と Release は `main` とタグだけです。

## Arena エージェントとの共存

- エージェントは 1 セッション = 1 ブランチ（`arena/...`）に固定され、他のブランチを
  作成・checkout・push できません。並列エージェント同士の衝突を避けるためです。
- したがって `feature/*` という**名前の**ブランチをエージェントが作ることはありませんが、
  オーナーが作った `develop` へ PR を出すことはできます。
- [`AGENTS.md`](../../AGENTS.md) と `docs/roadmap/milestones.md` のチェックボックスは
  全ブランチ共有なので編集しません。進捗は `docs/tasks/<ID>-*.md` の 1 タスク 1 ファイルに
  分けます。

## 関連

- [リポジトリの地図](repository-map.md)
- [ドキュメント同期台帳](doc-sync.md)
- [GitHub Actions の運用](../environment/github-actions.md)
- アプリ作者向けの依存の張り方 → [`../learn/ja/guides/library.md`](../learn/ja/guides/library.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
