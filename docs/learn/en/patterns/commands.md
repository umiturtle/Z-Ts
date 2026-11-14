# Designing commands

> **Audience**: anyone who has written three or more `invoke("…")` calls and is wondering how to
> keep adding them.
> **Time**: 6 minutes (+15 for the three exercises).
> **Before this**: [How it works: commands](../concepts/commands.md) and
> [Tutorials](../tutorials/index.md).

A command is a **boundary**: the only Zig the page can see, and the only page Zig can see.
That is why the shape you pick decides whether a later one-line change takes a minute or an hour.

## A working example

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

    /// `invoke("addTodo", { title: "milk" })` → the todo that was added
    pub fn addTodo(state: *State, args: struct { title: []const u8 }) !Todo {
        if (args.title.len == 0) return error.EmptyTitle;
        const todo = Todo{ .id = state.next_id, .title = try state.arena.allocator().dupe(u8, args.title) };
        state.next_id += 1;
        try state.todos.append(state.allocator, todo);
        return todo;
    }

    /// `invoke("toggleTodo", { id: 3 })` → the todo after the toggle
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
    const first = try Commands.addTodo(&state, .{ .title = "milk" });
    try std.testing.expectEqual(@as(u32, 1), first.id);
    try std.testing.expectEqual(false, first.done);
}
```

Four things matter.

1. **Verb + noun** (`addTodo`, `toggleTodo`). No screen vocabulary (`handleClick`) in the name
2. **One struct for the arguments.** `Schema` accepts a single payload; a second one is a compile
   error. Declaring `RpcState` is what stops `*State` from being mistaken for an argument
3. **The return value is what the page needs to draw next** — here the updated `Todo`
4. **State arrives as `*State`.** No globals, so a test is just `State.init(...)`

## The shape that grows / the shape that breaks

| Decision | Grows | Breaks | Why |
|---|---|---|---|
| granularity | one command per verb | `applyAction(action: enum)` | the payload collapses into an enum; every screen grows a branch |
| relation to screens | one per action | one per screen (`getHomeScreen`) | every new screen adds a Zig function, and logic leaks into the UI |
| arguments | `struct { id: u32 }` | `id: u32, force: bool, note: ?[]const u8` | the third one fails to compile; start with a struct |
| return value | the minimum the page draws | `bool` / `void` | after `true`, the page has to re-fetch to learn what changed |
| naming | `addTodo` / `markDone` | `doTodo` / `todo1` | you cannot recover the meaning in six months |
| failure | `error{…}` | everything as `error.Failed` | the UI cannot tell the cases apart ([errors](errors.md)) |

### before → after: stop writing one command per screen

```zig ignore
// before: every screen adds a Zig function, and the same work lives in three places
pub fn homeScreen(state: *State) !Screen { ... }
pub fn detailScreen(state: *State, args: struct { id: u32 }) !Screen { ... }
pub fn settingsScreen(state: *State) !Screen { ... }

// after: three actions. Screens can multiply freely — the UI just arranges the same commands.
pub fn listTodos(state: *State) ![]const Todo { ... }
pub fn toggleTodo(state: *State, args: struct { id: u32 }) !Todo { ... }
pub fn clearDone(state: *State) !u32 { ... }   // returns how many were removed
```

A "screen" is a front-end concept; Zig knows **actions**. Cross that line and Zig starts learning
about tab order and modals, and your tests become screen tests.

### before → after: do not return `void`

```zig ignore
// before: the page only knows "it worked" and has to read everything again
pub fn rename(state: *State, args: struct { id: u32, name: []const u8 }) !void { ... }

// after: the page draws exactly what came back
pub fn rename(state: *State, args: struct { id: u32, name: []const u8 }) !Todo { ... }
```

`void` is right when the page truly redraws nothing (telemetry, a preference applied in place).
When unsure, ask "what does the caller draw next?" — if there is an answer, return it.

## Why

The `invoke` boundary **serialises**. Arguments and return values become JSON, and an `enum`
branch means both sides must agree on the strings. Split into separate commands and
`zts_rpc.tsgen` gives each one its own TypeScript type (`RpcResult<T, E>`), so changing one side
**fails to compile**. Collapse everything into one big command and the type becomes "a box that
holds anything" — the compiler stops protecting you.

The same argument applies to `bool`. Information is lost, and the page replaces it with a second
call ("fetch again"), which doubles the round trips.

## Exercises

### 1. Split `toggleTodo`?

What do you gain and lose by splitting "mark done" and "mark open" into two commands?

<details>
<summary>Answer</summary>

**Gain**: the caller no longer has to know the current state (`markDone` is idempotent).
**Lose**: two commands now write the same data, so both must uphold the invariant (forget
`updated_at` in one of them and the data quietly diverges).

Decide by **what the action means**. If "toggle" is the UI's word, one command is enough. If
"done" is the domain's word (an audit log, a notification), split — and share the internals
(`fn setDone(state: *State, id: u32, done: bool) !Todo`) so the commands stay thin entry points.

</details>

### 2. Arguments as a struct

What happens if you put `pub fn search(state: *State, query: []const u8, limit: u32) ![]const Todo`
into `Schema`, and how do you fix it?

<details>
<summary>Answer</summary>

`zts_rpc.Schema` allows **one payload parameter**; the second is a compile error
(`has multiple payload parameters`). The fix:

```zig ignore
pub fn search(state: *State, args: struct { query: []const u8, limit: u32 = 20 }) ![]const Todo
```

A default on `limit` means `invoke("search", { query: "milk" })` works too, and the default lives
in exactly one place instead of being repeated in every screen.

</details>

### 3. Choose a return value

For "save settings", which return value do you pick, and why?

1. `void`
2. `bool` (did it work)
3. `struct { saved_at: i64, revision: u32 }`

<details>
<summary>Answer</summary>

**3**, by default. `revision` detects conflicts in optimistic updates; `saved_at` is exactly what a
"saved" badge needs. Choose `void` only when you are **certain** the page redraws nothing
(startup telemetry). Never `bool`: failure is already expressed by `error{}`, and `false` tells the
caller nothing.

</details>

---

## Next

- Where state lives: [Where state lives](state.md)
- How to report failure: [Designing errors](errors.md)
- The generated types: [API reference](../../../api/index.html), `zts_rpc` section

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
