# Documentation sync ledger

> **Audience**: anyone rewriting or reviewing a documentation page.
> **This file is generated.** Do not edit it; run `python3 scripts/check-docs.py --sync`.

One row per **Japanese/English pair** records when the page was last rewritten and which
version was verified consistent with the implementation. The source of truth is
[`scripts/doc-sync.json`](../../scripts/doc-sync.json); rule 13 of `check-docs.py` checks:

1. every reader page has a real English counterpart (its H1 is not Japanese, and it is not
   a byte-for-byte copy of the Japanese page);
2. the sha256 of both documents matches the ledger (**a rewrite without a new date** is caught);
3. the sha256 of the implementation files matches (**an implementation change without
   re-verification** is caught);
4. `zts_version` / `zig_version` match `build.zig.zon`;
5. `last_rewritten` is an ISO date no later than the verification date.

## Verified against

- **Verified version**: `ziggurats 0.1.0` / Zig `0.17.0`
- **Verified on**: `2026-10-21`
- **Base commit**: `2029866` (HEAD when verification began; the sha256 below identifies the implementation)
- **Verified with**: `python3 scripts/check-docs.py` · `./zigw docs-check` · `./zigw quick-test` · `./zigw test -Mroot=src/cli/mod.zig` · `./zigw fmt --check src/ build.zig build.zig.zon`
- **Implementation hash**: `1cd02c33badbfb19a495429be3f2e0329e01090ab5a2e75f79e6a8478a5b6154`

Implementation files compared: `build.zig`, `build.zig.zon`, `src/cli/args.zig`, `src/cli/main.zig`, `src/cli/template.zig`, `src/docsite/main.zig`, `src/docsite/learn_path.zig`, `src/docsite/i18n.zig`, `src/docsite/site.zig`, `scripts/check-docs.py`

## Per-page record

| Japanese | English | Last rewritten | Verified version |
|---|---|---|---|
| `README.md` | `README.en.md` | 2026-10-21 | 0.1.0 |
| `docs/INDEX.md` | `docs/INDEX.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/README.md` | `docs/contributing/README.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/doc-sync.md` | `docs/contributing/doc-sync.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/repository-map.md` | `docs/contributing/repository-map.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/troubleshooting.md` | `docs/contributing/troubleshooting.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/writing-docs.md` | `docs/contributing/writing-docs.en.md` | 2026-10-21 | 0.1.0 |
| `docs/glossary.md` | `docs/glossary.en.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/architecture.md` | `docs/learn/en/concepts/architecture.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/commands.md` | `docs/learn/en/concepts/commands.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/index.md` | `docs/learn/en/concepts/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/plugins.md` | `docs/learn/en/concepts/plugins.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/security.md` | `docs/learn/en/concepts/security.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/index.md` | `docs/learn/en/guides/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/install.md` | `docs/learn/en/guides/install.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/migrate-from-tauri.md` | `docs/learn/en/guides/migrate-from-tauri.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/package.md` | `docs/learn/en/guides/package.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/plugins.md` | `docs/learn/en/guides/plugins.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/rpc.md` | `docs/learn/en/guides/rpc.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/static-site.md` | `docs/learn/en/guides/static-site.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/troubleshooting.md` | `docs/learn/en/guides/troubleshooting.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/index.md` | `docs/learn/en/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/boundaries.md` | `docs/learn/en/patterns/boundaries.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/commands.md` | `docs/learn/en/patterns/commands.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/errors.md` | `docs/learn/en/patterns/errors.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/index.md` | `docs/learn/en/patterns/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/state.md` | `docs/learn/en/patterns/state.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/start.md` | `docs/learn/en/start.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter.md` | `docs/learn/en/tutorials/counter.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/index.md` | `docs/learn/en/tutorials/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/todo.md` | `docs/learn/en/tutorials/todo.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/ui.md` | `docs/learn/en/tutorials/ui.md` | 2026-10-21 | 0.1.0 |
| `docs/reference/cli.md` | `docs/reference/cli.en.md` | 2026-10-21 | 0.1.0 |
| `docs/reference/tauri-internals.md` | `docs/reference/tauri-internals.en.md` | 2026-10-21 | 0.1.0 |
| `docs/reference/tauri-usage.md` | `docs/reference/tauri-usage.en.md` | 2026-10-21 | 0.1.0 |
| `examples/c_embed/README.md` | `examples/c_embed/README.en.md` | 2026-10-21 | 0.1.0 |
| `examples/counter/README.md` | `examples/counter/README.en.md` | 2026-10-21 | 0.1.0 |
| `examples/frameworks/README.md` | `examples/frameworks/README.en.md` | 2026-10-21 | 0.1.0 |
| `examples/gallery/README.md` | `examples/gallery/README.en.md` | 2026-10-21 | 0.1.0 |

## How to refresh

```bash
# after changing the implementation or a doc, re-verify and refresh the ledger
python3 scripts/check-docs.py --sync
python3 scripts/check-docs.py --sync --date 2026-10-21   # explicit date
python3 scripts/check-docs.py                             # check only (what CI runs)
```

`--sync` updates `last_rewritten` only for pages whose content changed, and keeps the date of
untouched pages. Internal documents (ADRs, design notes, task sheets) are Japanese-only and
are deliberately outside the ledger.

## Related

- [Writing the docs](writing-docs.en.md) — rule 13 and the bilingual conventions
- [Repository map](repository-map.en.md) — where files live
- [Documentation index](../INDEX.en.md) — the site's order
