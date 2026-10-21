# Z-Ts ロードマップ・並列マイルストーン構成

> **重要**: 並列エージェント間のマージコンフリクトを防ぐため、**このファイルの本文を進捗のたびに書き換えないでください。**
> 各タスクの実際の着手・完了ステータスは **`docs/tasks/<ID>-<slug>.md` の `Status` フィールド** が唯一の真実の源泉（Single Source of Truth）であり、`bash scripts/status.sh` で自動集計されます。

---

## マイルストーンと並列実行グラフ（6 パッケージ直交構成）

同じフェーズ内のパッケージは完全に独立したディレクトリに分かれており、**複数のエージェントが別ブランチでコンフリクトゼロで並列実装可能**です（アーキテクチャ詳細は [`../architecture/00-overview.md`](../architecture/00-overview.md) および [`../architecture/web-zig-boundary.md`](../architecture/web-zig-boundary.md) 参照）：

```text
[M0: 基盤・CI・ツールチェーン・設計監査] (完了: M0-01, ADR-0001, ADR-0002)
          │
          ▼
[M1-01: `src/core/` (`zts_core`)]  ── 最下層契約の確定（先行・極小）
  (u53 HandlePool, OwnedBytes, Host VTable, MPSC Queue, URL/Glob/CSP/MIME, 206 Range Assets)
          │
          ├───► [M1-02: `src/rpc/` (`zts_rpc`)]
          │       (codec, Patch(T)/BigInt/OsPath, Schema/bind, ErrorSet→TS `tsgen` + `tsc --noEmit` 検証)
          │
          ├───► [M1-03: `src/bridge/` (`zts_bridge`)]
          │       (`std.Io.net` セキュア HTTP+SSE ブリッジ — ブラウザ & Arena Live Preview 即時動作)
          │
          ├───► [M1-04: `src/webview/` (`zts_webview` — Core C ABI + Linux)]
          │       (`zts_webview.h` 相当 VTable, Headless Mock, `step()`, GTK3 + WebKit2GTK 4.1 非同期応答)
          │
          └───► [M1-05: `src/tauri/` (`zts_tauri` — Wire Protocol & Built-in Commands)]
                  (`__TAURI_INTERNALS__` JS, `Channel`, `window`/`event`/`path`/`app` コマンドモジュール)
                         │
                         ▼
[M2: Vertical Slice E2E 統合]
  (実 `@tauri-apps/api` + 自動生成 `bindings.gen.ts` フロントエンドが
   ① Mock (0.01s) / ② Live Preview Bridge / ③ Linux Xvfb 実 WebView の全 3 モードで完全動作)
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   [M3-A: macOS]  [M3-B: Windows] [M3-C: Extended Commands & Optional ACL]
   (ObjC WKWebView) (Win32+WebView2  (`dialog`, `fs`, `clipboard`, `menu`, `tray`,
    on Actions CI)   Direct Loader)    `tauri.conf.json` / `capabilities` インポータ)
          └──────────────┼──────────────┘
                         ▼
[M4: `zts` CLI (`init` / `dev` / `build` / `tsgen`)・`embedFrontend`・Cross-Bundler & ベンチマーク比較]
```
