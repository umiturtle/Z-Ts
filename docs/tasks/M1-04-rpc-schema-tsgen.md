# Task M1-04: `zts_rpc` `Schema`/`bind` ルーター合成 & `tsgen`（実 `tsc` 検証 & Live Node E2E 付き）

- **Status**: `review`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `src/rpc/{mod,ctx,schema,tsgen}.zig`, `tests/tsgen/`, `build.zig`, `.github/workflows/ci.yml`, `docs/tasks/M1-04-rpc-schema-tsgen.md`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/00-overview.md`, `docs/architecture/web-zig-boundary.md`, `docs/decisions/0002-hybrid-architecture-proposal.md`
- **Next Step**: 3-OS GitHub Actions CI（`ci-linux`, `ci-macos`, `ci-windows`）オールグリーン確認後、`main` へマージして Wave 3（`M1-06` `zts_tauri`, `M1-07` `zts_webview`）の統合を受け入れ可能にする。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push（並列エージェントとのスコープ分離確立）
- [x] `src/rpc/ctx.zig`: `Ctx`（`io`, `scratch`, `host`, `window_id`, `origin`, `raw_body`）、`AuthorizeFn`、ゼロ確保エラー応答 `errorResponseComptime`（`.rodata` 静的文字列 `{"code":"<ErrorName>"}`）、および 2 ワード型消去 `Handler`（`userdata + vtable`）
- [x] `src/rpc/schema.zig`:
  - `Schema(.{ ... })` / `merge`: 複数名前空間（`""`, `"plugin:window|"`, `"blob:"` 等）の `Commands` 構造体を `comptime` で単一の O(1) `StaticStringMap` ディスパッチテーブルへ合成（完全 DCE 対応）
  - 引数シグネチャ自動判定: `*Ctx`・`*State`・`args: struct { ... }` の任意の組み合わせ・順序を `comptime` で自動認識し、`std.meta.ArgsTuple` へ束縛
  - 戻り値 `T` / `ErrorSet!T` / `Bytes` / `OwnedBytes`（`application/octet-stream` 生バイナリ応答対応）の自動ハンドリング & エラー時ヒープ確保 **0 バイト**（`testing.failing_allocator` 実証済み）の静的 `{"code":"<ErrorName>"}` 応答
  - `Rpc.bind(.{ ... })`: 実行時 State ポインタ群を検証付き `@Struct` に束縛し、ステートレス名前空間は省略可能なまま 2 ワード `Handler` へ型消去（8 ワーカー × 250 呼び出し = 2,000 並列 RPC ストレステスト実証済み）
- [x] `src/rpc/tsgen.zig`:
  - `Schema.ts_bindings`（外部 CLI 不要の純 `comptime` 生成文字列）および `writeTsBindings(writer)` / `generateAlloc(allocator, Schema)`
  - JS/TS 全予約語エスケープ、ハイフン識別子クォート（`"aria-label"`, `"--accent-color"` 等）
  - **`--erasableSyntaxOnly` 完全準拠**（TS `enum` / `namespace` / parameter property 一切不使用、Node `v22` ネイティブ `.ts` 直接実行対応）
  - **`--exactOptionalPropertyTypes` 完全準拠**（`?T` → `T | null`、`?T = null` / `Patch(T)` → `field?: T | null`、`T = default` → `field?: T`）
  - **`ErrorSet` → 判別可能な型付き `RpcResult<T, E>`（`client.$try.<cmd>`）& `ZtsRpcError<E>` 例外送出（`client.<cmd>`）のデュアル API 生成**
  - **`Handle(Tag)` → Nominal Branded Type `Brand<number, "<Tag>">` 自動出力 & 世代 0 偽造ハンドルの実行時 `InvalidHandle` 自動拒絶**
  - **全 4 種 `TaggedUnion`（`internal`, `adjacent`, `external`, `untagged`）& `bigint` ⇔ string / `Uint8Array` ⇔ Base64 自動相互変換**
- [x] 実 `tsc` + Live Node ⇔ Zig 双方向 IPC E2E 検証（`tests/tsgen/verify_client.ts`）:
  - `typescript@7.0.2`（`tsgo`）で `--noEmit --strict --exactOptionalPropertyTypes --erasableSyntaxOnly --target es2022 --module nodenext --moduleResolution nodenext` が **エラー・警告 0 件**（かつ `@ts-expect-error` ネガティブ型証明 4 項目すべて発火確認！）
  - 実 `node` `v22` プロセスを起動し、生成された `createRpcClient` と Zig `Router`（`Handler`）の間で 9 往復のリアルタイム双方向 RPC ラウンドトリップ（`9007199254741000n` 64bit 超 `bigint`、`Uint8Array` バイナリ、`Patch(T)` 3 状態、世代付き `Handle` 偽造拒絶と通過、予約語 `delete`、`plugin:window|set_title`、型付きエラー網羅分岐）を実行し完全一致を検証
- [x] ローカル Debug / `ReleaseFast`（`73/73` 全テストパス、メモリリーク 0 バイト）および 3-OS GitHub Actions CI 設定完了

---

## 2. 実測パフォーマンス記録（Arena Sandbox / Zig `0.17.0` + `typescript@7.0.2` + Node `v22.22.3`）

| 対象 | Debug コンパイル | Debug 実行 | `ReleaseFast` 実行 | 備考 |
|---|---|---|---|---|
| `zts_core` 単体 (`20/20`) | `4ms` (cached) / `1s` | `16ms` (`MaxRSS: 7MB`) | **`2ms` (`MaxRSS: 2MB`)** | 10,000-step `HandlePool` fuzz + 並列 `RingQueue` 込み |
| `z_ts` 全体統合 (`53/53`) | `1s` (`MaxRSS: 168MB`) | `771ms` (`MaxRSS: 93MB`) | **`423ms` (`MaxRSS: 94MB`)** | 2,000 並列 RPC + `tsc 7.0.2` + Live Node `v22` E2E 起動込み |

---

## 3. 下流タスク（`M1-05` `zts_bridge` / `M1-06` `zts_tauri` / `M1-07` `zts_webview`）向け接続ガイド

> **重要（単体切り出し境界）**: `zts_rpc` は **`zts_foundation` のみ** に依存しており、デスクトップ Window `Host` (`zts_core.Host`) や Tauri 型への直接依存を持ちません。ホスト固有コンテキストはゼロ確保の型安全 DI スロット `Ctx.withEnv(&env)` / `ctx.requireEnv(T)` で受け渡します。

1. **アプリ / プラグイン側の定義と `Handler` 取得**:
   ```zig
   const WindowPlugin = struct {
       pub const rpc_prefix = "plugin:window|";

       pub fn set_title(ctx: *zts.rpc.Ctx, args: struct {
           window: zts.core.WindowId,
           title: []const u8,
       }) (zts.core.HostError || error{MissingContext})!void {
           const call = try ctx.requireEnv(zts.core.CallContext);
           try call.host.setWindowTitle(args.window, args.title);
       }
   };

   const Rpc = zts.rpc.Schema(.{
       .app = .{ .State = AppState, .Cmds = AppCommands },
       .window = WindowPlugin,
   });

   var router = Rpc.bind(.{ .app = &app_state });
   const handler: zts.rpc.Handler = router.handler();
   ```
2. **IPC トランスポート層（Tauri custom protocol / Z-Ts native bridge）からの呼び出し**:
   ```zig
   _ = worker_arena.reset(.retain_capacity);
   const call_ctx: zts.core.CallContext = .{ .host = host, .window_id = caller_window_id };
   var ctx = zts.rpc.Ctx.init(io, worker_arena.allocator()).withEnv(&call_ctx);
   ctx.origin = caller_origin;
   var resp = handler.dispatch(response_gpa, &ctx, command_name, request_body_bytes);
   defer resp.deinit(); // または `host.respond(request_id, resp)` へ所有権ムーブ
   ```
