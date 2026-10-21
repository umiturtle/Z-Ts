# Task M1-03: `zts_rpc` 型システム & Web⇔Zig 境界 JSON コーデック

- **Status**: `in_progress`
- **Branch**: `arena/939625cc-z-ts`
- **Scope**: `src/rpc/{types,codec,naming}.zig, docs/tasks/M1-03-rpc-codec.md, docs/architecture/rpc-codec.md`
- **Upstream Reference**: `docs/architecture/web-zig-boundary.md`, `docs/roadmap/m1-foundation-packages.md`, `vendor/tauri/crates/tauri/src/ipc/`
- **Next Step**: `Zig 0.17.0 の std.json API を確認し、src/rpc/naming.zig, src/rpc/types.zig, src/rpc/codec.zig を TDD で実装する`

---

## 1. 目的と完了条件（Definition of Done）

- [ ] `src/rpc/naming.zig`: `comptime` `snake_case` ⇔ `camelCase` 変換（ハイフンを含む `@"aria-label"` / `@"data-id"` / `@"--bg"` は無変換で保持）
- [ ] `src/rpc/types.zig`: Web 境界専用ラッパー型群
  - `BigInt(T)`（`i64`/`u64`/`i128`/`u128` ⇔ JSON 文字列 `"..."` ⇔ TS `bigint`）
  - `Bytes`（生バイナリ `[]const u8` ⇔ JSON Base64 または数値配列 / Raw 経路 ⇔ TS `Uint8Array`）
  - `OsPath`（UTF-8 表示名 + 非 UTF-8 / WTF-8 生バイト往復トークン）
  - `Patch(T)`（`union(enum) { unchanged, null, value: T }` — `undefined` と `null` の 3 状態完全識別）
  - `UnionStyle` / タグ付き union 設定メタデータ（`.internal`, `.adjacent`, `.external`, `.untagged`）
  - `Handle` 互換プロトコル（`packed struct(u53)` または `toU53`/`fromU53` ダックタイピング連携）
- [ ] `src/rpc/codec.zig`: 単一ソース `comptime` JSON エンコーダ / デコーダ
  - 素の `i64`/`u64`/`i128`/`u128`/`usize`/`isize` 使用時に `@compileError` を出し `i53`/`u53` または `BigInt` へ誘導
  - 文字列デコードは `.allocate = .alloc_if_needed` で非エスケープ入力のゼロコピー借用を実現（片割れサロゲート `\uD800` 等の適切なハンドリング / 検証）
  - `f32`/`f64` の `isFinite` 検査（`NaN`/`Inf` 混入防止）
  - `union(enum)` の 4 表現モード（デフォルト `.internal` = `{ "kind": "tag", ... }`, `.adjacent` = `{ "kind": "tag", "value": ... }`, `.external` = `{ "tag": ... }`, `.untagged`）
- [ ] [`docs/architecture/web-zig-boundary.md`](../architecture/web-zig-boundary.md) の境界ケース（片割れサロゲート、非 UTF-8 パス往復、`Patch(T)` 3 状態、53-bit 境界、`NaN` 拒否、Discriminated Union、ハイフン識別子、ゼロコピー文字列）のラウンドトリップ単体テスト通過（`std.testing.allocator` リーク 0 バイト）
- [ ] `python3 scripts/check-docs.py` および `./zigw fmt --check` パス

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `scripts/status.sh` によるブランチ・並列エージェント状況確認
  - `M1-03` 要件と `docs/architecture/web-zig-boundary.md` 仕様の精査
  - タスクファイル `docs/tasks/M1-03-rpc-codec.md` の作成
- **作業中・直前の状態**:
  - タスクロックの初回コミット & Push、続いて `./zigw quick-test` による Zig 0.17.0 ブートストラップと `std.json` 仕様確認

---

## 3. 設計判断・技術メモ・ハマりどころ

- `M1-01`（`src/core/handle_pool.zig`）と並列実行される可能性があるため、`M1-03` の専有スコープ `src/rpc/{types,codec,naming}.zig` は `src/core/` が未存在でも単体コンパイル・テスト可能な疎結合設計（`comptime` ダックタイピング：`@hasDecl(T, "toU53") and @hasDecl(T, "fromU53")` または `packed struct(u53)` 判定、ならびにテスト用軽量 `Handle` 定義）とする。
- 共有ファイル（`src/root.zig` / `build.zig`）への変更は最小限に留める（または Wave 1 の排他スコープ原則に従い確認する）。
