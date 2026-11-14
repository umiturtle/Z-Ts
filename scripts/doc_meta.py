"""Source/version metadata carried by every published Markdown page.

Each site Markdown file ends with exactly one line:

    <!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->

* ``source-version``  — the ``build.zig.zon`` version this page describes (rule 20).
* ``verified``        — the day the sync ledger last confirmed docs against that implementation.
* ``last-rewritten``  — the day this page's *body* last changed (``scripts/doc-sync.json`` for
                        reader pairs, git's last-commit date for internal notes).

The commit SHA lives once in ``scripts/doc-sync.json`` (``verified.commit``), not in every page:
copying it into 220 files would make a no-op ``--sync`` rewrite all of them. A checker can still
resolve ``source-version`` + ``verified`` back to that SHA, which is what rule 23 does.

A trailing HTML comment is deliberate: rule 7 requires the audience banner in the first twelve
lines, and the docsite renders unknown comments as nothing. Front matter would move the H1.

This module is the single source of the format. ``check-docs.py`` (rule 23 + ``--sync``) and
``gen-framework-tutorials.py`` (rule 15 verbatim comparison) both call it.
"""

from __future__ import annotations

import glob
import hashlib
import os
import re

META_PREFIX = "<!-- zts-doc-meta:"
META_PATTERN = re.compile(r"(?:\n)*" + re.escape(META_PREFIX) + r"\s*([^>]*)-->\s*\Z")


def meta_line(source_version: str, verified: str, last_rewritten: str) -> str:
    """The exact one-line comment. Values are restricted to `[A-Za-z0-9._-]` by the callers."""
    return (
        f"{META_PREFIX} source-version={source_version} "
        f"verified={verified} last-rewritten={last_rewritten} -->"
    )


def split_meta(text: str) -> tuple[str, dict[str, str] | None]:
    """Return ``(body_without_meta, fields)``. ``body`` always ends in exactly one newline."""
    stripped = text.rstrip()
    match = META_PATTERN.search(stripped)
    if match is None:
        return (stripped + "\n") if stripped else "", None
    body = stripped[: match.start()].rstrip("\n")
    fields: dict[str, str] = {}
    for token in match.group(1).split():
        if "=" in token:
            key, value = token.split("=", 1)
            fields[key] = value
    return (body + "\n") if body else "", fields


def with_meta(text: str, source_version: str, verified: str, last_rewritten: str) -> str:
    """Strip any old meta, then append the current one on its own line."""
    body, _ = split_meta(text)
    return body.rstrip("\n") + "\n\n" + meta_line(source_version, verified, last_rewritten) + "\n"


def body_hash(path: str) -> str:
    """sha256 of the body *excluding* the meta line — used to decide `last_rewritten`."""
    with open(path, "rb") as handle:
        text = handle.read().decode("utf-8")
    body, _ = split_meta(text)
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def site_md_files() -> list[str]:
    """Every Markdown file the docsite publishes (rule 23 scans exactly this set)."""
    paths = ["AGENTS.md", "README.md", "README.en.md"]
    paths += glob.glob("docs/**/*.md", recursive=True)
    paths += glob.glob("examples/*/README*.md")
    paths += glob.glob("bench/*.md")
    return sorted({p.replace(os.sep, "/") for p in paths if os.path.isfile(p)})
