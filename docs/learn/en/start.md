# Your first ten minutes with Z-Ts

> **Audience**: anyone who has not run Z-Ts yet. No Zig or Web knowledge assumed.
> **Time**: 10 minutes. **What you need**: a terminal, Zig 0.17, and the `zts` binary (one file).
> **What you get**: your own project running in a browser, plus a single binary in `zig-out/bin/`.

Work through this page top to bottom and you will have Z-Ts running. There is no architecture
talk here: **run it first, understand it second**, which is how the rest of these docs are ordered.

```text
① get zts ──► ② scaffold ──► ③ serve ──► ④ edit ──► ⑤ build a binary
  install zts     zts init     zts dev    web/index.html     zts build
```

---

## 1. Get `zts` (3 minutes)

`zts` is the CLI that drives a Z-Ts project. What you install is **one binary** (about 300 KB, no
libc dependency); you bring Zig.

```bash
# 1) Zig 0.17 on PATH (skip if you already have it)
zig version             # → 0.17.0

# 2) download the zts binary for your OS and put it on PATH
curl -LO https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/zts-0.1.0-linux-x86_64
chmod +x zts-0.1.0-linux-x86_64
mkdir -p ~/.local/bin
mv zts-0.1.0-linux-x86_64 ~/.local/bin/zts
export PATH="$HOME/.local/bin:$PATH"
zts version             # → zts 0.1.0
```

**No clone, no `./zigw`.** `zts` only spawns `zig`. The PowerShell command, `ZTS_ZIG`, and platform
packages are in [`guides/install.md`](guides/install.md).

> [!NOTE]
> Working on Z-Ts itself, or prefer source builds? `git clone` + `zig build` produces the same
> binary (`./zigw` is that repository's bootstrap wrapper, not a distributed artifact). A `zts`
> built that way makes generated projects depend on the checkout via `.path`.

## 2. Check the environment (1 minute)

```bash
zts doctor
```

`all checks passed` means you are ready. If something is missing:

| Output | Meaning | Fix |
|---|---|---|
| `zig          MISSING` | `zts` cannot find the Zig compiler | install Zig 0.17 on `PATH`, or `export ZTS_ZIG=<path to zig>` |
| `z_ts MISSING at …` | (source builds only) the checkout that built `zts` is gone | move the checkout there, or pass `zts init --zts-path` |
| a `gtk` / `webkit` warning | Linux GUI libraries are absent | ignore it while you are only serving the front end |

## 3. Create a project (1 minute)

```bash
cd ~
zts init my-app
cd my-app
```

`zts init` writes six files and then builds **once**, so the fingerprint Zig demands in
`build.zig.zon` is filled in for you.

| File | What it is |
|---|---|
| `src/main.zig` | the application (at first it just counts the embedded files) |
| `web/index.html` | the UI, with inline `<style>` and `<script>` |
| `build.zig` / `build.zig.zon` | build definition; `web/` becomes `embedded_frontend` |
| `README.md` / `.gitignore` | convenience only |

**There is no link between the page and Zig yet.** The scaffolding only serves `web/` and embeds it
at build time. Attaching "button → Zig function" to that scaffolding is the job of
[Build an app](tutorials/counter.md), two steps from here.

## 4. Serve it (2 minutes)

```bash
zts dev
```

```text
zts: my_app — serving web/ at http://127.0.0.1:5173/
     watching src/ and web/ — Ctrl+C to stop
```

Open <http://127.0.0.1:5173/> and you will see the `my_app` heading and the line
"Edit `web/index.html`, then run `zts dev`." **That is your first success.**

`zts dev` does two things at once:

- serves `web/` over HTTP, and keeps serving the last good output when a build fails
- watches `src/` and `web/`, rebuilds on change, and reloads the browser

`zts dev --browser` opens your default browser on start.

## 5. Edit and watch it land (2 minutes)

Change the `<h1>` in `web/index.html` and save. **Do not touch the terminal.**

```html
<h1>my_app — hello Z-Ts</h1>
```

The browser reloads within about a second. The write → see loop is now closed; everything else in these
docs is that loop with more in it.

## 6. Build a single binary (1 minute)

```bash
zts build
./zig-out/bin/my_app
```

```text
my_app: 1 embedded assets
  index.html (… bytes)
```

`zts build` compiles with `ReleaseSmall` and embeds `web/` **inside the executable**, so shipping it
means shipping one file. Stop `zts dev` before running the binary.

> [!TIP]
> On Linux without the GTK / WebKit2GTK development packages, `zts build` builds with the GUI
> backend disabled (the same as `zig build -Dgtk=false`). Install them when you are ready for a
> windowed app — the table in [`guides/install.md`](guides/install.md) says which.

---

## What you have now

```text
✔ zts version             → zts 0.1.0
✔ zts doctor              → all checks passed
✔ zts init my-app         → six files + a filled-in fingerprint
✔ zts dev                 → my_app visible in the browser
✔ edit web/index.html     → reloaded automatically
✔ zts build               → zig-out/bin/my_app (front end embedded)
```

## Where to go next

The four steps above this page are the learning path; the same rail is at the top of every page on
it. The order is a suggestion. Going on to [How it works](concepts/index.md) gives you a 15-minute
map before the `Schema` and `invoke` in [Build an app](tutorials/counter.md) show up. **If you would
rather build first**, jump straight to the tutorial and come back when a word stops you.

1. **[How it works](concepts/index.md)** (15 min) — the three moving parts, and how a button reaches Zig
2. **[Build an app](tutorials/counter.md)** (15 min) — your own command, a test, one binary
3. **[Look things up](guides/index.md)** — from here on, read only what you need

Stuck on a word? [Glossary](../../glossary.md). Stuck on an error?
[Troubleshooting](guides/troubleshooting.md) and the [error index](../../reference/errors.html).
