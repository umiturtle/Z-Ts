# チュートリアル: Astro でカウンターを作る

> **対象読者**: `Astro` は使えるが ziggurats は初めての人。Zig の基本文法は知っている前提です。
> **所要時間**: 15 分（写経すれば動くところまで）。
> **前提**: [はじめての ziggurats](../start.md)（10 分）を済ませていること。

これは [カウンターを作る](counter.md) の **`Astro 6.4` 版**です。Zig 側のコードは
元のチュートリアルと **1 文字も変わりません**。違うのは `web/` の中身だけで、そこに
[`examples/frameworks/astro/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/astro) の実物をそのまま使います。
[ライブラリを選び直す](frameworks.md) といつでも別の分岐へ移れます。

<!-- framework-picker -->

| 章 | やること | 終わったとき |
|---|---|---|
| [0](#0-前提) | 前提の確認 | `zts doctor` が緑 |
| [1](#1-example-を手に入れる) | 完成済み example を持ってくる | 静的出力が手元にある |
| [2](#2-ziggurats-プロジェクトに組み込む) | `zts init` → `web/` に置く | `zts dev` で画面が出る |
| [3](#3-実物のコンポーネントを読む) | example のソースを読む | 状態とボタンの場所が分かる |
| [4](#4-zig-のコマンドを足す) | `increment` を書く | `invoke("increment")` が通る |
| [5](#5-ボタンを-ipc-につなぐ) | `Astro` の流儀で `invoke` を呼ぶ | ボタン → Zig → 画面 |
| [6](#6-動かして配る) | `zts build` | 単一バイナリ |

---

## 0. 前提

| 項目 | 要件 |
|---|---|
| `zts` | [`install.md`](../guides/install.md) のとおり、Releases のバイナリ 1 個を `PATH` に |
| Zig | 0.17 系が `PATH` か `ZTS_ZIG` に |
| Node.js | `Astro` を自分でビルドし直すときだけ。完成済み出力を使うなら不要 |
| OS | Linux（GTK3 + WebKit2GTK 4.1）/ macOS / Windows |

```bash
zts doctor       # all checks passed なら準備完了
```

## 1. example を手に入れる

リポジトリには **ビルド済みの静的出力**がコミットされているので、ネットワーク無しで始められます。

```text
examples/frameworks/astro/                 Astro のソース
examples/gallery/src/web/fw/astro/         完成済みの静的出力（ここを使う）
```

```bash
# ziggurats のチェックアウトが隣にある場合
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/astro/. ./fw-astro/
ls fw-astro/index.html
```

自分で作り直したいときだけ、ソース側でビルドします。出力先は `dist/` です。

```bash
cd /path/to/Z-Ts/examples/frameworks/astro
npm install
npm run build        # astro build
ls dist/index.html
```

> [!NOTE]
> 9 つの example は**同じ DOM・同じ CSS・同じ文言**で作られています。違うのはフレームワーク名と
> バージョンだけなので、[公開デモ](https://umiturtle.github.io/ZigguraTs/examples/frameworks/astro/index.html) を見比べれば「どれを選んでも同じアプリ」だと
> 確認できます。3 OS のスクリーンショット比較については
> [`examples/frameworks/README.md`](../../../../examples/frameworks/README.md) を参照してください。

## 2. ziggurats プロジェクトに組み込む

```bash
zts init my-app
cd my-app
rm -rf web
cp -R ../fw-astro web
zts dev                 # http://127.0.0.1:5173
```

`web/` はそのまま配信され、`zts build` でバイナリに埋め込まれます。`Astro` の成果物を
`web/` に置くだけで、Zig 側の設定は何も変わりません（複数の chunk や `_next/` のような
サブディレクトリもそのまま辿れます）。

`zts dev` は `web/` の変更を 0.2 秒ほどでリロードします。**いまは Zig のアプリは動いていない**
ので、次の章で `invoke` を足したら `zts build` で確認してください。

## 3. 実物のコンポーネントを読む

以下は `examples/frameworks/astro/src/pages/index.astro` の抜粋です（このページのコードはコミット済み example と機械的に
突き合わせています）。アイランド無しの静的 HTML ＋ 小さな `<script>`。デフォルトで JS を送らない。

<!-- source: examples/frameworks/astro/src/pages/index.astro -->
```astro
  <section class="card">
    <div class="counter">
      <div class="value" data-zts="count">0</div>
      <button data-zts="dec">−</button>
      <button class="primary" data-zts="inc">＋</button>
    </div>
    <ul class="features">
```

状態は DOM を直接更新（`data-zts`） です。

アイランドを置かず、静的 HTML ＋小さな `<script>` だけで動かします。状態は変数ではなく **DOM の `data-zts` 属性**にあり、`textContent` を書き換えるのが唯一の更新手段です。

カウンター本体は 3 OS で画素を一致させるため、あえて **ローカル状態だけ**
で動かしています。その下の `.zigbar` パネルは逆で、**Zig が動いていないと絶対に埋まりません**
（[付録](#付録-zig-が動いているかを画面で確かめる)）。次の章でここに ziggurats のコマンドを
つなぎます。

## 4. Zig のコマンドを足す

**ここは全ライブラリ共通**です。[カウンターを作る](counter.md#3-数えるコマンドを書く) の
`zig check` ブロックをそのまま `src/main.zig` に写してください。古い API を書くと CI が赤くなる
ようになっているので、元チュートリアルのコードだけが唯一の正本です。

```zig
const State = struct { count: i32 = 0 };
const Commands = struct {
    pub fn increment(state: *State) !i32 {
        state.count += 1;
        return state.count;
    }
};
pub const Schema = rpc.Schema(.{ .app = Commands });
```

アプリ側は状態を作って `bind` するだけです。

```zig
var state = State{};
var router = Schema.bind(.{ .app = &state });
const handler = router.handler();
```

## 5. ボタンを IPC につなぐ

`Astro` では次のように書きます。`@tauri-apps/api` は**改造不要**です。

```astro
import { invoke } from "@tauri-apps/api/core";

const value = document.querySelector('[data-zts="count"]');
document.querySelector('[data-zts="inc"]').addEventListener("click", async () => {
  value.textContent = await invoke("increment");
});
```

`Astro` のローカル状態と、Zig が持つカウンタは **別の状態** です
（[付録](#付録-zig-が動いているかを画面で確かめる)）。`value.textContent = String(r.count)` は `await` の後に 1 回だけ。フレームワークの再レンダリングが無いので、書き換え順がそのまま画面に出ます。Zig が居ない静的ビルドでは `invoke` を呼ばず `ZIG OFFLINE` を保ってください。

ギャラリーの `zig_inc` を同じ状態に流し込むなら、こう書きます。

```astro
import { invoke } from "@tauri-apps/api/core";

const value = document.querySelector('[data-zts="count"]');
const seal = document.querySelector('[data-zts="zig-seal"]');
const inc = document.querySelector('[data-zts="zig-inc"]');
if (!value || !seal || !inc) throw new Error("counter markup missing");

inc.addEventListener("click", async () => {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  value.textContent = String(r.count);   // Zig の戻り値だけを正にする
  seal.textContent = r.seal;
});
```

これで「ボタン → `invoke("increment")` → Zig の関数 → 戻り値 → 画面」が 1 周します。
`zts dev` のブラウザだけを見ていると `invoke` は届かないので、必ず `zts build` 後の
実行ファイルで確かめてください。

> [!NOTE]
> `web/index.html` のインラインスクリプトにはビルド時に CSP ハッシュが付きます。
> `unsafe-inline` は不要です。フレームワークが生成した `<script type="module">` も同じ扱いです。

## 6. 動かして配る

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # ウィンドウが開き、+1 が Zig まで届く
```

`web/` は gzip 双子・CSP ハッシュ付きでバイナリに埋め込まれるので、隣にアセットディレクトリは
要りません。

## 付録: Zig が動いているかを画面で確かめる

9 つの example はどれも同じ `.zigbar` パネルを持っています。ここだけは **Zig が無いと成立しません**。

| 見た目 | 裏で起きていること |
|---|---|
| 赤い `ZIG OFFLINE`・`＋` `−` が無効 | 静的 HTML だけ（公開デモ、`zts dev` のブラウザ）。`window.__ZTS_ZIG__` が無い |
| 緑の `ZIG ONLINE`・16 桁の seal・`＋` `−` が有効 | Zig のバイナリが `zig_probe` / `zig_inc` / `zig_dec` に答えている |

seal は **Zig 側だけが持つ秘密**と Zig のカウンタから作る SHA-256 の先頭 8 バイトです。静的
ファイルには秘密も計算式も入っていないので、JavaScript だけでこの文字列をでっち上げることは
できません。`＋` `−` はフレームワークのローカル状態ではなく **Zig が保持するカウンタ**を増減し、
押すたびに seal が変わります。つまりこの 1 行が「裏で Zig が生きているか」の答えです。

Astro はデフォルトで JS を送りません。`<script>` はビルド時にバンドルされ、`window.__ZTS_ZIG__` はネイティブホストが `DOCUMENT_START` で注入したときだけ存在します。

> [!WARNING]
> ``querySelector` が `null` を返したときのガードを忘れると、静的 HTML を単体で開いた瞬間に `TypeError` になります。`if (!value) return;` を必ず入れてください。`

配線の実物は
[`examples/gallery/src/web/zig-bridge.js`](../../../../examples/gallery/src/web/zig-bridge.js) と
[`examples/gallery/src/main.zig`](../../../../examples/gallery/src/main.zig) にあります。ギャラリーは
無改造の `@tauri-apps/api` v2 と同じ `window.__TAURI_INTERNALS__.invoke` を `DOCUMENT_START` で
注入し、`ipc://localhost/<command>` を Zig で捌きます。自分のアプリで点灯させたいときは、この
3 コマンドを `rpc.Schema` に追加し、同じブリッジを注入してください。カウンター本体を IPC に
つなぐ手順は [5 章](#5-ボタンを-ipc-につなぐ) のとおりです。

## ここから先

| 次に知りたいこと | 行き先 |
|---|---|
| 別のライブラリで同じチュートリアル | [ライブラリを選ぶ](frameworks.md) |
| 素の JS 版（分岐の元） | [カウンターを作る](counter.md) |
| 状態を増やす・失敗を返す | [Todo リストを作る](todo.md) |
| 読み込み中 / 空 / エラーの画面 | [画面を作る](ui.md) |
| `Astro` 版の Todo | [Todo を Astro で](todo-astro.md) |
| `Astro` 版の画面 | [画面を Astro で](ui-astro.md) |
| `Astro` の実物ソース | [`examples/frameworks/astro/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/astro) |
| `Astro` の公開デモ | [ブラウザで開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/astro/index.html) |
| 9 つの example の比較 | [`examples/frameworks/README.md`](../../../../examples/frameworks/README.md) |
| コマンドの引数・エラー・型生成 | [ガイド: コマンド](../guides/rpc.md) |
