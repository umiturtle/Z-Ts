# Task M5-06: ドキュメントの充実 + GitHub Pages 公開（Markdown → 静的サイト）

- **Status**: `in_progress`（**2026-10-30 に GitHub Pages へ初回公開済み** —
  <https://umiturtle.github.io/Z-Ts/>。残りはスクリーンショット画廊の取り込みのみ）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/docsite/`（新規）, `build.zig`, `zigw`, `.github/workflows/pages.yml`（新規）,
  `docs/architecture/documentation-site.md`, `docs/decisions/0018-documentation-site.md`,
  `docs/INDEX.md`, `README.md`, 本ファイル
- **Upstream Reference**: なし（`std` のみ）。Markdown の挙動は GitHub のレンダリング
  （GFM + `github-slugger` のアンカー規則）に合わせている
- **Next Step**: ギャラリーの PNG（`M5-04`）を Pages に載せる。CI の
  `upload-artifact`（`shots-*`）を Pages ワークフローで取得するか、`examples/gallery` を
  Pages ジョブでも実行して `_site/gallery/` に置き、`examples/gallery/README.html` から
  画像ギャラリーのページを生成する。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 60 本以上の Markdown を「読める場所」に置く。目次・検索・リンク検査を自動化し、
`examples/` のビルド済み成果物（カウンターの SSG、9 フレームワークのデモ）をブラウザで触れる
ようにする。実装はリポジトリ自身の Zig で行う（外部の静的サイトジェネレータを持ち込まない）。

- [x] `src/docsite/markdown.zig` — GFM 相当のレンダラ（**12 テスト**）
  - 見出し（GitHub 互換 slug・CJK 保持・重複採番）/ 段落 / 強調 / インラインコード /
    フェンス（info string 付き）/ GFM テーブル（`\|` と桁揃え）/ ネストしたリスト・
    タスクリスト / 引用 / 水平線 / 生 HTML ブロック / 画像 / 自動リンク / ハードブレーク
  - 相対 `.md` リンクの `.html` 化、外部リンクの `target="_blank"`、ページ単位の書き換え規則
- [x] `src/docsite/site.zig` — ページシェル・サイドバー・目次・検索インデックス・リンク検査
      （**8 テスト**）
- [x] `src/docsite/demos.zig` — サンプル公開（絶対 URL → 相対 URL、**8 テスト**）
- [x] `src/docsite/main.zig` + `mod.zig` — 収集・2 パス描画・書き出し・`OK docsite …` マーカー
- [x] `zig build docs` / `./zigw quick-test` / `zig build test` への組み込み
- [x] `.github/workflows/pages.yml` — `main` への push で docs + counter SSG + frameworks を公開
- [x] ドキュメント: 本ファイル / `docs/architecture/documentation-site.md` / ADR-0018 /
      `docs/INDEX.md` への追記
- [ ] スクリーンショット（`M5-04`）をサイトに載せる
- [ ] 各フレームワークのデモへのリンクを `examples/frameworks/README.md` から張る（現在は
      生成サイトの `/examples/frameworks/index.html` が入口）
- [x] `./zigw quick-test` / `build test -Dgtk=true|false` / `fmt --check` / `check-docs`
- [x] Pages ワークフローが**未設定でも緑**になる（run `40999281238` / `41000081966` で実証。
      失敗アノテーション 0 件・`Pages not enabled` の警告 1 件）
- [x] リポジトリ設定（Pages → Source: GitHub Actions）後の初回デプロイを確認
      （run [`41004100950`](https://github.com/umiturtle/Z-Ts/actions/runs/41004100950) /
      `main` `01132a6` = success、Deploy ジョブも success。
      `GET /repos/umiturtle/Z-Ts/pages` → `build_type: workflow`、
      公開 URL <https://umiturtle.github.io/Z-Ts/>）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - レンダラ（`markdown.zig`）: 12 テスト。GitHub の slug 規則に合わせて `.` は削除、CJK は保持
  - シェル（`site.zig`）: 8 テスト。`relativeHref` は共通ディレクトリを畳む
  - サンプル公開（`demos.zig`）: 8 テスト。`="/…`、`:"/…`、`url(/…`、`href="/"` を書き換え
  - 生成: `./zigw build docs` → **86 ページ / 207 リンク / 6,868 アセット URL / 311,648 語 /
    60 デモファイル**、`zig-out/docs` は約 4.7 MB
  - アセット検査: 生成した全 HTML の `src=` / `href=` を書き出しツリーと突き合わせる
    （壊れていれば `error.BrokenAssets`）。Nuxt の `_payload.json` のみ既知の欠落として除外。
  - ガイド（`getting-started` / `migrating-from-tauri` / `troubleshooting`）と
    `reference/cli.md` を追加し、README を実質的なフロントページにした
  - リンク検査: 初回実行で既存ドキュメントの壊れたリンク **11 本**を検出 → 6 本は生成対象漏れ
    （`examples/*/README.md` の読み込み上限 1 KB が原因）、5 本はサイト外ファイル（GitHub
    blob URL へ自動差し替え）で解消
  - `zig build test -Dgtk=false`: **52/52 steps, 289/291 tests**（2 skipped）
- **作業中・直前の状態**: CI run `40979757166`（`81a2447`）で **4/4 green**、
  Linux の `Render the documentation site and verify every internal link (M5-06 gate)` も success。
  Pages の初回有効化はワークフローが試みるが、`GITHUB_TOKEN` では Pages サイトを作成できない
  ことを実測で確認済み（`Create Pages site failed. Error: Resource not accessible by integration`）。
  その場合は `::warning::` を出して**公開だけスキップ**し、ジョブは緑のまま。
  リポジトリ管理者が Settings → Pages → Source = GitHub Actions にすれば、次の push で公開される。
- **再開するとき**: `./zigw build docs` が `OK docsite pages=…` を出すことを確認し、
  `python3 -m http.server --directory zig-out/docs` で目視 → 次の増分（スクショ）へ。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **レイアウトを写像にする**: `docs/a/b.md` → `docs/a/b.html`。これでリポジトリ内の相対リンクが
  そのまま動く（拡張子だけ書き換える）。URL 設計を凝ると全リンクの書き換えが必要になる。
- **リンク切れをビルドで落とす**: 生成対象の集合と突き合わせる。サイト外ファイルへのリンクは
  「リポジトリに実在する」ものだけ GitHub の blob URL に差し替え、**そのページだけ再描画**する
  （2 パス）。実在しなければ失敗。
- **`std.Io.Writer.Allocating` のエラー集合は `error{WriteFailed}`**: `Allocator.Error!T` を
  宣言した関数から `try w.writeAll(...)` は通らない。内部は `Error = Allocator.Error ||
  error{WriteFailed}` で受け、公開境界（`render` など）で `OutOfMemory` に畳む。
- **`{` を `std.fmt` で扱わない**: HTML テンプレートに JS が入るので、`{root}` / `{title}` だけを
  置換する自前スキャナにした（`{{` エスケープと衝突しない）。
- **`std.mem` の 0.17 変更**: `trimLeft` / `trimRight` は **`trimStart` / `trimEnd`**。
- **Zig の細かい罠**: `align` は予約語（変数名に使うと `expected an identifier`）／
  `x + if (c) 2 else 4` は comptime_int になるので `const offset: usize = if …` と分けて書く／
  `_"…"/…"` 形式の文字列リテラルを含むテスト名はコンパイルできない。
- **アンカーは GitHub と同じ規則**: 小文字化 → 英数字と `_` 以外を削除（空白は `-`）→
  CJK はそのまま。`.` を残すと `#build.zig` になり GitHub とずれるので**削除**する。
- **サンプルの絶対 URL**: ギャラリーは `tauri://localhost/fw/react/` のルートで配信するため
  HTML が `/assets/…` を持つ。Pages は `/Z-Ts/` のサブパスなので相対化が必要。フォントだけは
  9 デモで共有するため 1 つ上（`../fonts/`）へ向ける。
- **`.nojekyll`**: `_zts/`（wasm とアセット）が Jekyll に消されないようにする。
