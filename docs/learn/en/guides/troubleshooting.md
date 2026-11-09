# Troubleshooting (building an app)

> **Audience**: readers stuck while building an app with `zts`.
> **Time**: look up your symptom (one minute).

One page for "my app will not build". If you are stuck **building the ziggurats repository itself**,
go to [`docs/contributing/troubleshooting.md`](../../../contributing/troubleshooting.md) instead —
that page is about repository development and CI, which app authors never need.

---

## Run these first

```bash
zts doctor            # checks environment, dependencies and web/ ("all checks passed")
zts build             # does a plain build work (no dev server involved)?
```

If `doctor` prints no `MISSING` line, the failure is in your project's code.
`zts doctor --dir path/to/app` targets a project elsewhere.

---

## `zts init`

### `'…' already has files — pass --force to write into it anyway`

`zts init` only writes into an **empty directory**. Overwriting `src/main.zig` or
`web/index.html` in an existing project needs an explicit `--force`.

```bash
zts init my-app --force
```

A directory containing only `.git` or `node_modules` triggers the same message. Move an existing
`build.zig.zon` aside first if you want to keep it.

### `cannot derive a package name from '…' — pass --name <name>`

The directory name cannot be a Zig package name (hyphens, leading digits, capitals, non-ASCII).
Package names are `[a-z][a-z0-9_]*` and at most 31 characters.

```bash
zts init "my-app" --name my_app      # display name my-app, package name my_app
```

### `warning — could not read the fingerprint Zig suggested`

`zts init` builds once immediately and writes back the `build.zig.zon` fingerprint Zig asks for.
This warning is **not a failure**: the next `zts build` prints the same value and writes it back
automatically.

If `error: invalid fingerprint: 0x…` persists, replace `.fingerprint` with the value from the
error message (the upper 32 bits come from the package name; the lower 32 are a fork identifier
and may change freely).

### The generated `.z_ts.path` is `../../../…`

`zts` points at **the checkout it was built from**, as a relative path (for example
`../../../home/user/Z-Ts`), because Zig rejects absolute paths. Three ways out:

* leave it (fine as long as you stay on the same machine)
* regenerate with `zts init … --zts-path <checkout>`
* edit `.path` in `build.zig.zon` to a relative path that works for you

If `zts` moved, `zts doctor` says
`z_ts MISSING at … — rebuild zts or pass --zts-path`.

---

## `zts build`

### `cannot read <dir>/build.zig.zon — is this a ziggurats project?`

`--dir` does not point at a project. Run inside a directory made by `zts init`, or pass `--dir`.

### `could not run zig …` / `set ZTS_ZIG to the zig binary if it is not on PATH`

`zts build` spawns Zig as a child process. Put the same series `zts` was built with (0.17) on
`PATH`, or set `ZTS_ZIG`.

```bash
ZTS_ZIG=/tmp/zts-toolchains/zig/zig zts build
```

### `zig build failed`, then nothing

`zts` passes Zig's stderr through **unmodified** — you should see exactly what
`zig build 2>&1 | head -40` prints. Read the first `error:` line.

### I only want to rebuild the frontend

```bash
zts build --frontend-only      # only build.zig's "frontend" step (sub-100 ms)
```

Use it after editing `web/` when the native side does not need recompiling.

### I want to pass extra `zig build` options

`zts build` understands only `--target`, `--debug`, `--frontend-only` and `--dir`; anything else
stops with `unknown flag`. For `build.zig` options such as `-Dgtk=`, call Zig directly in the
project directory.

```bash
cd my-app && zig build -Dgtk=false
```

### `error: invalid fingerprint: 0x…`

See "could not read the fingerprint" above.

### GTK / WebKit2GTK headers are missing (Linux)

```bash
sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev
```

`zts build` does not forward Zig options, so use `zig build` directly for fine control (see above).

---

## `zts dev`

### `cannot listen on 127.0.0.1:5173` (`AddressInUse`)

A previous `zts dev` is still running, or something else owns the port. Change it.

```bash
zts dev --port 5199
```

`--host 0.0.0.0` exposes it to the LAN or outside a container (Arena live preview, for example).

### Blank page / "web/ is missing"

`zts dev` serves `web/` and injects a live-reload script before `</body>`. Without
`web/index.html` it stops at startup with
`web/ does not exist — zts init puts the front end there`.

### Edits do not trigger a reload

* The watcher covers `src/`, `web/`, `build.zig` and `build.zig.zon` (no inotify / FSEvents).
  Zig sources are compared by **mtime + size + a content hash**, so a same-content rewrite
  (`touch`, a formatter, re-saving) deliberately does **not** rebuild. If a real one-character
  edit is ignored, check that you are not editing a file that `src/main.zig` never imports (below).
* Poll state at `curl http://127.0.0.1:5173/__zts_dev__/state`. If `v` in
  `{"v":3,"ok":true,"hot":"full"}` rises, the change was seen.
* **Editing CSS does not reload the page** — the `<link>` is swapped in place. If nothing appears
  to change, check whether the rule is in an inline `<style>` block instead: embedded styles are
  part of the HTML, so they go through a normal reload.
* If `ok` stays `false`, **the type-check is failing**. `zts dev` keeps serving the last good
  output and does not bump `v` (so it never shows a broken app). Fix the Zig error in the terminal.

### A Zig edit does not rebuild / types pass but linking fails

`zts dev` keeps an **import graph** from `src/main.zig` (relative `@import` / `@embedFile`) and
skips both the build and the reload for files it cannot reach — scratch files, notes, test-only
sources. That is intentional: import the file from `main.zig`, or edit a reachable file instead.

Ordinary Zig edits use **`zig build check`**, a type-check that skips LLVM codegen and linking:
`zts dev` only serves `web/` and never starts the executable. To validate the real binary (link
errors, undefined `extern` symbols), run `zts build`, or start the dev loop with
`ZTS_DEV_BUILD=full zts dev`. Older templates without a `check` step, and `build.zig` files that
link native libraries, automatically fall back to full builds on every edit.

### Caching behaves oddly between reloads

`zts dev` sends `Cache-Control: no-store`. If a stale page persists after a build, check `v` in
the state endpoint rather than force-reloading the browser.

---

## Running the native WebView

### An app from `zts init` prints an asset count and shows nothing

That is by design. The template is the smallest thing that proves frontend embedding works: it
prints `<name>: 1 embedded assets` and exits. For a desktop app with a window, start from
`examples/counter`'s `build.zig` and `src/main.zig` and wire in `zts_tauri`'s `App` plus a
`zts_webview` backend ([`examples/counter/README.md`](../../../../examples/counter/README.md)).

### Linux renders tofu, or looks different from other OSes

ziggurats ships its own fonts so glyphs match across OSes. Asking for a system font in your CSS
(`system-ui`, …) reintroduces the difference on Linux. Use the bundled `ZTS Sans` / `ZTS Mono`.

### Screenshots come out black (CI / Xvfb)

Force software rendering:

```bash
LIBGL_ALWAYS_SOFTWARE=1 zts …        # plus Xvfb's -screen 0 1280x800x24
```

### The native WebView is not used on macOS / Windows

`zts_webview` picks the backend from the target (GTK on Linux, Cocoa on macOS, Win32 on Windows).
Without GTK3 / WebKit2GTK 4.1 on Linux it falls back to `HeadlessMock`; check with
`pkg-config --exists webkit2gtk-4.1 gtk+-3.0`.

---

## Frontend

### `bindings.gen.ts` does not match `@tauri-apps/api`

`@tauri-apps/api` ships **unmodified**. Check that command names in the generated file match the
schema — including the `plugin:` prefix (`plugin:fs|read_text_file`). Regenerate after schema
changes.

```bash
cd my-app && zig build tsgen     # after adding a tsgen step to build.zig
```

The `zts init` template has no schema yet, so it has no `tsgen` step. Copy the `tsgenBindings`
call from `examples/counter/build.zig`.

### A Vite build goes blank once embedded

Inlining several ES module chunks into one `<script type="module">` leaves `import "./chunk.js"`
unresolvable. `zts build` embeds the whole `web/` **directory** and leaves `/assets/…` resolution
to `zts_web.Assets`. Keep Vite's output inside `web/` and set `base` to a relative `./`.

---

## `zts package`

Most packaging errors come from per-format preconditions (`dmg` is macOS-only, `exe` is PE-only,
…). The message-by-message table lives in
[Packaging §9](package.md#9-usual-traps).

---

## Next

- The whole picture: [Build a counter](../tutorials/counter.md)
- Producing artefacts: [Packaging](package.md)
- Every `zts` flag: [`docs/reference/cli.md`](../../../reference/cli.md)
- Finding the API behind an error: [API index](../../../api/index.html)
- Stuck building ziggurats itself: [`docs/contributing/troubleshooting.md`](../../../contributing/troubleshooting.md)
