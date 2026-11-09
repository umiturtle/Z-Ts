# Task M5-14: 左メニューを学習パスに統一し、チュートリアルを 3 本にする

- **Status**: `done`
- **Branch**: `arena/a52b9ce6-z-ts`（PR #16 に追加コミット。PR は増やさない）
- **Scope**: `src/docsite/{main,learn_path,i18n,apidoc}.zig`, `scripts/check-docs.py`, `docs/INDEX.md`, `README.md`, `docs/learn/{ja,en}/{index,start,concepts/index,patterns/index,patterns/commands,tutorials/*}.md`, `docs/contributing/{README.md,repository-map.md,troubleshooting.md,writing-docs.md}`
- **Upstream Reference**: [`../architecture/docs-as-a-product.md`](../architecture/docs-as-a-product.md) P23（道順は 1 本）／ [`../contributing/writing-docs.md`](../contributing/writing-docs.md) 規約 11・12
- **Next Step**: なし（完了）。次に章を 1 つ足すときは `learn_path.page_order` → `GroupKey.order()` →
  `docs/INDEX.md` → `README.md` の順に 1 行ずつ足す（規約 11 / 12 が忘れを落とす）。

---

## 1. 依頼と完了条件

依頼（4 点）:

1. **開くページによって左メニューの並びが変わるのは分かりにくい。学習パスの方に統一したい**
   （現状そちらが綺麗にまとまっている）
2. **トップページから入るのはチュートリアルページではなく初心者用ページがよい**
3. **`tutorials/counter.html` へのリンクが `tutorials/index.html` より前にあるのはおかしい**
4. **チュートリアルも複数ほしい**

- [x] 左メニューを**全ページ・日英で同一の並び**にする
- [x] 先頭を「学習パスの入口 + 5 つの番号付きステップ」にする
- [x] 章内を**ファイル名順ではなく読み順**にする（章の索引 → 1 本目 → 2 本目 …）
- [x] トップのヒーローは `start.html`（初心者ページ）を主 CTA に、副 CTA は
      `tutorials/index.html` に変更（`counter.html` は章の索引より後ろにだけ出る）
- [x] チュートリアルを **3 本**（カウンター / Todo / 画面）に。日英 2 言語、`zig check` 4 ブロック
- [x] 所要分のドリフトを止める（規約 12）
- [x] `./zigw docs-check` / `doctest` / `fmt --check` / 3 OS CI を緑に

## 2. 実際の原因

- **言語でメニューが違った**: `GroupKey.order(lang)` が日本語では 11 グループ、英語では
  `.api` までの 6 グループを返していた。言語切替のたびに「リファレンス」「サンプル」
  「リポジトリ開発」「内部資料」が消え、並びが変わって見える。
- **章内がファイル名順だった**: `orderLearnEntries()` はステップの着地ページだけを先頭に
  寄せ、残りは `href` の辞書順。そのため `patterns/boundaries.md` が章の 2 番目に出たり、
  ガイドが `install.md` から始まらなかったりした。`.patterns` はそもそもソート対象外。
- **ステップ 1 が「学習パス」グループに押し込められていた**: 2〜5 は番号付きの独立
  グループなのに 1 だけ番号が無く、レールとサイドバーが一致していなかった。
- **ヒーローの副 CTA が `counter.html`**: ランディングのパス区画（ステップ 3 =
  `tutorials/index.html`）より前に個別チュートリアルへのリンクが出ていた。
  API 内部実装バナーの「はじめかた」も `counter.html` を指していた。

## 3. 設計判断

- **並びの正本を 1 つにする**。`GroupKey.order()` は引数を失い、両言語で同じ 11 グループを
  返す。未翻訳のページ（リファレンス・サンプル・開発者向け）も英語メニューに出す。
  ただし H1 は日本語なので、`englishNavTitle()` が**ナビのラベルだけ**英訳する
  （ページ本体は日本語 H1 + `ja` バッジのまま）。消すより、読めるラベルで示したほうが迷わない。
- **章内の読み順は `learn_path.page_order`**、それ以外のグループは `navRank()` の短い表。
  未掲載のページは**落とさず末尾に辞書順**で出す。新しいファイルを足した瞬間に
  「消えた」と思わせないため。純関数なので、walk がどんな順でページを渡しても同じ並び。
- **ステップ 1 を独立グループに**: `GroupKey.start` を追加し `groupHeading` が
  `learn_path.steps[0]` から `1 · はじめての Z-Ts` を引く。番号は全部 `learn_path.steps` 由来。
- **死んだ `.deep` グループを削除**: `docs/guides/` の旧ページはすでに `.internals` に
  畳まれており、`.deep` はどのページも返さなかった（`groupFor` の分岐も `pageKind` の
  `"deep"` 分岐も到達不能）。
- **3 本目のチュートリアルは「画面」**: Zig 側だけだと `web/` の状態・CSS ホット差し替え・
  CSP がどこにも手を動かして出てこなかった。Todo は「状態と失敗」、画面は「描画と配布」を
  担当し、両方から実用パターンへ橋を架ける。
- **所要分は正直に**: 3 本で 15 + 20 + 15 = 50 分。ステップ 3 を 15 → 50、合計 60 → 95 分に
  上げ、README / 索引 / 日英ハブ / `start.md` の次ステップ表を全部更新。
  **規約 12** が `learn_path.zig` の `.minutes` を読み、4 か所の「およそ N 分」と 2 つの
  ステップ表を突き合わせる（ずらして発火を確認済み）。`GroupKey.order()` が再び言語を
  取った場合も落とす。

## 4. 検証

```
python3 scripts/check-docs.py
  Documentation check OK (130 markdown files, 24 reader pages in each of 2 languages)
./zigw test -Mroot=src/docsite/mod.zig   → All 79 tests passed
./zigw fmt --check src/ build.zig ...    → OK
./zigw quick-test                        → All 7 tests passed
./zigw doctest                           → OK doctest blocks=20
./zigw docs-check                        → OK
./zigw build docs
  OK docsite pages=241 links=943 assets=19769 words=576920 api_undoc=0 errors=119
  （236 → 241: 日英 2 本 × 2 チュートリアル + このタスク票）
```

生成 HTML の `<nav class="nav-groups">` を全ページ走査し、**構造は日本語版・英語版の
2 種類だけ**（どちらも 48 エントリ・11 グループ、先頭 6 つが学習パス + 番号付き 5 ステップ）
であることを確認。ランディングの `tutorials/index.html` は全 `counter.html` より前。
