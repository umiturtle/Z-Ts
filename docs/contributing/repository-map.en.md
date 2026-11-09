# Repository map (for maintainers)

> **Audience**: people changing ziggurats itself, and agents. What each file is, and how far you may go.
> **Time**: 30 seconds to look up one row.
> **Prerequisite**: the toolchain section of [`README.en.md`](README.en.md).

**App authors do not need to read this.** How to use the library is in
[`../INDEX.en.md`](../INDEX.en.md) and [`../learn/en/index.md`](../learn/en/index.md). This is about
**where things live inside the repository**.

The table has two jobs: restoring your place after a context reset, and **keeping several branches
from touching the same file**. The "churn / conflict risk" column is the unit of parallel work.

## 1. The four documentation layers

| Layer | Source of truth | Reader | Location |
|---|---|---|---|
| ① Learn | procedures and minimum examples | app author | [`../learn/`](../learn/en/index.md) (Japanese + English, identical file names) |
| ② Look up | **the Zig source** (`///`) | app author | generated `../api/**`, [`../reference/cli.en.md`](../reference/cli.en.md), [`../glossary.en.md`](../glossary.en.md) |
| ③ Verify | behaviour contracts | app author | [`../reference/cli.en.md`](../reference/cli.en.md), [`../reference/tauri-usage.en.md`](../reference/tauri-usage.en.md) |
| ④ Read the inside | ADRs, design notes, task sheets | maintainer | [`../architecture/00-overview.md`](../architecture/00-overview.md), [`../decisions/0001-zig-017-and-sharded-agent-workflow.md`](../decisions/0001-zig-017-and-sharded-agent-workflow.md), [`../roadmap/milestones.md`](../roadmap/milestones.md), [`../tasks/TEMPLATE.md`](../tasks/TEMPLATE.md), [`../environment/arena-and-caching.md`](../environment/arena-and-caching.md) |

Layer ④ is the project's memory and stays Japanese-only; an English reader can use browser
translation. Layers ①–③ are fully bilingual, verified by rule 13 in
[`doc-sync.en.md`](doc-sync.en.md).

## 2. Where documentation lives

| File | What it is | Churn / risk |
|---|---|---|
| [`../INDEX.en.md`](../INDEX.en.md) · [`../INDEX.md`](../INDEX.md) | the index in sidebar order, one per language | one row whenever a page is added |
| [`doc-sync.en.md`](doc-sync.en.md) · [`doc-sync.md`](doc-sync.md) | when each page was last rewritten, which version was verified | every re-verification (rule 13) |
| [`../glossary.en.md`](../glossary.en.md) · [`../glossary.md`](../glossary.md) | one definition per term | low (both halves together) |
| [`../learn/en/index.md`](../learn/en/index.md) | the learning hub; the route is expanded from `src/docsite/learn_path.zig` | low (never delete the `<!-- learn-path -->` line) |
| `../learn/{ja,en}/concepts/` · `tutorials/` · `patterns/` · `guides/` | the 24 reader pages per language | medium, split by chapter |
| [`../reference/cli.en.md`](../reference/cli.en.md) · [`../reference/cli.md`](../reference/cli.md) | every flag of `zts` | high when `src/cli/args.zig` changes (rule 4 checks both) |
| [`writing-docs.en.md`](writing-docs.en.md) · [`writing-docs.md`](writing-docs.md) | the 13 mechanical rules | low |
| `../architecture/` · `../decisions/` | subsystem designs / ADRs | **add-only**; never edit an existing ADR |
| `../tasks/` | one task = one file, with memory checkpoints | one file per agent |
| `../roadmap/milestones.md` | milestones and parallel waves | do not tick checkboxes here |
| [`../../AGENTS.md`](../../AGENTS.md) | the agent constitution | read only |

## 3. Code and examples

| Path | What it is | Churn / risk |
|---|---|---|
| `src/core/`, `src/rpc/`, `src/tauri/`, `src/bridge/`, `src/webview/`, `src/wasm/`, `src/ssg/` | the ten public packages | split by package (highest contention) |
| `src/cli/` | the `zts` app-author CLI | medium |
| `src/cli/incremental.zig` | dev-loop import graph, dirty flags and build-mode decisions (`plan()`) | medium when touching `zts dev` |
| `scripts/bench-dev-loop.py` | end-to-end dev-loop benchmark + seven invariants (`verify` runs in CI) | low |
| `src/build_tools/` | the shared frontend embedder | low |
| `src/docsite/` | the site generator (Markdown, link checks, API generation) | medium (`main.zig` is large) |
| `src/docsite/learn_path.zig` | the five steps, their minutes, and **the chapter order of the left menu** (`page_order`) | medium when a tutorial is added (rule 12 cross-checks the index and the minutes) |
| `scripts/check-docs.py` | rules 1–13 | low, but every rule has a test |
| `scripts/doc-tests.py` | compiles the `zig check` fences | low |
| `examples/counter`, `examples/frameworks`, `examples/gallery`, `examples/c_embed` | the four shipped examples | split by example |
| `.github/workflows/` | CI (3 OSes + parity) and Pages | low |

## 4. Five rules for parallel work

1. Read `bash scripts/status.sh` before starting; do not touch another agent's task sheet or module.
2. Claim your `docs/tasks/<ID>-<slug>.md` with an early commit and push.
3. Keep checkpoints in that one file (`Current State` / `Decisions` / `Next Step`).
4. Share `build.zig` / `src/root.zig` as one alphabetical line, nothing more.
5. A doc edit touches **both languages, both indexes, and the sync ledger**. Rules 8, 11 and 13 are
   what make that mechanical rather than a matter of memory.
