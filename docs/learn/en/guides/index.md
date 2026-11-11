# Guides — look up what you want to do

> **Audience**: readers with one specific job (with a working `zts`).
> **Time**: read exactly one page (5–10 minutes each).

Guides are **task-first**. You do not have to read the concepts in order. If you have not run
anything yet, do [Your first ten minutes](../start.md) first — this page is an index for people who
already have something working.

## By what you want to do

| Job | Page | Minutes |
|---|---|---|
| get `zts` on this machine | [Install](install.md) | 5 |
| add it to an existing Zig project | [Use it as a library](library.md) | 5 |
| call a Zig function from a button | [Commands (RPC)](rpc.md) | 10 |
| use windows, files, menus | [Plugins](plugins.md) | 8 |
| ship a site with no server | [Static sites](static-site.md) | 8 |
| produce `.deb` / `.dmg` / `.exe` | [Packaging](package.md) | 10 |
| move a Tauri v2 project over | [Migrating from Tauri](migrate-from-tauri.md) | 10 |
| nothing works / an error appeared | [Troubleshooting](troubleshooting.md) | — |

## How to read a guide

The first twelve lines of every guide state the **audience, time and prerequisites**. If they are
not you, move on — none of these pages is required reading.

- Blocks tagged `zig check` are **compiled by CI**. Writing a stale API turns CI red, so the code
  here builds against today's version.
- `> [!WARNING]` marks either data loss or a setting that fails silently. Do not skip those.
- Lost in terminology? [Glossary](../../../glossary.md). Searching by name?
  [API index](../../../api/index.html).

## If you want the internal notes

Design rationale (why the layout is what it is, which milestone introduced what) lives in
`docs/architecture/`, `docs/decisions/` and `docs/tasks/`. **App authors never need them** — the
published site folds them into a single "internals" entry.

## Next

- The bigger picture → [Concepts](../concepts/index.md)
- Terminology → [Glossary](../../../glossary.md)
- Working on the repository (builds, CI, tests) →
  [`docs/contributing/README.md`](../../../contributing/README.md)
