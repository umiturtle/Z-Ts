# ドキュメントは製品である — Angular / Tauri / Rust に学ぶ文書設計と ziggurats の現在地

> **内部資料です。** これは「ziggurats のドキュメントをどう作るか」を決めるための調査記録で、
> ライブラリ利用者が読む必要はありません。利用者向けの入口は
> [`../learn/ja/guides/index.md`](../learn/ja/guides/index.md)、改善の作業計画は
> [`../tasks/M5-09-docs-ux.md`](../tasks/M5-09-docs-ux.md) にあります。

- **調査日**: 2026-11-06
- **調査対象（第 1 ラウンド）**: <https://angular.dev> / <https://v2.tauri.app> / <https://doc.rust-lang.org>（＋ `rust-lang.org/learn`）
- **調査対象（第 2 ラウンド）**: <https://react.dev/learn> / <https://kubernetes.io/docs/concepts/> / <https://go.dev/blog/examples> /
  <https://docs.python.org/3/glossary.html> / <https://docs.deno.com/runtime/reference/ts_config_migration/> / <https://www.typescriptlang.org/tsconfig/>
- **対象読者**: ziggurats のドキュメントを書く人・直す人・エージェント
- **前提**: `M5-07`（API リファレンス生成）と `M5-08`（読者分離）で作った 4 層モデルを出発点に、
  **「学習しやすさ」の側面を足す**のがこの文書の目的です。4 層モデルを否定はしません。

---

## 0. 結論（先に 10 行）

1. **優れたドキュメントは「1 つのサイト」ではなく「速度の違う 4 つの読み物」**でできている。
   Angular は *概念 → ガイド → チュートリアル → 辞書*、Tauri は *地図 → 概念 → 開発 → 配布 →
   リファレンス*、Rust は *本 → 例 → 手を動かす → 辞書* を並べている。
2. **ziggurats の 4 層（学ぶ / 引く / 確かめる / 中を読む）は方向として正しい**。だが ziggurats は
   「学ぶ」の中身が薄く（10 ページ・約 1,600 行）、**概念とチュートリアルが丸ごと欠けている**。
   概念は内部資料（`architecture/`）にしかなく、読者には「読むな」と言っている。
3. **API リファレンスは 90 ページ・455 宣言すべてに `///` があるが、コード例は 0 個**。
   Rust の rustdoc は「宣言 → 1 行 → 例 → 発展」を規約とし、**例をコンパイルしてテストする**。
   文書化率 100% は品質の証明ではない。
4. **公開 API の `///` に内部事情が漏れている**（`ADR-0002` 等の参照 37 箇所、`M1-03` 等の
   マイルストーン ID、`2-word fat-pointer` のような実装用語）。`M5-07` で決めた層の規約に
   自分で違反している。
5. **失敗からの回復が弱い**。Angular は Error Encyclopedia、Tauri は capabilities ページに
   「何を守り、何を守らないか」を明記している。ziggurats は `troubleshooting.md` の表が 1 つだけで、
   エラー名から引く索引も、ACL/権限のリファレンスもない。
6. **現在地と次の一歩が見えない**。前後ページ送り・パンくず・ページ種別がなく、API ページには
   目次すら無い（Markdown ページにしか TOC を付けていない）。
7. **機械可読な配布が弱い**。Angular も Tauri も `llms.txt` を公開している。ziggurats は
   エージェント前提の開発をしているのに、サイトにはそれが無い。
8. **検証されていない記述が残る**。`src/docsite/site.zig` は `sitemap.txt` を出すと書いているが
   実際には出していない。「矛盾は許さない」という自分たちの規約に反する。
9. したがって改善は「ページを増やす」ではなく、**① 欠けている 2 種（概念・チュートリアル）を足す、
   ② 既存ページに「型」と「現在地」を与える、③ 記述を機械で検証する**の 3 方向に絞るべき。
10. 具体的な作業は [`../tasks/M5-09-docs-ux.md`](../tasks/M5-09-docs-ux.md) の Wave 1〜4 に
    落としてある（S/M/L の見積りと受け入れ条件つき）。

---

## 1. 調査の方法

3 サイトの「HTML をそのまま読む」だけでなく、**学習の入口から 1 ページ辿る**形で確認しました。
確認したのは以下です（内容の要約は §2）。

| サイト | 実際に見たページ |
|---|---|
| Angular | ホーム `/`、`/essentials`（概念の導入）、`/api/core/Signal`（API 1 件）、`/llms.txt` |
| Tauri | ホーム `/`、`/start/`、`/develop/calling-rust/`、`/security/capabilities/`、`/llms.txt` |
| Rust | `rust-lang.org/learn`（学習ハブ）、`doc.rust-lang.org/std/index.html`（std の入口）、`/book/` と第 1 章、`/rustdoc/how-to-write-documentation.html`（文書の書き方の規約） |

調査の観点は 8 つです。**① 初回接触 ② 概念の置き場所 ③ 手を動かす手段 ④ 辞書（名前から引く）
⑤ 失敗からの回復 ⑥ バージョン・互換 ⑦ 機械可読性 ⑧ オフライン/印刷**。

---

## 2. 3 サイトの解剖

### 2.1 Angular — 「速度の違う 4 つの読み物」を 1 つのサイトに並べる

Angular の強さは、**同じ事実を 4 つの速度で書いている**ことです。

| 速度 | 実体 | 読了 | 何が書いてあるか |
|---|---|---|---|
| 30 秒 | ホームの Features（Signals / Control Flow / Deferrable Views / Hydration） | 30 秒 | コード付きのデモと 1 行の価値。「この機能で何ができるか」だけ |
| コーヒー 1 杯 | `/essentials`（全 7 ページ） | 15 分 | 概念の最短ツアー。冒頭に「何を知っている前提か」を明記 |
| 半日 | `/tutorials/learn-angular`（**ブラウザ内で完結**） | 数時間 | インストール不要のハンズオン。「まずコードを書きたい人はこちら」と明示 |
| 辞書 | `/api` `/cli` `/errors` | 用語引き | 網羅。`Signal` のページは**型定義 + Description のみ**で、例はガイド側 |

注目すべき点:

- **「読む人」と「書く人」の分岐がホームにある。** 「New to Angular? → tutorial」「More of a
  reader? → essentials guides」。同じサイトで 2 つの入口を用意し、**どちらが正解かを読者に
  決めさせない**（両方勧める）。
- **API ページは索引に徹している。** 左に `@angular/core` の全宣言（100 件以上）が並び、本文は
  型・説明・"Jump to details" だけ。**例はガイドが持つ**。API は「名前から辿る地図」で、
  例の置き場ではない、という役割分担が徹底されている。
- **Error Encyclopedia がある。** `NG0…` のコードごとに「原因 → 直し方」を持つ辞書。エラーは
  「トラブルシューティング記事の一節」ではなく、**検索できる第 1 級のコンテンツ**。
- **バージョンの移行が独立している。** `/update-guide`、`/reference/versions`（互換表）、
  `/reference/releases`（リリース）。「今のコードが次の版で壊れるか」を 1 ページで答える。
- **`llms.txt` を公開している。** 章立てと全ページ URL の一覧。AI エージェントに「どこに何が
  あるか」を渡すための目次。

### 2.2 Tauri — 「学習の地図」と「機械可読な配布」

Tauri の情報設計は、**読者の目的でトップレベルを切っている**点が際立っています。

```text
start（まず動かす） → concept（設計を理解する） → develop（作る）
→ distribute（配る） → learn（チュートリアル） → plugin（拡張）
→ reference（辞書） → security（信頼） → about（組織）
```

- **ホームは「1 つのコマンド」から始まる。** `create-tauri-app` を Bash / PowerShell / Fish /
  npm / pnpm / yarn / deno / bun / Cargo の **9 タブ**で提示。「あなたの環境の行をコピーすれば
  始まる」状態にしてある。加えて価値提案 4 つ（Frontend Independent / Cross Platform /
  Maximum Security / Minimal Size）。
- **`concept` が独立した章。** 使い方（develop）と分けて「なぜそうなっているか」を説明する。
  ziggurats の内部資料（architecture）に近いが、**読者向けに書き直されている**点が決定的に違う。
- **`security` が独立し、capabilities ページに「守るもの / 守らないもの」が明記されている。**

  > What does it protect against? / What does it **not** protect against?

  これは単なる説明ではなく**信頼の設計**です。「何を保証しないか」を書くことで、利用者は
  過信せずに済み、Issue の質も上がる。
- **プラグインごとに 1 章 + 権限表。** `plugin:<name>` のコマンド一覧と、必要な permission
  identifier が同じ場所にある。「この関数を呼ぶには何を許可するか」が 1 ホップで分かる。
- **`llms.txt` が 4 セットに分かれている。** `llms.txt`（目次）/ `llms-small.txt`（要約版）/
  `llms-full.txt`（全文）/ `_llms-txt/{guides,reference}.txt`。**用途別に切り分けて配る**。
- ページ内は "Section titled" 形式のアンカーで、見出し 1 つ 1 つが URL を持つ。

### 2.3 Rust — 「例がテストされる」API ドキュメント

Rust は 3 つの層がはっきり分かれています。

| 層 | 実体 | 役割 |
|---|---|---|
| 本 | The Book（20 章 + 付録） | 順番に読む。章送り（← →）、`S` で検索、`?` でヘルプ、`print.html` で一括印刷 |
| 例 | Rust by Example | 「言葉を最小に、コードを最大に」 |
| 手 | Rustlings | 手元の環境で穴埋めを直しながら学ぶ |
| 辞書 | std / Reference / Nomicon / Error Index | 引く。`rustup doc` で**オフラインでも同じもの**が見られる |

**API リファレンス（rustdoc）の規約が、そのまま「良い API 文書の条件」になっています。**

- クレートの先頭（`//!`）は**「役割 → なぜ使うか → 現実的な例 → 機能一覧」**。`std` のトップには
  さらに **"How to read this documentation"**（この文書の読み方）が置かれている。
- 各アイテムの文書は **「1 文で何か → 補足 → コピペできる例 → 発展」** の順。
- 最初の 1 段落は検索結果とモジュール一覧の要約に再利用されるので、**1 行で書く**。
- **`# Panics` / `# Errors` / `# Safety` 節**を、該当するときに必ず書く。
- **型を文章で説明し直さない**（シグネチャにリンクが付くので冗長）。
- **コード例は doctest としてコンパイル・実行される。** だから「動かない例」が公開されない。
- 「Source」リンクで実装に飛べる。安定性（`1.0.0`）が各アイテムに表示される。

つまり Rust の API 文書は、**「例が検証されている」という一点で他と別次元**にあります。

### 2.4 横断比較

| 観点 | Angular | Tauri | Rust | ziggurats（現状） |
|---|---|---|---|---|
| 初回接触 | ホームで 2 入口（読む / 書く） | ホームで 9 タブのコマンド | 学習ハブで 3 モード | ホームに「はじめかた（5 分）」1 本 |
| 概念の説明 | `essentials`（読者向け） | `concept`（読者向け） | Book 第 1〜4 章 | **内部資料にしかない** |
| 手を動かす | ブラウザ内チュートリアル | `start` + `learn` | Book / RBE / Rustlings | 5 分の getting-started のみ |
| 辞書 | API / CLI / Errors | reference（config / JS API / CLI / ACL） | std / Reference / Error Index | API（例なし）/ CLI。ACL なし |
| 失敗回復 | Error Encyclopedia | 各章の "Troubleshooting" + 権限表 | Error Index | `troubleshooting.md` の表 1 つ |
| 信頼（守らないこと） | Security 章 | capabilities の "not protect against" | Nomicon / Safety | なし |
| バージョン | update guide / 互換表 | v1 / v2 の切替 | editions / stable・nightly | なし（0.1.0 のみ） |
| 機械可読 | `llms.txt` | `llms.txt` + 4 セット | （rustdoc の索引） | **なし** |
| オフライン | — | — | `rustup doc` | リポジトリ内 Markdown |
| ナビゲーション | 章送り・目次 | 章送り・目次 | ← → / `S` / `?` / print | 目次（details）のみ、前後なし |

### 2.5 第 2 ラウンド — 6 サイトが「1 つのこと」を徹底している

第 1 ラウンド（Angular / Tauri / Rust）は**サイト全体の骨格**を教えてくれました。
第 2 ラウンドは「1 ページの中の書き方」を学ぶために、性格の違う 6 つを選びました。

| サイト | 見たページ | 1 文でいうと | ziggurats への持ち帰り |
|---|---|---|---|
| **React** | `/learn` | 「このページで日常使う React 概念の 80% を紹介する」と**範囲を宣言**し、`### You will learn` の箇条書き → コード → 説明。`class` `map()` `export` など**術語の初出で MDN へインラインリンク** | §2.5.1 |
| **Kubernetes** | `/docs/concepts/` | 概念トップが**索引**で、各サブセクションに**1 文の説明**が付く（"The Kubernetes cluster architecture…"）。分類は技術ではなく**タスク**順 | §2.5.2 |
| **Go** | `/blog/examples` | **Testable Examples**。例はパッケージのテストとしてコンパイル・実行され、`// Output:` と出力を突き合わせる。`Output:` が無ければコンパイルのみ。命名規約 `ExampleFoo` / `ExampleBar_Qux` で**例と対象が機械的に対応** | §2.5.3 |
| **Python** | `/3/glossary.html` | 用語集の各項目が**定義元（実装ページ）へリンク**し、項目同士が相互参照（`duck typing` ↔ `abstract base class`）。PEP・HOWTO へのインラインリンクも | §2.5.4 |
| **Deno** | `ts_config_migration` | 移行ガイドが **「あなたの tsconfig の項目 \| Deno では」の 1 行表**。delete / keep を**断定**し、選択肢を残さない | §2.5.5 |
| **TypeScript** | `/tsconfig/` | 参照ページは**カテゴリ索引 + 安定アンカー**。各項目が **Default / Related（他項目へのリンク）/ Released** のメタデータを持つ | §2.5.6 |

#### 2.5.1 React — 「何を学ぶか」を先に宣言し、術語を初出でリンクする

React の `/learn` は冒頭で「**このページは日常的に使う React の 80% を教える。残りは上級編**」と
**範囲を明示**します。読者は「読み終われば何ができるか」を最初の 3 行で知り、離脱するかどうかを
決められます。続く `### You will learn` は 5〜7 個の箇条書きで、本文の見出しとほぼ 1:1 です。

さらに重要なのが**術語のインラインリンク**です。`class` と書けば MDN へ、`map()` と書けば MDN へ、
`export` と書けば MDN へ。**用語集ページへ飛ばさず、その場で定義へ飛ばす**。
ziggurats の `` `Handler` `` の自動リンク（§3 P13）は、この発想を**サイト内で**やるものです。

#### 2.5.2 Kubernetes — 索引ページは「1 文つきの目次」である

`/docs/concepts/` は Concept の一覧ですが、ただのリンク集ではありません。各項目に
**「それが何か」を 1 文**書いてあります。読者はリンクを踏む前に、自分が読むべきかを判断できます。

分類も技術者向けではありません（`Cluster Architecture` `Containers` `Workloads` `Storage`
`Security`）。**「何をしたいか」で並んでいる**ので、初見でも辿れます。
ziggurats の `docs/learn/ja/guides/index.md`（Learning Path）とホームの目的別入口は、この形に寄せます。

#### 2.5.3 Go — 例は「動くテスト」として書く

Go の例は `_test.go` の中の関数で、`// Output:` コメントが付いていれば**出力まで照合**されます。
つまり、例が古くなれば `go test` が落ちます。公式ブログの言葉がすべてです。

> 実行可能なドキュメントは、API の変化で古くならない。

ziggurats の `scripts/doc-tests.py`（§3 P5 / P18）は、この仕組みの**前半（コンパイル）**を実装しました。
後半（出力の一致）は未実装で、理由は「例の多くがウィンドウとイベントループを要する」からです。

#### 2.5.4 Python — 用語集は「辞書」ではなく「ハブ」

Python の用語集は、項目を並べただけのページではありません。各項目が

1. **定義**（1〜2 文）
2. **定義元へのリンク**（`__slots__` → data model の該当節）
3. **他の用語へのリンク**（`duck typing` → `abstract base class`）
4. **関連仕様へのリンク**（PEP や HOWTO）

を持ちます。結果として、用語集は「読んだ語を確認する場所」から「**次に読むべき場所を教える場所**」
に変わっています。ziggurats の `docs/glossary.md`（31 項目）は 1 と 3 を実装済み、2 と 4 を
xref の自動リンクで近似しています。

#### 2.5.5 Deno — 移行は「1 行 1 項目、断定で」

Deno の `tsconfig` 移行ガイドは、**「あなたの tsconfig の項目 | Deno ではどうするか」**という
2 列の表だけです。`target` は削除、`module` は削除（Deno は常に ESM）、`strict` は既定で有効——
**「場合によっては」を書かない**のが特徴です。読者は迷わず、終わったかどうかも判定できます。

ziggurats の [`../learn/ja/guides/migrate-from-tauri.md`](../learn/ja/guides/migrate-from-tauri.md) は
Tauri の API → ziggurats の API を 1 行 1 項目の表にし、各行にリンクを付けました。

#### 2.5.6 TypeScript — 参照項目はメタデータを持つ

`/tsconfig/` の各オプションは、**Default（既定値）/ Related（関連オプションへのリンク）/
Released（導入バージョン）** を必ず持ちます。読者は「今の設定から変えたら何が起きるか」を、
ページを移らずに判断できます。アンカーも安定していて（`#strict` など）、外部からリンクされます。

ziggurats の [`../reference/cli.md`](../reference/cli.md) は、この 3 点を各節に足す方針にしました。

### 2.6 10 サイトを 1 枚にすると

| 観点 | 第 1 ラウンド（3） | 第 2 ラウンド（6） | 共通する結論 |
|---|---|---|---|
| 学習の入口 | Angular 2 入口 / Tauri 地図 / Rust 3 モード | React「範囲の宣言」 | **読む前に「何が得られるか」を 1 文で** |
| 概念の置き場所 | essentials / concept / Book | K8s の 1 文つき索引 | **概念は読者の層に、索引は 1 文つきで** |
| 辞書 | API / CLI / Errors | Python 用語集 / TS メタデータ | **引くページは「次に読む」を返す** |
| 例 | Angular サンドボックス / Rust doctest | Go の Testable Examples | **例は機械が検証する。手で貼らない** |
| 移行 | Angular update guide / Tauri v1→v2 | Deno の 1 行表 | **変更前 → 変更後、断定で** |
| 機械可読 | Angular・Tauri の `llms.txt` | （TS の安定アンカー） | **目次は 1 リクエストで取れる形で** |

### 2.7 第 3 ラウンド — 「入口の作り方」だけを見る（Vue / Kubernetes ホーム）

第 2 ラウンドで「1 ページの中」を学んだので、最後に**サイトの入口**だけを 2 サイトで確認しました。

| サイト | 見たページ | 発見 | ziggurats での対応 |
|---|---|---|---|
| **Vue** | `/guide/introduction.html` | 冒頭に **Prerequisites** 節があり、「HTML/CSS/JS の基礎が無いなら先に MDN へ」と**読者を返す**。さらに "The Progressive Framework" で「どこから始めても、学んだことは後で効く」と**学習の投資対効果**を明言 | 各ガイドの冒頭に `> **対象読者**` と `> **所要時間**` を必須化（`check-docs.py` の規約 7） |
| **Kubernetes** | `/docs/home/` | ホームが **4 つの入口**（Understand / Try / Set up / Learn tasks / Reference）で、各入口に **1 文の説明 + 代表 5〜7 リンク + CTA**。フッターに "About the documentation"（対応バージョン） | ホームに「4 つの入口」（学ぶ / 手を動かす / 引く / 確かめる・中を読む）を追加。全ページ一覧は `<details>` に畳む |

#### 2.7.1 Vue — 前提知識を書くと、読者は正しい場所から始められる

Vue の導入ページは、本文の前に**「この先を読むには HTML/CSS/JavaScript の基礎が要る」**と書き、
足りない読者には MDN の該当ページを渡して**戻します**。これは親切であると同時に、
「分からないのは自分が悪いのか、説明が悪いのか」という迷いを消します。

ziggurats のガイドは対象読者を書いていましたが、**「何を知っている前提か」**は書いていませんでした。
第 2 ラウンドで全ガイドに `> **対象読者**` と `> **所要時間**` を入れ、`check-docs.py` が
12 行以内に無ければ落とすようにしました（書き忘れを機械で止める）。

#### 2.7.2 Kubernetes ホーム — 索引ではなく「入口」

`/docs/home/` は全ページの一覧ではありません。**4 つの目的**（理解する / 試す / 使う / 引く）が
縦に並び、それぞれに「この節は何のためか」の 1 文、代表的な 5〜7 リンク、そして
"View Concepts" のような CTA があります。読者は「自分は今どこにいるか」を選んでから入ります。

ziggurats のホームはヒーロー + 3 枚のカード + グループ別リンク集でした。これを
**4 つの入口**（学ぶ / 手を動かす / 引く / 確かめる・中を読む）に置き換え、全ページ一覧は
`<details>` に畳みました。リンクのラベルは**サイドバーから引く**ので、ページ名を変えても
ホームが古い名前を出し続けることはありません。

---

## 3. 導かれる 20 の原則（第 1 ラウンドの 12）

以下は「3 サイトに共通して見えたこと」と「ziggurats に当てはめたときに効くこと」をセットにした
原則です。**判定基準**は、後で機械的に測れる形にしてあります。

### P1. 読者を最初に分ける

**根拠**: Angular は「New to Angular?」と「More of a reader?」を同じホームに並べる。Tauri は
`develop`（作る人）と `concept`（理解したい人）を分ける。Rust は「本 / 例 / 手」を並べる。

**ziggurats への含意**: `M5-08` で「アプリ作者 / リポジトリ開発者」の 2 分はできた。だが
**アプリ作者の中に「これから学ぶ人」と「既に知っている人」の分岐がない**。

**判定基準**: ホームに、目的別の入口が 3 つ以上あり、それぞれ「所要時間」が書かれていること。

### P2. 学習の入口を「読む」と「手を動かす」の 2 本にする

**根拠**: Angular のチュートリアルはインストール不要でブラウザ内で完結する。Rustlings は手元で
動かす。どちらも「読むだけ」で終わらせない。

**ziggurats への含意**: `getting-started.md` は 5 分で動くが、**その先の「作る」体験がない**。
1 時間で「コマンドを 1 つ足して、配布物を作る」までのレッスンが必要。

**判定基準**: チュートリアルが 1 本以上あり、各レッスンに「実行するコマンド」「期待する出力」
「失敗したときのリンク」が揃っていること。

### P3. 概念は「内部資料」ではなく読者の層に置く。ADR 番号は読者に出さない

**根拠**: Tauri の `concept` 章は読者向けに書き直されている。rustdoc は `//!` に役割と例を書く。
一方で**内部の設計番号やトレードオフは API 文書に出さない**（Rust の std に ADR 参照はない）。

**ziggurats への含意**: いま「6 パッケージの地図」「IPC の流れ」「ACL の考え方」「実行モード
（desktop / live / wasm / ssg）」は `docs/architecture/` にしかなく、`guides/README.md` は
「内部資料は読まなくてよい」と書いている。**読者が最初に知りたいことが、読むなと言われた場所に
しかない**という倒錯がある。

**判定基準**: 読者向けの概念ページが 3 本以上あり、`ADR-` と `M\d-\d\d` の文字列を含まないこと
（機械検査）。

### P4. すべての公開宣言に「1 行 + 例」を持たせる

**根拠**: rustdoc の規約。`std::env::args()` は 1 文 → 補足 → 例 → Panics の順。

**ziggurats への含意**: 455 宣言すべてに `///` はあるが、**コード例は 0**。`///` 全体（1,530 行）の
うちフェンスは 3 ブロックだけ。読者は「何をするか」は分かるが「どう書くか」が分からない。

**判定基準**: API リファレンスに「コード例を含む宣言」の割合（`api_with_examples`）を出し、
最初は主要 20 宣言で 100%、最終的に 60% を目標にする。

### P5. 例は機械で検証する

**根拠**: rustdoc の doctest。例が壊れたら CI が落ちる。

**ziggurats への含意**: ガイドのコードは手で貼られており、API の変更で壊れても気付けない。少なくとも
**`zig` フェンスを抽出してコンパイルする**だけの検査（doctest-lite）は、依存ゼロの現構成でも
実現できる。

**判定基準**: `zig build docs` か専用ステップが、ガイド内の Zig コード片のコンパイルに失敗したら
落ちること。

### P6. 名前から引ける（検索が第一の入口）

**根拠**: rustdoc はクレートページ冒頭で「名前が分かっているなら検索が最速」と明言する。
Angular は API 索引を全宣言のチップで敷き詰める。Tauri はページ内アンカーを全見出しに付ける。

**ziggurats への含意**: 検索は 886 件の索引で動いているが、**型メンバ（1,477 件）は索引にない**。
`WindowConfig` の `title` を探すとき、`title` では引けない。

**判定基準**: メンバ名で検索して、そのメンバのアンカーに直接飛べること。

### P7. 現在地と次の一歩が見える

**根拠**: Rust の本は ← → で章送り。Tauri / Angular も前後送りと目次を持つ。

**ziggurats への含意**: 目次（`<details>`）はあるが、**前後ページ送り・パンくず・ページ種別が無い**。
API ページに至っては目次すら生成していない（`toc` を Markdown ページだけに渡している）。

**判定基準**: すべてのページにパンくずと前後送りがあり、API モジュールページにも目次があること。

### P8. 失敗から回復できる（エラーは第 1 級のコンテンツ）

**根拠**: Angular の Error Encyclopedia（コードごとに原因と直し方）。Tauri は権限まわりで
「何を許可すればこの関数が呼べるか」を同じページに書く。

**ziggurats への含意**: エラー名（`error.InvalidName` など）はソースの `error{…}` 集合として既に
存在するのに、**ドキュメントとして索引化していない**。`troubleshooting.md` の表はあるが、
「エラー名 → ページ」の対応がない。

**判定基準**: エラー名で検索すると、その意味と直し方のページに着地すること。

### P9. ページの「型」を固定する（ガイド / 概念 / リファレンス / レシピ / 移行 / 障害）

**根拠**: 3 サイトとも、ページ種別ごとに書き方が違う（概念は理由、ガイドは手順、リファレンスは
網羅）。混ざると読みにくくなる。この分類は Diátaxis として知られる枠組みと一致する。

**ziggurats への含意**: 4 層モデルは「置き場所」の規約だが、**ページ単位の種別ラベルがない**。
`guides/` の中にハンズオン（getting-started）と移行（migrating）と障害対応（troubleshooting）が
同居していて、サイドバーでは区別が付かない。

**判定基準**: 各ページに `guide` / `concept` / `reference` / `recipe` / `migration` / `errors` の
いずれかの種別が付き、サイドバーと検索結果に表示されること。

### P10. バージョンと互換性を明示する

**根拠**: Angular の update guide / 互換表、Tauri の v1・v2 切替、Rust の editions。

**ziggurats への含意**: まだ 0.1.0 なので版切替は不要。ただし**「どの Zig で動くか」「どの Tauri v2
互換か」**は今すぐ必要な情報で、いまは `AGENTS.md` と各所に散っている。

**判定基準**: トップに「対応 Zig / 対応 Tauri バージョン」が 1 行で出ていること。

### P11. 機械可読にする（エージェントも読者）

**根拠**: Angular と Tauri は `llms.txt` を公開。Tauri はサイズ別に 4 種。

**ziggurats への含意**: このリポジトリは**エージェント前提**で運用されている（`AGENTS.md`、
タスク分割、記憶リセット耐性）。にもかかわらず、公開サイトに `llms.txt` がない。

**判定基準**: `llms.txt`（目次）と `llms-full.txt`（本文）が生成され、リンク検査の対象になること。

### P12. オフライン / 印刷 / 単一ファイル

**根拠**: Rust の `rustup doc`、Book の `print.html`。

**ziggurats への含意**: サイトには印刷用 CSS がある（クロームを隠す）が、**全ページを 1 つにまとめた
版がない**。オフラインは「リポジトリの Markdown」で代替できるが、読者には自明でない。

**判定基準**: `print.html`（または `docs.txt`）が生成され、主要ページが 1 ファイルで読めること。

---

## 3b. 第 2 ラウンドで足した 6 原則（P13〜P18）

§2.5 の 6 サイトから取り出した、**1 ページの中の書き方**に関する原則です。P1〜P12 が
「サイトの骨格」なら、こちらは「段落と表の作り方」です。

### P13. 術語は初出でリンクする（用語集へ飛ばさない）

**根拠**: React は `class` `map()` `export` の初出で MDN へリンクする。

**ziggurats への含意**: 「用語集を見てください」は 1 クリックの無駄。本文の `` `Handler` `` が
そのまま `zts_rpc` の宣言へ飛ぶべき。実装は `src/docsite/markdown.zig` の `writeCodeSpan()` —
コード表記を xref 索引（4,600 項目）で引き、完全修飾名 → 一意な名前 → 何もしない、の順に解決する。

**判定基準**: 生成 HTML に `class="xref"` のリンクが一定数（現在 982 本）あり、
リンク先がすべて実在すること（`zig build docs` が検査）。

### P14. 索引ページは「1 文つきの目次」にする

**根拠**: Kubernetes の `/docs/concepts/`。各項目に 1 文、並びはタスク順。

**ziggurats への含意**: ホーム・`docs/learn/ja/guides/index.md`・`docs/api/index.html` の 3 つは索引である。
リンクだけを並べず、**読者が踏む前に判断できる 1 文**を付ける。並びは「機能」ではなく
「やりたいこと」（はじめる → コマンドを書く → 画面を作る → 配る → 失敗から戻る）。

**判定基準**: 索引ページの各リンクに 1 文の説明があること（`llms.txt` の生成は同じ情報源）。

### P15. 移行ガイドは「変更前 → 変更後」を 1 行 1 項目で書く

**根拠**: Deno の `tsconfig` 移行表。断定で、選択肢を残さない。

**ziggurats への含意**: Tauri からの移行は `fs` → `zts_tauri.fs`、`invoke` → `zts_rpc` の
`Schema` のように、**1 行で書ける対応**がほとんど。文章で説明すると読者は写経を間違える。

**判定基準**: [`../learn/ja/guides/migrate-from-tauri.md`](../learn/ja/guides/migrate-from-tauri.md) の
対応表が全行リンク付きで、各行が「Tauri の API | ziggurats の API | ひとこと」になっていること。

### P16. 参照ページの項目は既定値・関連・導入時期を持つ

**根拠**: TypeScript の `/tsconfig/`。`Default` / `Related` / `Released` が全項目にある。

**ziggurats への含意**: `zts` のフラグは「既定値」が最重要（`--release` の既定は何か）。
「関連」は同じページ内アンカーで足りる。「導入」は 0.1.0 のうちは省いてよいが、
フラグが増えたら必要になる。

**判定基準**: [`../reference/cli.md`](../reference/cli.md) の各節に **既定値** 行があり、
フラグ集合が `src/cli/args.zig` と一致すること（`check-docs.py` の規約 4）。

### P17. 用語集はハブにする（定義 + 定義元 + 相互参照）

**根拠**: Python の用語集は、定義元・他用語・PEP へリンクする。

**ziggurats への含意**: 31 項目の [`../glossary.md`](../glossary.md) は、各項目が
「1 文 + 初出ページ + API 宣言」を持つ。定義中の `` `Code` `` は他の項目へリンクするので、
用語集の中を読み進められる。

**判定基準**: `###` 見出しが一意（`check-docs.py` の規約 6）、各項目にリンクが 1 本以上あること。

### P18. 例は出力まで含めて検証する（コンパイルは最低線）

**根拠**: Go の Testable Examples は `// Output:` と照合する。**例が古くなるとテストが落ちる。**

**ziggurats への含意**: すべての例を実行するのは無理（ウィンドウ・イベントループが要る）。
だが**コンパイルは全例でできる**ので、そこを最低線にする。`zig check` を付けたブロックだけ
が対象で、`scripts/doc-tests.py` が `zig test --test-no-exec` に通す。出力の一致は将来の拡張。

**判定基準**: `python3 scripts/doc-tests.py` が緑で、`zig check` ブロックが 2 本以上あること。
**未達**: 出力一致（`// Output:`）は未実装。

---

## 3c. 第 3 ラウンドで足した 2 原則（P19〜P20）

### P19. ホームは索引ではなく「入口」にする

**根拠**: Kubernetes の `/docs/home/`。4 つの目的 ×（1 文 + 代表リンク + CTA）。

**ziggurats への含意**: ホームに全 197 ページを並べても読者は選べない。**目的で 4 つに切り**、
各入口に「何のための節か」を 1 文で書く。全ページ一覧は `<details>` に畳んで残す。

**判定基準**: ホームに 4 つの `article.path` があり、各カードに 1 文の説明・5 リンク・CTA があること。
リンクのラベルはサイドバー（`groups`）から引くので、改名に追従する。

### P20. 「何を知っている前提か」を書く（読者を正しい場所へ返す）

**根拠**: Vue の Prerequisites 節。基礎が無い読者には MDN を渡して**戻す**。

**ziggurats への含意**: 「対象読者」だけでは足りない。**所要時間**と**前提**（例:「Rust の
`#[tauri::command]` を知っている」「Zig の `comptime` を読める」）を冒頭 12 行に置く。
書かなければ CI が落ちるので、新しいページでも抜けない。

**判定基準**: `docs/learn/**` と `docs/reference/*`（索引と内部向けを除く）の全ページが
`> **対象読者**`（英語ページは `> **Audience**`）を 12 行以内に持ち、`check-docs.py` の規約 7 が
検証する。

## 3d. 第 4 ラウンド: 言語と見た目を「後付け」にしない

第 3 ラウンドまでで**構造**（4 層・入口・現在地・前提）は揃いました。残ったのは
「日本語しか読めない」「見た目が素の HTML」という 2 点で、どちらも**後から足すと必ず壊れる**
種類のものです。そこで 2 原則を追加しました。

### P21. 翻訳はパスの写像にする（ファイル名を一致させる）

**根拠**: Tauri（`/start/` と `/ja/start/` が同じ slug）、React（`/learn` と `/ja/learn`）。
両者とも**言語だけがパスの前置き**で、ページの識別子は言語に依存しません。

**ziggurats への含意**: 読者向けページは `docs/learn/ja/…` と `docs/learn/en/…` に**同一ファイル名**で
置く。言語切替はパスの `ja`/`en` を置き換えるだけ（`i18n.alternateHref`）で、翻訳の有無を
判定するコードを持たない。逆に、片方にしかないファイルは**切替を押した瞬間に 404** になるので、
規約 8 が両ツリーの集合一致を検証する。

**判定基準**: `docs/learn/ja` と `docs/learn/en` の相対パス集合が一致（`check-docs.py` 規約 8）。
相手が存在するときだけ `<link rel="alternate" hreflang>` を出す（`altHref` が実ファイルを見る）。

### P22. テーマはトークンで 2 つ持つ（後から暗くしない）

**根拠**: Vue / Deno / TypeScript のドキュメントはいずれも**色をすべて変数**にし、
`:root` と `[data-theme="dark"]` で 2 回定義します。後から「暗いときに読めない箇所」を
探す作業が発生しないのが利点です。

**ziggurats への含意**: `site.css` の色は `--bg` / `--fg` / `--accent` などの宣言だけで使い、
直値の色を本文側に書かない。ブランドのグラデーションだけは例外で、`--accent` がダークで
明るい色に反転するため**反転しない固定色**（`--brand-a` / `--brand-b`）を別に持つ。
初期値は `prefers-color-scheme`、切替は `localStorage`、`<head>` の 1 行スクリプトで
**描画前に**確定させる（白い flash を出さない）。

**判定基準**: `site.css` の全 `var(--…)` が両テーマで定義されていること、本文色の
コントラストが AA（4.5:1）を満たすこと。現状 `--fg-faint` は 4.87:1（light）/ 6.33:1（dark）。

## 3e. 第 5 ラウンド: 初心者の「1 本目」を 1 本にする

第 4 ラウンドまでで、入口・前提・言語・見た目は揃いました。それでも初心者は詰まります。
原因は**選択肢の多さ**でした。ランディングに 4 入口、サイドバーに 10 グループ、学習の入口に
「概念 → チュートリアル → ガイド」の 3 択。どれも正しいのに、**最初の 1 歩が決まらない**。

### P23. 学習の道順は 1 本にし、同じ表から 3 か所（ページ・サイドバー・ランディング）に描く

**根拠**: Angular `essentials`（7 ページの線形パス）、Vue `guide`（左サイドバーが学習順）、
Rust `learn`（3 つの学習スタイルを明示）。いずれも「最初に何を読むか」を読者に選ばせず、
**道順そのものを製品の一部**として提示します。Kubernetes のように用途別に並べるのは、
読者がすでに目的語を持っている場合の型です。

**ziggurats への含意**: 道順（`はじめての ziggurats → 仕組みを知る → アプリを作る → 実用パターン → 目的から引く`）を
**`src/docsite/learn_path.zig` の 1 つの表**に置き、そこから次の 4 つを生成する。

| 描画先 | 何が出るか |
|---|---|
| 各ページ上部のレール | 5 ステップ・現在地・所要分。`done` / `current` の状態付き |
| サイドバー | グループ見出しが `2 · 仕組みを知る` のように道順の番号を持つ |
| 学習入口（`docs/learn/*/index.md`） | `<!-- learn-path -->` が同じ 5 ステップの一覧に展開される |
| ランディング | ヒーロー直下にステップカードと合計時間（ステップ数は表から数える） |

**順番の根拠**: 概念を先に置かない。1 度も動かしていない読者に 6 層の依存図を見せると、
読む理由が無いまま抽象語を暗記させることになります。**触る → 理解する → 作る → 設計を選ぶ → 引く**。

4 ページ目の「実用パターン」（`docs/learn/*/patterns/`）は、チュートリアルの直後と
examples（完成形）の間に置きます。完成形のコードは「なぜそう書くか」を復元できないので、
書きはじめた直後に**判断基準と練習**を渡すのが目的です（[`../tasks/M5-12-patterns-docs.md`](../tasks/M5-12-patterns-docs.md)）。

**判定基準**:

- 各ステップの開始ページが実在すること（`learn_path` の単体テスト + `zig build docs` のリンク検査）。
- サイドバー・レール・ランディング・学習入口の順序が**同一**であること（すべて同じ表から生成）。
- 道順の外のページ（API・用語集・内部資料）にはレールを出さないこと。

---

## 4. ziggurats の現在地（実測）

### 4.1 数字（2026-11-06、`./zigw build docs`）

> 下表の「当初」はこの調査を始めた時点（本調査記録と M5-09 を書き足す前）の実測です。
> 「現在」は 2026-11-06 の第 2 ラウンド実装後（`./zigw build docs`）。

```text
# 当初（2026-11-06 調査時）
OK docsite pages=192 links=409 assets=9492 words=392967 bytes=4512495 demos=60
   api_pages=90 api_decls=455 api_members=1477 api_undoc=0 api_internal=452

# 現在（第 2 ラウンド実装後）
OK docsite pages=197 links=468 assets=12895 words=460868 bytes=5452965 demos=60
   api_pages=90 api_decls=455 api_members=1477 api_undoc=0 api_internal=452
   xref_targets=4605 xrefs=988 errors=118

# 第 5 ラウンド後（2026-11-07 / 学習パス）
OK docsite pages=221 links=731 assets=16158 words=495012 bytes=6757466 demos=60
   api_pages=90 api_decls=455 api_members=1477 api_undoc=0 api_internal=452
   xref_targets=4605 xrefs=1164 errors=118
```

| 指標 | 当初 | 現在 | 補足 |
|---|---|---|---|
| 総ページ | 192 | **197** | うち内部資料が大半（サイドバーでは 1 エントリに畳まれる） |
| 読者向けリンク | 409 | **468** | 相対リンクの総数。`zig build docs` が全数を検査 |
| xref（自動リンク） | 0 | **988** | `` `Handler` `` 等のコード表記が API へ飛ぶ |
| エラー索引の項目 | 0 | **118** | `error{…}` から生成。`#error.Name` で引ける |
| 検索索引 | 886 件 | **2,363 件** | 型メンバ（1,477）と用語集を追加 |
| API ページ | 90 | 90 | 10 パッケージ。目次（TOC）付きに |
| 公開宣言 | 455 | 455 | `///` 付き 100%（`api_undoc=0`） |
| 型メンバ | 1,477 | 1,477 | 宣言とは別に数えている（検索対象になった） |
| サイドバー | 6 グループ / 31 項目 | 6 グループ / 35 項目 | エラー索引・用語集・執筆規約を追加 |
| `llms.txt` / `llms-full.txt` | なし | **あり** | サイドバーと同じ並びから生成 |
| `sitemap.xml` / `404.html` | なし | **あり** | 行き止まりから戻れる |
| 注記（`> [!NOTE]`） | なし | **4 種対応** | GitHub とサイトの両方で読める |
| `zig check` ブロック | 0 | **2 本** | `scripts/doc-tests.py` が CI でコンパイル |
| `///` 内の内部参照 | **37 箇所** | **0**（公開ツリー） | `check-docs.py` の規約 3 が再発を止める |

### 4.2 できていること（他サイトと比べても強い部分）

- **リンクとアンカーの機械検査**。壊れたリンク・存在しないアンカーはビルドが落ちる。3 サイトの
  うち、ここまで明示しているのは ziggurats だけ（彼らは CI で別途やっているが、我々は生成の一部）。
- **API をソースから生成**。シグネチャ・`///`・ソース行リンクが常に一致する。手書きの API 一覧が
  腐る問題が構造的に起きない。
- **公開 / 内部の分離**。FFI テーブル（`win32.zig` 142 宣言、`gtk_bindings.zig` 69 宣言）を
  索引・検索・文書化率から外している。rustdoc でも `pub` にすると出てしまう類のものを、
  読者の前から畳んである。
- **4 層モデルとサイドバーの順序**。読者の動線が先、内部資料が最後の 1 エントリ。
- **日本語アンカーが GitHub と一致**。`#設計判断` のようなリンクが両方で動く。
- **コピーボタン・テーマ・`/` 検索・モバイル対応**。地味だが 3 サイトと同等の基本装備。

### 4.3 不足（証拠 → 原則）

| # | 不足 | 証拠 | 原則 |
|---|---|---|---|
| G1 | 読者向けの**概念**ページが無い | 「6 パッケージ」「IPC」「ACL」の説明は `docs/architecture/` のみ。`guides/README.md` は内部資料を「読まなくてよい」と案内 | P3 |
| G2 | **チュートリアル**が無い | `getting-started.md`（5 分）以降の段階が無い | P2 |
| G3 | API に**例**が無い | 90 ページ中 0。`///` のフェンスは 3 ブロック | P4 |
| G4 | 例が**検証されない** | ガイドのコード片をコンパイルする仕組みが無い | P5 |
| G5 | **ACL / capability のリファレンス**が無い | `src/tauri/acl.zig` と `config_import.zig` は実装済み（`M4-04`）。読者向けページは 0 | P8, P9 |
| G6 | **エラー事典**が無い | `error{…}` 集合はソースにあるが索引化していない。`troubleshooting.md` は表 1 つ | P8 |
| G7 | **用語集**が無い | `Handle` `Channel` `RawPayload` `OwnedBytes` `Capability` などを 1 か所で説明する場所が無い | P3 |
| G8 | **前後送り・パンくず・ページ種別**が無い | `site.zig` のテンプレートに該当要素なし | P7, P9 |
| G9 | API ページに**目次**が無い | `main.zig` は `toc` を Markdown ページにしか渡さない | P7 |
| G10 | 検索が**メンバ**を引けない | 索引は宣言単位（886 件）。メンバ 1,477 件は対象外 | P6 |
| G11 | `llms.txt` が無い | 生成物に無い | P11 |
| G12 | 全ページ 1 ファイル版が無い | `print.html` 相当なし | P12 |
| G13 | 注記・コードタブが無い | Markdown レンダラは blockquote まで。`> [!NOTE]` やタブは未対応 | P9 |
| G14 | 404 ページ・`sitemap.xml` が無い | 生成物に無い | P6, P11 |

### 4.4 自己矛盾（いま直すべきもの）

| # | 矛盾 | 場所 |
|---|---|---|
| C1 | 公開 API の `///` に `ADR-0002` / `M1-03` / 「2-word fat-pointer」など内部事情が入っている（37 箇所）。`M5-07` の「実装意図を `///` に書かない」に違反 | `src/rpc/schema.zig`、`src/rpc/ctx.zig`、`src/tauri/mod.zig` ほか |
| C2 | モジュール先頭の `//!` が「設計書の要約」になっていて、**役割と例**になっていない（Rust の規約と逆） | `src/tauri/mod.zig`、`src/rpc/mod.zig` |
| C3 | `site.zig` のモジュールドキュメントが `sitemap.txt` を出すと書いているが、実際には出していない | `src/docsite/site.zig:6` |
| C4 | `guides/README.md` の「ガイド 8 本」は実態と合うが、内訳（ハンズオン / 移行 / 障害）がラベルされていない | `docs/learn/ja/guides/index.md` |

### 4.5 第 2 ラウンドで解消したもの（2026-11-06）

| 項目 | 状態 | 実装 |
|---|---|---|
| G4 例の検証（コンパイル） | **達成** | `scripts/doc-tests.py` + `zig check` 規約。`./zigw docs-check` と CI で実行 |
| G6 エラー索引 | **達成** | `docs/reference/errors.html`（118 項目、`error{…}` から生成） |
| G7 用語集 | **達成** | [`../glossary.md`](../glossary.md)（31 項目、相互参照） |
| G8 パンくず・種別・前後送り | **達成** | `site.zig` の `Crumb` / `kindLabel` / `NavLink` |
| G9 API の目次 | **達成** | `apidoc.Page.toc`（宣言の見出しのみ。メンバは索引を肥大させるため除外） |
| G10 メンバ検索 | **達成** | `search-index.js` 2,362 件（型メンバ 1,477 を含む） |
| G11 `llms.txt` | **達成** | `main.zig` の `renderLlmsTxt` / `renderLlmsFull` |
| G13 注記 | **達成**（コードタブは未） | `markdown.zig` の admonition（`> [!NOTE]` 他 3 種） |
| G14 404 / `sitemap.xml` | **達成** | `main.zig` の `renderSitemap` / `renderNotFoundBody` |
| C1 `///` の内部 ID | **達成**（公開ツリー） | 54 行から削除。`check-docs.py` 規約 3 が再発を止める |
| C2 `//!` の要約化 | **部分達成** | `src/rpc/mod.zig` 等の主要 3 本を書き換え。残りは Wave 2 |
| C3 `sitemap.txt` の虚偽記述 | **達成** | `site.zig` のモジュールドキュメントを実態に合わせた |
| — 相互リンクの量 | **達成** | 読者向けリンク 409 → 460、xref 0 → 985、用語集・エラー索引からの導線 |
| — 執筆規約の明文化 | **達成** | [`../contributing/writing-docs.md`](../contributing/writing-docs.md) |
| G1 概念ページ / G2 チュートリアル / G5 ACL / G12 印刷版 / G3 API の例 | **未着手** | Wave 2〜4（[`../tasks/M5-09-docs-ux.md`](../tasks/M5-09-docs-ux.md)） |

### 4.6 第 4 ラウンドで解消したもの（2026-11-06）

| 項目 | 状態 | 実装 |
|---|---|---|
| G1 概念ページ | **達成** | `docs/learn/{ja,en}/concepts/` 4 ページ（構成・コマンド・プラグイン・セキュリティ） |
| G2 チュートリアル | **達成** | `docs/learn/{ja,en}/tutorials/counter.md`（15 分・`zig check` 付き） |
| G12 印刷版 | **達成** | `site.css` の `@media print`（ナビ・レール・検索を落とし、リンクを下線で残す） |
| 2 言語（P21） | **達成** | `docs/learn/{ja,en}/` 各 16 ページ・規約 8 がパリティ検証 |
| ダークモード（P22） | **達成** | `site.css` のトークン 2 定義・AA コントラスト・描画前のテーマ確定 |
| 学習の道筋（P14 / P19 / P20） | **達成** | 日英 2 つのランディング（4 入口）+ `docs/learn/*/index.md` |
| 1 本の学習パス（P23） | **達成** | `src/docsite/learn_path.zig` → レール・サイドバー・学習入口・ランディングの 4 面。`docs/learn/{ja,en}/start.md` |
| G5 ACL の作例 / G3 API の例 | **未着手** | Wave 2 の残り |

---

## 5. 原則 → 改善への写像

「効き目の大きさ」×「実装コスト」で 4 象限に分けます。詳細は
[`../tasks/M5-09-docs-ux.md`](../tasks/M5-09-docs-ux.md)。

```text
          影響 大
              │
   Wave 1     │   Wave 2
  （すぐやる） │  （学習体験）
  C1 C2       │  G1 G2 G7 G5
  G8 G9 G10   │  G6 G13
  G11 G14     │
──────────────┼──────────────  コスト →
   Wave 0     │   Wave 3/4
  （1 行修正） │  （検証と発展）
  C3          │  G4 G12
              │
          影響 小
```

- **Wave 0（1 行）**: C3 の虚偽記述を消す。ドキュメントの信頼はここから。
- **Wave 1（S〜M）**: 既存ページの「型」と「現在地」を整える。C1/C2、G8/G9/G10、G11、G14。
  新しい文章をほとんど書かずに、**読みやすさだけ**が上がる。
- **Wave 2（M〜L）**: 欠けている 2 種（概念・チュートリアル）と辞書（用語・エラー・ACL）を足す。
  **ここが本体**。文章を書く作業なので、エージェントより人間の判断が要る部分が多い。
- **Wave 3（M）**: 書いたものが腐らないように機械で縛る（doctest-lite、層違反 lint、
  `api_with_examples` 指標）。
- **Wave 4（L・任意）**: コードタブ、印刷版、バージョン切替。今の規模では後回し。

> **進捗（2026-11-06）**: Wave 0・Wave 1・Wave 3 の大半は実装済み（§4.5）。残るのは
> Wave 2 の本体（G1 概念 / G2 チュートリアル / G5 ACL / G3 API の例）と G12 の印刷版です。
> 実装済みの検証は `./zigw docs-check`（レンダラのテスト → `check-docs.py` → `doc-tests.py` →
> `zig build docs`）の 4 段で、CI でも同じ順に回ります。

---

## 6. アンチパターン（やらないこと）

1. **外部 SSG（MkDocs / Starlight）へ移行しない。** 2 秒でビルドできる現状の利点を失う。
   必要な機能は 100〜300 行の Zig で足りる（このリポジトリの実績）。
2. **ページ数を増やして「充実した」ことにしない。** いま 192 ページのうち読者向けは 10。
   問題は総量ではなく**種別の欠落**。
3. **API に実装の理由を書かない。** 理由は `docs/decisions/` に、使い方は `///` に。
4. **例を手で貼らない。** 検証できない例は、書かないより悪い（古い例は嘘になる）。
5. **バージョン切替を今作らない。** 0.1.0 のうちは「対応 Zig / Tauri」の 1 行で足りる。
6. **検索に外部サービスを入れない。** 静的な索引で 886 件は十分速い。

---

## 7. 参照した一次情報

| サイト | URL | 何を得たか |
|---|---|---|
| Angular | <https://angular.dev/> | ホームの 2 入口、Features のライブコード、AI 章 |
| Angular | <https://angular.dev/essentials> | 「コーヒー 1 杯」の概念ツアー、前提知識の明示 |
| Angular | <https://angular.dev/api/core/Signal> | API ページ = 索引 + 型 + 説明。例はガイド側 |
| Angular | <https://angular.dev/llms.txt> | 章立てと全 URL の機械可読目次 |
| Tauri | <https://v2.tauri.app/> | 9 タブのコマンド、価値提案 4 つ |
| Tauri | <https://v2.tauri.app/start/> | `start / concept / develop / distribute / learn / plugin / reference` の地図 |
| Tauri | <https://v2.tauri.app/develop/calling-rust/> | 章内アンカー、Rust と TS を対にした例 |
| Tauri | <https://v2.tauri.app/security/capabilities/> | 「守るもの / 守らないもの」、`$schema` による補完 |
| Tauri | <https://v2.tauri.app/llms.txt> | 4 種の `llms` セット |
| Rust | <https://www.rust-lang.org/learn> | 本 / 例 / 手の 3 モード、辞書の一覧、オフライン |
| Rust | <https://doc.rust-lang.org/std/index.html> | "How to read this documentation"、Summary、Source |
| Rust | <https://doc.rust-lang.org/book/> と第 1 章 | 章送り、`S` / `?`、print.html、Listing 番号 |
| Rust | <https://doc.rust-lang.org/rustdoc/how-to-write-documentation.html> | 文書構造の規約、Panics/Errors/Safety、doctest |
| React | <https://react.dev/learn> | 範囲の宣言（「日常使う 80%」）、`You will learn`、術語の MDN リンク、実行可能な例 |
| Kubernetes | <https://kubernetes.io/docs/concepts/> | 1 文つき索引、タスク志向の分類 |
| Go | <https://go.dev/blog/examples> | Testable Examples（`// Output:`）、命名規約、"executable documentation" |
| Python | <https://docs.python.org/3/glossary.html> | 定義元リンク、用語間の相互参照、PEP・HOWTO へのインラインリンク |
| Deno | <https://docs.deno.com/runtime/reference/ts_config_migration/> | 移行の 1 行表、断定（delete / keep） |
| TypeScript | <https://www.typescriptlang.org/tsconfig/> | カテゴリ索引、安定アンカー、Default / Related / Released |
| Vue | <https://vuejs.org/guide/introduction.html> | Prerequisites（前提知識を書いて読者を MDN へ返す）、Progressive Framework の位置づけ |
| Kubernetes | <https://kubernetes.io/docs/home/> | ホーム = 4 つの入口 ×（1 文 + 代表リンク + CTA）、対応バージョンの明記 |

Diátaxis（Tutorial / How-to / Reference / Explanation の 4 分類）は、3 サイトの情報設計を
整理する枠組みとして参照した一般に知られた分類です（この文書では §3 P9 でのみ使用）。

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-11-14 -->
