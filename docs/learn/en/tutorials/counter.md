# Tutorial: build a counter

> **Audience**: first contact with Z-Ts. You are expected to know basic Zig.
> **Time**: 15 minutes, typing included.
> **Never run Z-Ts?** [Your first ten minutes](../start.md) comes first; it makes chapter 0 shorter.

Create a project with `zts init`, **call a Zig function from a button**, grow it with reload on
save, and finish with a single binary. **Every command on this page is `zts`**. Repository work
(`./zigw`, CI) lives in [`docs/contributing/README.md`](../../../contributing/README.md).

| Step | You do | You end up with |
|---|---|---|
| [0](#0-prerequisites) | check the toolchain | `zts doctor` is green |
| [1](#1-create-a-project) | `zts init` | six files |
| [2](#2-run-while-you-edit-zts-dev) | `zts dev` | a page in your browser |
| [3](#3-write-the-counting-command) | write a Zig function | `invoke("increment")` works |
| [4](#4-build-a-single-binary) | `zts build` | one self-contained executable |
| [5](#5-when-it-breaks-run-zts-doctor) | `zts doctor` | you know where you got stuck |

## 0. Prerequisites

| Item | Requirement |
|---|---|
| `zts` | built from a checkout, see [Install](../guides/install.md) |
| Zig | 0.17 on `PATH` or in `ZTS_ZIG` (`zts` spawns it) |
| OS | Linux (GTK3 + WebKit2GTK 4.1), macOS, Windows |

```bash
zts version      # zts 0.1.0
zts doctor       # "all checks passed" means you are ready
```

## 1. Create a project

```bash
zts init my-app
cd my-app
```

You get six files.

```text
my-app/
├── build.zig          # uses the shared embedder to inline web/
├── build.zig.zon      # path dependency on Z-Ts
├── src/main.zig       # your app (a minimal asset listing)
├── web/index.html     # the frontend
├── .gitignore         # ignores zig-out/ and .zig-cache/
└── README.md
```

`zts init` builds once immediately and writes back the `.fingerprint` that Zig requires in
`build.zig.zon`. To write into an existing directory add `--force`; to rename the package add
`--name my_app`.

> **The template is a working minimum.** `zts build` prints something like
> `my_app: 1 embedded assets` and exits. To grow into a desktop app with a window, start from
> [`examples/counter/README.md`](../../../../examples/counter/README.md) — its `build.zig` and
> `src/main.zig` are the shortest complete example.

## 2. Run while you edit (`zts dev`)

```bash
zts dev               # http://127.0.0.1:5173
```

`web/` is served, and a fingerprint of `web/` and `src/` is polled every 400 ms; when it changes,
`zts dev` runs `zig build` and **reloads the browser**.

* `--browser` opens your default browser on start
* `--host 0.0.0.0` makes it reachable from a container or the LAN (Arena live preview)
* `--port 5199` changes the port
* while a build is failing it **keeps serving the last good output**, so you never stare at a
  broken page. The state is one request away:

```bash
curl http://127.0.0.1:5173/__zts_dev__/state
{"v":3,"ok":true}
```

`v` increments on every successful build; `ok` is the result of the last attempt. While `ok` is
`false`, fix the Zig error printed in the terminal.

## 3. Write the counting command

This is the heart of Z-Ts. **A Zig function becomes JavaScript's `invoke("…")`.** First add
`zts_rpc` to `build.zig`.

```zig
// one line next to the other modules
const zts_rpc = dep.module("zts_rpc");
// and in .imports of the app module:
//     .{ .name = "zts_rpc", .module = zts_rpc },
```

The command itself is three lines.

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const State = struct { count: i32 = 0 };

const Commands = struct {
    /// `invoke("increment")` → `state.count += 1`
    pub fn increment(state: *State) !i32 {
        state.count += 1;
        return state.count;
    }
};

pub const Schema = rpc.Schema(.{ .app = Commands });

test "increment adds one" {
    var state = State{};
    try std.testing.expectEqual(@as(i32, 1), try Commands.increment(&state));
    try std.testing.expectEqual(@as(i32, 2), try Commands.increment(&state));
}
```

CI compiles this block (`./zigw doctest`), so **writing a stale API turns CI red** — what you read
here builds today.

The frontend is plain Tauri. `@tauri-apps/api` works unchanged.

```html
<button id="inc">+1</button>
<span id="count">0</span>
<script type="module">
  import { invoke } from "@tauri-apps/api/core";
  document.getElementById("inc").addEventListener("click", async () => {
    document.getElementById("count").textContent = await invoke("increment");
  });
</script>
```

> [!NOTE]
> Inline scripts in `web/index.html` get a **CSP hash** at build time. You never write
> `unsafe-inline`. If the build refuses the page, check that `<script>` is closed properly — the
> hash is computed over the whole element.

On the app side, create the state and `bind` it.

```zig
var state = State{};
var router = Schema.bind(.{ .app = &state });
const handler = router.handler(); // hand this to the Host
```

"Button → `invoke` → Zig function → return value" now works. Time to ship it.

## 4. Build a single binary

```bash
zts build
# → zig-out/bin/my_app
```

The contents of `web/` are **embedded in the binary** (with gzip twins and CSP hashes). Nothing
has to sit next to the executable.

```bash
zts build --target aarch64-macos    # cross-compile
zts build --debug                  # Debug (ReleaseSmall by default)
zts build --frontend-only          # re-embed web/ only
```

`zts build` understands only `--target`, `--debug`, `--frontend-only` and `--dir`. For
`build.zig` options (`-Dgtk=false`, …) run `zig build` in the project directory directly.

## 5. When it breaks: run `zts doctor`

```text
$ zts doctor
zts 0.1.0
  checkout     /home/you/Z-Ts
  z_ts         present
  zig          /tmp/zts-toolchains/zig/zig
  package      my_app
  dependency   ../../home/you/Z-Ts
  web/         present

all checks passed
```

A `MISSING` line is the hint for what to fix (details in
[Troubleshooting](../guides/troubleshooting.md)).

---

## Where next

That is one full lap: create, run, ship.

| Next thing you want | Where |
|---|---|
| arguments, errors, generated TypeScript | [Guide: commands](../guides/rpc.md) |
| windows, files, menus | [Guide: plugins](../guides/plugins.md) |
| a static site with no server | [Guide: static sites](../guides/static-site.md) |
| `.deb` / `.dmg` / `.exe` | [Guide: packaging](../guides/package.md) |
| moving off Tauri v2 | [Guide: migration](../guides/migrate-from-tauri.md) |
| something is wrong | [Troubleshooting](../guides/troubleshooting.md) |
| every command and flag | [`docs/reference/cli.md`](../../../reference/cli.md) |
| a runnable sample (3 artefacts) | [`examples/counter/README.md`](../../../../examples/counter/README.md) |
| the design behind all this | [Concepts](../concepts/index.md) |
