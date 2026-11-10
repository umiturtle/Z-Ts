# チュートリアル: React でカウンターを作る

> **対象読者**: `React` は使えるが ziggurats は初めての人。Zig の基本文法は知っている前提です。
> **所要時間**: 15 分（写経すれば動くところまで）。
> **前提**: [はじめての ziggurats](../start.md)（10 分）を済ませていること。

これは [カウンターを作る](counter.md) の **`React 19.3` 版**です。Zig 側のコードは
元のチュートリアルと **1 文字も変わりません**。違うのは `web/` の中身だけで、そこに
[`examples/frameworks/react/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/react) の実物をそのまま使います。
[ライブラリを選び直す](frameworks.md) といつでも別の分岐へ移れます。

<!-- framework-picker -->

| 章 | やること | 終わったとき |
|---|---|---|
| [0](#0-前提) | 前提の確認 | `zts doctor` が緑 |
| [1](#1-example-を手に入れる) | 完成済み example を持ってくる | 静的出力が手元にある |
| [2](#2-ziggurats-プロジェクトに組み込む) | `zts init` → `web/` に置く | `zts dev` で画面が出る |
| [3](#3-実物のコンポーネントを読む) | example のソースを読む | 状態とボタンの場所が分かる |
| [4](#4-zig-のコマンドを足す) | `increment` を書く | `invoke("increment")` が通る |
| [5](#5-ボタンを-ipc-につなぐ) | `React` の流儀で `invoke` を呼ぶ | ボタン → Zig → 画面 |
| [6](#6-動かして配る) | `zts build` | 単一バイナリ |

---

## 0. 前提

| 項目 | 要件 |
|---|---|
| `zts` | [`install.md`](../guides/install.md) のとおり、Releases のバイナリ 1 個を `PATH` に |
| Zig | 0.17 系が `PATH` か `ZTS_ZIG` に |
| Node.js | `React` を自分でビルドし直すときだけ。完成済み出力を使うなら不要 |
| OS | Linux（GTK3 + WebKit2GTK 4.1）/ macOS / Windows |

```bash
zts doctor       # all checks passed なら準備完了
```

## 1. example を手に入れる

リポジトリには **ビルド済みの静的出力**がコミットされているので、ネットワーク無しで始められます。

```text
examples/frameworks/react/                 React のソース
examples/gallery/src/web/fw/react/         完成済みの静的出力（ここを使う）
```

```bash
# ziggurats のチェックアウトが隣にある場合
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/react/. ./fw-react/
ls fw-react/index.html
```

自分で作り直したいときだけ、ソース側でビルドします。出力先は `dist/` です。

```bash
cd /path/to/Z-Ts/examples/frameworks/react
npm install
npm run build        # vite build
ls dist/index.html
```

> [!NOTE]
> 9 つの example は**同じ DOM・同じ CSS・同じ文言**で作られています。違うのはフレームワーク名と
> バージョンだけなので、[公開デモ](https://umiturtle.github.io/ZigguraTs/examples/frameworks/react/index.html) を見比べれば「どれを選んでも同じアプリ」だと
> 確認できます。3 OS のスクリーンショット比較については
> [`examples/frameworks/README.md`](../../../../examples/frameworks/README.md) を参照してください。

## 2. ziggurats プロジェクトに組み込む

```bash
zts init my-app
cd my-app
rm -rf web
cp -R ../fw-react web
zts dev                 # http://127.0.0.1:5173
```

`web/` はそのまま配信され、`zts build` でバイナリに埋め込まれます。`React` の成果物を
`web/` に置くだけで、Zig 側の設定は何も変わりません（複数の chunk や `_next/` のような
サブディレクトリもそのまま辿れます）。

`zts dev` は `web/` の変更を 0.2 秒ほどでリロードします。**いまは Zig のアプリは動いていない**
ので、次の章で `invoke` を足したら `zts build` で確認してください。

## 3. 実物のコンポーネントを読む

以下は `examples/frameworks/react/src/main.jsx` の抜粋です（このページのコードはコミット済み example と機械的に
突き合わせています）。`useState` で数を持ち、`useEffect` でマウント完了を ziggurats に知らせる。

<!-- source: examples/frameworks/react/src/main.jsx -->
```jsx
      <section className="card">
        <div className="counter">
          <div className="value" data-zts="count">{count}</div>
          <button onClick={() => setCount(count - 1)} data-zts="dec">−</button>
          <button className="primary" onClick={() => setCount(count + 1)} data-zts="inc">＋</button>
        </div>
        <ul className="features">
```

状態は `useState(0)` です。カウンター本体は 3 OS で画素を一致させるため、あえて **ローカル状態だけ**
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

`React` では次のように書きます。`@tauri-apps/api` は**改造不要**です。

```jsx
import { invoke } from "@tauri-apps/api/core";

async function inc() { setCount(await invoke("increment")); }
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
| `React` の実物ソース | [`examples/frameworks/react/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/react) |
| `React` の公開デモ | [ブラウザで開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/react/index.html) |
| 9 つの example の比較 | [`examples/frameworks/README.md`](../../../../examples/frameworks/README.md) |
| コマンドの引数・エラー・型生成 | [ガイド: コマンド](../guides/rpc.md) |
