# Task M5-01: `build.zig` 統合ヘルパー（`embedFrontend` & 自動 `tsgen`）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/build_tools/`（新規）, `build.zig`, `.github/workflows/ci.yml`,
  `docs/architecture/build-tools.md`（新規）, `docs/roadmap/m2-m5-platform-and-ecosystem.md`,
  `docs/INDEX.md`, 本ファイル
- **Upstream Reference**: `vendor/tauri/crates/tauri-build/src/lib.rs`（`tauri_build::build()` /
  `Attributes` / `CodegenContext`）、`vendor/tauri/crates/tauri-codegen/src/context.rs`
  （アセットの圧縮・CSP ハッシュ付与）、`src/rpc/tsgen.zig`（既存の TypeScript 生成器）
- **Next Step**: `src/build_tools/assets.zig` に純粋関数（gzip 圧縮 / CSP ハッシュ抽出 /
  マニフェスト描画）を実装し、単体テストを付ける。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `M2-01` で入れた `embedFrontendDir` は `build.zig` の中に直書きされていて、
(1) アプリ側から再利用できない、(2) 圧縮も CSP ハッシュも無い、(3) `bindings.gen.ts` が
手動生成のまま、という 3 点が残っている。`M5-01` でこの 3 つを片付ける。

- [ ] `src/build_tools/assets.zig`（Pure Zig・全 OS でテスト）
  - [ ] `gzipAlloc(allocator, bytes, level)` — `std.compress.flate` で決定論的に圧縮
        （同じ入力 → 同じ出力。mtime / OS バイトを固定する）
  - [ ] `cspHashesAlloc(allocator, html)` — インライン `<script>` / `<style>` の
        **中身** から `sha256-<base64>` を作る（`src=` / `href=` 付きは対象外）
  - [ ] `renderManifest(allocator, entries)` — ソート済み・決定論的な `assets_manifest.zig`
        （`entries` / `sha256_digests` / `gzip` / `csp_hashes` / `assets`）
- [ ] `src/build_tools/mod.zig`（ビルドスクリプト専用・`std.Build` のみ）
  - [ ] `embedFrontend(b, web_mod, .{ .src_dir, .module_name, .gzip, .csp })` —
        `build.zig` から呼べる形に切り出し（既存 `embedFrontendDir` の上位互換）
  - [ ] `tsgenBindings(b, .{ .rpc_mod, .schema_file, .output_path })` —
        スキーマを読む小さな exe をビルドして実行し、stdout を `bindings.gen.ts` へ書き出す
  - [ ] `tsgenBindings(...).check` — 生成結果がディスク上のファイルと**一致するか**を検証する
        （CI 用。差分があれば非 0 で落ちる）
- [ ] `build.zig`
  - [ ] 直書きの `embedFrontendDir` を `src/build_tools/mod.zig` に置き換え（実装の二重化を消す）
  - [ ] `zig build tsgen`（生成）/ `zig build check-bindings`（検証）ステップを追加
  - [ ] `examples/` のデモに `bindings.gen.ts` を実際に生成させ、E2E から読む
- [ ] CI: `OK build-tools` マーカー + `zig build check-bindings` を Linux ジョブで実行
- [ ] `./zigw quick-test` / `build test -Dgtk=true|false` / `fmt --check` / `check-docs`

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 本タスクシートの作成
- **作業中・直前の状態**:
  - 実装着手前

---

## 3. 設計判断・技術メモ・ハマりどころ

- **なぜ `src/build_tools/` を分けるか**: `build.zig` はアプリごとに書き換わる。共通ロジックを
  `build.zig` に置くとフォークが増えるので、`std.Build` だけに依存する純粋なヘルパーとして
  切り出し、アプリ側は 3 行で呼べるようにする。**`src/build_tools/` は `zts_*` モジュールを
  一切 import しない**（ビルドスクリプトとして独立してコンパイルできることをテストで担保）。
- **決定論**: `assets_manifest.zig` はパスでソートし、`@embedFile` の順序も固定する。
  gzip は `std.compress.flate` の `gzip` コンテナを使い、ヘッダの MTIME / OS を 0 で固定する
  （同じ `dist/` から常に同じバイト列 → CI の差分検出が意味を持つ）。
- **CSP ハッシュ**: 上流 `tauri-codegen` はインラインスクリプトのハッシュを `csp` に差し込む。
  ここでは **ハッシュ一覧を生成**するところまでを担当し、CSP ヘッダへの合成は `zts_web` 側の
  `Assets` 利用側（アプリ）に任せる（関心の分離）。
- **`bindings.gen.ts` の生成**: `zts_rpc.tsgen.generateComptime` は `comptime` で動くので、
  「スキーマを import するだけの小さな exe」をビルド時に走らせて stdout を書き出す。
  ソースツリーへの書き込みは `b.addUpdateSourceFiles()` を使う。
- **`--check` の実装**: 生成物をメモリ上で比較する（書き込まない）。`std.Build.Step.Run` の
  stdout を比較用の exe で読むより、生成 exe に `--check <path>` を渡して自分で比較させる方が
  シンプルで、CI でも同じコードパスを通る。
- **罠（Zig 0.17）**: `b.addWriteFiles` は `addUpdateSourceFiles` に改名済み。
  ビルドスクリプトから `@import("std").Build` 以外を持ち込むと「モジュールが 2 つに属する」
  エラーになるので、`src/build_tools/` は完全に独立させる。
