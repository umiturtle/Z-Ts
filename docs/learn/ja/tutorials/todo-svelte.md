# チュートリアル: Svelte で Todo リストを作る

> **対象読者**: `Svelte` は使えるが ziggurats のコマンドは初めての人。
> **所要時間**: 20 分（写経すれば動くところまで）。
> **前提**: [カウンターを作る](counter.md)（10 分）を済ませていること。

これは [Todo リストを作る](todo.md) の **`Svelte 5.57` 版**です。Zig 側
（`State`・`addTodo` / `toggleTodo` / `removeTodo`・`error{}`・テスト）は **1 文字も変わりません**。
変わるのは `web/` の中身、つまり一覧の状態の持ち方と描き方だけです。
[ライブラリを選び直す](frameworks.md) といつでも別の分岐へ移れます。

<!-- framework-picker -->

| 章 | やること | 終わったとき |
|---|---|---|
| [0](#0-前提) | 前提の確認 | `zts doctor` が緑 |
| [1](#1-状態を読み替える) | 状態プリミティブを確認 | `let count = 0` が一覧になる |
| [2](#2-zig-側は共通) | 3 つのコマンドを写す | `zig check` が通る |
| [3](#3-一覧を描く) | `listTodos` から描く | 追加・完了・削除が画面に出る |
| [4](#4-楽観更新しない) | 戻り値だけから描く | Zig と画面が一致する |
| [5](#5-状態は-2-つある) | signal と Zig の境界 | seal の意味を説明できる |
| [6](#6-動かす) | `zts build` | 単一バイナリ |

---

## 0. 前提

| 項目 | 要件 |
|---|---|
| `zts` | [`install.md`](../guides/install.md) のとおり、Releases のバイナリ 1 個を `PATH` に |
| Zig | 0.17 系が `PATH` か `ZTS_ZIG` に |
| Node.js | `Svelte` を自分でビルドし直すときだけ |
| 元プロジェクト | [カウンターを作る](counter.md) で作った `my-app` をそのまま使う |

```bash
cd my-app
zts doctor       # all checks passed なら準備完了
```

## 1. 状態を読み替える

Svelte 5 の例は `let count = 0` で、代入がそのままリアクティブです（必要なら `$state(0)`）。コンパイラが代入箇所を直接 DOM 更新に変換するので、仮想 DOM も再レンダリングもありません。

`let todos: Todo[] = $state([])` と `{#each todos as t (t.id)}` のキー付き each を使います。代入で差し替えるので `push` より `todos = next` が確実です。

素の JS 版では `let todos = []` と `innerHTML` の組み立てでしたが、
ここではその部分だけを置き換えます。**Zig の `State` は置き換えません**。

## 2. Zig 側は共通

[Todo リストを作る](todo.md#2-コマンドを-3-つ書く) の `zig check` ブロックをそのまま
`src/main.zig` に写してください。3 つのコマンドと引数、返す `error{}` は全ライブラリで同一です。
短く再掲すると、骨格はこれだけです。

```zig
const Todo = struct { id: u32, title: []const u8, done: bool = false };
const State = struct { todos: std.ArrayList(Todo) = .empty };
const Commands = struct {
    pub fn listTodos(state: *State) ![]const Todo { return state.todos.items; }
    // addTodo / toggleTodo / removeTodo は todo.md の zig check ブロックを写す
};
pub const Schema = rpc.Schema(.{ .app = Commands });
```

> コードの正本はあくまで [todo.md](todo.md) です。上の骨格は「どこが共通か」を示す抜粋なので、
> 写経するときは元チュートリアルの `zig check` ブロックを使ってください。

## 3. 一覧を描く

```svelte
let todos: Todo[] = $state([]);

async function refresh() {
  todos = await invoke<Todo[]>("listTodos");
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // 代入で丸ごと差し替える
}
// {#each todos as t (t.id)}<li>{t.title}</li>{/each}
```

`refresh()` が `listTodos` を読み直し、追加・完了・削除のあとにも必ず呼ぶのがポイントです。
ローカルの配列に `push` して見た目だけ増やすと、Zig の `State` と食い違います。

## 4. 楽観更新しない

[画面を作る](ui.md#4-画面は「戻り値だけ」から描く) と同じ原則です。`invoke` が reject したら
**状態を書き換えず**、エラー表示に切り替えてください。`count = r.count` は `await` の後に 1 回だけ代入します。代入が即座に画面へ効くため、`invoke` 前に `count += 1` と書くと一瞬だけ Zig と食い違った値が見えます。

```svelte
let status: "loading" | "ready" | "empty" | "error" = $state("loading");

async function load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    status = list.length ? "ready" : "empty";
  } catch (e) {
    status = "error";
  }
}
// {#if status === "error"}<p class="error">…</p>{/if}
```

## 5. 状態は 2 つある

ここが 3 本のチュートリアルで**一番大事な境界**です。画面に見えている値と、Zig が持っている値は
別の状態です。

| どこ | 誰が持つ | どう更新される |
|---|---|---|
| アプリのデータ | Zig の `State` | `addTodo` / `toggleTodo` / `removeTodo` などのコマンド |
| 画面に出る一覧・数 | `let count = 0` から作った Svelte の状態 | **`invoke` の戻り値で丸ごと差し替え** |
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

`onMount` 内でだけ `window` を触ります。`.svelte` の `<script>` はビルド時に評価されることがあるので、トップレベルで bridge を参照しないでください。

`count = r.count` は `await` の後に 1 回だけ代入します。代入が即座に画面へ効くため、`invoke` 前に `count += 1` と書くと一瞬だけ Zig と食い違った値が見えます。

Svelte で Zig 所有カウンタを受け取るなら、こう書きます（`invoke` は `zts build` 後の
実行ファイルでだけ届きます）。

```svelte
import { invoke } from "@tauri-apps/api/core";

let zigCount = $state(0);
let seal = $state("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  zigCount = r.count;     // await の後に 1 回だけ代入
  seal = r.seal;
}
```

> [!WARNING]
> 配列を `todos.push(x)` で増やしても代入が無いと Svelte 5 の `$state` でも追跡されないことがあります。必ず `todos = [...todos, x]` か再読込で差し替えてください。

## 6. 動かす

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # ウィンドウが開き、Todo の追加が Zig まで届く
```

`zts dev` のブラウザだけを見ていると `invoke` は届きません。必ず `zts build` 後の実行ファイルで
確かめてください。`web/` は gzip 双子・CSP ハッシュ付きでバイナリに埋め込まれます。

## ここから先

| 次に知りたいこと | 行き先 |
|---|---|
| 同じライブラリのカウンター | [Svelte でカウンター](counter-svelte.md) |
| 同じライブラリの画面状態 | [Svelte で画面を作る](ui-svelte.md) |
| 素の JS 版（分岐の元） | [Todo リストを作る](todo.md) |
| ライブラリを選び直す | [選択ハブ](frameworks.md) |
| `Svelte` の実物ソース | [`examples/frameworks/svelte/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/svelte) |
| コマンドの引数・エラー・型生成 | [ガイド: コマンド](../guides/rpc.md) |
| 3 本の設計判断 | [実用パターン](../patterns/index.md) |
