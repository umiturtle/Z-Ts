# Tutorial: build a Todo list with Astro

> **Audience**: you know `Astro` but are new to ziggurats commands.
> **Time**: 20 minutes (type it in and it runs).
> **Prerequisites**: [Build a counter](counter.md) (10 minutes).

This is the **`Astro 6.4` version of [Build a Todo list](todo.md)**. The Zig side
(`State`, `addTodo` / `toggleTodo` / `removeTodo`, the `error{}` set and the tests) does not change
**by a single character**. Only `web/` changes: how the list state is held and rendered.
[Pick another library](frameworks.md) at any time.

<!-- framework-picker -->

| Chapter | What you do | When you are done |
|---|---|---|
| [0](#0-prerequisites) | check prerequisites | `zts doctor` is green |
| [1](#1-translate-the-state) | learn the state primitive | Direct DOM updates (`data-zts`) holds a list |
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
| Node.js | only if you rebuild `Astro` yourself |
| Project | the `my-app` you made in [Build a counter](counter.md) |

```bash
cd my-app
zts doctor       # all checks passed
```

## 1. Translate the state

There is no island: static HTML plus a tiny `<script>`. State lives in the DOM's `data-zts` attributes rather than a variable, and `textContent` is the only update mechanism.

Build the list into `<ul data-zts="todo-list">` with `createElement` / `textContent`, not `innerHTML` — this satisfies both CSP and XSS hygiene.

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

```astro
const list = document.querySelector('[data-zts="todo-list"]');

async function refresh() {
  if (!list) return;
  const todos = await invoke<Todo[]>("listTodos");
  list.replaceChildren(...todos.map((t) => {
    const li = document.createElement("li");
    li.textContent = t.title;   // innerHTML ではなく textContent
    return li;
  }));
}
```

`refresh()` re-reads `listTodos` and is called after **every** add / toggle / remove. Pushing into a
local array makes the UI drift away from Zig's `State`.

## 4. No optimistic updates

Same rule as [Build a screen](ui.md#4-draw-only-from-what-came-back): when `invoke` rejects, **do not
change state**, switch to the error view instead. Set `value.textContent = String(r.count)` once after `await`. With no re-render, write order is exactly what the user sees. In a static build with no Zig host, do not call `invoke` and keep `ZIG OFFLINE`.

```astro
const status = document.querySelector('[data-zts="status"]');

async function load() {
  if (!status) return;
  try {
    const list = await invoke<Todo[]>("listTodos");
    status.textContent = list.length ? "ready" : "empty";
  } catch (e) {
    status.textContent = "error";
  }
}
```

## 5. Two states: local and Zig's

This is the **most important boundary** in all three tutorials. The value on screen and the value
Zig owns are different state.

| Where | Owned by | Updated by |
|---|---|---|
| Application data | Zig's `State` | commands such as `addTodo` / `toggleTodo` / `removeTodo` |
| The list / number on screen | Astro state built from Direct DOM updates (`data-zts`) | **wholesale replacement from the `invoke` result** |
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

Astro ships no framework JS by default. `<script>` is bundled at build time, and `window.__ZTS_ZIG__` exists only when the native host injects it at `DOCUMENT_START`.

Set `value.textContent = String(r.count)` once after `await`. With no re-render, write order is exactly what the user sees. In a static build with no Zig host, do not call `invoke` and keep `ZIG OFFLINE`.

To receive the Zig-owned counter in Astro, write this (`invoke` only reaches a backend from the
`zts build` executable):

```astro
import { invoke } from "@tauri-apps/api/core";

const value = document.querySelector('[data-zts="count"]');
const seal = document.querySelector('[data-zts="zig-seal"]');
const inc = document.querySelector('[data-zts="zig-inc"]');
if (!value || !seal || !inc) throw new Error("counter markup missing");

inc.addEventListener("click", async () => {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  value.textContent = String(r.count);   // Zig の戻り値だけを正にする
  seal.textContent = r.seal;
});
```

> [!WARNING]
> Without a null guard, `querySelector` throws a `TypeError` the moment the static HTML is opened alone. Always start with `if (!value) return;`.

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
| Counter in the same library | [Counter with Astro](counter-astro.md) |
| Screen states in the same library | [Screen with Astro](ui-astro.md) |
| Plain-JS original | [Build a Todo list](todo.md) |
| Pick another library | [Chooser hub](frameworks.md) |
| Real `Astro` source | [`examples/frameworks/astro/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/astro) |
| Command arguments, errors, TS generation | [Commands guide](../guides/rpc.md) |
| Why these three are shaped this way | [Patterns](../patterns/index.md) |

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
