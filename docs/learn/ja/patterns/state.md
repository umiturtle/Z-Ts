# 状態の置き場所

> **対象読者**: 画面の状態と Zig の状態をどちらに置くか迷っている人。
> **所要時間**: 5 分（練習 2 問で +12 分）。
> **前提**: [コマンドの設計](commands.md)。

状態は「どこかに置く」ものではなく、**正しさの責任を持つ場所**を決めることです。
ziggurats では 3 つの置き場所があります。

| 置き場所 | 何を置くか | 寿命 | 例 |
|---|---|---|---|
| `State`（Zig） | 正しさが要るもの、再起動後も残したいもの | アプリの起動中（必要なら保存） | todo の一覧、ログイン、ファイルパス |
| フロントのメモリ | 見た目だけのもの | 画面を閉じるまで | 開いているタブ、スクロール位置、ホバー |
| 入力途中の値 | まだ送っていない文字 | 1 フォーム | 検索ボックスの下書き |

**迷ったら「間違っていたら困るか」で決めます。** 困るなら Zig、困らないならフロントです。

## 動く例: 状態は引数で受け取る

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const Counter = struct {
    count: i32 = 0,
    /// 何回目の更新か。画面はこれを「保存済み」の表示に使う（衝突検出にも使える）。
    revision: u32 = 0,
};

const Commands = struct {
    pub const RpcState = Counter;

    pub fn bump(state: *Counter, args: struct { by: i32 = 1 }) !i32 {
        state.count += args.by;
        state.revision += 1;
        return state.count;
    }

    /// 状態を変えないコマンドは `*const` で受ける。読むだけだと型で分かる。
    pub fn current(state: *const Counter) i32 {
        return state.count;
    }
};

pub const Schema = rpc.Schema(.{ .app = Commands });

test "the state is an ordinary value, so a test is a value" {
    var state = Counter{};
    try std.testing.expectEqual(@as(i32, 1), try Commands.bump(&state, .{}));
    try std.testing.expectEqual(@as(i32, 4), try Commands.bump(&state, .{ .by = 3 }));
    try std.testing.expectEqual(@as(i32, 4), Commands.current(&state));
    try std.testing.expectEqual(@as(u32, 2), state.revision);
}
```

`State` がただの構造体なので、テストは `Counter{}` を作って関数を呼ぶだけです。グローバル変数を
使うとこの形が壊れ、テストは「前のテストが残した状態」に依存しはじめます。

## 育つ書き方 / 壊れる書き方

| 判断 | 育つ | 壊れる | なぜ |
|---|---|---|---|
| 状態の受け取り | `*State` を引数で | `var global: State` | テストが順番に依存し、並列実行で落ちる |
| 読むだけのコマンド | `*const State` | `*State` | 変更しないと型で表明できる |
| 状態の初期化 | `State.init(allocator)` | `State{}` + 後から代入 | メモリの所有者が曖昧になる（下記） |
| 永続化 | 明示的な `save` / `load` コマンド | コマンドのたびにファイル書き込み | 1 操作 = 1 保存になり、失敗時の巻き戻しが効かない |
| 一時的な値 | フロントに置く | Zig に送って戻す | 往復だけで 1 コマンド増える |

### メモリの所有者を 1 人にする

`[]const u8` を受け取って状態に残すなら、**状態がコピーを持つ**のが安全です。呼び出し元の
バッファは JSON のデコード結果で、ハンドラが返った後に解放されるからです。

```zig check
const std = @import("std");

const Named = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) Named {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }
    fn deinit(self: *Named) void {
        self.arena.deinit();
    }
    fn keep(self: *Named, text: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, text);
    }
};

test "keep copies, so the caller may reuse its buffer" {
    var named = Named.init(std.testing.allocator);
    defer named.deinit();

    var scratch = [_]u8{ 'h', 'i' };
    const kept = try named.keep(&scratch);
    scratch[0] = 'X';
    try std.testing.expectEqualStrings("hi", kept);
}
```

### before → after: 変更を積む

```zig ignore
// before: 画面が「何をしたか」を知らないので、毎回全部を取り直す
pub fn setFilter(state: *State, args: struct { text: []const u8 }) !void { ... }
// 画面: await invoke("setFilter", ...); await invoke("list", {});  // 往復 2 回

// after: 変更を 1 つ返す。画面はその 1 つを差し替える
pub fn setFilter(state: *State, args: struct { text: []const u8 }) !Snapshot { ... }
```

## なぜそうなるか

状態を Zig に置く利点は**検証と保存を同じ場所でできる**ことです。「在庫があれば注文できる」
という規則は、在庫を持っている側でしか正しく判定できません。フロントに写しを持つと、
2 つの真実ができ、片方だけ古くなります（`toggleTodo` を 2 つのタブから呼んだときに起きます）。

一方で、**見た目だけの状態を Zig に置くと往復が増えます**。タブの選択はサーバを知る必要が
ありません。判断は「間違っていたら困るか」の 1 問で足ります。

## 練習

### 1. どこに置くか

次の 3 つは Zig とフロントのどちらに置きますか。

1. 検索ボックスに入力中の文字
2. `examples/counter` のカウント（再起動しても残したい）
3. モーダルが開いているか

<details>
<summary>答え</summary>

1. **フロント**。まだ検索していない下書きです。送るのは Enter か「検索」を押したときだけにすると
   往復が減り、入力中のちらつきも消えます。
2. **Zig**（+ 明示的な保存）。再起動後に残すなら、状態は Zig が持ち、`save` コマンドで
   ファイルに書きます。書き込みは操作ごとではなく、区切りのよいところで。
3. **フロント**。見た目だけです。Zig に置くと「開く」「閉じる」で往復が 2 回増え、
   ネットワークが詰まったときにモーダルが開かない事故が起きます。

</details>

### 2. `*const` にする

`pub fn list(state: *State) []const Todo` を `*const` にできますか。できない場合はなぜですか。

<details>
<summary>答え</summary>

`list` が `state.todos.items` を返すだけなら **`*const State` にできます**（読むだけ）。
できないのは、遅延初期化・ソート・キャッシュ更新など**読むついでに書き換える**場合です。
その場合は「読むだけに見えるコマンドが状態を変えている」というサインなので、
`refresh` のような名前のコマンドに分けるか、初期化を `init` に寄せてください。

</details>

---

## 次に読むもの

- 失敗をどう返すか: [エラーの設計](errors.md)
- 実際の `State` の例: [`examples/counter`](../../../../examples/counter/README.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
