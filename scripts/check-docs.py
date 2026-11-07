#!/usr/bin/env python3
"""Mechanical lint for the Z-Ts documentation set.

The point of this file is **drift**: every rule below exists because a human edit could
otherwise leave the prose describing a library that no longer exists. The rules are all
cheap (regexes over checked-in text), so they run in CI on every push and locally in
`./zigw docs-check`.

1. Layout           — forbidden monolithic files, required hub files, task-sheet headers.
2. Links            — relative Markdown links must resolve (generated pages understood).
3. Layers           — `///` and `//!` in the *published* trees must not leak milestone IDs or
                      ADR numbers. Rationale lives in `docs/decisions/`, usage lives in `///`;
                      seeing `M4-03` in the API reference is the tell that the two got mixed.
4. CLI              — the flags parsed by `src/cli/args.zig` and the flags documented in
                      `docs/reference/cli.md` must be the same set. Renaming a flag without
                      touching the reference is the classic silent break.
5. Packages         — every `zts_*` mentioned in the docs must be a real module.
6. Glossary         — every `### Term` is unique (it is used as a link anchor).
7. Structure        — every reader-facing page has exactly one H1 (it becomes the sidebar label
                      and `<title>`), and guides carry the `> **対象読者**` / `> **Audience**`
                      banner that tells the reader whether the page is for them.
8. Parity           — `docs/learn/ja/` and `docs/learn/en/` hold the same file names. A page
                      added to one language and forgotten in the other is how a bilingual site
                      rots; the switcher would send the reader to a 404.

Run: `python3 scripts/check-docs.py` (or `./zigw docs-check`).
"""

import glob
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO_ROOT)

errors: list[str] = []
warnings: list[str] = []

# ---------------------------------------------------------------------------
# 1. Layout
# ---------------------------------------------------------------------------

FORBIDDEN_FILES = ["memory.md", "MEMORY.md", "PROGRESS.md", "TODO.md"]
for f in FORBIDDEN_FILES:
    if os.path.exists(f):
        errors.append(
            f"Forbidden monolithic file '{f}' exists. "
            "Use sharded files under 'docs/tasks/<ID>-<slug>.md' instead to prevent parallel merge conflicts."
        )

REQUIRED_DOCS = [
    "AGENTS.md",
    "docs/INDEX.md",
    "docs/glossary.md",
    "docs/architecture/00-overview.md",
    "docs/roadmap/milestones.md",
    "docs/tasks/TEMPLATE.md",
    "docs/environment/arena-and-caching.md",
    "docs/environment/github-actions.md",
]
for req in REQUIRED_DOCS:
    if not os.path.isfile(req):
        errors.append(f"Missing required documentation file: '{req}'")

REQUIRED_TASK_KEYS = ["Status", "Branch", "Scope", "Next Step"]
for path in sorted(glob.glob("docs/tasks/*.md")):
    if os.path.basename(path) == "TEMPLATE.md":
        continue
    content = open(path, encoding="utf-8").read()
    for key in REQUIRED_TASK_KEYS:
        if not re.search(rf"^- \*\*{re.escape(key)}\*\*:\s*.+$", content, re.M):
            errors.append(f"{path}: missing required header field '- **{key}**: ...'")

# ---------------------------------------------------------------------------
# 2. Links
# ---------------------------------------------------------------------------

# Pages the generator writes that have no `.md` source. They may be linked from Markdown even
# though `os.path.exists` is false before `zig build docs` has run.
GENERATED_PAGES = {
    "docs/index.html",
    "docs/internals/index.html",
    "docs/api/index.html",
    "docs/reference/errors.html",
}
GENERATED_PREFIXES = ("docs/api/",)


def is_generated(resolved: str) -> bool:
    if resolved in GENERATED_PAGES:
        return True
    return any(resolved.startswith(p) for p in GENERATED_PREFIXES)


def strip_fences(text: str) -> str:
    """Drop fenced code blocks, tracking fence lines only at line starts.

    A regex over the whole file mis-pairs when a fence appears mid-prose (`` ` ```zig ` ``
    inside a table cell, for example), which used to hide real links from the checker.
    """
    out: list[str] = []
    in_fence = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append(line)
    return "\n".join(out)


link_pat = re.compile(r"\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)")
md_files = ["AGENTS.md"] + glob.glob("docs/**/*.md", recursive=True)
md_files = sorted(f for f in md_files if os.path.isfile(f))

for md in md_files:
    base_dir = os.path.dirname(md)
    text = open(md, encoding="utf-8").read()
    stripped = strip_fences(text)
    for m in link_pat.finditer(stripped):
        target = m.group(1).strip()
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        resolved = os.path.normpath(os.path.join(base_dir, target))
        if os.path.exists(resolved) or is_generated(resolved):
            continue
        errors.append(f"{md}: broken relative link -> '{target}' (resolved: '{resolved}')")

# ---------------------------------------------------------------------------
# 3. Layers: no milestone IDs / ADR numbers in public doc comments
# ---------------------------------------------------------------------------

# Only the trees that are published under `docs/api/**` (`apidoc.packages`). The docs site, the
# CLI, the packager and the build helpers are tools for this repository; their module headers are
# read by maintainers, not by library users, so a milestone ID there is a legitimate breadcrumb.
PUBLISHED_TREES = (
    "src/core/",
    "src/rpc/",
    "src/tauri/",
    "src/ssg/",
    "src/wasm/",
    "src/bridge/",
    "src/webview/",
    "src/root.zig",
)
LAYER_PAT = re.compile(r"\b(?:ADR-\d{4}|M\d-\d{2})\b")
for path in sorted(glob.glob("src/**/*.zig", recursive=True)):
    if not path.startswith(PUBLISHED_TREES):
        continue
    for lineno, line in enumerate(open(path, encoding="utf-8"), 1):
        stripped = line.lstrip()
        if not (stripped.startswith("///") or stripped.startswith("//!")):
            continue
        m = LAYER_PAT.search(line)
        if m:
            errors.append(
                f"{path}:{lineno}: internal reference '{m.group(0)}' in a doc comment "
                "(put the rationale in docs/decisions/, the usage in ///)"
            )

# The same rule for reader-facing prose. A milestone ID in `docs/guides/` is the same leak as one
# in `///`: the reader has no way to look it up and it will be wrong in six months.
# `docs/INDEX.md` is the repository map: task and ADR identifiers *are* its subject.
READER_MD = [
    "README.md",
    "docs/glossary.md",
] + sorted(glob.glob("docs/learn/**/*.md", recursive=True)) + sorted(glob.glob("docs/reference/**/*.md", recursive=True))
for md in READER_MD:
    if not os.path.isfile(md):
        continue
    for lineno, line in enumerate(open(md, encoding="utf-8"), 1):
        m = LAYER_PAT.search(line)
        if m:
            errors.append(f"{md}:{lineno}: internal reference '{m.group(0)}' in a reader-facing page")

# ---------------------------------------------------------------------------
# 4. CLI reference vs. the argument parser
# ---------------------------------------------------------------------------

args_src = open("src/cli/args.zig", encoding="utf-8").read() if os.path.isfile("src/cli/args.zig") else ""
# Flags are parsed from the implementation, minus the strings that only exist to be *rejected*:
# `expectError(error.UnknownFlag, parse(&.{ "doctor", "--fix" }))` is a negative test fixture, not
# a flag a user can pass, so documenting it would be wrong.
code_flags: set[str] = set()
for line in args_src.splitlines():
    if "expectError" in line:
        continue
    code_flags.update(re.findall(r'"(--[a-z][a-z0-9-]+)"', line))
code_flags.discard("--nope")

cli_ref_path = "docs/reference/cli.md"
if os.path.isfile(cli_ref_path):
    cli_ref = open(cli_ref_path, encoding="utf-8").read()
    doc_flags = set(re.findall(r"(?<![\w-])(--[a-z][a-z0-9-]+)", cli_ref))
    for flag in sorted(code_flags - doc_flags):
        errors.append(f"{cli_ref_path}: flag '{flag}' exists in src/cli/args.zig but is not documented")
    for flag in sorted(doc_flags - code_flags):
        errors.append(f"{cli_ref_path}: flag '{flag}' is documented but does not exist in src/cli/args.zig")

    # Subcommands: the parser matches on bare words, the reference uses `## `zts <cmd>``.
    commands = set(re.findall(r'std\.mem\.eql\(u8, head(?:\[\d\])?, "([a-z]+)"\)', args_src))
    doc_commands = set(re.findall(r"^## `zts ([a-z]+)", cli_ref, re.M))
    for cmd in sorted(doc_commands - commands - {"help", "version"}):
        errors.append(f"{cli_ref_path}: subcommand 'zts {cmd}' is documented but not parsed by src/cli/args.zig")

# ---------------------------------------------------------------------------
# 5. Package names mentioned in the docs must be real modules
# ---------------------------------------------------------------------------

# The package names a reader can type: the ten `apidoc.packages` roots plus the two build-time
# modules a generated `build.zig` imports. Only `@import("zts_…")` occurrences are checked:
# scanning every `zts_*` token would also flag the C ABI (`zts_wasm_invoke`), which is a function,
# not a package.
KNOWN_PACKAGES = {
    "zts_foundation", "zts_web", "zts_core", "zts_rpc", "zts_bridge",
    "zts_webview", "zts_tauri", "zts_wasm", "zts_ssg", "z_ts",
    "zts_build", "zts_cli",
}
import_pat = re.compile(r'@import\("(zts_[a-z][a-z0-9_]*|z_ts)"\)')
scan_files = ["README.md", "docs/glossary.md"] + sorted(glob.glob("docs/learn/**/*.md", recursive=True))
scan_files += sorted(glob.glob("docs/reference/**/*.md", recursive=True))
scan_files += sorted(glob.glob("examples/**/*.zig", recursive=True))
for md in scan_files:
    if not os.path.isfile(md):
        continue
    for m in import_pat.finditer(open(md, encoding="utf-8").read()):
        name = m.group(1)
        if name not in KNOWN_PACKAGES:
            errors.append(f"{md}: '@import(\"{name}\")' does not name a package the library ships")

# ---------------------------------------------------------------------------
# 6. Glossary anchors must be unique
# ---------------------------------------------------------------------------

glossary_path = "docs/glossary.md"
if os.path.isfile(glossary_path):
    seen: dict[str, int] = {}
    for lineno, line in enumerate(open(glossary_path, encoding="utf-8"), 1):
        m = re.match(r"^### (.+)$", line.rstrip("\n"))
        if not m:
            continue
        term = m.group(1).strip()
        if term in seen:
            errors.append(f"{glossary_path}:{lineno}: duplicate glossary term '{term}' (first at line {seen[term]})")
        seen[term] = lineno

# ---------------------------------------------------------------------------
# 7. Page structure: one H1 per page, and a reader banner on guides
# ---------------------------------------------------------------------------

# The renderer takes the first `# ` heading as the page title (sidebar label, `<title>`, search
# entry). A second H1 silently becomes a section that looks like a page, so it is rejected here.
# Fenced code is stripped first: `# comment` inside a shell block is not a heading.
READER_PAGES = sorted(glob.glob("docs/learn/**/*.md", recursive=True)) + sorted(
    glob.glob("docs/reference/**/*.md", recursive=True)
)
for md in ["README.md"] + READER_PAGES + ["docs/glossary.md", "docs/contributing/writing-docs.md"]:
    if not os.path.isfile(md):
        continue
    body = strip_fences(open(md, encoding="utf-8").read())
    h1 = [line for line in body.splitlines() if line.startswith("# ")]
    if len(h1) != 1:
        errors.append(f"{md}: expected exactly one '# ' heading, found {len(h1)}")
    # Guides are read by choice: the first lines must tell the reader whether to read on. The
    # README files are indexes (their list of pages *is* the banner) and `tauri-internals.md` is
    # an autopsy filed under `reference/`, so both are exempt.
    needs_banner = md.startswith(("docs/learn/", "docs/reference/"))
    if needs_banner and not md.endswith(("README.md", "index.md")) and md != "docs/reference/tauri-internals.md":
        head = "\n".join(body.splitlines()[:12])
        # Japanese pages carry `> **対象読者**`, English ones `> **Audience**`. Both say the same
        # thing, so both satisfy the rule; a page with neither is a page nobody can triage.
        if "対象読者" not in head and "Audience" not in head:
            errors.append(f"{md}: missing the '> **対象読者**: …' / '> **Audience**: …' banner in the first 12 lines")

# ---------------------------------------------------------------------------
# 8. Translation parity between docs/learn/ja and docs/learn/en
# ---------------------------------------------------------------------------

# The language switcher rewrites the `ja`/`en` segment of the path, so a file that exists in one
# tree and not the other produces a 404 the moment the reader clicks "English". Names are the
# contract; translated *titles* inside the files are free.
LEARN_ROOT = "docs/learn"
parity_errors = 0
ja_files = {
    os.path.relpath(p, os.path.join(LEARN_ROOT, "ja"))
    for p in glob.glob(os.path.join(LEARN_ROOT, "ja", "**", "*.md"), recursive=True)
}
en_files = {
    os.path.relpath(p, os.path.join(LEARN_ROOT, "en"))
    for p in glob.glob(os.path.join(LEARN_ROOT, "en", "**", "*.md"), recursive=True)
}
for missing in sorted(ja_files - en_files):
    errors.append(f"{LEARN_ROOT}/en/{missing}: missing translation (exists in ja)")
    parity_errors += 1
for missing in sorted(en_files - ja_files):
    errors.append(f"{LEARN_ROOT}/ja/{missing}: missing translation (exists in en)")
    parity_errors += 1

if warnings:
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)

if errors:
    print("Documentation structure check FAILED:", file=sys.stderr)
    for err in errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

print(
    f"Documentation check OK ({len(md_files)} markdown files verified, "
    f"{len(ja_files)} reader pages in each of 2 languages)."
)
