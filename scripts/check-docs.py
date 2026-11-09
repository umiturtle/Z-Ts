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
13. Sync ledger      — `scripts/doc-sync.json` records, for every bilingual pair, when the page was
                      last rewritten, which Z-Ts / Zig version and commit were verified consistent,
                      which checks were run, and sha256 of both documents and of the implementation
                      sources. A hash mismatch means something changed after verification. It also
                      enforces a real English counterpart for every reader page. Refresh with
                      `python3 scripts/check-docs.py --sync`.

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
        out.append(os.path.relpath(p, "docs"))
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
    "scripts/check-docs.py",
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
        f"- **確認バージョン**: `zts {verified['zts_version']}` / Zig `{verified['zig_version']}`\n"
        f"- **確認日**: `{date}`\n"
        f"- **基準コミット**: `{verified['commit']}`（確認開始時点の HEAD。実装の同一性は下のハッシュで判定）\n"
        f"- **確認コマンド**: {checks}\n"
        f"- **実装ハッシュ**: `{verified['implementation_sha256']}`\n"
    )
    en_common = (
        f"- **Verified version**: `zts {verified['zts_version']}` / Zig `{verified['zig_version']}`\n"
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
        "日付は保持します。内部資料（ADR・設計メモ・タスク票）は日本語専用なので台帳の対象外です。\n\n"
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
        "are deliberately outside the ledger.\n\n"
        "## Related\n\n"
        "- [Writing the docs](writing-docs.en.md) — rule 13 and the bilingual conventions\n"
        "- [Repository map](repository-map.en.md) — where files live\n"
        "- [Documentation index](../INDEX.en.md) — the site's order\n"
    )
    open(LEDGER_JA, "w", encoding="utf-8").write(ja)
    open(LEDGER_EN, "w", encoding="utf-8").write(en)


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

    new_pages = []
    for ja, en in pairs:
        jh, eh = sha256_file(ja), sha256_file(en)
        prev = old_pages.get((ja, en), {})
        changed = prev.get("ja_sha256") != jh or prev.get("en_sha256") != eh
        last = date if changed or not prev.get("last_rewritten") else prev["last_rewritten"]
        new_pages.append({"ja": ja, "en": en, "last_rewritten": last})

    # The ledger views are themselves pages in the ledger. Render them first; their content does
    # not depend on the hashes, so no fixed-point iteration is needed.
    render_ledger(verified, new_pages, date)
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
        f"zts {zts} / Zig {zig}, verified {date} at {verified['commit']}."
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
