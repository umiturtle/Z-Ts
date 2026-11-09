# Tutorial: build the screen

> **Audience**: you have [the counter](counter.md) or [the todo list](todo.md) running.
> **Time**: 15 minutes. **Prerequisite**: a project where `zts dev` works.
> **After this page**: you can write a page that distinguishes loading, empty and error states.

Everything so far was Zig. This page is about `web/`. Z-Ts asks nothing of your frontend — plain
HTML, CSS and TypeScript are enough — but `zts dev` and `zts build` own **updating and shipping**
the page. Three things are worth knowing.

| What to know | Why it matters |
|---|---|
| decide "loading / empty / error" before you fetch | stops the page from briefly lying |
| keep CSS in `<link>` | `zts dev` swaps it **without a reload** (about 0.4 s) |
| inline `<script>` gets a CSP hash automatically | no `unsafe-inline`, ever |

---

## 1. Decide the three states first

A screen that fetches data moves between these four. Deciding them up front makes the code shorter.

| State | Screen | Common omission |
|---|---|---|
| loading | a skeleton, or "Loading…" | nothing at all, so the page looks blank |
| empty | "Nothing here yet" + the next action | a white void the reader reads as broken |
| error | what failed + **try again** | logged to the console, screen frozen |
| ready | the data | — |

```ts
type View<T> =
  | { kind: "loading" }
  | { kind: "empty" }
  | { kind: "error"; message: string }
  | { kind: "ready"; data: T };
```

Do not keep a separate `busy` flag: one value cannot represent "loading *and* error", so the
screen cannot contradict itself.

## 2. The HTML skeleton

```html
<main id="app">
  <h1>To do</h1>
  <form id="add">
    <label for="title">Title</label>
    <input id="title" autocomplete="off" />
    <button type="submit">Add</button>
  </form>
  <p id="status" role="status" aria-live="polite"></p>
  <ul id="todos"></ul>
</main>
```

`role="status"` with `aria-live="polite"` is the minimum that makes counts and errors audible to a
screen reader. It changes nothing visually; without it, "nothing happened" is what gets announced.

## 3. Keep CSS in its own file

```html
<link rel="stylesheet" href="./style.css" />
```

When a `web/**/*.css` file changes, `zts dev` replaces the `<link>` **in place** — input values,
scroll position and the open devtools survive. Tuning colours and spacing gets much faster
(measured: about 0.4 s).

> [!NOTE]
> CSS inside `<style>` is part of the HTML, so it goes through a full reload instead of a swap.
> Keep it in `style.css` while iterating; inlining before shipping saves one request and costs you
> the fast loop. Either way `zts build` embeds all of `web/`, so the artefact stays one file.

## 4. Draw only from what came back

```ts
import { invoke } from "@tauri-apps/api/core";

type Todo = { id: number; title: string; done: boolean };

const list = document.getElementById("todos")!;
const status = document.getElementById("status")!;

async function refresh() {
  try {
    const todos = await invoke<Todo[]>("listTodos");
    if (todos.length === 0) {
      status.textContent = "Nothing yet — add one above.";
    } else {
      status.textContent = `${todos.length} items`;
    }
    list.replaceChildren(...todos.map(renderOne));
  } catch (err) {
    status.textContent = "Could not load the list. Try again.";
    console.error(err);
  }
}

function renderOne(todo: Todo): HTMLLIElement {
  const li = document.createElement("li");
  const button = document.createElement("button");
  button.textContent = todo.title;
  button.setAttribute("aria-pressed", String(todo.done));
  button.addEventListener("click", () => invoke("toggleTodo", { id: todo.id }).then(refresh));
  li.append(button);
  return li;
}

refresh();
```

The important part: the page keeps **no copy** of the list. If it did, a divergence between JS and
Zig would leave you guessing which one is right. Draw the return value, then re-read after a
mutation.

## 5. CSP and shipping

`zts build` reads the HTML and **adds the hashes of inline `<script>` / `<style>` blocks to the
CSP**. You never write `unsafe-inline`, and you cannot: it is rejected.

| How you write it | CSP | Note |
|---|---|---|
| inline `<script>…</script>` | hash added automatically | no nonce plumbing |
| external `<script src="./app.js">` | allowed by `script-src 'self'` | what bundlers emit |
| `onclick="…"` attribute | **no hash** (blocked) | use `addEventListener` |

```bash
zts dev      # tune (CSS swaps without a reload)
zts build    # zig-out/bin/my_app — web/ embedded
```

## Exercises

<details>
<summary>1. How do you stop a double submit while the request is in flight?</summary>

Disable the button in `submit` and re-enable in `finally`. That is not enough on its own (keyboard,
a second tab, a slow link), so the Zig side must also ignore the second request — or make the
operation idempotent with an id the client chooses. The three-layer version is in
[the page/logic boundary](../patterns/boundaries.md).
</details>

<details>
<summary>2. The list reaches 1000 items. What do you suspect first?</summary>

`replaceChildren` rebuilding every row. Batch with a `DocumentFragment` or update only the changed
row. But check **the request** first: if `listTodos` ships all 1000 items on every call, that is the
bigger cost.
</details>

<details>
<summary>3. Why not build the error sentence in Zig?</summary>

Zig does not know the page's language. Return the **code** (`error.EmptyTitle`) and let the page
choose the sentence. For the same reason, `error{…}` is split by "what the page does differently",
not by "what went wrong in Zig" (see [Designing errors](../patterns/errors.md)).
</details>

---

## Where to go next

| Want to know | Go to |
|---|---|
| command and state design | [Patterns](../patterns/index.md) |
| `invoke` arguments, types, TypeScript | [Guide: commands](../guides/rpc.md) |
| windows, dialogs, files | [Guide: plugins](../guides/plugins.md) |
| installers (`.deb` / `.dmg` / `.exe`) | [Guide: packaging](../guides/package.md) |
