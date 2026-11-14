# チュートリアル: React で画面を作る

> **対象読者**: `React` で画面を組み立てられる人。ziggurats の `invoke` は初めてでも構いません。
> **所要時間**: 20 分（写経すれば動くところまで）。
> **前提**: [Todo リストを作る](todo.md) を済ませていること。

これは [画面を作る](ui.md) の **`React 19.3` 版**です。状態の境界・CSP・
`zts dev` の差し替えは **どのライブラリでも同じ**です。変わるのは「読み込み中 / 空 / エラー」を
React の構文でどう出し分けるかだけです。[ライブラリを選び直す](frameworks.md) といつでも
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

`useState(0)` は値と setter の組を返します。setter を呼ぶとコンポーネント関数が**もう一度実行され**、返した JSX 全体が再評価されます。状態はレンダリングごとに作り直されるクロージャなので、`await` の前の値を後で使うと古い値を掴みます。

`const [status, setStatus] = useState<"loading" | "ready" | "empty" | "error">("loading")` の 1 本で出し分けます。条件付き JSX は `status === ... ? ... : ...` です。

`ui.md` の素の JS 版では `let status = "loading"` と
`if / else` でしたが、ここではその部分だけを React の流儀に読み替えます。
**Zig 側の `State` と `error{}` は共通**です。

## 2. 骨格と CSS は共通

[画面を作る](ui.md#2-html-の骨格) の `web/index.html` と `web/style.css` をそのまま置いてください。
`React` を使う場合も **`data-zts` 属性名は変えません**。3 OS のスクリーンショット比較と
`.zigbar` パネルが同じ属性を参照するからです。

```bash
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/react/. ./fw-react/
# 必要なら vite build で作り直す。出力先は dist/
```

## 3. 状態をテンプレートで出し分ける

```jsx
const [status, setStatus] = useState<"loading" | "ready" | "empty" | "error">("loading");

async function load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    setStatus(list.length ? "ready" : "empty");
  } catch (e) {
    setStatus("error");   // 画面だけ進めない
  }
}
```

`loading` から始めて、成功したときだけ `ready` / `empty` に進めます。プリレンダーや静的
書き出しでは HTML に初期値が焼き付くので、**Zig の値が届くまで `ZIG OFFLINE` を出したまま**
にするのが `useEffect` はブラウザでだけ走るので、`window.__ZTS_ZIG__` の確認はそこに置きます。`zts dev` のブラウザには bridge が無いため `ZIG OFFLINE` のままになるのは正常です。 の理由です。

## 4. `invoke` の失敗を error にする

[画面を作る](ui.md#4-画面は「戻り値だけ」から描く) の原則どおり、`invoke` が reject したら
状態を書き換えず `error` に切り替えます。`setCount(await invoke("zig_inc"))` のように **Zig の戻り値だけ**を渡します。クリック時に `setCount(c => c + 1)` で楽観更新すると、Zig が拒否したとき画面だけが進みます。`invoke` が reject したら setter を呼ばず、エラー状態に切り替えてください。

一覧の再読込は Todo 版と同じです。

```jsx
const [todos, setTodos] = useState<Todo[]>([]);

async function refresh() {
  setTodos(await invoke<Todo[]>("listTodos"));
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // ローカル配列を足さず、Zig から読み直す
}
// {todos.map((t) => <li key={t.id}>{t.title}</li>)}
```

## 5. 状態は 2 つある

ここが 3 本のチュートリアルで**一番大事な境界**です。画面に見えている値と、Zig が持っている値は
別の状態です。

| どこ | 誰が持つ | どう更新される |
|---|---|---|
| アプリのデータ | Zig の `State` | `addTodo` / `toggleTodo` / `removeTodo` などのコマンド |
| 画面に出る一覧・数 | `useState(0)` から作った React の状態 | **`invoke` の戻り値で丸ごと差し替え** |
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

`useEffect` はブラウザでだけ走るので、`window.__ZTS_ZIG__` の確認はそこに置きます。`zts dev` のブラウザには bridge が無いため `ZIG OFFLINE` のままになるのは正常です。

`setCount(await invoke("zig_inc"))` のように **Zig の戻り値だけ**を渡します。クリック時に `setCount(c => c + 1)` で楽観更新すると、Zig が拒否したとき画面だけが進みます。`invoke` が reject したら setter を呼ばず、エラー状態に切り替えてください。

React で Zig 所有カウンタを受け取るなら、こう書きます（`invoke` は `zts build` 後の
実行ファイルでだけ届きます）。

```jsx
import { invoke } from "@tauri-apps/api/core";

const [zigCount, setZigCount] = useState(0);
const [seal, setSeal] = useState("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  setZigCount(r.count);   // 楽観更新せず、Zig の戻り値だけを正にする
  setSeal(r.seal);        // Zig 側だけが作れる SHA-256 seal
}
```

> [!WARNING]
> `useEffect` の依存配列を空にしたまま `invoke` を呼ぶと StrictMode の開発時だけ 2 回走ります。Zig 側のカウンタが 2 つ進むので、本番と挙動が違って見えたらまずここを疑ってください。

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
| 同じライブラリのカウンター | [React でカウンター](counter-react.md) |
| 同じライブラリの Todo | [React で Todo](todo-react.md) |
| 素の JS 版（分岐の元） | [画面を作る](ui.md) |
| ライブラリを選び直す | [選択ハブ](frameworks.md) |
| `React` の公開デモ | [ブラウザで開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/react/index.html) |
| CSP と配布 | [ガイド: 静的サイト](../guides/static-site.md) |
| コマンドとエラーの設計 | [実用パターン](../patterns/index.md) |

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
