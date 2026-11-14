# Tutorial: build a screen with Next.js

> **Audience**: you can assemble a UI in `Next.js`; ziggurats `invoke` may be new.
> **Time**: 20 minutes (type it in and it runs).
> **Prerequisites**: [Build a Todo list](todo.md).

This is the **`Next.js 16.4` version of [Build a screen](ui.md)**. The state boundary, CSP
and the `zts dev` swap are **identical in every library**. What changes is only how
"loading / empty / error" is expressed in `Next.js` syntax.
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

A stateful App Router page needs `'use client'`. `useState(0)` exists only in client components; putting it in a server component fails the build.

Start from `useState<"loading" | "ready" | "empty" | "error">("loading")` and render `ZIG OFFLINE` during prerender so hydration does not mismatch.

The plain-JS `ui.md` used `let status = "loading"` with `if / else`;
only that part is translated into `Next.js`'s idiom. **Zig's `State` and the `error{}` set are
shared.**

## 2. The skeleton and CSS are shared

Copy `web/index.html` and `web/style.css` from [Build a screen](ui.md#2-the-html-skeleton)
unchanged. Even with `Next.js`, **keep the `data-zts` attribute names**: the 3-OS screenshot
comparison and the `.zigbar` panel both read them.

```bash
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/next/. ./fw-next/
# rebuild with next build if needed; output goes to out/
```

## 3. Branch in the template

```tsx
const [status, setStatus] = useState<"loading" | "ready" | "empty" | "error">("loading");

useEffect(() => {
  invoke<Todo[]>("listTodos")
    .then((list) => setStatus(list.length ? "ready" : "empty"))
    .catch(() => setStatus("error"));
}, []);
```

Start at `loading` and move to `ready` / `empty` only on success. Prerendered and statically
exported HTML bakes in the initial value, which is why Reference `window.__ZTS_ZIG__` only inside `useEffect`. Even with `'use client'`, module scope is evaluated during prerendering, so a top-level `window` is unsafe. asks you to keep `ZIG OFFLINE`
visible until Zig's answer arrives.

## 4. Turn `invoke` failures into `error`

As in [Build a screen](ui.md#4-draw-only-from-what-came-back): on rejection, do not change the data
state — switch to the error view. With `output: 'export'` there is no Zig host, so `invoke` only reaches a backend from the `zts build` binary. Call `setCount` once after `await`, and never on rejection.

Re-reading the list is the same as in the Todo version:

```tsx
const [todos, setTodos] = useState<Todo[]>([]);

useEffect(() => { refresh(); }, []);
async function refresh() {
  setTodos(await invoke<Todo[]>("listTodos"));
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();
}
// {todos.map((t) => <li key={t.id}>{t.title}</li>)}
```

## 5. Two states: local and Zig's

This is the **most important boundary** in all three tutorials. The value on screen and the value
Zig owns are different state.

| Where | Owned by | Updated by |
|---|---|---|
| Application data | Zig's `State` | commands such as `addTodo` / `toggleTodo` / `removeTodo` |
| The list / number on screen | Next.js state built from `useState(0)` (with `'use client'`) | **wholesale replacement from the `invoke` result** |
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

Reference `window.__ZTS_ZIG__` only inside `useEffect`. Even with `'use client'`, module scope is evaluated during prerendering, so a top-level `window` is unsafe.

With `output: 'export'` there is no Zig host, so `invoke` only reaches a backend from the `zts build` binary. Call `setCount` once after `await`, and never on rejection.

To receive the Zig-owned counter in Next.js, write this (`invoke` only reaches a backend from the
`zts build` executable):

```tsx
"use client";
import { invoke } from "@tauri-apps/api/core";

const [zigCount, setZigCount] = useState(0);
const [seal, setSeal] = useState("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  setZigCount(r.count);
  setSeal(r.seal);
}
```

> [!WARNING]
> Never try to bake `invoke` results into the static export — no Zig exists at build time. The initial state must always be "loading".

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
| Counter in the same library | [Counter with Next.js](counter-next.md) |
| Todo in the same library | [Todo with Next.js](todo-next.md) |
| Plain-JS original | [Build a screen](ui.md) |
| Pick another library | [Chooser hub](frameworks.md) |
| Live `Next.js` demo | [Open in a browser](https://umiturtle.github.io/ZigguraTs/examples/frameworks/next/index.html) |
| CSP and shipping | [Static sites guide](../guides/static-site.md) |
| Command and error design | [Patterns](../patterns/index.md) |

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
