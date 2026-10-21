# ADR 0001: Zig 0.17 ツールチェーン・コールドキャッシュ戦略・並列エージェント向け分割ドキュメント設計

- **Date**: 2026-10-21
- **Status**: Accepted

---

## Context

1. Arena サンドボックスは新規チャット・新規並列ブランチごとにコンテナが初期化され、`/usr/local` や `~/.cache/zig` が毎回消去される。
2. 実機計測の結果、空キャッシュ状態から `zig build test` を走らせると `std.Build` ビルドランナーと `compiler_rt` の再ビルドに **94.05 秒**、さらに `gtk/gtk.h` 等に `addTranslateC` を使うと **+約 50 秒** を要する。また、GitHub Actions ランナーで生成した `~/.cache/zig` を Arena へ転送する手法は、ホスト CPU feature ビット列（AMD EPYC vs Intel Xeon Ice Lake）と glibc バージョンの相違により `native` キャッシュキーが一致しないことも実機検証で判明した。
3. 一方、`build.zig` ランナーを介さないダイレクト実行（`zig test src/root.zig` および `extern fn` 直宣言を用いた `zig build-exe`）は、**キャッシュ 0 バイトの完全コールド状態でも 4.8〜5.0 秒、同一チャット 2 回目以降は 0.019 秒（19ms）** で完了する。
4. エージェントは一定トークンごとにコンテキスト圧縮（記憶飛び）が発生するほか、複数ブランチで同時に並列稼働するため、単一の `memory.md` や `ROADMAP.md` を全員が編集すると確実に Git マージコンフリクトが発生する。

---

## Decision

1. **ツールチェーン & C バインディング**:
   - LLVM `22.1.8` / Clang `22.1.8` 同梱の公式 `ziglang==0.17.0` ホイールを採用する。
   - コア層は `link_libc = false`（Pure Zig）を徹底し、OS ネイティブ C API（GTK3 / WebKit2GTK 等）は `addTranslateC` を使わず `extern fn ... callconv(.c)` 直宣言モジュールとして `src/` に保持する。
   - 追加ツールチェーン（`--sysroot`, `--rust`, `--submodules`）は必要なチャットでのみオンデマンド導入する。
2. **ローカル爆速 `./zigw quick-test` × GitHub Actions 永続キャッシュ CI の二段構え**:
   - ローカル Arena の日常 TDD ループは `./zigw quick-test`（コールド 5.0s / ウォーム 0.02s）を標準とする。
   - `build.zig` を含むフルビルド（`zig build test`）および 3 大 OS 実機検証（Linux `xvfb-run` + WebKit2GTK / macOS `WKWebView` / Windows `WebView2`）は、`actions/cache@v4` 永続キャッシュが効く GitHub Actions で自動検証する。
   - Arena から `results-receiver.actions.githubusercontent.com` がブロックされる問題に対し、全 CI 出力を `$GITHUB_STEP_SUMMARY` にミラーリングし `scripts/ci-logs.sh`（`api.github.com` 経由）で全ログを取得可能にする。
3. **Sharded Markdown & 分散タスクロック**:
   - ルート単一 `memory.md` を禁止し（`scripts/check-docs.py` で強制）、タスク単位の `docs/tasks/<ID>-<slug>.md`・モジュール単位の `docs/architecture/<mod>.md`・追記専用の `docs/decisions/<NNNN>-*.md` に分割する。
   - `scripts/status.sh` により、現在ブランチの作業記憶と他エージェントのリモートブランチ・Open PR を 1 コマンドで可視化する。
