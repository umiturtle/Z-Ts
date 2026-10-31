# Task M5-03: 3-OS パッケージャ & 対 Rust Tauri ベンチマーク

- **Status**: `in_progress`
- **Branch**: `arena/235a0653-z-ts`
- **Scope**: `src/bundler/`（新規）, `src/cli/`（`package` サブコマンド）, `bench/`（新規）,
  `build.zig`, `zigw`, `.github/workflows/ci.yml`, `docs/reference/cli.md`,
  `docs/guides/packaging.md`, `docs/architecture/packaging-and-bench.md`, 本ファイル
- **Upstream Reference**: `vendor/tauri/crates/tauri-bundler/src/bundle/{deb,macos,settings,common}.rs`
  （`.deb` の control/data 構成、`.app` の `Info.plist`、Windows の `.exe` リソース）
- **Next Step**: スライス C（`bench/run.mjs` + CI の Check Summary）。A/B は実装・テスト・
  `zts package` への配線・ドキュメントまで完了。

---

## 1. 目的と完了条件（Definition of Done）

配布物を作る工程を**ライブラリ（`src/bundler/`）としてテスト可能**にし、`zts` から呼べるようにする。
ベンチは「同一機能のアプリを Z-Ts と本家 Rust Tauri で測る」ためのハーネスを `bench/` に置く。

### スライス A — Linux / macOS の配布物（完了）

- [x] `app.zig`: 名前・バージョン・識別子・メンテナ・説明の検証と派生文字列
      （`.desktop` / `control` / `Info.plist` / `AppRun` / パッケージ名）
- [x] `plan.zig`: 仮想パッケージ（`Entry = path + mode + bytes`）を作る純粋関数
      （AppDir / `.app` / `.deb` の中身）
- [x] `deb.zig`: `ar` アーカイブ + `control.tar.gz` + `data.tar.gz` を**決定的**に生成
- [x] `tree.zig`: 仮想パッケージを実ディレクトリへ書き出す（パーミッション含む）
- [x] `zts package`（`--format deb|appdir|app|dmg|exe|tar.gz`）と `zts init` からの導線
- [x] 単体テストで `dpkg-deb --info` / `--contents` 相当の検証（実 `dpkg-deb` でも確認済み）

### スライス B — Windows（完了）

- [x] `.ico` を読み、`RT_ICON` / `RT_GROUP_ICON` / `RT_MANIFEST` からなる `.rsrc` を生成
- [x] 既存 PE にセクションを 1 本追加してリソースを埋め込む（純 Zig・クロスプラットフォーム）
- [x] `zts package --format exe`（`zig-out/package/<name>.exe`）

### スライス C — ベンチマーク

- [ ] `bench/`: 被測定アプリを「ビルドコマンド / 実行ファイル / 起動判定 / 停止」で記述する
      依存ゼロのランナー（`bench/run.mjs`）と Z-Ts 側の定義
- [ ] 6 指標（コールドビルド・インクリメンタル・サイズ・起動・RSS・IPC）を JSON + Markdown で出力
- [ ] CI: Linux で Z-Ts 側を実測し Check Run Summary に出す（Rust 側はツールチェーンが
      無いとき `skipped` と明示）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

<!-- サブタスク完了・設計決定・デバッグ判明のたびにここを上書き更新すること -->
- **完了したこと**: スライス A + B。`src/bundler/{app,plan,deb,tree,ico,pe,binary}.zig` の 7 本
  （テスト 35 本、`./zigw test src/bundler/mod.zig` で全通過）、`zts package`（6 形式）、`zigw
  quick-test` と `zig build test` への組み込み、`docs/{guides/packaging.md,
  architecture/packaging-and-bench.md, reference/cli.md}`、CI の `ci-cli` ジョブ（3 OS で
  `init` → `build` → `package` → `doctor`）。
- **ローカル実測**: `/tmp` の生成プロジェクトで `deb`（`dpkg-deb -I`/`-c` が受理）、
  `appdir`（`AppRun` 実行可）、`app`、`tar.gz`、`exe`（`--target x86_64-windows` + `.ico` +
  マニフェスト、`.rsrc` 1 セクション・DataDirectory[2]・チェックサム一致を Python で検証）。
- **作業中・直前の状態**: 未コミットの変更なしを目標に、ドキュメントと CI を整えた直後。
- **再開するとき**: スライス C。`bench/run.mjs`（依存ゼロ・Node 22）から。CI は
  `setup-toolchains.sh --rust` を呼ぶ **ベンチ専用ジョブ**にし、Rust が無い環境では
  `skipped` を Check Summary に明記する。

---

## 3. 設計判断・技術メモ・ハマりどころ

詳細は [`../architecture/packaging-and-bench.md`](../architecture/packaging-and-bench.md)。要点だけ:

- **Zig 0.17 に Win32 リソース埋め込み API は無い**（`addWin32ResourceFile` 不存在）。`.rc` →
  `zig rc` も無いため、PE の `.rsrc` を自前で追記する方式にした。歩留まりは `pe.zig` のテスト 4 本。
- **`std.tar.Writer` の `mtime` 既定は現在時刻**。再現性のため全エントリで `.{ .mtime = 0 }` を明示。
- **`std.compress.flate` の gzip** は `flate.Compress.init(&writer, &window, .gzip, level)`。
  `flate.max_window_len` のバッファが必須。
- **アーキテクチャは実行ファイルから読む**（`binary.zig`）。`--arch` は作らない。
- **`Depends:` は soname から生成**。GTK 決め打ちは headless アプリに 100 MB を足す。
- **`control` に `License:` を書かない**（Debian のバイナリフィールドではない）。
- **`zts package` は `--format` と実行ファイルの形式が食い違えば書く前に止まる**（例: PE に `deb`）。
- **`zigw quick-test` は bundler を含む 8 本**。`src/bundler/mod.zig` は依存ゼロなので
  `-Mroot` だけで走る。
- **CI の `ci-cli` は 3 OS で実際にビルドする**。Windows では `zts` が `zig` を解決できる必要が
  あり、`PATH` の `zig` をチェックアウト内の `zigw`（シェルスクリプト）より優先している。
