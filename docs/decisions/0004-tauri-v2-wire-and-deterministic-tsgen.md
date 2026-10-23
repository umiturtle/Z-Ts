# ADR 0004: `zts_tauri` ワイヤー互換レイヤー設計と決定論的 TypeScript 型生成

- **日付**: 2026-10-23
- **ステータス**: 承認・実装済み（`M1-07`）
- **関連モジュール**: `zts_tauri`, `zts_rpc`, `zts_bridge`, `src/app_runtime.zig`

---

## 1. 背景と課題

Z-Ts は以下の 2 つの一見相反する要件を同時に満たす必要がある：

1. **既存 Tauri v2 フロントエンド資産との完全ドロップイン互換**:
   npm で公開されている本家 `@tauri-apps/api` v2（`core`, `window`, `dpi`, `event`, `path`, `app`）を **1 行のパッチも当てずに無修正のまま** バンドルして動作させること。
2. **マルチプロダクト単体抽出可能性（ゲームエンジン・配信ツール等）**:
   将来切り出されるビジュアルノベルエンジンや OBS 系ツールが、OS GUI や Tauri 層を引きずらず必要なパッケージだけを選択リンクでき、かつ未使用の Tauri コアプラグインが Dead Code Elimination でバイナリから完全に消去されること。

---

## 2. アーキテクチャ決定事項

### 2.1 `zts_tauri` の完全 Pure Zig 分離 (`link_libc = false`)
- `zts_tauri` は **`zts_foundation`, `zts_web`, `zts_core`, `zts_rpc` のみ** に依存し、`zts_webview`（GTK/WebKit/Cocoa/WebView2）にも `zts_bridge`（TCP/HTTP ソケット）にも一切依存しない。
- これにより、全く同じ `CorePluginsSchema` + アプリケーション `Schema` が：
  - デスクトップ本番では `DesktopRuntime`（`WebviewHost` + `tauri://` / `ipc://` / `asset://`）上で動作し、
  - クラウド開発環境（Arena Live Preview 等）やヘッドレス E2E では `BridgeServer` + `BridgeHost`（HTTP/1.1 + Cookie + SSE）上で **1 行のコード変更もなく同一動作** する。

### 2.2 名前空間衝突ゼロの `withCorePlugins` 合成
- ユーザーのアプリケーション側が `.app = AppCommands` や `.window = WindowExt` といった自然な名前空間キーを使っても衝突しないよう、`CorePluginsSchema` 側の束縛キーは `.tauri_window`, `.tauri_event`, `.tauri_path`, `.tauri_app`, `.tauri_resources` とし、ワイヤー上のコマンドプレフィックスのみ `pub const rpc_prefix = "plugin:window|"` 等で制御する。
- `zts_rpc.merge` を拡張し、名前空間構造体リテラル（`.{ .a = A, .b = B }`）と既存 `Schema` 型のタプル（`.{ AppSchema, CorePluginsSchema }`）の双方を `comptime` で単一の静的ディスパッチテーブルへ平坦化できるようにした（大規模スキーマ向けに `@setEvalBranchQuota(200_000)` を設定）。

### 2.3 `@tauri-apps/api/event` の非同期 `once()` / `unlisten()` 競合根絶
- 本家 `@tauri-apps/api/event` の `once()` は初回イベント受信時に `void _unlisten(event, eventData.id)` を `await` せずに発火する。
- そのため `plugin:event|listen` の解決時点でフロントエンド側 `eventRegistry` に `eventId -> handlerId` を同期記録し、`unregisterListener(event, eventId)` 呼び出しと同一ティック内で `callbacks.delete(handlerId)` を完了させることで、パイプライン飛行中の後続イベントによる二重発火レースを 100% 排除した。

### 2.4 `zts_rpc.tsgen` における `ErrorSet` の辞書順ソート（決定論的コード生成）
- Zig `0.17.0` では `@typeInfo(ErrorSet).error_set.error_names` の列挙順が **翻訳単位ごとのグローバルエラーテーブル登録順（import 順）に依存して変動する** ことがスナップショット E2E 検証で判明した。
- `tsgen.zig` の `renderErrorSetTsType` にて `comptime` 辞書順ソートを導入し、どのターゲット・どの翻訳単位から生成しても **100% バイト単位で再現可能な TypeScript 型定義** が出力されることを保証した。

### 2.5 実機 WebKit2GTK 4.1 E2E で検証・解決した C/GObject 境界知見
1. **`webkit_uri_scheme_response_set_http_headers` 時の `Content-Type` ヘッダ明示付与**:
   - WebKit2GTK 4.1 では `webkit_uri_scheme_response_set_http_headers(resp, soup_hdrs)` を使用すると、JS `fetch()` の `res.headers.get("content-type")` は `soup_hdrs` テーブルを参照する。`soup_hdrs` に `"Content-Type"` を明示 `soup_message_headers_append` しないと `res.headers.get("content-type")` が空になり、Tauri v2 `ipc-protocol.js` が全レスポンスを `res.arrayBuffer()` 分岐で処理してしまうため、`soup_hdrs` 側にも必ず `Content-Type` を格納する。
2. **GObject 同期 `"destroy"` シグナルと RAII 逆順破棄 (`DesktopRuntime.destroy`)**:
   - `gtk_widget_destroy(toplevel)` は呼び出しスレッド上で同期的に `"destroy"` シグナルを発火する。`DesktopRuntime.destroy` では必ず先に `setCloseHandler(null)` / `setMessageHandler(null)` でコールバックを切り離し、`engine.deinit()` 完了後に `plugins.destroy()` を解放する。
