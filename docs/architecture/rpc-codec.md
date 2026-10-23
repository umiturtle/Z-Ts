# `zts_rpc` 型マッピング・JSON Codec 詳細設計（`M1-03`）

- **関連 ADR / 設計書**: `docs/decisions/0002-zig-idiomatic-core-architecture.md`, `docs/architecture/web-zig-boundary.md`
- **実装モジュール**: `src/rpc/{mod,naming,scanner,types,codec}.zig`（`zts_core` 単一ハンドル & HTML-Safe エスケープ基盤と直結）

---

## 1. モジュール責務分離

`zts_rpc` のシリアライズ基盤は単一責務の 4 モジュール + パッケージファサードで構成し、後続の `M1-04`（`Schema` / `bind` / `tsgen`）および `M1-07`（Tauri v2 ワイヤー互換・`Channel(T)`）から直接利用できる構造とする。

| モジュール | 責務 |
|---|---|
| `src/rpc/mod.zig` | `zts_rpc` 公開ファサード（`src/root.zig` の `pub const rpc` と直結） |
| `src/rpc/naming.zig` | `comptime` `snake_case` ⇔ `camelCase` 変換、ハイフン属性（`aria-*`, `data-*`, `--*`）の無変換保持、JS/TS 予約語エスケープ・クォート要否判定 |
| `src/rpc/scanner.zig` | ゼロアロケーション JSON プルカーソル（`Cursor`）、`O(1)` 3 ワード巻き戻し、3 モード UTF-16 サロゲート復元、共通オブジェクト反復子（`ObjectIter`） |
| `src/rpc/types.zig` | `BigInt(T)`、`SafeInt`（`±(2^53 - 1)`）、`Bytes`、`OsPath`、`Patch(T)`、`UnionStyle`/`TaggedUnion`、および **`core.Handle(Tag)` の名目同一再エクスポート** |
| `src/rpc/codec.zig` | `comptime` 型安全性検証（`checkRpcType`）、`core.html_escape` 統合ストリーミングエンコーダ、ゼロコピー・リークフリーデコーダ |

---

## 2. Zig ⇔ JSON ⇔ TypeScript 完全型マッピング表

| Zig 型 | JSON ワイヤー表現 | 生成される TypeScript 型 | 境界安全性・特記事項 |
|---|---|---|---|
| `void` | `null` | `void` / `null` | 引数なし・戻り値なしに対応 |
| `bool` | `true` / `false` | `boolean` | 厳密一致のみ許可 |
| `i8`..`i53`, `u8`..`u53` | 数値 (`42`, `-10`) | `number` | IEEE 754 `f64` 精度内で 100% ロスレス |
| **`rpc.SafeInt`** | 数値 (`-9007199254740991`) | `number` | 符号付きフル `MIN_SAFE_INTEGER .. MAX_SAFE_INTEGER`（`±(2^53 - 1)`）境界検査 |
| **`i54`..`i128`, `u54`..`u128`, `usize`, `isize`** | **禁止（`@compileError`）** | — | 暗黙の丸め破壊をコンパイル時に完全阻止 |
| `rpc.BigInt(T)` | 10進文字列 (`"9007199254740993"`) | `bigint` | 64/128-bit 整数を 1 ビットも欠落せず往復 |
| `f16`, `f32`, `f64` | 有限数値 (`3.14`) | `number` | **`NaN` / `±Infinity` は `error.NonFiniteFloat` で厳格拒絶**、`±0.0` は `0` に正規化 |
| `[]const u8`, `[:0]const u8` | 文字列 (`"hello"`) | `string` | 有効な UTF-8 を強制。未エスケープ文字列は **ヒープ確保 0 バイト** でゼロコピー借用 |
| `rpc.Bytes` | Base64 文字列 または `[u8]` | `Uint8Array` | バイナリ専用型。デコード時は Base64 と数値配列の双方を受理 |
| `rpc.OsPath` | UTF-8 時は `"..."`、非 UTF-8 時は `{ "display", "rawToken" }` | `string \| { readonly display: string; readonly rawToken: string }` | Linux 非 UTF-8 バイト列・Windows WTF-8 サロゲートを 1 バイトも損なわず完全往復 |
| `?T`（デフォルトなし） | `<T>` または `null` | `T \| null` | キー省略時は `error.MissingField`（TS `exactOptionalPropertyTypes` 準拠） |
| `?T = null` | 省略 / `null` / `<T>` | `field?: T \| null` | 省略時も `null` として受理 |
| `rpc.Patch(T)` | `.unchanged`（省略）/ `.null` / `.value` | `field?: T \| null` | 3 状態部分更新（未変更・削除・更新）を完全に区別 |
| `enum` / `error_set` | 文字列リテラル (`"dark"`) | `"light" \| "dark"` | Non-exhaustive enum の未定義整数タグは `error.InvalidEnumTag` で安全拒絶 |
| `union(enum)` | デフォルト `{ "kind": "...", ... }` | 判別共用体 (`\|`) | `.internal`（末尾 `kind` ゼロコピー対応）・`.adjacent`・`.external`・`.untagged` の 4 モード |
| **`core.Handle(Tag)` (`rpc.Handle(Tag)`)** | 53-bit 非負整数 (`<= 2^53 - 1`) | Branded `number & { readonly __brand: Tag }` | **`core.WindowId == rpc.Handle(.window)` 単一名目型**。世代 `0` 等の不正 ID はデコード境界で `error.InvalidHandle` |
| カスタム `jsonParse` / `jsonStringify` 型 | 型定義に委譲 | 型定義に委譲 | `Channel(T)` のように内部に `*anyopaque` や `usize` を持つランタイム型もそのまま透過サポート |
