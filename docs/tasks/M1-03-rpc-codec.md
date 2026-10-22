# Task M1-03: `zts_rpc` 型システム & Web⇔Zig 境界 JSON コーデック

- **Status**: `done`
- **Branch**: `arena/939625cc-z-ts`（初回実装） / `arena/ff647573-z-ts`（`M1-01`・`M1-02` 統合リファクタリング済み）
- **Scope**: `src/rpc/{mod,naming,scanner,types,codec}.zig, docs/tasks/M1-03-rpc-codec.md, docs/architecture/rpc-codec.md`
- **Upstream Reference**: `docs/architecture/web-zig-boundary.md`, `docs/roadmap/m1-foundation-packages.md`, `vendor/tauri/crates/tauri/src/ipc/`
- **Next Step**: `M1-04（src/rpc/{mod,ctx,schema,tsgen}.zig: Schema/bind ルーター合成 & tsgen 実 tsc 検証）または他の M1 タスクへの着手`

---

## 1. 目的と完了条件（Definition of Done）

- [x] `src/rpc/naming.zig`: `comptime` `snake_case` ⇔ `camelCase` 変換（ハイフンを含む `@"aria-label"` / `@"data-id"` / `@"--bg"` は無変換で保持）
- [x] `src/rpc/types.zig`: Web 境界専用ラッパー型群
  - `BigInt(T)`（`i64`/`u64`/`i128`/`u128` ⇔ JSON 文字列 `"..."` ⇔ TS `bigint`）
  - `Bytes`（生バイナリ `[]const u8` ⇔ JSON Base64 または数値配列 / Raw 経路 ⇔ TS `Uint8Array`）
  - `OsPath`（UTF-8 表示名 + 非 UTF-8 / WTF-8 生バイト往復トークン）
  - `Patch(T)`（`union(enum) { unchanged, null, value: T }` — `undefined` と `null` の 3 状態完全識別）
  - `UnionStyle` / `UnionConfig` / `TaggedUnion`（`.internal`, `.adjacent`, `.external`, `.untagged`）
  - `Handle` 互換プロトコル（`packed struct(u53)` および `toU53`/`fromU53` ダックタイピング連携）
- [x] `src/rpc/codec.zig`: 単一ソース `comptime` JSON エンコーダ / デコーダ
  - 素の `i64`/`u64`/`i128`/`u128`/`usize`/`isize` 使用時に `@compileError` を出し `i53`/`u53` または `BigInt` へ誘導
  - 文字列デコードは `.allocate = .alloc_if_needed` で非エスケープ入力のゼロコピー借用を実現（`testing.failing_allocator` で 0 バイト確保を実証）
  - `f32`/`f64` の `isFinite` 検査（`NaN`/`Inf`・指数オーバーフロー `1e500` 混入防止）
  - `union(enum)` の 4 表現モード（デフォルト `.internal` = `{ "kind": "tag", ... }`, `.adjacent` = `{ "kind": "tag", "value": ... }`, `.external` = `{ "tag": ... }`, `.untagged`）
- [x] [`docs/architecture/web-zig-boundary.md`](../architecture/web-zig-boundary.md) の境界ケース（片割れサロゲート、非 UTF-8 パス往復、`Patch(T)` 3 状態、53-bit 境界、`NaN` 拒否、Discriminated Union、ハイフン識別子、ゼロコピー文字列、HTML-Safe JSON、`checkAllAllocationFailures`）のラウンドトリップ単体テスト通過（全 29 テスト通過、リーク 0 バイト）
- [x] `python3 scripts/check-docs.py` および `./zigw fmt --check` パス

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `src/rpc/naming.zig` 実装（`snakeToCamel`, `camelToSnake`, ハイフン属性保持、先頭アンダースコア保持、JS/TS 予約語エスケープ・引用符判定）
  - `src/rpc/types.zig` 実装（`BigInt(T)`, `Bytes`, `OsPath` [POSIX 生バイト & Windows WTF-8 片割れサロゲート往復], `Patch(T)`, `UnionStyle`/`UnionConfig`/`TaggedUnion`, `Handle(Tag)`）
  - `src/rpc/codec.zig` 実装（53-bit 型検査 `checkRpcType`/`assertValidRpcType`、24B スタック `Cursor` による 0 バイト確保ゼロコピーデコーダ、4 モード `union(enum)`、HTML-safe エスケープ、`freeDecoded` による途中失敗/バックトラック時の完全解放、標準 `jsonParse`/`jsonStringify` フック互換）
  - サブシステム設計書 [`docs/architecture/rpc-codec.md`](../architecture/rpc-codec.md) 作成
  - `./zigw quick-test` 全 29 テスト通過（ウォーム実行 0.025 秒）
- **作業中・直前の状態**:
  - フォーマット・ドキュメント検査・コミット & GitHub Actions 3-OS CI 確認

---

## 3. 設計判断・技術メモ・ハマりどころ

- **なぜ `std.json.Scanner` ではなく専用の 24 バイト `Cursor` を実装したか**:
  1. `std.json.Scanner` は `{` や `[` に入るたび内部の `BitStack` でヒープ確保を行うため、非エスケープ文字列であっても完全な 0 バイト確保（`testing.failing_allocator` 通過）にならない。
  2. `std.json.Scanner` は片割れサロゲート（`\uD800`）に遭遇した時点で即 `error.SyntaxError` となり、`.replace_with_fffd` モードや `OsPath` の WTF-8 生バイト復元、また `\uD800` 直後に有効なサロゲートペア `\uD83D\uDE80` が続くケースを扱えない。
  3. 24 バイトの値型 `Cursor` にしたことで、`.internal` / `.adjacent` Union で `"kind"` キーが末尾にあるオブジェクトや、`.untagged` Union のバリアント試行バックトラックが `O(1)` の構造体コピー（ヒープ確保ゼロ）で実現できた。
- **`std.json` 標準フックとの共存**:
  - `M1-07` の `Channel(T)`（`"__CHANNEL__:<id>"` 形式）など、`pub fn jsonParse` / `pub fn jsonStringify` を持つ型も `codec.zig` からそのまま呼び出せるよう統合済み。
