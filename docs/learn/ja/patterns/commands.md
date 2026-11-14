# コマンドの設計

> **対象読者**: `invoke("…")` を 3 つ以上書いた人。増やし始めて迷っている人。
> **所要時間**: 6 分（練習 3 問で +15 分）。
> **前提**: [仕組みを知る: コマンド](../concepts/commands.md) と [アプリを作る](../tutorials/index.md)。

コマンドは**境界**です。画面から見える唯一の Zig であり、Zig から見える唯一の画面です。
だから設計の良し悪しが、そのまま「あとで 1 行直すのが 1 分か 1 時間か」になります。

## 動く例

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

const Commands = struct {
    /// Tells `Schema` which parameter is the state (otherwise `*State` looks like an argument).
    pub const RpcState = State;

    /// `invoke("addTodo", { title: "牛乳" })` → 追加した todo
    pub fn addTodo(state: *State, args: struct { title: []const u8 }) !Todo {
        if (args.title.len == 0) return error.EmptyTitle;
        const todo = Todo{ .id = state.next_id, .title = try state.arena.allocator().dupe(u8, args.title) };
        state.next_id += 1;
        try state.todos.append(state.allocator, todo);
        return todo;
    }

    /// `invoke("toggleTodo", { id: 3 })` → 更新後の todo
    pub fn toggleTodo(state: *State, args: struct { id: u32 }) !Todo {
        for (state.todos.items) |*todo| {
            if (todo.id == args.id) {
                todo.done = !todo.done;
                return todo.*;
            }
        }
        return error.NotFound;
    }
};

pub const Schema = rpc.Schema(.{ .app = Commands });

test "addTodo rejects an empty title and numbers the rest" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectError(error.EmptyTitle, Commands.addTodo(&state, .{ .title = "" }));
    const first = try Commands.addTodo(&state, .{ .title = "牛乳" });
    try std.testing.expectEqual(@as(u32, 1), first.id);
    try std.testing.expectEqual(false, first.done);
}
```

ポイントは 4 つだけです。

1. **名前は動詞 + 名詞**（`addTodo` / `toggleTodo`）。`handleClick` のような画面の都合は入れない
2. **引数は 1 つの構造体**。`Schema` は payload を 1 つしか受け付けません（2 つ目でコンパイルエラー）。
   状態を引数と間違えないよう、`RpcState` を宣言します
3. **戻り値は「画面が次に描くのに要るもの」**。ここでは更新後の `Todo`
4. **状態は `*State`**。`pub const RpcState = State;` の 1 行で「これが状態だ」と `Schema` に伝えます。
   グローバル変数を使わないので、テストは `State.init(...)` を作るだけで済みます

## 育つ書き方 / 壊れる書き方

| 判断 | 育つ | 壊れる | なぜ |
|---|---|---|---|
| 粒度 | 動詞ごとに 1 コマンド | `applyAction(action: enum)` で分岐 | 引数の型が `enum` に潰れ、増やすたびに全画面が分岐を持つ |
| 画面との対応 | 操作ごと | 画面ごと（`getHomeScreen`） | 画面を 1 つ足すたびに「Zig の関数」が増え、ロジックが UI に漏れる |
| 引数 | `struct { id: u32 }` | `id: u32, force: bool, note: ?[]const u8` | 3 つ目で `Schema` がコンパイルエラー。最初から構造体にする |
| 戻り値 | 次に描くのに要る最小の値 | `bool` / `void` | `true` だけ返すと、画面は「何が変わったか」を知るために再取得する羽目に |
| 命名 | `addTodo` / `markDone` | `doTodo` / `todo1` | 半年後の自分が意味を復元できない |
| 失敗 | `error{…}` を返す | `error{ Failed }` で全部まとめる | UI が文言を出し分けられない（[エラーの設計](errors.md)） |

### before → after: 「画面 1 個 = コマンド 1 個」をやめる

```zig ignore
// before: 画面が増えるたびに Zig の関数が増え、同じ処理が 3 か所に散る
pub fn homeScreen(state: *State) !Screen { ... }
pub fn detailScreen(state: *State, args: struct { id: u32 }) !Screen { ... }
pub fn settingsScreen(state: *State) !Screen { ... }

// after: 操作は 3 つ。画面は好きなだけ増やせる（UI は同じコマンドを並べ替えるだけ）
pub fn listTodos(state: *State) ![]const Todo { ... }
pub fn toggleTodo(state: *State, args: struct { id: u32 }) !Todo { ... }
pub fn clearDone(state: *State) !u32 { ... }   // 消した件数を返す
```

「画面」はフロントエンドの概念で、Zig は**操作**しか知りません。この線を越えると、
Zig が HTML の都合（タブの並び、モーダルの開閉）を知りはじめ、テストが画面ごとになります。

### before → after: `void` を返さない

```zig ignore
// before: 画面は「保存できたか」しか分からず、もう一度読み直す必要がある
pub fn rename(state: *State, args: struct { id: u32, name: []const u8 }) !void { ... }

// after: 画面は返ってきた値をそのまま描ける
pub fn rename(state: *State, args: struct { id: u32, name: []const u8 }) !Todo { ... }
```

`void` が正しい場面はあります（ログの送信、設定の反映など、画面が何も描き直さない操作）。
迷ったら「呼び出し側は次に何を描くか」を考え、その値があるなら返します。

## なぜそうなるか

`invoke` の境界は**シリアライズされる**からです。引数も戻り値も JSON になり、`enum` の分岐は
「どの文字列が来るか」を両側で知っていなければなりません。コマンドを分けておけば、
TypeScript の型（`rpc.tsgen` が生成する `RpcResult<T, E>`）が関数ごとに付き、
**片方だけ変えたときにコンパイルが落ちます**。1 個の大きなコマンドにまとめると、型は
「なんでも入る箱」になり、コンパイルは何も守ってくれません。

同じ理由で、戻り値に `bool` を選ぶと**情報が落ちます**。落ちた情報は、画面側で
「もう一度取得する」という別のコマンドで埋めることになり、往復が 2 倍になります。

## 練習

### 1. `toggleTodo` を分割する

「完了にする」「未完了に戻す」を別コマンドにすると、何が良くて何が悪くなりますか。

<details>
<summary>答え</summary>

**良くなる点**: 呼び出し側が「今の状態」を知らなくても呼べます（`markDone` は冪等）。
**悪くなる点**: 同じデータを 2 つのコマンドが書き換えるので、`State` の不変条件を
両方で守る必要があります（片方だけ `updated_at` を更新し忘れる、など）。

判断基準は**操作の意味**です。「切り替え」が UI の言葉なら `toggleTodo` 1 つで足ります。
「完了」が業務の言葉（監査ログに残す、通知を送る）なら分けます。
分けたときは、内部の関数（`fn setDone(state: *State, id: u32, done: bool) !Todo`）を
共有し、コマンドは薄い入口にしてください。

</details>

### 2. 引数を構造体にする

`pub fn search(state: *State, query: []const u8, limit: u32) ![]const Todo` を `Schema` に入れると
何が起きますか。直してください。

<details>
<summary>答え</summary>

`zts_rpc.Schema` は**payload パラメータを 1 つ**しか許しません（2 つ目で
`has multiple payload parameters` のコンパイルエラー）。直す形はこうです。

```zig ignore
pub fn search(state: *State, args: struct { query: []const u8, limit: u32 = 20 }) ![]const Todo
```

`limit` に既定値を置いておくと、`invoke("search", { query: "牛乳" })` でも呼べます。
既定値は Zig 側の 1 か所だけに書かれるので、画面ごとに `20` を書く必要がありません。

</details>

### 3. 戻り値を選ぶ

「設定を保存する」コマンドの戻り値として、次のどれを選びますか。理由も書いてください。

1. `void`
2. `bool`（成功したか）
3. `struct { saved_at: i64, revision: u32 }`

<details>
<summary>答え</summary>

**3** が既定です。`revision` は楽観更新の衝突検出に使え、`saved_at` は「保存済み」の表示に
そのまま使えます。`void` は「画面が何も描き直さない」と**確信できる**ときだけ（例: 起動時の
テレメトリ送信）。`bool` は失敗を `error{}` で表す設計と二重になり、
`false` のときに何も分からないので選びません。

</details>

---

## 次に読むもの

- 状態をどこに置くか: [状態の置き場所](state.md)
- 失敗の返し方: [エラーの設計](errors.md)
- 生成される型: [API リファレンス](../../../api/index.html) の `zts_rpc` 節

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
