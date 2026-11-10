# Writing the docs (rules a machine enforces)

> **Audience**: anyone adding or editing a documentation page.
> **Time**: 10 minutes once, then just the rule you tripped.

The rules below are cheap regex checks in [`../../scripts/check-docs.py`](../../scripts/check-docs.py),
run in CI on every push and locally by `./zigw docs-check`. They exist because prose drifts: a flag
gets renamed, a page is added in one language, an example stops compiling. Each rule is a guard
against one specific kind of drift.

## 1. Where to write (four layers)

| You want to say | Where |
|---|---|
| How to use it | `///`, `docs/learn/`, `docs/reference/` |
| Why it is shaped this way | `docs/decisions/` (add-only), `docs/architecture/` |
| Which milestone introduced it | `docs/tasks/M#-##-*.md` |
| Where to start reading | the learning hub and the index |

`src/docsite/`, `src/cli/`, `src/bundler/` and `src/build_tools/` are tools, not public API, so their
headers may carry internal breadcrumbs.

## 2. Page skeleton

```markdown
# Page title

> **Audience**: who this is for.
> **Time**: how long it takes. **Prerequisites**: what must work first.

One sentence saying what the page gives you.

## 1. First section
…
```

Rule 7 requires exactly one `# ` H1 (it becomes the sidebar label and `<title>`) and the
`> **Audience**` / `> **対象読者**` banner in the first 12 lines. Index pages and the implementation
autopsy are exempt.

### Joining or leaving the learning path

The five steps, their titles, minutes and order live in
[`../../src/docsite/learn_path.zig`](../../src/docsite/learn_path.zig). The rail at the top of every
path page, the landing page, the numbered sidebar headings and the `<!-- learn-path -->` list in the
hub all read that table — never copy the order by hand. A new page under `concepts/` is step 2
automatically; add it to `page_order` to give it a reading position.

## 3. Cross-references (xref)

Write `` `Engine` `` and the renderer links it to the API reference, glossary, error index or CLI
reference. Names come from the source, so a rename breaks the link and fails the build. Never invent
a name that is not declared.

## 4. Compile examples with `zig check`

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");
…
```

A `zig check` fence is a complete file compiled by `zig test --test-no-exec`;
`zig check-snippet` is a fragment wrapped in a function. Plain `zig` fences are illustrations and
are deliberately not compiled. `./zigw doctest` compiles them; a broken example turns CI red.

## 5. Notes (GitHub-compatible)

`> [!NOTE]`, `> [!TIP]`, `> [!WARNING]` render as admonitions on the site and as blockquotes on
GitHub. Keep the marker alone on its line.

## 6. Adding to the glossary

```markdown
### Capability

A declaration that "this window holds this permission"…
```

One sentence of definition, then the link to the page where the term first appears. Add the term to
**both** `docs/glossary.md` and `docs/glossary.en.md`; rule 6 checks for duplicate anchors.

## 7. Reference pages (CLI, config, errors)

Rule 4 compares the flags parsed by `src/cli/args.zig` with the flags documented in
`docs/reference/cli.md` **and** `docs/reference/cli.en.md`, in both directions. Rename a flag and
both references must change. The error index is generated from `error{…}` sets — never hand-edit it.

## 8. Do not show internal IDs to readers

Design numbers (`M4-03`) and ADR numbers belong in `docs/decisions/` and `docs/tasks/`, not in
published `///` comments or reader prose. Rule 3 fails on either.

Repository-only tools stay out of reader pages too: `zigw` is not in Releases, so an app author who
reads `./zigw build` stops at a missing file. Reader pages may name `zts` and ordinary `zig` only;
rule 10 scans `README.md`, `docs/INDEX.md`, `docs/learn/`, `docs/reference/` and example READMEs.

When you add a reader page, add **one row to each language's index**. Rule 11 checks coverage, not
order: the sidebar order is generated from `GroupKey` in `src/docsite/main.zig`.

**The left menu is the same list on every page and in both languages.** `GroupKey.order()` takes no
language; its first six groups are the learning hub plus the five numbered steps. Within a group the
order comes from `learn_path.page_order` (chapters) and `navRank()` (lookups, examples, repository).
Unlisted pages are not dropped — they sort last, alphabetically. Japanese-only pages stay in the
English menu with an English navigation label (`englishNavTitle`).

`learn_path.steps`' `minutes` drives the landing total, the per-page rail and the
`<!-- learn-path -->` list. README, the index and both learning hubs quote those numbers **by hand**,
so adding a tutorial means updating them. Rule 12 compares the Zig table with four prose totals,
two step tables, and checks that `GroupKey.order()` has not become language-dependent again.

**Tutorial branches are generated from one catalog.** The ten choices (nine committed framework
examples plus plain JavaScript) live in `src/docsite/frameworks.json` and nowhere else. A page with
`<!-- framework-picker -->` gets the bilingual chooser table; `src/docsite/assets/site.js` upgrades
that table to a `<select>` when JavaScript is on (with it off, the ten links still work).
`python3 scripts/gen-framework-tutorials.py` writes the nine per-library tutorials from the real
example sources — never copy framework code into prose by hand. Rule 15 verifies
catalog ↔ example directory ↔ both translations ↔ embedded snippet ↔ generated page freshness, so
editing an example without regenerating turns CI red. A branch is an **alternative route, not an
extra chapter**: `learn_path.steps` minutes do not change.

## 9. Write in two languages (English and Japanese)

Reader pages exist as **`docs/learn/ja/` + `docs/learn/en/` with identical file names**, and pages
that exist once (index, glossary, reference, contributing, examples, root README) use a
**`.en.md` mirror**: `docs/glossary.md` ↔ `docs/glossary.en.md`. The language switcher is a pure
path substitution — a missing file is a 404 the instant the switcher is pressed.

| Rule | Why |
|---|---|
| Identical file names / mirror suffix | the switcher needs no lookup table |
| H1 may be translated | the sidebar label and `<title>` are per language |
| `> **対象読者**` / `> **Audience**` in the first 12 lines | rule 7, same position in both |
| Code blocks may be identical | `zig check` validates one copy for both |
| Language-specific notes stay in their own page | translating them would lie |

Rule 8 checks the learning trees; rule 13 checks every other pair, that the English H1 is actually
English, and that the two halves are not byte-identical copies. Japanese → English is the easier
direction: writing English first tends to produce Japanese pages with untranslatable asides.

## 10. Record when it was rewritten and what was verified

Rule 13 reads the [sync ledger](doc-sync.en.md): for every bilingual pair it records the last
rewrite date, the ziggurats / Zig version verified, the commit, the checked commands, the implementation
files the page describes, and **sha256 hashes of both documents and of those implementation files**.
If an implementation file changes, the hash check fails and asks you to re-verify. If a document
changes, the hash check tells you to update its rewrite date. The two languages share one row, so
one cannot be silently left behind.

```bash
python3 scripts/check-docs.py             # check (fails on drift)
python3 scripts/check-docs.py --sync      # re-verify: refresh hashes, dates and the ledger view
```

**Internal documents (ADRs, design notes, task sheets, environment notes) are Japanese-only** — they
are the project's memory and the parallel-agent protocol, not a reader manual. They stay published
and reachable from both sidebars.

**The project's full name is `ziggurats`**, always lowercase. The legacy hyphenated name may remain
only in repository URLs and checkout paths, because the owner renames the repository later. Rule 14
scans reader-facing Markdown, the site's UI strings, `zts` help and generated templates, CI and
scripts, and fails on a leftover legacy name or a capitalised spelling.
**`zts`, `z_ts`, `zts_*` and `ZTS_*` are identifiers, not the project name** — they are untouched by
the rename. Test data in `src/`, library default window titles, and the visible text of the demos
are deliberately left alone too: that text is part of the three-OS pixel-parity gate, so it should
be regenerated together with the generator when the repository is renamed.

## 11. Generated output (do not create by hand)

`zig-out/docs/**`, `docs/api/**`, `docs/reference/errors.html`, `assets/search-index.js`,
`llms.txt`, `llms-full.txt`, `sitemap.xml` and `bindings.gen.ts` are all produced by the build.
`llms.txt` uses the same order as the sidebar, so it cannot disagree with the menu.

## 12. Common failures and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `broken relative link -> '../api/…/dialog.html'` | modules render at `<pkg>/<module>/mod.html` | link to `.../dialog/mod.html` or to the package index |
| `anchor(s) point at nothing` | a heading was renamed, or a member is not in the TOC | restore the heading or link to the declaration anchor |
| `flag '--x' is documented but does not exist` | prose written before code | add the flag or remove the row (both languages) |
| `internal reference 'M4-03' in a doc comment` | layers mixed | reasoning to `docs/decisions/`, usage to `///` |
| `duplicate glossary term` | one term defined twice | merge, then link from the other |
| `docs/learn/en/…: missing translation` | one language only | add the same path (rule 8) |
| `mentions 'zigw'` in a reader page | wrong toolchain | use `zts` / `zig` (rule 10); `zigw` only in `docs/contributing/` |
| `does not link 'learn/ja/…'` | page added, index row missing | add a row to both indexes (rule 11) |
| `does not say 'およそ 95 分'` / `step 3 says …` | minutes drifted after a tutorial was added | fix `learn_path.zig` and all four prose copies (rule 12) |
| `GroupKey.order() takes a language` | the menu was split again | one `order()` for both languages |
| `missing English counterpart` / `hash mismatch` | half a pair edited, or implementation changed | add the mirror and run `check-docs.py --sync` (rule 13) |
| `legacy project name … in prose` | the old name survived, or was capitalised | write `ziggurats` (lowercase); only URLs and checkout paths are exempt (rule 14) |
| `embedded excerpt is not verbatim` / `generated tutorial pages are stale` | an example changed but its branch was not regenerated | run `python3 scripts/gen-framework-tutorials.py` (rule 15) |
| `missing tutorial branch for 'react'` / `missing '<!-- framework-picker -->'` | a library or tutorial was added without its branch | regenerate, add one row to each index (rules 11, 15) |
| `doc-tests: 1 of 2 blocks failed` | example is stale | fix the example — or question the API change |

## Related

- [`doc-sync.en.md`](doc-sync.en.md) — the verification ledger and how to refresh it
- [`../tasks/M5-09-docs-ux.md`](../tasks/M5-09-docs-ux.md) — the improvement plan and success criteria
- [`../../src/docsite/learn_path.zig`](../../src/docsite/learn_path.zig) — the single source of path order
