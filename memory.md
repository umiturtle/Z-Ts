# memory.md — Z-Ts 開発引き継ぎ・進捗ログ

## プロジェクト概要

- **リポジトリ**: `umiturtle/Z-Ts`
- **目的**: Tauri v2 の Zig (`0.17.0`) 移植プロジェクト

---

## 現在の進捗

### 完了済み ✅

1. **`AGENTS.md` 雛形の作成**
   - 上流リファレンス対応表（L1 Windowing〜L6 Tooling）、Zig `0.17.0` 実装規約、TDD・差分テスト戦略、環境構築手順、要合意事項リストを策定。
2. **上流リファレンスリポジトリの取得（`vendor/` Git サブモジュール）**
   - `vendor/tauri` (`tauri-apps/tauri`, commit `5b50edd992420dabff167309f96b2dd20385a9d7`)
   - `vendor/wry` (`tauri-apps/wry`, commit `acafd84bc8b6425e4ac323365e7fda29b67ec24a`)
   - `vendor/tao` (`tauri-apps/tao`, commit `9977d585ba364d1812db37218c0d9e6a953a7db4`)
3. **Zig / Rust コンパイラおよび Linux GUI/WebView Sysroot 環境の整備**
   - **Zig `0.17.0`**（PyPI `ziglang` + `/usr/local/bin/zig`）
   - **Rust `1.99.0`**（`rustc`, `cargo`, `rustfmt`, `clippy`, `rustdoc`, `x86_64-unknown-linux-gnu` & `wasm32-unknown-unknown` std）
   - **Debian 12 Linux Sysroot**（`pkg-config 1.8.1`, `gtk+-3.0 3.24.38`, `webkit2gtk-4.1 2.50.6`, `javascriptcoregtk-4.1 2.50.6`, `libsoup-3.0 3.2.3`, `ayatana-appindicator3-0.1 0.5.90`, `openssl 3.0.20`）
   - 冪等セットアップ＆フルリンク検証スクリプト `scripts/setup-toolchains.sh` を作成・検証済み。
   - 最小 Zig パッケージ骨格（`build.zig`, `build.zig.zon`, `src/root.zig`）を作成し `zig build test` パス確認済み。

---

## 技術的メモ・発見事項

1. **Zig `0.17.0` における C バインディング仕様**
   - `@cImport` / `@cInclude` 組み込みは廃止されているため、`build.zig` の `b.addTranslateC(...)` でモジュール化して `@import("c")` する方式を使うこと。
2. **Sysroot 共有ライブラリの `INPUT(...)` スタブ修復**
   - `@toolchain-bin/sysroot-linux-x64` 内の `.so` ファイル群には GNU ld 用の `INPUT(libfoo.so.x.y.z)` テキストファイルが含まれており、そのままだと `ldconfig` および Zig ネイティブ ELF リンカが `UnexpectedEndOfFile` を起こす。`scripts/setup-toolchains.sh` にて 388 個のスタブを本物の POSIX シンボリックリンクへ自動変換済み。
3. **Rust `staticlib` と Zig のリンク**
   - Rust 側 `crate-type = ["staticlib"]` 成果物を Zig にリンクする際は `mod.linkSystemLibrary("gcc_s", .{})` を追加することでアンワインドシンボルが解決され、GTK3 / WebKit2GTK とも問題なく単一バイナリにリンク・実行できることを確認済み。

---

## 次のステップ候補 📋

1. **アーキテクチャ方針のすり合わせ & `docs/ARCHITECTURE.md` / `ROADMAP.md` の策定**
   - ターゲット OS の優先順位（まずは Linux `GTK3` + `WebKit2GTK 4.1` で最小ウィンドウ表示＋双方向 IPC デモを通す Vertical Slice か、コア層 `config` / `ipc` / `acl` から固めるか）
   - `@tauri-apps/api` v2 フロントエンドとの完全互換スコープの決定
2. **Milestone 0 / 1 の詳細設計と TDD 実装開始**
