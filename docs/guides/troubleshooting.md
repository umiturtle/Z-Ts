# トラブルシューティング（アプリ開発）

`zts` でアプリを作っていて詰まったときの 1 ページです。**Z-Ts リポジトリ自体のビルド**で
詰まった場合は [`../contributing/troubleshooting.md`](../contributing/troubleshooting.md) へ
（そちらは `./zigw` と CI の話で、アプリ作者には不要です）。

---

## まず実行するもの

```bash
zts doctor            # 環境・依存・web/ をまとめて点検（問題なければ "all checks passed"）
zts build             # 素のビルドが通るか（dev サーバを挟まない）
```

`doctor` が `MISSING` を 1 つも出さなければ、失敗はあなたのプロジェクトのコード側です。
`zts doctor --dir path/to/app` でプロジェクトを指定できます。

---

## `zts init`

### `'…' already has files — pass --force to write into it anyway`

`zts init` は**空のディレクトリ**にだけ雛形を書きます。既存プロジェクトに重ねると
`src/main.zig` や `web/index.html` を上書きするため、明示的に `--force` が要ります。

```bash
zts init my-app --force
```

`.git` や `node_modules` があるだけのディレクトリでも同じメッセージが出ます。
`zts build.zig.zon` を残したいなら、先に退避してください。

### `cannot derive a package name from '…' — pass --name <name>`

ディレクトリ名が Zig のパッケージ名になれないとき（ハイフン・先頭数字・大文字・非 ASCII）に
出ます。パッケージ名は `[a-z][a-z0-9_]*` で最大 31 文字です。

```bash
zts init "my-app" --name my_app      # 表示名は my-app、パッケージ名は my_app
```

### `warning — could not read the fingerprint Zig suggested`

`zts init` は生成直後に 1 回ビルドし、Zig が「この値を使ってください」と出す
`build.zig.zon` の fingerprint を拾って書き戻します。この警告が出た場合も**失敗ではありません**。
次の `zts build` が同じ値をもう一度出力し、`zts build` が自動で書き戻します。

`error: invalid fingerprint: 0x…` が消えない場合は `build.zig.zon` の `.fingerprint` 行を
エラーメッセージが示した値に置き換えてください（上位 32 bit はパッケージ名から決まり、
下位 32 bit は fork 識別子で毎回変わってかまいません）。

### 生成された `build.zig.zon` の `.z_ts.path` が `../../../` になる

`zts` は**自分をビルドしたチェックアウト**を相対パスで指します（例:
`../../../home/user/Z-Ts`）。これは絶対パスが Zig に拒否されるためです。次のいずれかで直せます。

* そのままでよい（同じマシンで使い続ける限り動く）
* `zts init … --zts-path <checkout>` で生成し直す
* `build.zig.zon` の `.path` を、あなたの環境でのチェックアウトへの相対パスに書き換える

`zts` を別の場所へ移した場合は `zts doctor` が
`z_ts MISSING at … — rebuild zts or pass --zts-path` と教えます。

---

## `zts build`

### `cannot read <dir>/build.zig.zon — is this a Z-Ts project?`

`--dir` の指す先がプロジェクトではありません。`zts init` をしたディレクトリで実行するか、
`--dir` を正しく渡してください。

### `could not run zig …` / `set ZTS_ZIG to the zig binary if it is not on PATH`

`zts build` は Zig を子プロセスとして起動します。`zts` をビルドしたのと同じバージョン
（0.17 系）を `PATH` に置くか、`ZTS_ZIG=/path/to/zig` を設定してください。

```bash
ZTS_ZIG=/tmp/zts-toolchains/zig/zig zts build
```

### `zig build failed` の後、何も表示されない

`zts` は Zig の stderr を**そのまま**流します（加工しません）。`zig build 2>&1 | head -40`
と同じ内容が出ているはずなので、最初の `error:` 行を読みます。

### フロントエンドだけ作り直したい

```bash
zts build --frontend-only      # build.zig の "frontend" ステップだけ（100 ms 台）
```

`web/` を書き換えたがネイティブ側を再コンパイルしたくないときに使います。

### 追加の `zig build` オプションを渡したい

`zts build` は `--target` / `--debug` / `--frontend-only` / `--dir` だけを解釈します
（それ以外は `unknown flag` で止まります）。`-Dgtk=` のような `build.zig` のオプションは、
プロジェクトのディレクトリで Zig を直接呼びます。

```bash
cd my-app && zig build -Dgtk=false
```

### `error: invalid fingerprint: 0x…`

上記「`warning — could not read the fingerprint…`」を参照。

### GTK / WebKit2GTK のヘッダが見つからない（Linux）

```bash
sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev
```

`zts build` は Zig のオプションをそのまま受け取らないので、細かい制御は `zig build` を直接
叩いてください（下記「追加の `zig build` オプション」）。

---

## `zts dev`

### `cannot listen on 127.0.0.1:5173`（`AddressInUse`）

前回の `zts dev` が残っているか、他のプロセスが使っています。ポートを変えます。

```bash
zts dev --port 5199
```

`--host 0.0.0.0` で LAN やコンテナの外からも見られます（Arena の Live Preview など）。

### 画面が真っ白 / `web/` が無いと言われる

`zts dev` は `web/` を配信し、`</body>` の直前にライブリロード用スクリプトを差し込みます。
`web/index.html` が無いと起動時に
`web/ does not exist — zts init puts the front end there` で止まります。

### 編集してもリロードされない

* 監視対象は `web/` と `src/` の**mtime + サイズ**です（inotify / FSEvents は使いません）。
  ファイルを保存したが mtime が変わらないツール（一部のエディタの atomic save）では
  検知できないことがあります。一度タッチしてください。
* ポーリングの状態は `curl http://127.0.0.1:5173/__zts_dev__/state` で確認できます。
  `{"v":3,"ok":true}` の `v` が増えていれば検知されています。
* `ok:false` のままなら**ビルドが失敗しています**。`zts dev` は直前の成功物を配信し続け、
  `v` を進めません（壊れたアプリを表示しないため）。ターミナルに出ている Zig のエラーを直します。

### リロードのたびにキャッシュが効かない

`zts dev` は `Cache-Control: no-store` を返します。ビルド後に古い画面が残るときは、
ブラウザの強制リロードではなく `state` の `v` を確認してください。

---

## 実行・ネイティブ WebView

### `zts init` したアプリは何も表示せず、アセット数だけ出る

これは仕様です。`zts init` の雛形は**フロントエンドの埋め込みが動くこと**を示す最小構成で、
`<name>: 1 embedded assets` のような行を出して終わります。ウィンドウを開く
デスクトップアプリにするには、`examples/counter` の `build.zig` と `src/main.zig` を出発点に
`zts_tauri` の `App` / `zts_webview` のバックエンドを組み込みます
（[`../../examples/counter/README.md`](../../examples/counter/README.md)）。

### Linux で文字が豆腐になる / OS ごとに表示が違う

Z-Ts はフォントを同梱し、OS 間で同じ字形になるようにしています。独自 CSS でシステム
フォント（`system-ui` など）を指定すると Linux だけ字形が変わります。同梱の
`ZTS Sans` / `ZTS Mono` を使ってください。

### スクリーンショットを撮ると真っ黒（CI / Xvfb）

ソフトウェアレンダリングを強制します。

```bash
WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 \
ZTS_WEBVIEW_SOFTWARE_RENDER=1 \
xvfb-run -a ./zig-out/bin/my-app
```

### macOS / Windows でネイティブ WebView が使われない

`zts_webview` は対象ターゲットからバックエンドを決めます（Linux: GTK、macOS: Cocoa、
Windows: Win32）。Linux で GTK3 / WebKit2GTK 4.1 が無い場合は `HeadlessMock` に
フォールバックするので、`pkg-config --exists webkit2gtk-4.1 gtk+-3.0` で確認してください。

---

## フロントエンド

### `bindings.gen.ts` と `@tauri-apps/api` の型が合わない

`@tauri-apps/api` は**無改変**で同梱しています。生成された `bindings.gen.ts` のコマンド名が
スキーマと一致しているか確認してください（`plugin:fs|read_text_file` のように
`plugin:` 接頭辞まで含めて一致が必要です）。スキーマを変えたら生成し直します。

```bash
cd my-app && zig build tsgen     # build.zig に tsgen ステップを足してから
```

`zts init` の雛形にはスキーマがまだ無いため `tsgen` ステップは入っていません。
`examples/counter/build.zig` の `tsgenBindings` 呼び出しを参考に追加します。

### Vite の出力を埋め込んだら真っ白

複数チャンクの ES モジュールを 1 つの `<script type="module">` にインライン化すると
`import "./chunk.js"` が解決できません。`zts build` は `web/` を**ディレクトリごと**埋め込み、
`/assets/…` の相対解決は `zts_web.Assets` に任せます。`web/` の外に Vite の出力を置かず、
`base` を相対（`./`）に設定してください。

---

## `zts package`

配布物まわりのエラーは、形式ごとの前提（`dmg` は macOS だけ、`exe` は PE だけ、など）に
起因するものがほとんどです。メッセージ別の表は
[`packaging.md`](packaging.md#9-つまずきどころ) にまとめてあります。

---

## 次に読むもの

- 使い方の全体像: [`getting-started.md`](getting-started.md)
- 配布物を作る: [`packaging.md`](packaging.md)
- `zts` の全オプション: [`../reference/cli.md`](../reference/cli.md)
- エラーに対応する API の引き方: [`using-the-api-reference.md`](using-the-api-reference.md)
- Z-Ts 本体の開発で詰まったとき: [`../contributing/troubleshooting.md`](../contributing/troubleshooting.md)
