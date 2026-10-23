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

## 2. 各パッケージの責務境界と単体切り出し不変条件（CI 強制）

Z-Ts の下位レイヤは、デスクトップ WebView フレームワーク以外の別プロダクト（外部エンジン・メディア/配信ツール・サーバー等）からも `b.dependency("z_ts", .{}).module("<name>")`（またはディレクトリ単位の切り出し）で単体利用できるよう、**各 `.zig` ソースファイルが厳密に単一モジュールにのみ所属する排他 DAG** を構成します。

| `build.zig` 公開モジュール名 | 専属ファイル範囲 | 依存先 | 単体で提供する責務（上位レイヤへの逆依存厳禁） |
|---|---|---|---|
| **`zts_foundation`** | `src/core/{foundation,owned_bytes,response,handle_pool,queue,geometry,url,glob,html_escape}.zig` | `std` のみ (`link_libc = false`) | Window/WebView/HTTP 非依存の純粋汎用ランタイム基盤（`OwnedBytes`, `OutgoingResponse`, 53-bit 世代 `HandlePool`, `RingQueue`, `geometry`, `url`, `glob`）。 |
| **`zts_web`** | `src/core/{web,assets,http_range,mime,csp}.zig` | `zts_foundation` (`link_libc = false`) | 静的/動的アセット解決、RFC 9110 `206 Partial Content` バイトレンジシーク配信、MIME 判定、CSP 生成（Window/RPC 非依存）。 |
| **`zts_rpc`** | `src/rpc/*.zig` | `zts_foundation` のみ (`link_libc = false`) | **Window/WebView/Tauri 依存ゼロ**の汎用 `comptime` JSON/Binary RPC ルーター（`Schema`/`bind`）、ゼロ確保エラー応答、型安全環境注入 `Ctx.withEnv(&T)` / `requireEnv(T)`、トランスポート中立 `tsgen`（`createIpcTransport` / `createFetchTransport`）。 |
| **`zts_core`** | `src/core/{mod,host}.zig` | `zts_foundation`, `zts_web` (`link_libc = false`) | デスクトップフレームワーク共通コア（プラットフォーム非依存 Window `Host` VTable・`CallContext`・`RecordingHost` + 下位再公開）。 |
| **`zts_webview`** | `src/webview/{mod,types,pending,mock,gtk_bindings,linux,c_api}.zig` + `include/zts_webview.h` | `zts_foundation` (+ OS GUI APIs; JSON/RPC/Tauri 依存ゼロ) | C99 ABI（`libzts_webview_static.a`）でも単体組み込み可能な Custom URI Scheme 非同期ゼロコピー応答・子ウィジェット埋め込み・`step(.blocking / .poll)` 駆動型の極薄 WebView エンジン + `HeadlessMock`。 |
| **`zts_bridge`** | `src/bridge/{mod,auth,sse,js_init,server}.zig` | `zts_foundation`, `zts_web`, `zts_rpc` (`link_libc = false`) | **Window/GUI 依存ゼロ**の組み込み HTTP/1.1 + `206` Range + 三重 CSRF 防御 RPC + リアルタイム SSE サーバー（Live Preview・Playwright E2E・外部配信ツール/エンジン制御 UI で単体利用可能。未使用時は 0B）。 |
| **`zts_tauri`** | `src/tauri/` | `zts_core`, `zts_rpc` (`link_libc = false`) | Tauri v2 ワイヤー互換層および `comptime` 選択可能な標準プラグイン群。 |
| **`zts_wasm`** | `src/wasm/{mod,io_stub,host,runtime,js_bootstrap}.zig` | `zts_foundation`, `zts_web`, `zts_core`, `zts_rpc`, `zts_tauri` (`link_libc = false`) | `wasm32-freestanding` 向け `WasmHost`・`WasmApp` エクスポート ABI・WebAssembly インメモリ IPC ブートストラップ生成。 |
| **`zts_ssg`** | `src/ssg/{mod,manifest_gen,exporter,embed_dir_main}.zig` | `zts_foundation`, `zts_web`, `zts_wasm` (`link_libc = false`) | フロントエンド SSG ディレクトリ（`out/`・`dist/`）の決定論的 `@embedFile` マニフェスト生成、ルート別プリレンダリング、およびサーバー不要静的サイト（`dist/` + `.wasm` + `.nojekyll` + `_headers`）エクスポータ。 |
| **`z_ts`** | `src/{root,bridge_host,webview_host,app_runtime}.zig` | 上記を統合再公開 | デスクトップ & Web ハイブリッド統合 SDK（`BridgeHost`, `WebviewHost`, `WasmHost`, `DesktopRuntime`, `ssg` を再公開）。 |

> **CI 自動強制ガード (`tests/standalone_modules.zig` & `tests/webview/verify_c_abi.c`)**: `zig build test` は `z_ts`・`zts_core` を一切インポートしない独立コンパイルターゲットで `zts_foundation`・`zts_web`・`zts_rpc`・`zts_bridge`・`zts_webview` をビルド・実行し、さらに厳格 `-std=c99 -Wall -Wextra -Werror` の C ホストバイナリとの静的リンク実行を強制検証します。

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
