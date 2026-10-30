# `build.zig` 統合ヘルパー（`embedFrontend` / `tsgen`）

`M5-01` で追加した `src/build_tools/` は、**アプリの `build.zig` から呼ぶための薄いレイヤ**です。
「フロントエンドの `dist/` を Zig モジュールにする」と「スキーマから `bindings.gen.ts` を作る」の
2 つだけを担当し、判定ロジックは持たない（全部 `assets.zig` と 2 つの CLI にある）。

```text
build.zig ──(src/build_tools/mod.zig)──┬──> zts_embed_frontend  (embed_main.zig)
                                       │        └─ assets.zig: walk / gzip / CSP / manifest
                                       └──> zts_tsgen           (tsgen_main.zig)
                                                └─ zts_rpc.tsgen: Schema.ts_bindings
```

## 1. なぜ `build.zig` の外に出すのか

`build.zig` は**アプリごとに書き換わる**ファイルで、共通ロジックを置くとフォークが増える
（実際 `examples/counter/build.zig` には `embedFrontendDir` の写しが置かれていた）。
`src/build_tools/` は次を満たすように作ってある:

| 制約 | 理由 |
|---|---|
| `std` と `std.Build` **だけ**を import する | ビルドスクリプトは `zts_*` モジュールを解決できない（別ビルドルート） |
| OS 依存の処理を持たない | Linux 上で macOS / Windows 向けの生成物も作れる必要がある |
| 判定ロジックは `assets.zig`（純粋関数） | `./zigw quick-test` で全 OS 分をテストできる |

`mod.zig` は `std.Build` を使うのでビルドスクリプト専用、`assets.zig` は純粋関数なので
通常のテスト対象、`embed_main.zig` / `tsgen_main.zig` はビルド時に走る小さな実行ファイル、という
3 層に分かれている。

## 2. `embedFrontend`: `dist/` → 静的 Zig モジュール

```zig
const embedded = embedFrontend(b, .{
    .src_dir = b.path("frontend/dist"),   // Vite / Astro / Next.js / SvelteKit の出力
    .web_mod = web_mod,                   // `zts_web`
});
// `embedded.module` は `@import("embedded_frontend")` で使える
```

生成物（`assets_manifest.zig`）は `M2-01` の `embedFrontendDir` と**上位互換**:

| 宣言 | 内容 |
|---|---|
| `entries: []const web.StaticAsset` | `@embedFile` された本体（パス昇順・決定論的） |
| `assets: web.Assets` | そのまま `zts_web` の静的配信に渡せる |
| `sha256_digests` | 各エントリの SHA-256（ETag / 不変キャッシュ用） |
| `gzip_entries: []const ?[]const u8` | **gzip 済みの双子**。`null` は「圧縮しない方が小さい」 |
| `csp_hashes: []const []const u8` | インライン `<script>` / `<style>` の `sha256-<base64>` |

### 2.1 決定論

* 入力は**パスでソート**してから出力する（`walk` の順序に依存しない）。
* gzip は `std.compress.flate` の gzip コンテナで、ヘッダの `MTIME` は 0・`OS` は 3（Unix）に固定。
  つまり **どの OS でビルドしても同じバイト列**になる（CI の差分検出が意味を持つ）。
* 元より大きくなるファイルは `.gz` を作らず `null` を出す（27 バイトの JS に 54 バイトの
  gzip を埋め込むのは純粋な無駄）。

### 2.2 CSP ハッシュ

上流 `tauri-codegen` と同じく、**インライン**の `<script>` / `<style>` の本文だけをハッシュ化する。

* `<script src="…">` は対象外（外部ファイルはハッシュではなく nonce / パスで許可する）。
* タグの走査は大文字小文字を無視し、**引用符の中の `>`** でタグを打ち切らない
  （`<script data-x="a > b">` を正しく扱う）。
* 出力はソート + 重複除去済み。

CSP ヘッダへの合成はアプリ側の責務にした（`zts_web.assets` は `Assets` を返すだけで、
セキュリティポリシーの組み立てはアプリの文脈に依存するため）。

## 3. `tsgenBindings`: スキーマ → `bindings.gen.ts`

`zts_rpc.tsgen` はスキーマ全体を `comptime` で TypeScript に変換する（`Schema.ts_bindings`）。
したがってビルド時にやることは「その文字列をファイルへ移す」だけ:

```zig
const gen = tsgenBindings(b, .{
    .schema_mod = counter_schema_mod,        // `pub const Schema` を公開するモジュール
    .output_path = "examples/counter/web/bindings.gen.ts",
});
```

* **生成**: 生成 exe の stdout を `captureStdOut()` し、`addUpdateSourceFiles()` で
  ソースツリーへ書き込む（内容が同じなら書き込まない）。
* **検証** (`check = true`): 生成 exe に `--check` を渡し、ディスク上のファイルと比較して
  **違えば exit 1**。`zig build test` がこれに依存しているので、スキーマを変えて再生成を忘れると
  CI が落ちる。
* `run.has_side_effects = true` を付けている: 比較対象のファイルはビルドの入力ではないため、
  キャッシュで**スキップされてはいけない**（スキップされると「常に緑」になる）。

## 4. 下流パッケージからの使い方

ビルドスクリプトは依存パッケージのモジュールを `@import` できないが、
`dep.builder.path("src/build_tools/embed_main.zig")` で**ソースを指す**ことはできる。
`examples/counter/build.zig` はこの方法でエンベッダを共有しており、gzip / CSP / マニフェストの
ロジックはライブラリ側に 1 つだけ存在する。

## 5. 検証

| 対象 | 方法 |
|---|---|
| gzip（往復・決定論・空入力） | `src/build_tools/assets.zig` の単体テスト（全 OS） |
| CSP 抽出（外部 script 除外・引用符内 `>`・大文字・重複・空要素） | 同上 |
| マニフェスト（ソート・エスケープ・重複パス拒否・gzip/CSP の on/off） | 同上 |
| 生成モジュールが実際に使えるか | `tests/ssg/embedded_consumer.zig`（実 `@embedFile` + `zts_web.Assets`） |
| `bindings.gen.ts` の鮮度 | `zig build check-bindings`（`zig build test` に組み込み済み） |
| エンベッダが実際に走ったか | CI の `OK build-tools embed files=… raw=… gzip=… csp=… gz=…` マーカー |
