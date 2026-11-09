# チュートリアル: Todo リストを作る

> **対象読者**: [カウンター](counter.md)を 1 本作り終えた人。Zig の基本文法は知っている前提です。
> **所要時間**: 20 分（写経すれば動くところまで）。**練習**を足すと +15 分。
> **前提**: `zts` と Zig 0.17 が `PATH` にあり、[カウンター](counter.md)の 3 章までを済ませていること。

カウンターは「1 つの数」でした。次は**リスト**です。要素が増え、コマンドが 3 つになり、
「空のタイトル」「存在しない id」という**失敗**が出てきます。ここで身につくのは、
アプリが育っても壊れないための 3 つです。

| 学ぶこと | このページで書くもの |
|---|---|
| 状態は 1 つの構造体に閉じ込める | `State` |
| コマンドは「動詞 1 つ = 関数 1 つ」 | `addTodo` / `toggleTodo` / `removeTodo` |
| 失敗は `error{…}` で返し、文言は画面が決める | `error.EmptyTitle` / `error.NotFound` |
| テストはコマンドを直接呼ぶ | `std.testing` |

> [!TIP]
> 設計の**理由**は [実用パターン](../patterns/index.md) にあります。このページは手を動かすことが
> 目的なので、判断に迷ったら先に進んで構いません。

---

## 1. 状態を 1 つの構造体にする

`State` はアプリの**唯一の可変状態**です。コマンドは `*State` を引数で受け取り、そこだけを触ります
（グローバル変数は作りません。テストで 2 つの状態を同時に持てなくなるためです）。

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const Todo = struct { id: u32, title: []const u8, done: bool = false };

const State = struct {
    allocator: std.mem.Allocator,
    /// Titles are copied into the state's own arena, so a command may return them without the
    /// caller having to know who owns the memory.
    arena: std.heap.ArenaAllocator,
    next_id: u32 = 1,
    todos: std.ArrayListUnmanaged(Todo) = .empty,

    fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *State) void {
        self.todos.deinit(self.allocator);
        self.arena.deinit();
    }
};

test "タイトルは状態の arena にコピーされる" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    const title = try state.arena.allocator().dupe(u8, "牛乳");
    try state.todos.append(state.allocator, .{ .id = 1, .title = title });
    try std.testing.expectEqualStrings("牛乳", state.todos.items[0].title);
}
```

`arena` があるのは、`invoke("addTodo", { title: "牛乳" })` の `"牛乳"` が**リクエストのバッファ**に
載ってくるからです。そのまま `todos` に入れると、次のリクエストで上書きされます。状態が持つ
メモリにコピーしてから保存します。

## 2. コマンドを 3 つ書く

`add` / `toggle` / `remove` の 3 つです。**動詞が違うのでコマンドも分けます**（`setTodo` 1 つに
`action: "toggle"` を渡す形にしない理由は [コマンドの設計](../patterns/commands.md)）。

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const Todo = struct { id: u32, title: []const u8, done: bool = false };

const State = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    next_id: u32 = 1,
    todos: std.ArrayListUnmanaged(Todo) = .empty,

    fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *State) void {
        self.todos.deinit(self.allocator);
        self.arena.deinit();
    }
};

const Commands = struct {
    /// Tells `Schema` which parameter is the state (otherwise `*State` looks like an argument).
    pub const RpcState = State;

    /// `invoke("addTodo", { title: "牛乳" })` → the new todo
    pub fn addTodo(state: *State, args: struct { title: []const u8 }) !Todo {
        if (args.title.len == 0) return error.EmptyTitle;
        const todo = Todo{
            .id = state.next_id,
            .title = try state.arena.allocator().dupe(u8, args.title),
        };
        state.next_id += 1;
        try state.todos.append(state.allocator, todo);
        return todo;
    }

    /// `invoke("toggleTodo", { id: 3 })` → the updated todo
    pub fn toggleTodo(state: *State, args: struct { id: u32 }) !Todo {
        for (state.todos.items) |*todo| {
            if (todo.id == args.id) {
                todo.done = !todo.done;
                return todo.*;
            }
        }
        return error.NotFound;
    }

    /// `invoke("removeTodo", { id: 3 })` → nothing (the UI re-reads `listTodos`)
    pub fn removeTodo(state: *State, args: struct { id: u32 }) !void {
        for (state.todos.items, 0..) |todo, i| {
            if (todo.id == args.id) {
                _ = state.todos.swapRemove(i);
                return;
            }
        }
        return error.NotFound;
    }

    /// Returns the whole list; the UI draws what it gets.
    pub fn listTodos(state: *State) ![]const Todo {
        return state.todos.items;
    }
};

pub const Schema = rpc.Schema(.{ .app = Commands });

test "add / toggle / remove が 1 本の流れで動く" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectError(error.EmptyTitle, Commands.addTodo(&state, .{ .title = "" }));

    const milk = try Commands.addTodo(&state, .{ .title = "牛乳" });
    _ = try Commands.addTodo(&state, .{ .title = "パン" });
    try std.testing.expectEqual(@as(u32, 1), milk.id);
    try std.testing.expectEqual(@as(usize, 2), (try Commands.listTodos(&state)).len);

    const toggled = try Commands.toggleTodo(&state, .{ .id = milk.id });
    try std.testing.expect(toggled.done);

    try Commands.removeTodo(&state, .{ .id = milk.id });
    try std.testing.expectError(error.NotFound, Commands.removeTodo(&state, .{ .id = milk.id }));
    try std.testing.expectEqual(@as(usize, 1), (try Commands.listTodos(&state)).len);
}
```

このブロックは CI の doctest がコンパイルしています。`RpcState` を忘れると
`command 'app.addTodo' has multiple payload parameters` で落ちるので、**エラーの名前で
原因が分かる**ようにしてあります（[エラーの設計](../patterns/errors.md)）。

`listTodos(state: *State)` のように引数が状態だけなら、`RpcState` がなくても状態と判定されます。
`addTodo` のように**引数がもう 1 つ**あるときだけ必要です。

## 3. エラーは「画面の対応が変わる単位」で返す

| エラー | 起きる条件 | 画面がすること |
|---|---|---|
| `error.EmptyTitle` | 空文字で追加しようとした | 入力欄を赤くして「入力してください」を出す。**再送はまだしない** |
| `error.NotFound` | すでに消えた id を操作した | 一覧を取り直す（他のタブで消された可能性がある） |

どちらも**文字列ではなく型**で返します。文言はフロントエンドが持ちます（英語版・日本語版を
Zig 側に埋め込まないため）。JS 側には `code` だけが届きます。

```ts
import { invoke } from "@tauri-apps/api/core";

async function add(title: string) {
  try {
    return await invoke("addTodo", { title });
  } catch (err) {
    // err is { code: "EmptyTitle" } -> the page decides the sentence
    const code = (err as { code?: string }).code ?? "Unknown";
    showMessage(code === "EmptyTitle" ? "入力してください" : "追加できませんでした");
  }
}
```

## 4. 画面から呼ぶ

`web/index.html` に一覧と入力欄を置き、**1 操作 = 1 コマンド**で呼びます。描画は
「戻ってきた値だけ」から行います（画面が別の真実を持たない）。

```html
<ul id="todos"></ul>
<form id="add">
  <input id="title" placeholder="やること" aria-label="やること" />
  <button>追加</button>
</form>
<p id="message" role="status" aria-live="polite"></p>

<script type="module">
  import { invoke } from "@tauri-apps/api/core";

  const list = document.getElementById("todos");
  const message = document.getElementById("message");

  async function render() {
    const todos = await invoke("listTodos");
    list.replaceChildren(...todos.map((t) => {
      const li = document.createElement("li");
      li.textContent = t.title;
      li.dataset.done = String(t.done);
      li.addEventListener("click", () => invoke("toggleTodo", { id: t.id }).then(render));
      return li;
    }));
  }

  document.getElementById("add").addEventListener("submit", async (event) => {
    event.preventDefault();
    const input = document.getElementById("title");
    try {
      await invoke("addTodo", { title: input.value });
      input.value = "";
      message.textContent = "";
      await render();
    } catch (err) {
      message.textContent = err.code === "EmptyTitle" ? "入力してください" : "追加できませんでした";
    }
  });

  render();
</script>
```

## 5. 動かす

```bash
zts dev          # 保存するたびに反映（CSS はリロードなしで差し替わる）
zts build        # zig-out/bin/my_app
```

`zts dev` が見せているのは `web/` だけで、Zig のアプリは動いていません。`invoke` の往復まで
確かめるときは `zts build` で作った実行ファイルを起動してください
（[カウンター](counter.md)の 2 章と同じ制約です）。

## 練習

<details>
<summary>1. 「全部消す」コマンドを足すとき、`State` に何を足すか</summary>

**何も足しません。** `clearTodos(state: *State) !void` を `Commands` に足して
`state.todos.clearRetainingCapacity()` を呼ぶだけです。状態の形は変わりません。
`next_id` を戻すかどうかは仕様です（戻すと、古い id への `toggleTodo` が**別の項目を
書き換える**ので、戻さないほうが安全です）。
</details>

<details>
<summary>2. `toggleTodo` が `error.NotFound` を返したとき、画面は何をすべきか</summary>

一覧を**取り直す**。他のタブや別のウィンドウで消えている可能性があり、画面が持っている
一覧はすでに古いからです。エラーメッセージを出すだけでは、消えた項目が残り続けます。
</details>

<details>
<summary>3. `addTodo` の戻り値を `Todo` ではなく `void` にすると、何が困るか</summary>

追加した id が分からないので、画面は**全件を取り直す**必要があります。1 件追加するたびに
一覧全体を往復させるのは、件数が増えたときに効いてきます。戻り値は「画面が次に描くもの」に
するのが原則です（[コマンドの設計](../patterns/commands.md)）。
</details>

---

## ここから先

| 次に知りたいこと | 行き先 |
|---|---|
| なぜこの形なのか（判断基準と練習） | [実用パターン](../patterns/index.md) |
| 引数の型・戻り値・TypeScript の生成 | [ガイド: コマンド](../guides/rpc.md) |
| 一覧をファイルに保存する | [ガイド: プラグイン](../guides/plugins.md)（`plugin:fs`） |
| 画面の作り込み（状態・CSS・CSP） | [チュートリアル: 画面を作る](ui.md) |
| うまく動かないとき | [トラブルシューティング](../guides/troubleshooting.md) |
