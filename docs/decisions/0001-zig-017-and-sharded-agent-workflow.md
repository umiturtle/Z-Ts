# ADR 0001: Zig 0.17 ツールチェーン・コールドキャッシュ戦略・並列エージェント向け分割ドキュメント設計

- **Date**: 2026-10-21
- **Status**: Accepted

---

## Context

1. Arena サンドボックスは新規チャット・新規並列ブランチごとにコンテナが初期化され、`/usr/local` や `~/.cache/zig` が毎回消去される。
2. 空キャッシュ状態から素朴に `zig build test` を走らせると約 94 秒、さらに `gtk/gtk.h` 等に `addTranslateC` を使うと +約 50 秒を要する。
3. エージェントは一定トークンごとにコンテキスト圧縮（記憶飛び）が発生するほか、複数ブランチで同時に並列稼働するため、単一の `memory.md` や `ROADMAP.md` を全員が編集すると確実に Git マージコンフリクトが発生する。

---

## Decision

1. **ツールチェーン & C バインディング**:
   - LLVM `22.1.8` / Clang `22.1.8` 同梱の公式 `ziglang==0.17.0` ホイールを採用する。
   - コア層は `link_libc = false`（Pure Zig）を徹底し、OS ネイティブ C API（GTK3 / WebKit2GTK 等）は `addTranslateC` を使わず `extern fn ... callconv(.c)` 直宣言モジュールとして `src/` に保持する。
   - 追加ツールチェーン（`--sysroot`, `--rust`, `--submodules`）は必要なチャットでのみオンデマンド導入する。
2. **GitHub Actions 連携によるキャッシュ事前供給**:
   - `.github/workflows/ci.yml` の `warm-zig-cache` ジョブで `~/.cache/zig` を生成し、orphan ブランチ `ci-cache-linux-x64` へ自動発行する。
   - リポジトリ直下の `./zigw` ラッパーがコールド起動時に `codeload.github.com` から自動展開し、初回ビルド時間を約 94 秒 → 約 2.5 秒に短縮する。
   - Linux GUI (`xvfb-run`), macOS (`WKWebView`), Windows (`WebView2`) の実機テストは GitHub Actions マトリクスで常時検証する。
3. **Sharded Markdown & 分散タスクロック**:
   - ルート単一 `memory.md` を禁止し（`scripts/check-docs.py` で強制）、タスク単位の `docs/tasks/<ID>-<slug>.md`・モジュール単位の `docs/architecture/<mod>.md`・追記専用の `docs/decisions/<NNNN>-*.md` に分割する。
   - `scripts/status.sh` により、現在ブランチの作業記憶と他エージェントのリモートブランチ・Open PR を 1 コマンドで可視化する。
