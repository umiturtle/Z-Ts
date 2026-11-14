#!/usr/bin/env python3
"""Mechanical lint for the ziggurats documentation set.

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
9. Tool wrapper      — every `./zigw <verb>` in the docs must be a verb `zigw` actually
                      implements, or a real `zig` subcommand it forwards. The wrapper is the
                      easiest thing in the repository to document from memory, and "run
                      `./zigw quick-tests`" reads plausibly right up until someone types it.
10. Reader toolchain — reader-facing docs (README, `docs/INDEX.md`, `docs/learn/`,
                      `docs/reference/`, example READMEs) must not mention `zigw` at all. It is
                      a bootstrap for *this* checkout, not a distributed artifact, so an app
                      author cannot run it. The toolchain those pages may name is `zts` + `zig`.
11. Index coverage   — every page a reader can reach must be linked from its language's index
                      (`docs/INDEX.md` / `docs/INDEX.en.md`). The index is a hand-written mirror of
                      the sidebar; a page added without a row is a page only the sidebar knows
                      about. The rule checks coverage, not order: the order lives in main.zig.
12. Path budget      — the minutes quoted in README, the index and both learning hubs come from
                      `learn_path.zig`, and the sidebar's first six groups are the five numbered
                      steps. A third tutorial that leaves the rail at "15 min" is a lie; a
                      language-dependent `GroupKey.order()` is the menu changing as you navigate.
17. Native state     — the OS→`WindowRegistry` event path, the `core.Host.applyWindowExtras`
                      contract and the `createWindow` option application must exist on all four
                      backends (GTK / Cocoa / Win32 / HeadlessMock) with the SAME enum ordinals.
                      A backend that only records state locally is how `isMaximized()` silently
                      diverges between Linux, macOS and Windows.
13. Sync ledger      — `scripts/doc-sync.json` records, for every bilingual pair, when the page was
                      last rewritten, which ziggurats / Zig version and commit were verified consistent,
                      which checks were run, and sha256 of both documents and of the implementation
                      sources. A hash mismatch means something changed after verification. It also
                      enforces a real English counterpart for every reader page. Refresh with
                      `python3 scripts/check-docs.py --sync`.
14. Project name     — the full name is `ziggurats`, always lowercase. The legacy hyphenated name
                      may remain only inside repository URLs / checkout paths (the owner renames
                      the repository later) and in source test data / demo fixtures. Reader prose,
                      the site UI, CLI help, generated project templates, workflows and scripts
                      must say `ziggurats`. `zts` / `z_ts` / `zts_*` / `ZTS_*` are identifiers and
                      are deliberately not part of this rename.
15. Tutorial branches — `src/docsite/frameworks.json` is the single list of libraries with a
                      committed example. Each needs a Japanese and an English tutorial, the
                      `<!-- framework-picker -->` directive, and an embedded code excerpt that
                      is verbatim from the real example source. A tenth (plain-JS) branch is the
                      original counter tutorial. Adding a library without updating the docs (or
                      editing an example without regenerating the tutorial) turns this red.
16. Zig-only demos   — the nine examples, the generator, the gallery host and the published
                      output must all agree on the `.zigbar` panel. A static-only demo shows
                      `ZIG OFFLINE`; the native gallery answers `zig_probe` / `zig_inc` /
                      `zig_dec` over `ipc://` with a seal only Zig can make. If any one of the
                      four surfaces drifts, the demos silently become "just HTML" again.
18. Rename-safe CI   — Check Run log publishers resolve the repository's current `full_name`
                      with a GET before PATCH, are `continue-on-error`, and mirror to the Step
                      Summary. A `context.repo` frozen by a mid-run repository rename turns
                      `checks.update` into HTTP 500; that diagnostic must never fail the build.
19. Pages URL        — the published site's absolute URLs (`site_url`, sitemap, llms.txt,
                      framework demos, generated tutorials, README/index links) must use the
                      *current* repository name. The old `/Z-Ts/` Pages path 404s after a rename;
                      `github.com` links and checkout paths stay as rule 14 prescribes.
20. Version          — `build.zig.zon` is the single source of the release version. The CLI's
                      `SemanticVersion`, release URLs, archive names and the sync ledger must all
                      say the same `vX.Y.Z`. A stale `v0.1.0` in an install command ships a 404.
21. Branch model     — CI must accept `main` / `develop` / `feature/**` / `release/**` /
                      `hotfix/**` / `arena/**`, the naming validator must run in CI, and both
                      language guides plus the PR template must name the same bases. Agents never
                      create branches, so the validator must not either.
22. Tutorial grid    — all three tutorials (counter / todo / ui) need a branch for all nine
                      catalog libraries in both languages. Every branch must name the library's
                      state primitive and cover the Zig linkage (seal, two states, `ipc://`,
                      ONLINE/OFFLINE), and both hubs plus each original must link the whole grid.
23. Page provenance  — every published Markdown page ends with one `zts-doc-meta` comment naming
                      the source version, the verification day and its own last rewrite. Match the
                      zon version and the sync ledger so a stale page can be detected mechanically.

Run: `python3 scripts/check-docs.py` (or `./zigw docs-check`).
"""

import datetime
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

import doc_meta

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
md_files = ["AGENTS.md", "README.md", "README.en.md"] + glob.glob("docs/**/*.md", recursive=True)
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

# Both language versions are real references: a flag renamed in the parser must disappear from
# `cli.md` AND `cli.en.md`, otherwise the English reader is taught a flag that no longer exists.
commands = set(re.findall(r'std\.mem\.eql\(u8, head(?:\[\d\])?, "([a-z]+)"\)', args_src))
for cli_ref_path in ("docs/reference/cli.md", "docs/reference/cli.en.md"):
    if not os.path.isfile(cli_ref_path):
        continue
    cli_ref = open(cli_ref_path, encoding="utf-8").read()
    doc_flags = set(re.findall(r"(?<![\w-])(--[a-z][a-z0-9-]+)", cli_ref))
    for flag in sorted(code_flags - doc_flags):
        errors.append(f"{cli_ref_path}: flag '{flag}' exists in src/cli/args.zig but is not documented")
    for flag in sorted(doc_flags - code_flags):
        errors.append(f"{cli_ref_path}: flag '{flag}' is documented but does not exist in src/cli/args.zig")

    # Subcommands: the parser matches on bare words, the reference uses `## `zts <cmd>``.
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

# ---------------------------------------------------------------------------
# 9. `./zigw` invocations in the docs must be real
# ---------------------------------------------------------------------------

# Keep the two sets in sync with `zigw` itself: the `if [[ ... == ... ]]` branches near the top
# and the fall-through `exec "$ZIG_BIN" "$@"`.
ZIGW_SUBCOMMANDS = {
    "zig-path",   # prints the Zig this checkout uses
    "quick-test", # direct `zig test` over the module graph
    "docs-check", # renderer tests + the python gates + `zig build docs`
    "doctest",    # only the ```zig check fences
    "full-test",  # `zig build test`
}
ZIG_SUBCOMMANDS = {
    "build", "build-exe", "build-lib", "build-obj", "test", "fmt", "version", "cc", "c++",
    "ar", "run", "fetch", "env", "ast-check", "reduce", "objcopy", "rc", "dlltool", "lib",
    "translate-c", "std", "init", "targets", "help", "zen",
}
zigw_ref = open("zigw", encoding="utf-8").read() if os.path.exists("zigw") else ""
if not zigw_ref:
    errors.append("zigw: the wrapper is missing but the docs tell readers to run it")
else:
    for name in sorted(ZIGW_SUBCOMMANDS):
        if f'== "{name}"' not in zigw_ref:
            errors.append(f"scripts/check-docs.py: '{name}' is listed as a zigw subcommand but zigw does not implement it")

zigw_uses: set[str] = set()
for md in md_files:
    text = open(md, encoding="utf-8").read()
    for match in re.finditer(r"(?<![\w./-])\./zigw\s+([a-z][a-z0-9+-]*)", text):
        zigw_uses.add(match.group(1))
for verb in sorted(zigw_uses - ZIGW_SUBCOMMANDS - ZIG_SUBCOMMANDS):
    errors.append(f"docs: './zigw {verb}' is not something zigw (or the zig it forwards to) accepts")

# ---------------------------------------------------------------------------
# 10. Reader-facing docs must not name the repository's bootstrap wrapper
# ---------------------------------------------------------------------------

# `zigw` downloads Zig into /tmp and then runs `zig build` in this checkout. It is not in
# Releases, so an app author who follows a page that says `./zigw build` hits a missing file
# before they have a project. The toolchain those pages may use is `zts` plus a normal `zig`;
# what `zigw` does is still documented where repository contributors read it
# (docs/contributing/README.md), and this rule keeps the two audiences from bleeding.
READER_DOCS = ["README.md", "README.en.md", "docs/INDEX.md", "docs/learn", "docs/reference"]
reader_files = [
    md for md in md_files
    if any(md == root or md.startswith(root + "/") for root in READER_DOCS)
]
reader_files += sorted(glob.glob("examples/*/README.md")) + sorted(glob.glob("examples/*/*/README.md"))
for md in sorted(set(reader_files)):
    if not os.path.isfile(md):
        continue
    text = open(md, encoding="utf-8").read()
    if re.search(r"\bzigw\b", text):
        errors.append(
            f"{md}: mentions `zigw`; reader-facing pages must only use `zts` and `zig` "
            f"(`zigw` is a checkout bootstrap, not a distributed artifact)"
        )

# ---------------------------------------------------------------------------
# 11. Each language's index links every page a reader can reach
# ---------------------------------------------------------------------------

# The index mirrors the sidebar by hand. Coverage is the part a human forgets: adding a page and
# not adding a row leaves it discoverable only through navigation. Order is not checked here — it
# is generated from `GroupKey` in main.zig.
def reader_pairs():
    """(Japanese page, English page) for every page a reader can reach."""
    pairs = []
    for ja in sorted(glob.glob("docs/learn/ja/**/*.md", recursive=True)):
        en = os.path.join("docs/learn/en", os.path.relpath(ja, "docs/learn/ja"))
        pairs.append((ja, en))
    # Pages that exist once use a `.en.md` mirror next to the original.
    fixed = ["README.md", "docs/INDEX.md", "docs/glossary.md"]
    fixed += sorted(p for p in glob.glob("docs/reference/*.md") if not p.endswith(".en.md"))
    fixed += sorted(p for p in glob.glob("docs/contributing/*.md") if not p.endswith(".en.md"))
    fixed += sorted(p for p in glob.glob("examples/*/README.md") if not p.endswith(".en.md"))
    for ja in fixed:
        pairs.append((ja, ja[: -len(".md")] + ".en.md"))
    return sorted(pairs)


def mirror_of(path):
    if path.startswith("docs/learn/ja/"):
        return os.path.join("docs/learn/en", os.path.relpath(path, "docs/learn/ja"))
    return path[: -len(".md")] + ".en.md"


def index_targets(en):
    """Paths that the given language's index must mention, relative to `docs/`."""
    out = []
    for p in sorted(glob.glob("docs/learn/en/**/*.md" if en else "docs/learn/ja/**/*.md", recursive=True)):
        rel = os.path.relpath(p, "docs").replace(os.sep, "/")
        # The 3 x 9 framework branches are covered by tutorials/index.md + frameworks.md
        # (rule 22 verifies the whole grid). Repeating 27 rows here would bury the index.
        if re.match(r"^learn/(ja|en)/tutorials/(counter|todo|ui)-[a-z0-9]+\.md$", rel):
            continue
        out.append(rel)
    for p in ["docs/glossary.md"] + sorted(glob.glob("docs/reference/*.md")) + sorted(
        glob.glob("docs/contributing/*.md")
    ) + sorted(glob.glob("examples/*/README.md")):
        # A `.en.md` mirror is checked against the English index, the original against the
        # Japanese one. `doc-sync.*` is a generated ledger; both indexes link their own half.
        if p.endswith(".en.md") != en:
            continue
        out.append(os.path.relpath(p, "docs"))
    return out


for index, en in (("docs/INDEX.md", False), ("docs/INDEX.en.md", True)):
    text = open(index, encoding="utf-8").read() if os.path.isfile(index) else ""
    if not text:
        errors.append(f"{index}: missing (the site's footer links it on every page)")
        continue
    for rel in index_targets(en):
        if rel not in text:
            errors.append(
                f"{index}: does not link '{rel}' (add a row under the group it belongs to)"
            )

# 12. The learning path's budget and the sidebar's shape are one truth
# ---------------------------------------------------------------------------

# `learn_path.steps` drives the rail on every page and the total on the landing page. README,
# `docs/INDEX.md` and the two learning hubs quote those numbers by hand, so adding a tutorial
# without editing them leaves the site claiming a 60-minute path that now takes 95 minutes.
LEARN_PATH_ZIG = "src/docsite/learn_path.zig"
MAIN_ZIG = "src/docsite/main.zig"
if not os.path.isfile(LEARN_PATH_ZIG):
    errors.append(f"{LEARN_PATH_ZIG}: missing (the learning path has no single source of truth)")
else:
    lp = open(LEARN_PATH_ZIG, encoding="utf-8").read()
    step_minutes = [int(n) for n in re.findall(r"^\s*\.minutes = (\d+),", lp, re.M)]
    if len(step_minutes) != 5:
        errors.append(f"{LEARN_PATH_ZIG}: expected 5 steps with a `.minutes` field, found {len(step_minutes)}")
    else:
        total = sum(step_minutes)
        for path, phrase in (
            ("docs/INDEX.md", f"およそ {total} 分"),
            ("README.md", f"およそ {total} 分"),
            ("docs/INDEX.en.md", f"about {total} minutes"),
            ("README.en.md", f"about {total} minutes"),
            ("docs/learn/ja/index.md", f"{total} 分"),
            ("docs/learn/en/index.md", f"{total} minutes"),
        ):
            text = open(path, encoding="utf-8").read() if os.path.isfile(path) else ""
            if phrase not in text:
                errors.append(
                    f"{path}: does not say '{phrase}' (the total comes from {LEARN_PATH_ZIG}; rule 12)"
                )
        # Both step tables are hand-written too: compare their minute column row by row.
        for path in ("docs/INDEX.md", "docs/INDEX.en.md", "README.md", "README.en.md"):
            text = open(path, encoding="utf-8").read() if os.path.isfile(path) else ""
            rows = {
                int(num): (0 if mins == "—" else int(mins))
                for num, mins in re.findall(r"^\|\s*(\d)\s*\|[^|]*\|\s*(\d+|—)\s*\|", text, re.M)
            }
            for i, minutes in enumerate(step_minutes, 1):
                if rows.get(i) != minutes:
                    errors.append(
                        f"{path}: step {i} says {rows.get(i, 'nothing')} minutes but "
                        f"{LEARN_PATH_ZIG} says {minutes} (rule 12)"
                    )

    main = open(MAIN_ZIG, encoding="utf-8").read() if os.path.isfile(MAIN_ZIG) else ""
    if re.search(r"fn order\(lang: i18n\.Lang\)", main):
        errors.append(
            f"{MAIN_ZIG}: GroupKey.order() takes a language — the left menu must be the same list "
            f"on every page and in both languages (rule 12)"
        )
    order = re.search(r"fn order\(\) \[\]const GroupKey \{\s*return &\.\{(.*?)\};", main, re.S)
    keys = re.findall(r"\.([a-z_]+)", order.group(1)) if order else []
    if keys[:6] != ["learn", "start", "concepts", "tutorials", "patterns", "guides"]:
        errors.append(
            f"{MAIN_ZIG}: the sidebar must open with the learning hub and the five numbered steps "
            f"(got {keys[:6]}; rule 12)"
        )

# ---------------------------------------------------------------------------
# 13. Sync ledger: when a page was last rewritten, and what was verified
# ---------------------------------------------------------------------------

SYNC_JSON = "scripts/doc-sync.json"
LEDGER_JA = "docs/contributing/doc-sync.md"
LEDGER_EN = "docs/contributing/doc-sync.en.md"

SYNC_CHECKS = [
    "python3 scripts/check-docs.py",
    "python3 scripts/gen-framework-tutorials.py --check",
    "./zigw docs-check",
    "./zigw quick-test",
    "./zigw test -Mroot=src/cli/mod.zig",
    "./zigw fmt --check src/ build.zig build.zig.zon",
]

# The implementation surface the documentation makes claims about. One shared hash is enough: any
# change to the CLI, the site generator, the path table or this checker means "re-verify", and a
# per-page list would be both noisier and easier to lie in.
SYNC_IMPL = [
    "build.zig",
    "build.zig.zon",
    "src/cli/args.zig",
    "src/cli/main.zig",
    "src/cli/template.zig",
    "src/docsite/main.zig",
    "src/docsite/learn_path.zig",
    "src/docsite/i18n.zig",
    "src/docsite/site.zig",
    "src/docsite/frameworks.zig",
    "src/docsite/frameworks.json",
    "src/docsite/assets/site.js",
    "src/docsite/assets/site.css",
    "scripts/check-docs.py",
    "scripts/gen-framework-tutorials.py",
]

ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
CJK = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uff00-\uffef]")


def sha256_file(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def sha256_files(paths):
    h = hashlib.sha256()
    for path in paths:
        h.update(path.encode("utf-8"))
        h.update(b"\0")
        with open(path, "rb") as handle:
            h.update(handle.read())
        h.update(b"\0")
    return h.hexdigest()


def zon_versions():
    zon = open("build.zig.zon", encoding="utf-8").read()
    zts = re.search(r'\.version\s*=\s*"([^"]+)"', zon)
    zig = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon)
    return (zts.group(1) if zts else ""), (zig.group(1) if zig else "")


def current_commit():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5, check=True,
        )
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def render_ledger(verified, pages, date):
    """Write the two human-readable views. Deliberately depends only on dates/versions/paths —
    never on the hashes — so the ledger can contain its own pages without a fixed-point loop."""
    rows = "\n".join(
        f"| `{p['ja']}` | `{p['en']}` | {p['last_rewritten']} | {verified['zts_version']} |"
        for p in pages
    )
    checks = " · ".join(f"`{c}`" for c in verified["checks"])
    impl_files = ", ".join(f"`{p}`" for p in verified["implementation"])
    ja_common = (
        f"- **確認バージョン**: `ziggurats {verified['zts_version']}` / Zig `{verified['zig_version']}`\n"
        f"- **確認日**: `{date}`\n"
        f"- **基準コミット**: `{verified['commit']}`（確認開始時点の HEAD。実装の同一性は下のハッシュで判定）\n"
        f"- **確認コマンド**: {checks}\n"
        f"- **実装ハッシュ**: `{verified['implementation_sha256']}`\n"
    )
    en_common = (
        f"- **Verified version**: `ziggurats {verified['zts_version']}` / Zig `{verified['zig_version']}`\n"
        f"- **Verified on**: `{date}`\n"
        f"- **Base commit**: `{verified['commit']}` (HEAD when verification began; the sha256 below identifies the implementation)\n"
        f"- **Verified with**: {checks}\n"
        f"- **Implementation hash**: `{verified['implementation_sha256']}`\n"
    )
    ja = (
        "# ドキュメント同期台帳\n\n"
        "> **対象読者**: ドキュメントを書き換える人・レビューする人。\n"
        "> **このファイルは自動生成です。** 編集せず、`python3 scripts/check-docs.py --sync` を実行してください。\n\n"
        "「いつ最後に書き換えたか」と「どのバージョンまで実装と無矛盾を確認したか」を、\n"
        "**日英 1 組 = 1 行**で記録します。正本は [`scripts/doc-sync.json`](../../scripts/doc-sync.json) で、\n"
        "`check-docs.py` の規約 13 が次を検査します。\n\n"
        "1. すべての読者向けページに英語版があること（英語の H1 が日本語ではないこと、日本語版のコピーでないことも含む）\n"
        "2. 日英それぞれの本文 sha256 が台帳と一致すること（**書き換えたのに日付を更新していない**ことを検出）\n"
        "3. 実装ファイル群の sha256 が一致すること（**実装が変わったのに再確認していない**ことを検出）\n"
        "4. `zts_version` / `zig_version` が `build.zig.zon` と一致すること\n"
        "5. `last_rewritten` が確認日以前の ISO 日付であること\n\n"
        "## 確認したバージョン\n\n" + ja_common + "\n"
        "実装として突き合わせたファイル: " + impl_files + "\n\n"
        "## ページごとの記録\n\n"
        "| 日本語 | English | 最終書き換え | 確認バージョン |\n|---|---|---|---|\n" + rows + "\n\n"
        "## 更新のしかた\n\n"
        "```bash\n"
        "# 実装か Doc を変えたあと、再確認して台帳を更新する（日付は既定で当日）\n"
        "python3 scripts/check-docs.py --sync\n"
        "python3 scripts/check-docs.py --sync --date 2026-10-21   # 日付を明示するとき\n"
        "python3 scripts/check-docs.py                             # 検査のみ（CI はこれ）\n"
        "```\n\n"
        "`--sync` は本文が変わったページの `last_rewritten` だけを更新し、変わっていないページの\n"
        "日付は保持します。内部資料（ADR・設計メモ・タスク票）は日本語専用なので台帳の対象外です。\n"
        "全ページの末尾には `<!-- zts-doc-meta: ... -->` を 1 行書き、対応バージョン・確認日・\n"
        "最終書き換え日を記録します（規約 23）。メタ自身は本文に数えません。\n\n"
        "## 関連\n\n"
        "- [ドキュメントの書き方](writing-docs.md) — 規約 13 と 2 言語の規約\n"
        "- [リポジトリの地図](repository-map.md) — ファイル配置\n"
        "- [ドキュメント索引](../INDEX.md) — サイトの並び\n"
    )
    en = (
        "# Documentation sync ledger\n\n"
        "> **Audience**: anyone rewriting or reviewing a documentation page.\n"
        "> **This file is generated.** Do not edit it; run `python3 scripts/check-docs.py --sync`.\n\n"
        "One row per **Japanese/English pair** records when the page was last rewritten and which\n"
        "version was verified consistent with the implementation. The source of truth is\n"
        "[`scripts/doc-sync.json`](../../scripts/doc-sync.json); rule 13 of `check-docs.py` checks:\n\n"
        "1. every reader page has a real English counterpart (its H1 is not Japanese, and it is not\n"
        "   a byte-for-byte copy of the Japanese page);\n"
        "2. the sha256 of both documents matches the ledger (**a rewrite without a new date** is caught);\n"
        "3. the sha256 of the implementation files matches (**an implementation change without\n"
        "   re-verification** is caught);\n"
        "4. `zts_version` / `zig_version` match `build.zig.zon`;\n"
        "5. `last_rewritten` is an ISO date no later than the verification date.\n\n"
        "## Verified against\n\n" + en_common + "\n"
        "Implementation files compared: " + impl_files + "\n\n"
        "## Per-page record\n\n"
        "| Japanese | English | Last rewritten | Verified version |\n|---|---|---|---|\n" + rows + "\n\n"
        "## How to refresh\n\n"
        "```bash\n"
        "# after changing the implementation or a doc, re-verify and refresh the ledger\n"
        "python3 scripts/check-docs.py --sync\n"
        "python3 scripts/check-docs.py --sync --date 2026-10-21   # explicit date\n"
        "python3 scripts/check-docs.py                             # check only (what CI runs)\n"
        "```\n\n"
        "`--sync` updates `last_rewritten` only for pages whose content changed, and keeps the date of\n"
        "untouched pages. Internal documents (ADRs, design notes, task sheets) are Japanese-only and\n"
        "are deliberately outside the ledger. Every published page also ends with one\n"
        "`<!-- zts-doc-meta: ... -->` line recording its source version, verification day and last\n"
        "rewrite (rule 23). The meta line is not counted as body text.\n\n"
        "## Related\n\n"
        "- [Writing the docs](writing-docs.en.md) — rule 13 and the bilingual conventions\n"
        "- [Repository map](repository-map.en.md) — where files live\n"
        "- [Documentation index](../INDEX.en.md) — the site's order\n"
    )
    open(LEDGER_JA, "w", encoding="utf-8").write(ja)
    open(LEDGER_EN, "w", encoding="utf-8").write(en)


def git_last_commit_date(path):
    """Last commit day for an internal note that has no ledger row."""
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%cs", "--", path],
            capture_output=True, text=True, timeout=5, check=True,
        )
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def run_sync(date):
    zts, zig = zon_versions()
    verified = {
        "date": date,
        "commit": current_commit(),
        "zts_version": zts,
        "zig_version": zig,
        "checks": SYNC_CHECKS,
        "implementation": SYNC_IMPL,
        "implementation_sha256": sha256_files(SYNC_IMPL),
    }
    old = {}
    if os.path.isfile(SYNC_JSON):
        try:
            old = json.load(open(SYNC_JSON, encoding="utf-8"))
        except (ValueError, OSError):
            old = {}
    old_pages = {(p.get("ja"), p.get("en")): p for p in old.get("pages", [])}

    pairs = reader_pairs()
    for ja, en in pairs:
        if not os.path.isfile(en):
            print(f"error: {en}: missing English counterpart — cannot verify", file=sys.stderr)
            sys.exit(1)

    # Decide `last_rewritten` from the BODY only. The meta line is regenerated on every sync, so
    # hashing the whole file here would make every page look "just rewritten" every time.
    new_pages = []
    for ja, en in pairs:
        jb, eb = doc_meta.body_hash(ja), doc_meta.body_hash(en)
        prev = old_pages.get((ja, en), {})
        # Fall back to the old full-file hash for ledgers written before body hashes existed.
        prev_jb = prev.get("ja_body_sha256", prev.get("ja_sha256"))
        prev_eb = prev.get("en_body_sha256", prev.get("en_sha256"))
        changed = prev_jb != jb or prev_eb != eb
        last = date if changed or not prev.get("last_rewritten") else prev["last_rewritten"]
        new_pages.append({
            "ja": ja, "en": en, "last_rewritten": last,
            "ja_body_sha256": jb, "en_body_sha256": eb,
        })

    # The ledger views are themselves pages in the ledger. Render them first; their content does
    # not depend on the hashes, so no fixed-point iteration is needed.
    render_ledger(verified, new_pages, date)

    # Put one provenance comment at the end of every published page. Reader pages take the ledger
    # date; internal notes (ADRs, task sheets, architecture notes) use their last commit day.
    page_dates = {}
    for page in new_pages:
        page_dates[page["ja"]] = page["last_rewritten"]
        page_dates[page["en"]] = page["last_rewritten"]
    site_files = doc_meta.site_md_files()
    for path in site_files:
        last = page_dates.get(path) or git_last_commit_date(path) or date
        text = open(path, encoding="utf-8").read()
        open(path, "w", encoding="utf-8").write(
            doc_meta.with_meta(text, source_version=zts, verified=date, last_rewritten=last)
        )

    # The ledger's *_sha256 covers the FULL file, meta included (rule 13 stays unchanged).
    for page in new_pages:
        page["ja_sha256"] = sha256_file(page["ja"])
        page["en_sha256"] = sha256_file(page["en"])

    with open(SYNC_JSON, "w", encoding="utf-8") as handle:
        json.dump(
            {"schema": 1, "verified": verified, "pages": new_pages},
            handle, indent=2, ensure_ascii=False,
        )
        handle.write("\n")
    print(
        f"Sync ledger updated: {len(new_pages)} bilingual pairs, "
        f"ziggurats {zts} / Zig {zig}, verified {date} at {verified['commit']}; "
        f"{len(site_files)} pages carry zts-doc-meta."
    )


if "--sync" in sys.argv:
    idx = sys.argv.index("--sync")
    date = sys.argv[idx + 2] if "--date" in sys.argv and idx + 2 < len(sys.argv) else datetime.date.today().isoformat()
    if "--date" in sys.argv and not ISO_DATE.fullmatch(date):
        print(f"error: --date must be YYYY-MM-DD, got '{date}'", file=sys.stderr)
        sys.exit(1)
    run_sync(date)
    sys.exit(0)

if not os.path.isfile(SYNC_JSON):
    errors.append(f"{SYNC_JSON}: missing (run `python3 scripts/check-docs.py --sync`)")
else:
    try:
        ledger = json.load(open(SYNC_JSON, encoding="utf-8"))
    except ValueError as exc:
        ledger = {}
        errors.append(f"{SYNC_JSON}: invalid JSON ({exc})")
    if ledger:
        if ledger.get("schema") != 1:
            errors.append(f"{SYNC_JSON}: unsupported schema {ledger.get('schema')!r}")
        v = ledger.get("verified") or {}
        zts, zig = zon_versions()
        if v.get("zts_version") != zts:
            errors.append(f"{SYNC_JSON}: zts_version {v.get('zts_version')!r} != build.zig.zon {zts!r}")
        if v.get("zig_version") != zig:
            errors.append(f"{SYNC_JSON}: zig_version {v.get('zig_version')!r} != build.zig.zon {zig!r}")
        date = str(v.get("date", ""))
        if not ISO_DATE.fullmatch(date):
            errors.append(f"{SYNC_JSON}: verified.date '{date}' is not an ISO date")
        if not v.get("commit"):
            errors.append(f"{SYNC_JSON}: verified.commit is empty")
        if not v.get("checks"):
            errors.append(f"{SYNC_JSON}: verified.checks is empty (which commands proved consistency?)")
        impl = v.get("implementation") or []
        if not impl:
            errors.append(f"{SYNC_JSON}: verified.implementation is empty")
        else:
            for path in impl:
                if not os.path.isfile(path):
                    errors.append(f"{SYNC_JSON}: implementation file '{path}' does not exist")
            if all(os.path.isfile(p) for p in impl):
                want = sha256_files(impl)
                if v.get("implementation_sha256") != want:
                    errors.append(
                        f"{SYNC_JSON}: implementation changed since verification "
                        f"(sha256 {v.get('implementation_sha256', '')[:12]}… != {want[:12]}…) — "
                        f"re-check the docs and run `python3 scripts/check-docs.py --sync`"
                    )

        pairs = reader_pairs()
        entries = {(p.get("ja"), p.get("en")): p for p in ledger.get("pages", [])}
        for ja, en in pairs:
            if not os.path.isfile(en):
                errors.append(f"{en}: missing English counterpart (rule 13; every reader page is bilingual)")
                continue
            entry = entries.get((ja, en))
            if entry is None:
                errors.append(f"{SYNC_JSON}: no row for {ja} / {en} (run --sync)")
                continue
            for key, path in (("ja_sha256", ja), ("en_sha256", en)):
                have = sha256_file(path)
                if entry.get(key) != have:
                    errors.append(
                        f"{SYNC_JSON}: {path} changed after verification ({key} mismatch) — "
                        f"update last_rewritten with `python3 scripts/check-docs.py --sync`"
                    )
            last = str(entry.get("last_rewritten", ""))
            if not ISO_DATE.fullmatch(last):
                errors.append(f"{SYNC_JSON}: {ja}: last_rewritten '{last}' is not an ISO date")
            elif ISO_DATE.fullmatch(date) and last > date:
                errors.append(f"{SYNC_JSON}: {ja}: last_rewritten {last} is after verified.date {date}")
            en_text = open(en, encoding="utf-8").read()
            h1 = next((line[2:].strip() for line in en_text.splitlines() if line.startswith("# ")), "")
            if CJK.search(h1):
                errors.append(f"{en}: the English H1 still contains Japanese text ('{h1}') — translate it")
            if open(en, "rb").read() == open(ja, "rb").read():
                errors.append(f"{en}: is a byte-for-byte copy of {ja} — translate it")
        for key in entries:
            if key not in pairs:
                errors.append(f"{SYNC_JSON}: stale row for {key[0]} / {key[1]} (run --sync)")

        for view in (LEDGER_JA, LEDGER_EN):
            if not os.path.isfile(view):
                errors.append(f"{view}: missing generated ledger view (run --sync)")
            else:
                text = open(view, encoding="utf-8").read()
                for needle in (zts, date, v.get("commit", "")):
                    if needle and needle not in text:
                        errors.append(f"{view}: is out of date (missing '{needle}'; run --sync)")

# ---------------------------------------------------------------------------
# 14. The project's full name is `ziggurats`
# ---------------------------------------------------------------------------

LEGACY_NAME = "Z-Ts"
NEW_NAME = "ziggurats"


def legacy_name_is_protected(line, j):
    """A repository URL or checkout path is the only legitimate home of the old name."""
    prev = line[j - 1] if j > 0 else ""
    rest = line[j + len(LEGACY_NAME):]
    nxt = rest[0] if rest else ""
    return (
        prev in ("/", "\\")
        or rest.startswith(".git")
        or (nxt == "/" and (j == 0 or prev.isspace() or prev in "\"'`([{"))
        or line[max(0, j - 3):j] == "cd "
    )


# The reader-facing surface: Markdown, the site generator, the CLI's own help/templates, the
# build step names, CI, and the bootstrap scripts. `scripts/check-docs.py` is intentionally not
# scanned (this rule has to spell the old name), and neither are test fixtures, library default
# titles or the rendered demo pages whose visible text is part of the pixel-parity gate.
NAME_SCAN = sorted(set(
    [
        p for p in glob.glob("**/*.md", recursive=True)
        if not p.startswith(("zig-out/", ".git/", "vendor/", "node_modules/"))
    ]
    + glob.glob("src/docsite/**/*.zig", recursive=True)
    + glob.glob("src/docsite/assets/*.css")
    + glob.glob("src/docsite/assets/*.js")
    + glob.glob("src/cli/*.zig")
    + ["build.zig", "zigw"]
    + glob.glob(".github/workflows/*.yml")
    + glob.glob("scripts/*.sh")
))
for path in NAME_SCAN:
    if not os.path.isfile(path):
        continue
    for lineno, line in enumerate(open(path, encoding="utf-8"), 1):
        cursor = 0
        while True:
            found = line.find(LEGACY_NAME, cursor)
            if found < 0:
                break
            if not legacy_name_is_protected(line, found):
                errors.append(
                    f"{path}:{lineno}: legacy project name '{LEGACY_NAME}' in prose — "
                    f"write '{NEW_NAME}' (rule 14)"
                )
            cursor = found + len(LEGACY_NAME)
        for variant in ("Ziggurats", "ZIGGURATS", "ZigguRats"):
            if variant in line:
                errors.append(
                    f"{path}:{lineno}: '{variant}' — the name is lowercase '{NEW_NAME}' (rule 14)"
                )

# The new name has to be visible on the two front doors and in the generated surfaces.
for path in (
    "README.md", "README.en.md", "docs/INDEX.md", "docs/INDEX.en.md",
    "src/docsite/site.zig", "src/docsite/i18n.zig", "src/docsite/main.zig",
    "src/cli/template.zig",
):
    if os.path.isfile(path) and NEW_NAME not in open(path, encoding="utf-8").read():
        errors.append(f"{path}: does not say '{NEW_NAME}' (rule 14)")

# ---------------------------------------------------------------------------
# 15. Framework tutorial branches must match the committed examples
# ---------------------------------------------------------------------------

FRAMEWORK_CATALOG = "src/docsite/frameworks.json"
PICKER_MARKER = "<!-- framework-picker -->"


def fenced_excerpt(lines, start):
    """The first fenced code block at or after `start`, or None."""
    i = start
    while i < len(lines) and not lines[i].lstrip().startswith("```"):
        i += 1
    if i >= len(lines):
        return None
    j = i + 1
    while j < len(lines) and not lines[j].lstrip().startswith("```"):
        j += 1
    return "\n".join(lines[i + 1:j]).strip("\n")


if not os.path.isfile(FRAMEWORK_CATALOG):
    errors.append(f"{FRAMEWORK_CATALOG}: missing — the framework picker has no catalog")
else:
    try:
        catalog = json.load(open(FRAMEWORK_CATALOG, encoding="utf-8"))
    except (OSError, ValueError) as exc:
        catalog = []
        errors.append(f"{FRAMEWORK_CATALOG}: cannot parse ({exc})")

    ids = [fw.get("id", "") for fw in catalog]
    if len(ids) != len(set(ids)):
        errors.append(f"{FRAMEWORK_CATALOG}: duplicate framework ids")
    if not ids:
        errors.append(f"{FRAMEWORK_CATALOG}: empty catalog — the tutorials have no branches")

    for fw in catalog:
        fid = fw.get("id", "")
        if not fid or not fid.islower() or not fid.isalnum():
            errors.append(f"{FRAMEWORK_CATALOG}: bad framework id '{fid}' (lowercase alphanumeric)")
            continue
        example_dir = os.path.join("examples", "frameworks", fid)
        if not os.path.isdir(example_dir):
            errors.append(f"{example_dir}: missing example for framework '{fid}' (rule 15)")
        source = fw.get("source", "")
        if not os.path.isfile(source):
            errors.append(f"{source}: example source for '{fid}' is missing (rule 15)")
            continue
        source_text = open(source, encoding="utf-8").read()
        if 'data-zts="count"' not in source_text:
            errors.append(f"{source}: example has no counter markup (rule 15)")

        for lang in ("ja", "en"):
            page = os.path.join("docs", "learn", lang, "tutorials", f"counter-{fid}.md")
            if not os.path.isfile(page):
                errors.append(f"{page}: missing tutorial branch for '{fid}' (rule 15)")
                continue
            text = open(page, encoding="utf-8").read()
            if PICKER_MARKER not in text:
                errors.append(f"{page}: missing '{PICKER_MARKER}' (rule 15)")
            if "frameworks.md" not in text:
                errors.append(f"{page}: does not link back to the chooser (rule 15)")
            marker = f"<!-- source: {source} -->"
            lines = text.splitlines()
            at = next((i for i, ln in enumerate(lines) if ln.strip() == marker), None)
            if at is None:
                errors.append(f"{page}: missing '{marker}' (rule 15)")
                continue
            excerpt = fenced_excerpt(lines, at + 1)
            if not excerpt or excerpt.strip() not in source_text:
                errors.append(
                    f"{page}: embedded excerpt is not verbatim from {source} "
                    "(run python3 scripts/gen-framework-tutorials.py; rule 15)"
                )

    # The chooser links every branch plus the plain-JS original, in both languages.
    for lang in ("ja", "en"):
        chooser = os.path.join("docs", "learn", lang, "tutorials", "frameworks.md")
        if not os.path.isfile(chooser):
            errors.append(f"{chooser}: missing chooser page (rule 15)")
            continue
        chooser_text = open(chooser, encoding="utf-8").read()
        if PICKER_MARKER not in chooser_text:
            errors.append(f"{chooser}: missing '{PICKER_MARKER}' (rule 15)")
        for link in ["counter.md"] + [f"counter-{fid}.md" for fid in ids]:
            if link not in chooser_text:
                errors.append(f"{chooser}: does not link '{link}' (rule 15)")

    # All three originals must offer the branch, so a reader never gets stuck on one library.
    for lang in ("ja", "en"):
        for stem in ("index", "counter", "todo", "ui"):
            page = os.path.join("docs", "learn", lang, "tutorials", f"{stem}.md")
            if os.path.isfile(page) and PICKER_MARKER not in open(page, encoding="utf-8").read():
                errors.append(f"{page}: missing '{PICKER_MARKER}' — this tutorial is not branchable (rule 15)")

    # The picker's progressive enhancement must exist in both shipped assets; the Markdown
    # table stays usable when it does not, but the selector would silently disappear.
    site_js = "src/docsite/assets/site.js"
    site_css = "src/docsite/assets/site.css"
    if os.path.isfile(site_js) and "data-fw-picker" not in open(site_js, encoding="utf-8").read():
        errors.append(f"{site_js}: framework picker enhancement is missing (rule 15)")
    if os.path.isfile(site_css) and ".fw-picker" not in open(site_css, encoding="utf-8").read():
        errors.append(f"{site_css}: framework picker styles are missing (rule 15)")

    # The generated pages are a pure function of the catalog + examples.
    try:
        generated = subprocess.run(
            [sys.executable, "scripts/gen-framework-tutorials.py", "--check"],
            capture_output=True, text=True, timeout=30,
        )
        if generated.returncode != 0:
            errors.append(
                "generated tutorial pages are stale (rule 15): " + generated.stderr.strip().replace("\n", " | ")
            )
    except (OSError, subprocess.SubprocessError) as exc:
        errors.append(f"cannot verify generated tutorial pages (rule 15): {exc}")



# ---------------------------------------------------------------------------
# 16. Every framework demo must prove that Zig is running (M5-21)
# ---------------------------------------------------------------------------
#
# Before this rule the nine builds were *visually identical* to a static HTML file: the counter
# was local JS state, so nothing on screen could tell a real WebView+Zig host from GitHub Pages.
# The `.zigbar` panel fixes that: its seal can only be produced by `zig_probe` / `zig_inc` /
# `zig_dec` inside the Zig binary. Four surfaces have to agree, or one of them silently regresses
# back to "just HTML": the generator, the 9 example sources, the 9 published builds, and the
# gallery host (bridge + ipc scheme + CI gate).

GEN_SCRIPT = "scripts/gen-framework-demos.mjs"
ZIG_BRIDGE = "examples/gallery/src/web/zig-bridge.js"
GALLERY_MAIN = "examples/gallery/src/main.zig"
GALLERY_BUILD = "examples/gallery/build.zig"
GALLERY_ASSETS = "examples/gallery/src/fw_assets.zig"
SHOT_VERIFY = "scripts/verify-screenshots.mjs"
CI_WORKFLOW = ".github/workflows/ci.yml"
ZIG_COMMANDS = ("zig_probe", "zig_inc", "zig_dec")
PANEL_TOKENS = ('data-zts="zig-panel"', "ZIG OFFLINE", "__ZTS_ZIG__")
# Bundlers minify attribute quoting away (`data-zts=zig-panel`), so published builds are checked
# with the attribute *name* rather than the exact source spelling.
PUBLISHED_TOKENS = ("zig-panel", "ZIG OFFLINE", "__ZTS_ZIG__")


def rule16_text(path):
    if not os.path.isfile(path):
        return None
    return open(path, encoding="utf-8").read()


def rule16_require(path, token, label=None):
    text = rule16_text(path)
    if text is None:
        errors.append(f"{path}: missing ({label or 'rule 16'})")
    elif token not in text:
        errors.append(f"{path}: missing {token!r} ({label or 'rule 16'})")
    return text


# (a) The generator owns all nine bodies: one shared panel + one shared lifecycle hook.
gen = rule16_require(GEN_SCRIPT, "ZIG_PANEL_HTML", "shared Zig panel")
if gen:
    for token in ("ZIG_READY_JS", ".zigbar", '.zigbadge[data-online=', "writeGlobalTypes(dir)"):
        if token not in gen:
            errors.append(f"{GEN_SCRIPT}: missing {token!r} (rule 16)")

# (b) The bridge must never contain the Zig secret or a JS reimplementation of the seal.
bridge = rule16_require(ZIG_BRIDGE, "__ZTS_ZIG__", "DOCUMENT_START bridge")
if bridge:
    for cmd in ZIG_COMMANDS + ("ZIG ONLINE", "'zig-state'"):
        if cmd not in bridge:
            errors.append(f"{ZIG_BRIDGE}: missing {cmd!r} (rule 16)")
    for forbidden in ("zig_secret", "Sha256", "sha256"):
        if forbidden in bridge:
            errors.append(f"{ZIG_BRIDGE}: leaks {forbidden!r} — static JS could forge the seal (rule 16)")

# (c) The gallery really registers `ipc://`, uses the unmodified Tauri bootstrap, and reports
#     `zig_online` into the manifest.
gallery = rule16_require(GALLERY_MAIN, 'ipc_scheme_name = "ipc"', "ipc scheme")
if gallery:
    for token in (
        "registerScheme(ipc_scheme_name", "js_bootstrap.renderScriptAlloc", "composeInitScripts",
        "zig_bridge_script", "zig_online", "zig_invoked", "__ZTS_ZIG_DONE__", "Tauri-Response", "zigSeal",
    ) + ZIG_COMMANDS:
        if token not in gallery:
            errors.append(f"{GALLERY_MAIN}: missing {token!r} (rule 16)")
rule16_require(GALLERY_BUILD, '"zts_tauri"', "unmodified js_bootstrap module import")
rule16_require(SHOT_VERIFY, "--require-zig", "CI gate for zig_online")
ci = rule16_text(CI_WORKFLOW)
if ci is None or ci.count("--require-zig") < 3:
    errors.append(f"{CI_WORKFLOW}: --require-zig must gate all three native OS captures (rule 16)")

# (d) Every catalog entry: real source, published static build, embedded asset row and the TS
#     declaration must all carry the panel / bridge markers.
assets = rule16_text(GALLERY_ASSETS) or ""
for fw in catalog:
    fid = fw.get("id", "")
    if not fid:
        continue
    source = fw.get("source", "")
    src_text = rule16_text(source) or ""
    for token in PANEL_TOKENS:
        if token not in src_text:
            errors.append(f"{source}: missing {token!r} in the example source (rule 16)")

    out_dir = os.path.join("examples", "gallery", "src", "web", "fw", fid)
    published = ""
    if os.path.isdir(out_dir):
        for base, _dirs, files in os.walk(out_dir):
            for name in files:
                if not name.endswith((".html", ".js", ".mjs", ".css", ".txt", ".json")):
                    continue
                try:
                    published += open(os.path.join(base, name), encoding="utf-8", errors="ignore").read()
                except OSError:
                    pass
    else:
        errors.append(f"{out_dir}: missing published build (rule 16)")
    for token in PUBLISHED_TOKENS:
        if token not in published:
            errors.append(f"{out_dir}: published build lost {token!r} — regenerate with gen-framework-demos.mjs (rule 16)")
    if f'/fw/{fid}/index.html' not in assets:
        errors.append(f"{GALLERY_ASSETS}: missing embedded /fw/{fid}/index.html row (rule 16)")

    decl = os.path.join("examples", "frameworks", fid, "types", "zts-globals.d.ts")
    decl_text = rule16_text(decl)
    if decl_text is None or "__ZTS_ZIG__" not in decl_text:
        errors.append(f"{decl}: missing __ZTS_ZIG__ declaration (rule 16)")

    for lang in ("ja", "en"):
        branch = os.path.join("docs", "learn", lang, "tutorials", f"counter-{fid}.md")
        text = rule16_text(branch)
        if text is None or "ZIG OFFLINE" not in text or "ZIG ONLINE" not in text:
            errors.append(f"{branch}: missing the ZIG OFFLINE / ZIG ONLINE appendix (rule 16)")

# (e) Reader docs in both languages describe the difference between static and native.
for lang, off, on in (("ja", "ZIG OFFLINE", "ZIG ONLINE"), ("en", "ZIG OFFLINE", "ZIG ONLINE")):
    chooser = os.path.join("docs", "learn", lang, "tutorials", "frameworks.md")
    text = rule16_text(chooser) or ""
    for token in (off, on, "zig_probe", "zig_inc", "zig_dec"):
        if token not in text:
            errors.append(f"{chooser}: missing {token!r} (rule 16)")
for readme in ("examples/frameworks/README.md", "examples/frameworks/README.en.md"):
    text = rule16_text(readme) or ""
    for token in ("ZIG OFFLINE", "ZIG ONLINE", "zig_probe", "zig_inc", "zig_dec", "--require-zig"):
        if token not in text:
            errors.append(f"{readme}: missing {token!r} (rule 16)")

# ---------------------------------------------------------------------------
# 17. Native window-state wiring: one contract, four backends, three OSes (M5-22)
# ---------------------------------------------------------------------------
#
# The registry used to be the *only* owner of window flags, so a title-bar button changed the OS
# window while `isMaximized()` still returned the last value JS had set. Rule 17 pins the four
# surfaces that must stay in lockstep: the webview event enum, the tauri counterpart (same names,
# same order, because the runtime converts by ordinal), the four backend emitters, and the
# `core.Host` vtable that every setter now goes through.

R17_STATE_KINDS = (
    "minimized", "maximized", "fullscreen", "focused", "visible",
    "decorated", "resizable", "always_on_top", "moved", "resized",
)
R17_BACKENDS = {
    "src/webview/mock.zig": (
        "state_handler", "emitState", "simulateWindowStateEvent",
        "applyWindowExtras", "centerWindow", "applyWindowCreationOptions",
    ),
    "src/webview/linux.zig": (
        "state_handler", "emitState", "onGdkWindowState", "onGdkConfigure",
        "applyWindowExtras", "centerWindow", "applyWindowCreationOptions",
    ),
    "src/webview/macos.zig": (
        "state_handler", "emitState", "onWindowState",
        "applyWindowExtras", "centerWindow", "applyWindowCreationOptions",
        "zts_macos_apply_extras", "zts_macos_apply_creation_options",
    ),
    "src/webview/windows.zig": (
        "state_handler", "emitState", "emitWin32Geometry", "WM_ACTIVATE",
        "applyWindowExtras", "centerWindow", "applyWindowCreationOptions",
    ),
}
R17_HOSTS = (
    "src/core/host.zig", "src/webview_host.zig", "src/bridge_host.zig", "src/wasm/host.zig",
)


def r17_read(path):
    if not os.path.isfile(path):
        errors.append(f"{path}: missing (rule 17)")
        return None
    return open(path, encoding="utf-8").read()


def r17_require(path, *tokens):
    text = r17_read(path)
    if text is None:
        return
    for token in tokens:
        if token not in text:
            errors.append(f"{path}: missing {token!r} (rule 17)")
    return text


def r17_enum_names(path, name):
    text = r17_read(path)
    if text is None:
        return []
    m = re.search(r"pub const " + name + r"\s*=\s*enum(?:\([^)]*\))?\s*\{([^}]*)\}", text, re.S)
    if not m:
        errors.append(f"{path}: cannot find enum {name} (rule 17)")
        return []
    return re.findall(r"^\s*([a-z_]+)\s*,", m.group(1), re.M)


# (a) The two enums are the same names in the same order: `DesktopRuntime` converts by ordinal.
webview_kinds = r17_enum_names("src/webview/types.zig", "WindowStateKind")
native_kinds = r17_enum_names("src/tauri/window.zig", "NativeStateKind")
if tuple(webview_kinds) != R17_STATE_KINDS:
    errors.append("src/webview/types.zig: WindowStateKind order changed (rule 17)")
if tuple(native_kinds) != R17_STATE_KINDS:
    errors.append("src/tauri/window.zig: NativeStateKind order diverged from WindowStateKind (rule 17)")

# (b) C ABI ordinals in the Cocoa shim match the Zig enum 0..9.
shim = r17_read("src/webview/macos_shim.m")
if shim is not None:
    for i, kind in enumerate(R17_STATE_KINDS):
        token = f"ZTS_STATE_{kind.upper()} = {i}"
        if token not in shim:
            errors.append(f"src/webview/macos_shim.m: missing {token!r} (rule 17)")
    for delegate in (
        "windowDidMiniaturize:", "windowDidDeminiaturize:", "windowDidEnterFullScreen:",
        "windowDidExitFullScreen:", "windowDidBecomeKey:", "windowDidResignKey:",
        "windowDidMove:", "windowDidResize:", "ZtsEmitState", "ZtsEmitFrame",
        "zts_macos_state_cb", "zts_macos_apply_creation_options",
    ):
        if delegate not in shim:
            errors.append(f"src/webview/macos_shim.m: missing {delegate!r} (rule 17)")

# (c) Four backends + the GDK event structs + the runtime bridge.
for path, tokens in R17_BACKENDS.items():
    r17_require(path, *tokens)
r17_require(
    "src/webview/gtk_bindings.zig",
    "GdkEventWindowState", "GdkEventConfigure", "GdkRectangle",
    "gtk_window_set_skip_taskbar_hint", "gdk_monitor_get_geometry",
)
r17_require(
    "src/app_runtime.zig", "onWindowState", "setWindowStateHandler", "applyNativeState",
)
# `createWindow()` now applies options on EVERY window, including C-ABI overlay embeds which have
# no `GtkWindow`. GTK must guard those calls or `zts_webview_window_create` returns Unsupported.
r17_require(
    "src/webview/linux.zig", "const top = w.toplevel orelse return;",
    "if (w.toplevel) |top| c.gtk_window_present",
)
r17_require(
    "src/webview/mod.zig", "setWindowStateHandler", "applyWindowExtras",
    "centerWindow", "applyWindowCreationOptions", "cfg.maximized", "cfg.center", "cfg.focus",
)
r17_require(
    "src/core/window_extras.zig", "WindowExtrasSnapshot", "WindowCreationOptions",
)

# (d) `core.Host` + all four host implementations carry the one setter contract.
r17_require("src/core/host.zig", "applyWindowExtras", "WindowExtrasSnapshot", "extras_log")
for path in R17_HOSTS[1:]:
    r17_require(path, "applyWindowExtras")
r17_require(
    "src/tauri/window.zig", "extrasSnapshot", "t.host.applyWindowExtras", "applyNativeState",
)

# Zig 0.17 removed `Allocator.dupeZ`; the Linux/macOS backends are only compiled on their own
# OS CI jobs, so a local Linux run would NOT catch it. Pin the allowed API here.
for path in ("src/webview/linux.zig", "src/webview/macos.zig", "src/webview/windows.zig", "src/webview/mock.zig"):
    text = r17_read(path)
    if text is not None and ".dupeZ(" in text:
        errors.append(f"{path}: Allocator.dupeZ does not exist in Zig 0.17; use dupeSentinel(..., 0) (rule 17)")

# (e) E2E state round trips + bilingual reader docs.
r17_require(
    "tests/tauri/src/e2e_suite.ts",
    "win.minimize()", "win.unminimize()", "win.maximize()", "win.unmaximize()",
    "win.setFullscreen(true)", "win.isFullscreen()", "win.isMinimized()", "win.isMaximized()",
)
r17_require("docs/learn/ja/guides/plugins.md", "applyWindowExtras", "WindowStateEvent", "isMaximized()")
r17_require("docs/learn/en/guides/plugins.md", "applyWindowExtras", "WindowStateEvent", "isMaximized()")
# The API reference describes the UNMODIFIED upstream package, so it names the public getters
# instead of an internal `Host` method (rule 3 keeps internal identifiers out of reader pages).
for path in ("docs/reference/tauri-usage.md", "docs/reference/tauri-usage.en.md"):
    r17_require(path, "isMinimized()", "isMaximized()", "setFullscreen", "tauri://window-flags-changed")
r17_require("docs/architecture/zts-webview-backends.md", "WindowStateEvent", "applyWindowExtras", "WindowCreationOptions")

# ---------------------------------------------------------------------------
# 18. Rename-safe Check Run log publishing (CI diagnostics must never fail the build)
# ---------------------------------------------------------------------------
#
# A repository rename during a run leaves `context.repo` / `GITHUB_REPOSITORY` pointing at the
# old name. `GET /repos/{old}` redirects, but `PATCH /repos/{old}/check-runs/{id}` returns
# HTTP 500 (`HttpError: fetch failed`). Rule 18 pins the guard: one helper resolves the canonical
# `full_name`, every publishing step is non-fatal, and the Pages API uses the same resolution.

R18_HELPER = "scripts/publish-check-run-summary.js"
R18_TEST = "tests/ci/publish-check-run-summary.test.cjs"
R18_DOC = "docs/environment/github-actions.md"


def r18_read(path):
    if not os.path.isfile(path):
        errors.append(f"{path}: missing (rule 18)")
        return None
    return open(path, encoding="utf-8").read()


helper = r18_read(R18_HELPER)
if helper is not None:
    for token in (
        "resolveRepository", "github.rest.repos.get", "full_name",
        "core.summary.addRaw", "truncateUtf8", "MAX_SUMMARY_BYTES",
        "core?.warning?.(", "github.rest.checks.update",
    ):
        if token not in helper:
            errors.append(f"{R18_HELPER}: missing {token!r} (rule 18)")

ci = r18_read(".github/workflows/ci.yml")
if ci is not None:
    if ci.count("publish-check-run-summary.js") != 5:
        errors.append(".github/workflows/ci.yml: every Check Run publisher must use the helper (rule 18)")
    if ci.count("continue-on-error: true") != 5:
        errors.append(".github/workflows/ci.yml: every Check Run publisher must be continue-on-error (rule 18)")
    if "github.rest.checks.update" in ci:
        errors.append(".github/workflows/ci.yml: direct checks.update bypasses the rename-safe helper (rule 18)")
    if "node --test tests/ci/publish-check-run-summary.test.cjs" not in ci:
        errors.append(".github/workflows/ci.yml: the helper's Node tests must run in CI (rule 18)")

pages = r18_read(".github/workflows/pages.yml")
if pages is not None:
    for token in ("canonical=\"$(gh api \"repos/${repo}\"", "repos/${repo}/pages"):
        if token not in pages:
            errors.append(f".github/workflows/pages.yml: missing {token!r} (rule 18)")

test = r18_read(R18_TEST)
if test is not None:
    for token in ("node:test", "fullName", "updateFailures", "renamed"):
        if token not in test:
            errors.append(f"{R18_TEST}: missing {token!r} (rule 18)")

doc = r18_read(R18_DOC)
if doc is not None:
    for token in ("publish-check-run-summary.js", "full_name", "continue-on-error"):
        if token not in doc:
            errors.append(f"{R18_DOC}: missing {token!r} (rule 18)")

# ---------------------------------------------------------------------------
# 19. Published Pages URLs follow the current repository name
# ---------------------------------------------------------------------------
#
# A repository rename changes the GitHub Pages sub-path but not `github.com` URLs (those redirect).
# Rule 14 deliberately keeps the legacy name inside repository URLs and checkout paths; rule 19 is
# the narrower guard for the *published site*: `site_url`, sitemap.xml, llms.txt, framework demos,
# the generated tutorials and every reader-facing link must use the current `/ZigguraTs/` base.
# ADRs and task sheets are historical records and are intentionally excluded from the scan.

R19_BASE = "https://umiturtle.github.io/ZigguraTs/"
R19_OLD = "https://umiturtle.github.io/Z-Ts/"
R19_SOURCES = (
    "src/docsite/main.zig",
    "src/docsite/frameworks.zig",
    "scripts/gen-framework-tutorials.py",
)
R19_SCAN = (
    [
        "README.md", "README.en.md", "AGENTS.md",
        "docs/INDEX.md", "docs/INDEX.en.md",
        "docs/architecture/documentation-site.md",
        ".github/workflows/pages.yml",
        "src/docsite/demos.zig",
    ]
    + sorted(glob.glob("docs/learn/**/*.md", recursive=True))
    + sorted(glob.glob("docs/reference/**/*.md", recursive=True))
    + sorted(glob.glob("docs/contributing/**/*.md", recursive=True))
    + sorted(glob.glob("docs/architecture/**/*.md", recursive=True))
    + sorted(glob.glob("examples/*/README*.md", recursive=True))
    + sorted(glob.glob("src/docsite/**/*.zig", recursive=True))
    + ["scripts/gen-framework-tutorials.py"]
)

for path in R19_SOURCES:
    if not os.path.isfile(path):
        errors.append(f"{path}: missing (rule 19)")
        continue
    text = open(path, encoding="utf-8").read()
    if R19_OLD in text:
        errors.append(f"{path}: stale Pages base {R19_OLD!r} (rule 19)")
    if R19_BASE not in text:
        errors.append(f"{path}: missing current Pages base {R19_BASE!r} (rule 19)")

for path in sorted(set(R19_SCAN)):
    if not os.path.isfile(path):
        continue
    text = open(path, encoding="utf-8").read()
    if R19_OLD in text:
        errors.append(f"{path}: stale published Pages URL {R19_OLD!r} (rule 19)")

# ---------------------------------------------------------------------------
# 20. One release version, everywhere it is published
# ---------------------------------------------------------------------------
#
# `build.zig.zon` is the source of truth; `release.yml` reads it with `sed` and the sync ledger
# mirrors it. The remaining copies are the CLI's own `SemanticVersion` and the URLs a reader is
# told to fetch. A stale `v0.1.0` in an install command is a 404 that no link checker catches
# because GitHub URLs are external and therefore skipped.
#
# The `0.1.0` in a *scaffolded project's* `build.zig.zon` (src/cli/template.zig, project.zig,
# `my_app_0.1.0_amd64.deb` in the CLI reference) is a different version and is deliberately not
# scanned: it is the app author's first release, not ours.

R20_SURFACES = (
    "README.md", "README.en.md",
    "docs/learn/ja/guides/install.md", "docs/learn/en/guides/install.md",
    "docs/reference/cli.md", "docs/reference/cli.en.md",
    "src/cli/template.zig",
)
R20_STALE = ("v0.1.0", "zts-0.1.0", "z_ts-0.1.0", "zts 0.1.0")

def r20_read(path):
    if not os.path.isfile(path):
        errors.append(f"{path}: missing (rule 20)")
        return None
    return open(path, encoding="utf-8").read()


version = zon_versions()[0]
for path in R20_SURFACES:
    text = r20_read(path)
    if text is None:
        continue
    if f"z_ts-{version}" not in text:
        errors.append(f"{path}: missing z_ts-{version} archive name (rule 20)")
    for stale in R20_STALE:
        if stale in text:
            errors.append(f"{path}: stale release version {stale!r} (rule 20)")

for path in ("README.md", "README.en.md", "docs/learn/ja/guides/install.md",
             "docs/learn/en/guides/install.md", "docs/reference/cli.md",
             "docs/reference/cli.en.md", "src/cli/template.zig"):
    text = open(path, encoding="utf-8").read() if os.path.isfile(path) else ""
    if f"v{version}" not in text:
        errors.append(f"{path}: missing v{version} release tag (rule 20)")

cli_args = open("src/cli/args.zig", encoding="utf-8").read() if os.path.isfile("src/cli/args.zig") else ""
m = re.search(
    r"pub const version = std\.SemanticVersion\{\s*\.major = (\d+),\s*\.minor = (\d+),\s*\.patch = (\d+)\s*\}",
    cli_args,
)
if not m:
    errors.append("src/cli/args.zig: cannot parse the CLI SemanticVersion (rule 20)")
else:
    cli_version = f"{m.group(1)}.{m.group(2)}.{m.group(3)}"
    if cli_version != version:
        errors.append(
            f"src/cli/args.zig: CLI version {cli_version} != build.zig.zon {version} (rule 20)"
        )

# Reader-facing pages must not teach an old release or the pre-rename repository URL. Task
# sheets and ADRs are historical records and are exempt; checkout path examples are rule 14's.
R20_READER = ["README.md", "README.en.md"] + sorted(
    p for p in glob.glob("docs/**/*.md", recursive=True)
    if not p.startswith(("docs/tasks/", "docs/decisions/"))
)
for path in R20_READER:
    text = open(path, encoding="utf-8").read()
    if "github.com/umiturtle/Z-Ts" in text:
        errors.append(f"{path}: pre-rename repository URL in reader docs (rule 20)")
    for stale in ("v0.1.0", "zts-0.1.0-", "zts 0.1.0"):
        if stale in text:
            errors.append(f"{path}: stale release reference {stale!r} (rule 20)")

release = open(".github/workflows/release.yml", encoding="utf-8").read() if os.path.isfile(".github/workflows/release.yml") else ""
if "build.zig.zon" not in release or ".version" not in release:
    errors.append(".github/workflows/release.yml: must read the version from build.zig.zon (rule 20)")

# CI builds its smoke archive from the same single source of truth; a hardcoded `z_ts-0.1.1`
# there would rot on the next release.
ci = open(".github/workflows/ci.yml", encoding="utf-8").read() if os.path.isfile(".github/workflows/ci.yml") else ""
for stale in R20_STALE:
    if stale in ci:
        errors.append(f".github/workflows/ci.yml: stale release version {stale!r} (rule 20)")
if "build.zig.zon" not in ci or "z_ts-$version" not in ci:
    errors.append(".github/workflows/ci.yml: the smoke archive must derive its name from build.zig.zon (rule 20)")
if "verify-library-consumer.sh" not in ci:
    errors.append(".github/workflows/ci.yml: missing library-consumer gate (rule 20)")

# ---------------------------------------------------------------------------
# 21. gitflow intake: CI triggers, naming validator, bilingual guide, PR template
# ---------------------------------------------------------------------------
#
# The repository owner creates the branches; Arena agents are pinned to one `arena/*` ref per
# session. This rule keeps the *intake* honest: every gitflow branch gets the same 3-OS CI, the
# validator is exercised in CI, and both languages tell the reader the same PR bases.

R21_BRANCHES = ("develop", '"feature/**"', '"release/**"', '"hotfix/**"', '"arena/**"')
R21_CI = open(".github/workflows/ci.yml", encoding="utf-8").read() if os.path.isfile(".github/workflows/ci.yml") else ""
for branch in R21_BRANCHES:
    if branch not in R21_CI:
        errors.append(f".github/workflows/ci.yml: missing push branch {branch} (rule 21)")
if "scripts/gitflow.sh --self-test" not in R21_CI:
    errors.append(".github/workflows/ci.yml: gitflow naming validator is not run in CI (rule 21)")

R21_SCRIPT = open("scripts/gitflow.sh", encoding="utf-8").read() if os.path.isfile("scripts/gitflow.sh") else ""
if not R21_SCRIPT:
    errors.append("scripts/gitflow.sh: missing (rule 21)")
else:
    for token in ("--self-test", "feature/*", "release/*", "hotfix/*", "arena/*", "develop"):
        if token not in R21_SCRIPT:
            errors.append(f"scripts/gitflow.sh: missing {token!r} (rule 21)")
    # An agent must never create/switch/push a branch: the owner owns the branch model.
    for forbidden in ("git checkout -b", "git switch -c", "git branch -m", "git push origin"):
        if forbidden in R21_SCRIPT:
            errors.append(f"scripts/gitflow.sh: must not create branches ({forbidden!r}) (rule 21)")

for path in ("docs/contributing/gitflow.md", "docs/contributing/gitflow.en.md"):
    text = r20_read(path)
    if text is None:
        continue
    for token in ("develop", "feature/", "release/", "hotfix/", "arena/", "--base develop", f"v{version}"):
        if token not in text:
            errors.append(f"{path}: missing {token!r} (rule 21)")

pr_template = open(".github/PULL_REQUEST_TEMPLATE.md", encoding="utf-8").read() if os.path.isfile(".github/PULL_REQUEST_TEMPLATE.md") else ""
if not pr_template:
    errors.append(".github/PULL_REQUEST_TEMPLATE.md: missing (rule 21)")
elif "develop" not in pr_template or "gitflow.sh --check" not in pr_template:
    errors.append(".github/PULL_REQUEST_TEMPLATE.md: must name develop and the validator (rule 21)")

# ---------------------------------------------------------------------------
# 22. Three tutorials x nine libraries: full grid, real Zig linkage, hub coverage
# ---------------------------------------------------------------------------
#
# `scripts/gen-framework-tutorials.py` writes 54 branch pages from one profile table. Rule 15
# still checks the verbatim example excerpt on the counter branches; this rule checks the rest:
# no library is left behind, every branch teaches the state primitive AND the Zig connection, and
# a reader can reach all 27 branches from the chapter hub, the chooser hub and each original.

R22_KINDS = ("counter", "todo", "ui")
R22_TOKENS = ("zig_inc", "seal", "ZIG OFFLINE", "ipc://", "invoke", "window.__ZTS_ZIG__")
R22_CATALOG = json.loads(open("src/docsite/frameworks.json", encoding="utf-8").read())

# The profile table must cover exactly the catalog: a new library without teaching text would
# otherwise produce a KeyError only when someone regenerates, not when the doc check runs.
profiles_src = open("scripts/framework_tutorial_profiles.py", encoding="utf-8").read()
for fw in R22_CATALOG:
    if f'"{fw["id"]}": {{' not in profiles_src:
        errors.append(f"scripts/framework_tutorial_profiles.py: no profile for {fw['id']!r} (rule 22)")

for lang in ("ja", "en"):
    hub_path = f"docs/learn/{lang}/tutorials/index.md"
    chooser_path = f"docs/learn/{lang}/tutorials/frameworks.md"
    hub = open(hub_path, encoding="utf-8").read() if os.path.isfile(hub_path) else ""
    chooser = open(chooser_path, encoding="utf-8").read() if os.path.isfile(chooser_path) else ""
    if not hub:
        errors.append(f"{hub_path}: missing (rule 22)")
    if not chooser:
        errors.append(f"{chooser_path}: missing (rule 22)")

    for kind in R22_KINDS:
        original_path = f"docs/learn/{lang}/tutorials/{kind}.md"
        original = open(original_path, encoding="utf-8").read() if os.path.isfile(original_path) else ""
        if not original:
            errors.append(f"{original_path}: missing (rule 22)")
        for fw in R22_CATALOG:
            fid = fw["id"]
            link = f"{kind}-{fid}.md"
            page = f"docs/learn/{lang}/tutorials/{link}"
            if not os.path.isfile(page):
                errors.append(f"{page}: missing branch page (rule 22)")
                continue
            text = open(page, encoding="utf-8").read()
            for token in R22_TOKENS:
                if token not in text:
                    errors.append(f"{page}: missing Zig-linkage token {token!r} (rule 22)")
            state = fw[f"state_{lang}"]
            if state not in text:
                errors.append(f"{page}: missing state primitive {state!r} (rule 22)")
            for name, body in (("index.md", hub), ("frameworks.md", chooser), (f"{kind}.md", original)):
                if link not in body:
                    errors.append(f"docs/learn/{lang}/tutorials/{name}: missing {link} (rule 22)")

# ---------------------------------------------------------------------------
# 23. Every published page states which source it describes and when it was rewritten
# ---------------------------------------------------------------------------
#
# `scripts/doc_meta.py` owns the one-line comment; `--sync` writes it. This rule is what makes the
# note mechanically useful: a page that claims the wrong version, an outdated verification day, a
# duplicated meta or a reader page whose date drifted from the ledger all turn CI red.

R23_SITE = doc_meta.site_md_files()
R23_DATES = {}
for (ja, en), entry in entries.items():
    R23_DATES[ja] = entry.get("last_rewritten")
    R23_DATES[en] = entry.get("last_rewritten")

for path in R23_SITE:
    text = open(path, encoding="utf-8").read()
    # Only the TRAILING comment counts. A doc may legitimately quote the format when explaining
    # the mechanism (this task sheet does), so do not count occurrences in the body.
    body, fields = doc_meta.split_meta(text)
    if fields is None:
        errors.append(f"{path}: missing trailing zts-doc-meta comment (rule 23)")
        continue
    if fields.get("source-version") != zts:
        errors.append(f"{path}: source-version {fields.get('source-version')!r} != {zts} (rule 23)")
    if fields.get("verified") != date:
        errors.append(f"{path}: verified {fields.get('verified')!r} != {date} (rule 23)")
    last = fields.get("last-rewritten", "")
    if not ISO_DATE.fullmatch(last):
        errors.append(f"{path}: last-rewritten '{last}' is not an ISO date (rule 23)")
    elif last > date and path in R23_DATES:
        # Internal notes take their real git commit day, which may postdate the last verification;
        # only ledger-backed pages must not claim a rewrite after the verification day.
        errors.append(f"{path}: last-rewritten {last} is after verified {date} (rule 23)")
    if path in R23_DATES and R23_DATES[path] and last != R23_DATES[path]:
        errors.append(
            f"{path}: last-rewritten {last} != ledger {R23_DATES[path]} (rule 23)"
        )

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
