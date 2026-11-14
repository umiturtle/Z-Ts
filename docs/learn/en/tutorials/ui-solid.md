# Tutorial: build a screen with Solid

> **Audience**: you can assemble a UI in `Solid`; ziggurats `invoke` may be new.
> **Time**: 20 minutes (type it in and it runs).
> **Prerequisites**: [Build a Todo list](todo.md).

This is the **`Solid 1.9` version of [Build a screen](ui.md)**. The state boundary, CSP
and the `zts dev` swap are **identical in every library**. What changes is only how
"loading / empty / error" is expressed in `Solid` syntax.
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

`createSignal(0)` returns a `[getter, setter]` pair. **Only the DOM nodes that read it** update, and the component function runs exactly once. `count` is a function, so JSX calls `count()`.

Branch with `<Show when={status() === "ready"} fallback={...}>`. `status` is a signal too, so the condition calls it.

The plain-JS `ui.md` used `let status = "loading"` with `if / else`;
only that part is translated into `Solid`'s idiom. **Zig's `State` and the `error{}` set are
shared.**

## 2. The skeleton and CSS are shared

Copy `web/index.html` and `web/style.css` from [Build a screen](ui.md#2-the-html-skeleton)
unchanged. Even with `Solid`, **keep the `data-zts` attribute names**: the 3-OS screenshot
comparison and the `.zigbar` panel both read them.

```bash
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/solid/. ./fw-solid/
# rebuild with vite build if needed; output goes to dist/
```

## 3. Branch in the template

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

Start at `loading` and move to `ready` / `empty` only on success. Prerendered and statically
exported HTML bakes in the initial value, which is why `onMount` is client-only, so call `window.__ZTS_ZIG__.mount()` from there; a static export simply leaves the panel at `ZIG OFFLINE`. asks you to keep `ZIG OFFLINE`
visible until Zig's answer arrives.

## 4. Turn `invoke` failures into `error`

As in [Build a screen](ui.md#4-draw-only-from-what-came-back): on rejection, do not change the data
state — switch to the error view. Call `setCount(r.count)` exactly once, after Zig replies. Fine-grained updates hide a run-ahead UI, so keep two signals (local counter and Zig counter) to make the source of truth obvious.

Re-reading the list is the same as in the Todo version:

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
zig-out/bin/my_app        # a window opens; the three states switch
```

Inline scripts in `web/index.html` get a CSP hash at build time. `unsafe-inline` is unnecessary,
and a framework-generated `<script type="module">` is handled the same way.

## Next

| Next question | Where |
|---|---|
| Counter in the same library | [Counter with Solid](counter-solid.md) |
| Todo in the same library | [Todo with Solid](todo-solid.md) |
| Plain-JS original | [Build a screen](ui.md) |
| Pick another library | [Chooser hub](frameworks.md) |
| Live `Solid` demo | [Open in a browser](https://umiturtle.github.io/ZigguraTs/examples/frameworks/solid/index.html) |
| CSP and shipping | [Static sites guide](../guides/static-site.md) |
| Command and error design | [Patterns](../patterns/index.md) |

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
