# Designing errors

> **Audience**: readers writing their first `!T` commands, or itching to put prose in Zig.
> **Time**: 5 minutes (+15 for the three exercises).
> **Before this**: [Designing commands](commands.md).

In ziggurats, only the **name** of an error reaches the page.

```text
Zig:   return error.OutOfStock;
JS:    { ok: false, error: { code: "OutOfStock" } }
```

**The wording lives in the page.** Three reasons.

1. translation belongs to the display side (Japanese in Zig breaks the moment there is a second
   language)
2. the same error is shown differently by screen (a toast in a list, a field hint in a form)
3. `error{}` is a type, so **the generated TypeScript lists exactly what can fail**

## A working example

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
    /// failures: `EmptyOrder` / `TooMany` / `OutOfStock`
    pub fn order(state: *Shop, args: struct { item: []const u8, quantity: u32 }) !Order {
        // 1. Validate once, at the boundary. Everything below may assume valid input.
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
    try std.testing.expectEqual(@as(u32, 2), (try Commands.order(&shop, .{ .item = "pen", .quantity = 2 })).quantity);
    try std.testing.expectEqual(@as(u32, 1), shop.stock);
}
```

## The shape that grows / the shape that breaks

| Decision | Grows | Breaks | Why |
|---|---|---|---|
| granularity | one name per **different UI response** | a single `error.Failed` | neither wording nor retry can differ |
| wording | a translation table in the page | `error.Invalid_title_please_retry` | the name becomes UI, and a second language is impossible |
| validation | once, at the top | in each of three inner functions | the checks drift, and one copy goes missing |
| expected outcomes | part of the return value (`status`) | modelled as `error{}` | "out of stock" is often a **result**, not a failure |
| panic | never | `unreachable` | it takes the WebView down and the user learns nothing |
| multi-step updates | validate first, mutate after | mutate halfway, then `return error` | page and state disagree (sometimes permanently) |

### before → after: split the generic error

```zig ignore
// before: the page can only say "that did not work"
pub fn save(state: *State, args: struct { path: []const u8, body: []const u8 }) !void {
    if (args.path.len == 0) return error.Failed;
    const file = open(args.path) catch return error.Failed;
    file.write(args.body) catch return error.Failed;
}

// after: the caller can fix the path, free space, or change permissions
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

Collapsing everything into one name is a choice to **throw away a cause Zig already knows**. The
`switch` costs a few lines; the page gains the ability to offer the right next step.

### before → after: do not fail halfway

```zig ignore
// before: the first item is written, the second fails, and the state has moved on
for (items) |item| try append(item);

// after: prove it can be written, then write
for (items) |item| try validate(item);
for (items) |item| try append(item);
```

When you cannot validate everything up front, make it **reversible**: temp file then rename,
a transaction, or `errdefer` to roll back.

## Why

`zts_rpc` generates TypeScript from the command's return type. `!Order` becomes
`RpcResult<Order, "EmptyOrder" | "TooMany" | "OutOfStock">`, and a `switch (res.error.code)` that
misses a case does not compile. More names means fewer forgotten branches. A single
`error.Failed` produces a type with one member, which protects nothing.

There is a second option for outcomes the user can act on: return them. `order` could return
`union(enum) { placed: Order, backordered: u32 }`, and the page renders "backordered" as a normal
state. Choose by asking **"is this a branch the caller must handle, or is it a failure?"**

## Exercises

### 1. Split the error

A command that opens a file only ever returns `error.IoFailed`. What can the page say? How would
you split it?

<details>
<summary>Answer</summary>

Only "something went wrong". Split by **what the user can do next**:

| Name | What the page shows |
|---|---|
| `PermissionDenied` | "No access — pick another location" |
| `NoSuchDirectory` | "That folder does not exist. Create it?" (+ a create command) |
| `DiskFull` | "Not enough free space" |
| `IoFailed` | "Read/write failed" + retry |

Do not over-split. Keep one `IoFailed` for the cases whose response is the same.

</details>

### 2. Validate at the boundary

`rename(state, { id, name })` checks the length of `name` in three inner functions. Fix it.

<details>
<summary>Answer</summary>

Check once at the top of the command and let the inner functions **assume** a valid name.

```zig ignore
pub fn rename(state: *State, args: struct { id: u32, name: []const u8 }) !Todo {
    if (args.name.len == 0 or args.name.len > 64) return error.InvalidName;
    return renameInner(state, args.id, args.name);
}
```

Better still, make the assumption a **type** (`Name`, validated on construction). At minimum keep
one check in one place, so changing the limit is one edit.

</details>

### 3. Error or result?

Is "this email is already registered" an `error{}` or a return value?

<details>
<summary>Answer</summary>

**Either works; default to the return value.** Duplicates are an expected outcome, and the page
wants to offer a next step ("log in instead?").

```zig ignore
pub const RegisterResult = union(enum) {
    created: User,
    already_registered: void,
};

pub fn register(state: *State, args: struct { email: []const u8 }) !RegisterResult { ... }
```

`InvalidEmail` (malformed) stays an error: the user must fix the input and there is nothing to
choose. The dividing line is **"does the user have a next step?"**

</details>

---

## Next

- The page side: [The page/logic boundary](boundaries.md)
- Every error code: [Error index](../../../reference/errors.html)
- The generated types: [API reference](../../../api/index.html), `zts_rpc.tsgen`

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
