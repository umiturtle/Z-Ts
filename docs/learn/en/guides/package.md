# Packaging for distribution (`zts package`)

> **Audience**: readers who want to hand their app to someone else (`.deb` / `.dmg` / `.exe`).
> **Time**: 15 minutes.

`zts build` stops at "an executable that runs". This guide takes it to **something you can hand
over**: a `.deb`, an AppDir, a `.app`, a `.dmg`, an `.exe` with an icon, or a portable `.tar.gz`.

```bash
zts build            # produce the executable
zts package          # wrap it in the host OS's default format
```

Output lands in `<project>/zig-out/package/`.

> `zts package` only wraps an executable; it never builds one. Run `zts build` first, or it stops
> with `zig-out/bin/<name> not found — run zts build first`.

---

## 1. What each host can produce

| Host | `deb` | `appdir` | `app` | `dmg` | `exe` | `tar.gz` |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Linux | ✅ | ✅ | ✅ | ❌ | ✅ (given a PE) | ✅ |
| macOS | ✅ | ✅ | ✅ | ✅ | ✅ (given a PE) | ✅ |
| Windows | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |

* `dmg` calls macOS `hdiutil`, so it is macOS-only.
* Everything else is **host-independent**: a Windows `.exe` can be built on Linux (cross-build
  plus `--format exe`).
* "given a PE" means an executable built with `zts build --target x86_64-windows`. If the format
  and the binary disagree, packaging stops before writing anything.

---

## 2. Produce one artefact first

```bash
zts build
zts package
ls zig-out/package/
```

On Linux you get one `.deb`, on macOS one `.app`, on Windows one `.exe`. Ask for several with a
comma-separated `--format`.

```bash
zts package --format deb,appdir,tar.gz
zts package --format app,dmg --icon icon.png
```

Existing output is overwritten. `--out` writes somewhere else.

```bash
zts package --out dist
```

---

## 3. Name, version, icon

The package name comes from `.name` in `build.zig.zon` and the version from `.version`. Override
them with flags.

```bash
zts package --version 1.2.0 --maintainer "Your Name <you@example.com>"
```

Without `--maintainer`, `ZTS_MAINTAINER` is read; with neither, a placeholder is used and a warning
is printed (always set it for a published package).

| Icon | Format | How to make one |
|---|---|---|
| `deb` / `appdir` / `app` | PNG (256×256 recommended) | `magick icon.svg -resize 256x256 icon.png` |
| `exe` | `.ico` (several sizes: 16/32/48/256) | `magick icon.png -define icon:auto-resize=256,48,32,16 icon.ico` |

```bash
zts package --icon icon.png --icon-ico icon.ico --manifest app.manifest
```

`.icns` is not needed: the macOS bundle holds `Contents/Resources/<name>.png` (fine for
development builds; use `iconutil` if you need an App Store `.icns`).

---

## 4. Linux

### Installing the `.deb`

```bash
sudo dpkg -i zig-out/package/my_app_0.1.0_amd64.deb
my_app
sudo dpkg -r my-app        # underscores become hyphens in the package name
```

What goes in:

```text
/usr/bin/<name>
/usr/share/applications/<name>.desktop
/usr/share/icons/hicolor/128x128/apps/<name>.png   (when --icon is given)
/usr/share/doc/<name>/copyright
```

`Architecture:` is read from the executable header, so a `--target aarch64-linux` build becomes
`arm64` instead of being mislabelled `amd64`.

`Depends:` comes from **the libraries the executable actually links**. An app that opens no window
does not drag in GTK. A GTK/WebKitGTK app gets `libgtk-3-0, libwebkit2gtk-4.1-0`.

### Turning an AppDir into an AppImage

`appdir` is the input format AppImage expects. With `appimagetool` it is one command.

```bash
zts package --format appdir --icon icon.png
appimagetool zig-out/package/my-app-0.1.0-amd64.AppDir my-app.AppImage
chmod +x my-app.AppImage && ./my-app.AppImage
```

The AppDir also runs on its own (`AppRun` calls the executable).

```bash
./zig-out/package/my-app-0.1.0-amd64.AppDir/AppRun
```

### A portable `.tar.gz`

```bash
zts package --format tar.gz
tar -xzf zig-out/package/my-app-0.1.0-amd64.tar.gz
./my-app-0.1.0/my-app
```

`<name>-<version>/` contains the executable, the `.desktop` file and the icon.

---

## 5. macOS

```bash
zts build
zts package --format app --icon icon.png
open zig-out/package/My\ App.app
```

`CFBundleIdentifier` comes from `--identifier` (default `com.example.<name>`). When launched from
Finder, the **display name** (`my_app` → `My App`) is the bundle name.

A `.dmg` wraps an existing `.app`.

```bash
zts package --format dmg --icon icon.png
open zig-out/package/My\ App-0.1.0.dmg
```

Distributed `.dmg` / `.app` files are **not signed**. If a recipient is stopped by Gatekeeper they
can clear it with `xattr -dr com.apple.quarantine <app>`. Real distribution needs `codesign` and
`notarytool`, which `zts` does not call.

---

## 6. Windows

The icon and manifest are **embedded into an already-built `.exe`**.

```bash
zts build --target x86_64-windows
zts package --format exe --icon-ico icon.ico --manifest app.manifest
```

A minimal `app.manifest` (declaring per-monitor DPI awareness):

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="MyApp" version="1.0.0.0"/>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">permonitorv2</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
```

You can tell it worked because Explorer shows the new icon for `my_app.exe`.

---

## 7. Wrapping a cross-built executable

After `zts build --target <triple>` you can just run `zts package`. The architecture is read from
the executable, which is why there is no `--arch` flag.

```bash
zts build --target aarch64-linux      # zig-out/bin/my_app
zts package --format deb,tar.gz       # my_app_0.1.0_arm64.deb and friends
```

`--binary` points at a different executable.

```bash
zts package --binary path/to/other-exe --format tar.gz
```

---

## 8. Shipping from CI

Keep build and package in one job and upload the output as-is.

```yaml
- run: zts build
- run: zts package --format deb,tar.gz --icon icon.png
- uses: actions/upload-artifact@v4
  with:
    name: packages-${{ runner.os }}
    path: zig-out/package/*
```

For getting `zts` itself, see [Install](install.md).

---

## 9. Usual traps

| Message | Meaning and fix |
|---|---|
| `zig-out/bin/<name> not found — run zts build first` | nothing was built. Run `zts build`; rebuild after changing `--target` |
| `--format exe needs a Windows PE image` | `--format exe` is PE-only; build with `zts build --target x86_64-windows` |
| `--format deb needs a POSIX executable, got a PE image` | you are wrapping a Windows build in a Linux format; match the format to the target |
| `--format dmg needs macOS` | `dmg` is macOS-only; use `app` elsewhere |
| `the executable is not an ELF, Mach-O or PE image` | `--binary` points at something that is not an executable (a script, for instance) |
| `unknown format 'foo'` | pick one of `deb` / `appdir` / `app` / `dmg` / `exe` / `tar.gz` |
| `names are [a-z][a-z0-9_-]*` | the package name breaks the convention; fix `.name` in `build.zig.zon` or regenerate with `zts init` |
| `no --maintainer (or ZTS_MAINTAINER)` | pass `--maintainer "Name <email>"` before publishing |

The same input produces **the same bytes** (timestamps are fixed). Rebuilding does not change the
`.deb` hash, so this doubles as a release reproducibility check.

---

## Next

- Every flag: [`docs/reference/cli.md`](../../../reference/cli.md#zts-package)
- Back to the tutorial: [Build a counter](../tutorials/counter.md)
- How it works inside (why PE rewriting, and so on):
  [`docs/architecture/packaging-and-bench.md`](../../../architecture/packaging-and-bench.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
