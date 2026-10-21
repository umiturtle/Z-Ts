# Task M1-01: `zts_core` 基盤型・世代ハンドル・スレッド間キュー・Host 契約の実装

- **Status**: `done`
- **Branch**: `arena/fd56d824-z-ts`
- **Scope**: `src/core/{mod,handle_pool,owned_bytes,queue,geometry,host}.zig`, `src/root.zig`, `docs/decisions/0003-zig-017-runtime-findings.md`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/web-zig-boundary.md`, `vendor/tauri/crates/tauri/src/resources/`
- **Next Step**: PR を `main` へマージ後、依存解除された Wave 2 タスク（`M1-04`, `M1-05`, `M1-06`, `M1-07`）へ着手可能。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push
- [x] `src/core/handle_pool.zig`: IEEE 754 安全な `u53` 世代番号付き `Handle(Tag)` & `HandlePool(T, Tag)`（O(1) フリーリスト、ABA 検出、世代ラップアラウンド、`std.json` 統合、10,000 ステップ Fuzz Oracle テスト）
- [x] `src/core/owned_bytes.zig`: 遅延/非同期解放スライス `OwnedBytes`（`static`, `dupe`, `fromOwnedSlice`, C ABI `GDestroyNotify` 単一ポインタコールバック連携 `intoCParts` / `destroyFromC`）
- [x] `src/core/queue.zig`: `std.Io.Mutex` + `std.Io.Condition` 保護のスレッドセーフ MPSC リングキュー `RingQueue(T)`（起床合流フラグ `was_empty`、一括 `drain`、`waitPop` / `close`）
- [x] `src/core/geometry.zig`: `LogicalPx` / `PhysicalPx` 型安全分離、DPI スケール変換、macOS Y軸反転、Straight RGBA ⇔ Premultiplied BGRA / CSS Hex パーサ
- [x] `src/core/host.zig`: OS 非依存 `Host` Fat-Pointer VTable 契約 & インメモリスライステスト用 `RecordingHost`
- [x] `src/core/mod.zig` & `src/root.zig`: Debug / `ReleaseFast` 全 11 テスト通過（リーク 0B）および Windows / macOS クロスコンパイル検証通過
- [x] `python3 scripts/check-docs.py`・`./zigw fmt --check`・GitHub Actions 3-OS CI グリーン確認

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `src/core/` 配下 6 モジュール（`handle_pool.zig`, `owned_bytes.zig`, `queue.zig`, `geometry.zig`, `host.zig`, `mod.zig`）の実装・テスト完了。
  - 実機コンパイルで判明した Zig `0.17.0` 実践仕様（`@TypeOf(.enum_literal)`、`Io.Group.concurrent` vs `async`、`Io.Mutex.lockUncancelable`）を [`ADR-0003`](../decisions/0003-zig-017-runtime-findings.md) に記録。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **`Io.Group.concurrent` の重要性**: `std.Io.Group.async` は `await` まで実行開始保証がなく同期インライン実行され得るため、Producer-Consumer 待機や非ブロッキング IPC タスクには必ず `group.concurrent` を使うこと（`ADR-0003` 参照）。
- **他ブランチとの衝突最小化**: `build.zig`・`docs/INDEX.md`・`M1-02` 領域ファイルは一切変更していないため、並行稼働中の `M1-02` / `M1-03` ブランチとそのままクリーンにマージ可能。
