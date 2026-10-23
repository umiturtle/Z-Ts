# Task M1-05: `zts_bridge` ブラウザ / Live Preview HTTP/1.1 + SSE トランスポート

- **Status**: `done`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `src/bridge/`, `src/bridge_host.zig`, `src/root.zig`, `build.zig`, `zigw`, `tests/bridge/`, `tests/standalone_modules.zig`, `docs/tasks/M1-05-bridge-http-sse.md`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/00-overview.md`, `docs/architecture/web-zig-boundary.md`, `docs/decisions/0003-zig-017-runtime-findings.md`
- **Next Step**: `M1-06`（`zts_webview`: C ABI コア・Headless Mock・Linux WebKit2GTK 4.1 バックエンド）または `M1-07`（`zts_tauri`: ワイヤー互換プロトコル & 基本コマンド群）へ進む。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push（並列エージェントとのスコープ分離確立）
- [x] `src/bridge/auth.zig`: 256-bit 暗号論的乱数（`io.randomSecure`）によるセッション Cookie（`__zts_session` / `HttpOnly; SameSite=Strict`）& 256-bit `Tauri-Invoke-Key` 生成、定数時間比較（タイミング攻撃耐性）、および許可 `Origin` リスト／`Host` 一致（Arena Live Preview 等のプロキシ環境も透過対応）の **三重 CSRF 防御検査（不一致時はボディ読み取り前に即 `403 Forbidden`）**
- [x] `src/bridge/sse.zig`: スレッドセーフなマルチクライアント SSE ブローカー（`/__zts_events__` 購読、WHATWG SSE 準拠の複数行エスケープ・`event: eval` / `event: emit` / `event: window` HTML-safe JSON フレーミング、切断クライアント掃除、グレースフルシャットダウン一斉起床）
- [x] `src/bridge/js_init.zig`: `<head>` へ自動注入される軽量ブリッジ初期化スクリプト（`globalThis.__ZTS_IPC__` および `window.__TAURI_INTERNALS__` の両方をセットアップし、Cookie + `Tauri-Invoke-Key` 付き `POST /__zts_ipc__/<cmd>` 送信・バイナリ `Uint8Array` 自動展開・`EventSource("/__zts_events__?key=...")` リアルタイム受信・`document.title` 同期を提供）
- [x] `src/bridge/server.zig`, `src/bridge/mod.zig` & `src/bridge_host.zig`:
  - ポート `0`（OS エフェメラルポート）および `127.0.0.1` / `0.0.0.0`（Arena Live Preview 等）両対応の `BridgeServer`
  - `GET` / `HEAD` `/*`: `zts_web.Assets` による HTML（初期化スクリプト自動 `<head>` 注入 & 初回 `Set-Cookie` 発行）・JS・CSS・SPA フォールバック・**RFC 9110 `206 Partial Content` / `416` メディア配信**
  - `POST /__zts_ipc__/<cmd>`: パーセントデコード（`plugin%3Awindow%7Cset_title` 等）+ 三重セキュリティ検査 → `zts_rpc.Handler` ディスパッチ（JSON / Raw `application/octet-stream` 両対応、`Tauri-Response: ok|error` ヘッダ付与）
  - 単体切り出し可能な公開モジュール `zts_bridge`（`zts_foundation` + `zts_web` + `zts_rpc` のみ依存、Window/GUI 依存ゼロ）＋ Z-Ts デスクトップ `zts_core.Host` VTable 実装アダプタ `BridgeHost`（`src/bridge_host.zig`）
- [x] 自動結合テスト（`tests/bridge/verify_bridge_e2e.ts`: 実 Node `v22` `fetch` + ストリーミング SSE + 6 パターン CSRF/盗聴攻撃 `403` 遮断 + 注入 `<script>` 本体実行検証 + `tsc --strict` ゼロエラー）& Debug / `ReleaseFast` 全 7 バイナリ `62/62` テスト完全通過 & 3-OS GitHub Actions CI グリーン

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `src/bridge/{auth,sse,js_init,server,mod}.zig`、`src/bridge_host.zig`、`tests/bridge/verify_bridge_e2e.ts` を実装し、公開モジュール `zts_bridge` を `build.zig`・`zigw`・`tests/standalone_modules.zig` に統合。
  - 2-vCPU マシン環境でも長寿命 SSE ストリームや HTTP/1.1 Keep-Alive 接続群が `std.Io.Threaded` ワーカープールを枯渇させない専用 OS スレッド接続アーキテクチャおよび決定論的グレースフルシャットダウン（全ストリーム `shutdown(.both)` + Loopback Wake Connect + OS スレッド `join`）を確立。
  - Debug / `ReleaseFast` 両モードで全 7 独立テストバイナリ `62/62` パスおよび `tsc 7.0.2 --strict` ゼロエラーを確認済み。
