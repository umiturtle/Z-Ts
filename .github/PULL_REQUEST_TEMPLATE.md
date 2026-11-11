## What / Why

<!-- One sentence each. Link the task sheet under docs/tasks/ if there is one. -->

## Branch model

The branch names are validated by `bash scripts/gitflow.sh --check <name>` and CI runs its
`--self-test` on every push. Pick the base that matches the source branch:

| Source | PR base |
|---|---|
| `feature/<slug>` | `develop` |
| `release/<x.y.z>` | `main` (then back-merge to `develop`) |
| `hotfix/<x.y.z>` | `main` (then back-merge to `develop`) |
| `arena/<agent>` | the base the repository owner chose — Arena agents cannot create branches |

- [ ] Source branch name is valid (`bash scripts/gitflow.sh --check <name>`)
- [ ] PR base matches the table above
- [ ] No `AGENTS.md` / `docs/roadmap/milestones.md` checkbox was edited

## Checks

- [ ] `./zigw quick-test`
- [ ] `python3 scripts/check-docs.py`
- [ ] `./zigw fmt --check src/ build.zig build.zig.zon`
- [ ] `bash scripts/gitflow.sh --self-test`
- [ ] 3 OS CI green
