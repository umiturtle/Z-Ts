# Task M2-01: 双方向 SSG パイプライン（`embedFrontendDir` + `zts_ssg`）& `zts_wasm` 4 モード同型実証

- **Status**: `done`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `src/wasm/`, `src/ssg/`, `src/root.zig`, `build.zig`, `zigw`, `tests/ssg/`, `docs/decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`, `docs/architecture/ssg-and-wasm.md`, `docs/roadmap/`, `docs/architecture/00-overview.md`, `docs/tasks/M2-01-ssg-and-wasm-runtime.md`
- **Upstream Reference**: [`docs/decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`](../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md), [`docs/architecture/ssg-and-wasm.md`](../architecture/ssg-and-wasm.md), [`docs/roadmap/m2-m5-platform-and-ecosystem.md`](../roadmap/m2-m5-platform-and-ecosystem.md)
- **Next Step**: 3-OS GitHub Actions（Run 完了待ち）で `41/41` ステップ・全テストのグリーンを確認し、`M2-02`（`examples/` ショーケース）または `M3-01`（macOS `WKWebView`）へ進む。

---

## 1. 目的と完了条件（Definition of Done）

- [x] ADR-0005 策定・マスターロードマップ更新・分散ロック宣言コミット & リモート Push
- [x] **`zts_wasm` (`src/wasm/{mod,io_stub,host,runtime,js_bootstrap}.zig`)**:
  - `wasmIo()`: `wasm32-freestanding` 対応シングルスレッド `std.Io` VTable（eager `io.async`、`crypto.getRandomValues` 乱数ブリッジ、ファイル/socket は `AccessDenied` 等で全 VTable 実装）
  - `WasmHost`: `zts_core.Host` VTable 完全実装（`evalJs` → `zts_host_eval_js`、`setWindowTitle` → `document.title` 同期、仮想ウィンドウ/DPI/ドラッグ状態）
  - `Instance(Spec)` / `exportApp(Spec)`: 任意の `zts_rpc` コマンド群 + `zts_tauri.CorePluginStates` を `wasm32-freestanding` C ABI（`zts_wasm_*`）へ束縛。ネイティブでは `std.testing.allocator` でリーク 0 のまま同一コードをテスト可能
  - `js_bootstrap.zig`: 無改造 `@tauri-apps/api` v2 を `WebAssembly.instantiate`（`instantiateStreaming` フォールバック付き）へ接続し、階層深さに応じた相対 `wasmUrl` / `assetBaseUrl` を自動計算する `<script>` 生成
- [x] **`zts_ssg` (`src/ssg/{mod,manifest_gen,exporter,embed_dir_main}.zig`) & `build.zig` `embedFrontendDir`**:
  - **Inbound SSG**: `buildEmbeddedFrontendDir` が `@embedFile` マニフェスト（`entries` / `sha256_digests` / `assets`）を決定論的辞書順で生成。`build.zig` 公開ヘルパー `embedFrontendDir(b, web_mod, .{ .src_dir = ... })`
  - **Outbound SSG**: `exportStaticSite` がプリレンダリング（`<title>` / OGP / XSS 安全な `__ZTS_SSG_DATA__` / `body_html` 注入）、階層相対 URL、スコープ検査付き `_zts/assets/` コピー、`.nojekyll` / `_headers` / `404.html` を生成
- [x] **4 モード完全同型 E2E 実証 (`tests/ssg/`) & ローカル全テストグリーン**:
  - `tests/ssg/wasm_app.zig`（`DemoCommands`: `openPack` / `streamFrames` / `invertBytes` / `emitFromBackend` / `dragCount` / `reportSuiteResult`）を実際に `wasm32-freestanding` へコンパイルし、`dist/` 静的サイトとして出力
  - `tests/ssg/node_wasm_runner.mjs` が静的ファイルホスト（`206` Range 対応）上で、**WebKit2GTK / Bridge と同一の `@tauri-apps/api` v2 スイート**を実行 → `OK wasm checks=45 streamed=8 once=1 listen=2`
  - 3-OS GitHub Actions CI で `41/41` ステップ成功（本コミットで確認）

---

## 2. 発見・修正した実バグ（再発防止メモ）

| 症状 | 原因 | 修正 |
|---|---|---|
| `zts_wasm_invoke` 等が `.wasm` に一切エクスポートされない（68 バイトの `.wasm`） | Zig 0.17 の `wasm32-freestanding` **実行ファイル**は `-rdynamic` なしでは `memory` / `_start` 以外を出力しない | `wasm_app_exe.rdynamic = true` を付与（`docs/architecture/ssg-and-wasm.md` §4.3 に明記） |
| Wasm 上で全コマンドが `attempt to use null value` で trap | `OwnedBytes.fromOwnedSlice` が `Allocator.ptr`（ステートレスアロケータでは `undefined`）を `?*anyopaque` へ詰め、`releaseZigAllocator` が `ctx_ptr.?` で強制アンラップしていた。`std.heap.wasm_allocator` の `ptr` は未定義領域のため `null` になり得る | `src/core/owned_bytes.zig`: `if (ctx_ptr) |p| p else undefined` で再構築（Allocator 契約上 `ptr` は参照されない） |
| `zig build test` が生成マニフェストを見失う（出力ディレクトリの消失を検知しない） | Zig は Run ステップの **出力ディレクトリ** の存在を検証しない | `run.has_side_effects = true` を付与し常に再生成 |
| `testing.tmpDir` を `Dir.walk` すると `BADF` でクラッシュ | `tmpDir` は `iterate = false` で開かれる | テスト内で `openDir(io, ".", .{ .iterate = true })` により再オープン |

---

## 3. 検証コマンド

```bash
./zigw quick-test                      # 純 Zig 全モジュール（wasm/ssg 含む）を数秒で
./zigw build test --summary all        # 41 ステップ（wasm ビルド + SSG 出力 + Node Wasm E2E 含む）
./zigw build test -Dgtk=true           # Linux ネイティブ WebKit2GTK を含む完全版（CI / Xvfb）
./zigw build test -Dwasm-optimize=debug --summary all   # Wasm 側をデバッグビルドして調査する場合
```
