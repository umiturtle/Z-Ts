# ドキュメントサイト（`M5-06` / `M5-07`）

`docs/**/*.md` を **リポジトリ自身の Zig コードで** HTML に変換し、GitHub Pages で公開します。
Markdown は唯一の正本（single source of truth）で、サイトはその写像にすぎません。リンク切れは
**生成時に落ちる**ので、壊れたドキュメントが公開されることはありません。

`M5-07` で 2 つ足りませんでした。**読者向けの API リファレンスが無い**こと、そして
**サイトの主役が実装メモだった**ことです。前者は `apidoc.zig`（ソースから生成）、
後者はナビゲーションの再編で解決しました。判断の記録は
[`../decisions/0019-api-reference.md`](../decisions/0019-api-reference.md)。

```text
docs/**/*.md ─┐
README.md     ├─> zts_docsite ──> dist/
AGENTS.md     │    ├─ markdown.zig（レンダラ）      ├─ index.html（ランディング）
examples/*/   ┘    ├─ site.zig（シェル・リンク検査）  ├─ docs/**/*.html
src/**.zig ──────> ├─ apidoc.zig（API 生成）        ├─ docs/api/**/*.html（90 ページ）
                   └─ demos.zig（サンプル公開）       ├─ docs/internals/index.html
                                                      ├─ examples/frameworks/<name>/
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

さらに `M5-07` で**アンカー検査**を足した。出力ツリーの全ページから `id="…"` を先に集め、
`page.html#anchor` のアンカーが実在するかまで見る（`error.DanglingAnchors`）。
API ページへ `#Schema` で飛ぶリンクは、宣言名を間違えると**ビルドが落ちる**。

```text
docsite: 1 anchor(s) point at nothing
  docs/guides/using-rpc.html: ../api/zts_rpc/schema.html#SchemaTypo
```

出力ディレクトリは毎回**消してから**書き出す。`verifyAssets` は「ディスクにあるもの」を歩くので、
前回の残骸があるとリンク検査の意味が変わる（古いページは検査されず、消えたファイルを指す
新しいページは誤検知になる）。

## 4. API リファレンス生成（`apidoc.zig`）

**読者向けのページは `docs/*.md` だけでは作れない** — シグネチャはソースにしかないからです。
`apidoc.zig` は `build.zig` のモジュール表と同じ 10 パッケージについて、
**ルートファイルから相対 `@import("….zig")` を辿って**ファイル集合を決め（手書きの一覧を持たない）、
各ファイルを次の規則で走査します。

| 対象 | 取り出し方 |
|---|---|
| モジュールドキュメント | 先頭の `//!` 行 |
| 宣言 | ブレース深さ 0 の `pub fn` / `pub const` / `pub var` / `pub usingnamespace` |
| 型のメンバ | `pub const X = struct/enum/union/opaque { … }` の本体、深さ 1（`pub` の無い **struct フィールド**と enum ケースも含む） |
| ドキュメント | 宣言の直上に連続する `///` |
| シグネチャ | 宣言の先頭から、括弧・ブレースの外側で `{` か `;` に当たるまで（複数行は 1 行に畳む） |
| ソース位置 | 宣言の行番号 → GitHub の `blob/main/<path>#L<n>` |

Zig のパーサは書きません。**文字列リテラル・文字リテラル・行コメントを追跡してブレースを数える**
だけの行スキャナです。意味解析は `zig build test` の仕事で、ドキュメント生成に必要なのは
宣言の「形」だけだからです。

描画は 3 層です。

```text
docs/api/index.html            10 パッケージの表 + 全宣言の A–Z 索引
docs/api/<pkg>/index.html      モジュール一覧・宣言数・ドキュメントコメントのカバレッジ
docs/api/<pkg>/<slug>.html     //! → 宣言ごとに シグネチャ / ドキュメント / メンバ / ソース行
```

`<slug>` は**パッケージ内の相対パス**（`tray/mod`, `fs/mod`, `codec`）です。basename を使うと
`src/tauri/` にある 6 つの `mod.zig` が 1 ページに潰れます（実際に潰れました）。

ドキュメントコメントは Markdown として描画するので、`# Parameters` 節もフェンス付きの例も
そのまま効きます。コメント中の相対リンク（`codec.zig` など）は**ソースファイルを指す**ので、
サイトのページではなく GitHub の blob URL に解決します。

**再エクスポート**（`pub const Ctx = ctx.Ctx` / `= @import("codec.zig")`）は「未文書」ではなく
「定義元にドキュメントがある」として扱い、カバレッジの分母からも外します。

### 4.1 公開モジュール / 内部モジュール

`audienceOf()` が各ファイルを 2 つに分けます。

| | 例 | 扱い |
|---|---|---|
| 公開（`.user`） | `mod.zig` / `codec.zig` / `schema.zig` / `c_api.zig` / `fs/scope.zig` | A–Z 索引・検索・文書化率に載る |
| 内部（`.internal`） | `gtk_bindings.zig` / `win32.zig` / `webview2_com.zig` / `webview2_loader.zig` / `windows_util.zig` / `*_test.zig` | パッケージページで `<details>` に**折り畳む**。ページ自体は生成する（埋め込み側が必要とする）が、見出しに「内部実装」バナー、検索索引と文書化率からは除外 |

`win32.zig` だけで 142 宣言、`gtk_bindings.zig` で 69 宣言あります。これを読者の索引に並べると
「学ぶためのページ」ではなく「リポジトリの写像」に戻ってしまうので、数値と一覧から外しました。
除外した件数は `api_internal=…` としてビルドログに出るので、**隠しているのではなく分けている**
ことが検証できます（内部側の文書化率も別枠で数えています）。

### 4.2 モジュールページの「読み込み 1 行」と数え方

モジュールページの冒頭には、そのまま貼れる 1 行を出します。

```zig
const window = @import("zts_tauri").window;
```

ルートの `pub const fs = @import("fs/mod.zig");` を 1 段ずつ辿って `zts_tauri.fs.scope` の
ような深いパスも解決します（`importAlias`）。型の再エクスポート（`@import("ctx.zig").Ctx`）は
モジュールではないので追いません。**どの再エクスポートからも届かないファイルには行を出しません**
（コンパイルできない import 行を書かないため）。

文書化率は **宣言** と **型メンバ** を別々に数えます。`WindowConfig` は宣言 1 件 + メンバ 24 件で、
合算すると「全宣言に `///` があるのに 24%」と読めてしまうためです。合計が 0 でない状態
（`api_undoc`）は CI が落とします。

## 5. サイドバー・検索・テーマ

* **サイドバー**: グループ順は固定（**はじめに → ガイド → API → サンプル → 内部資料**）。
  読者の動線を先に置き、実装意図（ADR・タスク・設計メモ・ロードマップ・環境・`AGENTS.md`）は
  **`内部資料` の 1 エントリに畳む**。個別ページは公開したままなので、既存のリンクは壊れない。
  * 内部ページの先頭には「内部資料」バナーを出し、読者向けの入口（ドキュメント索引 / API）を示す。
  * `docs/internals/index.html` が全内部資料をティーザー付きで一覧する（行き止まりを作らない）。
  * `AGENTS.md` と `docs/reference/tauri-internals.md` も内部資料扱い（前者はエージェント向け、
    後者は実装の解剖）。
* **検索**: `assets/search-index.js` に `window.ZTS_SEARCH = [{u,t,g,x}, …]` を書き出し、
  `site.js` が前方一致 → 部分一致の順で絞り込む。サーバもインデックス生成ツールも要らない。
  本文は 1 ページ 4000 文字まで（UTF-8 境界を割らない位置で切る）。
  **内部資料は索引に入れない**（読者の検索を開発メモで埋めない）。内部モジュールのページ
  （`gtk_bindings` / `win32` / `*_test`）と、内部モジュールを指す再エクスポート
  （`mod.webview2_com`）も索引から外す — ページを隠しておいて検索から差し出さない。代わりに
  **API の宣言 1 件ずつ**を索引に入れるので、`Schema` や `dispatch` で目的のページに飛べる。
* **テーマ**: `localStorage` の `zts-theme` を `<head>` のインラインスクリプトで先に適用して
  から CSS を読むので、ダークモードで一瞬白く光らない。JS 無効時は `prefers-color-scheme`。
* **アンカー**: GitHub と同じ slug（小文字化・空白は `-`・句読点は削除・**CJK は保持**）を
  生成するので、`#設計判断` のような日本語アンカーも GitHub と Pages で一致する。

## 6. サンプルの公開

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

## 7. 公開フロー（`.github/workflows/pages.yml`）

```text
push to main ──> build ──> ./zigw build docs            (リンク検査込み)
                        ├─ cd examples/counter && ../../zigw build dist
                        ├─ _site = docs + examples/counter + examples/frameworks
                        ├─ Pages の有無を確認（必要なら作成を試みる）
                        └─ upload-pages-artifact ──> deploy-pages（main のみ）
```

* `OK docsite pages=… links=… assets=… words=… demos=…` マーカーが出なければジョブは失敗する
  （＝ページが 0 枚でも「成功」しない）。
* `.nojekyll` を置くので Jekyll の処理は走らない（`_zts/` のようなアンダースコア始まりの
  ディレクトリもそのまま配信される）。
* サイトは `https://umiturtle.github.io/Z-Ts/` に公開される。
* **初回の有効化は「あれば使う / 無ければ作ってみる / 作れなければ警告」**の 3 段構え
  （`.github/workflows/pages.yml` の `Check whether GitHub Pages is enabled`）:

  | 状況 | 動作 |
  |---|---|
  | Pages が既にある | そのまま公開 |
  | 無いがトークンに作成権限がある | `POST /repos/{owner}/{repo}/pages` (`build_type=workflow`) で作成して公開 |
  | 無く、作成もできない | **ビルドは緑のまま**、`::warning::` と Job Summary で設定箇所を案内し、公開だけスキップ |

* **実測**: `GITHUB_TOKEN` は Pages サイトを**作成できない**
  （`Create Pages site failed. Error: Resource not accessible by integration`。
  作成には管理者権限が要り、`pages: write` では足りない）。したがって初回だけは
  Settings → Pages → Build and deployment → Source を **GitHub Actions** にする人手の操作が要る。
  設定後の次の `main` push で、コードを触らずに公開が始まる。
* `actions/configure-pages@v5` の `enablement: true` も同じ理由で失敗する（この
  `GITHUB_TOKEN` では `POST` が 403）。ワークフローは事前に API で状態を見てから呼ぶので、
  赤いステップや失敗アノテーションは出ない。

## 8. ローカルで確認する

```bash
./zigw build docs              # zig-out/docs/ に生成
./zigw quick-test              # レンダラ + シェルの単体テスト（28 本）
./zigw build docs --summary all
```

生成物は静的ファイルだけなので、`python3 -m http.server --directory zig-out/docs` で
そのまま確認できる（`file://` でも動くが、ブラウザの制約で検索インデックスの読み込みに
失敗することがある）。
