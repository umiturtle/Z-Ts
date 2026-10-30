# ドキュメントサイト（`M5-06`）

`docs/**/*.md` を **リポジトリ自身の Zig コードで** HTML に変換し、GitHub Pages で公開します。
Markdown は唯一の正本（single source of truth）で、サイトはその写像にすぎません。リンク切れは
**生成時に落ちる**ので、壊れたドキュメントが公開されることはありません。

```text
docs/**/*.md ─┐
README.md     ├─> zts_docsite ──> dist/
AGENTS.md     │    ├─ markdown.zig（レンダラ）      ├─ index.html（ランディング）
examples/*/   ┘    ├─ site.zig（シェル・リンク検査）  ├─ docs/**/*.html
                   └─ demos.zig（サンプル公開）       ├─ examples/frameworks/<name>/
                                                      ├─ assets/{site.css,site.js,search-index.js}
                                                      └─ .nojekyll
```

## 1. なぜ自前でレンダリングするのか

1. **依存ゼロ**: コールドスタートのコンテナでも `./zigw build docs` が 2 秒で終わる。
   Node / Pandoc / MkDocs を入れると CI のたびに数十秒のセットアップが要る。
2. **ドッグフーディング**: このプロジェクトの売りは「Zig だけで Web 資産を組み立てる」こと。
   ドキュメントサイトを Vite で作るのは整合しない。`std.compress` で gzip 双子を作る
   `M5-01` エンベッダと同じ精神で、`zts_docsite` は `std` だけでテキストを処理する。
3. **検証できる**: レンダラは純粋関数なので単体テストが書ける（**28 テスト**）。CI では
   リンク検査が生成の一部として走る。

## 2. レイアウトはリポジトリ構造をそのまま写す

ページ `docs/tasks/M5-01-build-tools.md` は `docs/tasks/M5-01-build-tools.html` になる。
これを守ると、**リポジトリ内の相対リンクがそのまま動く**（`../architecture/build-tools.md` →
`../architecture/build-tools.html`）。書き換えるのは拡張子だけなので、GitHub 上と Pages 上で
リンクの意味が変わらない。

例外的に、サイトに含まれないファイル（`src/**.zig`、`.github/workflows/ci.yml` など）への
リンクは **GitHub の blob URL** に置き換える。`markdown.Rewrite` を使ってページ単位で指定する
ので、レンダラ本体は「リンクをどう扱うか」を知らないままにできる。

## 3. リンク検査

* 相対リンクのみを対象にする（`http(s)://`、`mailto:`、`#anchor` は除外）。
* 対象は「これから書き出すページの集合」。存在しない → `error.BrokenLinks`。
* 1 回目の描画で壊れていたリンクのうち、**リポジトリに実在するファイル**へのものは GitHub の
  URL に差し替えて**そのページだけ再描画**し、もう一度検査する（2 パス）。実在しないものは
  そのまま失敗させる。

```text
docsite: 2 broken link(s)
  docs/INDEX.html: ../nope.md -> docs/nope.html
```

Markdown のリンクに加えて、**生成した HTML の `src=` / `href=` を全部**書き出しツリーと突き合わせる
（`assets=…` がその件数）。テンプレートやサンプルの `url(...)` は Markdown のリンク検査では
見えないので、Pages で 404 になる前にここで落とす。Nuxt の `_payload.json` だけは既知の欠落として
除外している。

## 4. サイドバー・検索・テーマ

* **サイドバー**: グループ順は固定（はじめに → ロードマップ → アーキテクチャ → 決定（ADR）→
  リファレンス → 環境 → タスク → サンプル）。各グループ内はソースパス順なので、**新しい
  ADR やタスクを足すだけで自動的に並ぶ**（手で索引を更新する必要はない）。
* **検索**: `assets/search-index.js` に `window.ZTS_SEARCH = [{u,t,g,x}, …]` を書き出し、
  `site.js` が前方一致 → 部分一致の順で絞り込む。サーバもインデックス生成ツールも要らない。
  本文は 1 ページ 4000 文字まで（UTF-8 境界を割らない位置で切る）。
* **テーマ**: `localStorage` の `zts-theme` を `<head>` のインラインスクリプトで先に適用して
  から CSS を読むので、ダークモードで一瞬白く光らない。JS 無効時は `prefers-color-scheme`。
* **アンカー**: GitHub と同じ slug（小文字化・空白は `-`・句読点は削除・**CJK は保持**）を
  生成するので、`#設計判断` のような日本語アンカーも GitHub と Pages で一致する。

## 5. サンプルの公開

| 何を | どこから | 変換 |
|---|---|---|
| カウンターの SSG 出力 | `examples/counter/zig-out/dist/`（CI でビルド） | そのまま（元から相対パス） |
| 9 フレームワークのデモ | `examples/gallery/src/web/fw/<name>/`（**コミット済み**） | 絶対 URL を相対 URL へ書き換え |
| フォント | `examples/gallery/src/web/fonts/*.woff2` | `examples/frameworks/fonts/` に 1 部だけ |

ギャラリーはカスタムスキームのルート（`tauri://localhost/fw/react/`）で配信するため、各デモの
HTML は `/assets/…` `/zts/fonts/…` のような**絶対パス**を持つ。GitHub Pages は `/Z-Ts/` という
サブパスで配信するので、そのままではリポジトリの外を指して 404 になる。`demos.zig` は

* `="/…`・`:"/…`・`url(/…` の先頭スラッシュを落とし、
* `/zts/fonts/…` だけは 1 つ上の共有ディレクトリ（`../fonts/…`）へ向け、
* `href="/"` は `href="./"`（デモの外へ出ない）、

という規則で書き換える。`//cdn…` や `https://…` は触らない。この関数は純粋なので単体テストで
固定してある（**8 テスト**）。Nuxt の `/_payload.json` は静的に書き出されないため 404 になるが、
SSR 済みの DOM で描画される（既知の挙動として [`../../examples/frameworks/README.md`](../../examples/frameworks/README.md)
に記載）。

## 6. 公開フロー（`.github/workflows/pages.yml`）

```text
push to main ──> build ──> ./zigw build docs            (リンク検査込み)
                        ├─ cd examples/counter && ../../zigw build dist
                        ├─ _site = docs + examples/counter + examples/frameworks
                        └─ upload-pages-artifact ──> deploy-pages
```

* `OK docsite pages=… links=… assets=… words=… demos=…` マーカーが出なければジョブは失敗する
  （＝ページが 0 枚でも「成功」しない）。
* `.nojekyll` を置くので Jekyll の処理は走らない（`_zts/` のようなアンダースコア始まりの
  ディレクトリもそのまま配信される）。
* サイトは `https://umiturtle.github.io/Z-Ts/` に公開される。
* **初回だけリポジトリ設定が必要**: Settings → Pages → Build and deployment → Source を
  **GitHub Actions** にする（Pages API は Bot トークンからは叩けないので、リポジトリ管理者が
  1 回だけ設定する）。未設定のまま `main` に push すると deploy ジョブが
  `Get Pages site failed` で止まる — ビルド自体は成功しているので、設定後に再実行すればよい。

## 7. ローカルで確認する

```bash
./zigw build docs              # zig-out/docs/ に生成
./zigw quick-test              # レンダラ + シェルの単体テスト（28 本）
./zigw build docs --summary all
```

生成物は静的ファイルだけなので、`python3 -m http.server --directory zig-out/docs` で
そのまま確認できる（`file://` でも動くが、ブラウザの制約で検索インデックスの読み込みに
失敗することがある）。
