# Getting `zts` on your machine

> **Audience**: readers who do not have `zts` yet.
> **Time**: 3 minutes (Linux / macOS / Windows).

`zts` is the CLI for building Z-Ts apps — roughly where Angular CLI sits. Learn four verbs
(`init`, `dev`, `build`, `doctor`) and you can go from an empty directory to a single binary.

> [!TIP]
> This page is for the install in detail. If you would rather have something running, see
> [Your first ten minutes](../start.md) — its steps 1–2 cover the same ground in four minutes.

> Building and testing the **Z-Ts repository itself** is documented in
> [`docs/contributing/README.md`](../../../contributing/README.md). This page stops at "I have a
> `zts` command".

---

## 1. Build it from a checkout (currently the only way)

There are no published binaries yet, so build from source.

```bash
git clone https://github.com/umiturtle/Z-Ts.git
cd Z-Ts
./zigw build            # installs Zig 0.17 and produces zig-out/bin/zts
```

Put the result on `PATH` and it works outside the repository.

```bash
mkdir -p ~/.local/bin
cp zig-out/bin/zts ~/.local/bin/
export PATH="$HOME/.local/bin:$PATH"
zts version             # → zts 0.1.0
```

> `./zigw` needs only Python 3.8+ and installs Zig 0.17.0 into `/tmp` (a fresh container installs
> it again). If you already have `zig`, plain `zig build` produces the same binary.

## 2. The Zig that `zts` uses

At build time `zts` remembers **the checkout it was built from** and writes that relative path
into the `build.zig.zon` of every project it generates. At run time it spawns `zig` as a child
process, so **a 0.17-series `zig` must be on `PATH`**.

```bash
export ZTS_ZIG="$(./zigw zig-path)"   # once, inside the checkout: the Zig this repo uses
zts doctor                            # checks zig / z_ts / package / dependency / web
```

`all checks passed` means you are done.

## 3. You moved the checkout (or want a different one)

Copy `zts` to another machine and the remembered path no longer exists. `zts doctor` says so:

```text
  z_ts         MISSING at /home/you/Z-Ts — rebuild zts or pass --zts-path
```

Three fixes.

| Approach | Command |
|---|---|
| put a checkout at that path | `cp -r Z-Ts /home/you/Z-Ts` |
| pass the path while generating | `zts init my-app --zts-path /path/to/Z-Ts` |
| rewrite an existing project | `.z_ts = .{ .path = "…" }` in `build.zig.zon` |

Rebuilding `zts` from the new checkout is the most reliable option.

## 4. Per-platform prerequisites

| OS | Needed | Note |
|---|---|---|
| Linux | GTK3 + WebKit2GTK 4.1 (`libgtk-3-dev libwebkit2gtk-4.1-dev`) | without them `zts build` drops the GTK backend |
| macOS | Xcode Command Line Tools | the Cocoa backend uses the macOS SDK |
| Windows | WebView2 Runtime (bundled with Windows 11) | a single `.exe`, no DLLs to ship |

Zig is a child process: **0.17 on `PATH` (or in `ZTS_ZIG`) is assumed**, and `zts` never bundles
its own compiler.

---

## Next

- Your first app: [Build a counter](../tutorials/counter.md)
- Every command and flag: [`docs/reference/cli.md`](../../../reference/cli.md)
- Something is broken: [Troubleshooting](troubleshooting.md)
