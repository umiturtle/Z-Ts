# エラーの設計

> **対象読者**: `!T` を返すコマンドを書きはじめた人。エラー文言を Zig に書きたくなった人。
> **所要時間**: 5 分（練習 3 問で +15 分）。
> **前提**: [コマンドの設計](commands.md)。

ziggurats では、コマンドのエラーは **`error{…}` の名前だけ**が画面に届きます。

```text
Zig:   return error.OutOfStock;
JS:    { ok: false, error: { code: "OutOfStock" } }
```

**文言は画面が持ちます。** 理由は 3 つです。

1. 多言語化は表示側の仕事（Zig に日本語を書くと 2 言語目で破綻する）
2. 同じエラーでも画面によって出し方が違う（一覧では toast、フォームでは項目の下）
3. `error{}` は型なので、**どのエラーが返り得るかが生成される TypeScript に出る**

## 動く例

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const Order = struct {
    item: []const u8,
    quantity: u32,
};

const Shop = struct {
    stock: u32 = 3,
};

const Commands = struct {
    pub const RpcState = Shop;

    /// `invoke("order", { item: "pen", quantity: 2 })`
    /// 失敗: `EmptyOrder` / `TooMany` / `OutOfStock`
    pub fn order(state: *Shop, args: struct { item: []const u8, quantity: u32 }) !Order {
        // ① 境界で 1 回だけ検証する。内部の関数は「正しい入力」を前提にできる。
        if (args.item.len == 0) return error.EmptyOrder;
        if (args.quantity == 0 or args.quantity > 100) return error.TooMany;
        if (args.quantity > state.stock) return error.OutOfStock;

        state.stock -= args.quantity;
        return Order{ .item = args.item, .quantity = args.quantity };
    }
};

pub const Schema = rpc.Schema(.{ .app = Commands });

test "each refusal has its own name, and none of them is generic" {
    var shop = Shop{};
    try std.testing.expectError(error.EmptyOrder, Commands.order(&shop, .{ .item = "", .quantity = 1 }));
    try std.testing.expectError(error.TooMany, Commands.order(&shop, .{ .item = "pen", .quantity = 0 }));
    try std.testing.expectError(error.OutOfStock, Commands.order(&shop, .{ .item = "pen", .quantity = 4 }));
    try std.testing.expectEqual(@as(u32, 1), (try Commands.order(&shop, .{ .item = "pen", .quantity = 2 })).quantity);
    try std.testing.expectEqual(@as(u32, 1), shop.stock);
}
```

## 育つ書き方 / 壊れる書き方

| 判断 | 育つ | 壊れる | なぜ |
|---|---|---|---|
| エラーの粒度 | 画面が**違う対応**をする単位 | `error.Failed` 1 つ | 文言も再試行も分けられない |
| 文言 | フロントの翻訳表 | `error.Invalid_title_please_retry` | 名前が UI になり、言語を足せない |
| 検証の場所 | コマンドの先頭で 1 回 | 内部の 3 関数でそれぞれ | 同じ検査が散り、片方だけ抜ける |
| 想定内の分岐 | 戻り値に含める（`status` など） | `error{}` にする | 「在庫 0」は失敗ではなく**結果**のことがある |
| panic | 使わない | `unreachable` で済ませる | WebView ごと落ちる。利用者は原因を知れない |
| 途中で失敗する更新 | 変更前に検証し、失敗時は何も変えない | 半分書き換えて `return error` | 画面と状態がずれる（最悪、二度と直せない） |

### before → after: 汎用エラーを分ける

```zig ignore
// before: 画面は「だめだった」しか言えない
pub fn save(state: *State, args: struct { path: []const u8, body: []const u8 }) !void {
    if (args.path.len == 0) return error.Failed;
    const file = open(args.path) catch return error.Failed;
    file.write(args.body) catch return error.Failed;
}

// after: 呼び出し側が「パスを直す」「容量を空ける」「権限を変える」を選べる
pub fn save(state: *State, args: struct { path: []const u8, body: []const u8 }) !Meta {
    if (args.path.len == 0) return error.InvalidPath;
    const file = open(args.path) catch |err| switch (err) {
        error.AccessDenied => return error.PermissionDenied,
        error.FileNotFound => return error.NoSuchDirectory,
        else => return error.IoFailed,
    };
    file.write(args.body) catch return error.DiskFull;
    return .{ .bytes = args.body.len };
}
```

「握りつぶして 1 つにまとめる」は、**Zig 側が原因を知っているのに画面に渡さない**選択です。
`switch` を書く手間より、画面が正しい対処を出せる価値の方が大きいです。

### before → after: 途中で失敗しない

```zig ignore
// before: 1 件目を書いた後に 2 件目で失敗し、状態だけ進む
for (items) |item| try append(item);

// after: 先に全部検証し、書けると分かってから書く
for (items) |item| try validate(item);
for (items) |item| try append(item);
```

全部を先に検証できないときは、**戻せる形**にします（一時ファイル → rename、トランザクション、
`errdefer` での巻き戻し）。

## なぜそうなるか

`zts_rpc` はコマンドの戻り値の型から TypeScript を生成します。`!Order` は
`RpcResult<Order, "EmptyOrder" | "TooMany" | "OutOfStock">` になり、`switch (res.error.code)` を
**網羅しないとコンパイラが通しません**。エラー名を増やすほど、画面側の分岐漏れが減ります。
逆に `error.Failed` だけだと、型は `"Failed"` 1 つになり、何も守れません。

「在庫 0」のように**利用者が次にできることがある**ものは、エラーではなく戻り値にする選択肢も
あります。たとえば `order` が `union(enum) { placed: Order, backordered: u32 }` を返せば、
画面は「入荷待ち」を通常の表示として扱えます。**失敗＝例外**ではなく、
「呼び出し側が分岐すべき結果」かどうかで選んでください。

## 練習

### 1. エラー名を分ける

ファイルを開くコマンドが `error.IoFailed` だけを返しています。画面は何を出せますか。
分けるとしたらどう分けますか。

<details>
<summary>答え</summary>

出せるのは「失敗しました」だけです。分けるなら、利用者の**次の行動**が変わる単位で分けます。

| 名前 | 画面が出すこと |
|---|---|
| `PermissionDenied` | 「アクセス権がありません。別の場所を選んでください」 |
| `NoSuchDirectory` | 「保存先がありません。作成しますか？」（+ 作成コマンド） |
| `DiskFull` | 「空き容量が足りません」 |
| `IoFailed` | 「読み書きに失敗しました」＋再試行ボタン |

分けすぎも害があります。`IoFailed` に落ちるものは 1 つにまとめ、**画面の対応が同じものは
同じ名前**にしてください。

</details>

### 2. 境界で検証する

`rename(state, { id, name })` が `name` の長さを内部の 3 関数でそれぞれ検査しています。
どう直しますか。

<details>
<summary>答え</summary>

コマンドの先頭で 1 回だけ検査し、内部の関数は「名前は 1〜64 文字」を**前提**にします。

```zig ignore
pub fn rename(state: *State, args: struct { id: u32, name: []const u8 }) !Todo {
    if (args.name.len == 0 or args.name.len > 64) return error.InvalidName;
    return renameInner(state, args.id, args.name);
}
```

前提はコメントではなく**型**にできると更好です（`Name` のような長さ検証済みの型を作る）。
少なくとも、検査が 1 か所にあれば、上限を変えるときに 1 行で済みます。

</details>

### 3. これはエラーか、結果か

「メールアドレスが既に登録されている」は `error{}` と戻り値のどちらにしますか。

<details>
<summary>答え</summary>

**どちらでも動きますが、既定は戻り値**です。理由は、重複が**想定内の結果**であり、
画面が「ログインしますか？」という次の行動を出すからです。

```zig ignore
pub const RegisterResult = union(enum) {
    created: User,
    already_registered: void,
};

pub fn register(state: *State, args: struct { email: []const u8 }) !RegisterResult { ... }
```

一方、`InvalidEmail`（形式が違う）はエラーです。画面は入力を直させるだけで、
続行の選択肢がありません。**「利用者に次の選択肢があるか」**が分かれ目です。

</details>

---

## 次に読むもの

- 画面側の扱い: [画面とロジックの境界](boundaries.md)
- エラーの一覧: [エラー索引](../../../reference/errors.html)
- 生成される型: [API リファレンス](../../../api/index.html) の `zts_rpc.tsgen`
