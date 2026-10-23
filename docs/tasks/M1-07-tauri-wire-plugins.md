# Task M1-07: `zts_tauri` Tauri v2 ワイヤー互換プロトコル・`Channel(T)`・標準プラグイン群

- **Status**: `done`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `src/tauri/{mod,js_bootstrap,channel,resources,app,path,window,event,protocol}.zig`, `src/app_runtime.zig`, `src/rpc/{mod,types,codec,ctx,schema,tsgen}.zig`, `src/bridge/{server,js_init}.zig`, `src/root.zig`, `build.zig`, `zigw`, `scripts/prepare-tauri-e2e.mjs`, `tests/tauri/`, `.github/workflows/ci.yml`, `docs/decisions/0004-tauri-v2-wire-and-deterministic-tsgen.md`
- **Upstream Reference**: [`docs/roadmap/m1-foundation-packages.md`](../roadmap/m1-foundation-packages.md), [`docs/architecture/00-overview.md`](../architecture/00-overview.md), [`docs/architecture/web-zig-boundary.md`](../architecture/web-zig-boundary.md), [`docs/decisions/0002-hybrid-architecture-proposal.md`](../decisions/0002-hybrid-architecture-proposal.md), [`docs/decisions/0004-tauri-v2-wire-and-deterministic-tsgen.md`](../decisions/0004-tauri-v2-wire-and-deterministic-tsgen.md)
- **Next Step**: フェーズ `M1` 全 7 タスク（`M1-01`〜`M1-07`）完了。次フェーズ `M2`（macOS `WKWebView` / Windows `WebView2` バックエンド・Capabilities ACL 統合等）へ着手可能。

---

## 1. 完了した実装内容（Definition of Done 全項目達成）

- [x] **分散ロック宣言コミット & リモート Push** (`25c6eeb`)
- [x] **`src/tauri/js_bootstrap.zig` & `src/bridge/js_init.zig`（本家 `@tauri-apps/api` v2 無修正完動ブートストラップ）**:
  - `window.isTauri = true`、`window.__TAURI_INTERNALS__`（`invoke`, `transformCallback`, `unregisterCallback`, `runCallback`, `callbacks`, `convertFileSrc`, `ipc`, `postMessage`, `metadata.currentWindow` / `currentWebview`, `plugins.path.{sep, delimiter}`）および `window.__TAURI_EVENT_PLUGIN_INTERNALS__.unregisterListener` を出力。
  - `plugin:event|listen` 解決時に `eventId -> handlerId` を同期登録し、`once()` / `unlisten()` 時のインフライト競合条件（Race Condition）を物理的にゼロ化。
  - `[data-tauri-drag-region]`（`""`, `"true"`, `"deep"`, `"false"`, インタラクティブ要素 `<button>` 等除外、シングルクリック `plugin:window|start_dragging`、ダブルクリック `plugin:window|internal_toggle_maximize`）＆ `-webkit-app-region: drag` イベント委譲を完備。
- [x] **`src/tauri/channel.zig` (`Channel(T)`)**:
  - `"__CHANNEL__:<id>"` ワイヤー形式のゼロヒープ確保デコード（`decodeZtsJson`）、`tsgen` 共変型出力（`{ readonly id: number; readonly onmessage: (response: T) => void; toJSON(): string }`）、HTML 安全 JSON シリアライズによる 0 始まり連番 `{"index":n,"message":...}` ストリーミング送信、およびスタックバッファ 0 アロケーション `close()`（`{"end":true,"index":n}`）を実装。
- [x] **`src/tauri/protocol.zig`（Tauri v2 Custom Protocol & `postMessage` ルーター）**:
  - `tauri://` / `http://tauri.localhost`（`zts_web.Assets` SPA 配信 + `206 Partial Content` / `416` Range 対応 + `CSP` 付与）、`asset://` / `http://asset.localhost`（`asset_root_dir` 解決 + `glob` スコープ検査 + `..` / NUL バイト `403` 防御 + `206` Range 対応）、`ipc://` / `http://ipc.localhost`（定数時間 `Tauri-Invoke-Key` 検証 + `Origin` 検証 + パーセントデコード + JSON / `application/octet-stream` ディスパッチ + `Tauri-Response: ok|error`）、および `postMessage` フォールバックを Pure Zig (`link_libc = false`) で実装。
- [x] **標準 `comptime` プラグイン群（`window.zig`, `event.zig`, `path.zig`, `app.zig`, `resources.zig`） & `DesktopRuntime` (`src/app_runtime.zig`)**:
  - `CorePluginsSchema`（`.tauri_window`, `.tauri_event`, `.tauri_path`, `.tauri_app`, `.tauri_resources` — ユーザー側 `.app` 等と衝突しない名前空間設計）および `withCorePlugins(...)` 1 行マージを提供。
- [x] **実 `@tauri-apps/api` v2 パッケージ（無修正 npm パッケージ）による 3 重 E2E 実証 (`tests/tauri/`)**:
  1. `DemoOnlySchema.ts_bindings` バイト単位完全一致スナップショット検証 + `tsc --noEmit` (`strict: true`)
  2. 全 3 OS（Linux / macOS / Windows）Live `BridgeServer` + `BridgeHost` + Node 22 HTTP/Cookie/SSE E2E スイート完走
  3. Linux `Xvfb` + 実物 `WebKit2GTK 4.1` `DesktopRuntime(.native)`（`tauri://`, `ipc://`, `asset://` `206`/`403`, `[data-tauri-drag-region]` マウス委譲）フル E2E スイート完走（Debug / `ReleaseFast` 双方 0 リーク）
