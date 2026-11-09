# ドキュメントの書き方（機械で守る規約）

> **対象読者**: ziggurats のドキュメントを書く・直す人（人間とエージェント）。
> **アプリを作る人は読む必要がありません** → [`../learn/ja/guides/index.md`](../learn/ja/guides/index.md)。
> なぜこの形なのか（調査と原則）は [`../architecture/docs-as-a-product.md`](../architecture/docs-as-a-product.md)。

ドキュメントが腐る原因は、ほぼ 1 つです。**書いた時点のコードと、書いた文章がずれる**。
レビューでは見つからない（レビュアーは差分しか見ない）ので、機械に見張らせます。
このページは「何を守れば `./zigw docs-check` が緑になるか」の一覧です。

```bash
./zigw docs-check      # これを 1 回打てば、下の全部が走ります（温まった状態で約 7 秒）
```

| 段 | 何を見るか | 失敗したときに出るもの |
|---|---|---|
| 1 | レンダラの単体テスト（Markdown・リンク・xref 索引） | `All N tests passed` 以外 |
| 2 | `scripts/check-docs.py` — 構造・リンク・層・CLI・パッケージ・用語集・言語パリティ | `Documentation structure check FAILED` |
| 3 | `scripts/doc-tests.py` — `zig check` フェンスを実際にコンパイル（単体では `./zigw doctest`） | `doc-tests: N of M blocks failed` |
| 4 | `zig build docs` — 生成した HTML の**リンクとアンカー**を検査 | `docsite: N broken link(s)` |

CI も同じ 4 段を回します（[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)）。
**手元で緑なら CI も緑**です。逆に CI だけ赤くなることはありません。

---

## 1. どこに書くか（4 層）

| 層 | 置き場所 | 読者 | 例 |
|---|---|---|---|
| 学ぶ | `docs/learn/ja/` と `docs/learn/en/` | アプリ作者 | [`guides/rpc.md`](../learn/ja/guides/rpc.md) / [`en/guides/rpc.md`](../learn/en/guides/rpc.md) |
| 引く | `docs/reference/`、`docs/api/`（生成）、[`../glossary.md`](../glossary.md) | アプリ作者 | [`cli.md`](../reference/cli.md) |
| 確かめる | `docs/decisions/`、`docs/architecture/` | メンテナ | [`docs-as-a-product.md`](../architecture/docs-as-a-product.md) |
| 操る | `docs/contributing/`、`docs/environment/`、`docs/tasks/` | メンテナ | このページ |

**迷ったら「アプリ作者が読むか」で決めます。** 読むなら上 2 層、読まないなら下 2 層です。
内部資料は公開サイトでは「内部資料」1 エントリに畳まれ、検索索引にも入りません
（[`../tasks/M5-09-docs-ux.md`](../tasks/M5-09-docs-ux.md) の U3）。

## 2. ページの骨格

`zig build docs` はパスから **ページ種別** を決め、パンくず・種別バッジ・前後送りを自動で付けます。
書き手がやることは 3 つだけです。

```markdown
# ページタイトル

> **対象読者**: アプリのコマンドを書きたい人
> **所要時間**: 5 分

本文。
```

`#` 見出し（H1）は **1 ページに 1 つだけ**。これがサイドバーのラベルと `<title>` になります
（`check-docs.py` の規約 7 が 2 つ目を検出）。

| 種別 | パスから決まる | バッジ |
|---|---|---|
| 概念 | `docs/learn/<lang>/concepts/*` | 概念 |
| チュートリアル | `docs/learn/<lang>/tutorials/*` | チュートリアル |
| ガイド | `docs/learn/<lang>/guides/*`、`docs/reference/*` | ガイド／リファレンス |
| レシピ | `docs/recipes/*` | レシピ |
| 移行 | `docs/learn/<lang>/guides/migrate-*` | 移行 |
| エラー | `docs/reference/errors.html`（生成） | エラー |
| API | `docs/api/**`（生成） | API |
| 内部 | それ以外（`docs/architecture/` 等） | 内部 |

`## ` 見出しは自動で目次になり、`#anchor` としてリンクできます。**見出し名を変えると
アンカーも変わる**ので、リンク元も一緒に直します。
直し忘れは段 4 が落とします。

### 学習パスに乗る・降りる

読者向けページは、**`src/docsite/learn_path.zig` の表**で決まる 5 ステップのどれかに属するのが
既定です。属し方はパスだけで決まります。

| 置き場所 | ステップ | ページ上部のレール |
|---|---|---|
| `docs/learn/<lang>/start.md` | 1 はじめての ziggurats | 出る |
| `docs/learn/<lang>/concepts/*` | 2 仕組みを知る | 出る |
| `docs/learn/<lang>/tutorials/*` | 3 アプリを作る | 出る |
| `docs/learn/<lang>/guides/*` | 4 目的から引く | 出る |
| `docs/learn/<lang>/index.md`（入口） | — | 出ない（5 ステップを本文に列挙） |
| `docs/reference/`・`docs/api/`・用語集・内部資料 | — | 出ない（引く専用） |

**新しい概念ページは `concepts/` に置けば、それだけで道順に入ります**（表の編集は不要）。逆に
`docs/learn/<lang>/` の直下に置けるのは `index.md` と `start.md` だけです。学習入口の 5 ステップ
一覧は `<!-- learn-path -->` と書くと `learn_path.zig` から展開されるので、**手で書き写さない**で
ください（同じ表がページ・サイドバー・レール・ランディングの 4 か所を駆動しています）。

## 3. 相互参照（xref）— バッククォートで書くだけ

本文中の `` `Engine` `` のようなコード表記は、**そのまま API リファレンスへのリンクになります**。

```markdown
`Handler` は `zts_rpc` の `ctx.zig` にあります。
```

- 完全修飾名（`Module.Decl` / `pkg.Decl`）が最優先、次に一意な裸の名前、曖昧な名前は**リンクしない**
  （間違ったリンクよりリンク無しのほうが良い）。
- 見出しの中では展開しません（目次が壊れるため）。同じページ内では 1 回だけ。
- 存在しない名前は**そのままコード表記**として残ります。typo を見つけたければ
  [`../glossary.md`](../glossary.md) に足してください（用語集の見出しはリンク先になります）。

## 4. 例は `zig check` でコンパイルする

**これが「実装と Doc のズレ」を止める本体です。** フェンスの情報文字列に `check` を足すと、
CI がそのブロックを `zig test --test-no-exec` に通します。書き方はこうです（3 連バッククォートの
直後に `zig check`）:

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const State = struct { count: i32 = 0 };
const Commands = struct { pub fn increment(state: *State) !i32 { state.count += 1; return state.count; } };

const Schema = rpc.Schema(.{ .app = Commands });

test "スキーマは名前空間を 1 つ持つ" {
    try std.testing.expectEqual(@as(usize, 1), Schema.namespaces.len);
}
```

| 情報文字列 | 意味 |
|---|---|
| `zig`（情報文字列がこれだけ） | 説明用。`…` を含んでよい。**コンパイルされない** |
| `zig check` | 完全なファイルとしてコンパイルする |
| `zig check-snippet` | 関数本体の断片。`std`・`zts_*` の前置きを付けて包む |
| `zig ignore` | 意図的に除外（理由を直後に 1 行書く） |

`> [!NOTE]` などの注記は**本文のどこにでも**置けます（§5）。

- 対象は `README.md`、`docs/learn/`、`docs/reference/`、`docs/glossary.md` です。
- `check` ブロックの末尾には `test { std.testing.refAllDecls(@This()); }` が自動で付きます。
  Zig は遅延解析なので、これが無いと「誰も参照していない宣言」の誤りを見逃します。
- 使えるパッケージ: `zts_foundation` `zts_web` `zts_core` `zts_rpc` `zts_bridge` `zts_tauri`
  `zts_wasm` `zts_ssg`（`zts_webview` は GTK/Cocoa のヘッダを要するため対象外）。
- **例を足すときは、まずコードを書いて `python3 scripts/doc-tests.py` に通す**のが速いです。
  落ちたら、それは API が変わったという合図でもあります。

- CI では `zig` が PATH に無いので、`./zigw doctest`（`$ZIG_BIN` を `ZTS_ZIG` として渡す）を使います。
  手元で `python3 scripts/doc-tests.py` を直接叩く場合は `zig` が PATH にあれば動きます。

> なぜ実行しないのか: 例の多くはウィンドウやイベントループを要します。`--test-no-exec` は
> **型検査とコンパイル**を行うので、改名・引数変更・削除はすべて検出できます。出力の一致まで
> 見る `// Output:` 方式は未実装です（[`../tasks/M5-09-docs-ux.md`](../tasks/M5-09-docs-ux.md) の U14）。

## 5. 注記（GitHub 互換）

```markdown
> [!NOTE]
> 補足。読み飛ばしてよい情報。

> [!WARNING]
> データを失う操作。
```

`> [!NOTE]` `[!TIP]` `[!WARNING]` `[!IMPORTANT]` の 4 種に対応しています。GitHub でも
同じ見た目で読め、サイトでは左線と見出し（注記／ヒント／注意／重要）が付きます。
それ以外の引用（`>`）は今まで通り引用として描画されます。

## 6. 用語集に足す

新しい概念を導入したら [`../glossary.md`](../glossary.md) に `### 用語` を 1 つ足します。

```markdown
### Capability

**1 文の定義。** そのあと、初出ページと実装元（API リファレンス）へのリンクを 1〜2 個。
```

- 見出しは**アンカーになる**ので重複できません（`check-docs.py` の段 6 が検出）。
- 定義の中から他の用語を `` `Code` `` で書くと、その用語の見出しへリンクされます
  （Python の用語集と同じ「相互参照する辞書」）。

## 7. 参照ページ（CLI・設定・エラー）の規約

TypeScript の `tsconfig` リファレンスに倣い、**1 項目 = 既定値 + 関連 + 導入時期**を持たせます。

```markdown
### `--release`

- **既定値**: `false`
- **関連**: [`zts build`](#zts-build)、[`--optimize`](#--optimize)
- **導入**: 0.1.0
```

- [`../reference/cli.md`](../reference/cli.md) のフラグ集合は `src/cli/args.zig` と**機械的に一致**
  させます（段 2 の規約 4）。フラグを足したらリファレンスも直す、が強制されます。
- 移行ガイドは Deno の `tsconfig` 移行に倣い、**「変更前 → 変更後」を 1 行 1 項目**の表にします
  （[`../learn/ja/guides/migrate-from-tauri.md`](../learn/ja/guides/migrate-from-tauri.md) /
  [`../learn/en/guides/migrate-from-tauri.md`](../learn/en/guides/migrate-from-tauri.md)）。
- エラーは [`../reference/errors.html`](../reference/errors.html) に自動生成されます
  （`error{…}` 集合から）。**手で書かない**でください。名前で引く導線だけを本文から張ります。

## 8. 内部 ID を読者に出さない

`///` と読者向けページ（guides / reference / glossary / README）に `ADR-0002` や `M4-03` を
書くと、段 2 が落とします。理由は「読者が引けない ID は、半年後に嘘になる」からです。

| 書きたいこと | 書く場所 |
|---|---|
| なぜこの設計なのか | `docs/decisions/ADR-….md` |
| どのマイルストーンで入ったか | `docs/tasks/M#-##-*.md` |
| どう使うか | `///`、`docs/learn/`、`docs/reference/` |

`src/docsite/` `src/cli/` `src/bundler/` `src/build_tools/` はツールなので対象外です
（公開 API ではない）。

同じ理由で、読者向けページには**リポジトリ専用の道具**も出しません。`zigw` は Releases に
含めていない（チェックアウト専用のブートストラップ）ので、読者が `./zigw build` を打つと
ファイルが無いところで止まります。読者向けページに書いてよいのは **`zts` と通常の `zig`**
だけで、`zigw` の手順は `docs/contributing/` に隔離します。`check-docs.py` の規約 10 が
`README.md`・`docs/INDEX.md`・`docs/learn/`・`docs/reference/`・`examples/*/README.md` を走査し、
`zigw` が 1 語でもあれば落とします（「`./zigw build` でビルドできます」は、いちばん最初に
踏む壊れた手順になります）。

読者向けのページを足したら、[`../INDEX.md`](../INDEX.md) と
[`../INDEX.en.md`](../INDEX.en.md) の**両方**に 1 行足します。索引はサイドバーを手で写した
ものなので、放っておくと「サイドバーにしか無いページ」ができます。規約 11 が、日本語版の
全ページ（と用語集）が日本語の索引から、英語版の全ページが英語の索引からリンクされているかを
検査します。**順番は検査しません** — 並びは `src/docsite/main.zig` の `GroupKey` が正本です。

**左メニューは全ページ・両言語で同じ並び**です。`GroupKey.order()` は言語を引数に取らず、
先頭 6 グループは「学習パスの入口 + 5 つの番号付きステップ」と決まっています。グループ内の
順番は [`src/docsite/learn_path.zig`](../../src/docsite/learn_path.zig) の `page_order`
（章の読み順）と `main.zig` の `navRank()`（索引・サンプルなど）が決めます。ファイル名の
アルファベット順は**読み順ではありません**。新しいページを足したら `page_order` に 1 行足し、
[`../INDEX.md`](../INDEX.md) にも 1 行足してください。未掲載のページは落とされず末尾に
アルファベット順で出るので、まずは追加だけでも壊れません。

`learn_path.steps` の `minutes` はランディングの合計・各ページ上部のレール・`<!-- learn-path -->`
に展開されます。`README.md`・[`../INDEX.md`](../INDEX.md)・日英の学習ハブに書いた「およそ N 分」
とステップ表の分は**手書き**なので、チュートリアルを 1 本足したら必ず更新します。
規約 12 が `learn_path.zig` の合計と 4 か所の記述、4 つのステップ表を突き合わせ、
`GroupKey.order()` が言語依存に戻っていないかも検査します。

**「いつ最終書き換えか」「どのバージョンまで実装と無矛盾を確認したか」は台帳に記録します。**
[`doc-sync.md`](doc-sync.md) と正本の `scripts/doc-sync.json` が、日英 1 組につき
`last_rewritten`・確認バージョン（`build.zig.zon` の `.version` / `minimum_zig_version`）・
確認コミット・確認コマンド・本文ふたつの sha256・実装ファイル群の sha256 を持ちます。
規約 13 がこれらを検査するので、**本文を書き換えて日付を更新し忘れる**ことも、
**実装が変わったのに再確認していない**ことも、片方の言語だけ直すことも CI で落ちます。
更新は `python3 scripts/check-docs.py --sync`（日付は `--date YYYY-MM-DD` で明示可）。
英語版の無いページも規約 13 が落とします。内部資料（ADR・設計メモ・タスク票）は
日本語専用なので台帳の対象外です。

**プロジェクトのフルネームは `ziggurats`**（常に小文字）です。旧称（ハイフン入りの大文字
表記）は、**リポジトリ URL とチェックアウトのパス名にだけ**残せます。リポジトリ名は所有者が
あとで変更するため、そこは書き換えません。規約 14 が読者向けの Markdown・サイトの UI
文字列・`zts` のヘルプと生成テンプレート・CI・スクリプトを走査し、旧称が残っていたり
頭文字を大文字にした表記で書かれていたりしたら落とします。
**`zts` コマンド、`z_ts` パッケージ、`zts_*` モジュール、`ZTS_*` 環境変数は識別子なので
改名の対象外**です（文字列としても旧称を含まないため、置換で壊れません）。
ソースのテストデータ、ライブラリの既定ウィンドウタイトル、デモの画面内テキストも
「関係ないものを巻き込まない」ため据え置いています。デモの可視テキストは 3 OS の画素一致
ゲートの対象なので、リポジトリ名を変えるときに生成器と生成物をまとめて更新してください。

## 9. 2 言語で書く（英語と日本語）

読者向けのページは **`docs/learn/ja/` と `docs/learn/en/` に同じファイル名で 1 本ずつ**置きます。
これは好みではなく、言語切替スイッチの実装上の要件です。スイッチはパスの `ja`/`en` だけを
差し替えるので、**片方にしかないファイルは押した瞬間に 404 になります**。`check-docs.py` の
規約 8 が両ツリーのファイル名を突き合わせ、欠けていれば落ちます。

| 決まり | 理由 |
|---|---|
| ファイル名・ディレクトリ構成を完全に一致させる | 言語切替がパス置換だけで済む |
| 見出し（H1）は翻訳してよい | サイドバーのラベル・`<title>` は各言語のものになる |
| `> **対象読者**` / `> **Audience**` のバナーを冒頭 12 行に置く | 規約 7。どちらの言語でも同じ位置 |
| コードブロックは同一でよい（`zig check` は 1 回で両方検証される） | 例は言語に依存しない。翻訳で壊す余地を作らない |
| 言語固有の事情（`dpkg` の例など）はその言語のページにだけ書く | 無理に訳すと嘘になる |

順番は **日本語 → 英語** が楽です。英語を先に書くと、日本語版でしか出てこない補足
（`zts doctor` の実出力など）を後から足す場所がなくなります。

`docs/reference/` と `docs/api/` は**翻訳しません**。前者は API 名と CLI フラグが主役で、
後者は `///` から自動生成されるためです（[用語集](../glossary.md)も同様）。

## 10. 生成されるもの（手で作らない）

| 生成物 | 中身 | どこで |
|---|---|---|
| `docs/api/**` | 90 ページ。`///` から生成 | `src/docsite/apidoc.zig` |
| `docs/reference/errors.html` | `error{…}` の索引 | `src/docsite/main.zig` |
| `assets/search-index.js` | 宣言 + メンバ + 用語 + ページ | `src/docsite/main.zig` |
| `llms.txt` / `llms-full.txt` | エージェント向け目次と全文 | `src/docsite/main.zig` |
| `sitemap.xml` / `404.html` | クローラ向け／行き止まりからの回復 | `src/docsite/main.zig` |

`llms.txt` はサイドバーと同じ並びから作られるので、**サイドバーと中身がずれません**。
新しいページを足したら、何もしなくてもここに入ります。

## 11. よくある失敗と直し方

| 症状 | 原因 | 直し方 |
|---|---|---|
| `broken relative link -> '../api/zts_tauri/dialog.html'` | モジュールは `<pkg>/<module>/mod.html` に生成される | リンク先を `.../dialog/mod.html` にするか、Markdown 側で `[`dialog`](../api/zts_tauri/index.html)` と索引へ張る |
| `anchor(s) point at nothing` | 見出しを変えた／メンバは TOC に出ない | 見出しを戻すか、リンクを宣言（`#Decl`）に向ける |
| `flag '--x' is documented but does not exist` | 実装より先に文章を書いた | `src/cli/args.zig` に足すか、リファレンスから消す |
| `internal reference 'M4-03' in a doc comment` | 層の混線 | 理由を `docs/decisions/` へ、用法を `///` に |
| `duplicate glossary term` | 同じ用語を 2 回定義 | 1 つに統合し、片方からリンク |
| `docs/learn/en/…: missing translation (exists in ja)` | 片方の言語にしか無い | 同じパスで翻訳を足す（規約 8） |
| `docs/learn/…: mentions 'zigw'` | 読者向けページに開発用ラッパーを書いた | `zts` と `zig` の手順に直す（規約 10）。`zigw` は `docs/contributing/` だけ |
| `docs/INDEX.md: does not link 'learn/ja/…'` | ページを足して索引を忘れた | [`../INDEX.md`](../INDEX.md) の該当グループに 1 行足す（規約 11） |
| `does not say 'およそ 95 分'` / `step 3 says … minutes` | チュートリアルを足したが所要分を直していない | `learn_path.zig` の `minutes` を決め、README・索引・日英ハブの分を合わせる（規約 12） |
| `GroupKey.order() takes a language` | 言語でメニューを分岐させた | `order()` を 1 本に戻す。未翻訳ページは日本語タイトルのまま両方に出す |
| `missing English counterpart` | 英語版を書き忘れた | `*.en.md` を足し、両方の索引に 1 行（規約 11・13） |
| `changed after verification` / `implementation changed since verification` | 本文か実装を変えたが台帳を更新していない | 差分を読み直し、`python3 scripts/check-docs.py --sync` で日付とハッシュを更新（規約 13） |
| `legacy project name … in prose` | 旧称が本文に残っている／頭文字を大文字にした | `ziggurats`（小文字）に直す。URL とチェックアウトのパス名だけ例外（規約 14） |
| `doc-tests: 1 of 2 blocks failed` | 例が古い（＝API が変わった） | 例を直す。**直せないなら API の変更が意図通りか疑う** |

## 関連

- 改善の作業計画と成功指標: [`../tasks/M5-09-docs-ux.md`](../tasks/M5-09-docs-ux.md)
- なぜこの設計か（12 サイトの調査）: [`../architecture/docs-as-a-product.md`](../architecture/docs-as-a-product.md)
- リポジトリの操作全般: [`README.md`](README.md)
