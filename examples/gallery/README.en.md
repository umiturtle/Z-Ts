# `examples/gallery` — screenshot regression gallery

A set of deterministic screens used to compare rendering across OSes, frameworks and releases.
Every pattern is captured as a PNG and listed in `manifest.json` with its layout fingerprint.

## Usage

```bash
zig build gallery                 # build and capture (Linux: use Xvfb)
node scripts/verify-screenshots.mjs --require-native --require-counts 17 --require-zig
node scripts/compare-screenshots.mjs   # 3-OS pixel comparison
```

The CI "Cross-OS parity" job runs the same checks on Linux, macOS and Windows and fails on a single
different pixel at the same resolution.

## The 17 patterns

Typography (weights, kerning, CJK + Latin fallback), flex and grid layouts, borders and radii,
gradients, SVG icons, form controls, overflow and scrollbars, fixed/absolute positioning, z-order,
opacity, transforms, shadows, tables, and a composite "real app" screen. Each one targets a class
of rendering difference rather than looking impressive.

## Fonts (the key to identical pixels)

One font archive is shipped with the demo and loaded explicitly, with a single CSS font stack.
System font substitution is the most common source of cross-OS differences; the build checks font
coverage before capturing.

## Layout fingerprint

Alongside each PNG, a compact JSON records element boxes, computed font family/size and scroll
metrics. Comparing the fingerprint first tells you whether a difference is layout (CSS/font) or
actual rasterisation, which makes failures much faster to diagnose.

### CSS invariants for deterministic typesetting

- No `Date.now()`, random ids, CSS animations or transitions in a captured frame.
- Explicit `width`/`height`, `line-height` and `font-family`; no `auto` where it can vary.
- Wait for the app's "ready" signal, never a fixed `sleep`.
- Capture through the same PNG encoder on all three OSes.

## The nine demos really run Zig (`ipc://`)

The counter in each framework demo uses that framework's local state, but the `.zigbar` strip below
it **cannot be filled in without Zig**. Static HTML (the published Pages demos, or the `zts dev`
browser) shows `ZIG OFFLINE` with disabled buttons; the native gallery shows `ZIG ONLINE`, a
16-character seal and a counter owned by Zig.

- Besides `tauri`, the host registers the **`ipc` scheme** and answers `zig_probe` / `zig_inc` /
  `zig_dec` as `application/json` with `Tauri-Response: ok` and CORS headers (WebView2 maps this
  to `http://ipc.localhost/<cmd>`).
- At `DOCUMENT_START` it injects the **unmodified** `src/tauri/js_bootstrap.zig` — so
  `window.__TAURI_INTERNALS__.invoke` is exactly what `@tauri-apps/api` v2 expects — plus
  [`src/web/zig-bridge.js`](src/web/zig-bridge.js), which defines `window.__ZTS_ZIG__` and is
  called from every framework's own lifecycle hook.
- The seal is the first eight bytes of `Sha256(a secret held only by Zig || command || count)`.
  Neither the secret nor the computation ships in a static file. No clock and no randomness are
  used, so the initial frame is identical on all three OSes.
- If `fetch('ipc://…')` is unavailable, the bootstrap's `__ztsPostMessage` fallback is answered
  by the same three Zig commands (the promise is resolved with `evalJs`).
- The nine manifest entries carry `zig_online`; `verify-screenshots.mjs --require-zig` fails
  unless every one is `true`.

## The custom scheme is `tauri://` (important)

The WebView loads the app from the custom scheme, not from `file://`; relative assets must be
resolved against that base. `@tauri-apps/api` v2 is used unmodified.

## Waiting for readiness

The host signals readiness after the first layout and font load. The capture script waits for that
signal and for `document.fonts.ready` before reading pixels.

## Output

```text
zig-out/gallery/
├── <pattern>.png
├── manifest.json
└── layout-fingerprints.json
```

See [the framework demos](../frameworks/README.en.md) and
[the capture ADR](../../docs/decisions/0009-screenshot-capture-and-ci-gallery.md) (Japanese,
internal).
