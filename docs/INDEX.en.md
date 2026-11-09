# Documentation index

> **Audience**: anyone deciding which page to read next, or looking a name up.
> **Time**: 30 seconds as a table of contents.

This is the map of the published site (<https://umiturtle.github.io/Z-Ts/>), in **the same order as
the sidebar**. Press `/` for full-text search; the `日本語 / English` control in the top right
switches language on every reader page, including this one.

**Only ten minutes?** → [Your first ten minutes with ziggurats](learn/en/start.md).
Prefer the whole picture first? → [Learn ziggurats (the learning path)](learn/en/index.md).

## Three ways in

ziggurats has three kinds of reader, with different commands and different pages. Mixing them shows an
app author the repository's CI, or a contributor the app tutorial.

| You are | Start here | Tool |
|---|---|---|
| **Building an app** | [Your first ten minutes](learn/en/start.md) → [Learning path](learn/en/index.md) (Japanese: [`learn/ja/`](learn/ja/index.md)) | `zts` (`init` / `dev` / `build` / `package` / `doctor`) |
| **Looking a name up** | [API reference](api/index.html) / [Glossary](glossary.en.md) / [Error index](reference/errors.html) | — |
| **Developing ziggurats itself** | [Contributing](contributing/README.en.md) → [Repository map](contributing/repository-map.en.md) | `zig build` / `scripts/*` |

## The learning path (5 steps, about 95 minutes)

The same sequence appears on the landing page and in the rail at the top of every path page. You
may skip ahead; you will just be looking up more words later.

| # | Step | Min | When you are done | Start |
|---|---|---|---|---|
| 1 | Your first ten minutes | 10 | your app runs in a browser and a single binary sits in `zig-out/bin/` | [start.md](learn/en/start.md) |
| 2 | How it works | 15 | you can say what happens between a button and a Zig function | [concepts/](learn/en/concepts/index.md) |
| 3 | Build an app | 50 | three walkthroughs later you can write commands, state and a screen, and ship it | [tutorials/](learn/en/tutorials/index.md) |
| 4 | Patterns that hold up | 20 | you can defend a command / state / error design, and you have done the exercises | [patterns/](learn/en/patterns/index.md) |
| 5 | Look things up | — | you reach the page you need from a job description in one hop | [guides/](learn/en/guides/index.md) |

**Every page has a Japanese and an English file.** In the learning tree the file names are identical
(`docs/learn/ja/` ↔ `docs/learn/en/`); the pages that exist once use a `.en.md` mirror
(`docs/glossary.md` ↔ `docs/glossary.en.md`). `check-docs.py` rule 13 checks both halves of every
pair, so a page added in one language fails CI.

---

## The site's order

### Learning path

| Page | One line |
|---|---|
| [Learn ziggurats](learn/en/index.md) | The route, a 30-second overview, prerequisites, and the entry for each goal. Start here |

### 1 · Your first ten minutes

| Page | One line |
|---|---|
| [Your first ten minutes with ziggurats](learn/en/start.md) | Put the binary on `PATH`, then `doctor` → `init` → `dev` → `build` on one page (10 min) |

### 2 · How it works

| Page | One line |
|---|---|
| [Concepts](learn/en/concepts/index.md) | The whole system in three actors (page / bridge / command) |
| [Package layout](learn/en/concepts/architecture.md) | Six layers with dependencies in one direction; where to put your code |
| [How a command arrives](learn/en/concepts/commands.md) | `invoke` becomes a Zig function; what `Schema` does and where types are checked |
| [Plugins](learn/en/concepts/plugins.md) | The seven standard Tauri plugins and `withCorePlugins` |
| [Security](learn/en/concepts/security.md) | Deny by default: capabilities, scopes, CSP — and what it does not protect |

### 3 · Build an app

| Page | One line |
|---|---|
| [Tutorials](learn/en/tutorials/index.md) | Chapter hub: the three walkthroughs, how to work through them, prerequisites |
| [Build a counter](learn/en/tutorials/counter.md) | `zts init` → command → screen → `dev` → `build` → `doctor` (15 min) |
| [Build a todo list](learn/en/tutorials/todo.md) | State in one struct, three commands, returning `error{}`, testing commands (20 min) |
| [Build the screen](learn/en/tutorials/ui.md) | Loading / empty / error states, CSS swapping, CSP (15 min) |

### 4 · Patterns that hold up

| Page | One line | Exercises |
|---|---|---|
| [Patterns](learn/en/patterns/index.md) | Turn working code into code that survives growth; chapter cheat sheet | — |
| [Designing commands](learn/en/patterns/commands.md) | Granularity, arguments, return values, naming. One verb = one command | 3 |
| [Where state lives](learn/en/patterns/state.md) | Zig when correctness matters, the frontend when only looks matter | 2 |
| [Designing errors](learn/en/patterns/errors.md) | `error{}` granularity, validation at the boundary, messages in the UI | 3 |
| [The page/logic boundary](learn/en/patterns/boundaries.md) | `$try` vs `throw`, optimistic updates, double submits | 2 |

### 5 · Look things up

| Page | One line |
|---|---|
| [Guides](learn/en/guides/index.md) | The job-to-page index. You do not have to read all of it |
| [Get `zts`](learn/en/guides/install.md) | Release binaries, `PATH`, `ZTS_ZIG`, building from source |
| [Write a command](learn/en/guides/rpc.md) | `zts_rpc`: command → `Schema` → `bind` → `dispatch` → TypeScript generation |
| [Standard Tauri plugins](learn/en/guides/plugins.md) | window / event / path / fs / dialog / clipboard / menu / tray and capabilities |
| [Export a static site](learn/en/guides/static-site.md) | `exportStaticSite` and WASM; a `dist/` with no server |
| [Build installers](learn/en/guides/package.md) | `zts package`: `.deb` / AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz` |
| [Migrating from Tauri v2](learn/en/guides/migrate-from-tauri.md) | `tauri.conf.json`, ACL, commands and plugins side by side |
| [Troubleshooting](learn/en/guides/troubleshooting.md) | `zts` errors and how to fix them |

### Reference

| Page | One line |
|---|---|
| [Glossary](glossary.en.md) | Definitions of the words used throughout the text |
| [`zts` command reference](reference/cli.en.md) | Every command and every flag of the app author's CLI |
| [Tauri v2 API map](reference/tauri-usage.en.md) | Upstream Rust/JS API, config and Capabilities, mapped |
| [Error index](reference/errors.html) | From an `error{…}` name back to where it is declared (generated) |

### API

Generated from `///` comments (**do not edit by hand**; `zig build docs` writes it). Every public
declaration can be reached by package or alphabetically.

| Entry | Contents |
|---|---|
| [All declarations (A–Z)](api/index.html) | Every public symbol, by name |
| [`zts_foundation`](api/zts_foundation/index.html) | Dependency-free data structures (`OwnedBytes` / `HandlePool` / geometry / glob) |
| [`zts_web`](api/zts_web/index.html) | Static asset serving (206 Range / MIME / URL / CSP) |
| [`zts_core`](api/zts_core/index.html) | Base types, generational pools, the Host contract |
| [`zts_rpc`](api/zts_rpc/index.html) | comptime JSON/Binary RPC router and TypeScript generation |
| [`zts_bridge`](api/zts_bridge/index.html) | HTTP/1.1 + SSE live server |
| [`zts_webview`](api/zts_webview/index.html) | GTK3+WebKit2GTK / Cocoa / Win32 / HeadlessMock |
| [`zts_tauri`](api/zts_tauri/index.html) | Tauri v2 protocol and standard plugins |
| [`zts_wasm`](api/zts_wasm/index.html) | The `wasm32-freestanding` runtime |
| [`zts_ssg`](api/zts_ssg/index.html) | Writing `dist/` and embedding `dist/ → Zig` |
| [`z_ts`](api/z_ts/index.html) | The umbrella import (`@import("z_ts")`) |

### Examples

All four are built on three OSes in CI, with their screenshots compared pixel by pixel.

| Page | One line |
|---|---|
| [Counter](../examples/counter/README.en.md) | One project → desktop / Live Preview / static SSG |
| [Nine frameworks](../examples/frameworks/README.en.md) | Angular / Solid / Svelte / SolidStart / Next / Nuxt / Astro / SvelteKit / React, one screen |
| [Gallery](../examples/gallery/README.en.md) | Screenshot regression (PNG + `manifest.json`) |
| [C embedding](../examples/c_embed/README.en.md) | Overlay embedding in a pure C99 host (zero lines of Zig in the host) |

### Repository

| Page | One line |
|---|---|
| [Developing ziggurats](contributing/README.en.md) | Toolchain, `zig build` steps, change etiquette, CI |
| [Repository map](contributing/repository-map.en.md) | Which file does what and how often it changes (the parallel-work unit) |
| [Repository troubleshooting](contributing/troubleshooting.en.md) | Toolchain, cold builds, 0.17 API differences, Pages |
| [Documentation sync ledger](contributing/doc-sync.en.md) | When each page was last rewritten and which version was verified |
| [Writing the docs](contributing/writing-docs.en.md) | Four layers, page skeleton, `zig check`, notes, glossary, generated output |

### Internals

The sidebar folds these into a single **[design notes · ADRs · tasks](architecture/00-overview.md)**
entry; they are not a chapter to read in order. They are the project's memory and remain
Japanese-only — an English reader who needs one can use the browser's translation. Open them only
when you are looking for why the implementation looks the way it does.

| Location | Contents |
|---|---|
| [`architecture/`](architecture/00-overview.md) | Why this shape (dependency DAG, boundary contracts, subsystem designs) |
| [`decisions/`](decisions/0001-zig-017-and-sharded-agent-workflow.md) | Architecture decision records (add only, never edit) |
| [`roadmap/milestones.md`](roadmap/milestones.md) | Milestones and the parallel-wave dependency map |
| [`tasks/`](tasks/TEMPLATE.md) | One task = one file, with memory checkpoints |
| [`environment/`](environment/arena-and-caching.md) | Arena caching and GitHub Actions operations |
| [`reference/tauri-internals.en.md`](reference/tauri-internals.en.md) | IPC protocol, macros and built-in plugins dissected (for porters) |
| [`decisions/0018-documentation-site.md`](decisions/0018-documentation-site.md) | The design of this site itself |

## Look a name up

| Looking for | Where |
|---|---|
| A word's meaning | [Glossary](glossary.en.md) (linked from the text as it appears) |
| An error name | [Error index](reference/errors.html) (generated from `error{…}` in `src/**`) |
| A function, type or constant | [API index](api/index.html) (generated from `///`) |
| Commands and flags | [`zts` command reference](reference/cli.en.md) |
| Any page | Site search (press `/`); the index is `assets/search-index.js` |
| A machine-readable table of contents | `llms.txt` at the site root (full text: `llms-full.txt`) |

> **Maintaining this index**: the sidebar order lives in `GroupKey` in
> [`src/docsite/main.zig`](../src/docsite/main.zig); the step numbers and minutes come from
> [`src/docsite/learn_path.zig`](../src/docsite/learn_path.zig). Add a row here whenever you add a
> page — **rule 11** fails if a reader page is not linked from its language's index, and
> **rule 13** ([sync ledger](contributing/doc-sync.en.md)) fails if the Japanese and English halves drift apart.
> The menu is the same in both languages and on every page (`GroupKey.order()` takes no language).
> The chapter order comes from `page_order`, and **rule 12** cross-checks the minutes quoted here,
> in `README.md`, and in both learning hubs. **Rule 14** keeps the full name `ziggurats` (lowercase)
> consistent in prose while leaving the legacy name in repository URLs/paths and the `zts` /
> `z_ts` / `zts_*` identifiers alone.
