# Task M0-01: リポジトリ初期基盤・ツールチェーン・並列エージェント運用環境構築

- **Status**: `done`
- **Branch**: `arena/88fe1f7e-z-ts`
- **Scope**: `AGENTS.md, zigw, scripts/, docs/, .github/workflows/ci.yml, vendor/, build.zig, src/root.zig`
- **Upstream Reference**: `vendor/tauri`, `vendor/wry`, `vendor/tao`
- **Next Step**: `M1 系タスク（Config / Comptime IPC / ACL / Runtime & Linux WebKit2GTK）の方針選定および並列タスク切り出し`

---

## 1. 目的と完了条件（Definition of Done）

- [x] `AGENTS.md` および並列エージェント・記憶リセット耐性ドキュメント構造（`docs/`）の構築
- [x] 上流リポジトリ（`tauri`, `wry`, `tao`）の Git shallow submodule 導入
- [x] Zig `0.17.0`（LLVM 22.1.8 内蔵確認済み）・Rust `1.99.0`・Linux `GTK3`/`WebKit2GTK 4.1` sysroot 環境構築
- [x] 毎チャットのキャッシュ揮発に対応する `./zigw`（自動 Zig 導入 + `ci-cache-linux-x64` 自動キャッシュ復元）の実装
- [x] GitHub Actions（Linux Xvfb + macOS + Windows + `warm-zig-cache`）の構築と実機稼働確認

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - PyPI `ziglang==0.17.0` に LLVM 22.1.8 / Clang 22.1.8 / LLD が静的リンク同梱されていることを実機検証（Windows / macOS クロスコンパイル含む）。
  - コールドコンテナでの初回 `zig build test` が 94 秒かかる原因（`std.Build` ランナーと `compiler_rt` の再ビルド）を特定し、GitHub Actions から `ci-cache-linux-x64` orphan ブランチ経由で 25MB のプリウォームキャッシュを自動配信する仕組みを実装（94秒 → 約2.5秒）。
  - 単一 `memory.md` を廃止し、`docs/tasks/<ID>-<slug>.md` 分割管理 + `scripts/status.sh` による他エージェント稼働レーダー + `scripts/check-docs.py` による機械的検査を導入。

---

## 3. 設計判断・技術メモ・ハマりどころ

- `@toolchain-bin/sysroot-linux-x64` 内の `.so` に含まれる GNU ld `INPUT(...)` テキストスタブは `scripts/setup-toolchains.sh --sysroot` で自動的に POSIX シンボリックリンクへ修復済み。
- Zig `0.17.0` では `@cImport` が廃止されているうえ、`gtk/gtk.h` 等の `addTranslateC` はコールド時に +50 秒かかるため、OS 境界は `extern fn ... callconv(.c)` 直宣言で管理する方針を確立（[`0001`](../decisions/0001-zig-017-and-sharded-agent-workflow.md)）。
