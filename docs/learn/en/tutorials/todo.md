# Tutorial: build a todo list

> **Audience**: you finished [the counter](counter.md). Zig basics assumed.
> **Time**: 20 minutes to type it in (plus 15 for the exercises).
> **Prerequisites**: `zts` and Zig 0.17 on `PATH`, and [the counter](counter.md) up to chapter 3.

The counter was one number. This is a **list**: many items, three commands, and two real failures
(an empty title, an id that is gone). What you practise here is the part that keeps an app alive
after it starts growing.

| What you learn | What you write |
|---|---|
| keep the state in one struct | `State` |
| one verb → one command | `addTodo` / `toggleTodo` / `removeTodo` |
| failures are `error{…}`; the sentence is the UI's job | `error.EmptyTitle` / `error.NotFound` |
| tests call the commands directly | `std.testing` |

> [!TIP]
> The *why* behind the shapes is in [Patterns](../patterns/index.md). This page is about getting
> something running; if a choice puzzles you, keep going and come back.

---

## 1. Put the state in one struct

`State` is the app's only mutable data. Commands take it as `*State` and touch nothing else (no
globals — with two globals you cannot run two tests at the same time).

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

test "titles are copied into the state's arena" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    const title = try state.arena.allocator().dupe(u8, "milk");
    try state.todos.append(state.allocator, .{ .id = 1, .title = title });
    try std.testing.expectEqualStrings("milk", state.todos.items[0].title);
}
```

The `arena` is there because the `"milk"` in `invoke("addTodo", { title: "milk" })` arrives in the
**request buffer**. Storing that slice directly means the next request overwrites it. Copy into
memory the state owns, then store.

## 2. Write three commands

`add` / `toggle` / `remove`. **Different verbs get different commands** (not one `setTodo` with an
`action: "toggle"` argument — see [Designing commands](../patterns/commands.md)).

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

    /// `invoke("addTodo", { title: "milk" })` → the new todo
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

test "add / toggle / remove work as one flow" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectError(error.EmptyTitle, Commands.addTodo(&state, .{ .title = "" }));

    const milk = try Commands.addTodo(&state, .{ .title = "milk" });
    _ = try Commands.addTodo(&state, .{ .title = "bread" });
    try std.testing.expectEqual(@as(u32, 1), milk.id);
    try std.testing.expectEqual(@as(usize, 2), (try Commands.listTodos(&state)).len);

    const toggled = try Commands.toggleTodo(&state, .{ .id = milk.id });
    try std.testing.expect(toggled.done);

    try Commands.removeTodo(&state, .{ .id = milk.id });
    try std.testing.expectError(error.NotFound, Commands.removeTodo(&state, .{ .id = milk.id }));
    try std.testing.expectEqual(@as(usize, 1), (try Commands.listTodos(&state)).len);
}
```

CI compiles this block. Forgetting `RpcState` fails with
`command 'app.addTodo' has multiple payload parameters` — the error names the cause
(see [Designing errors](../patterns/errors.md)).

A command whose only parameter is the state (`listTodos(state: *State)`) does not need it; only the
ones with **one more parameter** do.

## 3. Return failures the UI can act on

| Error | When | What the page does |
|---|---|---|
| `error.EmptyTitle` | someone submitted an empty title | mark the input, show "type something"; do **not** resend |
| `error.NotFound` | the id is already gone | re-read the list (another tab may have removed it) |

Both are returned as **types, not strings**. The sentence lives in the frontend so the Zig side
does not have to carry every translation. JS receives a `code`.

```ts
import { invoke } from "@tauri-apps/api/core";

async function add(title: string) {
  try {
    return await invoke("addTodo", { title });
  } catch (err) {
    // err is { code: "EmptyTitle" } -> the page decides the sentence
    const code = (err as { code?: string }).code ?? "Unknown";
    showMessage(code === "EmptyTitle" ? "Please type something" : "Could not add it");
  }
}
```

## 4. Call it from the page

Put the list and the input in `web/index.html` and make **one interaction = one command**. Draw only
from what came back (the page does not keep a second copy of the truth).

```html
<ul id="todos"></ul>
<form id="add">
  <input id="title" placeholder="Something to do" aria-label="Something to do" />
  <button>Add</button>
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
      message.textContent = err.code === "EmptyTitle" ? "Please type something" : "Could not add it";
    }
  });

  render();
</script>
```

## 5. Run it

```bash
zts dev          # updates on save (CSS swaps in place, no reload)
zts build        # zig-out/bin/my_app
```

`zts dev` serves `web/`; it does **not** run the Zig app, so `invoke` has no counterpart there.
Run the binary from `zts build` when you want to exercise the round trip (same caveat as
[the counter](counter.md), chapter 2).

## Exercises

<details>
<summary>1. You add a "clear all" command. What changes in `State`?</summary>

Nothing. Add `clearTodos(state: *State) !void` and call `state.todos.clearRetainingCapacity()`.
Keep `next_id` monotonic: resetting it makes a stale `toggleTodo` from another tab hit a
**different** item.
</details>

<details>
<summary>2. `toggleTodo` returned `error.NotFound`. What should the page do?</summary>

Re-read the list. Another tab may have removed the item, so the page's copy is stale. Showing a
message alone leaves the ghost row on screen.
</details>

<details>
<summary>3. Why return the new `Todo` from `addTodo` instead of `void`?</summary>

Without the id, the page has to re-fetch the whole list after every add. The return value should be
"what the page draws next" (see [Designing commands](../patterns/commands.md)).
</details>

---

## Read this with another library

**The Zig side is identical for every library** (`State`, the three commands, `error{}`, the
tests). Only list rendering changes: read the "State" column above in your library's idiom (React
`useState`, Svelte `let`, and so on).

<!-- framework-picker -->

The nine branches of this tutorial. The Zig side is identical in all of them.

| Library | This tutorial's branch |
|---|---|
| React | [Todo with React](todo-react.md) |
| Solid | [Todo with Solid](todo-solid.md) |
| Svelte | [Todo with Svelte](todo-svelte.md) |
| Angular | [Todo with Angular](todo-angular.md) |
| Next.js | [Todo with Next.js](todo-next.md) |
| Nuxt | [Todo with Nuxt](todo-nuxt.md) |
| Astro | [Todo with Astro](todo-astro.md) |
| SvelteKit | [Todo with SvelteKit](todo-sveltekit.md) |
| SolidStart | [Todo with SolidStart](todo-solidstart.md) |

The [chooser hub](frameworks.md) lists every real example.

## Where to go next

| Want to know | Go to |
|---|---|
| why these shapes, with exercises | [Patterns](../patterns/index.md) |
| argument types, return values, TypeScript generation | [Guide: commands](../guides/rpc.md) |
| persist the list to a file | [Guide: plugins](../guides/plugins.md) (`plugin:fs`) |
| the page itself (states, CSS, CSP) | [Tutorial: build the screen](ui.md) |
| something is broken | [Troubleshooting](../guides/troubleshooting.md) |

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
