# ガイド — ライブラリの使い方（Learning Path）

ここは **Z-Ts を使ってアプリを作る人**のための道筋です。コマンドは `zts` だけで、
`./zigw` や CI の話は出てきません（それらは [`../contributing/`](../contributing/README.md)）。

**このライブラリを使うのに、内部資料を読む必要はありません。** 下の 3 層だけで完結します。
「なぜそう作ったか」は 4 層目（内部資料）に隔離してあり、ナビゲーションの最後に 1 つだけ
入口があります。読まなくても壊れません。

```text
① 学ぶ（Learn）        はじめかた → ガイド 8 本        … 手順と最小例。まずここ
② 引く（Reference）    API リファレンス（自動生成）    … シグネチャ・型・/// ドキュメント
③ 確かめる（Spec）     リファレンス（CLI / Tauri 対応表）… 振る舞いの約束事
────────────────────────────────────────────────────────────
④ 中を読む（Internals）設計メモ・ADR・タスク・環境     … 実装の意図と経緯。任意
```

## 1. 何を読みたいかから引く

| 知りたいこと | 読む場所 | 層 |
|---|---|---|
| `zts` コマンドを手に入れたい | [`installing-zts.md`](installing-zts.md) | ① |
| とにかく動かしたい | [`getting-started.md`](getting-started.md) | ① |
| 作ったアプリを配布したい（`.deb` / `.app` / `.exe`） | [`packaging.md`](packaging.md) | ① |
| コマンドの全オプション | [`../reference/cli.md`](../reference/cli.md) | ③ |
| コマンド（`invoke`）を書きたい | [`using-rpc.md`](using-rpc.md) | ① |
| Tauri 標準プラグインを使いたい | [`using-plugins.md`](using-plugins.md) | ① |
| `dist/` に静的サイトを出したい | [`using-ssg.md`](using-ssg.md) | ① |
| Tauri v2 のプロジェクトから移したい | [`migrating-from-tauri.md`](migrating-from-tauri.md) | ① |
| 動かない / エラーが出た | [`troubleshooting.md`](troubleshooting.md) | ① |
| この関数の引数は？ 戻り値は？ | [API リファレンス](https://umiturtle.github.io/Z-Ts/docs/api/index.html)（`./zigw build docs` で手元にも生成） | ② |
| API ページの読み方が分からない | [`using-the-api-reference.md`](using-the-api-reference.md) | ② |
| `@tauri-apps/api` のどの関数が動く？ | [`../reference/tauri-usage.md`](../reference/tauri-usage.md) | ③ |
| Z-Ts リポジトリ自体を開発する | [`../contributing/README.md`](../contributing/README.md)（層の外） | — |
| `./zigw` と `zig build` のステップ一覧 | [`../contributing/README.md`](../contributing/README.md) §3（層の外） | — |
| なぜこの設計なのか | [`../internals/`](https://umiturtle.github.io/Z-Ts/docs/internals/index.html)（`docs/decisions/`・`docs/architecture/`） | ④ |

## 2. 3 つの層の役割（重複は許すが、矛盾は許さない）

同じ事実が複数の層に出てくることはあります（例: `Schema.bind` の呼び方はガイドと API ページの
両方にある）。**重複は許容、矛盾は禁止**です。層ごとに「正本」を決めてあります。

| 層 | 正本（source of truth） | 書き方 | 書かないこと |
|---|---|---|---|
| ① ガイド | 手順と最小例 | 「この順でこう書く」。動くコードを先に、理屈は後 | 内部の構造・当時のトレードオフ |
| ② API | **Zig のソースそのもの**（`///` から生成） | 宣言・型・不変条件を 1〜3 文で | チュートリアル・長い経緯 |
| ③ 仕様 | 振る舞いの約束（wire format、ACL の判定、CLI の引数） | 表と規則。実装に依存しない言い方 | 「なぜ」の議論 |
| ④ 内部 | ADR・設計メモ・タスク・環境ノート | 日付・制約・却下した案 | 利用者向けの手順 |

守っていること:

* ガイドは**内部資料に依存しない**。内部資料へリンクするときは必ず「内部資料」と明示する。
* API ページは**公開モジュールだけ**を A–Z 索引と検索に出し、FFI バインディング
  （`gtk_bindings.zig` / `win32.zig` / `webview2_com.zig` など）と契約テストは
  「内部モジュール」として折り畳む。文書化率の計算からも外す。
* 内部資料はサイドバーの最後に **1 エントリ**だけ。個別ページにバナーを出し、検索索引には
  入れない（学習中の読者の検索結果を開発メモで埋めない）。
* 実装の意図を API の `///` に書かない。`///` は「何をするか・何を渡すか・何が返るか」だけ。

## 3. ガイドの一覧

| ガイド | 内容 | 前提 |
|---|---|---|
| [`installing-zts.md`](installing-zts.md) | `zts` をビルドして `PATH` に置く、`ZTS_ZIG`、プラットフォーム前提 | なし |
| [`getting-started.md`](getting-started.md) | 5 分で `zts init` → `dev` → `build` → `doctor` | `zts` |
| [`packaging.md`](packaging.md) | `zts package` で配布物を作る（6 形式・アイコン・クロスビルド・CI） | アプリが 1 つ動く |
| [`using-rpc.md`](using-rpc.md) | `rpc.Schema` → `Schema.bind` → `handler()`、引数 3 形式、`tsgen` | Zig の基本 |
| [`using-plugins.md`](using-plugins.md) | 7 プラグインの入口、`CorePluginStates`、capability（ACL） | `using-rpc.md` |
| [`using-ssg.md`](using-ssg.md) | `embedFrontend` → `exportApp` → `exportStaticSite`、`ExportOptions` | アプリが 1 つ動く |
| [`migrating-from-tauri.md`](migrating-from-tauri.md) | Rust → Zig の対応表、`tauri.conf.json`、capabilities | Tauri v2 の経験 |
| [`troubleshooting.md`](troubleshooting.md) | `zts` のエラーメッセージ別の対処 | なんでも |

## 4. 内部資料を読みたくなったら

* [`../internals/`](https://umiturtle.github.io/Z-Ts/docs/internals/index.html) — 公開サイトの内部資料ハブ
* リポジトリ内: [`../decisions/`](../decisions/)（設計判断）/ [`../architecture/`](../architecture/)
  （サブシステム設計）/ [`../tasks/`](../tasks/)（作業記録）/ [`../roadmap/`](../roadmap/) /
  [`../environment/`](../environment/)

内部資料は**他のエージェントと将来の自分**のために残しています。読者のために書かれたものでは
ないので、古い記述が残っていることがあります（当時の制約を記録しているため）。矛盾を見つけた
ら、利用者向けの ①〜③ を正とし、④ を直してください。
