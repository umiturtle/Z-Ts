# Arena 実行環境・キャッシュ揮発対策・ツールチェーン詳細

このドキュメントは、Arena サンドボックス環境における実測データと、**「毎チャットごとにキャッシュ・システム領域が飛ぶ」制約下で最速のイテレーションを回すための技術設計**をまとめたリファレンスです。

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

> **非接続ドメイン**: `ziglang.org`, `static.rust-lang.org`, `crates.io` (`static.crates.io`), `deb.debian.org`, `objects.githubusercontent.com`（GitHub Release アセットのリダイレクト先）はブロックされます。
> そのため、本リポジトリのツールチェーン取得および CI キャッシュ配布は **すべて PyPI / npm / `codeload.github.com`（Git orphan ブランチ）で完結** するように設計されています。

---

## 2. 毎チャットのコールドスタート計測値と最適化アーキテクチャ

新しいチャット（または並列エージェントの新規ブランチ）を開くたび、コンテナ内の `~/.cache/zig` や `/usr/local` は初期状態に戻ります。実機ベンチマークにより判明したボトルネックと解決策は以下の通りです：

| シナリオ（コールドコンテナ起動直後） | 実測時間 | ボトルネック原因 / 高速化の仕組み |
|---|---|---|
| ❌ キャッシュ空から素で `zig build test` | **94.05 秒** | `std.Build` ビルドランナーと `compiler_rt` をゼロからフルコンパイルするため |
| ❌ `gtk/gtk.h` + `webkit2/webkit2.h` を `addTranslateC` | **+約 50 秒** | 数十万行の C ヘッダ群を Clang フロントエンドが毎回パースするため |
| ⚡ ダイレクト `./zigw test src/<mod>.zig` | **4.88 秒**（2回目以降 **0.08 秒**） | `std.Build` ランナーのコンパイル自体をスキップできる |
| 🚀 **`./zigw build test`（`ci-cache-linux-x64` 自動復元あり）** | **約 2.5 秒**（初回 Zig 導入込みでも **約 6 秒**） | GitHub Actions が事前生成した `~/.cache/zig`（約 25MB）を `codeload.github.com` からストリーミング展開するため **約 38 倍高速** |

### 実践ルールまとめ

1. **常に `./zigw` 経由で実行する**:
   - Zig 未導入なら約 3 秒で `zipfile` 直接展開し、同時に `origin/ci-cache-linux-x64` から温かい `~/.cache/zig` を自動展開します。
2. **必要な追加ツールだけプロファイル指定で入れる**:
   - Pure Zig 実装チャットでは `./zigw` のみで完結させ、不要な Rust 導入（+8秒）や Linux GUI Sysroot 導入（+8秒）を実行しない。
   - Linux ネイティブリンクが必要なときだけ `bash scripts/setup-toolchains.sh --sysroot`、Rust FFI が必要なときだけ `--rust` を実行する。
3. **C ライブラリ境界は `addTranslateC` ではなく手動 `extern fn ... callconv(.c)` モジュールにする**:
   - `@toolchain-bin/sysroot-linux-x64` 展開時の `.so` ファイル群に含まれる GNU ld `INPUT(...)` テキストスタブは、`scripts/setup-toolchains.sh --sysroot` が自動的に POSIX シンボリックリンクへ変換し `ldconfig` を通します。
