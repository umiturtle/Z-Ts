# Z-Ts アーキテクチャ全体概要（Composable Zig Packages 設計）

> **本書は `Z-Ts` のパッケージ分割境界・依存 DAG・設計原則を定義するマスター設計書です。**
> **最大の特徴は、Tauri（Rust）のような「すべてを抱え込む単一の巨大 `App` フレームワーク」ではなく、それぞれが単体でも 100% 価値を持ち独立して `@import` / C ABI リンクできる「6 つの直交 Zig パッケージ」で構成されている点です。**

---

## 1. パッケージ依存 DAG（単方向・直交・Pay-for-what-you-use）

下位パッケージは上位パッケージの存在を一切知らず（逆方向 `@import` 厳禁）、不要なパッケージはコンパイルもリンクもされません。

```text
                      ┌───────────────────────────────────────────┐
                      │  ⑥ `zts` (`src/root.zig`)                 │
                      │  薄い統合ファサード（約150行の再公開層）  │
                      └──────────┬───────────────────────┬────────┘
                                 │                       │
             ┌───────────────────▼──────────┐   ┌────────▼──────────────────┐
             │ ⑤ `zts_tauri` (`src/tauri/`) │   │ ④ `zts_bridge`            │
             │  Tauri v2 互換プロトコル &   │   │    (`src/bridge/`)        │
             │  Comptime 標準コマンド群     │   │  Pure Zig HTTP + SSE      │
             │  ・`window.__TAURI_INTERNALS`│   │  ブラウザ / Live Preview  │
             │  ・`window`/`event`/`dialog` │   │  Playwright E2E 実行基盤  │
             │  ・`tauri.conf` / ACL 読込   │   │  (本番ネイティブでは0B)   │
             └──────────┬───────────────────┴───┴────────┬──────────────────┘
                        │                                │
      ┌─────────────────▼────────────────┐ ┌─────────────▼──────────────────┐
      │ ② `zts_rpc` (`src/rpc/`)         │ │ ③ `zts_webview`                │
      │  Pure Zig Comptime RPC & TS 型生成│ │    (`src/webview/`)            │
      │  ・`codec`: camelCase JSON &     │ │  極薄 C ABI OS Window/WebView  │
      │    `.alloc_if_needed` ゼロコピー │ │  ・`step()` (`poll` / `wait`)  │
      │  ・`router`: Comptime 静的合成   │ │  ・Custom URI Scheme 非同期応答│
      │  ・`ErrorSet` → TS Union 自動生成│ │  ・Linux / macOS / Win32       │
      │  ※GUI/WebView 依存ゼロ！単体で   │ │  ※JSON/RPC/Tauri 依存ゼロ！   │
      │    HTTP/WS/CLI デーモンでも利用可│ │    単体 C/Zig/ゲーム組込可能！ │
      └─────────────────┬────────────────┘ └─────────────┬──────────────────┘
                        └───────────────┬────────────────┘
                                        ▼
                      ┌──────────────────────────────────┐
                      │ ① `zts_core` (`src/core/`)       │
                      │  Zero-Dep Pure Zig データ構造群  │
                      │  ・`HandlePool(T)` (53-bit 世代) │
                      │  ・`OwnedBytes` (完了通知解放)   │
                      │  ・MPSC Queue / URL / Glob / CSP │
                      │  ※libc 不要・OS I/O 一切なし！  │
                      └──────────────────────────────────┘
```

---

## 2. 各パッケージの責務境界と単体ユースケース

| パッケージ (`build.zig` 公開名) | ディレクトリ | 依存先 | 単体で誰がどう使えるか / テスト特性 |
|---|---|---|---|
| **① `zts_core`** | `src/core/` | `std` のみ (`link_libc = false`) | 53-bit 世代番号付き `HandlePool(T)`、非同期返却バッファ `OwnedBytes`、Glob/URL/CSP パーサ。**OS 非依存・0.01s 単体テスト**。 |
| **② `zts_rpc`** | `src/rpc/` | `zts_core` (`link_libc = false`) | **WebView を使わない普通の Zig HTTP/WebSocket サーバーや CLI デーモンでもそのまま使える**、マクロ不要の `comptime` JSON-RPC ルーター ＋ TypeScript クライアント/エラー型自動生成器。 |
| **③ `zts_webview`** | `src/webview/` + `include/zts_webview.h` | OS API のみ（Tauri/JSON 依存ゼロ） | **C / Python / Bun / ゲームエンジン（SDL/GLFW 親ウィンドウ埋め込み）からも単体で使える**、Custom URI Scheme 対応・`poll`/`wait` ステップ駆動型の極薄 WebView ライブラリ。 |
| **④ `zts_bridge`** | `src/bridge/` | `std.Io.net`, `zts_core` | GUI 環境のないサーバー・Docker・Arena Live Preview・Playwright E2E テスト用のセキュア HTTP + SSE トランスポート。本番ネイティブアプリからは未 import により完全除去（0 バイト）。 |
| **⑤ `zts_tauri`** | `src/tauri/` | `zts_core`, `zts_rpc` (+ 任意の Backend) | Tauri v2 ワイヤー互換層（`__TAURI_INTERNALS__`, `Tauri-Invoke-Key`, `Channel`）と、必要なものだけ `comptime` 合成できる標準コマンドモジュール（`window`, `event`, `path`, `fs`, `dialog` 等）。 |
| **⑥ `zts`** | `src/root.zig` | 上記を統合再公開 | 数十行でフル機能のデスクトップアプリを構築するための統合モジュール。 |

---

## 3. マルチエージェント並列開発ルール（コンフリクトゼロ保証）

1. **各パッケージは独自の `src/<pkg>/mod.zig` と単体テストを持ち、互いに完全に独立して並列実装できる**：
   - Agent A: `src/core/`
   - Agent B: `src/rpc/`
   - Agent C: `src/webview/`（さらに `linux.zig`, `macos.m`, `windows.zig` で OS ごとにも完全分離）
   - Agent D: `src/bridge/`
   - Agent E: `src/tauri/`（さらに `cmds/window.zig`, `cmds/dialog.zig`, `cmds/fs.zig` で完全分離）
2. **Rust 由来のアンチパターン持ち込み禁止**:
   - ❌ 動的 `PluginStore` VTable への全プラグイン一括登録（未使用コードが DCE されずバイナリが肥大化するため禁止 → **`zts_rpc.merge` による `comptime` 静的合成** を使う）
   - ❌ 世代番号なしの連番 `ResourceId: u32` と `Any` ダウンキャストマップ（ABA バグの温床になるため禁止 → **`zts_core.HandlePool(T)`（IEEE 754 安全な 53-bit 世代ハンドル）** を使う）
   - ❌ メインスレッドを乗っ取って戻らない `run()` 強制（`defer` リーク検査と外部ゲームループ統合を壊すため禁止 → **`step(.blocking / .non_blocking)` を基礎プリミティブ** にする）
