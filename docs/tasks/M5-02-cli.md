# Task M5-02: `zts` CLI（`init` / `dev` / `build` / `doctor`）

- **Status**: `done`（4 コマンド実装済み・E2E 済み。3 OS スモークは CI `ci-cli` ジョブで常時検証）
- **Branch**: `arena/bf471265-z-ts`
- **Scope**: `src/cli/`, `build.zig`, `docs/reference/cli.md`, `docs/guides/`, 本ファイル
- **Upstream Reference**: `vendor/tauri/crates/tauri-cli/src/{dev,build,init}.rs`
  （`tauri dev` のウォッチャ + 再起動ループ、`tauri build` のバンドル手順、`tauri init` の雛形）
- **Next Step**: なし（完了）。続きは [`M5-08-docs-audience-split.md`](M5-08-docs-audience-split.md)
  （利用者向けドキュメントとリポジトリ運用の分離）と `M5-03`（パッケージャ）。

---

## 1. 目的と完了条件（Definition of Done）

- [x] `zts init [dir]`
  - [x] テンプレート（`.gitignore` / `README.md` / `build.zig` / `build.zig.zon` /
        `src/main.zig` / `web/index.html`）を**純粋関数**として生成（`template.scaffold`）
  - [x] パッケージ名の検証（`[a-z][a-z0-9_]*`, 31 文字以内）と、ディレクトリ名からの導出 /
        正規化（`apps/my-app` → `my_app`）
  - [x] Zig 0.17 の `.fingerprint` 問題への対処（`fingerprintSuggestion` / `patchFingerprint`）
  - [x] 実ファイル書き込み・非空ディレクトリの拒否・`--force`
  - [x] `--zts-path` の相対化（絶対パス・相対パスのどちらでも `build.zig.zon` に書ける形へ）
- [x] `zts` の引数解析（`args.parse`）: `init` / `dev` / `build` / `doctor` / `help` / `version`、
      未知コマンド・未知フラグ・値欠落・範囲外ポートを**エラーにする**
- [x] `zts dev`
  - [x] `web/` を配信する静的サーバ（`std.http.Server` 直・`Cache-Control: no-store`）
  - [x] `web/` + `src/` の変更監視 → `zig build` → ブラウザ自動リロード
  - [x] `--browser` / `--host` / `--port`
- [x] `zts build`
  - [x] フロントエンドのバンドル（`M5-01` エンベッダ）→ `zig build -Doptimize=… [-Dtarget=…]`
  - [x] 単一実行ファイルの出力先を表示
  - [x] `--frontend-only`（`frontend` ステップのみ）
- [x] `zts doctor`（checkout / z_ts / zig / package / dependency / web/）
- [x] `./zigw quick-test` / `build test -Dgtk=true|false` / `fmt --check` / `check-docs`
- [x] CI: 3 OS で `zts` のスモーク（`ci-cli`: `init` → `doctor` → `build` → 実行）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）
<!-- サブタスク完了・設計決定・デバッグ判明のたびにここを上書き更新すること -->
- **完了したこと**:
  - `src/cli/args.zig` — `parse(argv[1..]) → Command`、`usage()`。**16 テスト**
  - `src/cli/template.zig` — `validateName` / `defaultName` / `normalizeName` /
    `scaffold` / `render` / `fingerprintSuggestion` / `patchFingerprint`。**9 テスト**
  - `src/cli/project.zig` — `packageName` / `dependencyPath` / `executablePath` / `mimeType` /
    `isHtml` / `assetPath` / `stripQuery` / `reloadScript` / `injectReload` / `toPosix`。**9 テスト**
  - `src/cli/devserver.zig` — accept スレッド・`/__zts_dev__/state`・フィンガープリント。**2 テスト**
  - `src/cli/main.zig` — `init` / `dev` / `build` / `doctor` の実行時実装（`std.process.run` で
    `zig build` を駆動。`zts_*` は一切 import しない）
  - `build.zig` — `zts` 実行ファイルを `b.installArtifact`（`src/cli/mod.zig` のテストからは
    除外したまま。理由は `mod.zig` のコメント参照）
  - **E2E（このチェックアウト上で実測）**: `init demo`（6 ファイル + fingerprint patch）→
    `build`（8 秒）→ 実行で `1 embedded assets` → `doctor` が `all checks passed` →
    `--frontend-only` 167 ms → `dev --port 5199` で編集検知（`v` 増加）・ビルド失敗時は
    `ok:false` かつ `v` 据え置き・復旧で `v` 再増加。
  - `src/cli/mod.zig` — **35 テスト**（`./zigw test src/cli/mod.zig`）
- **作業中・直前の状態**: 完了。CI の `ci-cli` ジョブ（3 OS）がこの振る舞いを常時検証する。
- **再開するとき**: `./zigw test src/cli/mod.zig` → `./zigw build` → `zig-out/bin/zts help`。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **CLI は `zts_*` を import しない**: `zts` は「ユーザーの `zig build` を駆動する」だけの
  ツールで、ライブラリをリンクする必要がない。そのおかげで `quick-test` に載せられ、
  コールドスタートでも 1 秒未満で回る。`206 Range` や MIME が要る `zts dev` では
  `zts_web` を**リンクする**（依存が増えるのはそこだけ）。
- **生成プロジェクトも共通エンベッダを使う**: 生成 `build.zig` は
  `dep.builder.path("src/build_tools/embed_main.zig")` で `M5-01` のエンベッダを起動する。
  生成側にスキャナの写しを作らないので、gzip / CSP の改善が全プロジェクトに自動で効く。
- **Zig 0.17 の `.fingerprint` は計算できない**: `build.zig.zon` は `.name` があると
  `.fingerprint` を要求する。値は「名前のハッシュ上位 32 bit + ランダムな下位 32 bit」で、
  名前部分のハッシュ関数はコンパイラ内部にあり stdlib から呼べない。**テンプレートには
  `0x0000000000000000` を書き、最初の `zig build` が stderr に出す
  `... use this value: 0x...` を `fingerprintSuggestion` で拾って patch する**方針にした
  （実測: `demo_app` に対して `0xe244585b…` が提示され、下位 32 bit は毎回変わるが
  上位が合っていれば検証を通る）。
- **`{{NAME}}` 置換は `std.fmt` を使わない**: テンプレート本体が Zig ソースで `{` だらけなので、
  `std.fmt` の `{{` エスケープと衝突する。手書きスキャンで `{{TOKEN}}` だけを置換し、
  未知トークンは**そのまま残す**（タイポがテストで露見する）。
- **テンプレートは「初回ビルドで CSP が効く」ようにした**: `web/index.html` にインラインの
  `<style>` と `<script>` を置いてあるので、`zts init` 直後のビルドで
  エンベッダが `csp=2` を報告する（`M5-01` の CSP ハッシュ経路が最初から可視化される）。
- **`dev` の既定バインドは `127.0.0.1`**: Arena のプレビューはプロキシ越しに `Host` を
  転送するので、開発サーバを 0.0.0.0 に晒す必要はない（明示的に `--host 0.0.0.0` も可能）。
