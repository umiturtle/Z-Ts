# Arena 実行環境・キャッシュ揮発対策・ツールチェーン詳細

このドキュメントは、Arena サンドボックス環境における実測ベンチマークデータと、**「毎チャットごとにキャッシュ・システム領域が飛ぶ」制約下で最速のイテレーションを回すための技術設計**をまとめたリファレンスです。

---

## 1. 実機検証済みの環境仕様

### 1.1 Zig `0.17.0` と LLVM 同梱有無（検証済み）

PyPI 公式バイナリホイール（`ziglang==0.17.0`）の `zig` 実行ファイル（約 185MB 静的リンクバイナリ）には、**`LLVM 22.1.8` / `Clang 22.1.8` / `LLD` / `llvm-ar` および各 OS 用 libc ヘッダ・スタートアップルーチンがすべて同梱されています。**

- `./zigw cc --version` → `clang version 22.1.8`
- `./zigw c++ --version` → `clang version 22.1.8`
- `./zigw ar --version` → `LLVM version 22.1.8`
- ネイティブ最適化ビルド（`-O ReleaseFast -fllvm` / `-O ReleaseSmall -fllvm`）→ 動作検証済み
- クロスコンパイル（`-target x86_64-windows-gnu`, `-target aarch64-macos`, `-target wasm32-freestanding`）→ 動作検証済み
- `./zigw` 初回起動時に `/usr/local/bin/clang` および `/usr/local/bin/clang++` へのラッパーシムも自動配置されるため、外部ビルドスクリプトから `clang` が呼ばれてもそのまま機能します。

### 1.2 外部ネットワーク通信ホワイトリスト

Arena コンテナから直接通信可能なホストは以下の 6 ドメインのみです：

- `github.com` / `codeload.github.com` / `api.github.com`
- `registry.npmjs.org`
- `pypi.org` / `files.pythonhosted.org`

> **非接続ドメイン**: `ziglang.org`, `static.rust-lang.org`, `crates.io`, `deb.debian.org`, `objects.githubusercontent.com`, `results-receiver.actions.githubusercontent.com`（GitHub Actions 生ログ ZIP のリダイレクト先）はブロックされます。

---

## 2. 毎チャットのコールドスタート計測値と最適アーキテクチャ

新しいチャット（または並列エージェントの新規ブランチ）を開くたび、コンテナ内の `~/.cache/zig` や `/usr/local` は初期状態に戻ります。実機検証により判明した数値と落とし穴は以下の通りです：

| シナリオ（キャッシュ完全ゼロ `0 bytes` の新チャット直後） | 実測時間 | 原因・メカニズム |
|---|---|---|
| ❌ 空キャッシュから素で `zig build test` | **94.05 秒** | 本体のビルド前に、約8万行規模の `std.Build` ビルドランナーと `compiler_rt` を毎回ゼロからコンパイルするため |
| ❌ CI ランナーで作った `~/.cache/zig` を Arena へ転送 | **短縮効果なし** | Zig の `native` ビルドキャッシュキーはホスト CPU feature ビット列（CI: AMD EPYC vs Arena: Intel Xeon Ice Lake）・カーネル・glibc バージョン（CI: 2.39 vs Arena: 2.36）を含むためハッシュ不一致となる（実機検証で確認済み） |
| ❌ `gtk/gtk.h` + `webkit2/webkit2.h` を `addTranslateC` | **+約 50 秒** | 数十万行の C ヘッダ群を Clang フロントエンドが毎回パースするため |
| 🚀 **`./zigw quick-test`（＝`zig test src/root.zig`）** | **初回 `5.00 秒`**<br>**2回目以降 `0.019 秒`（19ms）** | `std.Build` ランナーのコンパイルを完全にバイパスしてテストバイナリを直接生成するため、**キャッシュ0バイトでも 18.8 倍高速** |
| 🚀 **ダイレクト `./zigw build-exe`（GTK3 + WebKit2GTK ネイティブリンク込み）** | **初回 `4.82 秒`** | `extern fn ... callconv(.c)` 直宣言と組み合わせることで、ネイティブ GUI バイナリのリンク実行まで約 4.8 秒で完了 |

---

## 3. 実践運用ルールまとめ

1. **ローカルチャットでは `./zigw quick-test` と `./zigw build-exe` を標準にする**:
   - Zig 未導入でも `./zigw` が `pip` を介さず `zipfile` で約 3.5 秒で自動展開し、初回テスト完了までトータル約 8.5 秒、2 回目以降は **0.02 秒** で TDD ループが回ります。
   - 新しいモジュールを追加した際は、必ず `src/root.zig` の `test { _ = @import("..."); }` に登録して `./zigw quick-test` で一括実行される状態を保つこと。
   - `zig build test`（正式ビルドグラフ検証）は `build.zig` を変更した際、および **永続 `actions/cache@v4` が効く GitHub Actions（19秒〜）** で常時検証します。
2. **必要な追加ツールだけプロファイル指定で入れる**:
   - Pure Zig 実装チャットでは `./zigw` のみで完結させる。
   - Linux ネイティブリンクが必要なときだけ `bash scripts/setup-toolchains.sh --sysroot`、Rust FFI が必要なときだけ `--rust` を実行する。
3. **C ライブラリ境界は `addTranslateC` ではなく手動 `extern fn ... callconv(.c)` モジュールにする**:
   - `@toolchain-bin/sysroot-linux-x64` 内の `.so` に含まれる GNU ld `INPUT(...)` テキストスタブは、`scripts/setup-toolchains.sh --sysroot` が自動的に POSIX シンボリックリンクへ変換し `ldconfig` を通します。
