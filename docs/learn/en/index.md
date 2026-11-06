# Learn Z-Ts

> **Audience**: people building an app with Z-Ts (Zig and web basics help).
> **Time**: 3 minutes for this page, 10 minutes to an hour for the path you pick.

Z-Ts is **a Zig 0.17 reimplementation of Tauri v2's protocol and plugins**. One app source
produces three artefacts.

| Artefact | Runs on | What is special |
|---|---|---|
| Desktop app | the OS WebView (GTK / WKWebView / WebView2) | single binary, `web/` embedded inside it |
| Browser live preview | a browser during development | keeps serving the last good build when yours breaks |
| Static site | any static host | no server; state lives in `app.wasm` |

The frontend is **unmodified `@tauri-apps/api` v2**. `invoke` and `listen` behave exactly as they
do in Tauri — same names, same shapes.

---

## Four ways in

Read in any order, but **concepts → tutorial → guides** is the shortest path. In a hurry? The
tutorial alone leaves you with a working app.

| Entry | For people who | Contains |
|---|---|---|
| [Concepts](concepts/index.md) | want the design first | the six packages, how a command travels, how permissions work |
| [Tutorial](tutorials/counter.md) | want to run something now | a working counter in 15 minutes (backend → UI → build) |
| [Guides](guides/index.md) | have one specific job | commands, plugins, static sites, packaging, migration, problems |
| [API reference](../../api/index.html) | search by name | every public declaration (generated from `///`) |

## What you are expected to know

Z-Ts is not a first-contact programming course. If one of these is missing, fixing that first is
faster than pushing through.

| Prerequisite | Needed for | If you are missing it |
|---|---|---|
| Zig basics (`comptime`, error sets, `defer`) | writing commands, targeting WASM | [Zig Language Reference](https://ziglang.org/documentation/master/) |
| Web basics (HTML, CSS, `fetch`, events) | all of the frontend | [MDN: Learn Web Development](https://developer.mozilla.org/en-US/docs/Learn) |
| A terminal | everything | — |

Tauri v2 experience is **not** required. Only migrating? Read
[Migrating from Tauri](guides/migrate-from-tauri.md).

## The whole thing in 30 seconds

```bash
zts init my-app      # six files: build.zig, src/main.zig, web/index.html, …
cd my-app
zts dev              # http://127.0.0.1:5173 — reloads on save
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

## The learning path

```text
  Concepts (15 min)
     six packages → command flow → plugins → permissions
        │
        ├──► Tutorial (15 min)   build a working counter
        │
        └──► Guides (when you need one)
               install / rpc / plugins / static-site / package / troubleshooting / migrate
                        │
                        └──► API reference (look things up by name)
```

## Where to go next

- Design first → [Concepts](concepts/index.md)
- Hands on → [Tutorial: the counter](tutorials/counter.md)
- Lost in terminology → [Glossary](../../glossary.md)
- Something broke → [Error index](../../reference/errors.html) or
  [Troubleshooting](guides/troubleshooting.md)
