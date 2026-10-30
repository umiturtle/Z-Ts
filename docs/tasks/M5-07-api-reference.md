# Task M5-07: API リファレンス生成（zig doc 相当）と「使い方」中心へのサイト再編

- **Status**: `in_progress`
- **Branch**: `arena/18884101-z-ts`
- **Scope**: `src/docsite/{apidoc.zig,mod.zig,main.zig,site.zig,assets/site.css,assets/site.js}`,
  `src/*/**.zig`（`///` ドキュメントコメントの追記）, `docs/guides/using-*.md`,
  `docs/api/`（生成物・非コミット）, `docs/architecture/documentation-site.md`,
  `docs/decisions/0019-api-reference.md`, 本ファイル
- **Upstream Reference**: `zig doc`（`std` の autodoc: 宣言ごとのシグネチャ + ドキュメント
  コメント + ソース位置）と [`docs/decisions/0018-documentation-site.md`](../decisions/0018-documentation-site.md)
- **Next Step**: `src/docsite/apidoc.zig` のスキャナ（`//!` / `///` / `pub fn` / `pub const` /
  `pub var` / 型本体のメンバ）を実装し、`docs/api/**` を生成してサイドバーの
  「API リファレンス」グループに載せる。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 公開サイトを「開発の記録」ではなく「使う人のためのドキュメント」に振り直す。
実装意図（ADR・タスク・設計メモ）はサイドバーから外して 1 ページに畳み、代わりに
**`zig doc` 相当の API リファレンス**（全公開宣言 + シグネチャ + ドキュメントコメント +
ソース位置）と**使い方ガイド**を主役にする。

- [ ] 生成器はリポジトリ内の Zig のみ（外部ツール・外部 CDN なし）
- [ ] `zig build docs` が `docs/api/**` を生成し、リンク検査・アセット検査の対象に入る
- [ ] 全公開宣言がページに載る（本文コメントが無い宣言も「未文書」と分かる形で載せる）
- [ ] サイドバーは「はじめに / ガイド / API リファレンス / サンプル / 内部資料」の順になり、
      内部資料（ADR・タスク・設計・ロードマップ・環境）は**個別ページとして並ばない**
- [ ] 検索は利用者向けページ + API 宣言だけを対象にする（内部資料は出さない）
- [ ] 主要 API の `///` カバレッジを引き上げ、生成ページに「未文書宣言」の一覧を出す
- [ ] `./zigw quick-test` / `./zigw build docs` / `python3 scripts/check-docs.py` が通る

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 現状調査: 公開宣言 2,221 件 / `///` 付き 577 件（26%）。`src/tauri/` 791 件、`src/webview/` 629 件が
    大きい。サイトのサイドバーは 10 グループで ADR 18 本・タスク 25 本が並んでいる。
- **作業中・直前の状態**:
  - `src/docsite/apidoc.zig` を新規実装中（スキャナ → レンダラ → テスト）。
- **Next Step**:
  - スキャナのテストを先に書き、`docs/api/index.html` を生成してから配線する。

## 3. 設計判断・技術メモ・ハマりどころ

- **なぜ自前パーサか**: `-femit-docs`（Zig 標準の autodoc）は wasm + JS の単体アプリを吐くため、
  サイトの外観・検索・リンク検査と統合できない。宣言の抽出だけを自前で行い、描画はサイトの
  テンプレートに載せる（ADR-0019）。
- **完全な Zig パーサは書かない**: 行単位 + ブレース深さで「トップレベル宣言」と
  「型本体の 1 段下のメンバ」だけを拾う。式の意味解析はしない（`zig build test` が本体の正しさを
  担保しているので、ドキュメント生成は *見た目* の都合だけを扱う）。
- **深さ計算**: 文字列リテラルと行コメントを除去してから `{` `}` を数える。`\\` を含む
  複数行文字列は行頭 `\\` で判定して読み飛ばす。
