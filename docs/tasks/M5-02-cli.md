# Task M5-02: `zts` CLI（`init` / `dev` / `build`）

- **Status**: `in_progress`（引数解析と `init` テンプレートまで完了。`main.zig` / `dev` / `build` は未完）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/cli/`, `build.zig`, `zigw`, `docs/architecture/cli.md`（予定）,
  `docs/roadmap/m2-m5-platform-and-ecosystem.md`, 本ファイル
- **Upstream Reference**: `vendor/tauri/crates/tauri-cli/src/{dev,build,init}.rs`
  （`tauri dev` のウォッチャ + 再起動ループ、`tauri build` のバンドル手順、`tauri init` の雛形）
- **Next Step**: `src/cli/main.zig` を追加し、`init` を実 IO に繋ぐ
  （`template.scaffold` の結果を `Io.Dir.cwd().createDirPath` + `writeFile` で書き、
  空でないディレクトリは `--force` が無ければ拒否。続けて `zig build` を 1 回叩いて
  `fingerprintSuggestion` で `build.zig.zon` を patch する）。

---

## 1. 目的と完了条件（Definition of Done）

- [ ] `zts init [dir]`
  - [x] テンプレート（`.gitignore` / `README.md` / `build.zig` / `build.zig.zon` /
        `src/main.zig` / `web/index.html`）を**純粋関数**として生成（`template.scaffold`）
  - [x] パッケージ名の検証（`[a-z][a-z0-9_]*`, 64 文字以内）と、ディレクトリ名からの導出 /
        正規化（`apps/my-app` → `my_app`）
  - [x] Zig 0.17 の `.fingerprint` 問題への対処（`fingerprintSuggestion` / `patchFingerprint`）
  - [ ] 実ファイル書き込み・非空ディレクトリの拒否・`--force`
- [x] `zts` の引数解析（`args.parse`）: `init` / `dev` / `build` / `help` / `version`、
      未知コマンド・未知フラグ・値欠落・範囲外ポートを**エラーにする**
- [ ] `zts dev`
  - [ ] `web/` を配信する静的サーバ（`206 Range` / MIME は `zts_web` のロジックを再利用）
  - [ ] Zig ソース変更の監視 → `zig build` → 再起動
  - [ ] `--browser`（Arena の Live Preview 用に URL を 1 行出す）
- [ ] `zts build`
  - [ ] フロントエンドのバンドル（`M5-01` エンベッダ）→ `zig build -Doptimize=… [-Dtarget=…]`
  - [ ] 単一実行ファイルの出力先を表示
- [ ] `./zigw quick-test` / `build test -Dgtk=true|false` / `fmt --check` / `check-docs`
- [ ] CI: 3 OS で `zts` のスモーク（`zts init demo && zts build`）を回す

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `src/cli/args.zig` — `parse(argv[1..]) → Command`、`usage()`。**13 テスト**
    （help/version の別扱い、`init` の位置引数と `--dir`、`dev` の port/host/browser、
    `build` の `--debug`/`--target`、未知コマンド・未知フラグ・値欠落・範囲外ポート、
    ヘルプに載っている全フラグがパーサで往復することの検証）
  - `src/cli/template.zig` — `validateName` / `defaultName` / `normalizeName` /
    `scaffold` / `render` / `fingerprintSuggestion` / `patchFingerprint`。**9 テスト**
    （決定論・プレースホルダ残留なし・fingerprint の抽出と patch・未知トークンの温存）
  - `src/cli/mod.zig` — テスト集約（`quick-test` に `-Mroot=src/cli/mod.zig` を追加済み）
  - `build.zig` — `cli_tests` を `test` ステップに追加
- **作業中・直前の状態**: 純粋ロジックのみ実装済み。実行ファイル `zts` はまだ無い。
- **再開するとき**: `./zigw test src/cli/mod.zig`（23 本）が通ることを確認し、
  `src/cli/main.zig` を書くところから。

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
