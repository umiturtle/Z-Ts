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
