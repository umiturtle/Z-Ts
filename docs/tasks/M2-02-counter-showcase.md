# Task M2-02: ショーケースサンプル `examples/counter/`（1 プロジェクト → 3 成果物）

- **Status**: `done`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `examples/counter/`, `docs/tasks/M2-02-counter-showcase.md`, `.github/workflows/ci.yml`, `docs/architecture/ssg-and-wasm.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`, `docs/INDEX.md`
- **Upstream Reference**: [`docs/architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md), [`docs/decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`](../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md), `src/app_runtime.zig`, `src/bridge/server.zig`
- **Next Step**: 次フェーズ（`M3-01` macOS `WKWebView` / `M3-02` Windows `WebView2` / `M4-02` Scoped FS）へ進む。`examples/counter` はコード変更なしで 3 OS ネイティブ化できる受け皿として `M3-xx` の検証対象に使う。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 「1 つのサンプルプロジェクトからデスクトップ単一バイナリ・Live Preview (HTTP Bridge)・静的 SSG Web (`dist/`) の 3 成果物を生成できる」ことをコードで示すリファレンス実装を `examples/counter/` に置く。同時に、外部プロジェクトが `b.dependency("z_ts")` で本リポジトリの standalone モジュール群を **パッケージとして** 消費できることを実証する。

- [x] `examples/counter/` が独立パッケージとして `build.zig` + `build.zig.zon`（`z_ts` への path dependency）を持ち、ルート `build.zig` を汚さずにビルドできる
- [x] アプリコードは 1 実装のみ（`src/app.zig`）。成果物ごとの `if (target)` 分岐が **0 行**（`App(RuntimeMode)` の comptime パラメータで同一コマンド実装を共有）
- [x] 3 成果物:
  - [x] `counter`（デスクトップ単一バイナリ: `DesktopRuntime` + `embedFrontendDir` 済みフロントエンド）
  - [x] `counter-live`（`BridgeServer` + `BridgeHost`: `0.0.0.0:<port>` で待受、Arena Live Preview / ブラウザで動作）
  - [x] `counter.wasm` + `dist/`（`zts_wasm` + `zts_ssg.exportStaticSite`: サーバ不要の静的サイト）
- [x] フロントエンド（`web/main.ts`）は無改造の `@tauri-apps/api` v2（`invoke` / `listen`）のみを使用し、3 環境で同一バンドルが動作
- [x] 単体テスト（正常系・異常系・境界値・`std.testing.allocator` リーク 0）＋実プロセス E2E:
  - [x] `zig build test`（サンプルパッケージ側）で `live` の実 TCP RPC / CSRF 拒否 / SSE、`dist/` の実 `.wasm` 実行が自動検証される
- [x] 3 OS GitHub Actions で `examples/counter` ビルド & テストがグリーン
- [x] `examples/counter/README.md`（日本語）に 3 成果物の作り方と配信先を記載

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - タスクシェード作成（分散ロック宣言 `e362b8d`）
  - `build.zig.zon` の path dependency 実証（ルート fingerprint とは独立に自動採番される）
  - `src/app.zig`: `App(comptime RuntimeMode)` + `State` + `Commands`（`get_state` / `increment` / `decrement` / `reset` / `set_step`）+ `Spec`、単体テスト 6 ケース
  - `src/desktop.zig`（`DesktopRuntime` + `--selftest`）/ `src/live.zig`（`BridgeServer` + `BridgeHost`, 0.0.0.0:8788）/ `src/wasm_app.zig`（`exportApp(Spec)`）/ `src/ssg_export.zig`
  - `web/main.ts`（無改造 `@tauri-apps/api` v2 の `invoke` / `listen` のみ）+ `index.html` / `styles.css` / `tsconfig.json`
  - `scripts/build-web.mjs`（`tsc --noEmit` strict → esbuild IIFE、`tests/tauri` の依存を `nodePaths` / `paths` で共有）
  - `tests/live_probe.mjs`（43 チェック）/ `tests/ssg_probe.mjs`（28 チェック）/ `src/live_test.zig`（実 TCP）
  - `examples/counter/README.md`（日本語・6 章）、`docs/architecture/ssg-and-wasm.md` §6、roadmap / INDEX 追記
  - `.github/workflows/ci.yml`: 3 OS ジョブに `examples/counter` の `zig build test` + `zig build` を追加、`zig fmt --check` とキャッシュキーに `examples/**` を追加
- **作業中・直前の状態**:
  - 完了。ローカル / 3 OS CI ともにグリーン（§3・§5）。

---

## 3. ローカル検証結果（`Linux x86_64`, Zig 0.17.0）

```bash
cd examples/counter
../../zigw build test --summary all   # -> 15/15 steps succeeded; 7/7 tests passed
../../zigw build --summary all        # -> zig-out/{bin/counter, bin/counter-live, bin/counter.wasm, dist/}
```

| 検証 | 結果 |
|---|---|
| `src/app.zig` 単体テスト | **7/7 pass**（境界値 `step` 0/1/100/101、`i53` オーバーフロー、未知コマンド、`counter:changed`、`Instance(Spec)` リーク 0） |
| Live Preview 実 TCP | `OK live checks=43 count=5 mutations=7` |
| 静的 SSG (`dist/`) 実 `.wasm` | `OK ssg checks=28 count=0 step=5 events=7 wasm=187360B` |
| デスクトップ `--selftest` | `OK desktop mode=desktop count=2 step=1 mutations=2 html=1667B` |
| 生成物 | `counter` 27.6MB / `counter-live` 18.5MB / `counter.wasm` 184KB (ReleaseSmall) / `dist/` 233KB |
| Live Preview 実機確認 | `counter-live --port 8788 --host 0.0.0.0` に `Host: <port>-xxx.e2b.app` + `Origin: https://<port>-xxx.e2b.app` で `increment` → `{"count":1,...}`（Arena プロキシ経由でも `same_host` 検証が通る） |
| ルート側デグレ無し | `./zigw quick-test` 全モジュール pass、`./zigw fmt --check src/ tests/ examples/ build.zig build.zig.zon examples/counter/build.zig.zon` OK、`python3 scripts/check-docs.py` OK (29 files) |

---

## 4. 設計判断・技術メモ・ハマりどころ

- **`build.zig` ヘルパーの重複を許容**: `embedFrontendDir` はルート `build.zig` 内の関数で、依存パッケージからは呼べない。`M5-01` で `src/build_tools/` へ抽出するまでの暫定措置として、`examples/counter/build.zig` に同等実装を置いた（`dep.builder.path("src/ssg/mod.zig")` を root にしたスキャナを起動）。ルート `build.zig` と同じ「同一 `.zig` を別モジュールとして起動する」パターン。
- **`RuntimeMode` は comptime パラメータ**: JS 側で UA / `location` を判定しない。`getState` が返す `mode` フィールドに `@tagName(runtime)` を埋め、画面に表示する。
- **Zig 0.17 の `std.Build`**: `b.args`（`zig build run -- ...` の転送）と `b.pathFromRoot` は存在しない。前者は `preview` ステップを既定ポート固定にし、後者は `tests/live_probe.mjs` を `@embedFile`（モジュール化）+ `testing.tmpDir` へ書き出して解決した。
- **`i53` は符号込み 53 ビット**（`[-2^52, 2^52-1]`）。JS の `Number.MAX_SAFE_INTEGER` 全域が必要なら `zts_rpc.types.SafeInt`。カウンタの上限は `std.math.maxInt(i53)` を使う。
- **Bridge のイベント配送は `emit` ではなく `eval` フレーム**: `EventBus.dispatchRaw` → `Host.evalJs` → `SseHub.publishEval`。ブラウザは `es.addEventListener("eval", ...)` で `runCallback(...)` を実行する。
- **SSE は `?key=` 必須**: `EventSource` は独自ヘッダを付けられないため `verifySseRequest` がクエリパラメータを受理する（Cookie は HttpOnly で自動送信）。
- **デスクトップでは `__TAURI_INTERNALS__` が HTML に無い**: `inject_bootstrap_into_html = false` + `init_scripts` 注入のため、`--selftest` は `app.js` / `id="count"` の存在で検証する。
- **SSG `_headers` は CSP を出さない**（`application/wasm` + immutable のみ）。CSP は Bridge 側のヘッダで付与する設計。

---

## 5. CI 検証結果（GitHub Actions Run `#39919214847` — 3/3 OS ALL GREEN）

| OS / 構成 | `examples/counter` `zig build test` | `zig build`（3 成果物） | 実プロセス E2E |
|---|---|---|---|
| **Linux（`Ubuntu 24.04 + Xvfb + WebKit2GTK 4.1`）** | **`15/15 steps succeeded; 13/13 tests passed`** | **`14/14 steps succeeded`** | `OK live checks=43` / `OK ssg checks=28` / `OK desktop ...` |
| **macOS（`arm64 + WKWebView`）** | **`15/15 steps succeeded; 13/13 tests passed`** | **`14/14 steps succeeded`** | 同上（同一 43 / 28 チェック） |
| **Windows（`x86_64 + WebView2`）** | **`15/15 steps succeeded; 13/13 tests passed`** | **`14/14 steps succeeded`** | 同上（`counter-ssg pages=2 static=2 wasm=187360B`） |

- 3 OS すべてで `embedFrontendDir: embedded 3 files (17717 bytes)` が決定論的に一致
  （Windows の `D:\a\Z-Ts\Z-Ts\.zig-cache\...` 形式でも同じマニフェスト）。
- `counter.wasm` は 3 OS で **187,360 バイト** と完全一致（`-Dwasm-optimize=small` の再現性）。
- テスト数が 13 なのは、Zig のテストランナーが `live_test.zig` から到達可能な
  `app.zig` の 6 テストも同一コンパイル単位で実行するため（6 + 6 + 1 = 13）。
- 3 OS のどこでも追加インストールは発生せず、既存の `tests/tauri/node_modules` を共有。
