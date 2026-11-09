# Where state lives

> **Audience**: readers who keep wondering whether a piece of state belongs to the page or to Zig.
> **Time**: 5 minutes (+12 for the two exercises).
> **Before this**: [Designing commands](commands.md).

State is not "something you put somewhere"; it is a decision about **who is responsible for being
right**. ziggurats gives you three places.

| Place | What goes there | Lifetime | Example |
|---|---|---|---|
| `State` (Zig) | anything that must be correct, anything that outlives the window | the app's lifetime (persist explicitly) | the todo list, a login, a file path |
| Page memory | appearance only | until the page closes | the open tab, scroll position, hover |
| Half-typed text | what has not been sent yet | one form | a draft in the search box |

**Ask "does it hurt if this is wrong?"** If yes, Zig. If no, the page.

## A working example: state arrives as a parameter

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const Counter = struct {
    count: i32 = 0,
    /// Which update this is. The page uses it for a "saved" badge (and for conflict detection).
    revision: u32 = 0,
};

const Commands = struct {
    pub const RpcState = Counter;

    pub fn bump(state: *Counter, args: struct { by: i32 = 1 }) !i32 {
        state.count += args.by;
        state.revision += 1;
        return state.count;
    }

    /// A command that does not mutate takes `*const`, so the signature says so.
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

`State` is a plain struct, so a test is `Counter{}` and a function call. A global breaks that and
makes tests depend on whatever the previous test left behind.

## The shape that grows / the shape that breaks

| Decision | Grows | Breaks | Why |
|---|---|---|---|
| passing state | `*State` parameter | `var global: State` | tests become order-dependent and fail under parallelism |
| read-only commands | `*const State` | `*State` | the signature can promise "I do not mutate" |
| initialisation | `State.init(allocator)` | `State{}` then assign | ownership of memory becomes ambiguous |
| persistence | explicit `save` / `load` commands | writing a file inside every command | one action becomes one save, and rollback stops working |
| transient values | keep them in the page | send and read them back | a round trip per keystroke |

### One owner for the memory

If you keep a `[]const u8` you received, **let the state own a copy**. The caller's buffer is a
decode result that is freed when the handler returns.

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

### before → after: return the change

```zig ignore
// before: the page does not know what happened, so it fetches everything again
pub fn setFilter(state: *State, args: struct { text: []const u8 }) !void { ... }
// page: await invoke("setFilter", ...); await invoke("list", {});   // two round trips

// after: return the one thing that changed; the page swaps it in
pub fn setFilter(state: *State, args: struct { text: []const u8 }) !Snapshot { ... }
```

## Why

Keeping state in Zig lets you **validate and persist in the same place**. "You may order only if
there is stock" can only be decided by whoever holds the stock. A copy in the page creates two
truths, and one of them goes stale (call `toggleTodo` from two tabs and watch it happen).

The reverse is also true: **appearance-only state in Zig adds round trips**. Which tab is selected
does not need a server. One question settles it: does it hurt if this is wrong?

## Exercises

### 1. Where does it go?

Zig or the page?

1. the text currently in a search box
2. the count in `examples/counter` (which should survive a restart)
3. whether a modal is open

<details>
<summary>Answer</summary>

1. **The page.** It is a draft that has not been searched yet. Sending only on Enter (or a button)
   removes round trips and the flicker while typing.
2. **Zig** (plus explicit saving). Keep the value in Zig and write it from a `save` command at
   sensible boundaries, not on every increment.
3. **The page.** Appearance only. In Zig it costs two round trips and turns a slow network into a
   modal that will not open.

</details>

### 2. Make it `*const`

Can `pub fn list(state: *State) []const Todo` take `*const State`? When can it not?

<details>
<summary>Answer</summary>

If it only reads `state.todos.items`, **yes** — make it `*const`. It cannot when it writes as a
side effect: lazy initialisation, sorting, refreshing a cache. That is a signal: a command that
looks read-only is mutating. Either split it into a `refresh` command or move the initialisation
into `init`.

</details>

---

## Next

- How to report failure: [Designing errors](errors.md)
- A real `State`: [`examples/counter`](../../../../examples/counter/README.md)
