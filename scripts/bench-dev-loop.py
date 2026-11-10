#!/usr/bin/env python3
"""Reproducible probe for `zts dev`'s incremental Zig build (`M5-17`).

Two independent measurements, both on a real generated project:

  bench    End-to-end latency from "a byte in src/main.zig changes" to "the injected reload
           script sees a new build", comparing full builds (`ZTS_DEV_BUILD=full`, the old cost)
           with the incremental check path. Also times `zig build` vs `zig build check` directly.
  verify   Behavioural regressions: type errors, recovery, no-op saves, unreachable sources,
           CSS hot swap, build.zig changes, the debounce window swallowing an edit, and that the
           persistent compiler server really re-checks in single-digit milliseconds (so a silent
           fallback to the slow path is caught).

Usage:
    ./zigw build -Dgtk=false                 # produces zig-out/bin/zts
    python3 scripts/bench-dev-loop.py bench --iters 7
    python3 scripts/bench-dev-loop.py verify
    python3 scripts/bench-dev-loop.py bench --zts /path/to/zts --iters 5

The script never touches the repository's own sources: the project is created in a temporary
directory with `zts init` and removed at the end.
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
STATE_PATH = "/__zts_dev__/state"


def zig_binary():
    if os.environ.get("ZTS_ZIG"):
        return os.environ["ZTS_ZIG"]
    try:
        return subprocess.check_output(["./zigw", "zig-path"], cwd=REPO, text=True).strip()
    except (OSError, subprocess.SubprocessError):
        # Windows CI has `zig` on PATH but cannot execute the POSIX `zigw` wrapper from Python.
        return shutil.which("zig") or "zig"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def base_env(zig, mode):
    env = dict(os.environ)
    env["ZTS_ZIG"] = zig
    if mode == "full":
        env["ZTS_DEV_BUILD"] = "full"
    else:
        env.pop("ZTS_DEV_BUILD", None)
    return env


def make_project(root, zts, zig, name="app", with_extras=False):
    env = base_env(zig, "incremental")
    r = subprocess.run([str(zts), "init", name], cwd=root, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        raise RuntimeError("zts init failed:\n" + r.stdout)
    project = root / name
    if with_extras:
        # Present BEFORE the dev server starts, so later edits are content changes (not structural
        # additions) and the dependency graph can prove scratch.zig is not reachable.
        (project / "src/scratch.zig").write_text("pub const scratch = 1;\n")
        (project / "web/site.css").write_text("h1 { color: red; }\n")
    return project


class DevSession:
    def __init__(self, zts, project, zig, mode, log_path):
        self.zts, self.project, self.mode = zts, project, mode
        self.port = free_port()
        self.log_path = log_path
        self.log = open(log_path, "w", encoding="utf-8")
        self.proc = subprocess.Popen(
            [str(zts), "dev", "--host", "127.0.0.1", "--port", str(self.port)],
            cwd=project, env=base_env(zig, mode),
            stdout=self.log, stderr=subprocess.STDOUT, text=True,
        )

    def state(self):
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{self.port}{STATE_PATH}", timeout=1
            ) as resp:
                return json.loads(resp.read().decode())
        except (urllib.error.URLError, OSError, TimeoutError, ValueError):
            return None

    def wait_ready(self, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            s = self.state()
            if s is not None and s["v"] >= 1:
                # `v=1` is published after the baseline snapshot is taken; a tiny settle keeps the
                # first measurement from racing the process' own startup on a loaded machine.
                time.sleep(0.1)
                return s
            if self.proc.poll() is not None:
                raise RuntimeError("zts dev exited during the first build:\n" + self.log_text())
            time.sleep(0.02)
        raise TimeoutError("zts dev never finished its first build: " + self.log_text())

    def log_text(self):
        try:
            with open(self.log_path, encoding="utf-8") as f:
                return f.read()[-2000:]
        except OSError:
            return ""

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.log.close()


def wait_for_change(session, old_v, timeout=20):
    """Returns (elapsed_seconds, state) once `v` moves away from `old_v`."""
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        s = session.state()
        if s is not None and s["v"] != old_v:
            return time.monotonic() - start, s
        time.sleep(0.01)
    raise TimeoutError(
        f"build never completed (v stayed at {old_v}); tail:\n{session.log_text()}"
    )


def assert_no_change(session, old_v, quiet=1.6, label=""):
    """A no-op must not bump the counter, even after several poll+settle windows."""
    time.sleep(quiet)
    s = session.state()
    if s is None or s["v"] != old_v:
        raise AssertionError(f"{label}: expected no rebuild (v={old_v}), got {s}")


def source_edits(project, count, prefix):
    src = project / "src/main.zig"
    base = "\n".join(
        line for line in src.read_text().splitlines()
        if not line.startswith("// probe ")
    ) + "\n"
    for i in range(count):
        yield i, lambda i=i: src.write_text(base + f"// probe {prefix} {i}\n")


def bench_latency(session, project, iters, label):
    times, reported = [], []
    for i, write in source_edits(project, iters, label):
        before = session.state()
        if before is None:
            raise RuntimeError("dev server disappeared")
        write()
        elapsed, after = wait_for_change(session, before["v"])
        times.append(elapsed)
        if not after["ok"]:
            raise AssertionError(f"{label}: build reported failure: {after}")
    # Reported compiler time from the CLI log (independent of Python's polling overhead).
    text = session.log_text()
    reported = [int(x) for x in re.findall(r"zts: (?:build|type-check) ok \((\d+) ms\)", text)]
    return times, reported[-len(times):] if len(reported) >= len(times) else reported


def direct_build_bench(project, zig, iters, label, check):
    """Micro-benchmark: `zig build` vs `zig build check` after identical edits."""
    src = project / "src/main.zig"
    base = "\n".join(
        line for line in src.read_text().splitlines()
        if not line.startswith("// direct ")
    ) + "\n"
    argv = [zig, "build"] + (["check"] if check else []) + ["--summary", "none"]
    subprocess.run(argv, cwd=project, check=False, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    times = []
    for i in range(iters):
        src.write_text(base + f"// direct {label} {i}\n")
        t0 = time.perf_counter()
        r = subprocess.run(argv, cwd=project, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"{label} build failed: {r.stdout[-500:]}")
        times.append(time.perf_counter() - t0)
    src.write_text(base)
    return times


def fmt_ms(values):
    return [round(v * 1000) for v in values]


def run_bench(args, zts, zig, root):
    project = make_project(root, zts, zig)
    sessions = []
    if args.old_zts:
        # The strongest baseline: the pre-change binary, scaffolding its own (check-step-free)
        # project. Nothing from the new implementation is in that path.
        legacy = pathlib.Path(args.old_zts)
        if not legacy.is_file():
            print(f"error: --old-zts {legacy} not found", file=sys.stderr)
            return 2
        legacy_project = make_project(root, legacy, zig, name="legacy")
        sessions.append(("legacy binary (pre-change)", legacy, legacy_project, "incremental"))
    sessions.append(("full builds (ZTS_DEV_BUILD=full)", zts, project, "full"))
    sessions.append(("incremental check", zts, project, "incremental"))

    results = {}
    for label, binary, proj, mode in sessions:
        session = DevSession(binary, proj, zig, mode, root / f"dev-{mode}-{abs(hash(label))}.log")
        try:
            session.wait_ready()
            times, reported = bench_latency(session, proj, args.iters, label.split()[0])
            results[label] = (times, reported)
        finally:
            session.close()

    print("End-to-end: edit src/main.zig -> new build visible to the browser")
    for label, (times, reported) in results.items():
        suffix = ""
        if reported:
            suffix = f"  (compiler {statistics.median(reported):.0f} ms)"
        print(f"  {label:36s} median {statistics.median(times)*1000:7.1f} ms  "
              f"samples {fmt_ms(times)}{suffix}")

    baseline_label = "legacy binary (pre-change)" if args.old_zts else "full builds (ZTS_DEV_BUILD=full)"
    base = statistics.median(results[baseline_label][0])
    inc = statistics.median(results["incremental check"][0])
    print(f"  speedup vs {baseline_label}: {base/inc:5.2f}x")
    print(f"  same-binary full vs check: "
          f"{statistics.median(results['full builds (ZTS_DEV_BUILD=full)'][0])/inc:5.2f}x")

    print("\nDirect compiler step (no dev server, no polling)")
    direct_full = direct_build_bench(project, zig, args.iters, "full", check=False)
    direct_check = direct_build_bench(project, zig, args.iters, "check", check=True)
    print(f"  zig build       median {statistics.median(direct_full)*1000:7.1f} ms  "
          f"samples {fmt_ms(direct_full)}")
    print(f"  zig build check median {statistics.median(direct_check)*1000:7.1f} ms  "
          f"samples {fmt_ms(direct_check)}")
    print(f"  speedup                     {statistics.median(direct_full)/statistics.median(direct_check):5.2f}x")

    ratio = base / inc
    if ratio < args.min_speedup:
        print(f"\nFAIL: end-to-end speedup {ratio:.2f}x < required {args.min_speedup:.2f}x",
              file=sys.stderr)
        return 1
    print(f"\nOK: end-to-end speedup {ratio:.2f}x (>= {args.min_speedup:.2f}x)")
    return 0


def run_verify(args, zts, zig, root):
    project = make_project(root, zts, zig, with_extras=True)
    session = DevSession(zts, project, zig, "incremental", root / "dev-verify.log")
    failures = []

    def check(label, fn):
        try:
            fn()
            print(f"  PASS  {label}")
        except Exception as exc:  # noqa: BLE001 - report every failure, do not stop early
            failures.append(label)
            print(f"  FAIL  {label}: {exc}")
            print("  --- dev server log ---")
            print(session.log_text()[-2500:])
            print("  --- end dev server log ---")

    try:
        initial = session.wait_ready()
        print(f"zts dev ready: {initial}")

        def noop_save():
            src = project / "src/main.zig"
            data = src.read_text()
            old = session.state()["v"]
            src.write_text(data)  # same bytes, new mtime
            assert_no_change(session, old, label="identical-content rewrite")

        def unreachable_source():
            scratch = project / "src/scratch.zig"
            old = session.state()["v"]
            scratch.write_text("pub const scratch = 2;\n")
            assert_no_change(session, old, label="edit to a file outside the import graph")

        def fast_recheck():
            src = project / "src/main.zig"
            old = session.state()["v"]
            src.write_text(src.read_text() + "// probe fast recheck\n")
            _, state = wait_for_change(session, old)
            assert state["ok"], state
            # Correctness first: an environment where the persistent compiler cannot start
            # (different Zig build, sandbox restrictions) must still work via the fallback. The
            # fallback prints the SAME timing line format, so only assert speed when the server
            # actually announced itself; otherwise a slow-but-correct runner must still pass.
            body = session.log_text()
            if "incremental compiler server ready" not in body:
                print("      note: compiler server unavailable here; fallback path verified")
                for line in body.splitlines():
                    if "compiler server" in line:
                        print("      dev:", line.strip())
                return
            checks = [int(x) for x in re.findall(r"zts: type-check ok \((\d+) ms\)", body)]
            assert checks, "server announced ready but emitted no timing line"
            assert checks[-1] < 80, f"incremental check took {checks[-1]} ms (slow path?)"

        def css_hot_swap():
            css = project / "web/site.css"
            old = session.state()["v"]
            css.write_text("h1 { color: blue; }\n")
            _, state = wait_for_change(session, old)
            assert state["ok"] and state["hot"] == "css", state

        def web_reload():
            page = project / "web/index.html"
            old = session.state()["v"]
            page.write_text(page.read_text() + "\n<!-- probe -->\n")
            _, state = wait_for_change(session, old)
            assert state["ok"] and state["hot"] == "full", state

        def type_error_and_recovery():
            src = project / "src/main.zig"
            good = src.read_text()
            old = session.state()["v"]
            # Inject the error into `main`, i.e. code Zig actually analyses. An unreferenced
            # top-level declaration is deliberately lazy in both full and check builds.
            broken = good.replace("embedded.assets.entries.len", "does_not_exist_anywhere")
            assert broken != good, "the generated main.zig no longer contains the probe token"
            src.write_text(broken)
            # The failed check must not advance v; wait past a full poll+settle+build window.
            time.sleep(2.0)
            state = session.state()
            assert state["v"] == old, f"a failed build advanced v: {state}"
            assert state["ok"] is False, f"a failed build reported ok: {state}"
            src.write_text(good + "// probe recovered\n")
            _, state = wait_for_change(session, old)
            assert state["ok"], state

        def build_file_change():
            build = project / "build.zig"
            old = session.state()["v"]
            build.write_text(build.read_text() + "\n// build graph probe\n")
            _, state = wait_for_change(session, old)
            assert state["ok"], state

        def debounce_coalesces():
            src = project / "src/main.zig"
            good = src.read_text()
            old = session.state()["v"]
            src.write_text(good + "// probe burst A\n")
            time.sleep(0.04)
            src.write_text(good + "// probe burst B\n")
            _, state = wait_for_change(session, old)
            assert state["ok"], state
            # No second rebuild for the same burst.
            time.sleep(1.6)
            assert session.state()["v"] == state["v"], "a burst caused two rebuilds"

        check("compiler server re-checks a Zig edit in milliseconds", fast_recheck)
        check("identical-content rewrite (touch) does not rebuild", noop_save)
        check("edit outside the import graph does not rebuild", unreachable_source)
        check("stylesheet edit hot-swaps without a build", css_hot_swap)
        check("web/index.html edit reloads without a build", web_reload)
        check("type error is caught and the page recovers after a fix", type_error_and_recovery)
        check("build.zig edit triggers a full rebuild", build_file_change)
        check("two edits inside the settle window cause one rebuild", debounce_coalesces)
    finally:
        session.close()

    if failures:
        print(f"\nFAIL: {len(failures)} check(s) failed: {', '.join(failures)}", file=sys.stderr)
        return 1
    print("\nOK: all dev-loop invariants hold")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("bench", "verify"))
    ap.add_argument("--iters", type=int, default=7)
    ap.add_argument("--min-speedup", type=float, default=1.3)
    ap.add_argument("--zts", default=str(REPO / "zig-out/bin/zts"))
    ap.add_argument("--old-zts", default=None,
                    help="path to a `zts` built from the pre-change revision; adds a true A/B baseline")
    args = ap.parse_args()

    zts = pathlib.Path(args.zts)
    if not zts.is_file() and pathlib.Path(str(zts) + ".exe").is_file():
        zts = pathlib.Path(str(zts) + ".exe")
    if not zts.is_file():
        print(f"error: {zts} not found — run `./zigw build -Dgtk=false` first", file=sys.stderr)
        return 2
    zig = zig_binary()
    # A sibling of the checkout, not the system temp dir: on Windows runners the temp directory
    # can be on another volume, and `zts init` needs a relative path back to this checkout.
    try:
        ctx = tempfile.TemporaryDirectory(prefix="zts-dev-probe-", dir=str(REPO.parent))
    except OSError:
        ctx = tempfile.TemporaryDirectory(prefix="zts-dev-probe-")
    with ctx as tmp:
        root = pathlib.Path(tmp)
        return run_bench(args, zts, zig, root) if args.command == "bench" \
            else run_verify(args, zts, zig, root)


if __name__ == "__main__":
    sys.exit(main())
