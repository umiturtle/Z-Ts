# `examples/frameworks` — nine frameworks, one screen

Nine frontend frameworks render **the same screen** so their output can be compared, and so Z-Ts's
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

## What this demo proves

1. `embedFrontend` (or `exportStaticSite`) accepts the output of any of these bundlers unchanged.
2. Relative asset paths still resolve when served from memory or from a static host.
3. Inline scripts get CSP hashes automatically; no `unsafe-inline` is needed.
4. A fixed font set plus deterministic CSS gives byte-identical screenshots on three OSes.

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
