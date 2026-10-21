# AGENTS.md — Z-Ts（Tauri in Zig）開発憲法・エージェント運用ハブ

> **このファイルは、すべての AI エージェント（新規チャット開始時・コンテキスト圧縮による記憶リセット直後・並列稼働中）が最初に読むエントリーポイントです。**
> **注意**: 並列エージェント間のマージコンフリクトを防ぐため、**このファイルに個別タスクの進捗ログを書き込んではいけません。**

---

## 0. 最初の 30 秒ルーチン（新チャット開始時 / 記憶リセット直後）

記憶がない状態・新しいチャット環境に入ったら、**推測で動く前に必ず以下の順で現状を復元すること**：

```bash
# Step 1: 現在ブランチ・自分が触っていたタスク・他の並列エージェントの稼働状況を一括把握（0.3秒）
bash scripts/status.sh

# Step 2: ゼロ設定ラッパーで全単体テストを高速実行（キャッシュ0バイトの新チャット初回でも約5秒、2回目以降 0.02秒！）
./zigw quick-test

# Step 3: コミット・Push 前の必須チェック（ドキュメント構造検査 + Zig フォーマット検査）
python3 scripts/check-docs.py && ./zigw fmt --check src/ build.zig build.zig.zon
```

---

## 1. 記憶喪失対策 ＆ 並列マルチエージェント協調プロトコル（最重要）

このプロジェクトでは **① 1 エージェント内でも一定間隔でコンテキスト（記憶）が飛ぶ** こと、かつ **② 複数のエージェントが別ブランチで同時に並列稼働する** ことを前提にリポジトリ構造を設計しています。

### 1.1 絶対禁止事項（マージコンフリクト防止）

- ❌ **ルート直下に単一の `memory.md` / `PROGRESS.md` / `TODO.md` を作らない・追記しない**（`scripts/check-docs.py` と CI で機械的にブロックされます）。
- ❌ **`AGENTS.md` や `docs/roadmap/milestones.md` のチェックボックスをタスク完了のたびに書き換えない**（全並列ブランチが同じ行を編集して PR マージ時に衝突するため）。

### 1.2 分割ファイル（Sharded Files）による状態・記憶管理ルール

すべての作業状態・引き継ぎメモ・設計書は **「1 タスク / 1 モジュール / 1 意思決定 ＝ 1 独立ファイル」** として分割配置します：

| 種類 | 配置パス | 更新ルール（コンフリクト回避） |
|---|---|---|
| **タスク進捗 & 作業記憶（チェックポイント帳）** | [`docs/tasks/TEMPLATE.md`](docs/tasks/TEMPLATE.md) をコピーして<br>`docs/tasks/<ID>-<slug>.md` を作成 | **自分の担当タスクファイル 1 つだけ**を作成・更新する。他人のタスクファイルは触らない。 |
| **サブシステム設計書** | `docs/architecture/<module>.md`<br>（全体図は [`docs/architecture/00-overview.md`](docs/architecture/00-overview.md)） | 担当サブシステム専用ファイルを新規作成・編集する。 |
| **技術的判断・知見（ADR）** | `docs/decisions/<NNNN>-<slug>.md`<br>（例: [`0001`](docs/decisions/0001-zig-017-and-sharded-agent-workflow.md)） | **追記専用（Add-only）** で新しい番号のファイルを追加する。 |
| **環境・CI ナレッジ** | [`docs/environment/arena-and-caching.md`](docs/environment/arena-and-caching.md)<br>[`docs/environment/github-actions.md`](docs/environment/github-actions.md) | ツールチェーン・CI 構成変更時のみ更新する。 |

### 1.3 並列エージェントのタスク着手（分散ロック）フロー

1. **`bash scripts/status.sh` を実行**し、`[4] Parallel Agents Radar` に表示される **リモート `arena/*` ブランチ** と **Open PR** を確認する。他エージェントが既に触っている `docs/tasks/<ID>-*.md` や `src/<module>/` には手を出さない。
2. 自分が担当するタスクの `docs/tasks/<ID>-<slug>.md` を作成し、ヘッダを `- **Status**: in_progress` / `- **Branch**: <自分のブランチ名>` にして **最初に 1 コミット `git push` する**（これにより他エージェントの `status.sh` 上で即座にロックが可視化される）。
3. **記憶飛び（コンテキストリセット）に備えるチェックポイント習慣**:
   - 調査完了時・設計確定時・サブテスト通過時・ハマり原因特定時の区切りごとに、担当 `docs/tasks/<ID>-<slug>.md` の **`Current State` / `Decisions & Notes` / `Next Step` を具体的に更新してこまめにコミット**する。
   - これにより、いつ記憶が飛んでも次のターンで `bash scripts/status.sh` を 1 回叩くだけで直前の思考と次の 1 手が 100% 復元される。
4. **コード側の衝突最小化ルール**:
   - 各モジュールは `src/<module>/mod.zig` 以下に自己完結させ、単体テストもモジュール内から走らせるように書く。
   - 共有ファイル（`build.zig` / `src/root.zig`）への変更は最小限の 1 エントリ追加に留め、アルファベット順を維持する。

---

## 2. 毎チャット環境リセット（キャッシュ揮発）への最適運用

Arena サンドボックスでは **新しいチャット（ブランチ）ごとにコンテナが新規作成され、`/usr/local`・`~/.local`・`~/.cache/zig`・`.zig-cache`・`target` が毎回リセットされます**。無駄な待ち時間を出さないため、以下の仕組みを徹底してください（詳細計測データは [`docs/environment/arena-and-caching.md`](docs/environment/arena-and-caching.md) 参照）。

### 2.1 LLVM / コンパイラ仕様の事実確認（検証済み）

- **PyPI 版 `ziglang==0.17.0` には `LLVM 22.1.8` / `Clang 22.1.8` / `LLD` / `llvm-ar` が完全同梱（静的リンク）されています。**
  - `-O ReleaseFast` / `-O ReleaseSmall` / `-fllvm`、C/C++ コンパイル（`./zigw cc` / `./zigw c++`）、クロスコンパイル（`x86_64-windows-gnu`, `aarch64-macos`, `wasm32`）すべて単体で動作します。

### 2.2 必要なプロファイルだけをオンデマンド導入する（毎回フル導入しない！）

| 作業内容 | 実行コマンド | 実測所要時間（コールド時） | 導入・実行されるもの |
|---|---|---|---|
| **通常の Zig 実装・全単体テスト（全体の 8 割）** | `./zigw quick-test` | **初回 約 8.5 秒**（Zig 導入 3.5s + テスト 5.0s）<br>**2回目以降 `0.02 秒`（19ms）** | Zig `0.17.0` 自動導入 + `src/root.zig` テストスイート直接実行（94秒かかる `std.Build` ランナーのビルドをバイパス！） |
| **上流 `vendor/` コード参照** | `bash scripts/setup-toolchains.sh --submodules` | 約 3 秒（未展開時のみ） | `vendor/{tauri,wry,tao}` 浅い展開 |
| **Linux GTK3 / WebKit2GTK ネイティブリンク** | `bash scripts/setup-toolchains.sh --sysroot` | 約 8 秒（ビルド実行は **+4.8 秒**） | Debian 12 `gtk+-3.0` (`3.24`), `webkit2gtk-4.1` (`2.50`), `pkg-config` |
| **Rust リファレンスビルド / FFI 差分テスト** | `bash scripts/setup-toolchains.sh --rust` | 約 8 秒 | Rust `1.99.0` (`rustc`, `cargo`, `rustfmt`, `clippy`, `wasm32` std) |
| **全環境フル検証** | `bash scripts/setup-toolchains.sh --verify` | 初回 約 20 秒 | 上記すべて + GTK3/WebKit2GTK/Rust FFI 実リンク実行検証 |

### 2.3 高速ビルドを維持する Zig 0.17 必須コーディング規約

1. **ローカルチャットでは `./zigw quick-test` / `./zigw build-exe` を主軸にし、`zig build test` は `build.zig` 変更時または GitHub Actions で検証する**
   - 空キャッシュから `zig build` を叩くと、本体のコンパイル前に巨大な `std.Build` ランナー自身のビルドだけで **約 94 秒** かかります。
   - 一方、`./zigw quick-test`（`zig test src/root.zig`）や `./zigw build-exe` はキャッシュ完全ゼロの状態からでも **4.8〜5.0 秒、2回目以降は 0.02 秒** で完了します（`src/root.zig` から全サブモジュールのテストが辿れるよう `test { _ = @import("..."); }` を維持すること）。
   - `build.zig` 自体のビルド検証は、永続 `actions/cache@v4` が効く GitHub Actions（macOS 19秒〜）が Push ごとに自動検証します。
2. **`@cImport` は廃止済み & 巨大ヘッダの `addTranslateC` も原則禁止**
   - Zig `0.17.0` では `@cImport` は文法廃止済みです。
   - さらに `gtk/gtk.h` や `webkit2/webkit2.h` を `b.addTranslateC` で毎回パースさせると、キャッシュ揮発環境では **毎回 +50 秒** のペナルティが発生します。
   - **鉄則**: コア層は **`link_libc = false`（Pure Zig）** を厳守し、OS ネイティブ C ライブラリ（GTK3 / WebKit2GTK 等）の境界は **必要な C 関数・構造体のみを `extern fn ... callconv(.c)` で明示した Pure Zig バインディングファイル** として `src/` にコミットすること（コールドリンクが **2 秒** で完了します）。
3. **明示的 `Allocator` ＆ メモリリークゼロ**
   - すべてのテストで `std.testing.allocator` を使用し、1 バイトのリークも残さない。
4. **Rust `staticlib` リンク時は `mod.linkSystemLibrary("gcc_s", .{})` を付与する**。

---

## 3. GitHub Actions の積極活用ルール

ローカル Arena 環境の制約（キャッシュ揮発・Linux ヘッドレスのみ・`crates.io` 非接続）は、**GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml))** で補完します（詳細は [`docs/environment/github-actions.md`](docs/environment/github-actions.md) 参照）：

1. **永続キャッシュ付き `zig build test` & 3大 OS マトリクス検証 (`ci-linux` / `ci-macos` / `ci-windows`)**:
   - `actions/cache@v4` により `~/.cache/zig` と `.zig-cache` を永続保持するため、ローカルでは 94 秒かかる `zig build test` も CI 上では高速（macOS 実測 **19 秒**）に完了します。
   - **Linux**: `xvfb-run` 下での実 GTK3 ウィンドウ生成・WebKit2GTK レンダリング検証
   - **macOS (`arm64`)**: Cocoa / `WKWebView` ネイティブコードのビルド・実行検証
   - **Windows (`x86_64`)**: Win32 / `WebView2` ネイティブコードのビルド・実行検証
3. **本家 Rust 版 Tauri との Differential Test & ベンチマーク実行**:
   - CI 上では `crates.io` と永続キャッシュがフル稼働し、CPU ノイズも安定しているため、上流 Rust 実装との入出力比較ベクタ生成やパフォーマンス計測は GitHub Actions ジョブで実行し、以下のコマンドで結果を確認すること：
   ```bash
   git push origin <現在のブランチ名>
   gh run list --branch <現在のブランチ名> --limit 5
   gh run watch <run_id> --exit-status

   # 全ジョブの Step Summary 出力・コンパイルエラー・ベンチマーク結果を api.github.com 経由で取得
   # （※ gh run view --log は外部ログホストへのリダイレクトでブロックされるため必ずこちらを使う）
   bash scripts/ci-logs.sh <run_id>
   ```

---

## 4. アーキテクチャ・開発手法・ドキュメント索引

### 4.1 必読ドキュメントリンク

- 📚 **ドキュメント全体索引**: [`docs/INDEX.md`](docs/INDEX.md)
- 📖 **Tauri v2 使い方リファレンス**: [`docs/reference/tauri-usage.md`](docs/reference/tauri-usage.md)
- 🔬 **Tauri v2 内部実装完全解剖**: [`docs/reference/tauri-internals.md`](docs/reference/tauri-internals.md)
- 🏗️ **全体アーキテクチャ & 上流 `vendor/` 対応表**: [`docs/architecture/00-overview.md`](docs/architecture/00-overview.md)
- 🗺️ **マイルストーン定義**: [`docs/roadmap/milestones.md`](docs/roadmap/milestones.md)
- 📝 **タスク・記憶チェックポイント雛形**: [`docs/tasks/TEMPLATE.md`](docs/tasks/TEMPLATE.md)
- ⚡ **Arena 実行環境・キャッシュ最適化詳細**: [`docs/environment/arena-and-caching.md`](docs/environment/arena-and-caching.md)
- 🔄 **GitHub Actions 運用・オフロード詳細**: [`docs/environment/github-actions.md`](docs/environment/github-actions.md)

### 4.2 品質基準と開発姿勢

1. **上流コード精読ファースト**: 推測で仕様を作らず、必ず `vendor/tauri`・`vendor/wry`・`vendor/tao` の該当実装を読んでから設計・実装する。
2. **TDD / 差分テスト / ベンチマーク駆動**:
   - ロジック実装は **TDD（🔴 RED → 🟢 GREEN → 🔵 REFACTOR → 📝 COMMIT）** で進め、公開関数あたり **最低 5〜10 ケース以上**（正常系・異常系・境界値・セキュリティ境界・アロケーション失敗）のテストを書く。
3. **「言わなきゃいけないことを言う」**:
   - 設計上の矛盾、上流仕様の落とし穴、テスト不足、パフォーマンス悪化を見つけた場合は曖昧にせず明確に指摘・提案する。
4. **コミット規約**:
   - 1 コミット = 1 つの明確でテスト通過済みの変更とし、Conventional Commits（`feat`, `fix`, `docs`, `test`, `perf`, `refactor`, `chore`, `ci`）に従う。
   - **セッションの現在ブランチ（`arena/...`）以外に checkout / push しないこと。**
