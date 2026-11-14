#!/usr/bin/env python3
"""Generate the branched tutorials from the committed framework examples.

One catalog (`src/docsite/frameworks.json`) drives the docsite picker and rule 15; the per-library
teaching text lives in `framework_tutorial_profiles.py` and the two extra tutorial templates in
`framework_tutorial_templates.py`. Run after changing an example or a profile:

    python3 scripts/gen-framework-tutorials.py           # rewrite the 56 generated pages
    python3 scripts/gen-framework-tutorials.py --check  # fail if any generated page is stale

The counter branches embed a contiguous, verbatim slice of each example's real source. The Todo and
UI branches are reading guides: `todo.md` / `ui.md` remain the single source of the Zig commands.
All three carry the same chapter on local state vs the Zig-owned counter and the SHA-256 seal.
Deterministic; writes only inside `docs/learn/{ja,en}/tutorials/`.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from framework_tutorial_profiles import PROFILES
from framework_tutorial_templates import (
    TODO_EN, TODO_EN_TAIL, TODO_JA, TODO_JA_TAIL,
    UI_EN, UI_EN_TAIL, UI_JA, UI_JA_TAIL,
    ZIG_LINKAGE_EN, ZIG_LINKAGE_JA,
)

TODO_JA_FULL = TODO_JA + ZIG_LINKAGE_JA + TODO_JA_TAIL
TODO_EN_FULL = TODO_EN + ZIG_LINKAGE_EN + TODO_EN_TAIL
UI_JA_FULL = UI_JA + ZIG_LINKAGE_JA + UI_JA_TAIL
UI_EN_FULL = UI_EN + ZIG_LINKAGE_EN + UI_EN_TAIL

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "src" / "docsite" / "frameworks.json"
TUTORIALS = ROOT / "docs" / "learn"

PAGES_URL = "https://umiturtle.github.io/ZigguraTs/examples/frameworks/{id}/index.html"
TREE_URL = "https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/{id}"

FENCE = {
    "react": "jsx",
    "solid": "jsx",
    "svelte": "svelte",
    "angular": "ts",
    "next": "tsx",
    "nuxt": "vue",
    "astro": "astro",
    "sveltekit": "svelte",
    "solidstart": "tsx",
}

# The learning step: replace the example's local +1 handler with an IPC call. Written in each
# framework's own idiom; these snippets are tutorial-only (the committed examples deliberately keep
# local state so the 3-OS screenshot comparison has no backend dependency).
INVOKE = {
    "react": '''import { invoke } from "@tauri-apps/api/core";

async function inc() { setCount(await invoke("increment")); }''',
    "solid": '''import { invoke } from "@tauri-apps/api/core";

async function inc() { setCount(await invoke("increment")); }''',
    "svelte": '''import { invoke } from "@tauri-apps/api/core";

async function inc() { count = await invoke("increment"); }''',
    "angular": '''import { invoke } from "@tauri-apps/api/core";

async inc() { this.count.set(await invoke<number>("increment")); }''',
    "next": '''import { invoke } from "@tauri-apps/api/core";

async function inc() { setCount(await invoke("increment")); }''',
    "nuxt": '''import { invoke } from "@tauri-apps/api/core";

async function inc() { count.value = await invoke<number>("increment"); }''',
    "astro": '''import { invoke } from "@tauri-apps/api/core";

const value = document.querySelector('[data-zts="count"]');
document.querySelector('[data-zts="inc"]').addEventListener("click", async () => {
  value.textContent = await invoke("increment");
});''',
    "sveltekit": '''import { invoke } from "@tauri-apps/api/core";

async function inc() { count = await invoke("increment"); }''',
    "solidstart": '''import { invoke } from "@tauri-apps/api/core";

async function inc() { setCount(await invoke("increment")); }''',
}

VARIANT_JA = '''# チュートリアル: {{LABEL}} でカウンターを作る

> **対象読者**: `{{LABEL}}` は使えるが ziggurats は初めての人。Zig の基本文法は知っている前提です。
> **所要時間**: 15 分（写経すれば動くところまで）。
> **前提**: [はじめての ziggurats](../start.md)（10 分）を済ませていること。

これは [カウンターを作る](counter.md) の **`{{LABEL}} {{VERSION}}` 版**です。Zig 側のコードは
元のチュートリアルと **1 文字も変わりません**。違うのは `web/` の中身だけで、そこに
[`examples/frameworks/{{ID}}/`]({{TREE}}) の実物をそのまま使います。
[ライブラリを選び直す](frameworks.md) といつでも別の分岐へ移れます。

<!-- framework-picker -->

| 章 | やること | 終わったとき |
|---|---|---|
| [0](#0-前提) | 前提の確認 | `zts doctor` が緑 |
| [1](#1-example-を手に入れる) | 完成済み example を持ってくる | 静的出力が手元にある |
| [2](#2-ziggurats-プロジェクトに組み込む) | `zts init` → `web/` に置く | `zts dev` で画面が出る |
| [3](#3-実物のコンポーネントを読む) | example のソースを読む | 状態とボタンの場所が分かる |
| [4](#4-zig-のコマンドを足す) | `increment` を書く | `invoke("increment")` が通る |
| [5](#5-ボタンを-ipc-につなぐ) | `{{LABEL}}` の流儀で `invoke` を呼ぶ | ボタン → Zig → 画面 |
| [6](#6-動かして配る) | `zts build` | 単一バイナリ |

---

## 0. 前提

| 項目 | 要件 |
|---|---|
| `zts` | [`install.md`](../guides/install.md) のとおり、Releases のバイナリ 1 個を `PATH` に |
| Zig | 0.17 系が `PATH` か `ZTS_ZIG` に |
| Node.js | `{{LABEL}}` を自分でビルドし直すときだけ。完成済み出力を使うなら不要 |
| OS | Linux（GTK3 + WebKit2GTK 4.1）/ macOS / Windows |

```bash
zts doctor       # all checks passed なら準備完了
```

## 1. example を手に入れる

リポジトリには **ビルド済みの静的出力**がコミットされているので、ネットワーク無しで始められます。

```text
examples/frameworks/{{ID}}/                 {{LABEL}} のソース
examples/gallery/src/web/fw/{{ID}}/         完成済みの静的出力（ここを使う）
```

```bash
# ziggurats のチェックアウトが隣にある場合
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/{{ID}}/. ./fw-{{ID}}/
ls fw-{{ID}}/index.html
```

自分で作り直したいときだけ、ソース側でビルドします。出力先は `{{DIST}}/` です。

```bash
cd /path/to/Z-Ts/examples/frameworks/{{ID}}
npm install
npm run build        # {{BUILD}}
ls {{DIST}}/index.html
```

> [!NOTE]
> 9 つの example は**同じ DOM・同じ CSS・同じ文言**で作られています。違うのはフレームワーク名と
> バージョンだけなので、[公開デモ]({{DEMO}}) を見比べれば「どれを選んでも同じアプリ」だと
> 確認できます。3 OS のスクリーンショット比較については
> [`examples/frameworks/README.md`](../../../../examples/frameworks/README.md) を参照してください。

## 2. ziggurats プロジェクトに組み込む

```bash
zts init my-app
cd my-app
rm -rf web
cp -R ../fw-{{ID}} web
zts dev                 # http://127.0.0.1:5173
```

`web/` はそのまま配信され、`zts build` でバイナリに埋め込まれます。`{{LABEL}}` の成果物を
`web/` に置くだけで、Zig 側の設定は何も変わりません（複数の chunk や `_next/` のような
サブディレクトリもそのまま辿れます）。

`zts dev` は `web/` の変更を 0.2 秒ほどでリロードします。**いまは Zig のアプリは動いていない**
ので、次の章で `invoke` を足したら `zts build` で確認してください。

## 3. 実物のコンポーネントを読む

以下は `{{SOURCE}}` の抜粋です（このページのコードはコミット済み example と機械的に
突き合わせています）。{{NOTE}}。

<!-- source: {{SOURCE}} -->
```{{FENCE}}
{{SNIPPET}}
```

状態は {{STATE}} です。

{{REACTIVITY}}

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

`{{LABEL}}` では次のように書きます。`@tauri-apps/api` は**改造不要**です。

```{{FENCE}}
{{INVOKE}}
```

`{{LABEL}}` のローカル状態と、Zig が持つカウンタは **別の状態** です
（[付録](#付録-zig-が動いているかを画面で確かめる)）。{{SYNC}}

ギャラリーの `zig_inc` を同じ状態に流し込むなら、こう書きます。

```{{FENCE}}
{{CODE_ZIG}}
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

{{GUARD}}

> [!WARNING]
> `{{PITFALL}}`

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
| `{{LABEL}}` 版の Todo | [Todo を {{LABEL}} で](todo-{{ID}}.md) |
| `{{LABEL}}` 版の画面 | [画面を {{LABEL}} で](ui-{{ID}}.md) |
| `{{LABEL}}` の実物ソース | [`examples/frameworks/{{ID}}/`]({{TREE}}) |
| `{{LABEL}}` の公開デモ | [ブラウザで開く]({{DEMO}}) |
| 9 つの example の比較 | [`examples/frameworks/README.md`](../../../../examples/frameworks/README.md) |
| コマンドの引数・エラー・型生成 | [ガイド: コマンド](../guides/rpc.md) |
'''

VARIANT_EN = '''# Tutorial: build a counter with {{LABEL}}

> **Audience**: you know {{LABEL}} but have never used ziggurats; basic Zig syntax is assumed.
> **Time**: 15 minutes to a running app.
> **Before you start**: finish [Your first ten minutes](../start.md).

This is the **{{LABEL}} {{VERSION}}** branch of [Build a counter](counter.md). The Zig side is
**identical, character for character**; only `web/` changes, and it uses the real example from
[`examples/frameworks/{{ID}}/`]({{TREE}}). [Pick another library](frameworks.md) at any time.

<!-- framework-picker -->

| Chapter | You do | You end up with |
|---|---|---|
| [0](#0-prerequisites) | check the toolchain | `zts doctor` is green |
| [1](#1-get-the-example) | fetch the finished example | a static build on disk |
| [2](#2-drop-it-into-a-ziggurats-project) | `zts init` → `web/` | the page under `zts dev` |
| [3](#3-read-the-real-component) | read the example source | you know where state and buttons live |
| [4](#4-add-the-zig-command) | write `increment` | `invoke("increment")` works |
| [5](#5-wire-the-button-to-ipc) | call `invoke` the {{LABEL}} way | button → Zig → screen |
| [6](#6-run-and-ship) | `zts build` | one self-contained binary |

---

## 0. Prerequisites

| Item | Requirement |
|---|---|
| `zts` | one binary from Releases on `PATH` ([Install](../guides/install.md)) |
| Zig | 0.17 on `PATH` or in `ZTS_ZIG` |
| Node.js | only if you rebuild the framework yourself; not needed for the committed output |
| OS | Linux (GTK3 + WebKit2GTK 4.1) / macOS / Windows |

```bash
zts doctor       # "all checks passed" means you are ready
```

## 1. Get the example

The **built static output is committed**, so you can start with no network at all.

```text
examples/frameworks/{{ID}}/                 {{LABEL}} source
examples/gallery/src/web/fw/{{ID}}/         finished static output (use this one)
```

```bash
# when the ziggurats checkout sits next to you
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/{{ID}}/. ./fw-{{ID}}/
ls fw-{{ID}}/index.html
```

Only rebuild from source if you want to. The output directory is `{{DIST}}/`.

```bash
cd /path/to/Z-Ts/examples/frameworks/{{ID}}
npm install
npm run build        # {{BUILD}}
ls {{DIST}}/index.html
```

> [!NOTE]
> All nine examples render the **same DOM, CSS and copy**; only the framework name and version
> differ. Compare the [live demo]({{DEMO}}) with another one to see that the app is the same. See
> [`examples/frameworks/README.md`](../../../../examples/frameworks/README.en.md) for the 3-OS
> screenshot comparison.

## 2. Drop it into a ziggurats project

```bash
zts init my-app
cd my-app
rm -rf web
cp -R ../fw-{{ID}} web
zts dev                 # http://127.0.0.1:5173
```

`web/` is served as-is and embedded into the binary by `zts build`. Nothing on the Zig side has to
change — even multiple chunks and subdirectories such as `_next/` are followed verbatim.

`zts dev` reloads `web/` in about 0.2 s. **The Zig app is not running yet**, so once you add
`invoke` in the next chapters, verify with `zts build` as well.

## 3. Read the real component

This is an excerpt of `{{SOURCE}}` (the snippet is mechanically checked against the committed
example). {{NOTE}}

<!-- source: {{SOURCE}} -->
```{{FENCE}}
{{SNIPPET}}
```

State lives in {{STATE}}.

{{REACTIVITY}}

The counter deliberately uses **local state only** so the pixel
comparison across three OSes has no backend dependency. The `.zigbar` panel below it is the
opposite: it **cannot be filled in unless Zig is running**
([appendix](#appendix-prove-zig-is-running-from-the-screen)). The next chapter connects ziggurats.

## 4. Add the Zig command

**This part is shared by every library.** Copy the `zig check` block from
[Build a counter](counter.md#3-write-the-counting-command) into `src/main.zig` verbatim. That block is
compiled by CI, so it — not this page — is the single source of truth.

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

The app only has to create the state and `bind` it.

```zig
var state = State{};
var router = Schema.bind(.{ .app = &state });
const handler = router.handler();
```

## 5. Wire the button to IPC

In {{LABEL}} you write it like this. `@tauri-apps/api` is used **unmodified**.

```{{FENCE}}
{{INVOKE}}
```

The {{LABEL}} state and the counter owned by Zig are **two different states**
([appendix](#appendix-prove-zig-is-running-from-the-screen)). {{SYNC}}

To feed the gallery's `zig_inc` into that same state, write:

```{{FENCE}}
{{CODE_ZIG}}
```

That closes the loop: button → `invoke("increment")` → Zig function → return value → screen.
`invoke` does not reach anything in the browser served by `zts dev`, so always confirm with the
executable produced by `zts build`.

> [!NOTE]
> Inline scripts in `web/index.html` get a CSP hash at build time; `unsafe-inline` is not needed.
> Framework-generated `<script type="module">` tags are handled the same way.

## 6. Run and ship

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # a window opens and +1 reaches Zig
```

`web/` is embedded with gzip twins and CSP hashes, so no asset directory sits next to the binary.

## Appendix: prove Zig is running from the screen

All nine examples ship the same `.zigbar` panel. This one strip **cannot work without Zig**.

| What you see | What is happening behind it |
|---|---|
| red `ZIG OFFLINE`, `+` / `-` disabled | static HTML only (public demo, the `zts dev` browser): no `window.__ZTS_ZIG__` |
| green `ZIG ONLINE`, a 16-character seal, `+` / `-` enabled | the Zig binary is answering `zig_probe` / `zig_inc` / `zig_dec` |

The seal is the first eight bytes of SHA-256 over **a secret that only the Zig binary holds** and
Zig's own counter. Neither the secret nor the computation is present in any static file, so
JavaScript alone cannot manufacture the string. `+` / `-` change **the counter owned by Zig**, not
the framework's local state, and every press produces a new seal. That single line is the answer to
"is Zig actually alive back there?".

{{GUARD}}

> [!WARNING]
> `{{PITFALL}}`

The real wiring lives in
[`examples/gallery/src/web/zig-bridge.js`](../../../../examples/gallery/src/web/zig-bridge.js) and
[`examples/gallery/src/main.zig`](../../../../examples/gallery/src/main.zig). The gallery injects
the same `window.__TAURI_INTERNALS__.invoke` that unmodified `@tauri-apps/api` v2 uses, at
`DOCUMENT_START`, and answers `ipc://localhost/<command>` from Zig. To light the panel up in your
own app, add those three commands to `rpc.Schema` and inject the same bridge. Chapter
[5](#5-wire-the-button-to-ipc) shows how to connect the counter itself over IPC.

## Where next

| You want | Go to |
|---|---|
| the same tutorial in another library | [Choose a library](frameworks.md) |
| the plain-JS original | [Build a counter](counter.md) |
| more state, returning failures | [Build a todo list](todo.md) |
| loading / empty / error views | [Build the screen](ui.md) |
| the Todo branch for {{LABEL}} | [Todo with {{LABEL}}](todo-{{ID}}.md) |
| the screen branch for {{LABEL}} | [Screen with {{LABEL}}](ui-{{ID}}.md) |
| the real {{LABEL}} source | [`examples/frameworks/{{ID}}/`]({{TREE}}) |
| the live {{LABEL}} demo | [Open in a browser]({{DEMO}}) |
| all nine examples compared | [`examples/frameworks/README.en.md`](../../../../examples/frameworks/README.en.md) |
| arguments, errors, generated types | [Guide: commands](../guides/rpc.md) |
'''

CHOOSER_JA = '''# 好きなライブラリでチュートリアルを選ぶ

> **対象読者**: いつものフロントエンドのまま ziggurats を試したい人。
> **所要時間**: 選ぶだけなら 1 分。counter は 15 分、Todo / 画面は各 20 分。

チュートリアル 3 本は **Zig 側が共通**です。フロントエンドは実物の example が
コミットされている 9 ライブラリ＋素の JS から、**好きなものを 1 つ選んで**進められます。
どの分岐を選んでも `increment` の Zig コード、`zts dev`、`zts build` は同じです。

<!-- framework-picker -->

## どう分岐しているか

| 元のチュートリアル | 共通なもの | ライブラリごとに変わるもの |
|---|---|---|
| [カウンターを作る](counter.md) | `increment` コマンド・`zts dev`・`zts build` | 状態プリミティブとボタンの書き方（9 本） |
| [Todo リストを作る](todo.md) | 3 つの Zig コマンド・`error{}`・テスト | 一覧の状態・キー付き繰り返し・再読込（9 本） |
| [画面を作る](ui.md) | 状態の境界・CSP | 3 状態の条件分岐・エラー表示（9 本） |

> [!NOTE]
> `learn_path.zig` の 5 ステップ・所要時間は変えていません。分岐は**追加の章ではなく代替の道**で、
> 選んだ 1 本だけ読めば、その 1 本の所要時間で終わります。

## 実物の example 一覧

| 実物 | バージョン | ビルド | 出力先 | カウンター | Todo | 画面 | 公開デモ |
|---|---|---|---|---|---|---|---|
{{ROWS_JA}}

リポジトリの [`examples/frameworks/README.md`](../../../../examples/frameworks/README.md) に
ビルド方法と 3 OS のスクリーンショット比較の仕組みをまとめてあります。

## 裏で Zig が動いているかを見分ける

9 つの公開デモは静的 HTML なので、どれも下部のパネルが赤い **`ZIG OFFLINE`** になり、
`＋` `−` は押せません。これで「ブラウザだけでは ziggurats は動いていない」ことが一目で分かります。
ネイティブのギャラリー（`examples/gallery`）で開くと同じパネルが緑の **`ZIG ONLINE`** になり、
Zig だけが作れる 16 桁の seal と、Zig が保持するカウンタが表示されます。
`zig_probe` / `zig_inc` / `zig_dec` は `ipc://` 越しに Zig が答えるコマンドで、
静的ファイルには実装がありません。各分岐ページの付録に配線の実物へのリンクがあります。

## 次に読むもの

- まず 1 本通す → [カウンターを作る](counter.md)（素の JS）または上の表から 1 つ
- 分岐の元に戻る → [チュートリアルの入口](index.md)
- 概念から知りたい → [概念の索引](../concepts/index.md)
- コマンドの設計 → [実用パターン](../patterns/index.md)
'''

CHOOSER_EN = '''# Choose a library for the tutorials

> **Audience**: readers who want to try ziggurats without leaving their usual frontend stack.
> **Time**: one minute to choose; 15 minutes for the counter, 20 each for Todo / UI.

The three tutorials share **the same Zig side**. For the frontend you can pick **any** of the nine
libraries with a committed example, or plain JavaScript. `increment`, `zts dev` and `zts build`
are identical on every branch.

<!-- framework-picker -->

## How the branches work

| Original tutorial | Shared | What changes per library |
|---|---|---|
| [Build a counter](counter.md) | the `increment` command, `zts dev`, `zts build` | state primitive and button syntax (nine branches) |
| [Build a todo list](todo.md) | three Zig commands, `error{}`, command tests | list state, keyed repetition, re-reading (nine branches) |
| [Build the screen](ui.md) | state boundaries, CSP | three-state conditionals and error views (nine branches) |

> [!NOTE]
> The five learning-path steps and their minute budget are unchanged: a branch is an **alternative
> route, not an extra chapter**. Read one and you are done in that one's time budget.

## The real examples

| Example | Version | Build | Output | Counter | Todo | UI | Live demo |
|---|---|---|---|---|---|---|---|
{{ROWS_EN}}

See [`examples/frameworks/README.en.md`](../../../../examples/frameworks/README.en.md) for the
build commands and the 3-OS screenshot comparison.

## Telling whether Zig is running behind the page

The nine published demos are static HTML, so the strip at the bottom of each one reads **`ZIG OFFLINE`**
in red and its `+` / `-` buttons are disabled. That is the point: a browser alone does not run
ziggurats. Open the same build in the native gallery (`examples/gallery`) and the strip turns
**`ZIG ONLINE`** in green, showing a 16-character seal that only Zig can produce and a counter owned
by Zig. `zig_probe` / `zig_inc` / `zig_dec` are answered over `ipc://` by the Zig binary; no static
file implements them. Every branch page's appendix links to the real wiring.

## Next

- Work through one → [Build a counter](counter.md) (plain JS) or any row above
- Back to the chapter hub → [Tutorials](index.md)
- Concepts first → [Concepts](../concepts/index.md)
- Shaping commands → [Patterns](../patterns/index.md)
'''


def snippet_for(fw: dict) -> str:
    """A contiguous slice of the real source around the counter markup."""
    path = ROOT / fw["source"]
    lines = path.read_text(encoding="utf-8").splitlines()
    hit = next((i for i, line in enumerate(lines) if 'data-zts="count"' in line), None)
    if hit is None:
        raise SystemExit(f"{fw['id']}: no counter markup in {fw['source']}")
    # Two lines before / five after keeps the counter block intact (header closing tags and
    # the long CSS in Nuxt / Astro stay out of the excerpt).
    start = max(0, hit - 2)
    end = min(len(lines), hit + 5)
    return "\n".join(lines[start:end]).strip("\n")


def render(template: str, fw: dict, snippet: str, lang: str) -> str:
    body = template
    profile = PROFILES[fw["id"]]
    i = 0 if lang == "ja" else 1
    replacements = {
        "{{LABEL}}": fw["label"],
        "{{ID}}": fw["id"],
        "{{VERSION}}": fw["version"],
        "{{BUILD}}": fw["build"],
        "{{DIST}}": fw["dist"],
        "{{SOURCE}}": fw["source"],
        "{{NOTE}}": fw[f"note_{lang}"],
        "{{STATE}}": fw[f"state_{lang}"],
        "{{FENCE}}": FENCE[fw["id"]],
        "{{SNIPPET}}": snippet,
        "{{INVOKE}}": INVOKE[fw["id"]],
        "{{TREE}}": TREE_URL.format(id=fw["id"]),
        "{{DEMO}}": PAGES_URL.format(id=fw["id"]),
        "{{REACTIVITY}}": profile["reactivity"][i],
        "{{SYNC}}": profile["sync"][i],
        "{{GUARD}}": profile["guard"][i],
        "{{PITFALL}}": profile["pitfall"][i],
        "{{TODO_STATE}}": profile["todo_state"][i],
        "{{UI_STATE}}": profile["ui_state"][i],
        "{{CODE_ZIG}}": profile["code_zig"],
        "{{CODE_TODO}}": profile["code_todo"],
        "{{CODE_UI}}": profile["code_ui"],
    }
    for key, value in replacements.items():
        body = body.replace(key, value)
    # The English variant links the English example README explicitly; the Japanese one the
    # Japanese README. Both templates already use the language-specific path inline.
    return body


def rows(fw_list: list[dict], lang: str) -> str:
    out = []
    for fw in fw_list:
        tree = TREE_URL.format(id=fw["id"])
        demo = PAGES_URL.format(id=fw["id"])
        demo_label = "開く" if lang == "ja" else "Open"
        fid = fw["id"]
        out.append(
            f"| [`{fid}/`]({tree}) | {fw['version']} | `{fw['build']}` | `{fw['dist']}` | "
            f"[counter](counter-{fid}.md) | [todo](todo-{fid}.md) | [ui](ui-{fid}.md) | "
            f"[{demo_label}]({demo}) |"
        )
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="fail when a generated page is stale")
    args = ap.parse_args()

    fw_list = json.loads(CATALOG.read_text(encoding="utf-8"))
    expected: dict[Path, str] = {}
    for fw in fw_list:
        snippet = snippet_for(fw)
        fid = fw["id"]
        expected[TUTORIALS / "ja" / "tutorials" / f"counter-{fid}.md"] = render(VARIANT_JA, fw, snippet, "ja")
        expected[TUTORIALS / "en" / "tutorials" / f"counter-{fid}.md"] = render(VARIANT_EN, fw, snippet, "en")
        expected[TUTORIALS / "ja" / "tutorials" / f"todo-{fid}.md"] = render(TODO_JA_FULL, fw, snippet, "ja")
        expected[TUTORIALS / "en" / "tutorials" / f"todo-{fid}.md"] = render(TODO_EN_FULL, fw, snippet, "en")
        expected[TUTORIALS / "ja" / "tutorials" / f"ui-{fid}.md"] = render(UI_JA_FULL, fw, snippet, "ja")
        expected[TUTORIALS / "en" / "tutorials" / f"ui-{fid}.md"] = render(UI_EN_FULL, fw, snippet, "en")

    expected[TUTORIALS / "ja" / "tutorials" / "frameworks.md"] = CHOOSER_JA.replace("{{ROWS_JA}}", rows(fw_list, "ja"))
    expected[TUTORIALS / "en" / "tutorials" / "frameworks.md"] = CHOOSER_EN.replace("{{ROWS_EN}}", rows(fw_list, "en"))

    stale = []
    for path, content in sorted(expected.items()):
        if path.exists() and path.read_text(encoding="utf-8") == content:
            continue
        stale.append(str(path.relative_to(ROOT)))
        if not args.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    if args.check:
        if stale:
            print("stale generated tutorial pages:", file=sys.stderr)
            for name in stale:
                print(f"  {name}", file=sys.stderr)
            print("run: python3 scripts/gen-framework-tutorials.py", file=sys.stderr)
            return 1
        print(f"framework tutorials: {len(expected)} pages up to date")
    else:
        print(f"framework tutorials: wrote {len(stale)} of {len(expected)} pages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
