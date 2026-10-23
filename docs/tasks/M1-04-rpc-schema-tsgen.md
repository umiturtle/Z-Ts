# Task M1-04: `zts_rpc` `Schema`/`bind` ルーター合成 & `tsgen`（実 `tsc` 検証付き）

- **Status**: `in_progress`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `src/rpc/{mod,ctx,schema,tsgen}.zig`, `tests/tsgen/`, `build.zig`, `docs/tasks/M1-04-rpc-schema-tsgen.md`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/00-overview.md`, `docs/architecture/web-zig-boundary.md`
- **Next Step**: `Ctx` / `Handler` / `Schema` / `bind` / `tsgen` を実装し、Node.js + `typescript` (`tsc --noEmit --strict --exactOptionalPropertyTypes --erasableSyntaxOnly`) による自動型検証テストと 3-OS GitHub Actions CI を通す。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push（並列エージェントとのスコープ分離確立）
- [ ] `src/rpc/ctx.zig`: `Ctx`（`io`, `scratch`, `host`, `window_id`, `origin`, `headers`）および型消去 `Handler`（`userdata + vtable`）と `RpcResponse`（JSON / Raw `OwnedBytes`、エラー時 0 アロケーション `{"code":"<ErrorName>"}`）
- [ ] `src/rpc/schema.zig`:
  - `Schema(.{ ... })`: 複数名前空間（`""`, `"plugin:window|"` 等）の `Commands` 構造体を `comptime` で単一の静的ディスパッチテーブルへ合成
  - 引数シグネチャ自動判定: `(Ctx)` / `(Ctx, ArgsStruct)` / `(StatePtr, Ctx)` / `(StatePtr, Ctx, ArgsStruct)`（および `Ctx` 不要な純粋関数 `(ArgsStruct)` / `()` も柔軟対応！）
  - 戻り値 `T` / `ErrorSet!T` / `Bytes`（Raw バイナリ応答対応）の自動ハンドリング & エラー時ヒープ確保 0 バイトの静的 `{"code":"<ErrorName>"}` 応答
  - `Rpc.bind(.{ ... })`: 実行時 State ポインタ群を束縛し、軽量 `Handler` へ型消去する Router インスタンス生成
- [ ] `src/rpc/tsgen.zig`:
  - `Schema.ts_bindings`（`comptime` 生成文字列）および `writeBindings(writer)` / `zig build tsgen` ビルドステップ連携
  - JS/TS 全予約語エスケープ、ハイフン識別子クォート（`"aria-label"` 等）
  - **`erasableSyntaxOnly` 完全準拠**（TS `enum` / `namespace` 一切不使用、文字列リテラル共用体 + `as const` のみ）
  - **`exactOptionalPropertyTypes` 完全準拠**（`?T` → `T | null`、`?T = null` / `Patch(T)` → `field?: T | null`、`T = default` → `field?: T`）
  - **`ErrorSet` → 判別可能な型付き `RpcResult<T, E>` & 関数オーバーロード出力**
  - **`Handle(Tag)` → Nominal Branded Type `number & { readonly __brand: "<Tag>" }` 自動出力**
  - **循環・共通構造体 / 共用体の名前付き `export interface` / `export type` 自動重複排除エミッション**
- [ ] 実 `tsc` 検証: Node.js + `typescript` コンパイラで `--noEmit --strict --exactOptionalPropertyTypes --erasableSyntaxOnly` を自動実行し、生成コード＋型レベルアサーションテスト（`@ts-expect-error` で不正型が確実に弾かれることまで検証！）が警告・エラー 0 件で通過すること
- [ ] Debug / `ReleaseFast` / 3-OS GitHub Actions CI（Linux / macOS / Windows すべてで `tsc` 検証実行！）オールグリーン

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `main` (`63d9fd8`) からの分岐およびリモート並列ブランチ確認を実施し、`M1-04` をロック取得。
- **作業中・直前の状態**:
  - アーキテクチャ文書および Node/`tsc` 環境を確認し、実装設計を開始。
