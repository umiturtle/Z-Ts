# Task M5-13: 索引ページを「今のサイト」に合わせる

- **Status**: `done`
- **Branch**: `arena/a52b9ce6-z-ts`
- **Scope**: `docs/INDEX.md`, `docs/contributing/repository-map.md`（新規）, `README.md`, `docs/learn/{ja,en}/{index,concepts/index,tutorials/index}.md`, `docs/glossary.md`, `scripts/check-docs.py`, `src/docsite/{main,learn_path}.zig`
- **Upstream Reference**: Kubernetes の索引ページ（用途別ブロック + 全量は別ページ）／ [docs-as-a-product.md](../architecture/docs-as-a-product.md) P23（道順は 1 本）
- **Next Step**: なし（完了）。新しいページを足すときは `docs/INDEX.md` の該当グループに 1 行
  （規約 11 が忘れを落とす）。

---

## 1. 目的と完了条件

依頼: **「Index.md とかも今のサイトに合わせて改良して」**。サイトは 5 ステップの学習パス・
番号付きサイドバー・グループ 10 個（学習 / 概念 / チュートリアル / 実用パターン / ガイド /
リファレンス / API / サンプル / リポジトリ開発 / 内部資料）に育ったのに、`docs/INDEX.md` は
**サイトができる前のリポジトリ地図**のままでした。

- [x] `docs/INDEX.md` をサイトのサイドバーと同じ並びの索引に書き直す
- [x] 学習パスを 5 ステップ・60 分で明記し、各ステップの「終わったとき」を 1 行で
- [x] 全ページ（`docs/learn/ja/**`, `docs/reference/*.md`, `docs/contributing/*.md`, `examples/*/README.md`）を 1 回はリンクする
- [x] リポジトリのファイル地図（更新頻度・競合リスク）は読者向け索引から外し、
      [`../contributing/repository-map.md`](../contributing/repository-map.md) に移す（情報は捨てない）
- [x] `README.md` の「アプリを作る人向け」を同じ 5 ステップ表 + やりたいこと索引に
- [x] 章ハブ（概念 / チュートリアル）の「次に読む」に実用パターンを追加（ja / en）
- [x] サイト側の実際のズレを修正: ガイドのサイドバー見出しが **`4 · 実用パターン`** になっていた
      （パターン章を挿したとき `groupHeading` の番号が手書きだった）。パターンは `4 ·`、ガイドは `5 ·`
- [x] 404 のリンクを 6 行のメニューから 5 本（ホーム / 最初の一歩 / 学習パス / 索引 / API）に整理
- [x] 数字のドリフトを削除（「31 語の用語集」→ 実際は 30 語）。索引に件数を書かない
- [x] **規約 11**（`docs/INDEX.md` が全ページをリンクしているか）を追加
- [x] `./zigw docs-check` / `doctest` / `fmt --check` を緑に

## 2. 設計判断

- **索引は「サイトの写し」**。並びの正本は `src/docsite/main.zig` の `GroupKey`、学習パスの
  番号と分は `learn_path.zig`。`INDEX.md` はそれを人が読める形に写す。順番の機械検査はしない
  （正本が 2 か所になる）。**網羅だけ**を規約 11 で検査する。
- **内部向けの地図は contributing へ**。`INDEX.md` はサイトのフッター「ドキュメント索引」から
  誰でも開けるページで、`M4-03` や「競合リスク」を読む場所ではない。エージェント向けの
  情報は [`repository-map.md`](../contributing/repository-map.md) に残した（記憶復元の役割は維持）。
- **数字を書かない**。90 ページ・455 宣言・31 語はすぐ古くなる。生成側（ランディング）は
  実測値を出し、手書きページは「全公開宣言」「用語集」とだけ書く。
- **404 は 5 本**。迷った人にグループを選ばせない。最初の一歩・道順・全体の索引・辞書で十分。
- **サイドバーの番号は表から引く**。`groupHeading` の `switch` に番号を直書きしたのが今回の
  バグの原因。`learn_path.steps` の位置から引く形にし、`patterns` / `guides` の両方をテストで固定。

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-11-14 -->
