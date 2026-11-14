"""Templates for the `todo-<id>.md` and `ui-<id>.md` branches (plus the shared Zig chapter).

The counter branches live in `gen-framework-tutorials.py` (they embed a verbatim excerpt of the
real example, rule 15). These two do not: `todo.md` and `ui.md` are the single source of the Zig
commands, so each branch is a *reading guide* that swaps only the frontend state idiom.

The shared `ZIG_LINKAGE_*` chapter is the part the user explicitly asked to cover properly:
local signals vs the Zig-owned counter, the SHA-256 seal, `ZIG OFFLINE` / `ZIG ONLINE`, the
`ipc://` commands, error handling and SSR guards.
"""

from __future__ import annotations

ZIG_LINKAGE_JA = '''ここが 3 本のチュートリアルで**一番大事な境界**です。画面に見えている値と、Zig が持っている値は
別の状態です。

| どこ | 誰が持つ | どう更新される |
|---|---|---|
| アプリのデータ | Zig の `State` | `addTodo` / `toggleTodo` / `removeTodo` などのコマンド |
| 画面に出る一覧・数 | {{STATE}} から作った {{LABEL}} の状態 | **`invoke` の戻り値で丸ごと差し替え** |
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

{{GUARD}}

{{SYNC}}

{{LABEL}} で Zig 所有カウンタを受け取るなら、こう書きます（`invoke` は `zts build` 後の
実行ファイルでだけ届きます）。

```{{FENCE}}
{{CODE_ZIG}}
```

> [!WARNING]
> {{PITFALL}}
'''

ZIG_LINKAGE_EN = '''This is the **most important boundary** in all three tutorials. The value on screen and the value
Zig owns are different state.

| Where | Owned by | Updated by |
|---|---|---|
| Application data | Zig's `State` | commands such as `addTodo` / `toggleTodo` / `removeTodo` |
| The list / number on screen | {{LABEL}} state built from {{STATE}} | **wholesale replacement from the `invoke` result** |
| The `.zigbar` counter | Zig's `zig_count` | `zig_inc` / `zig_dec` mutate it directly |

The nine examples deliberately run the counter body on **local state only**, so the 3-OS
screenshots match pixel for pixel. The `.zigbar` panel underneath is the opposite: it can never
be filled without Zig.

`zig_probe` / `zig_inc` / `zig_dec` are answered by Zig over `ipc://localhost/<command>` and
return `{ ok, count, seal }`. The gallery injects the same `window.__TAURI_INTERNALS__.invoke`
that the unmodified `@tauri-apps/api` v2 uses, at `DOCUMENT_START`, and puts `mount()` on
`window.__ZTS_ZIG__`. The `seal` is the first eight bytes of a SHA-256 over a **secret only the
Zig binary holds** plus the counter; the static HTML carries neither the secret nor the formula.
JavaScript cannot forge it, so `ZIG ONLINE` plus the 16-character seal is proof that Zig is alive.
A static build or the `zts dev` browser has no `window.__ZTS_ZIG__` and correctly stays at
`ZIG OFFLINE`.

The real wiring is in
[`examples/gallery/src/web/zig-bridge.js`](../../../../examples/gallery/src/web/zig-bridge.js)
and [`examples/gallery/src/main.zig`](../../../../examples/gallery/src/main.zig). To light it up in
your own app, add those three commands to `rpc.Schema` and inject the same bridge.

{{GUARD}}

{{SYNC}}

To receive the Zig-owned counter in {{LABEL}}, write this (`invoke` only reaches a backend from the
`zts build` executable):

```{{FENCE}}
{{CODE_ZIG}}
```

> [!WARNING]
> {{PITFALL}}
'''

TODO_JA = '''# チュートリアル: {{LABEL}} で Todo リストを作る

> **対象読者**: `{{LABEL}}` は使えるが ziggurats のコマンドは初めての人。
> **所要時間**: 20 分（写経すれば動くところまで）。
> **前提**: [カウンターを作る](counter.md)（10 分）を済ませていること。

これは [Todo リストを作る](todo.md) の **`{{LABEL}} {{VERSION}}` 版**です。Zig 側
（`State`・`addTodo` / `toggleTodo` / `removeTodo`・`error{}`・テスト）は **1 文字も変わりません**。
変わるのは `web/` の中身、つまり一覧の状態の持ち方と描き方だけです。
[ライブラリを選び直す](frameworks.md) といつでも別の分岐へ移れます。

<!-- framework-picker -->

| 章 | やること | 終わったとき |
|---|---|---|
| [0](#0-前提) | 前提の確認 | `zts doctor` が緑 |
| [1](#1-状態を読み替える) | 状態プリミティブを確認 | {{STATE}} が一覧になる |
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
| Node.js | `{{LABEL}}` を自分でビルドし直すときだけ |
| 元プロジェクト | [カウンターを作る](counter.md) で作った `my-app` をそのまま使う |

```bash
cd my-app
zts doctor       # all checks passed なら準備完了
```

## 1. 状態を読み替える

{{REACTIVITY}}

{{TODO_STATE}}

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

```{{FENCE}}
{{CODE_TODO}}
```

`refresh()` が `listTodos` を読み直し、追加・完了・削除のあとにも必ず呼ぶのがポイントです。
ローカルの配列に `push` して見た目だけ増やすと、Zig の `State` と食い違います。

## 4. 楽観更新しない

[画面を作る](ui.md#4-画面は「戻り値だけ」から描く) と同じ原則です。`invoke` が reject したら
**状態を書き換えず**、エラー表示に切り替えてください。{{SYNC}}

```{{FENCE}}
{{CODE_UI}}
```

## 5. 状態は 2 つある

'''  # ZIG_LINKAGE_JA (with SECTION=5) is appended by render()

TODO_JA_TAIL = '''
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
| 同じライブラリのカウンター | [{{LABEL}} でカウンター](counter-{{ID}}.md) |
| 同じライブラリの画面状態 | [{{LABEL}} で画面を作る](ui-{{ID}}.md) |
| 素の JS 版（分岐の元） | [Todo リストを作る](todo.md) |
| ライブラリを選び直す | [選択ハブ](frameworks.md) |
| `{{LABEL}}` の実物ソース | [`examples/frameworks/{{ID}}/`]({{TREE}}) |
| コマンドの引数・エラー・型生成 | [ガイド: コマンド](../guides/rpc.md) |
| 3 本の設計判断 | [実用パターン](../patterns/index.md) |
'''

TODO_EN = '''# Tutorial: build a Todo list with {{LABEL}}

> **Audience**: you know `{{LABEL}}` but are new to ziggurats commands.
> **Time**: 20 minutes (type it in and it runs).
> **Prerequisites**: [Build a counter](counter.md) (10 minutes).

This is the **`{{LABEL}} {{VERSION}}` version of [Build a Todo list](todo.md)**. The Zig side
(`State`, `addTodo` / `toggleTodo` / `removeTodo`, the `error{}` set and the tests) does not change
**by a single character**. Only `web/` changes: how the list state is held and rendered.
[Pick another library](frameworks.md) at any time.

<!-- framework-picker -->

| Chapter | What you do | When you are done |
|---|---|---|
| [0](#0-prerequisites) | check prerequisites | `zts doctor` is green |
| [1](#1-translate-the-state) | learn the state primitive | {{STATE}} holds a list |
| [2](#2-the-zig-side-is-shared) | copy the three commands | `zig check` passes |
| [3](#3-render-the-list) | render from `listTodos` | add / toggle / remove appear |
| [4](#4-no-optimistic-updates) | draw only from results | UI and Zig agree |
| [5](#5-two-states-local-and-zigs) | signals vs Zig | you can explain the seal |
| [6](#6-run-it) | `zts build` | a single binary |

---

## 0. Prerequisites

| Item | Requirement |
|---|---|
| `zts` | one release binary on `PATH`, per [`install.md`](../guides/install.md) |
| Zig | 0.17 on `PATH` or in `ZTS_ZIG` |
| Node.js | only if you rebuild `{{LABEL}}` yourself |
| Project | the `my-app` you made in [Build a counter](counter.md) |

```bash
cd my-app
zts doctor       # all checks passed
```

## 1. Translate the state

{{REACTIVITY}}

{{TODO_STATE}}

The plain-JS version used `let todos = []` and built HTML with
`innerHTML`; only that part is swapped here. **Zig's `State` is not swapped.**

## 2. The Zig side is shared

Copy the `zig check` block from [Build a Todo list](todo.md#2-write-three-commands) into
`src/main.zig`. All three commands, their arguments and the `error{}` set are identical in every
library. Short recap of the skeleton:

```zig
const Todo = struct { id: u32, title: []const u8, done: bool = false };
const State = struct { todos: std.ArrayList(Todo) = .empty };
const Commands = struct {
    pub fn listTodos(state: *State) ![]const Todo { return state.todos.items; }
    // addTodo / toggleTodo / removeTodo come from todo.md's zig check block
};
pub const Schema = rpc.Schema(.{ .app = Commands });
```

> [todo.md](todo.md) is the source of truth. The skeleton above only shows what is shared; copy the
> real `zig check` block when you type it in.

## 3. Render the list

```{{FENCE}}
{{CODE_TODO}}
```

`refresh()` re-reads `listTodos` and is called after **every** add / toggle / remove. Pushing into a
local array makes the UI drift away from Zig's `State`.

## 4. No optimistic updates

Same rule as [Build a screen](ui.md#4-draw-only-from-what-came-back): when `invoke` rejects, **do not
change state**, switch to the error view instead. {{SYNC}}

```{{FENCE}}
{{CODE_UI}}
```

## 5. Two states: local and Zig's

'''

TODO_EN_TAIL = '''
## 6. Run it

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # a window opens; adding a Todo reaches Zig
```

The `zts dev` browser alone cannot deliver `invoke`; always verify with the `zts build` executable.
`web/` is embedded with gzip twins and CSP hashes.

## Next

| Next question | Where |
|---|---|
| Counter in the same library | [Counter with {{LABEL}}](counter-{{ID}}.md) |
| Screen states in the same library | [Screen with {{LABEL}}](ui-{{ID}}.md) |
| Plain-JS original | [Build a Todo list](todo.md) |
| Pick another library | [Chooser hub](frameworks.md) |
| Real `{{LABEL}}` source | [`examples/frameworks/{{ID}}/`]({{TREE}}) |
| Command arguments, errors, TS generation | [Commands guide](../guides/rpc.md) |
| Why these three are shaped this way | [Patterns](../patterns/index.md) |
'''

UI_JA = '''# チュートリアル: {{LABEL}} で画面を作る

> **対象読者**: `{{LABEL}}` で画面を組み立てられる人。ziggurats の `invoke` は初めてでも構いません。
> **所要時間**: 20 分（写経すれば動くところまで）。
> **前提**: [Todo リストを作る](todo.md) を済ませていること。

これは [画面を作る](ui.md) の **`{{LABEL}} {{VERSION}}` 版**です。状態の境界・CSP・
`zts dev` の差し替えは **どのライブラリでも同じ**です。変わるのは「読み込み中 / 空 / エラー」を
{{LABEL}} の構文でどう出し分けるかだけです。[ライブラリを選び直す](frameworks.md) といつでも
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

{{REACTIVITY}}

{{UI_STATE}}

`ui.md` の素の JS 版では `let status = "loading"` と
`if / else` でしたが、ここではその部分だけを {{LABEL}} の流儀に読み替えます。
**Zig 側の `State` と `error{}` は共通**です。

## 2. 骨格と CSS は共通

[画面を作る](ui.md#2-html-の骨格) の `web/index.html` と `web/style.css` をそのまま置いてください。
`{{LABEL}}` を使う場合も **`data-zts` 属性名は変えません**。3 OS のスクリーンショット比較と
`.zigbar` パネルが同じ属性を参照するからです。

```bash
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/{{ID}}/. ./fw-{{ID}}/
# 必要なら {{BUILD}} で作り直す。出力先は {{DIST}}/
```

## 3. 状態をテンプレートで出し分ける

```{{FENCE}}
{{CODE_UI}}
```

`loading` から始めて、成功したときだけ `ready` / `empty` に進めます。プリレンダーや静的
書き出しでは HTML に初期値が焼き付くので、**Zig の値が届くまで `ZIG OFFLINE` を出したまま**
にするのが {{GUARD}} の理由です。

## 4. `invoke` の失敗を error にする

[画面を作る](ui.md#4-画面は「戻り値だけ」から描く) の原則どおり、`invoke` が reject したら
状態を書き換えず `error` に切り替えます。{{SYNC}}

一覧の再読込は Todo 版と同じです。

```{{FENCE}}
{{CODE_TODO}}
```

## 5. 状態は 2 つある

'''

UI_JA_TAIL = '''
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
| 同じライブラリのカウンター | [{{LABEL}} でカウンター](counter-{{ID}}.md) |
| 同じライブラリの Todo | [{{LABEL}} で Todo](todo-{{ID}}.md) |
| 素の JS 版（分岐の元） | [画面を作る](ui.md) |
| ライブラリを選び直す | [選択ハブ](frameworks.md) |
| `{{LABEL}}` の公開デモ | [ブラウザで開く]({{DEMO}}) |
| CSP と配布 | [ガイド: 静的サイト](../guides/static-site.md) |
| コマンドとエラーの設計 | [実用パターン](../patterns/index.md) |
'''

UI_EN = '''# Tutorial: build a screen with {{LABEL}}

> **Audience**: you can assemble a UI in `{{LABEL}}`; ziggurats `invoke` may be new.
> **Time**: 20 minutes (type it in and it runs).
> **Prerequisites**: [Build a Todo list](todo.md).

This is the **`{{LABEL}} {{VERSION}}` version of [Build a screen](ui.md)**. The state boundary, CSP
and the `zts dev` swap are **identical in every library**. What changes is only how
"loading / empty / error" is expressed in `{{LABEL}}` syntax.
[Pick another library](frameworks.md) at any time.

<!-- framework-picker -->

| Chapter | What you do | When you are done |
|---|---|---|
| [0](#0-prerequisites) | check prerequisites | `zts doctor` is green |
| [1](#1-hold-the-three-states-in-one-value) | learn the state primitive | four states in one value |
| [2](#2-the-skeleton-and-css-are-shared) | place HTML / CSS | the skeleton renders in `zts dev` |
| [3](#3-branch-in-the-template) | write conditionals | three screens switch |
| [4](#4-turn-invoke-failures-into-error) | draw only from results | UI and Zig agree |
| [5](#5-two-states-local-and-zigs) | signals vs Zig | you can explain the seal |
| [6](#6-run-it) | `zts build` | a single binary |

---

## 0. Prerequisites

Reuse the `my-app` from [Build a counter](counter.md) → [Build a Todo list](todo.md).

```bash
cd my-app
zts doctor       # all checks passed
```

## 1. Hold the three states in one value

{{REACTIVITY}}

{{UI_STATE}}

The plain-JS `ui.md` used `let status = "loading"` with `if / else`;
only that part is translated into `{{LABEL}}`'s idiom. **Zig's `State` and the `error{}` set are
shared.**

## 2. The skeleton and CSS are shared

Copy `web/index.html` and `web/style.css` from [Build a screen](ui.md#2-the-html-skeleton)
unchanged. Even with `{{LABEL}}`, **keep the `data-zts` attribute names**: the 3-OS screenshot
comparison and the `.zigbar` panel both read them.

```bash
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/{{ID}}/. ./fw-{{ID}}/
# rebuild with {{BUILD}} if needed; output goes to {{DIST}}/
```

## 3. Branch in the template

```{{FENCE}}
{{CODE_UI}}
```

Start at `loading` and move to `ready` / `empty` only on success. Prerendered and statically
exported HTML bakes in the initial value, which is why {{GUARD}} asks you to keep `ZIG OFFLINE`
visible until Zig's answer arrives.

## 4. Turn `invoke` failures into `error`

As in [Build a screen](ui.md#4-draw-only-from-what-came-back): on rejection, do not change the data
state — switch to the error view. {{SYNC}}

Re-reading the list is the same as in the Todo version:

```{{FENCE}}
{{CODE_TODO}}
```

## 5. Two states: local and Zig's

'''

UI_EN_TAIL = '''
## 6. Run it

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # a window opens; the three states switch
```

Inline scripts in `web/index.html` get a CSP hash at build time. `unsafe-inline` is unnecessary,
and a framework-generated `<script type="module">` is handled the same way.

## Next

| Next question | Where |
|---|---|
| Counter in the same library | [Counter with {{LABEL}}](counter-{{ID}}.md) |
| Todo in the same library | [Todo with {{LABEL}}](todo-{{ID}}.md) |
| Plain-JS original | [Build a screen](ui.md) |
| Pick another library | [Chooser hub](frameworks.md) |
| Live `{{LABEL}}` demo | [Open in a browser]({{DEMO}}) |
| CSP and shipping | [Static sites guide](../guides/static-site.md) |
| Command and error design | [Patterns](../patterns/index.md) |
'''
