# Task M5-01: `build.zig` 統合ヘルパー（`embedFrontend` & 自動 `tsgen`）

- **Status**: `done`（2026-10-29 / CI run [`40841158959`](https://github.com/umiturtle/Z-Ts/actions/runs/40841158959) 4/4 green）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/build_tools/`（新規）, `build.zig`, `examples/counter/{build.zig,src/bindings_schema.zig,web/bindings.gen.ts}`,
  `tests/ssg/embedded_consumer.zig`, `.github/workflows/ci.yml`,
  `docs/architecture/build-tools.md`（新規）, `docs/decisions/0017-build-tools.md`（新規）,
  `docs/roadmap/m2-m5-platform-and-ecosystem.md`, `docs/INDEX.md`, 本ファイル
- **Upstream Reference**: `vendor/tauri/crates/tauri-build/src/lib.rs`（`tauri_build::build()` /
  `Attributes` / `CodegenContext`）、`vendor/tauri/crates/tauri-codegen/src/context.rs`
  （アセットの圧縮・CSP ハッシュ付与）、`src/rpc/tsgen.zig`（既存の TypeScript 生成器）
- **Next Step**: なし（完了）。後続は `M5-02`（`zts` CLI）/ `M5-03`（3-OS パッケージャ）。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `M2-01` で入れた `embedFrontendDir` は `build.zig` の中に直書きされていて、
(1) アプリ側から再利用できない、(2) 圧縮も CSP ハッシュも無い、(3) `bindings.gen.ts` が
手動生成のまま、という 3 点が残っている。`M5-01` でこの 3 つを片付ける。

- [x] `src/build_tools/assets.zig`（Pure Zig・全 OS でテスト）
  - [x] `gzipAlloc(allocator, bytes, level)` — `std.compress.flate` で決定論的に圧縮
        （同じ入力 → 同じ出力。mtime / OS バイトを固定する）
  - [x] `inlineCspHashes(allocator, html)` + `cspHashOf(body)` — インライン `<script>` /
        `<style>` の **中身** から `sha256-<base64>` を作る（`src=` 付きは対象外）
  - [x] `renderManifest(allocator, entries)` — ソート済み・決定論的な `assets_manifest.zig`
        （`entries` / `sha256_digests` / `gzip_entries` / `csp_hashes` / `assets`）
- [x] `src/build_tools/mod.zig`（ビルドスクリプト専用・`std.Build` のみ）
  - [x] `embedFrontend(b, .{ .src_dir, .web_mod, .module_name, .gzip, .csp, .runner_source })` —
        `build.zig` から呼べる形に切り出し（既存 `embedFrontendDir` の上位互換）
  - [x] `tsgenBindings(b, .{ .schema_mod, .output_path, .check, .runner_source })` —
        スキーマを公開するモジュールを入力に、stdout を `bindings.gen.ts` へ書き出す
  - [x] `tsgenBindings(...).check` — 生成結果がディスク上のファイルと**一致するか**を検証する
        （CI 用。差分があれば非 0 で落ちる）
  - [x] `embedRunner(b, source)` — 実行ファイルを組み立てる共通部分
- [x] `build.zig`
  - [x] 直書きの `embedFrontendDir` を `src/build_tools/mod.zig` に置き換え（実装の二重化を消す）
  - [x] `zig build tsgen`（生成）/ `zig build check-bindings`（検証）ステップを追加
  - [x] `examples/` のデモに `bindings.gen.ts` を実際に生成させ、E2E から読む
- [x] CI: `OK build-tools embed …` マーカー + `zig build check-bindings` を Linux ジョブで実行
- [x] `./zigw quick-test` / `build test -Dgtk=true|false` / `fmt --check` / `check-docs`

### 1.1 実装 API（確定版）

```zig
const zts_build = @import("src/build_tools/mod.zig");

// 1) dist/ → 静的モジュール
const embedded = zts_build.embedFrontend(b, .{
    .src_dir = b.path("web/dist"),
    .web_mod = web_mod,                     // `zts_web`（`Assets` 型を借りるだけ）
    .module_name = "embedded_frontend",     // 既定値
    .gzip = true,                           // 既定値
    .csp = true,                            // 既定値
});
app.root_module.addImport("embedded_frontend", embedded.module);

// 2) スキーマ → bindings.gen.ts
const gen = zts_build.tsgenBindings(b, .{
    .schema_mod = counter_schema_mod,       // `pub const Schema` を公開するモジュール
    .output_path = "web/bindings.gen.ts",
});
const check = zts_build.tsgenBindings(b, .{
    .schema_mod = counter_schema_mod,
    .output_path = "web/bindings.gen.ts",
    .check = true,                          // 差分があれば exit 1（キャッシュ無効化済み）
});
test_step.dependOn(check.step);
```

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**（すべて）:
  - `assets.zig`（7 テスト）→ `mod.zig` → `embed_main.zig` / `tsgen_main.zig` → `build.zig` 統合
    → `examples/counter` の写し実装削除 → テスト / CI ゲート → ドキュメント（本ファイル /
    `docs/architecture/build-tools.md` / `ADR-0017`）
  - `examples/counter/build.zig` のローカル `embedFrontendDir`（約 40 行）は
    `dep.builder.path("src/build_tools/embed_main.zig")` で**共通実装を起動するだけ**になった
- **作業中・直前の状態**: なし。CI 4/4 green、ドキュメント更新済み。
- **再開するとき**: `./zigw build tsgen` → `./zigw build check-bindings` →
  `./zigw build test -Dgtk=false` が通ることを確認すれば同じ状態に戻る。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **なぜ `src/build_tools/` を分けるか**: `build.zig` はアプリごとに書き換わる。共通ロジックを
  `build.zig` に置くとフォークが増えるので、`std.Build` だけに依存する純粋なヘルパーとして
  切り出し、アプリ側は数行で呼べるようにする。**`src/build_tools/` は `zts_*` モジュールを
  一切 import しない**（`web.Assets` の型だけを `web_mod` 経由で借りる）。
- **3 層構造**: ロジック（`assets.zig`・`std` のみ）／配線（`mod.zig`・`std.Build` のみ）／
  実行体（`*_main.zig`・ビルド時に走る CLI）。判定ロジックを `mod.zig` に置くと
  「ビルドスクリプトからしか呼べない＝テストできない」コードになるため、必ず `assets.zig` に寄せる。
- **決定論**: `assets_manifest.zig` はパスでソートし、`@embedFile` の順序も固定する。
  gzip は `std.compress.flate` の `gzip` コンテナを使い、ヘッダの MTIME / OS を固定する
  （実測ヘッダは `1f 8b 08 00 00 00 00 00 00 03` で、どの OS でも同じバイト列 → CI の差分検出が
  意味を持つ）。元より大きくなるファイルは `.gz` を作らず `null` を出す。
- **CSP ハッシュ**: 上流 `tauri-codegen` はインラインスクリプトのハッシュを `csp` に差し込む。
  ここでは **ハッシュ一覧を生成**するところまでを担当し、CSP ヘッダへの合成は `zts_web` 側の
  `Assets` 利用側（アプリ）に任せる（関心の分離）。
- **タグ走査の罠**: 開始タグの本体を「タグ名の直後」から切り出すと閉じタグが混入し、
  小文字比較だと `<SCRIPT>` を取りこぼす。**`html[open.start..close.start]`** で切り、
  タグ名は大文字小文字を無視して比較する（プローブで実数を確認してから直した）。
- **`bindings.gen.ts` の生成**: `zts_rpc.tsgen` は `comptime` で動くので、
  「スキーマを import するだけの小さな exe」をビルド時に走らせて stdout を書き出す。
  ソースツリーへの書き込みは `b.addUpdateSourceFiles()`（`addCopyFileToSource`）を使う。
- **`--check` の実装**: 生成 exe に `<output.ts> --check` を渡し、**自分で比較させる**
  （`captureStdOut` の結果を Zig 側で比べるより単純で、CI でも同じコードパスを通る）。
- **罠（Zig 0.17）**:
  - `b.addWriteFiles` は `addUpdateSourceFiles` に改名済み。
  - **`Step.dependOn` は `*Step` を要求**する。`TsgenResult.step` は `*const *Step` なので
    `test_step.dependOn(&check.step)` は `expected type '*Build.Step', found '*const *Build.Step'`
    になる → **`dependOn(check.step)`（`&` を付けない）**。
  - **検証ステップはキャッシュされると「常に緑」になる**。比較対象のファイルはビルド入力では
    ないため、`run.has_side_effects = true` を付けないと stale を見逃す（実際に踏んだ）。
  - `std.Io.Writer.writeAll` のエラー集合は `error{WriteFailed}` なので、
    `Allocator.Error![]u8` を宣言した関数からは `try` できない（戻り値型は推論 `![]u8`）。

---

## 4. 検証結果（ローカル Linux）

| コマンド | 結果 |
|---|---|
| `./zigw build tsgen` | `examples/counter/web/bindings.gen.ts` を生成（7392 B / 176 行、先頭 `// Auto-generated by Z-Ts \`zts_rpc.tsgen\` — DO NOT EDIT MANUALLY.`） |
| `./zigw build check-bindings` | 正常時 exit 0 / stale 時 exit 1 + ``tsgen: <path> is stale (N bytes on disk, M generated); run `zig build tsgen` `` |
| `./zigw build test -Dgtk=false` | **48/48**（`src/build_tools/assets.zig` 7 テスト含む） |
| `./zigw build test -Dgtk=true` | **50/50** |
| `./zigw fmt --check src/ tests/ examples/ build.zig` | exit 0 |
| `python3 scripts/check-docs.py` | `OK (60)` |
| エンベッダ単体実行（`tests/ssg/fixtures/site`） | `OK build-tools embed files=3 raw=451 gzip=2 csp=0 gz=328` |
| `examples/counter` の埋め込み | `OK build-tools embed files=3 raw=17717 gzip=3 csp=0 gz=5461` |

**CI**（run `40841158959` @ `cc9ca18`）: Linux / macOS / Windows / Cross-OS parity の **4/4 green**。
Linux ジョブの `Verify the build-tools embedder and the generated bindings (M5-01 gate)` ステップが
成功（＝ `OK build-tools embed …` マーカーが出た＝ walk / gzip / マニフェストが実際に走った）。
`check-bindings` は `zig build test` の依存なので、同じジョブのテストステップで検証済み。

> `csp=0` はフィクスチャにインライン `<script>` / `<style>` が無いため 0 が正しい値。
> CSP 抽出そのものは `assets.zig` の 7 テスト（外部 script 除外 / 引用符内の `>` / 大文字タグ /
> 重複除去 / 空 body）で検証している。
