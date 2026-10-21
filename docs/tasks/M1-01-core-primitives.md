# Task M1-01: `zts_core` 基盤型・世代ハンドル・スレッド間キュー・Host 契約の実装

- **Status**: `in_progress`
- **Branch**: `arena/fd56d824-z-ts`
- **Scope**: `src/core/{mod,handle_pool,owned_bytes,queue,geometry,host}.zig`, `src/root.zig`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/web-zig-boundary.md`, `vendor/tauri/crates/tauri/src/resources/`
- **Next Step**: `handle_pool.zig`, `owned_bytes.zig`, `queue.zig`, `geometry.zig`, `host.zig`, `mod.zig` を TDD で実装し、`std.testing.allocator` / `std.testing.io` による単体・境界値・並列ストレステストと GitHub Actions 3-OS CI を通す。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push
- [ ] `src/core/handle_pool.zig`: IEEE 754 安全な `u53` 世代番号付き `Handle(Tag)` & `HandlePool(T, Tag)`（O(1) フリーリスト、ABA 検出、世代ラップアラウンド、`std.json` 統合）
- [ ] `src/core/owned_bytes.zig`: 遅延/非同期解放スライス `OwnedBytes`（`static`, `dupe`, `fromOwnedSlice`, C ABI コールバック連携 `release_fn`）
- [ ] `src/core/queue.zig`: `std.Io.Mutex` 保護のスレッドセーフ MPSC リングキュー `RingQueue(T)`（バッチ drain・グレースフル close 対応）
- [ ] `src/core/geometry.zig`: `LogicalPx` / `PhysicalPx` 型安全分離、DPI スケール変換、macOS Y軸反転、Straight RGBA ⇔ Premultiplied BGRA / Hex パーサ
- [ ] `src/core/host.zig`: OS 非依存 `Host` Fat-Pointer VTable 契約 & テスト用 `RecordingHost`
- [ ] `src/core/mod.zig` & `src/root.zig`: 全テスト（正常・異常・境界値・マルチスレッド負荷・メモリリーク 0B）通過
- [ ] `python3 scripts/check-docs.py`・`./zigw fmt --check`・`./zigw quick-test`・GitHub Actions 3-OS CI 全グリーン

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `bash scripts/status.sh` でブランチ状態（`arena/fd56d824-z-ts`, HEAD `5b5383e`）および他並列ブランチとの競合なしを確認。
  - `M1-01` タスクファイルを `in_progress` として作成・Push。
- **作業中・直前の状態**:
  - `src/core/` 配下 6 ファイルの本実装と徹底的な単体・並列テスト作成を開始。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **並列コンフリクト防止**: `M1-02` が `src/core/{assets,mime,http_range,csp,html_escape,glob,url}.zig` を並行作業する可能性を考慮し、本タスクでは `M1-01` 専有ファイルのみを作成し、`build.zig` は無変更に保つ。
- **Zig `0.17.0` 準拠**: 排他制御には `std.Io.Mutex = .init` (`lock(io)` / `unlock(io)` / `lockUncancelable(io)`) を使用し、コレクションには Unmanaged スタイルの `std.ArrayList(T)` (`.empty`) を使用する。
