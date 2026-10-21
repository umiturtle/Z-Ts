# Z-Ts マスターロードマップ（全体計画 & 並列実行マトリクス）

> **運用ルール（コンフリクト防止）**:
> - **このファイルの本文をタスク進捗のたびに書き換えないでください**（複数ブランチ並列稼働時のマージ衝突を防ぐため）。
> - 各タスクのリアルタイムの着手・完了状態は **`docs/tasks/<ID>-<slug>.md` の `Status` フィールド** で管理し、`bash scripts/status.sh` で自動集計します。

---

## 詳細ロードマップ分割ファイル

| ドキュメント | カバー範囲 | 対象タスク ID |
|---|---|---|
| **本書 (`milestones.md`)** | 全体フェーズ設計・並列実行 Wave 計画・全 20 タスク俯瞰表 | `M0-01` 〜 `M5-03` |
| [`m1-foundation-packages.md`](m1-foundation-packages.md) | **M1 詳細仕様**: コア 5 パッケージ（`core`, `rpc`, `bridge`, `webview`, `tauri`）のファイル構成・公開型・テスト完了基準 | `M1-01` 〜 `M1-07` |
| [`m2-m5-platform-and-ecosystem.md`](m2-m5-platform-and-ecosystem.md) | **M2〜M5 詳細仕様**: E2E 統合・macOS/Windows ネイティブ・OS ダイアログ/トレイ・CLI/Bundler・対 Rust Tauri ベンチマーク | `M2-01` 〜 `M5-03` |

関連する設計基準書：
- 6 パッケージ依存 DAG: [`../architecture/00-overview.md`](../architecture/00-overview.md)
- HTML / CSS / TS ⇔ Zig 10 大境界規約: [`../architecture/web-zig-boundary.md`](../architecture/web-zig-boundary.md)
- アーキテクチャ決定記録: [`../decisions/0002-hybrid-architecture-proposal.md`](../decisions/0002-hybrid-architecture-proposal.md)

---

## 1. フェーズ全体像と検証ゲート（なぜこの順番で作るのか）

「実装しながら問題を早期に炙り出す」ため、**各マイルストーンの出口に必ず実動作ゲート（コンパイラ・実 `tsc`・実ブラウザ・3 OS 実機 CI）** を設けています：

```text
Wave 0 [完了] ── M0: ツールチェーン検証・コールド5秒テスト基盤・3-OS Actions CI・設計監査
   │
   ▼
Wave 1 [並列3] ── M1 前半: 他に一切依存しない独立コア層の同時構築
   ├─ M1-01: zts_core (プリミティブ: u53 HandlePool, OwnedBytes, Host VTable, Queue)
   ├─ M1-02: zts_core (Web 基盤: MIME, SPA, 206 Range Assets, HTML-Safe JSON, CSP, Glob)
   └─ M1-03: zts_rpc  (Codec: camelCase, Patch(T), BigInt, Bytes, OsPath, Tagged Union)
   │
   ▼
Wave 2 [並列4] ── M1 後半: ルーター/TS生成・トランスポート・OS WebView・Tauri 互換層
   ├─ M1-04: zts_rpc     (Schema/bind, ErrorSet→TS Union `tsgen` + 実 `tsc --strict` 検証)
   ├─ M1-05: zts_bridge  (std.Io.net HTTP+SSE, 三重認証 ── Arena Live Preview 動作!)
   ├─ M1-06: zts_webview (C ABI VTable, Mock, step(), Linux GTK3+WebKit2GTK 非同期応答)
   └─ M1-07: zts_tauri   (__TAURI_INTERNALS__ JS, Channel, drag-region, 標準コマンド群)
   │
   ▼
Wave 3 [統合]  ── M2: Vertical Slice 3 モード完全実証ゲート
   ├─ M2-01: `zts` 統合ファサード & `build.zig` マルチモジュール公開
   └─ M2-02: 本家 `@tauri-apps/api` UI が ①0ms Mock / ②Live Preview / ③Linux Xvfb で完動!
   │
   ▼
Wave 4 [並列5] ── M3 & M4: 3 大 OS 制覇 + デスクトップ標準機能の一斉並列展開
   ├─ M3-01: macOS Native (`WKWebView` + `WKURLSchemeTask` + Y軸変換 on Actions macOS)
   ├─ M3-02: Windows Native (Win32 DPI v2 + 内蔵 WebView2 Direct Loader on Actions Win)
   ├─ M3-03: 既存親ウィンドウ埋め込み (Overlay) & `include/zts_webview.h` C ABI 実証
   ├─ M4-01: Dialog & Clipboard コマンドモジュール (Linux / macOS / Windows)
   ├─ M4-02: Scoped FS コマンドモジュール (`OsPath` 往復 & シンボリックリンク脱出防止)
   ├─ M4-03: Native Menu & System Tray モジュール
   └─ M4-04: `tauri.conf.json` & `capabilities/*.json` comptime インポータ
   │
   ▼
Wave 5 [仕上げ] ── M5: ビルド統合・CLI・インストーラ・対本家 Rust Tauri 定量比較
   ├─ M5-01: `build.zig` 自動アセット埋め込み (`embedFrontend`) & `tsgen` ステップ
   ├─ M5-02: `zts` CLI (`init` / `dev` ホットリロード連携 / `build`)
   └─ M5-03: 3-OS パッケージャ (.deb/AppDir, .app/.dmg, 単一.exe) & 比較ベンチマーク完走
```

---

## 2. 全 20 タスク一覧 & 排他ファイルスコープ表（並列衝突防止マップ）

並列エージェントが同時に動く際は、**「担当 Scope ディレクトリが重ならないタスク」** を選んで `docs/tasks/<ID>-<slug>.md` を作成してください：

| ID | タスク名 | Wave | 依存タスク | 専有ファイルスコープ（他ブランチ編集禁止領域） | 主な検証手段 |
|---|---|---|---|---|---|
| **`M0-01`** | ブートストラップ・コールド高速化・3-OS CI | W0 | なし | `zigw`, `scripts/`, `.github/workflows/ci.yml` | 完了済み |
| **`M1-01`** | `zts_core` 基盤型・世代プール・Host 契約 | W1 | `M0-01` | `src/core/{mod,handle_pool,owned_bytes,queue,geometry,host}.zig` | `./zigw quick-test` |
| **`M1-02`** | `zts_core` アセット・MIME・Range・CSP・Glob | W1 | `M0-01` | `src/core/{assets,mime,http_range,csp,html_escape,glob,url}.zig` | `./zigw quick-test` |
| **`M1-03`** | `zts_rpc` 型システム & JSON コーデック | W1 | `M0-01` | `src/rpc/{types,codec,naming}.zig` | `./zigw quick-test` |
| **`M1-04`** | `zts_rpc` Schema/bind ルーター & `tsgen` | W2 | `M1-01`, `M1-03` | `src/rpc/{mod,ctx,schema,tsgen}.zig`, `tests/tsgen/` | `quick-test` + `tsc` |
| **`M1-05`** | `zts_bridge` セキュア HTTP+SSE ブリッジ | W2 | `M1-01`, `M1-02` | `src/bridge/` | `quick-test` + HTTP E2E |
| **`M1-06`** | `zts_webview` C ABI・Mock・Linux WebKit2GTK | W2 | `M1-01`, `M1-02` | `src/webview/{mod,c_api,mock,linux}.zig`, `include/zts_webview.h` | `quick-test` + Actions Linux |
| **`M1-07`** | `zts_tauri` ワイヤー層・Channel・基本コマンド | W2 | `M1-01`, `M1-04` | `src/tauri/{mod,protocol,channel,js_bootstrap,window,event,path,app}.zig` | `quick-test` |
| **`M2-01`** | `zts` ファサード & `build.zig` モジュール公開 | W3 | `M1-04`..`M1-07` | `src/root.zig`, `src/app.zig`, `build.zig` | `zig build test` (3 OS) |
| **`M2-02`** | Vertical Slice デモ & `@tauri-apps/api` E2E | W3 | `M2-01` | `examples/counter/`, `tests/e2e/` | Mock + Bridge + Xvfb |
| **`M3-01`** | macOS ネイティブ (`WKWebView` + `NSWindow`) | W4 | `M1-06`, `M2-01` | `src/webview/{macos.zig,macos_shim.m}` | Actions `macos-latest` |
| **`M3-02`** | Windows ネイティブ (`Win32` + 内蔵 WebView2) | W4 | `M1-06`, `M2-01` | `src/webview/{windows,webview2_com,webview2_loader}.zig` | Actions `windows-latest` |
| **`M3-03`** | 親ウィンドウ Overlay 埋め込み & C ABI サンプル | W4 | `M3-01`, `M3-02` | `examples/c_embed/`, `src/webview/embed_test.zig` | C コンパイルリンク実行 |
| **`M4-01`** | ネイティブ Dialog & Clipboard モジュール | W4 | `M2-01` | `src/tauri/{dialog,clipboard}/` | Mock + 3-OS CI |
| **`M4-02`** | Scoped FileSystem (`OsPath` & シンボリック防御) | W4 | `M2-01` | `src/tauri/fs/` | `quick-test` (リーク/境界) |
| **`M4-03`** | ネイティブ Menu & System Tray モジュール | W4 | `M2-01` | `src/tauri/{menu,tray}/` | Mock + 3-OS CI |
| **`M4-04`** | `tauri.conf.json` & `capabilities` インポータ | W4 | `M2-01` | `src/tauri/{config_import,acl}.zig` | 上流設定サンプル検証 |
| **`M5-01`** | `build.zig` ヘルパー (`embedFrontend` / `tsgen`) | W5 | `M2-02` | `src/build_tools/` | 実 Vite 出力バンドル検証 |
| **`M5-02`** | `zts` CLI (`init` / `dev` / `build`) | W5 | `M5-01` | `src/cli/` | スキャフォールド E2E |
| **`M5-03`** | 3-OS パッケージャ & 対 Rust Tauri ベンチマーク | W5 | `M3-01`, `M3-02`, `M5-01` | `src/bundler/`, `bench/` | 3-OS Actions ベンチ完走 |
