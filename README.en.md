# ziggurats

**Tauri's ideas, in Zig 0.17.** — desktop apps, WebAssembly and static sites from one codebase and
one toolchain.

> The project's full name is **`ziggurats`** (lowercase). The CLI, package and module names stay
> `zts` / `z_ts` / `zts_*`.

[![CI](https://github.com/umiturtle/Z-Ts/actions/workflows/ci.yml/badge.svg)](https://github.com/umiturtle/Z-Ts/actions/workflows/ci.yml)
[![Docs](https://github.com/umiturtle/Z-Ts/actions/workflows/pages.yml/badge.svg)](https://umiturtle.github.io/ZigguraTs/)

📖 **Documentation site: <https://umiturtle.github.io/ZigguraTs/>**
(search, table of contents and **working demos**; the Markdown in this repository is the source of
truth). Japanese and English are both available on every reader page.

---

## What this is

ziggurats is a toolkit that reimplements the Tauri v2 **IPC protocol, plugins, configuration files and
ACL** in Zig. There is no Rust runtime in between, so the artefact is small, the build is fast, and
the core stays `link_libc = false` (Pure Zig).

| Goal | How |
|---|---|
| **Single binary** | the frontend's `dist/` is embedded at build time with gzip twins and CSP hashes ([how embedding works](docs/architecture/build-tools.md)) |
| **Three artefacts** | native WebView / browser Live Preview (SSE) / server-less static SSG |
| **Identical rendering across OSes** | bundled fonts, layout fingerprints and pixel comparison of three OSes in CI ([pixel parity design](docs/architecture/screenshot-parity.md)) |
| **Nine frameworks** | Angular / Solid / Svelte / SolidStart / Next.js / Nuxt / Astro / SvelteKit / React |
| **Upstream compatibility** | runs **unmodified** `@tauri-apps/api` v2 and reads `tauri.conf.json` / `capabilities/*.json` |

## Quick start (build an app)

The distribution is **one `zts` binary** (about 300 KB, libc-free). All you need is Zig 0.17.

```bash
# 1) download the zts binary for your OS from GitHub Releases and put it on PATH
curl -LO https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/zts-0.1.0-linux-x86_64
chmod +x zts-0.1.0-linux-x86_64
mv zts-0.1.0-linux-x86_64 ~/.local/bin/zts

# 2) create a project
zts init my-app && cd my-app
zts dev                           # serve web/, reloading as you edit
zts build                         # zig-out/bin/my-app (web/ is embedded)
zts doctor                        # check the toolchain and the project
```

The `build.zig.zon` written by `zts init` points at **the published archive's `.url` + `.hash`**, so
no clone is needed (Zig fetches it on the first build, then caches it).

```zig
.z_ts = .{ .url = "https://github.com/umiturtle/Z-Ts/releases/download/v0.1.0/z_ts-0.1.0.tar.gz", .hash = "z_ts-0.1.0-…" },
```

> To build `zts` from source: `git clone … && cd Z-Ts && zig build` (Zig 0.17 on `PATH` is enough).
> Projects generated that way use a `.path` dependency. See
> [`docs/learn/en/guides/install.md`](docs/learn/en/guides/install.md).

`zts` is positioned like the Angular CLI: it operates on **your project only**.
**If this is your first time, follow [`docs/learn/en/start.md`](docs/learn/en/start.md) (10 minutes)
from the top** — that is the fastest route (Japanese:
[`ja/start.md`](docs/learn/ja/start.md)). Prerequisites are in
[`docs/learn/en/guides/install.md`](docs/learn/en/guides/install.md), and every option is in
[`docs/reference/cli.en.md`](docs/reference/cli.en.md).

```bash
# To run the ready-made sample (the samples have their own build.zig)
cd examples/counter
zig build desktop                 # native WebView single binary
zig build preview                 # browser Live Preview (0.0.0.0:8788)
zig build dist                    # server-less static site (zig-out/dist/)
```

## Architecture

```text
zts_foundation  ← dependency-free data structures (OwnedBytes / HandlePool / geometry / glob)
   ↑
zts_web         ← static assets (206 Range / MIME / URL / CSP)          ← foundation only
zts_rpc         ← comptime JSON/Binary RPC router + TypeScript generation ← foundation only
zts_bridge      ← HTTP/1.1 + SSE live server                            ← foundation · web · rpc
zts_webview     ← GTK3+WebKit2GTK / Cocoa / Win32 / HeadlessMock        ← foundation only
zts_tauri       ← Tauri v2 protocol + standard plugins                  ← all of the above
zts_wasm        ← wasm32-freestanding runtime (the same code in a browser)
zts_ssg         ← outward SSG (write dist/) and embedding (dist/ → Zig module)
```

**Boundary promise**: each package is self-contained below `mod.zig`, and the core links no C
library (the OS boundary uses explicit `extern fn … callconv(.c)` bindings only). See
[`docs/architecture/00-overview.md`](docs/architecture/00-overview.md).

## Finding your way around the repository

**For app authors** (the command is `zts`)

The learning path is the same **5 steps, about 95 minutes** as on the documentation site. Start with
step 1.

| # | Step | Min | When you are done | Go to |
|---|---|---|---|---|
| 1 | Your first ten minutes | 10 | the app runs in a browser and a single binary sits in `zig-out/bin/` | [`learn/en/start.md`](docs/learn/en/start.md) ([Japanese](docs/learn/ja/start.md)) |
| 2 | How it works | 15 | you can say what happens between a button and a Zig function | [`learn/en/concepts/`](docs/learn/en/concepts/index.md) |
| 3 | Build an app | 50 | three walkthroughs later you can write commands, state and a screen, and ship it | [`learn/en/tutorials/`](docs/learn/en/tutorials/index.md) |
| 4 | Patterns that hold up | 20 | you can defend a command / state / error design, and you have done the exercises | [`learn/en/patterns/`](docs/learn/en/patterns/index.md) |
| 5 | Look things up | — | you reach the page you need from a job description in one hop | [`learn/en/guides/`](docs/learn/en/guides/index.md) |

**Look something up by job**

| Goal | Go to |
|---|---|
| Follow a tutorial with your own library (9 branches) | [`learn/en/tutorials/frameworks.md`](docs/learn/en/tutorials/frameworks.md) |
| Get `zts` | [`learn/en/guides/install.md`](docs/learn/en/guides/install.md) |
| Write a command (`invoke`) | [`learn/en/guides/rpc.md`](docs/learn/en/guides/rpc.md) |
| Standard Tauri plugins | [`learn/en/guides/plugins.md`](docs/learn/en/guides/plugins.md) |
| Export a static site (`dist/`) | [`learn/en/guides/static-site.md`](docs/learn/en/guides/static-site.md) |
| Build installers (`.deb` / `.dmg` / `.exe`) | [`learn/en/guides/package.md`](docs/learn/en/guides/package.md) |
| Migrate from Tauri v2 | [`learn/en/guides/migrate-from-tauri.md`](docs/learn/en/guides/migrate-from-tauri.md) |
| Something broke | [`learn/en/guides/troubleshooting.md`](docs/learn/en/guides/troubleshooting.md) |
| **API reference** (generated from source) | <https://umiturtle.github.io/ZigguraTs/docs/api/index.html> |
| A word's meaning | [`docs/glossary.en.md`](docs/glossary.en.md) |
| An error name | <https://umiturtle.github.io/ZigguraTs/docs/reference/errors.html> |
| Every `zts` option | [`docs/reference/cli.en.md`](docs/reference/cli.en.md) |

**For people developing ziggurats itself** (the command is `zig build`)

| Goal | Go to |
|---|---|
| Contributor entry point | [`docs/contributing/README.en.md`](docs/contributing/README.en.md) |
| `zig build` steps and scripts | [`docs/contributing/README.en.md`](docs/contributing/README.en.md) §3 |
| Repository troubleshooting | [`docs/contributing/troubleshooting.en.md`](docs/contributing/troubleshooting.en.md) |
| Generate the documentation site | `zig build docs` (→ `zig-out/docs/`) |

**For people reading the inside** (why and how it got this way)

| Goal | Go to |
|---|---|
| Overview / dependency DAG | [`docs/architecture/00-overview.md`](docs/architecture/00-overview.md) |
| Milestones | [`docs/roadmap/milestones.md`](docs/roadmap/milestones.md) |
| Task progress and design notes | [`docs/tasks/`](docs/tasks/) (one task = one file) |
| Architecture decision records | [`docs/decisions/`](docs/decisions/) |
| Tauri v2 usage / internals | [`docs/reference/tauri-usage.en.md`](docs/reference/tauri-usage.en.md) / [`docs/reference/tauri-internals.en.md`](docs/reference/tauri-internals.en.md) |
| Agent operating rules | [`AGENTS.md`](AGENTS.md) |
| Documentation index (sidebar order) | [`docs/INDEX.en.md`](docs/INDEX.en.md) |
| File layout / parallel-work unit | [`docs/contributing/repository-map.en.md`](docs/contributing/repository-map.en.md) |
| Verification record | [`docs/contributing/doc-sync.en.md`](docs/contributing/doc-sync.en.md) |

## Examples

| Example | What it shows |
|---|---|
| [`examples/counter/`](examples/counter/README.en.md) | one project → desktop / Live Preview / static SSG |
| [`examples/gallery/`](examples/gallery/README.en.md) | 17 screenshot regression patterns, compared on three OSes |
| [`examples/frameworks/`](examples/frameworks/README.en.md) | nine frameworks rendering the same one screen |
| [`examples/c_embed/`](examples/c_embed/README.en.md) | overlay embedding in a pure C99 host's existing window |

## Development conventions

* **TDD** (🔴 RED → 🟢 GREEN → 🔵 REFACTOR → 📝 COMMIT) and zero leaks with
  `std.testing.allocator`. Every public function gets at least 5–10 cases covering normal, error,
  boundary and security-boundary behaviour.
* **Read upstream first** — do not guess a spec; read `vendor/{tauri,wry,tao,muda}`.
* **Keep `build.zig` changes minimal**; shared logic belongs in
  [`src/build_tools/`](docs/architecture/build-tools.md) and
  [`src/docsite/`](docs/architecture/documentation-site.md).
* CI (GitHub Actions) verifies Linux / macOS / Windows plus the pixel-comparison job.
* Documentation is **one task / one module / one decision = one file**. No aggregate `PROGRESS.md`
  at the root (it is a conflict source for parallel agents).
* **Every reader page exists in Japanese and English**, with its last-rewrite date and the verified
  version recorded in [`docs/contributing/doc-sync.en.md`](docs/contributing/doc-sync.en.md).

## Licence

The upstream [`tauri`](https://github.com/tauri-apps/tauri) / [`wry`](https://github.com/tauri-apps/wry) /
[`tao`](https://github.com/tauri-apps/tao) / [`muda`](https://github.com/tauri-apps/muda) projects
keep their respective licences (MIT / Apache-2.0). Code under `vendor/` is **for reference only**
and is not part of any build.
