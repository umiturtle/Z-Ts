# チュートリアル: 画面を作る

> **対象読者**: [カウンター](counter.md)か [Todo リスト](todo.md)を動かした人。
> **所要時間**: 15 分。**前提**: `zts dev` が動くプロジェクトがあること。
> **このページを終えると**: 「読み込み中」「空」「エラー」を出し分ける画面が書けます。

ここまでは Zig 側でした。このページは `web/` の話です。ziggurats は**フロントエンドに何も要求しません**
（素の HTML / CSS / TypeScript で十分です）。そのかわり、`zts dev` と `zts build` が
**画面の更新と配布**を受け持ちます。知っておくと迷わないのは次の 3 つです。

| 知ること | 効くところ |
|---|---|
| 状態は「読み込み中 / 空 / エラー」の 3 つを先に決める | 画面が一瞬だけ嘘をつくのを防ぐ |
| CSS は `<link>` に置く | `zts dev` が**リロードせず**差し替える（0.4 秒） |
| インライン `<script>` には CSP ハッシュが自動で付く | `unsafe-inline` を書かなくてよい |

---

## 1. 3 つの状態を先に決める

データを取ってくる画面は、必ずこの 4 つを行き来します。**先に決めておくと、コードが短くなります**。

| 状態 | 画面 | ありがちな抜け |
|---|---|---|
| 読み込み中 | 骨組み（スケルトン）か「読み込み中…」 | 何も出さずに空白になる |
| 空 | 「まだありません」＋次の操作へのリンク | 真っ白で、壊れたのか空なのか分からない |
| エラー | 何が失敗したか＋**もう一度**ボタン | コンソールにだけ出して、画面は無反応 |
| 成功 | データ | — |

```ts
type View<T> =
  | { kind: "loading" }
  | { kind: "empty" }
  | { kind: "error"; message: string }
  | { kind: "ready"; data: T };
```

`busy` のようなフラグを別に持たず、**1 つの値**で表します。フラグが 2 つになると
「読み込み中かつエラー」のような組み合わせが表現できてしまい、画面が矛盾します。

## 2. HTML の骨格

```html
<main id="app">
  <h1>やること</h1>
  <form id="add">
    <label for="title">タイトル</label>
    <input id="title" autocomplete="off" />
    <button type="submit">追加</button>
  </form>
  <p id="status" role="status" aria-live="polite"></p>
  <ul id="todos"></ul>
</main>
```

`role="status"` と `aria-live="polite"` は、**エラーや件数をスクリーンリーダーに読ませる**ための
最小限です。見た目は変わりませんが、これが無いと「押したのに何も起きない」と読まれます。

## 3. CSS は別ファイルに置く

```html
<link rel="stylesheet" href="./style.css" />
```

`zts dev` は `web/**/*.css` の変更を検知すると、**ページをリロードせずに `<link>` を差し替えます**。
入力中の値・スクロール位置・開いているコンソールがそのまま残るので、色や余白の調整は
圧倒的に速くなります（実測 0.4 秒ほど）。

> [!NOTE]
> `<style>` に直接書いた CSS は HTML の一部なので、差し替えではなく**フルリロード**になります。
> 調整中は `style.css` に出し、配布直前にインライン化を検討してください
> （インライン化すると初回表示は 1 リクエスト減りますが、開発中の反復は遅くなります）。

`zts build` は `web/` を丸ごと埋め込むので、`style.css` を別ファイルにしても配布物は 1 個のままです。

## 4. 画面は「戻り値だけ」から描く

```ts
import { invoke } from "@tauri-apps/api/core";

type Todo = { id: number; title: string; done: boolean };

const list = document.getElementById("todos")!;
const status = document.getElementById("status")!;

async function refresh() {
  try {
    const todos = await invoke<Todo[]>("listTodos");
    if (todos.length === 0) {
      status.textContent = "まだありません。上の欄から追加してください。";
    } else {
      status.textContent = `${todos.length} 件`;
    }
    list.replaceChildren(...todos.map(renderOne));
  } catch (err) {
    status.textContent = "読み込めませんでした。もう一度お試しください。";
    console.error(err);
  }
}

function renderOne(todo: Todo): HTMLLIElement {
  const li = document.createElement("li");
  const button = document.createElement("button");
  button.textContent = todo.title;
  button.setAttribute("aria-pressed", String(todo.done));
  button.addEventListener("click", () => invoke("toggleTodo", { id: todo.id }).then(refresh));
  li.append(button);
  return li;
}

refresh();
```

**画面が独自のコピーを持たない**のが大事です。`todos` を JS の配列に持ち回すと、
Zig 側と食い違ったときにどちらが正しいか分からなくなります。`invoke` の戻り値をそのまま描き、
変更のあとは `refresh()` で取り直します。

## 5. CSP と配布

`zts build` は `web/` の HTML を読み、**インライン `<script>` / `<style>` のハッシュを CSP に
自動で入れます**。`unsafe-inline` を書く必要はなく、書いてもいけません。

| 書き方 | CSP | 備考 |
|---|---|---|
| インライン `<script>…</script>` | ハッシュが自動で付く | 手で nonce を配る必要はない |
| 外部 `<script src="./app.js">` | `script-src 'self'` で通る | ビルドツールの出力はこちら |
| `onclick="…"` 属性 | **付かない**（拒否される） | `addEventListener` に書き換える |

配布物は `zts build` の 1 ファイルです。`web/` の画像やフォントもバイナリに入るので、
隣にディレクトリを置く必要はありません。

```bash
zts dev      # 調整（CSS はリロードなし）
zts build    # zig-out/bin/my_app — web/ を内包
```

## 練習

<details>
<summary>1. 送信中にボタンを二重に押せないようにするには</summary>

`<form>` の `submit` で `button.disabled = true` にし、`finally` で戻します。ただし
**それだけでは足りません**（キーボード、別タブ、遅い回線）。サーバ側（Zig）でも
「同じ操作が 2 回来たら 2 回目を無視する」か「id を決めて冪等にする」必要があります。
3 層で止める話は [画面とロジックの境界](../patterns/boundaries.md) にあります。
</details>

<details>
<summary>2. 一覧が 1000 件になったとき、まず何を疑うか</summary>

`replaceChildren` で毎回**全部作り直している**こと。差分更新（変わった行だけ書き換える）か、
`DocumentFragment` にまとめて 1 回で差し込む形にします。ただし最初に疑うのは描画より
**通信**です。`listTodos` が毎回全件を返しているなら、そこが先です。
</details>

<details>
<summary>3. エラー文言を Zig 側で組み立ててはいけないのはなぜか</summary>

Zig は画面の言語を知らないからです。`error.EmptyTitle` という**コード**だけを返し、
`"入力してください"` と `"Please type something"` の選択は画面がします。同じ理由で、
Zig の `error{}` は「画面の対応が変わる単位」で切ります（[エラーの設計](../patterns/errors.md)）。
</details>

---

## 別のライブラリで読む

状態の境界・CSP・`zts dev` の差し替えは **どのライブラリでも同じ**です。変わるのは
「読み込み中 / 空 / エラー」をテンプレートでどう出し分けるかだけなので、上の分岐表から
好きなライブラリを選んでその構文に読み替えてください。

<!-- framework-picker -->

このチュートリアルの 9 分岐です。Zig 側はどれも共通です。

| ライブラリ | このチュートリアルの分岐 |
|---|---|
| React | [React で画面](ui-react.md) |
| Solid | [Solid で画面](ui-solid.md) |
| Svelte | [Svelte で画面](ui-svelte.md) |
| Angular | [Angular で画面](ui-angular.md) |
| Next.js | [Next.js で画面](ui-next.md) |
| Nuxt | [Nuxt で画面](ui-nuxt.md) |
| Astro | [Astro で画面](ui-astro.md) |
| SvelteKit | [SvelteKit で画面](ui-sveltekit.md) |
| SolidStart | [SolidStart で画面](ui-solidstart.md) |

[選択ハブ](frameworks.md) に実物の example 一覧があります。

## ここから先

| 次に知りたいこと | 行き先 |
|---|---|
| コマンドと状態の設計 | [実用パターン](../patterns/index.md) |
| `invoke` の引数・型・TypeScript 生成 | [ガイド: コマンド](../guides/rpc.md) |
| ウィンドウ・ダイアログ・ファイル | [ガイド: プラグイン](../guides/plugins.md) |
| 配布物（`.deb` / `.dmg` / `.exe`） | [ガイド: 配布物](../guides/package.md) |
