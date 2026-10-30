# ADR-0018: ドキュメントサイトはリポジトリ内の Zig でレンダリングし、GitHub Pages に公開する

- **Status**: Accepted（`M5-06`）
- **Date**: 2026-10-30
- **関連**: [`../architecture/documentation-site.md`](../architecture/documentation-site.md)、
  [`../tasks/M5-06-docs-site.md`](../tasks/M5-06-docs-site.md)、
  [`0017-build-tools.md`](0017-build-tools.md)

---

## 1. 背景

`docs/` には 60 本以上の Markdown があるが、読むには GitHub を辿る必要があり、
* 検索できない（`grep` しかない）
* 目次が `docs/INDEX.md` の手書き 1 枚に依存している
* `examples/` の「ビルド済みのもの」（カウンターの SSG 出力・9 フレームワークのデモ）は
  CI でしか見られず、ブラウザで触れない

一方で、このプロジェクトは「Zig だけで Web 資産を組み立てる」ことを売りにしている。

## 2. 決定事項

### 2.1 サイトは `src/docsite/` の Zig で生成する（外部ツールを入れない）

| 層 | 役割 |
|---|---|
| `markdown.zig` | Markdown → HTML（GFM テーブル・ネストしたリスト・タスクリスト・フェンス・引用・生 HTML・インライン記法） |
| `site.zig` | ページシェル、サイドバー、目次、検索インデックス、**リンク検査** |
| `demos.zig` | サンプルの公開（絶対 URL の書き換え） |
| `main.zig` | ファイル IO と組み立て（`zig build docs`） |

MkDocs / Docusaurus / mdBook を使えば機能は増えるが、**毎チャットでキャッシュが消える環境**
（[`../environment/arena-and-caching.md`](../environment/arena-and-caching.md)）では
Node のインストールだけで数十秒かかる。`std` だけの実装なら `zig build docs` が 2 秒で終わり、
`./zigw quick-test` に 28 本のテストを載せられる。

### 2.2 サイトのレイアウトはリポジトリ構造の写像にする

`docs/tasks/x.md` → `docs/tasks/x.html`。**リポジトリ内の相対リンクがそのまま動く**ので、
Markdown を二重管理しない。GitHub 上での見え方と Pages 上での見え方が一致する。

### 2.3 リンク切れはビルドを失敗させる

生成時に全ページの相対リンクを解決し、書き出すページ集合に無ければ `error.BrokenLinks`。
サイトに含まれないファイル（`src/**.zig` など）へのリンクだけは GitHub の blob URL に
差し替える（差し替え対象は「リポジトリに実在する」ものに限る。実在しなければ失敗）。

これにより「ドキュメントを書き換えたらリンクが壊れた」が PR の CI で分かる。実際、この仕組みを
入れた時点で**既存ドキュメントの壊れたリンク 11 本**が見つかった（うち 6 本は `.md` の
リンク先ページが生成対象から漏れていたもの）。

### 2.4 サンプルのビルド済み出力も同じサイトで公開する

* `examples/counter` の SSG 出力（`zig build dist`）→ `/examples/counter/`
* 9 フレームワークのコミット済みデモ → `/examples/frameworks/<name>/`

フレームワークのデモはギャラリー用に**絶対パス**（`/assets/…`）で出力されているため、
GitHub Pages のサブパス（`/Z-Ts/`）では 404 になる。`demos.zig` が相対 URL に書き換える
（規則と根拠は [`../architecture/documentation-site.md`](../architecture/documentation-site.md) §5）。

### 2.5 公開は `main` への push 時のみ

`.github/workflows/pages.yml` が `main` で走り、`configure-pages` → `upload-pages-artifact` →
`deploy-pages` で公開する。PR ブランチからは公開しない（`github-pages` 環境を汚さないため）。

## 3. 検討した代替案

1. **MkDocs Material** — 高機能だが Python 依存。`pip install` が毎チャット必要で、
   さらに「Tauri を Zig で再実装する」プロジェクトのドキュメントサイトだけ Python なのは筋が悪い。
2. **mdBook（Rust）** — 単一バイナリで速いが、`cargo` の導入が要る（`--rust` プロファイル）。
   `SUMMARY.md` を手で維持する必要があり、タスクが増えるたびに衝突する。
3. **GitHub の Markdown 表示をそのまま使う** — 検索・目次・サンプルの公開ができない。
4. **Jekyll（Pages の既定）** — `_config.yml` とプラグインの挙動に依存し、
   ローカルで同じ出力を再現しにくい。`.nojekyll` で無効化した。
5. **サンプルは別ブランチ `gh-pages` に push** — 生成物のコミットが増える。
   `upload-pages-artifact` ならリポジトリを汚さない。

## 4. 結果

- `https://umiturtle.github.io/Z-Ts/` に「ドキュメント + 動くサンプル」が 1 つのサイトとして載る。
- `zig build docs` は 67 ページ・162 リンクを検証して 2 秒以内（コールドでも 1 分弱）。
- サイドバーはファイル一覧から自動生成されるので、**ADR やタスクを足すだけで目次が更新**される。
- 検索はサーバ無し（`search-index.js` を読み込むだけ）。
- **残課題**: サイト内の画像（スクリーンショット）はまだ無い。`M5-04` の PNG を
  Pages に載せるには、CI の artifact をサイトへ取り込む工程が必要（次の増分）。
