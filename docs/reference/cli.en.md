# `zts` command reference

> **Audience**: anyone looking up a `zts` command or flag.
> **Time**: just the section you need.

The specification of the app author's CLI. `zts` operates on **your project**.

> **Operating the ziggurats repository itself** (`zig build` steps, CI scripts) is documented in
> [`../contributing/README.en.md`](../contributing/README.en.md). It is deliberately not on this page.

```text
zts <command> [options]

  init     Scaffold a new project
  dev      Serve `web/` with rebuild-on-change
  build    Build the app into a single executable
  package  Wrap the executable into .deb / AppDir / .app / .exe / .tar.gz
  migrate  Convert an existing Tauri v2 project into a ziggurats project
  doctor   Check the toolchain and the project
  help     Show this help
  version  Print the version
```

`zts help` prints this list; `zts version` prints one line such as `zts 0.1.0`. Running `zts` with
no arguments is the same as `help`. Exit codes are `0` (success) and `1` (failure); `dev` keeps
running until Ctrl-C.

---

## `zts init [dir]`

Scaffolds a minimal project, builds it once immediately, and writes the `.fingerprint` that Zig
requires in `build.zig.zon` back into the generated file.

| Option | Default | Meaning |
|---|---|---|
| `[dir]` (positional) | `.` | Destination; created if missing |
| `--dir <path>` | — | Alternative to the positional argument |
| `--name <name>` | directory name | Zig package name (`[a-z][a-z0-9_]*`, at most 31 characters) |
| `--zts-path <path>` | see "Where the dependency comes from" | Value written to `.z_ts.path`; for a local checkout |
| `--zts-url <url>` | archive baked into a release build | `.z_ts.url`; **must** be paired with `--zts-hash` |
| `--zts-hash <hash>` | — | `.z_ts.hash` (the value `zig fetch` returns) |
| `--force` | off | Write into a directory that already has files |

Generated files:

```text
.gitignore  README.md  build.zig  build.zig.zon  src/main.zig  web/index.html
```

```bash
zts init my-app
zts init . --name my_app          # current directory, explicit package name
zts init my-app --force           # overwrite existing files
```

| Failure | Message |
|---|---|
| Directory not empty and no `--force` | `already has files — pass --force to write into it anyway` |
| Directory name cannot become a package name | `cannot derive a package name from '…' — pass --name <name>` |
| Package name violates the convention | `'…' is not a usable package name (…` |

### Where the dependency comes from (`.z_ts`)

`zts init` writes one line into the generated `build.zig.zon` saying where the project gets ziggurats.
A **`zts` built as a release** (the binary from GitHub Releases) points at the published archive:

```zig
.z_ts = .{ .url = "https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/z_ts-0.1.0.tar.gz", .hash = "z_ts-0.1.0-…" },
```

A `zts` built from a checkout writes a relative path to that checkout:

```zig
.z_ts = .{ .path = "../../../home/you/Z-Ts" },
```

| Situation | What is written |
|---|---|
| Published binary | `.url` + `.hash` (baked in; needs the network once, no checkout) |
| `--zts-url` and `--zts-hash` | the supplied `.url` + `.hash` (takes priority over the baked-in pair) |
| `--zts-path`, or `zts` built from source | `.path` (a local checkout) |

Passing only `--zts-url` or only `--zts-hash` fails with `IncompleteZtsRelease`: half a pair would
produce a `build.zig.zon` that Zig cannot read.

> A `.url` project fetches the archive into Zig's cache on its first `zig build`; later builds work
> offline.

The generated `build.zig` starts the shared embedder from the dependency's sources and embeds
`web/` as the `embedded_frontend` module. It has two steps: `run` and `frontend`.

## `zts dev`

Serves `web/` over HTTP, watches for changes, and does **only the smallest necessary update**.

| Option | Default | Meaning |
|---|---|---|
| `--dir <path>` | `.` | Project |
| `--host <addr>` | `127.0.0.1` | Bind address; `0.0.0.0` exposes it |
| `--port <n>` | `5173` | 1–65535 |
| `--browser` / `--open` | off | Open the default browser after startup (`--open` is an alias) |

### What gets updated

`zts dev` polls `src/`, `web/`, `build.zig` and `build.zig.zon`, and does the smallest update the
**contents** of the changed files require (no inotify / FSEvents). Zig sources are compared by a
**content hash** as well as their stat, so `touch` or a formatter writing the same bytes back does
not trigger a rebuild.

| Changed | What `zts dev` does | In the browser | Measured here |
|---|---|---|---|
| only `web/**/*.css` | **no build**; just reports "css" | swaps `<link rel="stylesheet">` **without reloading**, so scroll position, in-progress input and the console survive | ~0.2 s |
| anything else in `web/` (HTML / JS / images…) | **no build** (files are served from disk, so the next request sees the new one) | full reload | ~0.2 s |
| Zig source under `src/` that is part of the build | **`update` on a persistent compiler server** (type-check only, single-digit ms) | reload on success, keep the last good output on failure | ~0.1 s |
| an unreachable file under `src/` (not imported anywhere) | **nothing** | no change | 0 |
| `build.zig` / `build.zig.zon`, or files added/removed | **`zig build`** (full build) | reload on success | ~0.8 s |

> **Why a type-check is enough.** `zts dev` serves `web/` from disk and never starts the Zig
> executable. Zig 0.17 Debug uses the **self-hosted backend, not LLVM** (forcing `-fllvm` is ~4x
> slower). The generated `build.zig` has a `check` step whose emitted binary nobody asks for, so
> Zig adds `-fno-emit-bin` and skips codegen, linking and install. `zts dev` goes further and keeps
> **one Zig compiler process alive**, asking it to re-analyse only what changed (first check ~0.4 s,
> then a few milliseconds). Passing `-fincremental` to a fresh process every time is *slower*, so
> it is not used. **The first build of a session and `zts build` are still full builds**, where
> link errors are caught. "ok" in `zts dev` means the types pass; use `zts build` to validate the
> real binary. `ZTS_DEV_BUILD=full` forces full builds in the dev loop too.
>
> If the persistent server is unavailable (older template without a `check` step, `build.zig`
> linking native libraries, verbose argv capture or protocol failure), `zts dev` automatically falls back
> to `zig build check` and then to a full build. It never trades correctness for speed.

> **Why a `web/` change needs no build.** `zts dev` serves `web/` from disk. Regenerating the
> embedded copy would not change a single byte of the preview. Only Zig (`src/`) needs a build.

> **`zts dev` does not open a native window.** The preview is a browser looking at `web/`; the Zig
> app process is not running. To exercise an `invoke` round trip, run `zts build` and start
> `zig-out/bin/<name>` directly ([Concepts: commands](../learn/en/concepts/commands.md)).

### Behaviour

| Item | Behaviour |
|---|---|
| Serving | static files under `web/`; `/` is `index.html`; `Cache-Control: no-store` |
| Watching | compares **path + mtime + size** of `src/` and `web/`, plus `build.zig` / `build.zig.zon`; Zig sources also get a **content hash** (no inotify / FSEvents, so all three OSes behave identically) |
| Polling | 250 ms while idle, 50 ms for ~2 s after a change (with a ms-scale check, this is now the dominant latency) |
| Debounce | after a change, waits 60 ms, rescans and diffs against the **final** scan — folding a burst of editor writes into one update and never dropping an edit that arrived during the wait |
| Dependency graph | follows relative `@import` / `@embedFile` edges from `src/main.zig`; only reachable files trigger a build. Unresolved imports or added/removed files fall back to a full build |
| Reload | injects a script just before `</body>` that polls `/__zts_dev__/state` every 700 ms |
| CSS swap | creates a new `<link>` with `?zts=<v>` beside the old one and removes the old one after load; falls back to a full reload on error |
| Build failure | keeps serving the last successful output and returns `ok:false` with `v` unchanged |

```bash
zts dev
zts dev --port 5199 --host 0.0.0.0 --browser
curl http://127.0.0.1:5173/__zts_dev__/state    # {"v":3,"ok":true,"hot":"css"}
```

`v` increments on **each successful update**; `hot` is `"css"` (swap in place) or `"full"` (reload).
If `ok` stays `false`, fix the Zig error shown in the terminal. Design and measurements:
[`../architecture/incremental-dev-build.md`](../architecture/incremental-dev-build.md).

## `zts build`

Builds the project and prints the path to the produced executable.

| Option | Default | Meaning |
|---|---|---|
| `--dir <path>` | `.` | Project |
| `--target <triple>` | host | Zig target (for example `aarch64-macos`, `x86_64-windows-gnu`) |
| `--debug` | off | Build `Debug` (default is `ReleaseSmall`) |
| `--release` | on | State `ReleaseSmall` explicitly (a restatement of the default; combining with `--debug` is an error) |
| `--frontend-only` | off | Run only the `frontend` step of `build.zig` (re-embed `web/`) |

```bash
zts build
zts build --debug
zts build --target aarch64-macos
zts build --frontend-only       # a few hundred milliseconds
```

`zts build` **rejects flags it does not understand** rather than silently dropping them. For a
`build.zig` option such as `-Dgtk=false`, run `zig build` directly in the project directory. Zig's
stderr is passed through unchanged.

## `zts package`

Wraps the executable produced by `zts build` into something distributable. Every argument is
optional; by default it produces **one host-OS format** (Linux: `deb`, macOS: `app`, Windows: `exe`).

```bash
zts package                                  # host default
zts package --format deb,appdir,tar.gz       # three Linux formats at once
zts package --format exe --icon-ico app.ico --manifest app.manifest
zts package --icon icon.png --version 1.2.0 --maintainer "You <you@example.com>"
```

| Option | Default | Meaning |
|---|---|---|
| `--dir <path>` | `.` | Project |
| `--format <list>` | host default | Comma-separated: `deb`, `appdir`, `app`, `dmg`, `exe`, `tar.gz` |
| `--binary <path>` | `zig-out/bin/<name>` | Executable to wrap (relative to `--dir`) |
| `--out <path>` | `<dir>/zig-out/package` | Output directory |
| `--version <semver>` | `.version` from `build.zig.zon` | Package version |
| `--identifier <id>` | `com.example.<name>` | Reverse-DNS identifier (macOS `CFBundleIdentifier`) |
| `--maintainer <who>` | `ZTS_MAINTAINER`, else a placeholder | `Name <email>` |
| `--description <text>` | `<display> desktop application` | One-line description |
| `--icon <png>` | none | PNG for `.deb` / AppDir / `.app` (256×256 recommended) |
| `--icon-ico <ico>` | none | `.ico` embedded in the Windows executable |
| `--manifest <xml>` | none | Manifest embedded in the Windows executable |

| Format | Output (`<…>` substituted) | Contents |
|---|---|---|
| `deb` | `<name>_<version>_<arch>.deb` (`<name>` with `-` separators) | `ar` + `control.tar.gz` + `data.tar.gz`; readable by `dpkg-deb -c` |
| `appdir` | `<name>-<version>-<arch>.AppDir/` | `AppRun` / `usr/bin/<name>` / `.desktop` / icon (AppImage input) |
| `app` | `<display>.app/` | `Contents/{Info.plist,PkgInfo,MacOS/<name>,Resources/<name>.png}` |
| `dmg` | `<display>-<version>.dmg` | builds the `.app` then runs `hdiutil` (**macOS only**) |
| `exe` | `<name>.exe` | copies the PE as-is and appends one `.rsrc` section |
| `tar.gz` | `<name>-<version>-<arch>.tar.gz` | the whole `<name>-<version>/` tree; buildable from any host |

| Item | Behaviour |
|---|---|
| Architecture | read from the executable's header (ELF / Mach-O / PE), so cross-builds correctly say `arm64` |
| `Depends:` | built from the sonames the ELF actually links; a non-GUI app does not pull in GTK |
| Reproducibility | `ar` members and tar entries use mtime `0` and owner `0/0`; identical input gives identical bytes |
| Failure | writes nothing and exits `1`; a format/binary mismatch (a PE with `deb`, say) is detected up front |
| `License:` | not written into `control` (that field does not exist in Debian binary control); it goes into `copyright` |

```text
$ zts package --format deb,tar.gz --icon icon.png
zts: wrote ./zig-out/package/my_app_0.1.0_amd64.deb (65742 bytes)
zts: wrote ./zig-out/package/my-app-0.1.0-amd64.tar.gz (64911 bytes)
zts: packaged 2 artifact(s) into ./zig-out/package
```

```bash
sudo dpkg -i zig-out/package/my_app_0.1.0_amd64.deb   # Debian/Ubuntu
tar -xzf zig-out/package/my-app-0.1.0-amd64.tar.gz    # anywhere
```

Per-format prerequisites are in [`../learn/en/guides/package.md`](../learn/en/guides/package.md).

## `zts migrate [src-tauri]`

Converts an existing Tauri v2 project into a **new** ziggurats project while leaving the original
Rust tree untouched. It copies `tauri.conf.json`, `frontendDist/**`, `capabilities/*.json` and
`icons/**`, and writes a bilingual `MIGRATION.md`.

| Option | Default | Meaning |
|---|---|---|
| `[src-tauri]` (positional) | `src-tauri` | existing project; `tauri.conf.json` is looked for here and one level down |
| `--dir <path>` | `<parent>/<productName>-zts` | output directory (the source project is never modified) |
| `--name <name>` | normalised `productName` | Zig package name |
| `--zts-path <path>` | same as `zts init` | `.z_ts.path` in `build.zig.zon` |
| `--force` | off | write into a non-empty output directory |
| `--dry-run` | off | print the plan, detected values and warnings without writing any file |

```bash
$ zts migrate apps/legacy/src-tauri --dry-run
zts migrate: apps/legacy/src-tauri -> apps/legacy_notes-zts
  productName   Legacy Notes
  frontendDist  ../dist (2 files)
  capabilities  1 files / icons 1 files / rust 1 files
  files to write 11
  warning: Rust commands are NOT translated. Port 1 `src/*.rs` file(s) to a `zts_rpc.Schema` by hand.
zts migrate: --dry-run, nothing written (MIGRATION.md would explain the manual steps)
```

`#[tauri::command]` functions are not translated. Port them with §3 of the
[migration guide](../learn/en/guides/migrate-from-tauri.md); the generated `MIGRATION.md` lists the
detected values and every remaining step.

---

## `zts doctor`

Checks the environment and the project, exiting `1` on any problem. A **release `zts` has no
checkout**, so the `checkout` / `z_ts` lines disappear and `(none — release build)` is shown instead.

```text
$ zts doctor                     # zts built from source
zts 0.1.0
  checkout     /home/you/Z-Ts
  z_ts         present
  zig          /tmp/zts-toolchains/zig-0.17.0/ziglang/zig
  package      my_app
  dependency   ../../home/you/Z-Ts
  web/         present

all checks passed
```

```text
$ zts doctor                     # release zts (no checkout)
zts 0.1.0
  checkout     (none — release build)
  zig          /usr/local/bin/zig
  package      my_app
  dependency   https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/z_ts-0.1.0.tar.gz (fetched by zig)
  web/         present

all checks passed
```

| Line | Checks | On failure |
|---|---|---|
| `checkout` | the checkout that built `zts`; `(none — release build)` for releases | — |
| `z_ts` | that the path exists (line omitted for release builds) | `MISSING at … — rebuild zts or pass --zts-path` |
| `zig` | which `zig` is used (`ZTS_ZIG` → `PATH` → checkout) | `MISSING — install Zig 0.17 on PATH or set ZTS_ZIG` |
| `package` | `.name` in `build.zig.zon` | `MISSING .name in build.zig.zon` |
| `dependency` | that `.z_ts.path` exists; for `.z_ts.url` it prints the URL (fetch happens on first build) | `… does not exist (resolved from …)` |
| `web/` | the frontend directory | `missing — the embedder needs a front end` |

`--dir <path>` selects the project. **No other flag is accepted** — unknown flags are rejected as
`UnknownFlag`, never silently ignored, so a typo is visible.

## `zts --help` / `--version`

Global flags that belong to no subcommand. `help` / `-h` and `version` / `-V` mean the same thing;
bare `zts` shows help and exits `0`.

```bash
zts --help
zts --version
zts help          # same
```

## Environment variables

| Variable | Meaning |
|---|---|
| `ZTS_ZIG` | Path to the `zig` to use. If unset: `PATH` → the checkout's `zig` (release builds stop at `PATH`) |
| `ZTS_MAINTAINER` | Default for `zts package --maintainer` |
| `ZTS_DEV_BUILD` | Set to `full` to make `zts dev` do a full build on every Zig edit (link validation, or the baseline side of the benchmark) |

---

## Where to go next

- Getting started: [`../learn/en/tutorials/counter.md`](../learn/en/tutorials/counter.md)
- Getting `zts`: [`../learn/en/guides/install.md`](../learn/en/guides/install.md)
- Building installers: [`../learn/en/guides/package.md`](../learn/en/guides/package.md)
- Repository commands: [`../contributing/README.en.md`](../contributing/README.en.md)
