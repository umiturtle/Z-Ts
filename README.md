# ziggurats

**Tauri の思想を、Zig 0.17 で。** — デスクトップアプリ・WebAssembly・静的サイトを、
1 つのコードベースと 1 つのツールチェーンで。

> プロジェクトのフルネームは **`ziggurats`**（小文字）。CLI・パッケージ・モジュール名は
> これまでどおり `zts` / `z_ts` / `zts_*` です。

[![CI](https://github.com/umiturtle/Z-Ts/actions/workflows/ci.yml/badge.svg)](https://github.com/umiturtle/Z-Ts/actions/workflows/ci.yml)
[![Docs](https://github.com/umiturtle/Z-Ts/actions/workflows/pages.yml/badge.svg)](https://umiturtle.github.io/Z-Ts/)

📖 **ドキュメントサイト: <https://umiturtle.github.io/Z-Ts/>**
（全ドキュメントの検索・目次・**動くサンプル**つき。Markdown はこのリポジトリが正本です）

---

## これは何か

ziggurats は、Tauri v2 の **IPC プロトコル・プラグイン・設定ファイル・ACL** を Zig で再実装した
ツールキットです。Rust ランタイムを挟まないため、配布物は小さく、ビルドは速く、コアは
`link_libc = false`（Pure Zig）のまま保てます。

| 目標 | 手段 |
|---|---|
| **単一バイナリ** | フロントエンドの `dist/` をビルド時に gzip + CSP ハッシュ付きで埋め込む（[埋め込みの仕組み](docs/architecture/build-tools.md)） |
| **3 つの成果物** | ネイティブ WebView / ブラウザ Live Preview（SSE）/ サーバ不要の静的 SSG |
| **OS 間で同じ表示** | 同梱フォント・レイアウト指紋・画素許容差で 3 OS のスクショを CI が相互比較（[画素一致の設計](docs/architecture/screenshot-parity.md)） |
| **9 フレームワーク対応** | Angular / Solid / Svelte / SolidStart / Next.js / Nuxt / Astro / SvelteKit / React |
| **上流との互換** | `@tauri-apps/api` v2 を**無改変**で動かし、`tauri.conf.json` / `capabilities/*.json` を読む |

## クイックスタート（アプリを作る）

配布物は **`zts` の単体バイナリ 1 個**です（約 300 KB、libc 非依存）。必要なのは Zig 0.17 系だけ。

```bash
# 1) GitHub Releases から自分の OS の zts を落として PATH に置く
curl -LO https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/zts-0.1.0-linux-x86_64
chmod +x zts-0.1.0-linux-x86_64
mv zts-0.1.0-linux-x86_64 ~/.local/bin/zts

# 2) プロジェクトを作る
zts init my-app && cd my-app
zts dev                           # web/ を配信し、編集すると自動リロード
zts build                         # zig-out/bin/my-app（web/ はバイナリに埋め込み済み）
zts doctor                        # 環境とプロジェクトの点検
```

`zts init` が書く `build.zig.zon` は **公開アーカイブの `.url` + `.hash`** を指すので、
clone は要りません（初回ビルドで Zig が取得し、以降はキャッシュ）。

```zig
.z_ts = .{ .url = "https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/z_ts-0.1.0.tar.gz", .hash = "z_ts-0.1.0-…" },
```

> ソースから `zts` を作る場合: `git clone … && cd Z-Ts && zig build`（Zig 0.17 系が `PATH` に
> あれば十分です）。その場合の生成物は `.path` 依存になります。詳細は [`docs/learn/ja/guides/install.md`](docs/learn/ja/guides/install.md)。

`zts` は Angular CLI のような位置づけで、**自分のプロジェクトだけ**を操作します。
**はじめてなら [`docs/learn/ja/start.md`](docs/learn/ja/start.md)（10 分）を上から順に**
進めるのが最短です（英語は [`en/start.md`](docs/learn/en/start.md)）。
入手方法・前提は [`docs/learn/ja/guides/install.md`](docs/learn/ja/guides/install.md)、
全オプションは [`docs/reference/cli.md`](docs/reference/cli.md) にあります。

```bash
# 出来合いのサンプルを動かす場合（サンプルは独自の build.zig を持つ）
cd examples/counter
zig build desktop                 # ネイティブ WebView の単一バイナリ
zig build preview                 # ブラウザで Live Preview（0.0.0.0:8788）
zig build dist                    # サーバ不要の静的サイト（zig-out/dist/）
```

## アーキテクチャ

```text
zts_foundation  ← 依存ゼロのデータ構造（OwnedBytes / HandlePool / geometry / glob）
   ↑
zts_web         ← 静的資産配信（206 Range / MIME / URL / CSP）     ← foundation のみ
zts_rpc         ← comptime JSON/Binary RPC ルータ + TypeScript 生成  ← foundation のみ
zts_bridge      ← HTTP/1.1 + SSE のライブサーバ                    ← foundation・web・rpc
zts_webview     ← GTK3+WebKit2GTK / Cocoa / Win32 / HeadlessMock    ← foundation のみ
zts_tauri       ← Tauri v2 プロトコル + 標準プラグイン              ← 上記すべて
zts_wasm        ← wasm32-freestanding ランタイム（同じコードをブラウザへ）
zts_ssg         ← 外向き SSG（dist/ 書き出し）と埋め込み（dist/ → Zig モジュール）
```

**境界の約束**: 各パッケージは `mod.zig` 以下で自己完結し、コアは C ライブラリをリンクしない
（OS 境界は `extern fn … callconv(.c)` の明示バインディングのみ）。詳しくは
[`docs/architecture/00-overview.md`](docs/architecture/00-overview.md)。

## リポジトリの歩き方

**アプリを作る人向け**（コマンドは `zts`）

学習パスはドキュメントサイトと同じ **5 ステップ・およそ 95 分**です。まず 1 つ目を開いてください。

| # | ステップ | 分 | 終わったとき | 行き先 |
|---|---|---|---|---|
| 1 | はじめての ziggurats | 10 | ブラウザでアプリが動き、`zig-out/bin/` に単一バイナリがある | [`learn/ja/start.md`](docs/learn/ja/start.md)（[English](docs/learn/en/start.md)） |
| 2 | 仕組みを知る | 15 | 「ボタン → Zig の関数」がどこを通るか説明できる | [`learn/ja/concepts/`](docs/learn/ja/concepts/index.md) |
| 3 | アプリを作る | 50 | 3 本のチュートリアルを通し、コマンド・状態・画面を書いて配れる | [`learn/ja/tutorials/`](docs/learn/ja/tutorials/index.md) |
| 4 | 実用パターン | 20 | コマンド・状態・エラーの設計を、練習問題で自分の言葉にできる | [`learn/ja/patterns/`](docs/learn/ja/patterns/index.md) |
| 5 | 目的から引く | — | やりたいことから必要なページに 1 ホップで行ける | [`learn/ja/guides/`](docs/learn/ja/guides/index.md) |

**やりたいことから引く**

| 目的 | 行き先 |
|---|---|
| 好きなライブラリでチュートリアルを進める（9 分岐） | [`learn/ja/tutorials/frameworks.md`](docs/learn/ja/tutorials/frameworks.md) |
| `zts` を手元に用意する | [`learn/ja/guides/install.md`](docs/learn/ja/guides/install.md) |
| コマンドの書き方（`invoke`） | [`learn/ja/guides/rpc.md`](docs/learn/ja/guides/rpc.md) |
| Tauri 標準プラグイン | [`learn/ja/guides/plugins.md`](docs/learn/ja/guides/plugins.md) |
| 静的サイト書き出し（`dist/`） | [`learn/ja/guides/static-site.md`](docs/learn/ja/guides/static-site.md) |
| 配布物を作る（`.deb` / `.dmg` / `.exe`） | [`learn/ja/guides/package.md`](docs/learn/ja/guides/package.md) |
| Tauri v2 からの移行 | [`learn/ja/guides/migrate-from-tauri.md`](docs/learn/ja/guides/migrate-from-tauri.md) |
| うまく動かないとき | [`learn/ja/guides/troubleshooting.md`](docs/learn/ja/guides/troubleshooting.md) |
| **API リファレンス**（ソースから自動生成） | <https://umiturtle.github.io/Z-Ts/docs/api/index.html>（`zig build docs` で手元にも生成） |
| 言葉の意味 | [`docs/glossary.md`](docs/glossary.md) |
| エラー名から引く | <https://umiturtle.github.io/Z-Ts/docs/reference/errors.html> |
| `zts` の全オプション | [`docs/reference/cli.md`](docs/reference/cli.md) |

**ziggurats 本体を開発する人向け**（コマンドは `zig build`）

| 目的 | 行き先 |
|---|---|
| **リポジトリ開発の入口** | [`docs/contributing/README.md`](docs/contributing/README.md) |
| `zig build` のステップ・スクリプト | [`docs/contributing/README.md`](docs/contributing/README.md) §3 |
| 本体のトラブルシューティング | [`docs/contributing/troubleshooting.md`](docs/contributing/troubleshooting.md) |
| ドキュメントサイトを生成する | `zig build docs`（→ `zig-out/docs/`） |

**中を読む人向け**（実装の意図・経緯）

| 目的 | 行き先 |
|---|---|
| 全体像・依存 DAG | [`docs/architecture/00-overview.md`](docs/architecture/00-overview.md) |
| マイルストーン（M0〜M5） | [`docs/roadmap/milestones.md`](docs/roadmap/milestones.md) |
| 各タスクの進捗・設計メモ | [`docs/tasks/`](docs/tasks/) （1 タスク = 1 ファイル） |
| 設計判断の記録（ADR） | [`docs/decisions/`](docs/decisions/) |
| Tauri v2 の使い方 / 内部解剖 | [`docs/reference/tauri-usage.md`](docs/reference/tauri-usage.md) / [`docs/reference/tauri-internals.md`](docs/reference/tauri-internals.md) |
| AI エージェント向け運用ルール | [`AGENTS.md`](AGENTS.md) |
| ドキュメント索引（サイトと同じ並び） | [`docs/INDEX.md`](docs/INDEX.md) / [`docs/INDEX.en.md`](docs/INDEX.en.md) |
| ファイル配置・並列開発の分割単位 | [`docs/contributing/repository-map.md`](docs/contributing/repository-map.md) |
| 最終書き換え日・確認バージョンの台帳 | [`docs/contributing/doc-sync.md`](docs/contributing/doc-sync.md) |

## サンプル

| サンプル | 内容 |
|---|---|
| [`examples/counter/`](examples/counter/README.md) | 1 プロジェクト → デスクトップ / Live Preview / 静的 SSG の 3 成果物 |
| [`examples/gallery/`](examples/gallery/README.md) | 17 パターンのスクリーンショット回帰（3 OS で相互比較） |
| [`examples/frameworks/`](examples/frameworks/README.md) | 9 フレームワークで「同じ 1 画面」 |
| [`examples/c_embed/`](examples/c_embed/README.md) | 純粋な C99 ホストの既存ウィンドウへ Overlay 埋め込み |

## 開発の作法

* **TDD**（🔴 RED → 🟢 GREEN → 🔵 REFACTOR → 📝 COMMIT）と `std.testing.allocator` による
  リークゼロ。公開関数ごとに正常系・異常系・境界値・セキュリティ境界を最低 5〜10 ケース。
* **上流コード精読ファースト** — 推測で仕様を作らず `vendor/{tauri,wry,tao,muda}` を読む。
* **`build.zig` の変更は最小限** に留め、共通ロジックは
  [`src/build_tools/`](docs/architecture/build-tools.md) と
  [`src/docsite/`](docs/architecture/documentation-site.md) に置く。
* CI（GitHub Actions）が Linux / macOS / Windows の 3 環境 + 画素比較ジョブで検証する。
* ドキュメントは **1 タスク / 1 モジュール / 1 決定 = 1 ファイル**。ルートに
  `PROGRESS.md` のような集約ファイルを作らない（並列エージェントの衝突源になる）。

## ライセンス

上流の [`tauri`](https://github.com/tauri-apps/tauri) / [`wry`](https://github.com/tauri-apps/wry) /
[`tao`](https://github.com/tauri-apps/tao) / [`muda`](https://github.com/tauri-apps/muda) は
それぞれのライセンス（MIT / Apache-2.0）に従います。`vendor/` 以下のコードは**参照用**であり、
ビルドには含まれません。
