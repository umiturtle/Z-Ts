# Task M5-12: 学習パスの第 4 ステップ「実用パターン」（例とチュートリアルの間）

- **Status**: `done`
- **Branch**: `arena/7ef6be00-z-ts`
- **Scope**: `docs/learn/{ja,en}/patterns/{index,commands,state,errors,boundaries}.md`, `src/docsite/{learn_path,main,i18n}.zig`, `src/docsite/assets/site.css`, `docs/{INDEX.md,contributing/writing-docs.md,architecture/docs-as-a-product.md}`
- **Upstream Reference**: react.dev/learn（`### You will learn` と練習）／rust-lang.org/learn（1 文要約 → 例 → 発展）／kubernetes の job-based 索引
- **Next Step**: なし（完了）。ページを足すときは `docs/learn/<lang>/patterns/` に置くだけで、
  レールとサイドバーは `learn_path.zig` の表から自動で第 4 ステップになる。

---

## 1. 目的と完了条件

問い: **「初心者向け Doc の続き（examples との間）に、各機能の実用上の使い方・API 設計の
良し悪し・練習問題が要るのではないか」**

- [x] チュートリアル（作る）と examples（完成形）の間に、**判断基準**を扱う 1 ステップを置く
- [x] 4 ページ + 索引を日英で用意（同じファイル名 = パリティ検査を通す）
- [x] 各ページに「動く例 → 育つ/壊れる書き方 → なぜ → 練習（`<details>` の答え）」を持たせる
- [x] 動く例は `zig check` で**実際にコンパイル**（`./zigw doctest` が通る）。うち 1 本は `test` 付き
- [x] 練習は 3 + 2 + 3 + 2 = 10 問、すべて答えつき
- [x] レール・サイドバー・ランディングの 3 面を 1 つの表（`learn_path.zig`）から生成
- [x] ステップ数・合計時間の記述を 5 ステップ / 60 分に更新（機械的に検出できるところはテストで固定）

## 2. ページ構成

| ページ | 内容 | 練習 |
|---|---|---|
| `index.md` | なぜ「動く」と「育つ」が分かれるか、読み方、1 枚早見表 | — |
| `commands.md` | 粒度・引数（1 struct）・戻り値・命名。`RpcState` の宣言 | 3 |
| `state.md` | `*State` / `*const State`、メモリの所有者、フロントとの分担 | 2 |
| `errors.md` | `error{}` の粒度、境界での検証、結果と失敗の分け方、panic 禁止 | 3 |
| `boundaries.md` | `$try` と throw の使い分け、楽観更新、二重送信、再取得しない | 2 |

## 3. 設計判断

- **examples の前に置く**。examples は完成形で、読者は「なぜこう書くか」を復元できない。
  判断基準は、コードを書きはじめた直後（チュートリアルの後）に必要になる。
- **API リファレンスを複製しない**。ここは「選び方」、API は「引き方」。
  リンクで `docs/reference/cli.md` と生成 API に送る。
- **練習を本文と同じ重さで扱う**。`<details>` はレンダラがそのまま通すので、
  答えを隠したまま本文の流れを保てる。
- **動く例はコンパイルする**。`zts_rpc.Schema` の `RpcState` のように、書かないと落ちる規則は
  文章で説明するより、通るコードで示すほうが早い。
