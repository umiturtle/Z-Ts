# Troubleshooting (repository development)

> **Audience**: contributors whose checkout, CI or screenshot run is failing.
> **Time**: find your symptom in the table, then read only that section.

App-author problems (`zts` errors, a missing `web/`) belong in
[the app troubleshooting guide](../learn/en/guides/troubleshooting.md). This page is about the
repository itself.

## Run these first

```bash
bash scripts/status.sh
./zigw quick-test
python3 scripts/check-docs.py && ./zigw fmt --check src/ build.zig build.zig.zon
./zigw docs-check
```

The [`../../AGENTS.md`](../../AGENTS.md) 30-second routine and
[`../environment/arena-and-caching.md`](../environment/arena-and-caching.md) explain why a cold
container behaves differently.

## Build / toolchain

**`error: FileNotFound` — Zig is missing.** `zigw` downloads Zig into a temporary directory; if that
is blocked, put Zig 0.17.0 on `PATH` or set `ZTS_ZIG`. A cold container has no `~/.cache/zig`, so the
first build is always the slow one.

**`zig build` takes more than 90 seconds cold.** That is the `std.Build` runner compiling itself, not
your code. Use `./zigw quick-test` locally and let persistent CI caches handle `zig build test`.

**`-Dgtk=true` cannot find headers.** Install GTK3 + WebKit2GTK 4.1, or use
`bash scripts/setup-toolchains.sh --sysroot`. The core packages are Pure Zig (`link_libc = false`);
only the native boundary needs those headers.

## Tests

| Symptom | Cause / fix |
|---|---|
| `expected type '*Build.Step', found '*const *Build.Step'` | Zig 0.17 changed the `std.Build` API; the dependency takes a mutable pointer. See [`../architecture/build-tools.md`](../architecture/build-tools.md) |
| `bindings.gen.ts is stale` | Regenerate the bindings from `Schema`; the file is generated, never hand-edited |
| `error: invalid fingerprint: 0x…` in `build.zig.zon` | `zts init` rewrites it after one build; do not copy the fingerprint between projects |
| `error: WriteFailed` out of `Allocator.Error!` | Zig 0.17's `Io.Writer` errors are separate from allocation errors; widen the error set |
| `std.time.timestamp()` does not exist | Use `std.Io` clocks / `std.time` equivalents in 0.17 |

## Native WebView

**Text renders as tofu on Linux, or differs between OSes.** Ship one font with the demo and set the
same CSS font stack everywhere; see [`../architecture/screenshot-parity.md`](../architecture/screenshot-parity.md)
and [`../../examples/frameworks/README.en.md`](../../examples/frameworks/README.en.md).

**Screenshots are black or cannot be captured.** Use `Xvfb` on Linux, wait for the "ready" signal
instead of a fixed sleep, and capture through the same PNG encoder on all three OSes.

**The macOS C shim will not cross-build.** The `.m` shim is compiled only for a macOS host; CI runs
it in the macOS job. Do not add a target-specific `if` to shared Zig code.

## Documentation site

| Symptom | Cause / fix |
|---|---|
| `docsite: N broken link(s)` | a renamed page or a wrong relative path; `zig build docs` verifies every link before writing |
| Search returns 0 hits | `assets/search-index.js` was not regenerated, or the page is `.internals` / `.hidden` by design |
| Pages deployment is skipped (`Pages not enabled`) | `actions/configure-pages` needs `enablement: true` and a token with the right permissions; the `GITHUB_TOKEN` cannot enable it |
| `docs/INDEX.md: does not link …` (rule 11) | add a row to **both** language indexes |
| `does not say 'およそ 95 分'` (rule 12) | the step minutes changed in `learn_path.zig`; update README, the index and both hubs |
| `… missing translation` (rule 8) | `docs/learn/ja` and `docs/learn/en` must hold identical file names |
| `missing counterpart / verification stamp` (rule 13) | add the `.en.md` mirror and re-run `python3 scripts/check-docs.py --sync` |

The full symptom list with commands is in [`../environment/github-actions.md`](../environment/github-actions.md)
and [`../environment/arena-and-caching.md`](../environment/arena-and-caching.md) (Japanese, internal).

## Frontend

**`bindings.gen.ts` disagrees with `@tauri-apps/api` types.** The generator is the source of truth;
the package is used unmodified. Regenerate, do not patch the `.d.ts`.

**A Vite build embeds as a blank page.** Every relative asset path must survive being served from
memory; use `embedFrontend` and check the CSP hashes of inline scripts.

## CI

| Symptom | Cause / fix |
|---|---|
| `gh run view --log` fails with `EOF` | logs are redirected to a blocked host; use [`../../scripts/ci-logs.sh`](../../scripts/ci-logs.sh) via `api.github.com` |
| Windows only: `error.Unexpected NTSTATUS=0xc000000d` | a handle was passed across the FFI boundary with the wrong representation; check the Win32 shim |
| `tar -tzf … \| grep -q …` fails with "write error" | `grep -q` closes the pipe early; capture to a variable first |
| Only the 3-OS pixel comparison fails | compare the layout fingerprint and the font set before suspecting rendering |

## Where to go next

- Repository commands: [`README.en.md`](README.en.md)
- App-author troubleshooting: [`../learn/en/guides/troubleshooting.md`](../learn/en/guides/troubleshooting.md)
- Tutorials: [`../learn/en/tutorials/index.md`](../learn/en/tutorials/index.md)
- [`../../AGENTS.md`](../../AGENTS.md) and [`../../scripts/ci-logs.sh`](../../scripts/ci-logs.sh)
