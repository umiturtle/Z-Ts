# Getting `zts` on your machine

> **Audience**: readers who do not have `zts` yet.
> **Time**: 3 minutes (Linux / macOS / Windows).
> **Requirement**: Zig 0.17. `zts` does not bundle a compiler — it runs yours.

`zts` is the CLI for building ziggurats apps — roughly where Angular CLI sits. Learn four verbs
(`init`, `dev`, `build`, `doctor`) and you can go from an empty directory to a single binary.

What we distribute is **one `zts` binary**. It carries no compiler, so put a 0.17-series `zig` on
`PATH` as well. **Those two files are the whole toolchain** an app author needs.

> [!TIP]
> This page is for the install in detail. If you would rather have something running, see
> [Your first ten minutes](../start.md) — its steps 1–2 cover the same ground in four minutes.

---

## 1. Install the binary

Download one file for your OS from [GitHub Releases](https://github.com/umiturtle/ZigguraTs/releases)
(named like `zts-0.1.1-linux-x86_64`). About 300 KB, **a single binary with no libc dependency** —
nothing to put beside it.

```bash
# Linux / macOS (pick the name that matches your machine, e.g. `linux-aarch64`)
curl -LO https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/zts-0.1.1-linux-x86_64
chmod +x zts-0.1.1-linux-x86_64
mkdir -p ~/.local/bin
mv zts-0.1.1-linux-x86_64 ~/.local/bin/zts
export PATH="$HOME/.local/bin:$PATH"
zts version             # → zts 0.1.1
```

```powershell
# Windows (PowerShell)
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest `
  https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/zts-0.1.1-windows-x86_64.exe `
  -OutFile "$HOME\bin\zts.exe"
$env:PATH = "$HOME\bin;$env:PATH"
zts version
```

Every release ships `SHA256SUMS`; use it only if you want to check the download.

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

## 2. Put `zig` on `PATH`

`zts` only spawns `zig build` — it carries no compiler. Install a 0.17-series `zig` and make sure it
is on `PATH` ([ziglang.org/download](https://ziglang.org/download/)).

```bash
zig version             # → 0.17.0
zts doctor              # with a release binary the checkout line reads "(none — release build)"
```

If Zig lives somewhere else, point at it once:

```bash
export ZTS_ZIG=/opt/zig/zig
```

## 3. Your first project

```bash
zts init my-app
cd my-app
zts build
./zig-out/bin/my_app    # .\zig-out\bin\my_app.exe on Windows
```

The **first** `zts build` fetches the ziggurats source archive, because the generated `build.zig.zon`
contains this line (baked into the binary — you never type it):

```zig
.z_ts = .{ .url = "https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz", .hash = "z_ts-0.1.1-…" },
```

Zig caches what it fetched, so later builds work offline. **You do not need a checkout of ziggurats.**

> You can inspect the archive yourself:
> `zig fetch https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz`

## 4. Building `zts` from a checkout

If you are changing ziggurats itself, or would rather not use a published binary, build from source.
Bring your own `zig`.

```bash
git clone https://github.com/umiturtle/ZigguraTs.git
cd Z-Ts
zig build                # → zig-out/bin/zts (needs Zig 0.17 on PATH)
```

A `zts` built this way **remembers its checkout**: every project it scaffolds gets a relative path
in `build.zig.zon`.

```zig
.z_ts = .{ .path = "../../../home/you/Z-Ts" },
```

Move the checkout and existing projects lose that path. Pick one fix:

| Fix | Command |
|---|---|
| scaffold again, pointing at the release | `zts init my-app --zts-url <url> --zts-hash <hash>` |
| scaffold again, pointing at a checkout | `zts init my-app --zts-path /path/to/Z-Ts` |
| repair a project in place | change `.z_ts` in `build.zig.zon` to `.url`+`.hash` or a new `.path` |
| rebuild `zts` | `zig build` in the new checkout |

> Building and testing the repository itself (CI, scripts, generating the documentation site) is a
> **developer** workflow, described in
> [`../../contributing/README.md`](../../../contributing/README.md). You do not need any of it to
> build apps.

## 5. Per-platform prerequisites

| OS | Needed | Note |
|---|---|---|
| Linux | GTK3 + WebKit2GTK 4.1 (`libgtk-3-dev libwebkit2gtk-4.1-dev`) | without them `zts build` drops the GTK backend |
| macOS | Xcode Command Line Tools | the Cocoa backend uses the macOS SDK |
| Windows | WebView2 Runtime (bundled with Windows 11) | a single `.exe`, no DLLs to ship |

---

## Next

- Your first app: [Build a counter](../tutorials/counter.md)
- Every command and flag: [`docs/reference/cli.md`](../../../reference/cli.md)
- Something is broken: [Troubleshooting](troubleshooting.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
