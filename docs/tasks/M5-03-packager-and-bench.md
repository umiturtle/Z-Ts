# Task M5-03: 3-OS パッケージャ & 対 Rust Tauri ベンチマーク

- **Status**: `in_progress`
- **Branch**: `arena/235a0653-z-ts`
- **Scope**: `src/bundler/`（新規）, `src/cli/`（`package` サブコマンド）, `bench/`（新規）,
  `build.zig`, `zigw`, `.github/workflows/ci.yml`, `docs/reference/cli.md`,
  `docs/guides/packaging.md`, `docs/architecture/packaging-and-bench.md`, 本ファイル
- **Upstream Reference**: `vendor/tauri/crates/tauri-bundler/src/bundle/{deb,macos,settings,common}.rs`
  （`.deb` の control/data 構成、`.app` の `Info.plist`、Windows の `.exe` リソース）
- **Next Step**: `src/bundler/app.zig`（メタデータと派生文字列）→ `plan.zig`（仮想パッケージ）→
  `deb.zig`（ar + tar.gz）の順に実装し、`./zigw test src/bundler/mod.zig` を通す。

---

## 1. 目的と完了条件（Definition of Done）

配布物を作る工程を**ライブラリ（`src/bundler/`）としてテスト可能**にし、`zts` から呼べるようにする。
ベンチは「同一機能のアプリを Z-Ts と本家 Rust Tauri で測る」ためのハーネスを `bench/` に置く。

### スライス A — Linux / macOS の配布物（本次）

- [ ] `app.zig`: 名前・バージョン・識別子・メンテナ・説明の検証と派生文字列
      （`.desktop` / `control` / `Info.plist` / `AppRun` / パッケージ名）
- [ ] `plan.zig`: 仮想パッケージ（`Entry = path + mode + bytes`）を作る純粋関数
      （AppDir / `.app` / `.deb` の中身）
- [ ] `deb.zig`: `ar` アーカイブ + `control.tar.gz` + `data.tar.gz` を**決定的**に生成
- [ ] `tree.zig`: 仮想パッケージを実ディレクトリへ書き出す（パーミッション含む）
- [ ] `zts package`（`--format deb|appdir|app|dmg`）と `zts init` からの導線
- [ ] 単体テストで `dpkg-deb --info` / `--contents` 相当の検証（環境が許せば実 `dpkg-deb`）

### スライス B — Windows

- [ ] `.ico` を読み、`RT_ICON` / `RT_GROUP_ICON` / `RT_MANIFEST` からなる `.rsrc` を生成
- [ ] 既存 PE にセクションを 1 本追加してリソースを埋め込む（純 Zig・クロスプラットフォーム）
- [ ] `zts package --format exe`（`zig-out/package/<name>.exe`）

### スライス C — ベンチマーク

- [ ] `bench/`: 被測定アプリを「ビルドコマンド / 実行ファイル / 起動判定 / 停止」で記述する
      依存ゼロのランナー（`bench/run.mjs`）と Z-Ts 側の定義
- [ ] 6 指標（コールドビルド・インクリメンタル・サイズ・起動・RSS・IPC）を JSON + Markdown で出力
- [ ] CI: Linux で Z-Ts 側を実測し Check Run Summary に出す（Rust 側はツールチェーンが
      無いとき `skipped` と明示）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

<!-- サブタスク完了・設計決定・デバッグ判明のたびにここを上書き更新すること -->
- **完了したこと**: なし（着手直後）
- **作業中・直前の状態**: 仕様確認済み。`std.tar.Writer`（0.17）と
  `std.compress.flate` の gzip がそのまま使えることを確認。
- **再開するとき**: `src/bundler/app.zig` から。

---

## 3. 設計判断・技術メモ・ハマりどころ

（実装しながら追記）
