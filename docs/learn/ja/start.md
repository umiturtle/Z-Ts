# はじめての Z-Ts

> **対象読者**: Z-Ts をまだ 1 度も動かしたことがない人。Zig と Web の予備知識は問いません。
> **所要時間**: 10 分。**必要なもの**: ターミナル、Zig 0.17 系、`zts` のバイナリ（1 個）。
> **このページを終えると**: 自分のプロジェクトがブラウザで動き、`zig-out/bin/` に単一バイナリができます。

このページだけを上から順に打てば、Z-Ts の「動く」までを最短で通り抜けられます。
概念や設計の話はここではしません。**先に動かして、後から知る**のが Z-Ts の学び方です。

```text
① 用意する ──► ② 作る ──► ③ 動かす ──► ④ 書き換える ──► ⑤ バイナリにする
  zts を置く      zts init    zts dev      web/index.html     zts build
```

---

## 1. `zts` を用意する（3 分）

`zts` は Z-Ts でアプリを作る CLI です。配布物は**バイナリ 1 個**（約 300 KB、libc 非依存）で、
Zig だけは自分で用意します。

```bash
# 1) Zig 0.17 系を PATH に入れる（まだ無い場合）
zig version             # → 0.17.0

# 2) GitHub Releases から自分の OS の zts を落として PATH に置く
curl -LO https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/zts-0.1.0-linux-x86_64
chmod +x zts-0.1.0-linux-x86_64
mkdir -p ~/.local/bin
mv zts-0.1.0-linux-x86_64 ~/.local/bin/zts
export PATH="$HOME/.local/bin:$PATH"
zts version             # → zts 0.1.0
```

**チェックアウトの clone も `./zigw` も要りません。** `zts` は Zig を子プロセスで起動するだけです。
Windows の PowerShell 版や、Zig を `PATH` 以外に置いた場合の `ZTS_ZIG` は
[`guides/install.md`](guides/install.md) にまとめてあります。

> [!NOTE]
> Z-Ts 本体を直したい人・ソースから `zts` を作りたい人は `git clone` + `zig build` でも同じ
> ものが作れます（`./zigw` はそのリポジトリ専用のブートストラップで、配布物ではありません）。
> その場合、生成したプロジェクトはそのチェックアウトを `.path` 依存として指します。

## 2. 環境を点検する（1 分）

```bash
zts doctor
```

`all checks passed` が出れば準備完了です。`MISSING` が出たときの読み方は次のとおりです。

| 表示 | 意味 | 対処 |
|---|---|---|
| `zig          MISSING` | `zts` が Zig を見つけられない | Zig 0.17 を `PATH` に入れる。既にあるなら `export ZTS_ZIG=<その zig>` |
| `z_ts MISSING at …` | （ソースから作った `zts` だけ）チェックアウトが見つからない | そのパスに置くか `zts init --zts-path` |
| `gtk` / `webkit` の警告 | Linux の GUI ライブラリが無い | 開発だけなら無視してよい（後述） |

## 3. プロジェクトを作る（1 分）

```bash
cd ~
zts init my-app
cd my-app
```

`zts init` は 6 つのファイルを書き、**1 回だけビルドして** Zig が要求する
`build.zig.zon` の指紋を埋め戻します。書き出されるものはこれだけです。

| ファイル | 何か |
|---|---|
| `src/main.zig` | アプリ本体（最初は「埋め込んだファイルを数える」だけ） |
| `web/index.html` | 画面。`<style>` と `<script>` はインライン |
| `build.zig` / `build.zig.zon` | ビルド定義。`web/` を `embedded_frontend` として埋め込む |
| `README.md` / `.gitignore` | おまけ |

**画面と Zig の対応は、まだ 1 本もありません。** `web/` を配信し、ビルド時に埋め込む、
という土台だけが先にできています。この土台に「ボタン → Zig の関数」を載せるのが、
2 つ先の[アプリを作る](tutorials/counter.md)です。

## 4. 動かす（2 分）

```bash
zts dev
```

```text
zts: my_app — serving web/ at http://127.0.0.1:5173/
     watching src/ and web/ — Ctrl+C to stop
```

ブラウザで <http://127.0.0.1:5173/> を開くと、`my_app` の見出しと
「Edit `web/index.html`, then run `zts dev`.」が出ます。**これが最初の成功です。**

`zts dev` は次の 2 つを同時にやっています。

- `web/` を配信する（ビルドが失敗しても、直前の成功物を配信し続ける）
- `src/` と `web/` を見張り、**変わった種類に応じて最小の更新**をする

| 変えたもの | 何が起きるか | 待ち時間 |
|---|---|---|
| `web/index.html` や JS・画像 | ビルドせず、ページをリロード | 0.4 秒ほど |
| `web/style.css` | ビルドもリロードもせず、スタイルだけ差し替え（スクロール位置が残る） | 0.4 秒ほど |
| `src/` の Zig | `zig build` で型を検査してからリロード | 1〜2 秒 |

`zts dev --browser` を付けると、起動と同時に既定のブラウザが開きます。

## 5. 書き換えて、反映を見る（2 分）

`web/index.html` の `<h1>` を好きな文字に変えて保存してください。**ターミナルには触りません。**

```html
<h1>my_app — hello Z-Ts</h1>
```

保存から 0.5 秒ほどでブラウザがリロードされ、変更が反映されます（すでに開いているタブを
見ていれば、`zts dev` のターミナルは触らなくて構いません）。
これで「書く → 見る」のループが閉じました。ここから先はこのループを回すだけです。

## 6. 単一バイナリにする（1 分）

```bash
zts build
./zig-out/bin/my_app
```

```text
my_app: 1 embedded assets
  index.html (… bytes)
```

`zts build` は `ReleaseSmall` でビルドし、`web/` を**バイナリの中に**埋め込みます。
配布するときに隣に `web/` を置く必要はありません。`zts dev` を止めてから実行してください。

> [!TIP]
> Linux で GTK / WebKit2GTK の開発パッケージが無い場合、`zts build` は GUI バックエンドを
> 外してビルドします（`zig build -Dgtk=false` と同じ）。画面を出すアプリをビルドする段に
> なったら [`guides/install.md`](guides/install.md) の表に従って入れてください。

---

## ここまでで出来たこと

```text
✔ zts version             → zts 0.1.0
✔ zts doctor              → all checks passed
✔ zts init my-app         → 6 ファイル + 指紋の埋め戻し
✔ zts dev                 → ブラウザで my_app が見える
✔ web/index.html を編集   → 自動リロードで反映
✔ zts build               → zig-out/bin/my_app（web/ を内包）
```

## 次はどこへ

ここから先の 4 ステップ（このページを入れて 5 つ）は、常にページ上部の**学習パス**に出ています。
順番は自由です。
このまま [仕組みを知る](concepts/index.md) へ進むと、[アプリを作る](tutorials/counter.md) で
出てくる `Schema` と `invoke` に 15 分の地図を持って臨めます。**先に手を動かしたい**なら、
[アプリを作る](tutorials/counter.md) へ飛んでも構いません（詰まったら戻ってきてください）。

1. **[仕組みを知る](concepts/index.md)**（15 分）— 3 つの登場人物と、ボタンが Zig に届くまで
2. **[アプリを作る](tutorials/counter.md)**（15 分）— 自作コマンド、テスト、単一バイナリ
3. **[実用パターン](patterns/index.md)**（20 分）— コマンド・状態・エラーの設計と練習問題
4. **[目的から引く](guides/index.md)** — ここから先は必要なページだけ

用語で迷ったら [用語集](../../glossary.md)、動かないときは
[トラブルシューティング](guides/troubleshooting.md) と [エラー索引](../../reference/errors.html) へ。
