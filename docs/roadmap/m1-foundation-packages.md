# M1 詳細ロードマップ：コア 5 パッケージの構築（`M1-01` 〜 `M1-07`）

このドキュメントは、フェーズ M1（Wave 1 & Wave 2）の各タスクについて、**作成するファイル・公開インターフェース・エッジケース要件・完了定義（DoD）** を定めます。

---

## Wave 1：最下層 Pure Zig コア & 型コーデック（完全並列実行可能）

### `M1-01`：`zts_core` 基盤型・世代ハンドル・スレッド間キュー・Host 契約
- **専有スコープ**: `src/core/{mod,handle_pool,owned_bytes,queue,geometry,host}.zig`
- **外部依存**: `std` のみ（`link_libc = false`、OS I/O なし）
- **実装項目**:
  1. **`HandlePool(comptime T: type, comptime Tag: @EnumLiteral)`**:
     - ハンドル表現は JS `MAX_SAFE_INTEGER (2^53 - 1)` 内に完全収まる `packed struct(u53) { index: u24, generation: u29 }`（JSON/FFI 変換用の `toU53() / fromU53()` 付き）。
     - フリーリストによる `O(1)` `acquire` / `release` / `get` / `getPtr`。解放時に世代をインクリメントし、古いハンドルによる ABA アクセスを `null` / `error.StaleHandle` で 100% 検出。
  2. **`OwnedBytes`**:
     - `bytes: []const u8`, `ctx: ?*anyopaque`, `release_fn: ?*const fn (?*anyopaque, []const u8) void`。
     - WebKit `GDestroyNotify` や HTTP 送信完了後など「別スレッド・遅延解放」をゼロコピーかつ Use-After-Free ゼロで扱う共通バッファ型（静的リテラル `OwnedBytes.static("...")` と `Allocator` 確保 `OwnedBytes.fromOwnedSlice(...)` の両方に対応）。
  3. **`MpscQueue` / タスク起床キュー**:
     - `std.Io.Mutex` で保護されたリングバッファ。ワーカースレッド群からメイン GUI スレッドへ UI 操作コマンド・IPC 完了通知を送る。
  4. **`geometry.zig`（座標・色空間の型安全分離）**:
     - `LogicalPx` / `PhysicalPx`（別 `struct` 型として定義し暗黙混同をコンパイルエラー化）、`LogicalSize`, `LogicalRect`, `Color`（Straight RGBA `u8x4` + Premultiplied BGRA 変換ヘルパー）。
  5. **`host.zig`（OS 非依存 `Host` VTable 型定義）**:
     - `WindowId`、ウィンドウ制御（`setTitle`, `setSize`, `setPosition`, `setFullscreen`, `minimize`, `maximize`, `close`, `startDrag`）、WebView 制御（`evalJs`, `emitEvent`, `completeIpcRequest`）、イベントループ起床 `wakeup` の関数ポインタテーブル定義。
- **完了条件 (DoD)**:
  - `std.testing.allocator` で確保・解放・世代ラップアラウンド・ABA 拒否・マルチスレッド並列 push/pop ストレステストがリーク 0 バイトで通過すること。

---

### `M1-02`：`zts_core` Web アセット・HTTP Range・CSP・URL/Glob 基盤
- **専有スコープ**: `src/core/{assets,mime,http_range,csp,html_escape,glob,url}.zig`
- **外部依存**: `std` のみ（`link_libc = false`）
- **実装項目**:
  1. **`mime.zig`**: ES Modules (`.js`/`.mjs` → `text/javascript; charset=utf-8`), `.css`, `.html`, `.wasm` (`application/wasm`), `.svg` (`image/svg+xml`), `.json`, 画像/音声/動画/WebFont の拡張子＆マジックバイト判定。
  2. **`http_range.zig` & `assets.zig`**:
     - 静的埋め込みマップおよびディレクトリソース抽象。
     - **SPA ルーティング対応**: 拡張子なしパス不在時に `/index.html` を返すオプション。
     - **RFC 9110 `Range: bytes=start-end` パーサ & `206 Partial Content` 応答ビルダ**（`<video>`/`<audio>` 再生必須要件）。
  3. **`html_escape.zig` & `csp.zig`**:
     - JSON 文字列内の `<` (`\u003c`), `>` (`\u003e`), `&` (`\u0026`), U+2028/U+2029 をエスケープし `</script>` XSS を 100% 防ぐシリアライザラッパー。
     - HTML `<head>` への初期化 `<script>` 注入、CSP Nonce 置換 & SHA-256 ハッシュ計算。
  4. **`url.zig` & `glob.zig`**:
     - Origin 抽出・比較（`tauri://localhost`, `http://ipc.localhost`, リモート URL パターン）。
     - Capabilities スコープ用の高速 Glob マッチャ（`*`, `**`, `?`, パス境界安全検査）。
- **完了条件 (DoD)**:
  - `</script>` 注入ベクタ、不正 Range ヘッダ、SPA ネストパス、Glob パストラバーサル攻撃（`../`）の全単体テスト通過。

---

### `M1-03`：`zts_rpc` 型システム & Web⇔Zig 境界 JSON コーデック
- **専有スコープ**: `src/rpc/{types,codec,naming}.zig`
- **外部依存**: `std`（および `Handle` 連携のみ）
- **実装項目**:
  1. **`naming.zig`**: `comptime` `snake_case` → `camelCase` 変換。ただしハイフンを含む `@"aria-label"` / `@"data-id"` / `@"--bg"` は無変換で保持。
  2. **`types.zig`（Web 境界専用ラッパー型群）**:
     - `BigInt(T)`（`i64`/`u64`/`i128` ⇔ JSON 文字列 `"..."` ⇔ TS `bigint`）
     - `Bytes`（生バイナリ `[]const u8` ⇔ TS `Uint8Array`）
     - `OsPath`（UTF-8 表示名 + 非 UTF-8 / WTF-8 生バイト往復トークン）
     - `Patch(T)`（`union(enum) { unchanged, null, value: T }` — `undefined` と `null` の 3 状態完全識別）
  3. **`codec.zig`（単一ソース `comptime` エンコーダ / デコーダ）**:
     - 素の `i64`/`u64`/`usize` 使用時に `@compileError` を出し `i53`/`u53` または `BigInt` へ誘導。
     - 文字列デコードは `.allocate = .alloc_if_needed` で非エスケープ入力のゼロコピー借用を実現。
     - `f32`/`f64` の `isFinite` 検査（`NaN`/`Inf` 混入防止）。
     - `union(enum)` の 4 表現モード（デフォルト `.internal` = `{ kind: "tag", ... }`, `.adjacent`, `.external`, `.untagged`）。
- **完了条件 (DoD)**:
  - [`docs/architecture/web-zig-boundary.md`](../architecture/web-zig-boundary.md) の全 10 境界ケース（片割れサロゲート、非 UTF-8 パス往復、`Patch(T)` 3 状態、53-bit 境界、`NaN` 拒否、Discriminated Union）のラウンドトリップ単体テスト通過。

---

## Wave 2：RPC ルーター/TS 型生成・トランスポート・OS WebView・Tauri 層（4 並列）

### `M1-04`：`zts_rpc` `Schema`/`bind` ルーター合成 & `tsgen`（実 `tsc` 検証付き）
- **専有スコープ**: `src/rpc/{mod,ctx,schema,tsgen}.zig`, `tests/tsgen/`
- **依存**: `M1-01`, `M1-03`
- **実装項目**:
  1. **`Ctx`**: `io: std.Io`, `scratch: Allocator`（再利用 Arena）, `host: Host`, `window_id: WindowId`, `origin: []const u8`。
  2. **`Schema(.{ ... })` & `bind(.{ ... })`**:
     - 複数の名前空間（例：`""`, `"plugin:window|"`）の `Commands` 構造体を `comptime` で単一の静的ディスパッチテーブルへ合成。
     - `bind` で実行時の State ポインタ群を束縛し、具体型 `Handler`（`userdata + vtable`）へ型消去。
     - 戻り値 `ErrorSet!T` のエラー発生時はヒープ確保 0 バイトで `{"code":"<ErrorName>"}` を返却。
  3. **`tsgen.zig`**:
     - `Schema.ts_bindings` として `comptime` 文字列（または Writer 出力）で TypeScript クライアントを生成。
     - **JS/TS 全予約語エスケープ**、**`erasableSyntaxOnly` 完全準拠**（TS `enum` 不使用）、**`ErrorSet` → Union 型出力**、**`Handle` → Branded Type 出力**。
- **完了条件 (DoD)**:
  - 複雑なコマンドセットから生成した `bindings.gen.ts` に対し、テスト内で実際に TypeScript コンパイラ（`tsc --noEmit --strict --exactOptionalPropertyTypes --erasableSyntaxOnly`）を実行して **警告・エラー 0 件** を自動検証すること。

---

### `M1-05`：`zts_bridge` ブラウザ / Live Preview トランスポート
- **専有スコープ**: `src/bridge/`
- **依存**: `M1-01`, `M1-02`
- **実装項目**:
  - `std.Io.net` ベースの組み込み HTTP/1.1 + SSE（Server-Sent Events）サーバー。
  - `GET /...`: `zts_core.Assets` から HTML（ブリッジ用 init script 自動先頭注入済み）・JS・CSS・`206` メディアを配信し、初回応答で 256-bit 乱数 `HttpOnly; SameSite=Strict` セッション Cookie を発行。
  - `POST /__zts_ipc__/<cmd>`: **Cookie + `Tauri-Invoke-Key` ヘッダ + `Origin` 一致の三重検査** を通過したリクエストのみ `Handler` へディスパッチし、JSON または `application/octet-stream` と `Tauri-Response: ok|error` ヘッダを返却。
  - `GET /__zts_events__`: `eval` や `emit` イベントをブラウザ側へリアルタイム push する SSE ストリーム。
- **完了条件 (DoD)**:
  - ポート `0`（エフェメラルポート）で起動し、正当クライアントからの JSON/Raw IPC・SSE 受信成功、および Cookie 欠落・別 `Origin` からの CSRF 攻撃リクエストが `403 Forbidden` で 100% 拒否される自動結合テスト通過。

---

### `M1-06`：`zts_webview` C ABI コア・Headless Mock・Linux WebKit2GTK バックエンド
- **専有スコープ**: `src/webview/{mod,c_api,mock,linux}.zig`, `include/zts_webview.h`
- **依存**: `M1-01`, `M1-02`
- **実装項目**:
  1. **`include/zts_webview.h` & `c_api.zig`**: C / 他言語からも単体利用できる約 25 関数のクリーンな C ABI 定義。
  2. **イベントループ制御**: `step(.blocking)` / `step(.poll)` / スレッドセーフ `wakeup`（`g_main_context_invoke`）。
  3. **`PendingRequest` メインスレッド隔離テーブル**: `HandlePool` を用い、OS の生リクエストポインタを一切ワーカースレッドへ渡さない安全設計。
  4. **`mock.zig`**: ウィンドウを開かずメモリ上で WebView 操作・カスタムスキーム・JS 評価ログを検証できる `HeadlessMock` バックエンド。
  5. **`linux.zig` (`GTK3 + WebKit2GTK 4.1`)**:
     - Pure Zig `extern "c"` バインディング（`@cImport` / `addTranslateC` 不使用、コールドビルド <5 秒維持）。
     - `ipc://`, `asset://`, `tauri://` カスタムスキーム登録、**大容量 POST でもデッドロックしない `g_input_stream_read_all_async` 非同期ボディ読み取り**、`OwnedBytes` の `GDestroyNotify` 非同期解放連携。
- **完了条件 (DoD)**:
  - ローカル `HeadlessMock` 単体テスト通過 ＋ GitHub Actions `ci-linux`（`xvfb-run`）上で実 GTK3 ウィンドウ生成・HTML 描画・`ipc://` 双方向バイナリ & JSON 往復・クリーン終了（リーク 0）が自動テストで通過すること。

---

### `M1-07`：`zts_tauri` ワイヤー互換プロトコル & 基本コマンド群
- **専有スコープ**: `src/tauri/{mod,protocol,channel,js_bootstrap,window,event,path,app}.zig`
- **依存**: `M1-01`, `M1-04`
- **実装項目**:
  - 本家 `@tauri-apps/api` v2 がそのまま動く軽量 `window.__TAURI_INTERNALS__` JS ブートストラップ（`invoke`, `transformCallback`, `runCallback`, `convertFileSrc`, `[data-tauri-drag-region]` イベント委譲）。
  - `"__CHANNEL__:<id>"` カスタム `jsonParse` 対応の `Channel(T)` ストリーミング実装（順序保証連番付き）。
  - `Host` VTable 経由で動作する独立 `comptime` コマンドモジュール群：`window`, `event`, `path`, `app`。
- **完了条件 (DoD)**:
  - `HeadlessMock` 上で本家 `@tauri-apps/api` 互換リクエスト形式（ヘッダ・Channel 文字列・`plugin:window|*` コマンド）の全ハンドラテスト通過。
