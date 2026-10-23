# Task M2-01: 双方向 SSG パイプライン（`embedFrontendDir` + `zts_ssg`）& `zts_wasm` 4 モード同型実証

- **Status**: `in_progress`
- **Branch**: `arena/2a8b6e65-z-ts`
- **Scope**: `src/wasm/`, `src/ssg/`, `src/root.zig`, `build.zig`, `zigw`, `tests/ssg/`, `docs/decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`, `docs/roadmap/`, `docs/architecture/00-overview.md`, `docs/tasks/M2-01-ssg-and-wasm-runtime.md`
- **Upstream Reference**: [`docs/decisions/0005-isomorphic-ssg-and-wasm-pipeline.md`](../decisions/0005-isomorphic-ssg-and-wasm-pipeline.md), [`docs/roadmap/m2-m5-platform-and-ecosystem.md`](../roadmap/m2-m5-platform-and-ecosystem.md), [`docs/architecture/00-overview.md`](../architecture/00-overview.md)
- **Next Step**: `src/wasm/` および `src/ssg/` を実装し、Inbound SSG（`embedFrontendDir` マルチページ静的取り込み）と Outbound SSG（実 `wasm32-freestanding` `.wasm` + プリレンダリング `dist/` + 無改造 `@tauri-apps/api` v2 フル E2E スイート）を 3-OS CI で完全実証する。

---

## 1. 目的と完了条件（Definition of Done）

- [x] ADR-0005 策定・マスターロードマップ更新・分散ロック宣言コミット & リモート Push
- [ ] **`zts_wasm` (`src/wasm/{mod,io_stub,host,runtime,js_bootstrap}.zig`)**:
  - `wasmIo()` (`io_stub.zig`): `wasm32-freestanding` 対応シングルスレッド `std.Io` VTable + WebCrypto `zts_host_fill_random` 乱数ブリッジ
  - `WasmHost` (`host.zig`): `zts_core.Host` VTable 完全実装（仮想マルチウィンドウ管理、`evalJs` / `emitEvent` ホスト通知、HiDPI / ジオメトリ / ドラッグカウント保持）
  - `WasmApp(AppSchema, ...)` (`runtime.zig`): 任意の `zts_rpc` コマンド群 + `zts_tauri.CorePluginStates` を `wasm32-freestanding` C ABI（`zts_wasm_init`, `zts_wasm_alloc`, `zts_wasm_free`, `zts_wasm_invoke`, `zts_wasm_response_*`, `zts_wasm_deinit`）へ束縛するジェネリックランタイム
  - `js_bootstrap.zig`: 無改造 `@tauri-apps/api` v2 を `WebAssembly.Instance` へ接続し、ページのディレクトリ階層深さに応じた相対パス（`_zts/app.wasm` & `_zts/assets/...`）を自動解決するブートストラップ `<script>` 生成器
- [ ] **`zts_ssg` (`src/ssg/{mod,manifest_gen,exporter,embed_dir_main}.zig`) & `build.zig` `embedFrontendDir`**:
  - **Inbound SSG**: Astro / Next.js (`output: 'export'`) / Vite 等の出力ディレクトリを再帰走査し、決定論的辞書順ソート済みの `@embedFile` `zts_web.Assets` モジュールを生成する `manifest_gen.zig` + `embed_dir_main.zig` + `build.zig` 公開関数 `embedFrontendDir`
  - **Outbound SSG**: ルート別プリレンダリング（`<title>`・OGP・HTML 安全エスケープ済み初期 JSON データ `<script id="__ZTS_SSG_DATA__">`・静的 HTML 断片注入）、ネスト階層ごとの相対パス自動計算、スコープ検査付き `_zts/assets/` 書き出し、`.nojekyll` / `_headers` / `404.html` 自動生成を行う `exportStaticSite`
- [ ] **4 モード完全同型 E2E 実証 (`tests/ssg/`) & 3-OS GitHub Actions オールグリーン**:
  - `tests/tauri/e2e_live.zig` と全く同じ `DemoCommands` Zig コードを `wasm32-freestanding` の `.wasm` へコンパイルして `dist/` へ静的サイト出力し、サーバー一切不要で Node `WebAssembly.instantiate` 上から無改造 `@tauri-apps/api` v2 フルスイート（`Channel<T>` 8フレームストリーミング、`Resource`、`Event`、`Window`、`Path`、`App`、バイナリ `Uint8Array` 往復、`convertFileSrc` 静的アセット解決、プリレンダリング JSON 読み出し、スコープ外秘密ファイル非混入検査）が 100% パスすること
