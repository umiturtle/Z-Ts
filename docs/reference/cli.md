# `zts` コマンドリファレンス

> **対象読者**: `zts` のコマンドとフラグを引く人。
> **所要時間**: 引きたいコマンドの節だけ。

アプリ作者が使う CLI の仕様です。`zts` は **自分のプロジェクト**を操作します。

> **Z-Ts リポジトリ自体の操作**（`./zigw`、`zig build` のステップ、CI スクリプト）は
> [`../contributing/README.md`](../contributing/README.md) にまとめてあります。このページには
> 出てきません。

```text
zts <command> [options]

  init     Scaffold a new project
  dev      Serve `web/` with rebuild-on-change
  build    Build the app into a single executable
  package  Wrap the executable into .deb / AppDir / .app / .exe / .tar.gz
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
| `--zts-path <path>` | 下記の「依存の書き方」 | 生成する `build.zig.zon` の `.z_ts.path` に入れる値。チェックアウトを持っている場合用 |
| `--zts-url <url>` | release ビルドが焼き込んだ公開アーカイブ | `.z_ts.url`。`--zts-hash` と**必ず**対で指定する |
| `--zts-hash <hash>` | — | `.z_ts.hash`（`zig fetch` が返す値） |
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

### 依存の書き方（`.z_ts`）

`zts init` は、生成したプロジェクトが Z-Ts をどこから取るかを `build.zig.zon` に 1 行で書きます。
**release としてビルドされた `zts`**（GitHub Releases のバイナリ）は公開アーカイブを指します。

```zig
.z_ts = .{ .url = "https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/z_ts-0.1.0.tar.gz", .hash = "z_ts-0.1.0-…" },
```

チェックアウトから `zig build` した `zts` は、そのチェックアウトへの相対パスを書きます。

```zig
.z_ts = .{ .path = "../../../home/you/Z-Ts" },
```

| 状況 | 何が書かれるか |
|---|---|
| 公開バイナリ | `.url` + `.hash`（バイナリに焼き込み済み。ネットワークが要る、チェックアウトは不要） |
| `--zts-url` と `--zts-hash` | 指定した `.url` + `.hash`（焼き込みより優先） |
| `--zts-path`、またはソースからビルドした `zts` | `.path`（ローカルのチェックアウト） |

`--zts-url` だけ、`--zts-hash` だけの指定は `IncompleteZtsRelease` で失敗します。片方だけでは
Zig が読めない `build.zig.zon` になるためです。

> `.url` 依存のプロジェクトは、初回の `zig build` でアーカイブを取得して Zig のキャッシュに
> 入れます。以降はオフラインでもビルドできます。

生成される `build.zig` は共通エンベッダを依存パッケージのソースから起動し、
`web/` を `embedded_frontend` モジュールとして埋め込みます。ステップは `run` と `frontend`
の 2 つです。

## `zts dev`

`web/` を HTTP で配信し、変更を検知して**必要な最小の更新だけ**を行います。

| オプション | 既定 | 内容 |
|---|---|---|
| `--dir <path>` | `.` | プロジェクト |
| `--host <addr>` | `127.0.0.1` | バインドアドレス。`0.0.0.0` で外部公開 |
| `--port <n>` | `5173` | 1〜65535 |
| `--browser` / `--open` | 無効 | 起動後に既定ブラウザを開く（`--open` は別名） |

### 何を更新するか

`zts dev` は `src/` と `web/` を 250 ms 間隔で走査し、**変わったファイル**から 1 つを選びます。

| 変わったもの | `zts dev` がすること | ブラウザ側 | 実測（この環境） |
|---|---|---|---|
| `web/**/*.css` だけ | **ビルドしない**。ブラウザに「css」と伝えるだけ | `<link rel="stylesheet">` を差し替え。**リロードしない**のでスクロール位置・入力中の値・コンソールが残る | 約 0.4 秒 |
| `web/` のその他（HTML / JS / 画像…） | **ビルドしない**（配信元はディスクなので、次に要求された時点で新しい） | ページをリロード | 約 0.4 秒 |
| `src/` のいずれか | `zig build` を実行（型エラーの検出） | 成功したらリロード、失敗したら直前の成功物のまま | 1〜2 秒（ウォーム時） |

> **なぜ `web/` の変更でビルドしないのか。** `zts dev` は `web/` をディスクから配信します。
> 埋め込み済みのコピーを作り直しても、プレビューには 1 バイトも影響しません。ビルドが要るのは
> Zig 側（`src/`）だけです。

> **`zts dev` はネイティブウィンドウを開きません。** プレビューはブラウザで `web/` を見るだけで、
> Zig のアプリプロセスは動いていません。`invoke` の往復まで確認するときは `zts build` して
> `zig-out/bin/<name>` を直接起動してください（[概念: コマンド](../learn/ja/concepts/commands.md)）。

### 仕様

| 項目 | 振る舞い |
|---|---|
| 配信 | `web/` 配下の静的ファイル。`/` は `index.html`。`Cache-Control: no-store` |
| 監視 | `web/` と `src/` の **path + mtime + サイズ**を 250 ms 間隔で比較（inotify / FSEvents は使わない。3 OS で同じ挙動） |
| まとめ | 変更を検知したら 120 ms 待って再走査し、保存中の連続書き込みを 1 回に畳む |
| リロード | `</body>` の直前に 700 ms 間隔で `/__zts_dev__/state` を問い合わせるスクリプトを注入 |
| CSS 差し替え | 既存の `<link>` の隣に `?zts=<v>` 付きの新しい `<link>` を作り、読み込み完了後に古い方を外す。失敗したら通常のリロードに落ちる |
| ビルド失敗 | 直前の成功物を配信し続け、`ok:false` を返す。`v` は据え置き |

```bash
zts dev
zts dev --port 5199 --host 0.0.0.0 --browser
curl http://127.0.0.1:5173/__zts_dev__/state    # {"v":3,"ok":true,"hot":"css"}
```

`v` は**成功した更新**のたびに増えます。`hot` は `"css"`（その場で差し替え）か `"full"`（リロード）
です。`ok` が `false` のままなら、ターミナルに出ている Zig のエラーを直してください。

## `zts build`

プロジェクトをビルドし、生成された実行ファイルのパスを表示します。

| オプション | 既定 | 内容 |
|---|---|---|
| `--dir <path>` | `.` | プロジェクト |
| `--target <triple>` | ホスト | Zig のターゲット（例 `aarch64-macos`、`x86_64-windows-gnu`） |
| `--debug` | 無効 | `Debug` でビルド（既定は `ReleaseSmall`） |
| `--release` | 有効 | `ReleaseSmall` を明示（既定値の再確認用。`--debug` と同時指定はエラー） |
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

## `zts package`

`zts build` が作った実行ファイルを、配布できる形に包みます。引数はすべて省略可能で、
既定では**ホスト OS の形式**（Linux: `deb` / macOS: `app` / Windows: `exe`）を 1 つ作ります。

```bash
zts package                                  # ホストの既定形式
zts package --format deb,appdir,tar.gz       # Linux の 3 形式を一度に
zts package --format exe --icon-ico app.ico --manifest app.manifest
zts package --icon icon.png --version 1.2.0 --maintainer "You <you@example.com>"
```

| オプション | 既定 | 内容 |
|---|---|---|
| `--dir <path>` | `.` | プロジェクト |
| `--format <list>` | ホストの既定 | カンマ区切り。`deb`, `appdir`, `app`, `dmg`, `exe`, `tar.gz` |
| `--binary <path>` | `zig-out/bin/<name>` | 包む実行ファイル（`--dir` からの相対） |
| `--out <path>` | `<dir>/zig-out/package` | 出力先 |
| `--version <semver>` | `build.zig.zon` の `.version` | パッケージ版 |
| `--identifier <id>` | `com.example.<name>` | 逆 DNS 識別子（macOS の `CFBundleIdentifier`） |
| `--maintainer <who>` | `ZTS_MAINTAINER`、無ければ placeholder | `Name <email>` |
| `--description <text>` | `<表示名> desktop application` | 1 行の説明 |
| `--icon <png>` | 無し | `.deb` / AppDir / `.app` 用の PNG（256×256 推奨） |
| `--icon-ico <ico>` | 無し | Windows 実行ファイルに埋める `.ico` |
| `--manifest <xml>` | 無し | Windows 実行ファイルに埋めるマニフェスト |

| 形式 | 出力（`<…>` は置換） | 中身 |
|---|---|---|
| `deb` | `<name>` を `-` 区切りにし `<name>_<version>_<arch>.deb` | `ar` + `control.tar.gz` + `data.tar.gz`。`dpkg-deb -c` で読める |
| `appdir` | `<name>-<version>-<arch>.AppDir/` | `AppRun` / `usr/bin/<name>` / `.desktop` / アイコン（AppImage の入力） |
| `app` | `<display>.app/` | `Contents/{Info.plist,PkgInfo,MacOS/<name>,Resources/<name>.png}` |
| `dmg` | `<display>-<version>.dmg` | `.app` を作ってから `hdiutil`（**macOS 専用**） |
| `exe` | `<name>.exe` | PE をそのままコピーし、`.rsrc` を 1 セクション追記 |
| `tar.gz` | `<name>-<version>-<arch>.tar.gz` | `<name>-<version>/` を丸ごと。どのホストからでも作れる |

仕様:

| 項目 | 振る舞い |
|---|---|
| アーキテクチャ | 実行ファイルのヘッダ（ELF / Mach-O / PE）から読む。クロスビルドでも正しく `arm64` などになる |
| `Depends:` | ELF が実際にリンクしている soname から作る。GUI を使わないアプリに GTK は付かない |
| 再現性 | `ar` メンバも tar エントリも mtime `0`、所有者 `0/0`。同じ入力からは同じバイト列 |
| 失敗時 | 何も書かずに終了コード `1`。形式と実行ファイルの不一致（PE に `deb` など）は事前に検出 |
| `License:` | `control` には書かない（Debian のバイナリ control に存在しないフィールド）。`copyright` に書く |

出力例:

```text
$ zts package --format deb,tar.gz --icon icon.png
zts: wrote ./zig-out/package/my_app_0.1.0_amd64.deb (65742 bytes)
zts: wrote ./zig-out/package/my-app-0.1.0-amd64.tar.gz (64911 bytes)
zts: packaged 2 artifact(s) into ./zig-out/package
```

インストール:

```bash
sudo dpkg -i zig-out/package/my_app_0.1.0_amd64.deb   # Debian/Ubuntu
tar -xzf zig-out/package/my-app-0.1.0-amd64.tar.gz    # どこでも
```

形式ごとの前提は [`../learn/ja/guides/package.md`](../learn/ja/guides/package.md) にまとめてあります。

## `zts doctor`

環境とプロジェクトを点検し、問題があれば `1` で終了します。**release の `zts` はチェックアウトを
持たない**ので、`checkout` / `z_ts` の 2 行が消え、代わりに `(none — release build)` と出ます。

```text
$ zts doctor                     # ソースからビルドした zts
zts 0.1.0
  checkout     /home/you/Z-Ts
  z_ts         present
  zig          /tmp/zts-toolchains/zig-0.17.0/ziglang/zig
  package      my_app
  dependency   ../../home/you/Z-Ts
  web/         present

all checks passed
```

```text
$ zts doctor                     # release の zts（チェックアウトを持たない）
zts 0.1.0
  checkout     (none — release build)
  zig          /usr/local/bin/zig
  package      my_app
  dependency   https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/z_ts-0.1.0.tar.gz (fetched by zig)
  web/         present

all checks passed
```

| 行 | 検査内容 | 失敗時 |
|---|---|---|
| `checkout` | `zts` をビルドしたチェックアウト。release ビルドでは `(none — release build)` | — |
| `z_ts` | そのパスが実在するか（release ビルドでは行ごと出ない） | `MISSING at … — rebuild zts or pass --zts-path` |
| `zig` | 使用する Zig のパス（`ZTS_ZIG` → `PATH` → チェックアウト内） | `MISSING — install Zig 0.17 on PATH or set ZTS_ZIG` |
| `package` | `build.zig.zon` の `.name` | `MISSING .name in build.zig.zon` |
| `dependency` | `.z_ts.path` が実在するか。`.z_ts.url` なら URL を出すだけで、取得は初回ビルド時 | `… does not exist (resolved from …)` |
| `web/` | フロントエンドのディレクトリ | `missing — the embedder needs a front end` |

`--dir <path>` で対象プロジェクトを指定できます。**それ以外のフラグは受け付けません** —
未知のフラグは `UnknownFlag` として拒否します（黙って無視しないので、綴り間違いに気付けます）。

## `zts --help` / `--version`

どのサブコマンドにも属さない全体フラグです。`help` / `-h`、`version` / `-V` も同じ意味で、
`zts`（引数なし）はヘルプを表示して終了コード 0 で終わります。

```bash
zts --help
zts --version
zts help          # 同上
```

## 環境変数

| 変数 | 内容 |
|---|---|
| `ZTS_ZIG` | 使用する `zig` のパス。未設定なら `PATH` → チェックアウト内の `zig`（release ビルドは `PATH` まで） |
| `ZTS_MAINTAINER` | `zts package` の `--maintainer` の既定値 |

---

## 次に読むもの

- 使い始める: [`../learn/ja/tutorials/counter.md`](../learn/ja/tutorials/counter.md)
- `zts` の入手: [`../learn/ja/guides/install.md`](../learn/ja/guides/install.md)
- 配布物の作り方: [`../learn/ja/guides/package.md`](../learn/ja/guides/package.md)
- リポジトリ開発のコマンド: [`../contributing/README.md`](../contributing/README.md)
