# Learn ziggurats

> **Audience**: people building an app with ziggurats (Zig and web basics help).
> **Time**: 2 minutes for this page, about 95 minutes for the whole path (80 minutes of doing, 15 of concepts).

**Run it first.** Ten minutes of doing beats an hour of reading, and the first link below takes you
from a clone to a built binary on a single page.

[**→ Your first ten minutes with ziggurats**](start.md)

## The learning path

These five steps are the official order. **The same rail appears at the top of every page on the
path**, so you cannot lose your place. Skipping ahead is allowed; you will just be looking words up
later instead of now.

<!-- learn-path -->

| Step | State when you are done |
|---|---|
| 1. [Your first ten minutes](start.md) | your app runs in a browser and a single binary sits in `zig-out/bin/` |
| 2. [How it works](concepts/index.md) | you can say what happens between a button and a Zig function |
| 3. [Build an app](tutorials/index.md) | you have built the counter, the todo list and the screen |
| 4. [Patterns that hold up](patterns/index.md) | you can defend a command/state/error design, and you have done the exercises |
| 5. [Look things up](guides/index.md) | you reach the page you need from a job description in one hop |

> [!NOTE]
> **The concepts are not a prerequisite.** They are faster *after* you have run something: once
> you have seen `zts dev`, the six-layer diagram in step 2 costs one "ah, that is what that was".

## What ziggurats is (30 seconds)

**A Zig 0.17 reimplementation of Tauri v2's protocol and plugins.** One app source produces three
artefacts.

| Artefact | Runs on | What is special |
|---|---|---|
| Desktop app | the OS WebView (GTK / WKWebView / WebView2) | single binary, `web/` embedded inside it |
| Browser live preview | a browser during development | keeps serving the last good build when yours breaks |
| Static site | any static host | no server; state lives in `app.wasm` |

The frontend is **unmodified `@tauri-apps/api` v2**. `invoke` and `listen` behave exactly as they
do in Tauri — same names, same shapes.

```bash
zts init my-app      # six files
cd my-app && zts dev # http://127.0.0.1:5173 — reloads on save
zts build            # zig-out/bin/my_app — one binary with web/ inside
```

The backend is "write a function, put it in a struct, hand the struct to `Schema`".

```zig
const Commands = struct {
    pub fn increment(state: *State) !i32 {
        state.count += 1;
        return state.count;
    }
};

pub const Schema = rpc.Schema(.{ .app = Commands });
```

JavaScript can now call `invoke("increment")`. No routing table, no hand-written JSON, no
hand-written TypeScript declarations (`zig build` generates them).

## What you are expected to know

ziggurats is not a first-contact programming course, but **step 1 needs no prior knowledge at all**.
When one of these turns out to be missing, that is the moment to learn it.

| Prerequisite | Needed for | If you are missing it |
|---|---|---|
| Zig basics (`comptime`, error sets, `defer`) | writing commands, targeting WASM | [Zig Language Reference](https://ziglang.org/documentation/master/) |
| Web basics (HTML, CSS, `fetch`, events) | all of the frontend | [MDN: Learn Web Development](https://developer.mozilla.org/en-US/docs/Learn) |
| A terminal | everything | — |

Tauri v2 experience is **not** required. Only migrating? Read
[Migrating from Tauri](guides/migrate-from-tauri.md).

> [!NOTE]
> The learning path is translated in full. The two **lookup** trees — the generated API reference
> and `docs/reference/` (CLI flags, configuration) — are language-neutral by design: their subject
> is declaration names and flag spellings, which are identical in every language.

## Look things up by job

Once you have finished the path, most reading is one page at a time.

| I want to | Start at |
|---|---|
| implement a specific feature | [All guides](guides/index.md) — RPC, plugins, static sites, packaging, migration, problems |
| search by declaration name | [API reference](../../api/index.html) (generated from `///`) |
| understand an error | [Error index](../../reference/errors.html) / [Glossary](../../glossary.md) |
| see every CLI flag | [`zts` command reference](../../reference/cli.md) |
| look at a working example | [Examples](../../../examples/frameworks/README.md) |

## Where to go next

- Have not run it yet → [**Your first ten minutes**](start.md)
- Design first → [Concepts](concepts/index.md)
- Hands on → [Tutorials](tutorials/index.md) (counter, todo list, screen)
- Stuck on a design choice → [Patterns](patterns/index.md)
- Lost in terminology → [Glossary](../../glossary.md)
- Every page in one place → [Documentation index](../../INDEX.md)
