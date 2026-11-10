# Task M5-24: 公開サイトの URL を改名後のリポジトリ名へ寄せる

- **Status**: `in_progress` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/14e12855-z-ts`（main `a5b9d73` = PR #22 マージ後）
- **Scope**: `src/docsite/{main,frameworks,demos}.zig`, `scripts/gen-framework-tutorials.py`,
  `docs/learn/{ja,en}/tutorials/*.md`（生成物）, `README.md`, `README.en.md`, `AGENTS.md`,
  `docs/INDEX.md`, `docs/INDEX.en.md`, `docs/architecture/documentation-site.md`,
  `examples/frameworks/README.md`, `examples/frameworks/README.en.md`,
  `.github/workflows/pages.yml`（コメント）, `scripts/check-docs.py`（規約 19）,
  `scripts/doc-sync.json`, `docs/contributing/doc-sync{,.en}.md`, 本ファイル
- **Upstream Reference**: [`M5-23-ci-rename-safe-check-runs.md`](M5-23-ci-rename-safe-check-runs.md)
  （リネーム発覚の経緯）、[`../architecture/documentation-site.md`](../architecture/documentation-site.md)
  （Pages サブパスの設計）、規約 14（旧リポジトリ URL / パス名の扱い）
- **Next Step**: `umiturtle.github.io/Z-Ts/` を `umiturtle.github.io/ZigguraTs/` へ一括置換し、
  `python3 scripts/gen-framework-tutorials.py` で 20 ページを再生成する。その後、規約 19 を
  追加して再発を機械検査し、`--sync --date 2026-10-21` で同期台帳を更新して PR を 1 本作る。

---

## 1. 依頼と完了条件（Definition of Done）

> 「公開サイト内の `site_url` / sitemap / llms.txt などを新名へ寄せる必要があれば、別タスクで一括更新します」→「お願い」

- [ ] `https://umiturtle.github.io/Z-Ts/` を**公開面**（Doc・生成器・ワークフローのコメント）から
      `https://umiturtle.github.io/ZigguraTs/` へ一括更新する
- [ ] `src/docsite/main.zig` の `site_url`（sitemap.xml / llms.txt / llms-full.txt）、
      `src/docsite/frameworks.zig` のライブデモ URL、
      `scripts/gen-framework-tutorials.py` の `PAGES_URL` を新名に揃える
- [ ] 生成済みの日英チュートリアル 20 ページを再生成し、
      `python3 scripts/gen-framework-tutorials.py --check` が緑
- [ ] `github.com/umiturtle/Z-Ts/...` とチェックアウトのパス名（`cd Z-Ts` / `/path/to/Z-Ts` 等）は
      **規約 14 どおり据え置き**。`github.com` はリダイレクトされ、パス名は利用者のローカル名だから
- [ ] 履歴資料（`docs/tasks/*.md` / `docs/decisions/*.md`）は他エージェント・追記専用のため非編集
- [ ] 規約 19 を追加し、公開面に旧 Pages URL が残らないことを機械検査する
- [ ] 日英 Doc と同期台帳を更新、`learn_path.steps` / `AGENTS.md` と
      `docs/roadmap/milestones.md` の**チェックボックスは非編集**
- [ ] `quick-test` / `build test` / `doctest` / `docs-check` / `fmt --check` / 3 OS CI が緑、PR は 1 本だけ

## 2. 原因と範囲の切り分け

- リポジトリが `umiturtle/Z-Ts` → `umiturtle/ZigguraTs` に改名され、GitHub Pages の公開 URL も
  `https://umiturtle.github.io/ZigguraTs/` に変わった。旧 `/Z-Ts/` は **404**（実測）。
- `https://github.com/umiturtle/Z-Ts/...` は GitHub が 301 で新名へリダイレクトするため依然として有効。
  規約 14 の「リポジトリ URL / パス名は据え置き」も継続するため、今回は触らない。
- したがって修正対象は **404 になる Pages のベース URL だけ**。これにより `site_url` から生成される
  sitemap / llms.txt / llms-full.txt、フレームワークのライブデモリンク、日英チュートリアル、
  README / 索引 / アーキテクチャ Doc のリンクがすべて新しい公開位置を指す。
- `docs/decisions/` は ADR（追記専用）、`docs/tasks/` は他ブランチの担当票のため、そこに残る旧 URL は
  歴史的記録として許容し、規約 19 のスキャン対象から除外する。

## 3. 設計判断

| # | 判断 | 理由 |
|---|---|---|
| 1 | Pages URL のみ置換し `github.com` URL は残す | 404 は Pages 側だけ。リダイレクトで動くリンクを一括変更すると規約 14 と利用者の clone 手順を壊す |
| 2 | 正本は `site_url` / `PAGES_URL` / `demoUrl()` の 3 定数 | 生成物（20 ページ・sitemap・llms）は再生成で追随させ、手で直さない |
| 3 | チェックアウトのパス例は据え置き | `git clone` の URL を変えないので `cd Z-Ts` も整合する。ローカルディレクトリ名は利用者が決める |
| 4 | 規約 19 で公開面をスキャン | 「Doc と実装のズレを機械検証」する継続制約。ADR / タスク票は除外 |
| 5 | 同期台帳は `--sync --date 2026-10-21` | 読者向け Doc のハッシュが変わるため。`verified.date` は据え置き |

## Current State / Next Step

- **現在**: 調査完了。30 秒ルーチン（`quick-test` / `check-docs.py` / `fmt --check`）は緑。
  現ブランチは `main a5b9d73` 起点で clean、Open PR は別ブランチの #9 のみ。
  旧 Pages URL は 32 ファイル・101 箇所、旧 `github.com` URL は 43 ファイル・124 箇所（後者は据え置き）。
- **次の 1 手**: 分散ロック（この票）を push した後、3 定数と公開面の Pages URL を置換し、
  チュートリアル 20 ページを再生成する。
