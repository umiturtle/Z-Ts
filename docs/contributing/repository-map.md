# リポジトリの地図（開発者向け）

> **対象読者**: Z-Ts 本体を直す人・エージェント。どのファイルが何で、どこまで触ってよいか。
> **所要時間**: 引きたい行だけ 30 秒。
> **前提**: [`README.md`](README.md) のツールチェーンの節。

**アプリを作る人は読む必要がありません。** 使い方は [`../INDEX.md`](../INDEX.md) と
[`../learn/ja/index.md`](../learn/ja/index.md) にあります。ここは**リポジトリの中の配置**の話です。

この表の目的は 2 つあります。記憶が飛んだときに現在地を戻すことと、**複数のブランチが同じ
ファイルを触らないようにすること**です。「更新頻度・競合リスク」列が分割の単位です。

## 1. ドキュメントの 4 層

| 層 | 正本 | 読む人 | 置き場所 |
|---|---|---|---|
| ① 学ぶ | 手順と最小例 | アプリ作者 | [`../learn/`](../learn/ja/index.md)（日英 2 言語・同名ファイル） |
| ② 引く | **Zig のソース**（`///`） | アプリ作者 | `../api/**`（`zig build docs` の生成物・非コミット）、[`../reference/`](../reference/cli.md)、[`../glossary.md`](../glossary.md) |
| ③ 確かめる | 振る舞いの約束 | アプリ作者 | [`../reference/cli.md`](../reference/cli.md)、[`../reference/tauri-usage.md`](../reference/tauri-usage.md) |
| ④ 中を読む | ADR・設計メモ・タスク | 開発者 | [`../architecture/`](../architecture/00-overview.md)、[`../decisions/`](../decisions/0001-zig-017-and-sharded-agent-workflow.md)、[`../roadmap/milestones.md`](../roadmap/milestones.md)、[`../tasks/`](../tasks/TEMPLATE.md)、[`../environment/`](../environment/arena-and-caching.md) |

**①〜③ だけでライブラリは使えます。** ④ は実装の意図と経緯の記録です。公開サイトでは ④ を
「内部資料」1 エントリに畳み、検索索引からも外しています。層を混ぜると、読者は引けない
マイルストーン ID を読むことになります（[`writing-docs.md`](writing-docs.md) §8）。

リポジトリの操作（`zig build` のステップ・CI・サイト生成）は ①〜④ の**外**にあり、
このディレクトリ（`docs/contributing/`）に隔離しています。

## 2. ドキュメントの配置

| パス | 役割 | 更新頻度・競合リスク |
|---|---|---|
| [`../../AGENTS.md`](../../AGENTS.md) | 全エージェント必読の運用ルール | 低頻度（進捗追記禁止・チェックボックスは編集しない） |
| [`../INDEX.md`](../INDEX.md) / [`../INDEX.en.md`](../INDEX.en.md) | サイトのサイドバーと同じ並びの索引（日英） | ページを足したときだけ 1 行ずつ |
| [`doc-sync.md`](doc-sync.md) / [`doc-sync.en.md`](doc-sync.en.md) | 最終書き換え日・確認バージョン・本文と実装の sha256（規約 13） | 再確認のたび（`--sync` が自動生成） |
| `../learn/ja/` / `../learn/en/` | 学習パス 5 ステップ。`start.md` → `concepts/` → `tutorials/` → `patterns/` → `guides/` | 章ごとに独立。**ja と en は同名ファイル必須**（規約 8） |
| [`../learn/ja/index.md`](../learn/ja/index.md) | 学習の入口。道順は `src/docsite/learn_path.zig` から展開される | 低頻度（`<!-- learn-path -->` の行は消さない） |
| [`../learn/ja/start.md`](../learn/ja/start.md) | 10 分の導入。`zts` の入手 → `doctor` → `init` → `dev` → `build` | 低頻度（CLI の出力が変わったとき） |
| `../learn/*/concepts/` | 仕組み（パッケージ構成・コマンド・プラグイン・セキュリティ） | 機能追加時に 1 ページ追加 |
| `../learn/*/tutorials/` | 手を動かす章 | 低頻度 |
| `../learn/*/patterns/` | 設計の判断基準と練習（4 ページ + 索引） | 低頻度（API が変わったらコード例だけ） |
| `../learn/*/guides/` | 目的別（install / rpc / plugins / static-site / package / migrate / troubleshooting） | ガイド単位で独立 |
| [`../reference/cli.md`](../reference/cli.md) | `zts` の全フラグ | フラグ追加時に必ず（規約 4 が実装と突き合わせる） |
| [`../glossary.md`](../glossary.md) | 用語の定義（`## Term` が 1 項目） | 用語を足したときだけ |
| [`../architecture/00-overview.md`](../architecture/00-overview.md) | 6 パッケージの依存 DAG・境界契約 | 中頻度（全体方針の変更時） |
| [`../architecture/web-zig-boundary.md`](../architecture/web-zig-boundary.md) | HTML / CSS / TS ⇔ Zig の言語仕様ギャップの解決規約 | 境界仕様（全パッケージ必読） |
| [`../architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md) | 双方向 SSG と `zts_wasm` の 4 モード | サブシステム単位 |
| [`../architecture/zts-webview-backends.md`](../architecture/zts-webview-backends.md) | WebView 4 バックエンドの契約・C ABI・スクショ | サブシステム単位 |
| [`../architecture/build-tools.md`](../architecture/build-tools.md) | `build.zig` ヘルパー（`embedFrontend` / `tsgen`） | サブシステム単位 |
| [`../architecture/documentation-site.md`](../architecture/documentation-site.md) | このサイトの生成・検査・検索 | サイトを直すとき |
| [`../architecture/screenshot-parity.md`](../architecture/screenshot-parity.md) | 3 OS の画素一致（フォント・指紋・許容差） | CI 回帰を触るとき |
| [`../architecture/rpc-codec.md`](../architecture/rpc-codec.md) | RPC のワイヤ形式と `tsgen` | サブシステム単位 |
| [`../architecture/tauri-*.md`](../architecture/tauri-fs-plugin.md) | プラグイン個別の設計（fs / dialog・clipboard / menu・tray / config・ACL） | プラグイン単位 |
| [`../architecture/packaging-and-bench.md`](../architecture/packaging-and-bench.md) | パッケージャと対 Rust ベンチ | サブシステム単位 |
| [`../architecture/docs-as-a-product.md`](../architecture/docs-as-a-product.md) | ドキュメントサイトの方針（12 サイトの調査・原則 P1〜） | 方針を変えるとき |
| [`../decisions/`](../decisions/0001-zig-017-and-sharded-agent-workflow.md) | ADR（`NNNN-slug.md`） | **新規ファイル追加のみ**（既存は書き換えない） |
| [`../roadmap/milestones.md`](../roadmap/milestones.md) | M0〜M5 のマイルストーンと並列 Wave | 低頻度（チェックボックスは編集しない） |
| [`../roadmap/m1-foundation-packages.md`](../roadmap/m1-foundation-packages.md) / [`m2-m5-platform-and-ecosystem.md`](../roadmap/m2-m5-platform-and-ecosystem.md) | 各マイルストーンの詳細仕様 | 仕様リファレンス |
| [`../tasks/TEMPLATE.md`](../tasks/TEMPLATE.md) | 1 タスク = 1 ファイルの雛形 | テンプレート |
| `../tasks/<ID>-<slug>.md` | 個別タスクの進捗・設計メモ・次の 1 手 | **担当ブランチ専有（競合ゼロ）** |
| [`../environment/arena-and-caching.md`](../environment/arena-and-caching.md) | キャッシュ揮発対策・高速ビルド規約 | 環境変更時のみ |
| [`../environment/github-actions.md`](../environment/github-actions.md) | 3 OS マトリクス・キャッシュ・ベンチ運用 | CI 変更時のみ |
| `../api/**`（生成物・非コミット） | `///` から生成する API リファレンス | **手で編集しない** |

## 3. コードとサンプルの配置

| パス | 役割 | 競合リスク |
|---|---|---|
| `src/foundation/` | `zts_foundation`（依存ゼロ） | 低（完成済み・安定） |
| `src/web/` | `zts_web`（配信・MIME・Range・CSP） | 低 |
| `src/core/` | `zts_core`（Host 契約・世代プール） | 中 |
| `src/rpc/` | `zts_rpc`（`Schema` / codec / `tsgen`） | 中 |
| `src/bridge/` | `zts_bridge`（HTTP/1.1 + SSE） | 中 |
| `src/webview/` | `zts_webview`（4 バックエンド + C ABI） | バックエンドごとに独立 |
| `src/tauri/` | `zts_tauri`（プロトコル + 標準プラグイン） | プラグインごとに独立 |
| `src/wasm/` | `zts_wasm` | 低 |
| `src/ssg/` | `zts_ssg` | 低 |
| `src/cli/` | `zts` CLI（`init` / `dev` / `build` / `package` / `doctor`） | サブコマンドごとに独立 |
| `src/docsite/` | このサイトの生成器（Markdown・リンク検査・API 生成） | 中（`main.zig` は大きい） |
| `src/docsite/learn_path.zig` | 学習パスの 5 ステップ・所要分・**左メニューの章内読み順**（`page_order`） | 中（チュートリアルを足すとき。規約 12 が索引と分を突き合わせる） |
| `build.zig` / `build.zig.zon` | モジュール定義とステップ | **高い**（触る前に他ブランチを確認） |
| `examples/counter/` | 3 成果物ショーケース | 追記のみ |
| `examples/gallery/` | スクリーンショット回帰（17 パターン） | 追記のみ |
| `examples/frameworks/` | 9 フレームワークの同一画面デモ | 生成物は再生成で更新 |
| `examples/c_embed/` | C99 からの Overlay 埋め込み | 追記のみ |
| `scripts/` | `check-docs.py` / `doc-tests.py` / CI 補助 | `check-docs.py` は規約追加時に集中 |

## 4. 並列開発のための分割原則

1. **1 タスク = 1 ファイル**。進捗は `docs/tasks/<ID>-<slug>.md` に書き、共有ファイル
   （`AGENTS.md`・`milestones.md`・`INDEX.md`）には書かない。
2. **ADR は新規追加のみ**。既存の ADR を書き換えると、その番号を参照している全ブランチが衝突する。
3. **`build.zig` は分散ロック**。触る前に [`../../AGENTS.md`](../../AGENTS.md) §2 の手順に従う。
4. **学習ページは ja と en を同じ PR で**。片方だけだと規約 8 で CI が落ちる（落ちる場所で
   気づけるようにしてある）。
5. **生成物はコミットしない**。`docs/api/**`・`zig-out/**` は `zig build docs` の出力。
