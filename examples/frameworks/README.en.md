# `examples/frameworks` — nine frameworks, one screen

Nine frontend frameworks render **the same screen** so their output can be compared, and so ziggurats's
embedding path is exercised with real bundler output rather than a hand-written HTML file.

| Framework | Output used |
|---|---|
| Angular | browser build |
| SolidJS | static build |
| Next.js | `out/` (static export) |
| React | Vite build |
| Astro | `dist/` |
| Nuxt | generated static output |
| Svelte | static build |
| SvelteKit | static adapter |
| SolidStart | static output |

The point is not "which framework is best" but **the same pixels**: with one font set and one CSS
layout, the screenshots must be identical across frameworks and across Linux, macOS and Windows.

## Regenerate

```bash
# this one script installs dependencies and builds all nine (network required)
node scripts/gen-framework-demos.mjs
```

The generated sites are published with the documentation site under
`examples/frameworks/<name>/`, so the SSG output of the examples is browsable on GitHub Pages too.


## Tutorials (pick your library)

Every example has a **branch of the same counter tutorial**. The Zig side is shared; only the
frontend idiom changes. The plain-JS original is
[Build a counter](../../docs/learn/en/tutorials/counter.md), and the hub is
[Choose a library](../../docs/learn/en/tutorials/frameworks.md).

| Library | Example | Tutorial | Live demo |
|---|---|---|---|
| React | [`react/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/react) | [Build a counter](../../docs/learn/en/tutorials/counter-react.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/react/index.html) |
| Solid | [`solid/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/solid) | [Build a counter](../../docs/learn/en/tutorials/counter-solid.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/solid/index.html) |
| Svelte | [`svelte/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/svelte) | [Build a counter](../../docs/learn/en/tutorials/counter-svelte.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/svelte/index.html) |
| Angular | [`angular/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/angular) | [Build a counter](../../docs/learn/en/tutorials/counter-angular.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/angular/index.html) |
| Next.js | [`next/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/next) | [Build a counter](../../docs/learn/en/tutorials/counter-next.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/next/index.html) |
| Nuxt | [`nuxt/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/nuxt) | [Build a counter](../../docs/learn/en/tutorials/counter-nuxt.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/nuxt/index.html) |
| Astro | [`astro/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/astro) | [Build a counter](../../docs/learn/en/tutorials/counter-astro.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/astro/index.html) |
| SvelteKit | [`sveltekit/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/sveltekit) | [Build a counter](../../docs/learn/en/tutorials/counter-sveltekit.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/sveltekit/index.html) |
| SolidStart | [`solidstart/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/solidstart) | [Build a counter](../../docs/learn/en/tutorials/counter-solidstart.md) | [Open demo](https://umiturtle.github.io/Z-Ts/examples/frameworks/solidstart/index.html) |

## Links to the published demos

`zig build docs` publishes each framework's static output on Pages
([demo index](https://umiturtle.github.io/Z-Ts/examples/frameworks/index.html)).
If the repository is renamed, replace the base URL in this one table.

| Framework | Demo | Framework | Demo |
|---|---|---|---|
| Angular | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/angular/index.html) | Astro | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/astro/index.html) |
| Next.js | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/next/index.html) | Nuxt | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/nuxt/index.html) |
| React | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/react/index.html) | SolidJS | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/solid/index.html) |
| SolidStart | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/solidstart/index.html) | Svelte | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/svelte/index.html) |
| SvelteKit | [open](https://umiturtle.github.io/Z-Ts/examples/frameworks/sveltekit/index.html) | — | — |

For the screenshot regression itself see
[`examples/gallery/README.en.md`](../gallery/README.en.md) and
[`docs/architecture/screenshot-parity.md`](../../docs/architecture/screenshot-parity.md).

## What this demo proves

1. `embedFrontend` (or `exportStaticSite`) accepts the output of any of these bundlers unchanged.
2. Relative asset paths still resolve when served from memory or from a static host.
3. Inline scripts get CSP hashes automatically; no `unsafe-inline` is needed.
4. A fixed font set plus deterministic CSS gives byte-identical screenshots on three OSes.
5. The `.zigbar` strip cannot be filled in without the Zig backend (below).

## The part that only works when Zig is running

The counter itself uses each framework's local state so you can compare idioms. The `.zigbar` strip
underneath it is the opposite: **static HTML can never fill it in**. That is what makes "is Zig
actually running back there?" visible on screen instead of being a matter of trust.

| What you see | Behind the page |
|---|---|
| red `ZIG OFFLINE`, `+` / `-` disabled | published demo / the `zts dev` browser: no `window.__ZTS_ZIG__`, no `invoke` |
| green `ZIG ONLINE`, 16-character seal, `+` / `-` enabled | Zig answers `zig_probe` / `zig_inc` / `zig_dec` over `ipc://` |

The seal is the first eight bytes of SHA-256 over **a secret held only by the Zig binary** and Zig's
own counter. Neither the secret nor the computation ships in any static file, so JavaScript cannot
forge it. `+` / `-` mutate the counter owned by Zig, not the framework's local state, and each press
produces a new seal. No clock and no randomness are involved, so the initial frame is byte-identical
and pixel-identical on all three OSes.

The host side is real code: [`examples/gallery/src/main.zig`](../gallery/src/main.zig) registers the
`ipc` scheme and the three commands, while
[`examples/gallery/src/web/zig-bridge.js`](../gallery/src/web/zig-bridge.js) is injected at
`DOCUMENT_START`. Both use the unmodified `js_bootstrap` `window.__TAURI_INTERNALS__.invoke`. CI
fails unless all nine manifest entries report `zig_online: true`
(`scripts/verify-screenshots.mjs --require-zig`).

## Build notes per framework

| Family | Watch out for |
|---|---|
| Next / Nuxt / SvelteKit / SolidStart | use the static export target; an SSR server cannot be embedded |
| Angular / React / Svelte / SolidJS | set a relative `base` so assets resolve under a subpath |
| Astro | `dist/` is already static; do not add a trailing-slash rewrite |

## Measured gotchas

- A trailing slash difference changes relative paths: normalise every route before embedding.
- Fonts are the usual cause of cross-OS differences; ship one font and one explicit font stack.
- `Date.now()`, random ids and animation timing must not appear in the rendered page — determinism
  is a requirement of the screenshot gate.

See [the screenshot parity design](../../docs/architecture/screenshot-parity.md) (Japanese,
internal) and [the gallery](../gallery/README.en.md) for the regression images.
