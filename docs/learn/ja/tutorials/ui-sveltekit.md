# チュートリアル: SvelteKit で画面を作る

> **対象読者**: `SvelteKit` で画面を組み立てられる人。ziggurats の `invoke` は初めてでも構いません。
> **所要時間**: 20 分（写経すれば動くところまで）。
> **前提**: [Todo リストを作る](todo.md) を済ませていること。

これは [画面を作る](ui.md) の **`SvelteKit 3.1` 版**です。状態の境界・CSP・
`zts dev` の差し替えは **どのライブラリでも同じ**です。変わるのは「読み込み中 / 空 / エラー」を
SvelteKit の構文でどう出し分けるかだけです。[ライブラリを選び直す](frameworks.md) といつでも
別の分岐へ移れます。

<!-- framework-picker -->

| 章 | やること | 終わったとき |
|---|---|---|
| [0](#0-前提) | 前提の確認 | `zts doctor` が緑 |
| [1](#1-3-つの状態を-1-本で持つ) | 状態プリミティブを確認 | 4 状態を 1 本で表せる |
| [2](#2-骨格と-css-は共通) | HTML / CSS を置く | `zts dev` で骨格が出る |
| [3](#3-状態をテンプレートで出し分ける) | 条件分岐を書く | 3 つの画面が切り替わる |
| [4](#4-invoke-の失敗を-error-にする) | 戻り値だけから描く | Zig と画面が一致する |
| [5](#5-状態は-2-つある) | signal と Zig の境界 | seal の意味を説明できる |
| [6](#6-動かす) | `zts build` | 単一バイナリ |

---

## 0. 前提

[カウンターを作る](counter.md) → [Todo リストを作る](todo.md) で作った `my-app` をそのまま使います。

```bash
cd my-app
zts doctor       # all checks passed なら準備完了
```

## 1. 3 つの状態を 1 本で持つ

Svelte 5 の `let count = 0` / `$state(0)` は代入で直接 DOM を更新します。adapter-static のプリレンダーでは `0` が HTML に焼き付くので、クライアントの最初の `invoke` が実状態を作ります。

`{#if}` チェーンで 3 状態。プリレンダーでは `loading` を出し、ハイドレーション後に差し替えます。

`ui.md` の素の JS 版では `let status = "loading"` と
`if / else` でしたが、ここではその部分だけを SvelteKit の流儀に読み替えます。
**Zig 側の `State` と `error{}` は共通**です。

## 2. 骨格と CSS は共通

[画面を作る](ui.md#2-html-の骨格) の `web/index.html` と `web/style.css` をそのまま置いてください。
`SvelteKit` を使う場合も **`data-zts` 属性名は変えません**。3 OS のスクリーンショット比較と
`.zigbar` パネルが同じ属性を参照するからです。

```bash
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/sveltekit/. ./fw-sveltekit/
# 必要なら vite build で作り直す。出力先は build/
```

## 3. 状態をテンプレートで出し分ける

```svelte
let status: "loading" | "ready" | "empty" | "error" = $state("loading");

onMount(async () => {
  try {
    const list = await invoke<Todo[]>("listTodos");
    status = list.length ? "ready" : "empty";
  } catch (e) {
    status = "error";
  }
});
```

`loading` から始めて、成功したときだけ `ready` / `empty` に進めます。プリレンダーや静的
書き出しでは HTML に初期値が焼き付くので、**Zig の値が届くまで `ZIG OFFLINE` を出したまま**
にするのが `onMount` または `browser` でガードします。`+page.svelte` のモジュールスコープはプリレンダー時にサーバーで評価されます。`svelte.config.js` は不要で adapter は Vite に渡します。 の理由です。

## 4. `invoke` の失敗を error にする

[画面を作る](ui.md#4-画面は「戻り値だけ」から描く) の原則どおり、`invoke` が reject したら
状態を書き換えず `error` に切り替えます。`count = r.count` を `await` の後に 1 回。プリレンダー値との差が一瞬見えるので、`ZIG OFFLINE` の表示を消すのは seal が届いてからにしてください。

一覧の再読込は Todo 版と同じです。

```svelte
let todos: Todo[] = $state([]);

async function refresh() {
  todos = await invoke<Todo[]>("listTodos");
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // Zig から読み直す
}
// {#each todos as t (t.id)}<li>{t.title}</li>{/each}
```

## 5. 状態は 2 つある

ここが 3 本のチュートリアルで**一番大事な境界**です。画面に見えている値と、Zig が持っている値は
別の状態です。

| どこ | 誰が持つ | どう更新される |
|---|---|---|
| アプリのデータ | Zig の `State` | `addTodo` / `toggleTodo` / `removeTodo` などのコマンド |
| 画面に出る一覧・数 | `let count = 0` から作った SvelteKit の状態 | **`invoke` の戻り値で丸ごと差し替え** |
| `.zigbar` のカウンタ | Zig の `zig_count` | `zig_inc` / `zig_dec` が直接増減 |

9 つの example は 3 OS で画素を一致させるため、カウンター本体をわざと**ローカル状態だけ**で
動かしています。その下の `.zigbar` パネルは逆で、**Zig が動いていないと絶対に埋まりません**。

`zig_probe` / `zig_inc` / `zig_dec` は `ipc://localhost/<command>` を通して Zig が答え、
`{ ok, count, seal }` を返します。ギャラリーは無改造の `@tauri-apps/api` v2 と同じ
`window.__TAURI_INTERNALS__.invoke` を `DOCUMENT_START` で注入し、`window.__ZTS_ZIG__` に
`mount()` を置きます。`seal` は **Zig 側だけが持つ秘密**とカウンタから作る SHA-256 の先頭
8 バイトで、静的 HTML には秘密も計算式も入っていません。JavaScript だけでこの文字列を
でっち上げることはできないので、`ZIG ONLINE` と 16 桁の seal は「裏で Zig が生きている」
ことの証拠になります。`window.__ZTS_ZIG__` が無い静的ビルドや `zts dev` のブラウザでは
`ZIG OFFLINE` のままになるのが**正常**です。

配線の実物は
[`examples/gallery/src/web/zig-bridge.js`](../../../../examples/gallery/src/web/zig-bridge.js) と
[`examples/gallery/src/main.zig`](../../../../examples/gallery/src/main.zig) にあります。
自分のアプリで点灯させたいときは、この 3 コマンドを `rpc.Schema` に追加し、同じブリッジを
注入してください。

`onMount` または `browser` でガードします。`+page.svelte` のモジュールスコープはプリレンダー時にサーバーで評価されます。`svelte.config.js` は不要で adapter は Vite に渡します。

`count = r.count` を `await` の後に 1 回。プリレンダー値との差が一瞬見えるので、`ZIG OFFLINE` の表示を消すのは seal が届いてからにしてください。

SvelteKit で Zig 所有カウンタを受け取るなら、こう書きます（`invoke` は `zts build` 後の
実行ファイルでだけ届きます）。

```svelte
import { invoke } from "@tauri-apps/api/core";
import { onMount } from "svelte";

let zigCount = $state(0);
let seal = $state("—");

onMount(() => {
  const zig = window.__ZTS_ZIG__;   // プリレンダーでは触らない
  if (zig && typeof zig.mount === "function") zig.mount();
});

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  zigCount = r.count;
  seal = r.seal;
}
```

> [!WARNING]
> SSR 中に `window.__ZTS_ZIG__` を読むと `ReferenceError` になります。`browser` ガードを外さないでください。

## 6. 動かす

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # ウィンドウが開き、3 状態が切り替わる
```

`web/index.html` のインラインスクリプトにはビルド時に CSP ハッシュが付きます。
`unsafe-inline` は不要で、フレームワークが生成した `<script type="module">` も同じ扱いです。

## ここから先

| 次に知りたいこと | 行き先 |
|---|---|
| 同じライブラリのカウンター | [SvelteKit でカウンター](counter-sveltekit.md) |
| 同じライブラリの Todo | [SvelteKit で Todo](todo-sveltekit.md) |
| 素の JS 版（分岐の元） | [画面を作る](ui.md) |
| ライブラリを選び直す | [選択ハブ](frameworks.md) |
| `SvelteKit` の公開デモ | [ブラウザで開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/sveltekit/index.html) |
| CSP と配布 | [ガイド: 静的サイト](../guides/static-site.md) |
| コマンドとエラーの設計 | [実用パターン](../patterns/index.md) |

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
