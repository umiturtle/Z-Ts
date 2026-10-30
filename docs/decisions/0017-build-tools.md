# ADR-0017: フロントエンド埋め込みと `tsgen` は `src/build_tools/` の薄いビルドヘルパに置く

- **Status**: Accepted（`M5-01`）
- **Date**: 2026-10-29
- **関連**: [`../tasks/M5-01-build-tools.md`](../tasks/M5-01-build-tools.md)、
  [`../architecture/build-tools.md`](../architecture/build-tools.md)、
  [`0009-screenshot-capture-and-ci-gallery.md`](0009-screenshot-capture-and-ci-gallery.md)

---

## 1. 背景

`M2-01` で `embedFrontendDir`（`dist/` → `zts_web.Assets` モジュール）を実装したが、次の 3 点が
未解決だった。

1. 実装がルート `build.zig` の中にあり、**下流プロジェクトが再利用できない**
   （`examples/counter/build.zig` に写しが置かれていた）。
2. 生成物に**圧縮も CSP ハッシュも無い**。上流 `tauri-codegen` は brotli 圧縮と CSP ハッシュを
   行っており、配布サイズとセキュリティの両面で差が付く。
3. `bindings.gen.ts` が**手動生成**のままで、スキーマを変えても再生成されない。

## 2. 決定事項

### 2.1 3 層に分ける（`mod.zig` / `assets.zig` / `*_main.zig`）

| 層 | 依存 | 役割 |
|---|---|---|
| `mod.zig` | `std.Build` のみ | ビルドステップの配線（`embedFrontend` / `tsgenBindings`） |
| `assets.zig` | `std` のみ | gzip・CSP ハッシュ・マニフェスト描画（純粋関数） |
| `*_main.zig` | `std` のみ | ビルド時に走る小さな CLI |

ビルドスクリプトは `zts_*` モジュールを解決できない（別ビルドルート）ため、`mod.zig` にロジックを
置くと**テストできないコード**になる。判定ロジックを `assets.zig` に寄せれば、Linux の
`./zigw quick-test` で全 OS 分の変換が回る（ADR-0015 §2.1 と同じ判断）。

### 2.2 生成物は `M2-01` の上位互換にする

`entries` / `assets` / `sha256_digests` の名前と意味を変えず、`gzip_entries` と `csp_hashes` を
**足す**。既存の `zts_ssg` 利用コード（`extractAssets` 等）を書き換えずに移行できる。

### 2.3 圧縮はビルド時・決定論的に

`std.compress.flate` の gzip コンテナを使い、ヘッダの `MTIME` を 0・`OS` を Unix に固定する。
**同じ `dist/` からは、どの OS でビルドしても同じバイト列**になるので、生成物をキャッシュキーや
差分検出に使える。元より大きくなるファイルは `.gz` を作らない（`null` を出す）。

実行時圧縮（リクエストの `Accept-Encoding` を見て on-the-fly で圧縮）は却下した — CPU を
消費するうえ、ビルド時に 1 回やれば済むものをリクエストごとに繰り返すことになる。

### 2.4 `tsgen` は「生成」と「検証」の 2 モード

- 生成: 生成 exe の stdout を `captureStdOut()` → `addUpdateSourceFiles()`（同一内容なら書かない）。
- 検証: `--check` を付けて**ディスク上のファイルと比較**し、違えば exit 1。

検証モードは `run.has_side_effects = true` にする。比較対象はビルドの入力ではないため、
キャッシュ判定で「スキップ」されると検証が**常に緑**になってしまう（実際に踏んだ罠）。

`zig build test` は検証モードに依存させてあるので、スキーマを変えて再生成を忘れると CI が落ちる。

### 2.5 下流パッケージはソースを指して共有する

ビルドスクリプトは依存パッケージのモジュールを `@import` できないが、
`dep.builder.path("src/build_tools/embed_main.zig")` で**ファイルを指す**ことはできる。
`examples/counter/build.zig` はこの形で共有し、写しの実装を削除した。

## 3. 検討した代替案

1. **`build.zig` に実装を置いたまま、サンプルごとに写しを置く** — ロジックが N 箇所に増え、
   片方だけ直る事故が起きる（実際 `csp` / `gzip` を後から足すと全写しを直す必要がある）。却下。
2. **`std.Build` に依存するコードを `assets.zig` に混ぜる** — 単体テストが書けなくなる。却下。
3. **`tsgen` を `comptime` のファイル書き込みで行う** — Zig はコンパイル時のファイル書き込みを
   許さない。ビルドステップとして実行する必要がある。却下。
4. **`check-bindings` をキャッシュに任せる** — 上記のとおり常に緑になる。却下。

## 4. 結果

- `examples/counter` の `embedFrontendDir` 写し（約 40 行）が消え、共通実装 1 つになった。
- 生成物に gzip 双子と CSP ハッシュが入り、`tests/ssg/embedded_consumer.zig` が実物を検証する。
- `examples/counter/web/bindings.gen.ts` は **コミット済み**で、`zig build check-bindings` が
  鮮度を保証する。CI の Linux ジョブは `OK build-tools embed …` マーカーを必須にしている。
- **残課題**: `zts_web.Assets` はまだ `gzip_entries` を消費しない（配信側で
  `Content-Encoding: gzip` を選ぶのは `M5-03` のバンドラ / サーバ統合で扱う）。
