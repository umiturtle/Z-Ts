# Task M2-02: ショーケースサンプル `examples/counter/`（1 プロジェクト → 3 成果物）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `examples/counter/`, `docs/tasks/M2-02-counter-showcase.md`, `.github/workflows/ci.yml`, `docs/architecture/ssg-and-wasm.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Upstream Reference**: [`docs/architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md), [`docs/decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`](../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md), `src/app_runtime.zig`, `src/bridge/server.zig`
- **Next Step**: `examples/counter/build.zig` が `b.dependency("z_ts")` 経由でルートモジュールを取得できることを最小構成で確認 → `src/app.zig`（共有コマンド）→ `desktop/live/wasm/ssg` の 4 エントリポイント → Node プローブ（`tests/live_probe.mjs` / `tests/ssg_probe.mjs`）実装。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 「1 つのサンプルプロジェクトからデスクトップ単一バイナリ・Live Preview (HTTP Bridge)・静的 SSG Web (`dist/`) の 3 成果物を生成できる」ことをコードで示すリファレンス実装を `examples/counter/` に置く。同時に、外部プロジェクトが `b.dependency("z_ts")` で本リポジトリの standalone モジュール群を **パッケージとして** 消費できることを実証する。

- [ ] `examples/counter/` が独立パッケージとして `build.zig` + `build.zig.zon`（`z_ts` への path dependency）を持ち、ルート `build.zig` を汚さずにビルドできる
- [ ] アプリコードは 1 実装のみ（`src/app.zig`）。成果物ごとの `if (target)` 分岐が **0 行**（`App(RuntimeMode)` の comptime パラメータで同一コマンド実装を共有）
- [ ] 3 成果物:
  - [ ] `counter`（デスクトップ単一バイナリ: `DesktopRuntime` + `embedFrontendDir` 済みフロントエンド）
  - [ ] `counter-live`（`BridgeServer` + `BridgeHost`: `0.0.0.0:<port>` で待受、Arena Live Preview / ブラウザで動作）
  - [ ] `counter.wasm` + `dist/`（`zts_wasm` + `zts_ssg.exportStaticSite`: サーバ不要の静的サイト）
- [ ] フロントエンド（`web/main.ts`）は無改造の `@tauri-apps/api` v2（`invoke` / `listen`）のみを使用し、3 環境で同一バンドルが動作
- [ ] 単体テスト（正常系・異常系・境界値・`std.testing.allocator` リーク 0）＋実プロセス E2E:
  - [ ] `zig build test`（サンプルパッケージ側）で `live` の実 TCP RPC / CSRF 拒否 / SSE、`dist/` の実 `.wasm` 実行が自動検証される
- [ ] 3 OS GitHub Actions で `examples/counter` ビルド & テストがグリーン
- [ ] `examples/counter/README.md`（日本語）に 3 成果物の作り方と配信先を記載

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

<!-- サブタスク完了・設計決定・デバッグ判明のたびにここを上書き更新すること -->
- **完了したこと**:
  - タスクシェード作成（分散ロック宣言）
  - 既存 `M2-01` の API（`embedFrontendDir` / `exportStaticSite` / `BridgeServer` / `Instance(Spec)`）の再調査
- **作業中・直前の状態**:
  - これから `examples/counter/build.zig` の依存モジュール取得方式を検証

---

## 3. 設計判断・技術メモ・ハマりどころ

- **`build.zig` ヘルパーの重複を許容**: `embedFrontendDir` は現状ルート `build.zig` 内の関数で、依存パッケージからは呼べない。`M5-01` で `src/build_tools/` へ抽出するまでの暫定措置として、`examples/counter/build.zig` に同等実装を置く（`zts_ssg` モジュール自体は依存パッケージ経由で再利用）。
- **`zts_ssg` スキャナは `dep.builder.path("src/ssg/mod.zig")`** を root にした別モジュールとして起動する。ルート `build.zig` と同じ「同一ファイル・別モジュール」パターン（1 ビルド内で 2 モジュールに同一 `.zig` を入れない、という制約はモジュール単位で満たす）。
- **`RuntimeMode` は comptime パラメータ**: JS 側で環境判定をしない。`getState` が返す `mode` フィールドに `@tagName(runtime)` を埋め、画面に表示する。
- **Live Preview の bind**: Arena プレビューはプロキシ経由なので `0.0.0.0` に bind し、`PORT` 環境変数を尊重する。
