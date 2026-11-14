# Tutorial: build a screen with Svelte

> **Audience**: you can assemble a UI in `Svelte`; ziggurats `invoke` may be new.
> **Time**: 20 minutes (type it in and it runs).
> **Prerequisites**: [Build a Todo list](todo.md).

This is the **`Svelte 5.57` version of [Build a screen](ui.md)**. The state boundary, CSP
and the `zts dev` swap are **identical in every library**. What changes is only how
"loading / empty / error" is expressed in `Svelte` syntax.
[Pick another library](frameworks.md) at any time.

<!-- framework-picker -->

| Chapter | What you do | When you are done |
|---|---|---|
| [0](#0-prerequisites) | check prerequisites | `zts doctor` is green |
| [1](#1-hold-the-three-states-in-one-value) | learn the state primitive | four states in one value |
| [2](#2-the-skeleton-and-css-are-shared) | place HTML / CSS | the skeleton renders in `zts dev` |
| [3](#3-branch-in-the-template) | write conditionals | three screens switch |
| [4](#4-turn-invoke-failures-into-error) | draw only from results | UI and Zig agree |
| [5](#5-two-states-local-and-zigs) | signals vs Zig | you can explain the seal |
| [6](#6-run-it) | `zts build` | a single binary |

---

## 0. Prerequisites

Reuse the `my-app` from [Build a counter](counter.md) → [Build a Todo list](todo.md).

```bash
cd my-app
zts doctor       # all checks passed
```

## 1. Hold the three states in one value

The Svelte 5 example uses `let count = 0`, where assignment is reactive (`$state(0)` is the explicit form). The compiler turns each assignment into a direct DOM update — no virtual DOM, no re-render.

Express the three states in the template with `{#if status === "loading"}…{:else if status === "error"}…{:else}…{/if}`, backed by `let status = $state("loading")`.

The plain-JS `ui.md` used `let status = "loading"` with `if / else`;
only that part is translated into `Svelte`'s idiom. **Zig's `State` and the `error{}` set are
shared.**

## 2. The skeleton and CSS are shared

Copy `web/index.html` and `web/style.css` from [Build a screen](ui.md#2-the-html-skeleton)
unchanged. Even with `Svelte`, **keep the `data-zts` attribute names**: the 3-OS screenshot
comparison and the `.zigbar` panel both read them.

```bash
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/svelte/. ./fw-svelte/
# rebuild with vite build if needed; output goes to dist/
```

## 3. Branch in the template

```svelte
let status: "loading" | "ready" | "empty" | "error" = $state("loading");

async function load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    status = list.length ? "ready" : "empty";
  } catch (e) {
    status = "error";
  }
}
// {#if status === "error"}<p class="error">…</p>{/if}
```

Start at `loading` and move to `ready` / `empty` only on success. Prerendered and statically
exported HTML bakes in the initial value, which is why Touch `window` only inside `onMount`. The top-level `<script>` can be evaluated at build time, so never reference the bridge there. asks you to keep `ZIG OFFLINE`
visible until Zig's answer arrives.

## 4. Turn `invoke` failures into `error`

As in [Build a screen](ui.md#4-draw-only-from-what-came-back): on rejection, do not change the data
state — switch to the error view. Assign `count = r.count` exactly once after `await`. Because assignment repaints instantly, a `count += 1` before `invoke` shows a value that disagrees with Zig for one frame.

Re-reading the list is the same as in the Todo version:

```svelte
let todos: Todo[] = $state([]);

async function refresh() {
  todos = await invoke<Todo[]>("listTodos");
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // 代入で丸ごと差し替える
}
// {#each todos as t (t.id)}<li>{t.title}</li>{/each}
```

## 5. Two states: local and Zig's

This is the **most important boundary** in all three tutorials. The value on screen and the value
Zig owns are different state.

| Where | Owned by | Updated by |
|---|---|---|
| Application data | Zig's `State` | commands such as `addTodo` / `toggleTodo` / `removeTodo` |
| The list / number on screen | Svelte state built from `let count = 0` | **wholesale replacement from the `invoke` result** |
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

Touch `window` only inside `onMount`. The top-level `<script>` can be evaluated at build time, so never reference the bridge there.

Assign `count = r.count` exactly once after `await`. Because assignment repaints instantly, a `count += 1` before `invoke` shows a value that disagrees with Zig for one frame.

To receive the Zig-owned counter in Svelte, write this (`invoke` only reaches a backend from the
`zts build` executable):

```svelte
import { invoke } from "@tauri-apps/api/core";

let zigCount = $state(0);
let seal = $state("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  zigCount = r.count;     // await の後に 1 回だけ代入
  seal = r.seal;
}
```

> [!WARNING]
> A bare `todos.push(x)` may not be tracked even by `$state`. Replace the array (`todos = [...todos, x]`) or re-read it from Zig.

## 6. Run it

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # a window opens; the three states switch
```

Inline scripts in `web/index.html` get a CSP hash at build time. `unsafe-inline` is unnecessary,
and a framework-generated `<script type="module">` is handled the same way.

## Next

| Next question | Where |
|---|---|
| Counter in the same library | [Counter with Svelte](counter-svelte.md) |
| Todo in the same library | [Todo with Svelte](todo-svelte.md) |
| Plain-JS original | [Build a screen](ui.md) |
| Pick another library | [Chooser hub](frameworks.md) |
| Live `Svelte` demo | [Open in a browser](https://umiturtle.github.io/ZigguraTs/examples/frameworks/svelte/index.html) |
| CSP and shipping | [Static sites guide](../guides/static-site.md) |
| Command and error design | [Patterns](../patterns/index.md) |
