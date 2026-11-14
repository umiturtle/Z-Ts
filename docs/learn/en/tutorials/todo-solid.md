# Tutorial: build a Todo list with Solid

> **Audience**: you know `Solid` but are new to ziggurats commands.
> **Time**: 20 minutes (type it in and it runs).
> **Prerequisites**: [Build a counter](counter.md) (10 minutes).

This is the **`Solid 1.9` version of [Build a Todo list](todo.md)**. The Zig side
(`State`, `addTodo` / `toggleTodo` / `removeTodo`, the `error{}` set and the tests) does not change
**by a single character**. Only `web/` changes: how the list state is held and rendered.
[Pick another library](frameworks.md) at any time.

<!-- framework-picker -->

| Chapter | What you do | When you are done |
|---|---|---|
| [0](#0-prerequisites) | check prerequisites | `zts doctor` is green |
| [1](#1-translate-the-state) | learn the state primitive | `createSignal(0)` holds a list |
| [2](#2-the-zig-side-is-shared) | copy the three commands | `zig check` passes |
| [3](#3-render-the-list) | render from `listTodos` | add / toggle / remove appear |
| [4](#4-no-optimistic-updates) | draw only from results | UI and Zig agree |
| [5](#5-two-states-local-and-zigs) | signals vs Zig | you can explain the seal |
| [6](#6-run-it) | `zts build` | a single binary |

---

## 0. Prerequisites

| Item | Requirement |
|---|---|
| `zts` | one release binary on `PATH`, per [`install.md`](../guides/install.md) |
| Zig | 0.17 on `PATH` or in `ZTS_ZIG` |
| Node.js | only if you rebuild `Solid` yourself |
| Project | the `my-app` you made in [Build a counter](counter.md) |

```bash
cd my-app
zts doctor       # all checks passed
```

## 1. Translate the state

`createSignal(0)` returns a `[getter, setter]` pair. **Only the DOM nodes that read it** update, and the component function runs exactly once. `count` is a function, so JSX calls `count()`.

Use `createSignal<Todo[]>([])` with `<For each={todos()}>`. `<For>` is keyed and reuses DOM nodes instead of rebuilding them like `map`.

The plain-JS version used `let todos = []` and built HTML with
`innerHTML`; only that part is swapped here. **Zig's `State` is not swapped.**

## 2. The Zig side is shared

Copy the `zig check` block from [Build a Todo list](todo.md#2-write-three-commands) into
`src/main.zig`. All three commands, their arguments and the `error{}` set are identical in every
library. Short recap of the skeleton:

```zig
const Todo = struct { id: u32, title: []const u8, done: bool = false };
const State = struct { todos: std.ArrayList(Todo) = .empty };
const Commands = struct {
    pub fn listTodos(state: *State) ![]const Todo { return state.todos.items; }
    // addTodo / toggleTodo / removeTodo come from todo.md's zig check block
};
pub const Schema = rpc.Schema(.{ .app = Commands });
```

> [todo.md](todo.md) is the source of truth. The skeleton above only shows what is shared; copy the
> real `zig check` block when you type it in.

## 3. Render the list

```jsx
const [todos, setTodos] = createSignal<Todo[]>([]);

async function refresh() {
  setTodos(await invoke<Todo[]>("listTodos"));
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // Zig から読み直す
}
// <For each={todos()}>{(t) => <li>{t.title}</li>}</For>
```

`refresh()` re-reads `listTodos` and is called after **every** add / toggle / remove. Pushing into a
local array makes the UI drift away from Zig's `State`.

## 4. No optimistic updates

Same rule as [Build a screen](ui.md#4-draw-only-from-what-came-back): when `invoke` rejects, **do not
change state**, switch to the error view instead. Call `setCount(r.count)` exactly once, after Zig replies. Fine-grained updates hide a run-ahead UI, so keep two signals (local counter and Zig counter) to make the source of truth obvious.

```jsx
const [status, setStatus] = createSignal<"loading" | "ready" | "empty" | "error">("loading");

async function load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    setStatus(list.length ? "ready" : "empty");
  } catch (e) {
    setStatus("error");
  }
}
// <Show when={status() === "ready"} fallback={<p>Loading…</p>}>…</Show>
```

## 5. Two states: local and Zig's

This is the **most important boundary** in all three tutorials. The value on screen and the value
Zig owns are different state.

| Where | Owned by | Updated by |
|---|---|---|
| Application data | Zig's `State` | commands such as `addTodo` / `toggleTodo` / `removeTodo` |
| The list / number on screen | Solid state built from `createSignal(0)` | **wholesale replacement from the `invoke` result** |
| The `.zigbar` counter | Zig's `zig_count` | `zig_inc` / `zig_dec` mutate it directly |

The nine examples deliberately run the counter body on **local state only**, so the 3-OS
screenshots match pixel for pixel. The `.zigbar` panel underneath is the opposite: it can never
be filled without Zig.

`zig_probe` / `zig_inc` / `zig_dec` are answered by Zig over `ipc://localhost/<command>` and
return `{ ok, count, seal }`. The gallery injects the same `window.__TAURI_INTERNALS__.invoke`
that the unmodified `@tauri-apps/api` v2 uses, at `DOCUMENT_START`, and puts `mount()` on
`window.__ZTS_ZIG__`. The `seal` is the first eight bytes of a SHA-256 over a **secret only the
Zig binary holds** plus the counter; the static HTML carries neither the secret nor the formula.
JavaScript cannot forge it, so `ZIG ONLINE` plus the 16-character seal is proof that Zig is alive.
A static build or the `zts dev` browser has no `window.__ZTS_ZIG__` and correctly stays at
`ZIG OFFLINE`.

The real wiring is in
[`examples/gallery/src/web/zig-bridge.js`](../../../../examples/gallery/src/web/zig-bridge.js)
and [`examples/gallery/src/main.zig`](../../../../examples/gallery/src/main.zig). To light it up in
your own app, add those three commands to `rpc.Schema` and inject the same bridge.

`onMount` is client-only, so call `window.__ZTS_ZIG__.mount()` from there; a static export simply leaves the panel at `ZIG OFFLINE`.

Call `setCount(r.count)` exactly once, after Zig replies. Fine-grained updates hide a run-ahead UI, so keep two signals (local counter and Zig counter) to make the source of truth obvious.

To receive the Zig-owned counter in Solid, write this (`invoke` only reaches a backend from the
`zts build` executable):

```jsx
import { invoke } from "@tauri-apps/api/core";

const [zigCount, setZigCount] = createSignal(0);
const [seal, setSeal] = createSignal("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  setZigCount(r.count);   // Zig の戻り値だけを正にする
  setSeal(r.seal);
}
```

> [!WARNING]
> Forgetting the `count()` call passes the function object to the DOM; assigning to a plain `let` outside a signal never repaints.

## 6. Run it

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # a window opens; adding a Todo reaches Zig
```

The `zts dev` browser alone cannot deliver `invoke`; always verify with the `zts build` executable.
`web/` is embedded with gzip twins and CSP hashes.

## Next

| Next question | Where |
|---|---|
| Counter in the same library | [Counter with Solid](counter-solid.md) |
| Screen states in the same library | [Screen with Solid](ui-solid.md) |
| Plain-JS original | [Build a Todo list](todo.md) |
| Pick another library | [Chooser hub](frameworks.md) |
| Real `Solid` source | [`examples/frameworks/solid/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/solid) |
| Command arguments, errors, TS generation | [Commands guide](../guides/rpc.md) |
| Why these three are shaped this way | [Patterns](../patterns/index.md) |
