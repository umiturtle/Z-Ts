# ドキュメント索引

> **対象読者**: 次にどのページを読むか決めたい人。名前から引きたい人。
> **所要時間**: 目次として 30 秒。

公開サイト（<https://umiturtle.github.io/Z-Ts/>）の**サイドバーと同じ並び**で並べた索引です。
サイトでは `/` キーで全文検索、右上の `日本語 / English` で言語を切り替えられます。

**10 分だけあるなら** → [はじめての ziggurats](learn/ja/start.md)。
読み物として全体像から入るなら → [ziggurats を学ぶ（学習パス）](learn/ja/index.md)。

## 3 つの入口

ziggurats には読者が 3 種類いて、使うコマンドもページも別です。混ぜると、アプリを作りたい人に
リポジトリ運用の手順が、本体を直したい人にアプリの使い方が見えてしまいます。

| あなたは | 入口 | 使うコマンド |
|---|---|---|
| **アプリを作りたい** | [はじめての ziggurats](learn/ja/start.md) → [学習パス](learn/ja/index.md)（英語は [`learn/en/`](learn/en/index.md)） | `zts`（`init` / `dev` / `build` / `package` / `doctor`） |
| **名前から引きたい** | [API リファレンス](api/index.html) / [用語集](glossary.md) / [エラー索引](reference/errors.html) | — |
| **ziggurats 本体を開発したい** | [コントリビュータ向け](contributing/README.md) → [リポジトリの地図](contributing/repository-map.md) | `zig build` / `scripts/*` |

## 学習パス（5 ステップ・およそ 95 分）

サイトのランディングと各ページ上部のレールに出ている道順と同じです。順番を飛ばすのも自由ですが、
飛ばした分だけ後のページで用語を引き直すことになります。

| # | ステップ | 分 | 終わったとき | 入口 |
|---|---|---|---|---|
| 1 | はじめての ziggurats | 10 | 自分のアプリがブラウザで動き、`zig-out/bin/` に単一バイナリがある | [start.md](learn/ja/start.md) |
| 2 | 仕組みを知る | 15 | 「ボタン → Zig の関数」がどこを通るか説明できる | [concepts/](learn/ja/concepts/index.md) |
| 3 | アプリを作る | 50 | 3 本のチュートリアルを通し、コマンド・状態・画面を書いて配れる | [tutorials/](learn/ja/tutorials/index.md) |
| 4 | 実用パターン | 20 | コマンド・状態・エラーの設計を、練習問題で自分の言葉にできる | [patterns/](learn/ja/patterns/index.md) |
| 5 | 目的から引く | — | やりたいことから必要なページに 1 ホップで行ける | [guides/](learn/ja/guides/index.md) |

**英語版は 2 方式で並んでいます。** 学習ツリーは `learn/en/` に同じファイル名、
それ以外のページ（用語集・リファレンス・サンプル・開発者向け）は同じ場所に
`<名前>.en.md` を置きます。どちらも言語切替はパスの置換だけで済み、
`check-docs.py` の規約 8・13 が「片方にしか無いページ」を落とします。
内部資料（ADR・設計メモ・タスク票）だけは日本語専用です。

---

## サイトの並び

### 学習パス

| ページ | 1 文でいうと |
|---|---|
| [ziggurats を学ぶ](learn/ja/index.md) | 道順・30 秒の全体像・前提知識・目的別の入口。まずここから |

### 1 · はじめての ziggurats

| ページ | 1 文でいうと |
|---|---|
| [はじめての ziggurats](learn/ja/start.md) | バイナリを置く → `doctor` → `init` → `dev` → `build` を 1 ページで（10 分） |

### 2 · 仕組みを知る

| ページ | 1 文でいうと |
|---|---|
| [概念](learn/ja/concepts/index.md) | 3 つの登場人物（ページ / ブリッジ / コマンド）で全体を言い直す |
| [パッケージ構成](learn/ja/concepts/architecture.md) | 6 つの層が 1 方向にだけ依存する。どこに何を書くか |
| [コマンドが届くまで](learn/ja/concepts/commands.md) | `invoke` が Zig の関数になるまで。`Schema` の役割と型検査 |
| [プラグイン](learn/ja/concepts/plugins.md) | Tauri 標準の 7 プラグインと `withCorePlugins` |
| [セキュリティ](learn/ja/concepts/security.md) | 既定は拒否。capability・scope・CSP と、守らないこと |

### 3 · アプリを作る

| ページ | 1 文でいうと |
|---|---|
| [チュートリアル](learn/ja/tutorials/index.md) | 手を動かす章の入口。3 本の順番・進め方・前提 |
| [カウンターを作る](learn/ja/tutorials/counter.md) | `zts init` → コマンド → 画面 → `dev` → `build` → `doctor`（15 分） |
| [Todo リストを作る](learn/ja/tutorials/todo.md) | 構造体に閉じた状態、3 つのコマンド、`error{}` の返し方とテスト（20 分） |
| [画面を作る](learn/ja/tutorials/ui.md) | 読み込み中 / 空 / エラーを出し分ける画面、CSS 差し替え、CSP（15 分） |

### 4 · 実用パターン

| ページ | 1 文でいうと | 練習 |
|---|---|---|
| [実用パターン](learn/ja/patterns/index.md) | 動くコードを、壊れにくい形にする。章の早見表 | — |
| [コマンドの設計](learn/ja/patterns/commands.md) | 粒度・引数・戻り値・命名。動詞 1 つ = コマンド 1 つ | 3 問 |
| [状態の置き場所](learn/ja/patterns/state.md) | 正しさが要るなら Zig、見た目だけならフロント | 2 問 |
| [エラーの設計](learn/ja/patterns/errors.md) | `error{}` の粒度、境界での検証、UI に出す翻訳 | 3 問 |
| [画面とロジックの境界](learn/ja/patterns/boundaries.md) | `$try` と throw の使い分け、楽観更新、二重送信 | 2 問 |

### 5 · 目的から引く

| ページ | 1 文でいうと |
|---|---|
| [ガイド](learn/ja/guides/index.md) | やりたいことから引く索引。全部読む必要はない |
| [`zts` を手元に用意する](learn/ja/guides/install.md) | 配布バイナリ・`PATH`・`ZTS_ZIG`・ソースからのビルド |
| [コマンドを書く](learn/ja/guides/rpc.md) | `zts_rpc`: コマンド定義 → `Schema` → `bind` → `dispatch` → TypeScript 生成 |
| [Tauri 標準プラグイン](learn/ja/guides/plugins.md) | window / event / path / fs / dialog / clipboard / menu / tray と capability |
| [静的サイトを書き出す](learn/ja/guides/static-site.md) | `exportStaticSite` と WASM。サーバ不要の `dist/` |
| [配布物を作る](learn/ja/guides/package.md) | `zts package`: `.deb` / AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz` |
| [Tauri v2 からの移行](learn/ja/guides/migrate-from-tauri.md) | `tauri.conf.json`・ACL・コマンド・プラグインの対応表 |
| [トラブルシューティング](learn/ja/guides/troubleshooting.md) | `zts` のエラーと、その直し方 |

### リファレンス

| ページ | 1 文でいうと |
|---|---|
| [用語集](glossary.md) | Pack・Host・Capability など、本文に出てくる言葉の定義 |
| [`zts` コマンドリファレンス](reference/cli.md) | アプリ作者が使う CLI の全コマンドと全フラグ |
| [Tauri v2 の使い方](reference/tauri-usage.md) | 上流 Rust/JS API・設定・Capabilities の対応 |
| [エラー索引](reference/errors.html) | `error{…}` の名前から定義元へ（自動生成） |

### API

`///` から自動生成される API リファレンスです（**手で編集しない**。`zig build docs` が出力）。
サイトでは全パッケージの公開宣言を、パッケージ別と名前順の両方から引けます。

| 入口 | 中身 |
|---|---|
| [全体索引（A–Z）](api/index.html) | すべての公開宣言を名前順に |
| [`zts_foundation`](api/zts_foundation/index.html) | 依存ゼロのデータ構造（`OwnedBytes` / `HandlePool` / geometry / glob） |
| [`zts_web`](api/zts_web/index.html) | 静的資産配信（206 Range / MIME / URL / CSP） |
| [`zts_core`](api/zts_core/index.html) | 基盤型・世代プール・Host 契約 |
| [`zts_rpc`](api/zts_rpc/index.html) | comptime JSON/Binary RPC ルータと TypeScript 生成 |
| [`zts_bridge`](api/zts_bridge/index.html) | HTTP/1.1 + SSE のライブサーバ |
| [`zts_webview`](api/zts_webview/index.html) | GTK3+WebKit2GTK / Cocoa / Win32 / HeadlessMock |
| [`zts_tauri`](api/zts_tauri/index.html) | Tauri v2 プロトコルと標準プラグイン |
| [`zts_wasm`](api/zts_wasm/index.html) | wasm32-freestanding ランタイム |
| [`zts_ssg`](api/zts_ssg/index.html) | `dist/` の書き出しと `dist/ → Zig` の埋め込み |
| [`z_ts`](api/z_ts/index.html) | 全パッケージを束ねる入口（`@import("z_ts")`） |

### サンプル

どれも CI が 3 OS でビルドし、スクリーンショットを相互比較しています。

| ページ | 1 文でいうと |
|---|---|
| [Counter](../examples/counter/README.md) | 1 プロジェクト → デスクトップ / Live Preview / 静的 SSG の 3 成果物 |
| [フレームワーク 9 種](../examples/frameworks/README.md) | Angular / Solid / Svelte / SolidStart / Next / Nuxt / Astro / SvelteKit / React が同じ画面 |
| [ギャラリー](../examples/gallery/README.md) | 17 パターンのスクリーンショット回帰（PNG + `manifest.json`） |
| [C 埋め込み](../examples/c_embed/README.md) | 純粋な C99 ホストへ Overlay 埋め込み（Zig のコードは 0 行） |

### リポジトリ開発

| ページ | 1 文でいうと |
|---|---|
| [ziggurats 自体を開発する](contributing/README.md) | ツールチェーン・`zig build` のステップ・変更の作法・CI |
| [リポジトリの地図](contributing/repository-map.md) | どのファイルが何で、どのくらい触るか（並列開発の分割単位） |
| [トラブルシューティング（リポジトリ開発）](contributing/troubleshooting.md) | ツールチェーン・コールドビルド・0.17 API 差分・Pages |
| [ドキュメント同期台帳](contributing/doc-sync.md) | いつ最終書き換えか・どのバージョンまで実装と無矛盾を確認したか |
| [ドキュメントの書き方](contributing/writing-docs.md) | 4 層・ページ骨格・`zig check`・注記・用語集・内部 ID 禁止・生成物 |

### 内部資料

サイトのサイドバーでは **[設計メモ・ADR・タスク](architecture/00-overview.md)** の 1 エントリに
畳んであります（読者が順に読むものではないため）。実装の意図と経緯を調べるときだけ開いてください。

| 置き場所 | 中身 |
|---|---|
| [`architecture/`](architecture/00-overview.md) | なぜこの構成なのか（依存 DAG・境界契約・各サブシステム設計） |
| [`decisions/`](decisions/0001-zig-017-and-sharded-agent-workflow.md) | アーキテクチャ意思決定記録（ADR）。新しいファイルを足すだけ |
| [`roadmap/milestones.md`](roadmap/milestones.md) | M0〜M5 のマイルストーンと並列 Wave の依存マップ |
| [`tasks/`](tasks/TEMPLATE.md) | 1 タスク = 1 ファイルの作業計画と記憶チェックポイント |
| [`environment/`](environment/arena-and-caching.md) | Arena のキャッシュ・GitHub Actions の運用 |
| [`reference/tauri-internals.md`](reference/tauri-internals.md) | IPC プロトコル・マクロ・内蔵プラグインの解剖（移植の参考・内部資料扱い） |
| [`decisions/0018-documentation-site.md`](decisions/0018-documentation-site.md) | このサイト自体の設計（4 層・リンク検査・検索・`llms.txt`） |

## 名前から引く

| 探したいもの | どこで |
|---|---|
| 言葉の意味 | [用語集](glossary.md)（本文から随時リンクしている） |
| エラー名 | [エラー索引](reference/errors.html)（`src/**` の `error{…}` から自動生成） |
| 関数・型・定数 | [API 全体索引](api/index.html)（`///` から自動生成） |
| コマンドとフラグ | [`zts` コマンドリファレンス](reference/cli.md) |
| ページ全体 | サイトの検索（`/` キー）。索引データは `assets/search-index.js` |
| 機械可読な目次 | サイト直下の `llms.txt`（全文は `llms-full.txt`） |

> **この索引の保守**: サイドバーの並びは [`src/docsite/main.zig`](../src/docsite/main.zig) の
> `GroupKey`、学習パスの番号と所要分は [`src/docsite/learn_path.zig`](../src/docsite/learn_path.zig)
> が正本です。ページを足したら、このページにも 1 行足してください。**足し忘れは
> `check-docs.py` の規約 11 が落とします**（この索引は日本語版、
> [`INDEX.en.md`](INDEX.en.md) は英語版の全ページをリンクしているかを検査）。
> リンク切れと「`learn/ja` と `learn/en` のファイル名の不一致」も同じスクリプトが見ています。
> 左メニューの並びは両言語・全ページで共通（`GroupKey.order()` は言語を取りません）。
> 章内の読み順は `learn_path.zig` の `page_order`、所要分は `steps` が正本で、
> **規約 12** がこのページ・`README.md`・日英の学習ハブに書いた分と突き合わせます。
> **規約 13**（[同期台帳](contributing/doc-sync.md)）が「いつ最終書き換えか」「どのバージョンまで
> 実装と無矛盾を確認したか」を日英 1 組ずつ記録し、本文・実装のハッシュのズレを落とします。
> **規約 14** が、フルネーム `ziggurats`（小文字）と、リポジトリ URL / パスにだけ残る旧称の
> 使い分けを検査します。`zts` / `z_ts` / `zts_*` は識別子なので対象外です。
