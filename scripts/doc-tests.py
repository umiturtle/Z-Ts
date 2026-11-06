#!/usr/bin/env python3
"""Compile the code blocks in the docs. The cheap half of a doctest.

Why this exists
---------------
A guide that shows `Schema.bind(...)` is only correct until the next rename. Nothing in the
Markdown renderer can notice that, and a reviewer looking at a diff usually cannot either.
So the fences get one more field:

    ```zig check
    const std = @import("std");
    const rpc = @import("zts_rpc");
    ...
    ```

`zig check` is a complete file: it is dropped into a temporary directory and compiled with
`zig test --test-no-exec` (full semantic analysis, no run, no C toolchain, ~0.5 s), with a
trailing `refAllDecls(@This())` so that lazy analysis cannot skip the interesting parts.
`zig check-snippet` is a fragment that only makes sense inside a function body; it gets a
preamble (`std`, the `zts_*` modules) and is wrapped in `fn __doc() anyerror!void { … }`.

A plain ```zig fence is illustration, not gospel: it may contain `…` on purpose. Those are
never compiled, which is why the convention is opt-in. `zig ignore` documents the decision to
skip an otherwise-compilable block.

Run: `python3 scripts/doc-tests.py` (or `./zigw docs-check`).
"""

import glob
import os
import re
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO_ROOT)

# The module graph, mirroring `zigw quick-test` (minus `zts_webview`, whose `options` module is
# generated at build time and whose imports pull in GTK/Cocoa headers).
MODULES = [
    ("zts_foundation", "src/core/foundation.zig", []),
    ("zts_web", "src/core/web.zig", ["zts_foundation"]),
    ("zts_core", "src/core/mod.zig", ["zts_foundation", "zts_web"]),
    ("zts_rpc", "src/rpc/mod.zig", ["zts_foundation"]),
    ("zts_bridge", "src/bridge/mod.zig", ["zts_foundation", "zts_web", "zts_rpc"]),
    ("zts_tauri", "src/tauri/mod.zig", ["zts_foundation", "zts_web", "zts_core", "zts_rpc"]),
    ("zts_wasm", "src/wasm/mod.zig", ["zts_foundation", "zts_web", "zts_core", "zts_rpc", "zts_tauri"]),
    ("zts_ssg", "src/ssg/mod.zig", ["zts_foundation", "zts_web", "zts_tauri", "zts_wasm"]),
]

ZIG = os.environ.get("ZTS_ZIG") or "zig"

PREAMBLE = """const std = @import("std");
const zts = @import("zts_rpc");
const rpc = @import("zts_rpc");
const core = @import("zts_core");
const tauri = @import("zts_tauri");
const web = @import("zts_web");
const foundation = @import("zts_foundation");
const bridge = @import("zts_bridge");
const wasm = @import("zts_wasm");
const ssg = @import("zts_ssg");
const T = std.testing;
"""

FENCE = re.compile(r"^```(?P<info>[^\n]*)\n(?P<body>.*?)^```[ \t]*$", re.S | re.M)


def module_args() -> list[str]:
    args: list[str] = []
    for name, path, deps in MODULES:
        for dep in deps:
            args.extend(["--dep", dep])
        args.append(f"-M{name}={path}")
    return args


def fence_targets() -> list[str]:
    files = ["README.md"]
    files += sorted(glob.glob("docs/guides/**/*.md", recursive=True))
    files += sorted(glob.glob("docs/reference/**/*.md", recursive=True))
    files += sorted(glob.glob("docs/learn/**/*.md", recursive=True))
    files += ["docs/glossary.md"]
    return [f for f in files if os.path.isfile(f)]


def main() -> int:
    if not os.path.isfile("src/rpc/mod.zig"):
        print("doc-tests: run from the repository root", file=sys.stderr)
        return 2

    inputs = module_args()
    # The root module may import any of them; each `--dep` must precede every `-M` it applies to,
    # so they all go before `-Mroot`.
    extra: list[str] = []
    for name, _, _ in MODULES:
        extra.extend(["--dep", name])

    checked = 0
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="zts-doctest-") as tmp:
        for md in fence_targets():
            text = open(md, encoding="utf-8").read()
            for index, m in enumerate(FENCE.finditer(text)):
                info = m.group("info").strip().split()
                if not info or info[0] != "zig":
                    continue
                mode = info[1] if len(info) > 1 else ""
                if mode not in ("check", "check-snippet"):
                    continue

                body = m.group("body")
                if mode == "check-snippet":
                    source = PREAMBLE + "\nfn __doc() anyerror!void {\n" + body + "\n}\ncomptime { _ = __doc; }\n"
                else:
                    # `--test-no-exec` performs full semantic analysis, but Zig is lazy: a
                    # declaration nobody references is never checked. The trailing test forces
                    # every top-level declaration to be analysed, so a stale `rpc.Schema(...)`
                    # fails even when the block itself never calls it.
                    source = body + "\ntest { @import(\"std\").testing.refAllDecls(@This()); }\n"

                name = f"{md.replace('/', '_')}_{index}.zig"
                path = os.path.join(tmp, name)
                open(path, "w", encoding="utf-8").write(source)

                cmd = [ZIG, "test", "--test-no-exec"]
                cmd += extra
                cmd += [f"-Mroot={path}"]
                cmd += inputs
                # The repository's own caches are reused on purpose: a cold global cache would
                # rebuild the Zig std lib for every block (~4 s each).

                checked += 1
                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    failures.append(f"{md} (fence #{index}, {mode})\n{result.stderr.strip()}")

    if failures:
        print(f"doc-tests: {len(failures)} of {checked} blocks failed to compile", file=sys.stderr)
        for f in failures:
            print("\n" + f, file=sys.stderr)
        return 1

    print(f"OK doctest blocks={checked}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
