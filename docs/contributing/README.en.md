# Developing ziggurats itself (contributor guide)

> **If you are building an app, you do not need this page.** The [tutorials (3 walkthroughs)](../learn/en/tutorials/index.md)
> are the "`zts` CLI builds your own app" instructions. This page is the commands and conventions
> for **building, testing and publishing the ziggurats repository itself** (contributors, agents, and
> our future selves).

## 1. Toolchain

| What | Version / location |
|---|---|
| Zig | `0.17.0` (see `build.zig.zon`) |
| Rust | only for the upstream differential tests and benchmarks |
| Node | for the framework demos and screenshot comparison |
| GTK3 + WebKit2GTK 4.1 | Linux native windows (`Xvfb` in CI) |

### 1.1 What `./zigw` is

`zigw` is a bootstrap for **this checkout only**. It downloads Zig 0.17.0 into a temporary directory
when needed and then runs `zig` for you. It is **not shipped in Releases** and app authors should
never be told to run it — that is rule 10 of `check-docs.py`. On a cold container it avoids
installing anything globally, and `./zigw quick-test` runs the whole unit suite in about five
seconds (0.02 s once cached).

```bash
./zigw quick-test       # zig test src/root.zig — bypasses the 94 s std.Build runner
./zigw full-test        # zig build test — the CI-equivalent full run
./zigw docs-check       # renderer tests + check-docs.py + zig build docs
./zigw doctest          # only the ```zig check fences in the docs
```

## 2. Restore your state in 30 seconds

```bash
bash scripts/status.sh    # branch, task sheets, other agents, toolchain/cache health
./zigw quick-test
python3 scripts/check-docs.py && ./zigw fmt --check src/ build.zig build.zig.zon
```

`status.sh` prints the sharded task sheets and the parallel-agent radar. Never put progress logs in
`AGENTS.md` or the roadmap's checkboxes; one task gets one `docs/tasks/<ID>-<slug>.md`.

## 3. Command index

### 3.1 Tests

| Command | What it covers |
|---|---|
| `./zigw quick-test` | the module graph via `src/root.zig` (fast, cold-start friendly) |
| `./zigw test -Mroot=src/docsite/mod.zig` | docsite renderer tests |
| `zig build test` | the full `std.Build` runner, as CI does it |
| `./zigw doctest` / `python3 scripts/doc-tests.py` | compiles every `zig check` fence |
| `python3 scripts/check-docs.py` | the 13 documentation rules |

### 3.2 Builds

| Command | Output |
|---|---|
| `zig build` | libraries + `zts` CLI |
| `zig build docs` | `zig-out/docs/` (the published site) |
| `zig build dist` | `zig-out/dist/` (the static SSG artefact of `examples/counter`) |
| `zig build examples` | the example binaries |
| `zig build package` | `.deb` / AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz` |

### 3.3 Examples

`examples/counter` (one project → three artefacts), `examples/frameworks` (nine frameworks, one
screen), `examples/gallery` (screenshot regression), `examples/c_embed` (pure C99 overlay host).
The English READMEs sit beside the Japanese ones as `README.en.md`.

### 3.4 Scripts

`scripts/status.sh`, `scripts/check-docs.py`, `scripts/doc-tests.py`, `scripts/ci-logs.sh`,
`scripts/setup-toolchains.sh`, `scripts/verify-screenshots.mjs`, `scripts/compare-screenshots.mjs`.

## 4. Repository map

See [the repository map](repository-map.en.md): the four documentation layers, where each file
lives, how often it changes, and the split unit for parallel work. The short version:

| Layer | Source of truth | Reader | Location |
|---|---|---|---|
| Learn | steps and minimum examples | app author | `docs/learn/{ja,en}/` |
| Look up | Zig source (`///`) | app author | generated `docs/api/**`, `docs/reference/`, `docs/glossary.md` |
| Verify | behaviour contracts | app author | `docs/reference/cli.md`, `docs/reference/tauri-usage.md` |
| Read the inside | ADRs, design notes, task sheets | maintainer | `docs/architecture/`, `docs/decisions/`, `docs/tasks/`, `docs/environment/` |

## 5. Change etiquette

1. **One task, one file.** Create `docs/tasks/<ID>-<slug>.md` from
   [`../tasks/TEMPLATE.md`](../tasks/TEMPLATE.md) and push it first, so other agents can see the lock.
2. Keep `AGENTS.md` and `docs/roadmap/milestones.md` untouched (parallel branches share them).
3. Keep module tests inside `src/<module>/mod.zig`; shared files (`build.zig`, `src/root.zig`)
   get one alphabetically ordered line at most.
4. Before a PR: `check-docs.py`, `fmt --check`, `./zigw docs-check`, then CI on all three OSes.
5. Documentation is bilingual. Adding a reader page means adding **both** halves and a row in both
   indexes; rule 13 (the [sync ledger](doc-sync.en.md)) fails if either is missing.

## 6. CI and distribution

### 6.1 What is shipped

The `zts` binary from GitHub Releases is the only thing app authors need. It is built with the
published archive baked in, so a generated project points at `.url` + `.hash` and needs no checkout.
`zigw` is deliberately **not** shipped.

### 6.2 Making a release build

`zts` built from source writes a relative `.path` into generated `build.zig.zon`; a release build
writes the archive URL. See [the CLI reference](../reference/cli.en.md) and
[the packaging guide](../learn/en/guides/package.md).

## 7. When something breaks

[Repository troubleshooting](troubleshooting.en.md) covers toolchains, cold builds, Zig 0.17 API
differences, screenshot parity and Pages deployment.

## Where to go next

| Want to know | Go to |
|---|---|
| Build an app | [Tutorials](../learn/en/tutorials/index.md) |
| `zts` CLI specification | [CLI reference](../reference/cli.en.md) |
| The whole architecture | [Architecture overview](../architecture/00-overview.md) (Japanese, internal) |
| Design decisions | [`../decisions/`](../decisions/0001-zig-017-and-sharded-agent-workflow.md) (Japanese, internal) |
| Doc conventions | [Writing the docs](writing-docs.en.md) |
| Verification record | [Documentation sync ledger](doc-sync.en.md) |

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
