# はじめかた（5 分）

Z-Ts で最初のアプリをビルドし、3 つの成果物（デスクトップ / ブラウザ / 静的サイト）を
手元で動かすまでの最短ルートです。**必要なのは Python 3 だけ** — Zig 0.17 はラッパーが自動で
持ってきます。

---

## 0. 前提

| 項目 | 要件 |
|---|---|
| OS | Linux（GTK3 + WebKit2GTK 4.1）/ macOS（Cocoa）/ Windows（Win32 + WebView2） |
| Python | 3.8 以上（Zig の wheel を取得するため） |
| Node.js | 22 系（**任意** — Live Preview の E2E とフロントエンドのビルドにだけ必要） |

Linux の GTK 開発パッケージが無い場合は、同梱スクリプトで sysroot を入れられます
（詳細は内部資料 [`../environment/arena-and-caching.md`](../environment/arena-and-caching.md)）:

```bash
bash scripts/setup-toolchains.sh --sysroot
```

## 1. リポジトリを取って、テストを回す

```bash
git clone https://github.com/umiturtle/Z-Ts.git
cd Z-Ts
./zigw quick-test          # コールド 8 秒 / 2 回目以降 0.03 秒
```

`quick-test` は `zig build` を介さず `zig test` を直接叩くので、`std.Build` ランナーの
ビルド（コールドで 90 秒超）を待たずに全単体テストが走ります。**最初にこれを流すと、
ツールチェーンが正しく入ったことが 1 コマンドで分かります。**

## 2. サンプルを動かす（`examples/counter`）

```bash
cd examples/counter
../../zigw build desktop    # ネイティブ WebView の単一バイナリ → zig-out/bin/counter
../../zigw build preview    # ブラウザで Live Preview（既定 0.0.0.0:8788）
../../zigw build dist       # サーバ不要の静的サイト → zig-out/dist/
```

3 つは**同じアプリコード**（`src/app.zig` の状態と `src/main.zig` の UIView）から作られます。
違いは「どこで動くか」だけです:

| 成果物 | ルーティング | 状態の保持 |
|---|---|---|
| `desktop` | OS の WebView（GTK / Cocoa / Win32） | プロセス内 |
| `preview` | `zts_bridge` の HTTP + SSE | Zig プロセス内（タブを閉じても残る） |
| `dist` | 静的ファイル + `zts_wasm` | ブラウザ内（WASI 風の仮想 FS） |

## 3. 自分のプロジェクトを作る

```bash
# `zts` CLI（M5-02、実装中）が入るまでの代替: サンプルをコピーして名前を変える
cp -r examples/counter my-app && cd my-app
rm -rf zig-out .zig-cache web/bindings.gen.ts
```

`build.zig.zon` の依存を自分の Z-Ts のパスへ向けます:

```zig
.dependencies = .{
    .z_ts = .{ .path = "../Z-Ts" },   // ← ここ
},
```

> **`zts init` について**
> `src/cli/` に `zts init` / `dev` / `build` の実装が入りつつあります（引数解析とテンプレートは
> 完成・テスト済み）。雛形が出す `build.zig` は `M5-01` の共通エンベッダを
> `dep.builder.path("src/build_tools/embed_main.zig")` で起動する形で、
> このリポジトリのサンプルと同じ構成です。進捗は内部資料
> [`../tasks/M5-02-cli.md`](../tasks/M5-02-cli.md)。

## 4. フロントエンドを埋め込む

`build.zig` に次の 3 行を足すだけで、`web/` の内容が**バイナリに埋め込まれます**
（gzip 双子と CSP ハッシュ付き）:

```zig
const embed_run = b.addRunArtifact(b.addExecutable(.{
    .name = "embed",
    .root_module = b.createModule(.{
        .root_source_file = dep.builder.path("src/build_tools/embed_main.zig"),
        .target = b.graph.host,
    }),
}));
embed_run.has_side_effects = true;
embed_run.addArg("--src");
embed_run.addDirectoryArg(b.path("web"));
embed_run.addArg("--out");
const assets_dir = embed_run.addOutputDirectoryArg("frontend");
```

生成されたモジュールは `@import("embedded_frontend")` として `assets.entries`（`zts_web` の
静的アセット表）を公開します。仕組みは内部資料
[`../architecture/build-tools.md`](../architecture/build-tools.md)。

## 5. TypeScript の型を自動生成する

スキーマ（`pub const Schema = …`）を公開する小さなモジュールを 1 つ作り、
ルートの `build.zig` と同じ要領で `tsgenBindings` を呼ぶと `bindings.gen.ts` が出ます。

```zig
const gen = zts_build.tsgenBindings(b, .{
    .schema_mod = my_schema_mod,
    .output_path = "web/bindings.gen.ts",
});
b.step("tsgen", "Regenerate the TypeScript bindings").dependOn(gen.step);
```

`zig build test` は**生成物の鮮度**も検証します（古ければ落ちる）。生成と検証の 2 モードが
ある理由は内部資料 [`../architecture/build-tools.md`](../architecture/build-tools.md) §3。

## 6. ドキュメントサイトをビルドする

```bash
./zigw build docs                     # zig-out/docs/（81 ページ・リンク検査つき）
python3 -m http.server --directory zig-out/docs 8137
```

公開版は <https://umiturtle.github.io/Z-Ts/> です。仕組みは内部資料
[`../architecture/documentation-site.md`](../architecture/documentation-site.md)。

---

## 次に読むもの

| 知りたいこと | 行き先 |
|---|---|
| 全体アーキテクチャと依存 DAG | [`../architecture/00-overview.md`](../architecture/00-overview.md) |
| パッケージごとの境界契約 | [`../roadmap/m1-foundation-packages.md`](../roadmap/m1-foundation-packages.md) |
| Tauri v2 からの移行 | [`migrating-from-tauri.md`](migrating-from-tauri.md) |
| うまく動かないとき | [`troubleshooting.md`](troubleshooting.md) |
| コマンド一覧 | [`../reference/cli.md`](../reference/cli.md) |
| API ページの読み方 | [`using-the-api-reference.md`](using-the-api-reference.md) |
