# The page/logic boundary

> **Audience**: readers whose screens multiplied and whose `invoke` calls are now scattered.
> **Time**: 4 minutes (+12 for the two exercises).
> **Before this**: [Designing commands](commands.md) and [Designing errors](errors.md).

The previous three pages were about Zig. This one is about **crossing the boundary**: the same
command can feel very different depending on how it is called.

## A working example: one action, one call

```ts
// web/app.ts — uses `bindings.gen.ts`, the output of `zts_rpc.tsgen`
import { createRpcClient } from "./bindings.gen.ts";

const rpc = createRpcClient();

async function toggle(id: number): Promise<void> {
  // Move the UI forward first (optimistic update), roll back if it fails.
  render(id, "pending");
  const res = await rpc.$try.toggleTodo({ id }); // the non-throwing shape
  if (res.ok) {
    render(res.data.id, res.data.done ? "done" : "open");
    return;
  }
  render(id, "open"); // roll back
  showError(res.error.code); // translate "NotFound" and friends once
}
```

`zts_rpc.tsgen` generates two calling styles.

| Shape | How failure arrives | Use it for |
|---|---|---|
| `rpc.$try.toggleTodo(args)` | `{ ok: false, error: { code } }` | treating failure as a **branch** (default) |
| `rpc.toggleTodo(args)` | throws `ZtsRpcError` | when `try/catch` around several calls is simpler |

Three principles:

1. **One call per action.** Two `invoke`s in a row ("update, then re-fetch") is a return-value bug
   ([Designing commands](commands.md))
2. **The page may move first** (optimistic update) and **roll back** on failure. Waiting for a
   round trip feels slower than being corrected
3. **Translate error codes in one place.** One `showError(code)` function, not wording per screen

## The shape that grows / the shape that breaks

| Decision | Grows | Breaks | Why |
|---|---|---|---|
| call unit | one per action | one per screen (`loadEverything`) | one change refetches every screen |
| double submit | `disabled` + an in-flight promise | nothing | two clicks, two orders |
| loading | the row that was clicked | a full-screen spinner | the user loses context, and it feels slower |
| failure display | next to the action (row, form) | `alert()` | context disappears and the app is blocked until dismissed |
| retry | the one action that failed | reload the page | the form is gone |
| typing | debounce (e.g. 200 ms) | an `invoke` per keystroke | the pipe fills and responses arrive out of order |

### before → after: double submits and races

```ts
// before: two clicks, two orders. A slow response lands later and rewinds the UI.
button.onclick = () => rpc.order({ item: "pen", quantity: 1 });

// after: refuse while in flight, re-enable when done
let inFlight = false;
button.onclick = async () => {
  if (inFlight) return;
  inFlight = true;
  button.disabled = true;
  try {
    const res = await rpc.$try.order({ item: "pen", quantity: 1 });
    if (res.ok) showOrder(res.data);
    else showError(res.error.code);
  } finally {
    inFlight = false;
    button.disabled = false;
  }
};
```

Zig helps too (check stock before decrementing, detect conflicts with `revision`). **Do both**: the
page reduces accidents, Zig prevents them.

### before → after: stop re-fetching everything

```ts
// before: update then fetch all — two round trips, and the screen is briefly stale
await rpc.$try.toggleTodo({ id });
const list = await rpc.$try.listTodos();
renderList(list.data);

// after: swap the one item that came back
const res = await rpc.$try.toggleTodo({ id });
if (res.ok) renderItem(res.data);
```

## Why

A round trip is **asynchronous and unordered**. Fire the same command twice and the slower response
may land last, rewinding the screen. Two ways to stop it:

- **do not send** (disable while in flight)
- **drop stale responses** (number the requests, ignore everything but the latest)

A full-screen spinner hides the same problem rather than solving it. The user wants to know
**what is happening**; mark only the row they touched as `pending`.

## Exercises

### 1. Stop the double write

The "save" button in a settings screen was clicked twice and the file was written twice. Where do
you stop it?

<details>
<summary>Answer</summary>

**All three places.**

1. **UI**: `disabled` while in flight (+ `aria-busy="true"`). One line
2. **call site**: keep the promise for the same action and return it instead of starting a second
   (coalescing duplicates)
3. **Zig**: write a temp file and rename (a second identical write cannot corrupt anything)

UI alone breaks with a second tab or an autosave. Zig alone still makes the user wait twice.

</details>

### 2. Which command?

To mark one row in a list as done, which do you call?

1. `toggleTodo` (returns `Todo`)
2. `markDone` (returns `Todo`)
3. call `listTodos` again

<details>
<summary>Answer</summary>

**1 or 2.** Both return the `Todo`, so swapping that one item is enough. 3 costs an extra round
trip, redraws the whole list, and loses the scroll position. Choosing between 1 and 2 is exercise 1
of [Designing commands](commands.md) — is the action "toggle" or "done"?

</details>

---

## The chapter in one table

| Question | Answer | Page |
|---|---|---|
| split or extend a command? | different verb, different command; arguments are one struct | [Commands](commands.md) |
| where does state go? | Zig if being wrong hurts; the page if it is appearance | [State](state.md) |
| how to report failure? | one `error{}` name per different UI response; wording in the page | [Errors](errors.md) |
| how to cross the boundary? | one call per action, optimistic update, roll back | this page |

Next: [Look things up](../guides/index.md) — read one guide for the thing you want to build.

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
