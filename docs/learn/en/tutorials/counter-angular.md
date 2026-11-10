# Tutorial: build a counter with Angular

> **Audience**: you know Angular but have never used ziggurats; basic Zig syntax is assumed.
> **Time**: 15 minutes to a running app.
> **Before you start**: finish [Your first ten minutes](../start.md).

This is the **Angular 22.2** branch of [Build a counter](counter.md). The Zig side is
**identical, character for character**; only `web/` changes, and it uses the real example from
[`examples/frameworks/angular/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/angular). [Pick another library](frameworks.md) at any time.

<!-- framework-picker -->

| Chapter | You do | You end up with |
|---|---|---|
| [0](#0-prerequisites) | check the toolchain | `zts doctor` is green |
| [1](#1-get-the-example) | fetch the finished example | a static build on disk |
| [2](#2-drop-it-into-a-ziggurats-project) | `zts init` → `web/` | the page under `zts dev` |
| [3](#3-read-the-real-component) | read the example source | you know where state and buttons live |
| [4](#4-add-the-zig-command) | write `increment` | `invoke("increment")` works |
| [5](#5-wire-the-button-to-ipc) | call `invoke` the Angular way | button → Zig → screen |
| [6](#6-run-and-ship) | `zts build` | one self-contained binary |

---

## 0. Prerequisites

| Item | Requirement |
|---|---|
| `zts` | one binary from Releases on `PATH` ([Install](../guides/install.md)) |
| Zig | 0.17 on `PATH` or in `ZTS_ZIG` |
| Node.js | only if you rebuild the framework yourself; not needed for the committed output |
| OS | Linux (GTK3 + WebKit2GTK 4.1) / macOS / Windows |

```bash
zts doctor       # "all checks passed" means you are ready
```

## 1. Get the example

The **built static output is committed**, so you can start with no network at all.

```text
examples/frameworks/angular/                 Angular source
examples/gallery/src/web/fw/angular/         finished static output (use this one)
```

```bash
# when the ziggurats checkout sits next to you
cp -R /path/to/Z-Ts/examples/gallery/src/web/fw/angular/. ./fw-angular/
ls fw-angular/index.html
```

Only rebuild from source if you want to. The output directory is `dist/browser/`.

```bash
cd /path/to/Z-Ts/examples/frameworks/angular
npm install
npm run build        # ng build
ls dist/browser/index.html
```

> [!NOTE]
> All nine examples render the **same DOM, CSS and copy**; only the framework name and version
> differ. Compare the [live demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/angular/index.html) with another one to see that the app is the same. See
> [`examples/frameworks/README.md`](../../../../examples/frameworks/README.en.md) for the 3-OS
> screenshot comparison.

## 2. Drop it into a ziggurats project

```bash
zts init my-app
cd my-app
rm -rf web
cp -R ../fw-angular web
zts dev                 # http://127.0.0.1:5173
```

`web/` is served as-is and embedded into the binary by `zts build`. Nothing on the Zig side has to
change — even multiple chunks and subdirectories such as `_next/` are followed verbatim.

`zts dev` reloads `web/` in about 0.2 s. **The Zig app is not running yet**, so once you add
`invoke` in the next chapters, verify with `zts build` as well.

## 3. Read the real component

This is an excerpt of `examples/frameworks/angular/src/main.ts` (the snippet is mechanically checked against the committed
example). `signal()` with an inline template; the builder injects `<script>` into `index.html`

<!-- source: examples/frameworks/angular/src/main.ts -->
```ts
      <section class="card">
        <div class="counter">
          <div class="value" data-zts="count">{{ count() }}</div>
          <button (click)="dec()" data-zts="dec">−</button>
          <button class="primary" (click)="inc()" data-zts="inc">＋</button>
        </div>
        <ul class="features">
```

State lives in `signal(0)`. The example deliberately uses **local state only** so the pixel
comparison across three OSes has no backend dependency. The next chapter connects ziggurats.

## 4. Add the Zig command

**This part is shared by every library.** Copy the `zig check` block from
[Build a counter](counter.md#3-write-the-counting-command) into `src/main.zig` verbatim. That block is
compiled by CI, so it — not this page — is the single source of truth.

```zig
const State = struct { count: i32 = 0 };
const Commands = struct {
    pub fn increment(state: *State) !i32 {
        state.count += 1;
        return state.count;
    }
};
pub const Schema = rpc.Schema(.{ .app = Commands });
```

The app only has to create the state and `bind` it.

```zig
var state = State{};
var router = Schema.bind(.{ .app = &state });
const handler = router.handler();
```

## 5. Wire the button to IPC

In Angular you write it like this. `@tauri-apps/api` is used **unmodified**.

```ts
import { invoke } from "@tauri-apps/api/core";

async inc() { this.count.set(await invoke<number>("increment")); }
```

That closes the loop: button → `invoke("increment")` → Zig function → return value → screen.
`invoke` does not reach anything in the browser served by `zts dev`, so always confirm with the
executable produced by `zts build`.

> [!NOTE]
> Inline scripts in `web/index.html` get a CSP hash at build time; `unsafe-inline` is not needed.
> Framework-generated `<script type="module">` tags are handled the same way.

## 6. Run and ship

```bash
zts build
# → zig-out/bin/my_app
zig-out/bin/my_app        # a window opens and +1 reaches Zig
```

`web/` is embedded with gzip twins and CSP hashes, so no asset directory sits next to the binary.

## Where next

| You want | Go to |
|---|---|
| the same tutorial in another library | [Choose a library](frameworks.md) |
| the plain-JS original | [Build a counter](counter.md) |
| more state, returning failures | [Build a todo list](todo.md) |
| loading / empty / error views | [Build the screen](ui.md) |
| the real Angular source | [`examples/frameworks/angular/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/angular) |
| the live Angular demo | [Open in a browser](https://umiturtle.github.io/Z-Ts/examples/frameworks/angular/index.html) |
| all nine examples compared | [`examples/frameworks/README.en.md`](../../../../examples/frameworks/README.en.md) |
| arguments, errors, generated types | [Guide: commands](../guides/rpc.md) |
