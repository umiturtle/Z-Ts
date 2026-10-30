# Z-Ts ドキュメント索引（Documentation Hub）

`Z-Ts` では、**エージェントの定期的な記憶リセット（Context Compaction）への耐性** と **複数エージェントの同時並列開発（Git コンフリクトゼロ）** を両立するため、用途ごとに Markdown ファイルを厳格に分離しています。

---

## ディレクトリマップ

| パス | 役割 | 更新頻度・競合リスク |
|---|---|---|
| [`../AGENTS.md`](../AGENTS.md) | 全エージェント必読のエントリーポイント・運用ルール | 低頻度（進捗追記禁止） |
| [`architecture/00-overview.md`](architecture/00-overview.md) | Z-Ts 6 パッケージ直交アーキテクチャ・依存 DAG・モジュール境界契約 | 中頻度（全体方針変更時） |
| [`architecture/web-zig-boundary.md`](architecture/web-zig-boundary.md) | HTML / CSS / TS ⇔ Zig `0.17.0` 言語仕様ギャップ 10 項目の解決規約 | 境界仕様（全パッケージ必読） |
| [`architecture/ssg-and-wasm.md`](architecture/ssg-and-wasm.md) | 双方向 SSG（`embedFrontendDir` / `dist/` 出力）と `zts_wasm` 4 モード同型アーキテクチャ | サブシステム設計（静的 Web 出力時） |
| [`architecture/zts-webview-backends.md`](architecture/zts-webview-backends.md) | `zts_webview` 4 バックエンドの共通契約・Overlay 埋め込み・C ABI・スクリーンショット取得・テスト戦略 | サブシステム設計（WebView 全般） |
| [`architecture/build-tools.md`](architecture/build-tools.md) | `build.zig` 統合ヘルパー（`embedFrontend` の gzip/CSP マニフェスト生成・`tsgen` の生成/検証 2 モード・3 層構造）（`M5-01`） | サブシステム設計（ビルド統合時） |
| [`architecture/documentation-site.md`](architecture/documentation-site.md) | ドキュメントサイト生成（Markdown → 静的 HTML・リンク検査・検索インデックス・サンプル公開）（`M5-06`） | サブシステム設計（ドキュメント公開時） |
| [`architecture/screenshot-parity.md`](architecture/screenshot-parity.md) | 3 OS で「同じ表示」を保証する仕組み（同梱フォント・レイアウト指紋・画素許容差・9 フレームワーク） | サブシステム設計（CI 回帰） |
| [`architecture/tauri-fs-plugin.md`](architecture/tauri-fs-plugin.md) | スコープ付きファイルシステム `plugin:fs`（正規化 → リンク解決 → 包含判定・全コマンド表・エラーコード） | サブシステム設計（FS 利用時） |
| [`architecture/tauri-config-import-acl.md`](architecture/tauri-config-import-acl.md) | `tauri.conf.json` のインポートと `capabilities/*.json` の ACL（未知は警告・型違いはエラー・fail-closed） | Tauri プロジェクトを移行するとき |
| [`architecture/tauri-menu-tray.md`](architecture/tauri-menu-tray.md) | ネイティブメニュー & システムトレイ `plugin:menu` / `plugin:tray`（平板スナップショット・22+12 コマンド・アクセラレータ） | サブシステム設計（メニュー/トレイ利用時） |
| [`architecture/tauri-dialog-clipboard.md`](architecture/tauri-dialog-clipboard.md) | OS ダイアログ & クリップボード `plugin:dialog` / `plugin:clipboard-manager`（vtable + ネイティブ分離・untagged 戻り値・3 OS 対応表） | サブシステム設計（ダイアログ/クリップボード利用時） |
| `architecture/<module>.md` | 各サブシステム詳細設計（例: `config.md`, `ipc.md`, `acl.md`, `window-linux.md`） | モジュール単位で完全独立 |
| [`roadmap/milestones.md`](roadmap/milestones.md) | 全体マイルストーン（M0〜M5・全 20 タスク）と並列 Wave 依存マップ | 低頻度（進捗は `tasks/` で管理） |
| [`roadmap/m1-foundation-packages.md`](roadmap/m1-foundation-packages.md) | M1 詳細仕様（コア 5 パッケージのファイル境界・公開型・DoD） | 実装仕様リファレンス |
| [`roadmap/m2-m5-platform-and-ecosystem.md`](roadmap/m2-m5-platform-and-ecosystem.md) | M2〜M5 詳細仕様（E2E・macOS/Windows・OS 統合・CLI・比較ベンチ） | 実装仕様リファレンス |
| [`tasks/TEMPLATE.md`](tasks/TEMPLATE.md) | 1タスク＝1ファイルの作業計画＆記憶チェックポイント標準テンプレート | テンプレート |
| `tasks/<ID>-<slug>.md` | 個別タスクの進捗・設計メモ・次の1手（例: [`tasks/M0-01-bootstrap.md`](tasks/M0-01-bootstrap.md)） | **担当ブランチ専有（競合ゼロ）** |
| `decisions/<NNNN>-<slug>.md` | アーキテクチャ意思決定記録（ADR）（[`0001`](decisions/0001-zig-017-and-sharded-agent-workflow.md), [`0002`](decisions/0002-hybrid-architecture-proposal.md), … , [`0009`](decisions/0009-screenshot-capture-and-ci-gallery.md), [`0010`](decisions/0010-cross-os-pixel-parity.md), [`0011`](decisions/0011-scoped-fs-plugin.md), [`0012`](decisions/0012-dialog-and-clipboard-backends.md), [`0013`](decisions/0013-menu-and-tray-backends.md), [`0014`](decisions/0014-config-import-and-acl.md), [`0015`](decisions/0015-native-menu-cocoa-win32.md), [`0016`](decisions/0016-native-tray-cocoa-win32.md), [`0017`](decisions/0017-build-tools.md), [`0018`](decisions/0018-documentation-site.md)） | **新規ファイル追加のみ（競合ゼロ）** |
| [`../examples/counter/README.md`](../examples/counter/README.md) | ショーケースサンプル（1 プロジェクト → デスクトップ / Live Preview / 静的 SSG の 3 成果物） | 実装サンプル（追記のみ） |
| [`../examples/c_embed/README.md`](../examples/c_embed/README.md) | 純粋な C99 ホストから既存ウィンドウへ Overlay 埋め込み（`M3-03`） | 実装サンプル（追記のみ） |
| [`../examples/gallery/README.md`](../examples/gallery/README.md) | スクリーンショット回帰ギャラリー（17 パターン → PNG + `manifest.json`、CI が 3 OS で実行し相互比較）（`M5-04`/`M5-05`） | 実装サンプル（追記のみ） |
| [`../examples/frameworks/README.md`](../examples/frameworks/README.md) | 9 フレームワーク（Angular/Solid/Svelte/SolidStart/Next/Nuxt/Astro/SvelteKit/React）の同一画面デモと再生成手順（`M5-05`） | 実装サンプル（追記のみ） |
| [`environment/arena-and-caching.md`](environment/arena-and-caching.md) | 毎チャットキャッシュ揮発対策・LLVM 同梱検証・高速ビルド規約 | 環境変更時のみ |
| [`environment/github-actions.md`](environment/github-actions.md) | GitHub Actions 3 OS マトリクス・キャッシュ自動配信・ベンチ/差分テスト運用 | CI 変更時のみ |
| [`reference/tauri-usage.md`](reference/tauri-usage.md) | Tauri v2 の使い方リファレンス（Rust/JS API・設定・Capabilities） | リファレンス（追記のみ） |
| [`reference/tauri-internals.md`](reference/tauri-internals.md) | Tauri v2 内部実装の完全解剖（IPC プロトコル・マクロ・10個の内蔵 Plugin・OS 層） | リファレンス（追記のみ） |
