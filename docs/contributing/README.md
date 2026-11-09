# Z-Ts 自体を開発する（コントリビュータ向け）

> **アプリを作りたい人はこのページを読む必要はありません。**
> [`../learn/ja/tutorials/counter.md`](../learn/ja/tutorials/counter.md) が「`zts` CLI で自分のアプリを作る」
> 手順です。ここは **Z-Ts のリポジトリそのものをビルド・テスト・公開する**ためのコマンドと作法を
> まとめたページです（コントリビュータ・エージェント・将来の自分向け）。

このリポジトリには**2 種類のコマンド**があり、混ぜると危険です。

| 系統 | 例 | 誰のため | 説明 |
|---|---|---|---|
| **`zts`**（アプリ作者向け） | `zts init` / `zts dev` / `zts build` | ライブラリを使う人 | 自分のプロジェクトを操作する。→ [`../reference/cli.md`](../reference/cli.md) |
| **`./zigw` と `zig build`**（このリポジトリ専用） | `./zigw quick-test` / `./zigw build test` | Z-Ts を直す人 | ライブラリ本体・サンプル・ドキュメントサイトを作る。**このページ** |

`zts` は「アプリ作者が叩くもの」、`./zigw` は「Z-Ts のビルド環境を整えて Zig を叩くもの」です。
アプリ作者の手順に `./zigw` が出てきたら、それは書き間違いです。

---

## 1. ツールチェーン

| 必要なもの | 用途 | 無い場合 |
|---|---|---|
| Zig 0.17.0 | すべてのビルドとテスト。`PATH` に 0.17 があれば `./zigw` はそれをそのまま使う | `./zigw` が PyPI の wheel から `/tmp/zts-toolchains/` に導入する（そのときだけ Python 3.8+ が要る） |
| Python 3.8+ | Zig が無いときの導入と、`scripts/*.py` のドキュメント検査 | Zig を自前で入れる。`check-docs.py` / `doc-tests.py` は必須 |
| Node.js 22 | E2E（`node tests/…`）とフレームワークデモの再生成 | 該当ステップだけスキップされる |
| GTK3 + WebKit2GTK 4.1 | Linux のネイティブ WebView | `bash scripts/setup-toolchains.sh --sysroot` |

### 1.1 `./zigw` は何をするラッパーか

`zigw` は「このリポジトリ専用の環境整え役」で、**配布物ではありません**（[`§6`](#6-ci-と配布)）。
やることは 2 つだけです。

1. **Zig を見つける**（`PATH` の `zig` が 0.17.0 なら採用 → `/tmp/zts-toolchains/…` →
   PyPI wheel を展開）。sudo が使える環境では `/usr/local/bin/zig` にもリンクします。
2. **下の 5 つのサブコマンドだけ横取りし、それ以外は `zig` にそのまま渡す。**

| `./zigw <verb>` | 実体 | 何のため |
|---|---|---|
| `quick-test` | `zig test` をモジュールごとに直接実行 | `std.Build` ランナーのビルド（約 90 秒）を飛ばして TDD を回す |
| `full-test` | `zig build test --summary all` | E2E・C ABI・バインディング鮮度まで含む全ステップ |
| `docs-check` | docsite のテスト → `check-docs.py` → `doc-tests.py` → `zig build docs` | ドキュメントの全ゲート |
| `doctest` | `scripts/doc-tests.py` だけ | CI など、他のゲートを省きたいとき |
| `zig-path` | Zig のパスを 1 行 | `ZTS_ZIG` に渡す（`zts doctor` の `zig MISSING` 対策） |

**それ以外は `zig` に丸投げ**です。`./zigw build docs` は `zig build docs`、`./zigw fmt --check src/`
は `zig fmt --check src/`、`./zigw version` は `zig version`（`0.17.0`）。`zigw` 自身のバージョンを
問い合わせるコマンドはありません。この対応は `scripts/check-docs.py` の 9 番目の規則が
**ドキュメントの記述と `zigw` 本体を突き合わせて**検証します（存在しないサブコマンドを書くと
`docs-check` が落ちます）。

Zig が `PATH` に無い場合、初回は約 4 秒かけて `/tmp/zts-toolchains/` へ展開します。`/tmp` は
コンテナごとに消えるので、**チャットをまたぐたびに再導入が走るのは仕様**です
（詳細は [`../environment/arena-and-caching.md`](../environment/arena-and-caching.md)）。

## 2. 30 秒で現状を復元する

記憶が飛んだ直後・新しいチャットの最初に、この 3 つだけ流せば現状に戻れます。

```bash
bash scripts/status.sh          # ブランチ・未コミット・並列エージェント・直近 CI
./zigw quick-test               # 全単体テスト（キャッシュ無し 12 秒 / 温まれば 0.2 秒）
./zigw docs-check               # ドキュメントの 4 段ゲート（温まって 14 秒）
```

3 つとも通れば「壊れているのは自分の変更」です。

## 3. コマンド一覧

### 3.1 テスト

| コマンド | 内容 | 目安 |
|---|---|---|
| `./zigw quick-test` | `std.Build` を介さず全モジュールの単体テスト | キャッシュ無し 12 秒 / 温まれば 0.2 秒 |
| `./zigw full-test` | `zig build test` と同じ（E2E・C ABI・バインディング鮮度を含む） | コールド 90 秒以上 |
| `./zigw build test -Dgtk=false` | GTK を切って `test` ステップを実行（CI と同じ形） | キャッシュ次第 |
| `./zigw docs-check` | ドキュメントの**全ゲート**（下記 4 段）。PR 前に必ずこれ | 約 14 秒（温） |
| `./zigw build docs` | ドキュメントサイトを `zig-out/docs/` に生成（リンク・アンカー検査つき） | 約 8 秒 |
| `python3 scripts/check-docs.py` | 構造・相対リンク・層違反・CLI 乖離・パッケージ名・用語集・ページ骨格・`./zigw` の記述 | 0.1 秒 |
| `./zigw doctest` | `zig check` フェンスを実際にコンパイル（doctest-lite） | 2 ブロックで 1〜5 秒 |
| `./zigw zig-path` | このチェックアウトが使う Zig のパスを 1 行で出力（`ZTS_ZIG` に渡す用） | 即時 |

個別モジュールだけ回すときは `./zigw test src/docsite/mod.zig` のように書きます
（`src/cli/mod.zig` だけは `main.zig` を含まないので、CLI 本体は `./zigw build` が型検査します）。

### 3.2 ビルド

| コマンド | 出力 |
|---|---|
| `./zigw build` | デスクトップ本体・Live Preview・wasm・`dist/`・**`zig-out/bin/zts`** |
| `./zigw build -Doptimize=ReleaseSmall` | サイズ優先のビルド |
| `./zigw build -Dtarget=x86_64-windows-gnu` | Linux から Windows 版（単一 PE） |
| `./zigw build docs` | 公開サイト（`zig-out/docs/`） |

`zig build` のオプション:

| オプション | 既定 | 内容 |
|---|---|---|
| `-Dgtk=<bool>` | Linux では `pkg-config` で自動判定 | GTK3 + WebKit2GTK 4.1 バックエンド |
| `-Dmacos=<bool>` | macOS ターゲットで自動有効 | Cocoa + `WKWebView` |
| `-Dwindows=<bool>` | Windows ターゲットで自動有効 | Win32 + WebView2 |
| `-Dwasm-optimize=<mode>` | `small` | wasm デモの最適化 |
| `-Dtarget=<triple>` / `-Doptimize=<mode>` | ホスト / `Debug` | 標準の Zig オプション |

### 3.3 サンプル

`examples/*` はそれぞれ独立した `build.zig` を持ち、ルートを path 依存で参照します。

```bash
cd examples/counter
../../zigw build desktop    # 単一バイナリ
../../zigw build preview    # 0.0.0.0:8788 で Live Preview
../../zigw build dist       # サーバ不要の静的サイト
../../zigw build test       # 単体 + 実 TCP + 実 WebAssembly E2E
```

### 3.4 スクリプト

| スクリプト | 内容 |
|---|---|
| `bash scripts/status.sh` | ブランチ・未コミット・並列エージェント・直近 CI を 1 画面に |
| `bash scripts/setup-toolchains.sh --sysroot` | GTK3 / WebKit2GTK の sysroot を導入 |
| `bash scripts/setup-toolchains.sh --rust` | リファレンス実装（Rust）のビルド環境 |
| `bash scripts/setup-toolchains.sh --submodules` | `vendor/{tauri,wry,tao}` を浅く展開 |
| `bash scripts/ci-logs.sh <run_id>` | Check Run API 経由で CI の要約を取得 |
| `node scripts/verify-screenshots.mjs <dir>` | PNG の画素比較（3 OS パリティ） |
| `node scripts/gen-framework-demos.mjs [name]` | 9 フレームワークのデモを再生成 |
| `node scripts/check-font-coverage.mjs` | 同梱フォントが全使用文字を網羅しているか |

## 4. リポジトリの地図

| パス | 中身 |
|---|---|
| `src/core/` | `zts_foundation` / `zts_web` / `zts_core`（OS 非依存の土台） |
| `src/rpc/` | `zts_rpc`（スキーマ・codec・TypeScript 生成） |
| `src/bridge/` | `zts_bridge`（HTTP + SSE の Live Preview） |
| `src/webview/` | `zts_webview`（GTK / Cocoa / Win32 / HeadlessMock / C ABI） |
| `src/tauri/` | `zts_tauri`（Tauri v2 プロトコルと標準プラグイン） |
| `src/wasm/` `src/ssg/` | `zts_wasm` / `zts_ssg`（ブラウザと静的サイト） |
| `src/build_tools/` | `build.zig` から呼ぶエンベッダと `tsgen`（`M5-01`） |
| `src/cli/` | **`zts` CLI 本体**（アプリ作者向けのコマンド） |
| `src/docsite/` | このドキュメントサイトの生成器（Markdown 描画・API リファレンス） |
| `examples/` | サンプル（counter / gallery / frameworks / c_embed） |
| `docs/` | ドキュメント（4 層構造は [`../learn/ja/guides/index.md`](../learn/ja/guides/index.md)） |
| `scripts/` | CI・スクリーンショット・ツールチェーンのスクリプト |
| `tests/` | パッケージをまたぐ E2E |

パッケージ境界の約束（依存 DAG・`link_libc = false`・OS 境界は `extern fn … callconv(.c)` のみ）は
[`../architecture/00-overview.md`](../architecture/00-overview.md) にあります。

## 5. 変更の作法

1. **着手前**: `bash scripts/status.sh` で並列エージェントを確認し、
   [`../tasks/TEMPLATE.md`](../tasks/TEMPLATE.md) から `docs/tasks/<ID>-<slug>.md` を作って
   `Status: in_progress` / `Branch: <自分のブランチ>` で**最初に push** する（分散ロック）。
2. **TDD**: 🔴 RED → 🟢 GREEN → 🔵 REFACTOR → 📝 COMMIT。公開関数ごとに正常系・異常系・
   境界値・セキュリティ境界を最低 5〜10 ケース。
3. **コアは Pure Zig**: `zts_foundation` / `zts_web` / `zts_rpc` / `zts_webview` は
   `link_libc = false` を維持し、OS の C ライブラリは `extern fn … callconv(.c)` の
   手書きバインディングに閉じ込める。
4. **`build.zig` の変更は最小限**。共通ロジックは `src/build_tools/` と `src/docsite/` へ。
5. **公開宣言には必ず `///` を書く**。`zig build docs` のログに `api_undoc=N` が出て、
   **CI は 0 以外を失敗扱い**にします（[`../api/index.html`](../api/index.html)）。
6. **コミット前に**: `./zigw fmt --check src/ tests/ examples/ build.zig` と
   `python3 scripts/check-docs.py`。
7. **ドキュメントをどこに書くか**: アプリ作者向け（手順）は `docs/guides/`、振る舞いの約束は
   `docs/reference/`、**このリポジトリの操作**は `docs/contributing/`、実装の意図は
   `docs/architecture/` `docs/decisions/` `docs/tasks/`。迷ったら
   [`../learn/ja/guides/index.md`](../learn/ja/guides/index.md) §2 の表に従ってください。

## 6. CI と配布

`.github/workflows/ci.yml` は **Linux / macOS / Windows の 3 ジョブ + 3 OS の画素比較ジョブ +
`ci-cli`（`zts` のスモーク）**を回します。`ci-cli` はチェックアウトの**外**にプロジェクトを
作り、`zts init` → `doctor` → `build` → 実行 → `zts package --format tar.gz` まで通すので、
「利用者がリポジトリを知らなくても使える」ことが常時検証されます（[`../tasks/M5-08-docs-audience-split.md`](../tasks/M5-08-docs-audience-split.md)）。
Linux では加えて、**公開アーカイブを焼き込んだ release ビルド**が `.url` 依存のプロジェクトを
生成し、空の Zig キャッシュから取得してビルドできることまで確認します。

`pages.yml` は `main` への push でドキュメントサイトを GitHub Pages に公開します。

### 6.1 何を配るか

| 配るもの | 何か | 誰が使うか |
|---|---|---|
| `zts-<version>-<os>-<arch>[.exe]` | **`zts` の単体バイナリ**（約 300 KB、`link_libc = false`） | アプリを作る人 |
| `z_ts-<version>.tar.gz` | Z-Ts のソースアーカイブ（`git archive`） | 生成したプロジェクトの `build.zig.zon` が `.url` で参照する |
| `SHA256SUMS` | 上記のチェックサム | 検証したい人 |

`./zigw` は**配りません**。Zig を `/tmp` に導入して `zig build` を呼ぶだけのリポジトリ専用
ラッパーで、`zts` を入れる人には不要です（`zts` は `PATH` の `zig` を使う）。

### 6.2 release ビルドの作り方

`zts` は既定で「自分をビルドしたチェックアウト」を生成プロジェクトに書き込みます。配布用には、
公開アーカイブの URL と `zig fetch` の hash を**焼き込んで**ビルドします。

```bash
./zigw build -Doptimize=ReleaseSmall \
  -Dzts-pkg-url="https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/z_ts-0.1.0.tar.gz" \
  -Dzts-pkg-hash="z_ts-0.1.0-…"      # zig fetch <そのアーカイブ> が返す値
```

こうしてできた `zts` は `.url` + `.hash` を書くので、利用者は clone を持たずに `zig build` できます。
片方だけ指定すると `build.zig` が `panic` します（Zig が読めない `build.zig.zon` を作らないため）。
`v*` タグを push すると `.github/workflows/release.yml` がこの手順を 3 OS で回し、
アーカイブ・バイナリ・`SHA256SUMS` を GitHub Releases に公開します。

## 7. うまくいかないとき

リポジトリ側の既知の失敗（ツールチェーン・コールドビルド・GTK ヘッダ・ドキュメントサイトの
リンク検査・Pages の有効化・画素比較）は [`troubleshooting.md`](troubleshooting.md) に
まとめてあります。アプリ側のエラーは [`../learn/ja/guides/troubleshooting.md`](../learn/ja/guides/troubleshooting.md) へ。

---

## 次に読むもの

| 知りたいこと | 行き先 |
|---|---|
| アプリを作る（利用者向け） | [`../learn/ja/tutorials/counter.md`](../learn/ja/tutorials/counter.md) |
| `zts` CLI の仕様 | [`../reference/cli.md`](../reference/cli.md) |
| 全体アーキテクチャ | [`../architecture/00-overview.md`](../architecture/00-overview.md) |
| 設計判断の記録 | [`../decisions/`](../decisions/) |
| エージェント運用ルール | [`../../AGENTS.md`](../../AGENTS.md) |
