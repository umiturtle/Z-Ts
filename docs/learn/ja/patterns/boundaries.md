# 画面とロジックの境界

> **対象読者**: 画面が増え、`invoke` の呼び出しが散らばってきた人。
> **所要時間**: 4 分（練習 2 問で +12 分）。
> **前提**: [コマンドの設計](commands.md) と [エラーの設計](errors.md)。

ここまでの 3 ページは Zig 側の話でした。最後は**境界の跨ぎ方**です。同じコマンドでも、
呼び方で使い心地が変わります。

## 動く例: 1 回の操作 = 1 回の呼び出し

```ts
// web/app.ts — `bindings.gen.ts`（zts_rpc.tsgen の生成物）を使う
import { createRpcClient } from "./bindings.gen.ts";

const rpc = createRpcClient();

async function toggle(id: number): Promise<void> {
  // 画面を先に進める（楽観更新）。失敗したら戻す。
  render(id, "pending");
  const res = await rpc.$try.toggleTodo({ id }); // 例外を投げない形
  if (res.ok) {
    render(res.data.id, res.data.done ? "done" : "open");
    return;
  }
  render(id, "open"); // 巻き戻し
  showError(res.error.code); // "NotFound" などを文言に翻訳
}
```

`zts_rpc.tsgen` は 2 つの呼び方を生成します。

| 形 | 失敗の伝え方 | 使いどころ |
|---|---|---|
| `rpc.$try.toggleTodo(args)` | `{ ok: false, error: { code } }` を返す | 失敗を**分岐**として扱う（既定） |
| `rpc.toggleTodo(args)` | `ZtsRpcError` を投げる | `try/catch` でまとめて扱いたいとき |

3 つの原則があります。

1. **呼び出しは 1 操作 1 回**。`invoke` を 2 回続けて「取得し直す」のは、戻り値の設計ミス
   （[コマンドの設計](commands.md)）です
2. **画面は先に進めてよい**（楽観更新）。失敗したら**巻き戻す**。ユーザーは往復を待たされる
   より、戻る方が速いと感じます
3. **エラーコードは 1 か所で翻訳**。`showError(code)` のような関数を 1 つ作り、
   画面ごとに文言を書かない

## 育つ書き方 / 壊れる書き方

| 判断 | 育つ | 壊れる | なぜ |
|---|---|---|---|
| 呼び出しの単位 | 操作 1 つ | 画面 1 つ（`loadEverything`） | 1 か所変えると全画面が再取得する |
| 二重送信 | ボタンを `disabled` + 進行中の Promise を保持 | 何もしない | 連打で 2 回注文される |
| ローディング | 操作した行だけ | 画面全体をスピナーに | 何が起きているか分からず、体感も遅い |
| 失敗の表示 | 操作の近く（行・フォーム） | `alert()` | 文脈が消え、閉じるまで操作できない |
| 再試行 | 失敗した 1 操作だけ | 画面の再読み込み | 入力が消える |
| 連続入力 | デバウンス（例 200 ms） | 1 文字ごとに `invoke` | 往復が詰まり、順序も入れ替わる |

### before → after: 連打と競合

```ts
// before: 連打すると 2 回注文される。遅い応答が後から来て画面が巻き戻る。
button.onclick = () => rpc.order({ item: "pen", quantity: 1 });

// after: 進行中は受け付けず、完了後に戻す
let inFlight = false;
button.onclick = async () => {
  if (inFlight) return;
  inFlight = true;
  button.disabled = true;
  try {
    const res = await rpc.$try.order({ item: "pen", quantity: 1 });
    if (res.ok) showOrder(res.data);
    else showError(res.error.code);
  } finally {
    inFlight = false;
    button.disabled = false;
  }
};
```

Zig 側でも守れます（在庫を減らす前に確認する、`revision` で衝突を検出する）。**両方で守る**のが
正解で、UI 側は「事故を減らす」、Zig 側は「事故を防ぐ」役割です。

### before → after: 取得し直さない

```ts
// before: 更新 → 全件取得。往復 2 回、画面は一瞬古いまま
await rpc.$try.toggleTodo({ id });
const list = await rpc.$try.listTodos();
renderList(list.data);

// after: 返ってきた 1 件だけ差し替える
const res = await rpc.$try.toggleTodo({ id });
if (res.ok) renderItem(res.data);
```

## なぜそうなるか

`invoke` の往復は**非同期で、順序が保証されません**。同じコマンドを 2 回投げると、
遅い方が後に届いて画面が巻き戻ることがあります（stale response）。防ぐ方法は 2 つです。

- **投げない**（進行中は無効化する）
- **古い応答を捨てる**（リクエストに連番を付け、最新以外を無視する）

「画面全体をスピナーにする」も同じ問題を隠すだけです。ユーザーは待ち時間の間に
**何が起きているか**を知りたいので、操作した行だけを `pending` にしてください。

## 練習

### 1. 二重送信を止める

`zts build` の「保存」ボタンが 2 回押され、ファイルが 2 回書かれました。どこで止めますか。

<details>
<summary>答え</summary>

**3 か所すべて**で止めます。

1. **UI**: 進行中は `disabled`（+ `aria-busy="true"`）。最小の 1 行
2. **呼び出し**: 同じ操作の Promise を保持し、進行中ならそれを返す（重複をまとめる）
3. **Zig**: 書き込みは一時ファイル + rename（同じ内容の 2 回書き込みが壊れない）

UI だけだと、別タブや自動保存で破れます。Zig だけだと、ユーザーは 2 回待たされます。

</details>

### 2. どのコマンドを呼ぶか

「一覧で 1 件を完了にする」ために、次のどれを呼びますか。

1. `toggleTodo`（返り値: `Todo`）
2. `markDone`（返り値: `Todo`）
3. `listTodos` を呼び直す

<details>
<summary>答え</summary>

**1 か 2**。`Todo` が返るので、その 1 件を差し替えれば済みます。3 は往復が 1 回増え、
一覧全体が再描画されるのでスクロール位置も失われます。1 と 2 の選択は
[コマンドの設計](commands.md) の練習 1（操作の意味が「切り替え」か「完了」か）で決めます。

</details>

---

## この章のまとめ

| 迷い | 答え | ページ |
|---|---|---|
| コマンドを分けるか | 動詞が違えば分ける。引数は 1 つの構造体 | [コマンド](commands.md) |
| 状態はどこに | 間違うと困るなら Zig。見た目だけならフロント | [状態](state.md) |
| 失敗の返し方 | 画面の対応が変わる単位で `error{}`。文言はフロント | [エラー](errors.md) |
| 境界の跨ぎ方 | 1 操作 1 呼び出し・楽観更新・巻き戻し | このページ |

次は [目的から引く](../guides/index.md) へ。作りたいものから 1 本だけ読んでください。
