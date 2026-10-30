# Task M5-07: API リファレンス生成（zig doc 相当）と「使い方」中心へのサイト再編

- **Status**: `in_progress`
- **Branch**: `arena/18884101-z-ts`
- **Scope**: `src/docsite/{apidoc.zig,mod.zig,main.zig,site.zig,assets/site.css,assets/site.js}`,
  `src/*/**.zig`（`///` ドキュメントコメントの追記）, `docs/guides/using-*.md`,
  `docs/api/`（生成物・非コミット）, `docs/architecture/documentation-site.md`,
  `docs/decisions/0019-api-reference.md`, 本ファイル
- **Upstream Reference**: `zig doc`（`std` の autodoc: 宣言ごとのシグネチャ + ドキュメント
  コメント + ソース位置）と [`docs/decisions/0018-documentation-site.md`](../decisions/0018-documentation-site.md)
- **Next Step**: 残りの `///`（`src/tauri/menu/mod.zig` 7 / `tray/mod.zig` 5 /
  `menu/snapshot_wire.zig` 3 / `tauri/resources.zig` 2 / `src/wasm/*` 6 / `webview/windows.zig` 1 /
  `webview_host.zig` 1）。ネイティブ FFI（`gtk_bindings` / `win32` / `webview2_com` 等 111 件）は
  内部モジュール扱いなので対象外。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 公開サイトを「開発の記録」ではなく「使う人のためのドキュメント」に振り直す。
実装意図（ADR・タスク・設計メモ）はサイドバーから外して 1 ページに畳み、代わりに
**`zig doc` 相当の API リファレンス**（全公開宣言 + シグネチャ + ドキュメントコメント +
ソース位置）と**使い方ガイド**を主役にする。

- [x] 生成器はリポジトリ内の Zig のみ（外部ツール・外部 CDN なし）
- [x] `zig build docs` が `docs/api/**` を生成し、リンク検査・アセット検査・アンカー検査の対象に入る
- [x] 全公開宣言がページに載る（本文コメントが無い宣言も「未文書」と分かる形で載せる）
- [x] サイドバーは「はじめに / ガイド / API リファレンス / サンプル / 内部資料」の順になり、
      内部資料（ADR・タスク・設計・ロードマップ・環境）は**個別ページとして並ばない**
- [x] 検索は利用者向けページ + API 宣言だけを対象にする（内部資料は出さない）
- [x] 主要 API の `///` カバレッジを引き上げ、生成ページに「未文書宣言」の一覧を出す
      （公開面 1,932 宣言中 **1,079 件 = 55%**、トップレベルの宣言は未文書ゼロ。残りは主に
      各 `Commands` ハンドラの内部ヘルパと `z_ts` の再エクスポート）
- [x] `./zigw quick-test` / `./zigw build docs` / `python3 scripts/check-docs.py` が通る
- [x] **追加**: 読者向け / 内部向けの層分け（`docs/guides/README.md`）と API の公開・内部分離
      （`Audience`）— 学習中に FFI 宣言へ暴露されない

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**（`2d80f42` まで。詳細は commit message と ADR-0019）:
  - `src/docsite/apidoc.zig`（**44 テスト**）: 相対 `@import` グラフ走査 → 宣言/メンバ/`///`/
    シグネチャ抽出 → 3 層ページ（全体 / パッケージ / モジュール、**90 ページ**）。
  - `Audience { user, internal }`: FFI テーブルと `*_test.zig` を折り畳み・バナー・検索/索引/
    文書化率から除外（`api_internal=290`）。
  - `verifyAssets` のアンカー検査（`error.DanglingAnchors`）、出力ツリーの事前削除、
    `zig build docs` を `zig-out/docs` 直書きに変更（`InstallDir` が古いページを残していた）。
  - サイト再編: はじめに / ガイド / API / サンプル / 内部資料、`docs/internals/index.html`、
    内部資料の検索除外、`docs/guides/README.md`（4 層の学習の道筋）。
  - ガイド 3 本（`using-rpc` / `using-plugins` / `using-ssg`）+ ADR-0019 + 本ドキュメントの
    アーキテクチャ更新 + CI/Pages のゲート追加。
  - 公開面の `///` 約 90 件（webview / tauri / rpc / bridge / core / ssg / app_runtime）。
- **このターンの追加分**:
  - 公開面の `///` を全トップレベル宣言まで完了（未文書として残るのは内部モジュール 109 件のみ）。
  - 型メンバの `///` を約 250 件追加: `WindowSpec` / `TrackedWindow` / `WindowRegistry` /
    `BaseDirectory`(23) / `Predefined`(18) / `NativeIcon`(20) / `AboutMetadata` / `ItemKind` /
    `JsImage` / FS の全 `*Options` と `FileInfo` / `FileHandle` / `FsState` / `TrayIconOptions` /
    `TrayEvent` / `MessageDialogButtons` ほかダイアログ / `SchemeRequest` / `Capture` /
    `WindowConfig` / `EventTarget` / `EventBus` / `HeadlessMock` / `ProtocolRouter`。
  - `plugin:*` のコマンドハンドラ（`plugin:window|*` 42 件ほか）と `MenuState` / `Node` /
    `Options` / `TrackedWindow` / `WindowRegistry` のメソッドにも `///` を追加。
  - 文書化率: `zts_tauri` 22% → **59%**、`zts_webview` 16% → **51%**、`zts_core` 17% → **41%**、
    `zts_rpc` 39% → **54%**、全体 21% → **55%**（1,932 宣言中 1,079 件。内部モジュールは分母から除外）。
  - **スキャナのバグ修正**: 複数行の引数リスト（`ctx: *Ctx,`）を構造体フィールドとして拾っていた
    （幻のメンバ 187 件）。`parenDelta` を導入して括弧の深さを見るようにし、テストを 2 本追加。
  - カバレッジの「宣言 + 型メンバ」の内訳をパッケージページに明記（数値とページの食い違いを解消）。
  - `linux.zig` / `macos.zig` / `windows.zig`（各 OS バックエンドのネイティブハンドル）を内部扱いに。
- **既知の（既存の）ノイズ**: `zig build test` のログに
  `failed command: … zts_ssg_export_demo …` が出るが、同じ行は `main` でも出る。
  実体の終了コードは 0（`SSG export OK` を出力）で、ビルドは **52/52 steps succeeded**。
- **直前の検証値**:
  `OK docsite pages=183 links=324 assets=8159 words=344797 bytes=4185561 demos=60
  api_pages=90 api_decls=2119 api_internal=527` / `check-docs OK (74)` /
  `docsite 46` / `quick-test 7` / `build test -Dgtk=false` 52/52（184 tests）。
- **Next Step**:
  - 残り 25 件の `///`（menu / tray / snapshot_wire / resources / wasm / windows / webview_host）。
  - 公開面の文書化率を上げる第 2 波（`zts_tauri` の DTO、`z_ts` の re-export 以外）。

## 3. 設計判断・技術メモ・ハマりどころ

- **なぜ自前パーサか**: `-femit-docs`（Zig 標準の autodoc）は wasm + JS の単体アプリを吐くため、
  サイトの外観・検索・リンク検査と統合できない。宣言の抽出だけを自前で行い、描画はサイトの
  テンプレートに載せる（ADR-0019）。
- **完全な Zig パーサは書かない**: 行単位 + ブレース深さで「トップレベル宣言」と
  「型本体の 1 段下のメンバ」だけを拾う。式の意味解析はしない（`zig build test` が本体の正しさを
  担保しているので、ドキュメント生成は *見た目* の都合だけを扱う）。
- **深さ計算**: 文字列リテラルと行コメントを除去してから `{` `}` を数える。`\\` を含む
  複数行文字列は行頭 `\\` で判定して読み飛ばす。
