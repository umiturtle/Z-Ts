# ADR-0003: `M1-01` 実装で判明した Zig `0.17.0` 実践仕様メモ（後続タスク必読）

- **Date**: 2026-10-22
- **Status**: Accepted（実コンパイラ検証済み）

---

`M1-01`（`src/core/`）の実装およびマルチスレッドテスト実行を通じて確認された、後続タスク（`M1-03`〜`M5-03`）の全エージェントが必ず押さえておくべき Zig `0.17.0` 固有の仕様点：

1. **Enum Literal の `comptime` 型注釈**:
   - Zig `0.17.0` には `@EnumLiteral` 組み込み型は存在しない。
   - コンパイル時タグ引数の型には **`comptime Tag: @TypeOf(.enum_literal)`** を使用する（例: `pub fn Handle(comptime Tag: @TypeOf(.enum_literal)) type`）。

2. **`std.Io.Group.async` vs `std.Io.Group.concurrent` の決定的な違い（デッドロック防止）**:
   - **`group.async(io, fn, args)`**: `await` / `cancel` が呼ばれるまで実行開始が保証されず、実装によっては呼び出し元スレッド上でそのまま同期インライン実行される。したがって、**他タスクからの通知を `Condition.wait` で待つコンシューマや、メイン GUI ループをブロックしてはならないバックグラウンド IPC ワーカーに `group.async` を使うとデッドロック／UI 停止を起こす**。
   - **`try group.concurrent(io, fn, args)`**: 呼び出し元とは独立した実行コンテキスト（別スレッド／ファイバー）での即時並行進行を保証する。**メインループ非ブロッキング実行や Producer-Consumer 並列処理には必ず `concurrent` を使用すること**。

3. **`std.Io.Mutex` のロック使い分け**:
   - キャンセル境界を持ちたくないナノ秒単位のデータ構造操作（リングバッファの `push`/`pop` や状態フラグ更新）には **`mu.lockUncancelable(io)` + `defer mu.unlock(io)`**（戻り値 `void`、エラー不要）を使う。
   - スリープ待機を伴う `Io.Condition.wait(io, &mu)` の前後ではキャンセル可能な **`try mu.lock(io)`** を使う。

4. **Structure-of-Arrays (SoA) 化された `@typeInfo`（`M1-04` の `Schema` / `tsgen` 必読）**:
   - Zig `0.17.0`（`std/lang.zig`）では `.@"struct"`・`.@"union"`・`.@"enum"` の型情報から `fields` スライスが廃止され、並列配列（SoA）になっている：
     - **Struct**: `s_info.field_names`, `s_info.field_types`, `s_info.field_attrs`（デフォルト値の取得は **`f_attr.defaultValue(FieldType)`**）
     - **Union**: `u_info.field_names`, `u_info.field_types`
     - **Enum**: `enum_info.field_names` および **`enum_info.mode == .nonexhaustive`**（旧 `is_exhaustive` ではない）

5. **配列繰り返し演算子と Sentinel 付きスライス複製**:
   - 配列初期化の繰り返しには廃止された演算子ではなく **`@splat(value)`** を使用する（例: `var seen: [N]bool = @splat(false);`）。
   - Sentinel 付きスライス（`[:0]u8` 等）の複製には **`allocator.dupeZ` ではなく `allocator.dupeSentinel(u8, slice, sentinel)`** を使用する。

6. **関数・エラーセットの SoA `@typeInfo` と動的構造体生成 `@Struct`（`M1-04` で追加確認）**:
   - **Fn**: `.@"fn"` は `fn_info.attrs.varargs`（旧 `is_generic` は存在しないため `fn_info.return_type == null` と各要素 `maybe_param_type == null` で `anytype` を検出する）および **`fn_info.param_types: []const ?type`** を使う。関数呼び出しタプル型は `std.meta.ArgsTuple(FnType)`（内部で `@Tuple` 組み込みを使用）で取得できる。
   - **ErrorSet**: `.error_set` は `error_names: ?[]const [:0]const u8` を持つ構造体である。
   - **`@Struct` / `@Tuple` 組み込み**: `@Type(.{ .@"struct" = ... })` ではなく組み込み **`@Struct(.auto, null, field_names, &field_types, &field_attrs)`**（`std.builtin.Type.Struct.FieldAttributes` 配列）を使用する。
   - **`std.Io.Group.concurrent` のワーカー関数戻り値型**: ワーカー関数の戻り値は `void` または **`std.Io.Cancelable!void`**（`error{Canceled}!void`）でなければならない。


