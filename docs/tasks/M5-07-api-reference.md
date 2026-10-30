# Task M5-07: API リファレンス生成（zig doc 相当）と「使い方」中心へのサイト再編

- **Status**: `in_progress`
- **Branch**: `arena/18884101-z-ts`
- **Scope**: `src/docsite/{apidoc.zig,mod.zig,main.zig,site.zig,assets/site.css,assets/site.js}`,
  `src/*/**.zig`（`///` ドキュメントコメントの追記）, `docs/guides/using-*.md`,
  `docs/api/`（生成物・非コミット）, `docs/architecture/documentation-site.md`,
  `docs/decisions/0019-api-reference.md`, 本ファイル
- **Upstream Reference**: `zig doc`（`std` の autodoc: 宣言ごとのシグネチャ + ドキュメント
  コメント + ソース位置）と [`docs/decisions/0018-documentation-site.md`](../decisions/0018-documentation-site.md)
- **Next Step**: 生成器・`///`・ページ構成・CI ゲートまで揃った（宣言 455/455、メンバ
  1,477/1,477、`api_undoc=0` を CI が検査）。残りは (1) ガイド相互リンクの最終確認、
  (2) `docs/tasks/milestones.md` の M5-07 行は**編集しない**決まりなので、完了は本ファイルの
  Status と PR 説明で示す、(3) 長い `Options` 型の折り畳みは将来の改善として §4 に残す。

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
      （公開宣言 **455 件 = 100%**、型メンバ **1,477/1,477 = 100%**。ページ上に未文書表示はゼロ。
      ネイティブ FFI は内部扱いのため分母から除外）
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
- **このターンの追加分（第 2〜4 波）**:
  - 公開面の `///` を全トップレベル宣言まで完了。続いて**型メンバ・ネスト型・`zts_rpc_type`
    マーカー定数まで含めて全域**に到達（宣言 455/455、メンバ 1,477/1,477）。
  - 対象: `core/host.zig`（Host の 23 メソッド + `VTable` + `RecordingHost`）/ `webview/mock.zig`
    （`HeadlessMock` 31 / `MockWindow` 20）/ `tauri/menu/mod.zig`（`MenuState`・`Node`・
    `Options`・`Backend`・`Mock`・`Commands` 27）/ `tauri/tray/mod.zig`（`TrayEvent` の
    `Point`/`Size`/`Rect` ほか 44）/ `tauri/config_import.zig`（`App`/`Build`/`Bundle`/
    `TrayIcon`/`Security`/`Scope`/`WindowConfig`）/ `webview/mod.zig`（`Engine` 31）/
    `rpc/scanner.zig` / `webview/types.zig` / `core/geometry.zig` / `tauri/{app,dialog,protocol,
    clipboard,path,fs,event,window,resources}` / `bridge/{server,sse,auth}` / `rpc/{types,codec,
    schema,ctx}` / `app_runtime.zig` / `webview/{windows,linux,macos}.zig` / `wasm/*` / `ssg/*`。
  - **ツール**: `/tmp/addfields.py` の `document_members` / `document_fns` / `document_nested`
    （インデント可変・ネスト型の doc は宣言の直前へ）と `/tmp/which.py`（生成 HTML から
    未文書の `型.メンバ` を列挙）。`/tmp` は毎セッション消えるので作り直しが必要。
  - 型メンバの `///` を約 250 件追加: `WindowSpec` / `TrackedWindow` / `WindowRegistry` /
    `BaseDirectory`(23) / `Predefined`(18) / `NativeIcon`(20) / `AboutMetadata` / `ItemKind` /
    `JsImage` / FS の全 `*Options` と `FileInfo` / `FileHandle` / `FsState` / `TrayIconOptions` /
    `TrayEvent` / `MessageDialogButtons` ほかダイアログ / `SchemeRequest` / `Capture` /
    `WindowConfig` / `EventTarget` / `EventBus` / `HeadlessMock` / `ProtocolRouter`。
  - `plugin:*` のコマンドハンドラ（`plugin:window|*` 42 件ほか）と `MenuState` / `Node` /
    `Options` / `TrackedWindow` / `WindowRegistry` のメソッドにも `///` を追加。
  - 文書化率: `zts_tauri` 22% → **59%**、`zts_webview` 16% → **51%**、`zts_core` 17% → **41%**、
    `zts_rpc` 39% → 100%（宣言ベース。内部モジュールは分母から除外）。
  - **スキャナのバグ修正**: 複数行の引数リスト（`ctx: *Ctx,`）を構造体フィールドとして拾っていた
    （幻のメンバ 187 件）。`parenDelta` を導入して括弧の深さを見るようにし、テストを 2 本追加。
  - カバレッジの「宣言 + 型メンバ」の内訳をパッケージページに明記（数値とページの食い違いを解消）。
  - `linux.zig` / `macos.zig` / `windows.zig`（各 OS バックエンドのネイティブハンドル）を内部扱いに。
- **既知の（既存の）ノイズ**: `zig build test` のログに
  `failed command: … zts_ssg_export_demo …` が出るが、同じ行は `main` でも出る。
  実体の終了コードは 0（`SSG export OK` を出力）で、ビルドは **52/52 steps succeeded**。
- **読み味の仕上げ（宣言とメンバの分離・読み込み行）**:
  - 文書化率の分母を **宣言のみ** に変更（`Coverage.total` からメンバを除外し、`member_total` /
    `member_documented` として別行で報告）。混ぜると「全宣言に `///` があるのに 24%」と読めてしまう。
  - モジュールページの冒頭に**そのまま貼れる 1 行**を追加:
    `const window = @import("zts_tauri").window;` / `const scope = @import("zts_tauri").fs.scope;`。
    ルートの `pub const x = @import("…")` を 1 段ずつ辿って解決する（`importAlias`）。型の再エクスポート
    （`@import("ctx.zig").Ctx`）は追わない。再エクスポートされていないファイルには行を出さない。
  - `/tmp/which.py` 相当の未文書一覧は **1 件も出なくなった**（公開モジュール上は 0。
    残る `api-undoc` マーカーは内部モジュールのページだけ）。
  - 検索索引から**内部モジュールのページと、内部を指す再エクスポート**を除外
    （`Page.audience` / `reexportsInternal`）。ページを隠したまま検索で差し出す状態を解消。
- **直前の検証値**:
  `OK docsite pages=184 links=328 assets=8377 words=350343 bytes=4253223 demos=60
  api_pages=90 api_decls=455 api_members=1477 api_undoc=0 api_internal=452` / `check-docs OK (75)` /
  `docsite 48` / `quick-test 7` / `build test -Dgtk=false` 52/52。
  パッケージ別（内部モジュール除外、宣言ベース）: **10 パッケージすべて 100%**
  （`zts_tauri` 168 / `zts_webview` 91 / `zts_rpc` 78 / `zts_web` 33 / `zts_foundation` 31 /
  `zts_bridge` 21 / `zts_wasm` 11 / `zts_ssg` 10 / `zts_core` 8 / `z_ts` 4）。
  型メンバも **1,477/1,477 = 100%**（最後の 1 件は `DuplicateFieldBehavior.@"error"` —
  引用符つき識別子で、以前のスクリプトが拾い損ねていた）。内部モジュールは `zts_webview` の 10 件。
  **CI ゲート**: `api_undoc=0` を `ci.yml` が検査するので、`///` の無い公開宣言が入ると赤になる。

## 3. 設計判断・技術メモ・ハマりどころ

- **なぜ自前パーサか**: `-femit-docs`（Zig 標準の autodoc）は wasm + JS の単体アプリを吐くため、
  サイトの外観・検索・リンク検査と統合できない。宣言の抽出だけを自前で行い、描画はサイトの
  テンプレートに載せる（ADR-0019）。
- **完全な Zig パーサは書かない**: 行単位 + ブレース深さで「トップレベル宣言」と
  「型本体の 1 段下のメンバ」だけを拾う。式の意味解析はしない（`zig build test` が本体の正しさを
  担保しているので、ドキュメント生成は *見た目* の都合だけを扱う）。
- **深さ計算**: 文字列リテラルと行コメントを除去してから `{` `}` を数える。`\\` を含む
  複数行文字列は行頭 `\\` で判定して読み飛ばす。
