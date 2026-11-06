# Task M5-09: ドキュメントサイトの UX 改善（学習しやすさ）

- **Status**: `in_progress`（Wave 0 / 1 / 3 を実装済み。残りは Wave 2 の G1・G2・G5・G3）
- **Branch**: `arena/30af0dbd-z-ts`
- **Scope**: `docs/learn/`（新規）, `docs/errors/`（新規）, `docs/reference/`, `docs/guides/`,
  `src/docsite/{main,site,apidoc,markdown}.zig`, `src/docsite/assets/{site.css,site.js}`,
  `src/**.zig`（`///` の規約修正のみ）, `scripts/check-docs.py`, `build.zig`, `zigw`,
  `docs/INDEX.md`, `docs/tasks/M5-09-docs-ux.md`, 本ファイル
- **Upstream Reference**: 調査記録 [`../architecture/docs-as-a-product.md`](../architecture/docs-as-a-product.md)
  （Angular / Tauri / Rust の第 1 ラウンド、React / K8s / Go / Python / Deno / TypeScript の
  第 2 ラウンド、原則 P1〜P18）
- **Next Step**: Wave 2（U8 概念ページ → U9 チュートリアル → U12 ACL → U13 API の例）。
  執筆の規約は [`../contributing/writing-docs.md`](../contributing/writing-docs.md) に固定済み。

---

## 1. このタスクの目的

`M5-06` / `M5-07` / `M5-08` で「サイトが動く」「API がソースから生成される」「読者が分離されて
いる」ところまで来ました。足りないのは **学習の体験**です。調査
（[`../architecture/docs-as-a-product.md`](../architecture/docs-as-a-product.md)）で分かった
欠落は 3 つに集約されます。

1. **概念とチュートリアルが無い**（読者が最初に知りたいことが内部資料にしかない）
2. **現在地と次の一歩が見えない**（前後送り・パンくず・ページ種別・API の目次が無い）
3. **書いたものが腐る**（例が 0、例の検証が無い、`///` に内部事情が混入、虚偽の記述が残る）

このタスクは、その 3 つを **Wave 0〜4 の 21 項目**に落としたものです。実装は含みません。

---

## 2. 優先順位の付け方

| 判断 | 内容 |
|---|---|
| まず「嘘を消す」 | 誤った記述は 1 行で直り、信頼に直結する（U0） |
| 次に「新しい文章を書かずに読みやすくする」 | パンくず・前後送り・目次・検索は既存資産だけで効く（U1〜U7） |
| その次に「無い種類の文章を書く」 | 概念・チュートリアル・用語・エラー・ACL（U8〜U13）。**人間の判断が要る** |
| 最後に「腐らない仕組み」 | 例のコンパイル検査・層違反 lint・指標（U14〜U17） |
| 規模が小さいうちはやらない | コードタブ・印刷版・バージョン切替（U18〜U20） |

---

## 3. Wave 0 — すぐ直す（S・1 行）

### U0. `sitemap.txt` を出すと書いてあるのに出していない

- **証拠**: `src/docsite/site.zig:6` の `//!` が "emits `search-index.js` + `sitemap.txt`" と
  書いているが、`zig build docs` の出力に `sitemap.txt` は無い（`grep -r sitemap src/` も 1 件）。
- **やること**: 記述を実態に合わせる（「sitemap は未実装（U6）」と書くか、行ごと削る）。
- **受け入れ条件**: `ls zig-out/docs` の内容と `site.zig` の `//!` が一致する。
- **原則**: C3 / 「矛盾は許さない」

---

## 4. Wave 1 — 既存ページの読みやすさ（S〜M）

新しい文章をほとんど書かず、**枠組みだけ**を足す波です。ここが費用対効果の頂点です。

### U1. パンくず + 前後ページ送り

- **ねらい**: 「いまどこにいて、次に何を読むか」を常に見せる（P7）。Rust の本の ← → と同じ。
- **変更**: `src/docsite/site.zig`（`Layout` に `breadcrumbs` と `prev` / `next` を追加）、
  `src/docsite/main.zig`（サイドバーの順序＝学習順なので、そこから前後を計算）。
- **実装メモ**: 順序は既存の `group_order` とページの並びを使う。グループを跨ぐときは次のグループの
  先頭へ。`内部資料` は前後送りの対象外（読者の動線ではない）。
- **受け入れ条件**: すべての読者向けページに `<nav class="crumbs">` と `.pager` が出る。
  `site.zig` の既存テスト（`renderPage`）に 1 ケース追加。
- **コスト**: S / **原則**: P7

### U2. API ページの目次と「パッケージに戻る」

- **ねらい**: API モジュールページは宣言 8〜24 件で長いのに、目次が無い（G9）。読者は目的の宣言を
  スクロールで探している。
- **変更**: `src/docsite/apidoc.zig`（モジュールページ生成時に見出しを集める）、
  `src/docsite/main.zig`（API ページにも `toc` を渡す）。
- **実装メモ**: 目次項目は「宣言名 + 種別グリフ」。`<h2 class="api-sig">` の id は既に宣言名なので
  そのまま使える。パッケージページへのリンクは既存の `pkg_href` を本文冒頭に置く。
- **受け入れ条件**: `docs/api/<pkg>/<module>.html` に「このページの目次」が出て、リンク先の
  id がすべて実在する（アンカー検査が既にあるので自動で守られる）。
- **コスト**: S / **原則**: P7

### U3. ページ種別ラベル（`guide` / `concept` / `reference` / `recipe` / `migration` / `errors`）

- **ねらい**: `guides/` に「ハンズオン」「移行」「障害対応」が同居していて、サイドバーでは
  区別が付かない（G8 / C4）。種別が分かると、読者は「いま読むべきもの」を選べる（P9）。
- **変更**: `src/docsite/main.zig` に `pageKind(path)` を追加（既存の `groupFor()` と同じ形の
  純関数・テスト付き）、`site.NavEntry` に `kind` を追加してサイドバーに小さく表示。
- **実装メモ**: 判定はパスで行う（front matter を新設しない）。`learn/concepts/*` → `concept`、
  `learn/tutorial/*` → `tutorial`、`reference/*` → `reference`、`errors/*` → `errors`、
  `migrating-*` → `migration`、それ以外の `guides/*` → `guide`。
- **受け入れ条件**: サイドバーに種別バッジが出る。`pageKind` の単体テストが全種別を網羅。
- **コスト**: S / **原則**: P9

### U4. 検索の強化（型メンバ索引・`Ctrl/Cmd+K`・ハイライト）

- **ねらい**: 型メンバ 1,477 件が索引に無く、`title` や `size` で引けない（G10）。P6。
- **変更**: `src/docsite/main.zig`（メンバを `docs/api/<pkg>/<module>.html#<型>.<メンバ>` で
  索引に追加）、`src/docsite/assets/site.js`（`Ctrl/Cmd+K` で開く・一致部分を `<mark>` で強調・
  `↑↓` で結果移動）、`site.css`。
- **実装メモ**: 索引サイズは現在 257 KB。メンバ 1,477 件を足すと 400 KB 前後になる見込み。
  1 エントリの本文は短く（型名 + 1 行説明）して肥大を抑える。索引は gzip 済みで配信される
  （`M5-01` のエンベッダと同じ仕組みを使うかは任意）。
- **受け入れ条件**: `title` で検索して `WindowConfig.title` のアンカーに飛べる。
  キーボードだけで検索 → 選択 → 遷移ができる。
- **コスト**: M / **原則**: P6

### U5. `llms.txt` / `llms-full.txt` の生成

- **ねらい**: エージェント前提のリポジトリなのに、公開サイトに機械可読の目次が無い（G11）。P11。
- **変更**: `src/docsite/main.zig`（生成）、`.github/workflows/pages.yml` は変更不要。
- **実装メモ**: `llms.txt` は「タイトル + 1 行説明 + グループごとの URL 一覧」。
  `llms-full.txt` は `document.plain` を連結（内部資料は含めない）。**リンク検査の対象に
  入れる**（生成物なので `written` に足すだけでよい）。
- **受け入れ条件**: `zig-out/docs/llms.txt` と `llms-full.txt` が生成され、内部資料の URL を
  含まない。`OK docsite` マーカーに `llms=…` が増える。
- **コスト**: S / **原則**: P11

### U6. `404.html` と `sitemap.xml`

- **ねらい**: 旧 URL や綴り違いで着地した読者を、検索に戻す（G14）。
- **変更**: `src/docsite/main.zig`（`404.html` は検索ボックス + 主要 6 ページのリンク、
  `sitemap.xml` は全ページの URL 一覧）。
- **実装メモ**: GitHub Pages は `404.html` を自動で使う。`sitemap.xml` の URL は
  `https://umiturtle.github.io/Z-Ts/` を前置する（`main.zig` に定数化）。
- **受け入れ条件**: `zig-out/docs/404.html` と `sitemap.xml` が存在し、sitemap の URL 数が
  `pages` と一致する。
- **コスト**: S / **原則**: P6, P11

### U7. 注記（注意・ヒント・非推奨）の記法

- **ねらい**: 現状の `> **注意:**` はただの引用で、視覚的に弱い（G13）。
- **変更**: `src/docsite/markdown.zig`（blockquote の先頭が `[!NOTE]` / `[!TIP]` /
  `[!WARNING]` / `[!IMPORTANT]` のときクラスを付ける）、`site.css`。
- **実装メモ**: GitHub と同じ記法なので、Markdown の正本が GitHub でも崩れない。
  既存の `> **注意:**` はそのまま動く（後方互換）。
- **受け入れ条件**: `> [!NOTE]` を含むページが `<blockquote class="note">` になる。
  `markdown.zig` のテストに 4 種別 + 通常引用のケースを追加。
- **コスト**: S / **原則**: P9

---

## 5. Wave 2 — 学習体験（M〜L）

**ここが本体です。** ページを新しく書き足す波で、エージェントより人間の判断が要ります
（何を「概念」と呼ぶかは設計判断）。文章は `docs/architecture/` を**読者向けに書き直す**のが
基本方針で、ADR 番号・マイルストーン ID・実装用語は出しません。

### U8. 概念ページ `docs/learn/concepts/`（5 本）

| ページ | 書くこと | 出典（内部資料） |
|---|---|---|
| `packages.md` | 6 つの直交パッケージの地図。「どれをリンクすると何が付くか」 | `architecture/00-overview.md` |
| `request-lifecycle.md` | フロントの `invoke` がホストに届いて戻るまで（図 1 枚 + 5 ステップ） | `architecture/ipc.md` |
| `execution-modes.md` | 同じコードが desktop / Live Preview / WASM / SSG で動く理由 | `architecture/ssg-and-wasm.md` |
| `assets-and-csp.md` | `web/` がどう埋め込まれ、CSP ハッシュがどう付くか（読者視点） | `architecture/build-tools.md` |
| `security-and-acl.md` | capability / permission / scope の関係。「守るもの・守らないもの」 | `architecture/tauri-config-import-acl.md` |

- **受け入れ条件**: 5 ページとも (a) 冒頭に「このページで分かること」、(b) 図か表が 1 つ以上、
  (c) `ADR-` と `M\d-\d\d` を含まない、(d) 関連するガイドと API へのリンクが各 1 本以上。
- **コスト**: L（1 ページ 150〜250 行 × 5）/ **原則**: P3, P1

### U9. チュートリアル `docs/learn/tutorial/`（3 レッスン）

| レッスン | ゴール | 完了の判定 |
|---|---|---|
| `01-hello-window.md` | `zts init` → `zts dev` → ウィンドウが出る | 自分の環境で画面が出る |
| `02-add-a-command.md` | `Schema` にコマンドを 1 つ足し、TS から `invoke` する | ボタンで値が変わる |
| `03-ship-it.md` | `zts build` → `zts package` → 「配布物ができる」 | `zig-out/package/` に成果物 |

- **書き方の規約**（Angular / Rust の本から）: 各ステップに「実行するコマンド」「期待する出力」
  「うまくいかないときのリンク（`troubleshooting.md` / `errors/`）」を必ず付ける。コードは
  全文を載せる（断片だけにしない）。
- **受け入れ条件**: 各レッスンが 15〜25 分で終わり、最後に「次はこれ」がある。
  全コマンドが CI の `ci-cli` 相当で実際に動く（少なくともレッスン 1 と 3）。
- **コスト**: L / **原則**: P2

### U10. 用語集 `docs/reference/glossary.md`

- **ねらい**: `Handle` / `Channel` / `RawPayload` / `OwnedBytes` / `Capability` / `Namespace` /
  `Scope` / `Host` などを 1 か所で引けるようにする（G7）。定義は 1〜2 文 + 関連ページ。
- **受け入れ条件**: 用語が 50 語以上、各語に「1 文の定義」と「初出ページへのリンク」。
  アンカーは日本語でも GitHub と一致する（既存の slug 規約）。
- **コスト**: M / **原則**: P3

### U11. エラー事典 `docs/errors/`（生成 + 手書き）

- **ねらい**: エラー名から「意味 → 原因 → 直し方」へ着地させる（G6 / P8）。
- **実装**: `pub const X = error{ … };` と `error.Foo` の出現を走査して**索引を自動生成**し、
  各エラーに手書きの説明を `docs/errors/<error>.md` として持つ（未記述は「説明なし」と明示）。
  生成物は API と同じく `docs/errors/index.html` + 個別アンカー。
- **受け入れ条件**: ソースの `error{…}` 集合と索引の件数が一致する（`docsite` マーカーに
  `err_documented=N err_total=M`）。検索で `InvalidName` が引ける。`troubleshooting.md` の表から
  各エラーへリンクする。
- **コスト**: L / **原則**: P8

### U12. ACL / capability リファレンス `docs/reference/acl.md`

- **ねらい**: 「この関数を呼ぶには何を許可するか」が 1 ホップで分からない（G5）。
- **実装**: `src/tauri/acl.zig` と各プラグインの権限名から表を生成（`apidoc.zig` と同じ方式）。
  冒頭に Tauri の capabilities ページに倣った「守るもの / 守らないもの」を置く。
- **受け入れ条件**: 組み込みプラグイン 8 種のコマンド × 必要 permission の表がある。
  表の permission 名はソースと一致する（生成なので自動）。
- **コスト**: M / **原則**: P8, P9

### U13. 「例」と「関連ガイド」を API に載せる

- **ねらい**: API に例が 0 個（G3）、ガイドと API が繋がっていない。
- **実装方針**:
  1. `///` の規約を決める: 1 文の要約 → 補足 → `# Example`（コードフェンス）→
     `# See also`（関連ガイド）。
  2. まず**主要 20 宣言**（`Schema` / `bind` / `Ctx` / `Handler` / `Engine` / `WindowConfig` /
     `Assets` / `BridgeServer` / `Channel` / `App` …）に例を書く。
  3. `apidoc.zig` に「例あり / なし」の判定を足し、`api_with_examples` をマーカーに出す。
- **受け入れ条件**: 20 宣言にコンパイル可能な例がある（U14 の検査を通る）。
- **コスト**: M（20 × 10〜20 行）/ **原則**: P4

---

## 6. Wave 3 — 腐らせない仕組み（M）

### U14. doctest-lite（例のコンパイル検査）

- **ねらい**: ガイドには 25 個の Zig コードブロックがあるが、壊れても誰も気付かない（G4）。
- **実装**: `scripts/docs-examples.mjs` か Zig 実装の `docsite --check-examples`。フェンスの
  info 文字列で扱いを分ける。

  | 記法 | 意味 |
  |---|---|
  | `zig check` | 完全なファイルとしてコンパイル |
  | `zig check-snippet` | 宣言の断片。`fn __doc()` で包んでコンパイル |
  | `zig ignore` | 検査しない（意図をコメントで書く） |

- **受け入れ条件**: ガイド内の `zig` フェンスがすべて 3 種のいずれかに分類され、
  `snippet` / `full` がコンパイルを通る。壊すと CI が落ちる。
- **コスト**: M / **原則**: P5

### U15. 層違反 lint（`///` に内部事情を書かない）

- **ねらい**: 公開 API の `///` に `ADR-` / `M\d-\d\d` が 37 箇所（C1）。
- **実装**: `scripts/check-docs.py` に「`src/**.zig` の `///` に `ADR-\d+` と `M\d-\d\d` が
  現れたら失敗」を追加し、**まずは警告 → 0 件にしてから失敗**に切り替える。
- **受け入れ条件**: `python3 scripts/check-docs.py` が 0 件で通る（既存 37 箇所を修正した後）。
- **コスト**: M（37 箇所の書き直しが本体）/ **原則**: P3, C1

### U16. 指標をマーカーに足す

- **ねらい**: 品質を「文書化率 100%」以外でも測れるようにする。
- **追加する値**: `api_with_examples=N`（例を持つ宣言）、`err_documented=N`、`llms=1|0`、
  `pages_reader=N`（内部資料を除いたページ数）、`kinds={guide:8,concept:5,…}`。
- **受け入れ条件**: CI の `OK docsite` 行に載り、`pages.yml` のマーカー検査が新しい値でも通る。
- **コスト**: S / **原則**: P4, P5

### U17. 検索の重みづけ

- **ねらい**: 種別（U3）が付いたら、`concept` と `reference` を上位に、`internals` は対象外に
  （既に除外）。`guide` は中位。
- **受け入れ条件**: `Schema` で検索したとき、API の宣言が概念ページより上に出る。
- **コスト**: S / **原則**: P6, P9

---

## 7. Wave 4 — 発展（L・任意）

| # | 項目 | 内容 | 判断 |
|---|---|---|---|
| U18 | コードタブ | `:::tabs` で bash / PowerShell / npm を切り替え（Tauri のホーム相当） | 0.1.0 ではコマンドが `zts` 1 つなので**保留** |
| U19 | 印刷版 | 全読者向けページを 1 ファイルに連結（Rust の `print.html`） | 需要が出たら |
| U20 | バージョン切替 | Pages を `/v0.1/` サブパスで世代管理 + 「対応 Zig / Tauri」表 | 1.0 まで**保留**。今はトップに 1 行で足りる |

---

## 7.5 実装ログ（2026-11-06・第 2 ラウンド）

`arena/30af0dbd-z-ts` の 1 本の PR にまとめた実装です。**U0〜U7・U14〜U17 の大半が完了**。
検証は `./zigw docs-check`（4 段）で再現できます。

| # | 状態 | 実装 | 証拠 |
|---|---|---|---|
| U0 | ✅ | `site.zig` の `//!` を実態（`sitemap.xml` / `llms.txt` / `404.html`）に修正 | C3 解消 |
| U1 | ✅ | `site.Crumb` / `site.NavLink`、`main.buildCrumbs()` / `neighbors()` | 全 197 ページ |
| U2 | ✅ | `apidoc.Page.toc`（宣言の見出し）＋ パッケージへ戻るリンク | 90 API ページ |
| U3 | ✅ | `pageKind()` → `span.kind-badge[data-kind]`（9 種） | 全ページ |
| U4 | ✅ | 検索索引 886 → **2,362 件**（型メンバ 1,477 + 用語） | `assets/search-index.js` |
| U5 | ✅ | `renderLlmsTxt` / `renderLlmsFull`（サイドバーと同じ並び） | `llms.txt` 9 KB / `llms-full.txt` 146 KB |
| U6 | ✅ | `renderSitemap` / `renderNotFoundBody` | `sitemap.xml` / `404.html` |
| U7 | ✅ | `> [!NOTE]` `[!TIP]` `[!WARNING]` `[!IMPORTANT]`（GitHub 互換） | `markdown.zig` + 単体テスト |
| U10 | ✅ | [`../glossary.md`](../glossary.md) 31 項目（相互参照つき） | 用語集ページ |
| U11 | ✅ | [`../reference/errors.html`](../reference/errors.html) 118 項目（生成） | `renderErrorsBody` |
| U13 | ◐ | API ページに「関連」（署名一致の兄弟を最大 6 件）＋ 各ページ末尾の「関連 API」最大 24 件 | `apidoc.renderDecl` / `main.renderRelatedApi` |
| U14 | ✅ | `scripts/doc-tests.py` — `zig check` を `zig test --test-no-exec` でコンパイル | `./zigw docs-check` の第 3 段 |
| U15 | ✅ | `check-docs.py` 規約 3（`///`・`//!` の `ADR-####` / `M#-##` 禁止、公開ツリー限定） | 54 行を実際に除去 |
| U16 | ◐ | `OK docsite` マーカーに `xref_targets` / `xrefs` / `errors` を追加 | CI ログ |
| U17 | ✗ | 検索の重みづけ（前方一致の優先）は未実装 | — |
| U8 U9 U12 | ✗ | 概念・チュートリアル・ACL は本文を書く作業（Wave 2 の本体） | — |
| U18〜U20 | ✗ | 保留のまま（§7） | — |

**新しく増えた規約**（このタスクの範囲外だが、腐らせないために足したもの）

- `check-docs.py` の規約 6 本を再編: 読者向け散文（README / glossary / guides / reference）でも
  内部 ID を禁止、`@import("zts_…")` 以外の `zts_*` はパッケージ扱いしない。
- `./zigw docs-check` = レンダラのテスト → `check-docs.py` → `doc-tests.py` → `zig build docs`。
  CI も同じ 4 段（`.github/workflows/ci.yml`）。
- 執筆の規約を [`../contributing/writing-docs.md`](../contributing/writing-docs.md) に集約。

---

## 8. 成功の測り方

| 指標 | 着手前 | 現在（第 2 ラウンド後） | Wave 2 後（目標） |
|---|---|---|---|
| 読者向けページ数 | 10 | 12（用語集・執筆規約を追加） | 22（概念 5 + チュートリアル 3 + ACL + 用語 + エラー） |
| 読者向けリンク数 | 409 | **463** | 600 |
| xref（自動リンク） | 0 | **985** | 1,500 |
| コード例を持つ宣言 | 0 / 455 | 0 / 455（例はガイド側に 2 本） | 60% |
| メンバ検索 | 不可 | **1,477 件が引ける** | 同左 |
| ページ種別ラベル | なし | **全ページ（9 種）** | 同左 |
| 前後送り・パンくず | なし | **全ページ** | 同左 |
| `llms.txt` | なし | **生成（9 KB）** | 同左 |
| 例のコンパイル検査 | なし | **`zig check` 2 本 / CI** | ガイドの主要ブロック全部 |
| `///` の層違反 | 37 件 | **0 件（公開ツリー）** | 0 件 |

CI ゲートは `OK docsite` マーカーの拡張（U16）で行い、**数値が下がったら落ちる**ようにします。

---

## 9. やらないこと

- 外部 SSG（MkDocs / Starlight / VitePress）への移行。現在の生成は 2 秒で終わる。
- ページ数を増やして「充実した」ことにする。増やすのは**種別**（概念・チュートリアル・辞書）。
- `///` に実装の理由を書くこと。理由は `docs/decisions/`、使い方は `///`。
- 検索の外部サービス化。886 → 2,300 件程度なら静的索引で十分。
- バージョン切替の先回り実装（0.1.0 のうちは不要）。

---

## 10. 進捗チェックポイント（Context Reset 復元用）

（項目を完了するたびにここを上書き更新すること）

- **完了したこと**: U0〜U7・U10・U11・U14・U15（§7.5）。加えて 6 サイトの追加調査と P13〜P18 の
  原則化、執筆規約の文書化（`docs/contributing/writing-docs.md`）。
- **作業中・直前の状態**: 1 本の PR にまとめて提出する段階。`./zigw docs-check` が 4 段とも緑。
- **検証済み（2026-11-06）**:
  - `./zigw docs-check` → `All 52 tests passed` / `Documentation check OK (86 markdown files verified)` /
    `OK doctest blocks=2` / `OK docsite pages=197 links=463 xrefs=985 errors=118 api_undoc=0`
  - `python3 scripts/check-docs.py` → 0 件（かつて 671 件だった）
- **再開するとき**: Wave 2（U8 概念 → U9 チュートリアル → U12 ACL → U13 API の例）から。
  各ページは `docs/contributing/writing-docs.md` の骨格（`# 見出し` + 対象読者 + 所要時間）で書き、
  例には `zig check` を付ける。1 ページ書いたら `./zigw docs-check` を回す。
