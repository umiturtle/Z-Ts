# Task M1-07: `zts_tauri` Tauri v2 ワイヤー互換プロトコル・`Channel(T)`・標準プラグイン群

- **Status**: `in-progress`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `src/tauri/`, `src/app_runtime.zig`, `src/rpc/{types,codec,tsgen,mod}.zig`, `src/bridge/js_init.zig`, `src/root.zig`, `build.zig`, `tests/tauri/`, `tests/standalone_modules.zig`, `.github/workflows/ci.yml`, `docs/tasks/M1-07-tauri-wire-plugins.md`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/00-overview.md`, `docs/architecture/web-zig-boundary.md`, `docs/decisions/0002-hybrid-architecture-proposal.md`, `docs/decisions/0003-zig-017-runtime-findings.md`
- **Next Step**: `M1-07` 完了および 3-OS GitHub Actions CI（実 `@tauri-apps/api` v2 E2E 含む）オールグリーンを確認し、フェーズ `M1` 全 7 タスク（`M1-01`〜`M1-07`）を完遂する。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push（並列エージェントとのスコープ分離確立）
- [ ] **`src/tauri/js_bootstrap.zig`（本家 `@tauri-apps/api` v2 無修正完動ブートストラップ）**:
  - `window.isTauri = true`、`window.__TAURI_INTERNALS__`（`invoke`, `transformCallback`, `unregisterCallback`, `runCallback`, `callbacks`, `convertFileSrc`, `ipc`, `postMessage`, `metadata.currentWindow` / `currentWebview`, `plugins.path.{sep, delimiter}`）および `window.__TAURI_EVENT_PLUGIN_INTERNALS__.unregisterListener` を生成。
  - `[data-tauri-drag-region]`（`""`, `"true"`, `"deep"`, `"false"`, クリッカブル要素除外、シングルクリック移動 `plugin:window|start_dragging`、ダブルクリック最大化切替 `plugin:window|internal_toggle_maximize`）＆ `-webkit-app-region: drag` イベント委譲を搭載。
  - `src/bridge/js_init.zig` も同期アップデートし、ブラウザ `BridgeServer` 上でも本家 `@tauri-apps/api` v2 が無修正でそのまま動作することを保証。
- [ ] **`src/tauri/channel.zig` (`Channel(T)`)**:
  - `"__CHANNEL__:<id>"` ワイヤー形式の `jsonParse` デコード、`tsgen` 型連携（`{ readonly id: number; toJSON(): string } | string`）、0 始まり連番 `{"index":n,"message":...}` 順序保証ストリーミング送信、および `close()` 時の `{"end":true,"index":n}` 自動 `callbacks` クリーンアップ。
- [ ] **`src/tauri/protocol.zig`（Tauri v2 Custom Protocol & `postMessage` ルーター）**:
  - `tauri://localhost/*`（`zts_web.Assets` HTML 配信・`206 Partial Content` Range 対応）、`asset://localhost/*`（`glob` スコープ検査・パストラバーサル `403` 防御）、`ipc://localhost/<cmd>`（定数時間 `Tauri-Invoke-Key` 検査 + `Origin` 検査 + JSON / Raw Binary ディスパッチ + `Tauri-Response: ok|error`）、および `postMessage` フォールバックを単一モジュールで処理。
- [ ] **標準 `comptime` プラグイン群（`window.zig`, `event.zig`, `path.zig`, `app.zig`, `resources.zig`）**:
  - OS GUI / ソケット依存ゼロの Pure Zig (`link_libc = false`) で `zts_core.Host` VTable 越しに動作し、未使用プラグインは DCE で 0 バイト消去可能。
- [ ] **実 `@tauri-apps/api` v2 パッケージによる E2E 検証 & 3-OS CI オールグリーン**:
  - `HeadlessMock` 単体テスト、Node `BridgeServer` + 本物 `@tauri-apps/api` v2 E2E テスト、および Linux `Xvfb` + 実 WebKit2GTK 4.1 上での本物 `@tauri-apps/api` v2 バンドル E2E テストがリーク 0 バイトで完全通過し、Linux / macOS / Windows 全 3 OS CI がグリーンになること。

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `vendor/tauri` (`v2.12.4`) の `scripts/{core,ipc,ipc-protocol,process-ipc-message-fn}.js`, `src/event/{mod,plugin}.rs`, `src/window/scripts/drag.js`, `packages/api/src/{core,event,window,app,path,dpi,global.d}.ts` を全件照合し、全コマンド名・引数名・ワイヤー形式を確定。
- **次にやること**:
  - `src/rpc/` の `RawJson` / `zts_ts_type` 拡張 → `src/tauri/` 全モジュール実装 → `src/app_runtime.zig` デスクトップ配線 → 実 `@tauri-apps/api` v2 結合テスト & Xvfb WebKit2GTK 4.1 E2E 実装。
