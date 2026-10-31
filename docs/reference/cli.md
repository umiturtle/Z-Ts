# `zts` コマンドリファレンス

アプリ作者が使う CLI の仕様です。`zts` は **自分のプロジェクト**を操作します。

> **Z-Ts リポジトリ自体の操作**（`./zigw`、`zig build` のステップ、CI スクリプト）は
> [`../contributing/README.md`](../contributing/README.md) にまとめてあります。このページには
> 出てきません。

```text
zts <command> [options]

  init     Scaffold a new project
  dev      Serve `web/` with rebuild-on-change
  build    Build the app into a single executable
  doctor   Check the toolchain and the project
  help     Show this help
  version  Print the version
```

`zts help` はこの一覧を、`zts version` は `zts 0.1.0` のような 1 行を出力します。
引数なしで実行した場合も `help` と同じです。

終了コードは `0`（成功）と `1`（失敗）。`dev` は Ctrl-C まで動き続けます。

---

## `zts init [dir]`

最小構成のプロジェクトを生成します。生成直後に 1 回ビルドして、Zig が要求する
`build.zig.zon` の `.fingerprint` を拾い、その値を書き戻します。

| オプション | 既定 | 内容 |
|---|---|---|
| `[dir]`（位置引数） | `.` | 生成先。無ければ作成する |
| `--dir <path>` | — | 位置引数の代わり |
| `--name <name>` | ディレクトリ名 | Zig のパッケージ名（`[a-z][a-z0-9_]*`、最大 31 文字） |
| `--zts-path <path>` | `zts` をビルドしたチェックアウト | 生成する `build.zig.zon` の `.z_ts.path` に入れる値 |
| `--force` | 無効 | 既にファイルがあるディレクトリにも書く |

生成物:

```text
.gitignore  README.md  build.zig  build.zig.zon  src/main.zig  web/index.html
```

```bash
zts init my-app
zts init . --name my_app          # カレントに、パッケージ名を明示して
zts init my-app --force           # 既存ファイルがあっても書く
```

失敗する条件:

| 状況 | メッセージ |
|---|---|
| ディレクトリが空でなく `--force` 無し | `already has files — pass --force to write into it anyway` |
| ディレクトリ名がパッケージ名にできない | `cannot derive a package name from '…' — pass --name <name>` |
| パッケージ名が規約外 | `'…' is not a usable package name (…` |

生成される `build.zig` は `M5-01` の共通エンベッダを依存パッケージのソースから起動し、
`web/` を `embedded_frontend` モジュールとして埋め込みます。ステップは `run` と `frontend`
の 2 つです。

## `zts dev`

`web/` を HTTP で配信し、変更を検知してビルドし直し、ブラウザを自動リロードします。

| オプション | 既定 | 内容 |
|---|---|---|
| `--dir <path>` | `.` | プロジェクト |
| `--host <addr>` | `127.0.0.1` | バインドアドレス。`0.0.0.0` で外部公開 |
| `--port <n>` | `5173` | 1〜65535 |
| `--browser` / `--open` | 無効 | 起動後に既定ブラウザを開く |

仕様:

| 項目 | 振る舞い |
|---|---|
| 配信 | `web/` 配下の静的ファイル。`/` は `index.html`。`Cache-Control: no-store` |
| リロード | `</body>` の直前に 700 ms 間隔で `/__zts_dev__/state` を問い合わせるスクリプトを注入 |
| 監視 | `web/` と `src/` の **path + mtime + サイズ**のハッシュを 400 ms 間隔で比較（inotify / FSEvents は使わない） |
| 再ビルド | 変更検知で `zig build`。成功したときだけ `v` を進める |
| ビルド失敗 | 直前の成功物を配信し続け、`ok:false` を返す。`v` は据え置き |

```bash
zts dev
zts dev --port 5199 --host 0.0.0.0 --browser
curl http://127.0.0.1:5173/__zts_dev__/state    # {"v":3,"ok":true}
```

## `zts build`

プロジェクトをビルドし、生成された実行ファイルのパスを表示します。

| オプション | 既定 | 内容 |
|---|---|---|
| `--dir <path>` | `.` | プロジェクト |
| `--target <triple>` | ホスト | Zig のターゲット（例 `aarch64-macos`、`x86_64-windows-gnu`） |
| `--debug` | 無効 | `Debug` でビルド（既定は `ReleaseSmall`） |
| `--frontend-only` | 無効 | `build.zig` の `frontend` ステップだけ実行（`web/` の再埋め込み） |

```bash
zts build
zts build --debug
zts build --target aarch64-macos
zts build --frontend-only       # 100 ms 台
```

`zts build` は**解釈しないフラグを渡すとエラーにします**（黙って落とさない）。
`-Dgtk=false` のような `build.zig` のオプションは、プロジェクト直下で `zig build` を
直接叩いてください。Zig の stderr はそのまま中継されます。

## `zts doctor`

環境とプロジェクトを 6 項目で点検し、問題があれば `1` で終了します。

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

| 行 | 検査内容 | 失敗時 |
|---|---|---|
| `checkout` | `zts` をビルドしたチェックアウト | — |
| `z_ts` | そのパスが実在するか | `MISSING at … — rebuild zts or pass --zts-path` |
| `zig` | 使用する Zig のパス（`ZTS_ZIG` → `PATH` → チェックアウト内） | — |
| `package` | `build.zig.zon` の `.name` | `MISSING \`.name\` in build.zig.zon` |
| `dependency` | `.z_ts.path` が解決できるか | `… does not exist (resolved from …)` |
| `web/` | フロントエンドのディレクトリ | `missing — the embedder needs a front end` |

`--dir <path>` で対象プロジェクトを指定できます（他のフラグは受け付けません）。

## 環境変数

| 変数 | 内容 |
|---|---|
| `ZTS_ZIG` | 使用する `zig` のパス。未設定なら `PATH` → チェックアウト内の `zig` |

---

## 次に読むもの

- 使い始める: [`../guides/getting-started.md`](../guides/getting-started.md)
- `zts` の入手: [`../guides/installing-zts.md`](../guides/installing-zts.md)
- リポジトリ開発のコマンド: [`../contributing/README.md`](../contributing/README.md)
