# Branch model (gitflow)

> **Audience**: anyone proposing a change to this repository or cutting a release.
> **Prerequisites**: the repository owner creates `main` and `develop`.

This repository follows **gitflow**. The owner (a human) creates the branches; Arena agents running
in parallel commit to exactly one `arena/*` ref each. Naming is validated by
[`scripts/gitflow.sh`](../../scripts/gitflow.sh), and CI runs its `--self-test` table on every push
(rule 21).

## What each branch is for

| Branch | Purpose | Merge into | Tag |
|---|---|---|---|
| `main` | released state, always shippable | — | `vX.Y.Z` is cut here |
| `develop` | integration for the next release | `main` | never |
| `feature/<slug>` | one unit of work | PR to `develop` | never |
| `release/<x.y.z>` | version freeze and final polish | `main`, then back-merge to `develop` | `v<x.y.z>` on `main` |
| `hotfix/<x.y.z>` | urgent fix to a released version | `main`, then back-merge to `develop` | `v<x.y.z>` on `main` |
| `arena/<agent>` | an Arena agent's working ref | whichever base the owner chose | never |

`<slug>` is lowercase alphanumeric plus `._-`; `<x.y.z>` is SemVer (pre-releases such as
`1.0.0-beta.1` are allowed). A string like `beta-1.0` cannot go into `build.zig.zon`, so it is not
a branch version either.

## Validate a name

```bash
bash scripts/gitflow.sh --check feature/window-state
bash scripts/gitflow.sh --check release/0.1.1
bash scripts/gitflow.sh                 # current branch and its recommended base
bash scripts/gitflow.sh --self-test     # the naming table CI runs
```

The script **never creates a branch** — that is always the owner's job. An agent can only point a
PR's **base** at the `develop` branch the owner created (`--base develop`).

## Cutting a release

`build.zig.zon`'s `.version` is the single source of truth. Rule 20 checks that the CLI version,
release URLs, archive names and the sync ledger all say the same thing.

1. Merge `develop` into `main` and confirm the 3-OS CI is green.
2. Check `.version` in `build.zig.zon` (for example `0.1.1`).
3. Tag the merge commit on `main`:

   ```bash
   git tag v0.1.1 <main commit>
   git push origin v0.1.1
   ```

4. The [`Release`](../../.github/workflows/release.yml) workflow fires on `v*` and publishes the
   source archive → `zig fetch` hash → `zts` binaries for 3 OSes → `SHA256SUMS` → the GitHub
   release. The archive is also imported by a separate package before publishing.
5. Re-resolve the dependency from the public URL:

   ```bash
   zig fetch --save=z_ts https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz
   ```

Because `gh release create` uses `--verify-tag`, push the tag **first**. Do not use
`workflow_dispatch` for a release: `github.ref_name` would be a branch name.

## Branches CI reacts to

`push.branches` in [`ci.yml`](../../.github/workflows/ci.yml) is `main` / `develop` /
`feature/**` / `release/**` / `hotfix/**` / `arena/**`. A push to any of them runs the same 3-OS
matrix. Pages and Release are restricted to `main` and tags.

## Coexisting with Arena agents

- An agent is pinned to one branch per session (`arena/...`) and cannot create, check out or push
  any other branch. That is what keeps parallel agents from colliding.
- An agent therefore never creates a branch *named* `feature/*`, but it can open a PR against the
  `develop` branch you created.
- [`AGENTS.md`](../../AGENTS.md) and `docs/roadmap/milestones.md` checkboxes are shared by every
  branch and are never edited. Progress lives in one file per task under `docs/tasks/<ID>-*.md`.

## Related

- [Repository map](repository-map.en.md)
- [Documentation sync ledger](doc-sync.en.md)
- [GitHub Actions operations](../environment/github-actions.md)
- For app authors adding the dependency → [`../learn/en/guides/library.md`](../learn/en/guides/library.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
