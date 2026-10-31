# はじめかた（5 分）

`zts` でプロジェクトを作り、編集しながら動かし、単一バイナリにビルドするまでの最短ルートです。
**このページのコマンドは `zts` だけ**です。Z-Ts リポジトリの操作（`./zigw` や CI）は
[`../contributing/README.md`](../contributing/README.md) に分けてあります。

---

## 0. 前提

| 項目 | 要件 |
|---|---|
| `zts` | [`installing-zts.md`](installing-zts.md) の手順でチェックアウトからビルド |
| Zig | 0.17 系が `PATH` か `ZTS_ZIG` に（`zts` が子プロセスとして呼びます） |
| OS | Linux（GTK3 + WebKit2GTK 4.1）/ macOS / Windows |

```bash
zts version      # zts 0.1.0
zts doctor       # all checks passed なら準備完了
```

## 1. プロジェクトを作る

```bash
zts init my-app
cd my-app
```

生成されるのは 6 ファイルです。

```text
my-app/
├── build.zig          # 共通エンベッダで web/ を埋め込む
├── build.zig.zon      # Z-Ts への path 依存
├── src/main.zig       # アプリ本体（assets を列挙する最小構成）
├── web/index.html     # フロントエンド
├── .gitignore         # zig-out/ と .zig-cache/ を無視
└── README.md
```

`zts init` は生成直後に 1 回ビルドし、Zig が要求する `build.zig.zon` の
`.fingerprint` を自動で書き戻します。既存ディレクトリに書きたいときは `--force`、
パッケージ名を変えたいときは `--name my_app` を付けます。

> **雛形は「動く最小構成」です。** `zts build` すると `my_app: 1 embedded assets` のように
> 埋め込まれたアセットを列挙して終わります。ウィンドウを開くデスクトップアプリに育てるには
> [`../../examples/counter/README.md`](../../examples/counter/README.md) の
> `build.zig` と `src/main.zig` を出発点にしてください。

## 2. 編集しながら動かす（`zts dev`）

```bash
zts dev               # http://127.0.0.1:5173
```

`web/` を配信し、`web/` と `src/` の変更を 400 ms 間隔のフィンガープリントで監視して、
変わったら `zig build` を回して**ブラウザを自動リロード**します。

* `--browser` で起動時に既定ブラウザを開く
* `--host 0.0.0.0` でコンテナや LAN の外から見られる（Arena の Live Preview など）
* `--port 5199` でポート変更
* ビルドが失敗している間は**直前の成功物を配信し続け**、壊れた画面は出しません。
  現在の状態は次の 1 行で分かります。

```bash
curl http://127.0.0.1:5173/__zts_dev__/state
{"v":3,"ok":true}
```

`v` はビルドが成功するたびに増え、`ok` は直前のビルド結果です。`ok:false` のままなら
ターミナルに出ている Zig のエラーを直してください。

## 3. 単一バイナリにビルドする

```bash
zts build
# → zig-out/bin/my_app
```

`web/` の内容は**バイナリに埋め込まれます**（gzip 双子と CSP ハッシュ付き）。隣にアセット
ディレクトリを置く必要はありません。

```bash
zts build --target aarch64-macos    # クロスコンパイル
zts build --debug                  # Debug（既定は ReleaseSmall）
zts build --frontend-only          # web/ の再埋め込みだけ
```

`zts build` は `--target` / `--debug` / `--frontend-only` / `--dir` 以外のフラグを解釈しません。
`build.zig` のオプション（`-Dgtk=false` など）を使いたいときは、プロジェクト直下で
`zig build` を直接叩いてください。

## 4. つまずいたら `zts doctor`

```text
$ zts doctor
zts 0.1.0
  checkout     /home/you/Z-Ts
  z_ts         present
  zig          /tmp/zts-toolchains/zig/zig
  package      my_app
  dependency   ../../home/you/Z-Ts
  web/         present

all checks passed
```

`MISSING` が出た行がそのまま対処のヒントになります（詳細は
[`troubleshooting.md`](troubleshooting.md)）。

---

## ここから先

| 知りたいこと | 行き先 |
|---|---|
| 全コマンド・全オプション | [`../reference/cli.md`](../reference/cli.md) |
| 配布物（`.deb` / `.app` / `.exe`）を作る | [`packaging.md`](packaging.md) |
| RPC（`invoke`）と TypeScript 型生成 | [`using-rpc.md`](using-rpc.md) |
| Tauri 標準プラグイン | [`using-plugins.md`](using-plugins.md) |
| 静的サイト（SSG）とブラウザ実行 | [`using-ssg.md`](using-ssg.md) |
| Tauri v2 からの移行 | [`migrating-from-tauri.md`](migrating-from-tauri.md) |
| 動くサンプル 3 種 | [`../../examples/counter/README.md`](../../examples/counter/README.md) |
| API ページの読み方 | [`using-the-api-reference.md`](using-the-api-reference.md) |
| うまく動かないとき | [`troubleshooting.md`](troubleshooting.md) |
| Z-Ts 自体を開発する | [`../contributing/README.md`](../contributing/README.md) |
