# Z-Ts ロードマップ・並列マイルストーン構成（雛形）

> **重要**: 並列エージェント間のマージコンフリクトを防ぐため、**このファイルの本文を進捗のたびに書き換えないでください。**
> 各タスクの実際の着手・完了ステータスは **`docs/tasks/<ID>-<slug>.md` の `Status` フィールド** が唯一の真実の源泉（Single Source of Truth）であり、`bash scripts/status.sh` で自動集計されます。

---

## マイルストーンと並列実行グラフ

同じフェーズ内のモジュールは疎結合になるよう分割されており、**複数のエージェントが別ブランチで同時に並列実装可能**です：

```text
[M0: 基盤・CI・ツールチェーン整備] (完了: M0-01)
          │
          ├───► [M1-A: Config & Assets]   (tauri.conf.json パーサ・Embedded Assets・MIME)
          ├───► [M1-B: Comptime IPC Core] (JSON 引数展開・State 注入・Invoke Router・Event PubSub)
          ├───► [M1-C: Security & ACL]    (Capabilities / Permissions / Scope グロブ評価・Origin 検査)
          └───► [M1-D: Runtime & Linux]   (L3 Runtime 抽象 + MockRuntime + Linux GTK3 Window / WebKit2GTK 4.1)
                         │
                         ▼
          [M2: Vertical Slice 統合] ("Hello Z-Ts" 実ウィンドウ + JS ⇔ Zig 双方向 Comptime IPC E2E on Xvfb CI)
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   [M3-A: macOS]  [M3-B: Windows] [M3-C: Plugin / Tray / Menu / Dialog]
   (Cocoa+WKWeb)  (Win32+WebView2)
          └──────────────┼──────────────┘
                         ▼
          [M4: CLI / Dev Server / Bundler & ベンチマーク比較（vs 本家 Rust Tauri）]
```
