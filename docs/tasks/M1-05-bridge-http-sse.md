# Task M1-05: `zts_bridge` ブラウザ / Live Preview HTTP/1.1 + SSE トランスポート

- **Status**: `in_progress`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `src/bridge/`, `src/root.zig`, `build.zig`, `tests/standalone_modules.zig`, `docs/tasks/M1-05-bridge-http-sse.md`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/00-overview.md`, `docs/architecture/web-zig-boundary.md`, `docs/decisions/0003-zig-017-runtime-findings.md`
- **Next Step**: Zig `0.17.0` `std.Io.net` ベースの HTTP/1.1 + SSE サーバー（256-bit CSPRNG Cookie + `Tauri-Invoke-Key` + `Origin` 三重検証・`206 Partial Content`・リアルタイム SSE 配信・単体切り出し可能モジュール `zts_bridge`）を実装し、実ブラウザ Node E2E + CSRF 拒否テスト + 3-OS CI を通す。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push（並列エージェントとのスコープ分離確立）
- [ ] `src/bridge/auth.zig`: 256-bit 暗号論的乱数によるセッション Cookie（`__zts_session` / `HttpOnly; SameSite=Strict`）& 256-bit `Tauri-Invoke-Key` 生成、定数時間比較（タイミング攻撃耐性）、および許可 `Origin` リスト／ホスト一致の **三重 CSRF 防御検査（不一致時は `403 Forbidden`）**
- [ ] `src/bridge/http.zig`: `std.Io` Reader/Writer ベースの堅牢・ゼロリークな HTTP/1.1 リクエストパーサ & レスポンスライタ（ヘッダサイズ・ボディサイズ上限防御、大文字小文字非依存ヘッダ検索、Cookie パーサ、Keep-Alive / Streaming SSE 対応）
- [ ] `src/bridge/sse.zig`: スレッドセーフなマルチクライアント SSE ブローカー（`/__zts_events__` 購読、`event: eval` / `event: emit` / `event: window` JSON 安全フレーミング、切断クライアント自動掃除、グレースフルシャットダウン一斉起床）
- [ ] `src/bridge/js_init.zig`: `<head>` へ自動注入される軽量ブリッジ初期化スクリプト（`globalThis.__ZTS_IPC__` および `window.__TAURI_INTERNALS__` の両方をセットアップし、Cookie + `Tauri-Invoke-Key` 付き `POST /__zts_ipc__/<cmd>` 送信と `EventSource("/__zts_events__")` リアルタイム受信・`document.title` 同期を提供）
- [ ] `src/bridge/server.zig` & `src/bridge/mod.zig`:
  - ポート `0`（OS エフェメラルポート）および `127.0.0.1` / `0.0.0.0`（Arena Live Preview 等）両対応の `BridgeServer`
  - `GET /...`: `zts_web.Assets` による HTML（初期化スクリプト自動 `<head>` 注入 & 初回 `Set-Cookie` 発行）・JS・CSS・**`206 Partial Content` / `416` メディア配信**
  - `POST /__zts_ipc__/<cmd>`: 三重セキュリティ検査 → `zts_rpc.Handler` ディスパッチ（JSON / Raw `application/octet-stream` 両対応、`Tauri-Response: ok|error` ヘッダ付与）
  - `zts_core.Host` VTable アダプタ同梱（デスクトップ WebView と 1 行のコード変更もなく差し替え可能にしつつ、`zts_bridge` 自体は単体モジュールとしても切り出し可能！）
- [ ] 自動結合テスト & 実 Node `fetch` クライアント E2E 検証 & 3-OS GitHub Actions CI（Linux / macOS / Windows）オールグリーン

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `M1-01`〜`M1-04` および単体切り出しモジュール分割（`zts_foundation`, `zts_web`, `zts_rpc`, `zts_core`）が完了し、3-OS CI オールグリーン確認済み（`703a566`）。
  - `M1-05` タスクファイルを作成しロック取得。
- **作業中・直前の状態**:
  - Zig `0.17.0` の `std.Io.net` / CSPRNG API を実機ヘッダで確認し、`src/bridge/` の実装を開始。
