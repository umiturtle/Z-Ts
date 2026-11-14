# ziggurats Counter — one project, three artefacts

A showcase sample: the **same application logic** produces a native desktop binary, a browser Live
Preview, and a static site — with **zero target-specific branches**.

| Artefact | Where it runs | State lives in | Host implementation |
|---|---|---|---|
| `desktop` | OS WebView | in-process | `WebviewHost` (GTK3 / Cocoa / Win32 / HeadlessMock) |
| `preview` | browser + HTTP/SSE | in the Zig process | `BridgeHost` |
| `dist` | any static host | in the browser (WASM) | `WasmHost` |

The frontend (`web/main.ts`) uses **unmodified `@tauri-apps/api` v2** — only `invoke` and `listen`,
with no environment checks beyond displaying a `mode` field.

## 1. Directory layout

```text
examples/counter/
├── build.zig                 three artefact steps, one shared app module
├── src/app.zig               THE application logic (the only file with commands and state)
├── src/desktop.zig           entry point: .desktop
├── src/live.zig              entry point: .bridge
├── src/wasm_app.zig          entry point: .wasm
├── src/ssg_export.zig        writes dist/
├── src/bindings_schema.zig   the Schema used to generate TypeScript types
└── web/                      the frontend (identical for all three)
```

`app.zig` is generic over a comptime `RuntimeMode`. The three entry points instantiate the same
`App(mode)` with a different `Host`, so there is no `if (target)` anywhere in the app code.

## 2. How "zero branches" works

| Layer | What varies | What does not |
|---|---|---|
| build | target triple, `Host` implementation | `src/app.zig`, `web/` |
| run | how `invoke` reaches Zig (`ipc://`, HTTP, function call) | command names, argument types, return values |
| state | where the bytes live | the `State` struct and its invariants |

`Schema` is comptime-generated once, so the TypeScript bindings, the router and the tests all agree.

## 3. Commands (RPC)

| Command | Meaning |
|---|---|
| `getSnapshot` | returns `{ count, step, mutations, mode }` |
| `increment` / `decrement` | change the count by `step` and emit `counter:changed` |
| `setStep` | change the increment (clamped to the `i53` range) |
| `reset` | back to zero |

`step` and `count` stay inside JavaScript's safe-integer range (`i53`), so no precision is lost on
the wire. The `counter:changed` event is delivered from Zig to the page, which re-reads the snapshot.

## 4. Serving the static site (`zig-out/dist/`)

```bash
zig build dist       # -> zig-out/dist/
```

`src/ssg_export.zig` calls `exportStaticSite` with the embedded frontend, the `app.wasm` bytes and a
prerendered route. The result is plain HTML + JS + fonts + WASM, plus `_zts/manifest.json`, a SPA
`404.html`, `.nojekyll` and `_headers`. No server, no Node, no runtime process.

## 5. Tests (`zig build test`)

Unit tests cover the commands and state invariants; the Live Preview E2E test drives the HTTP/SSE
bridge; the WASM E2E test runs the same commands in a browser-like host. CI builds all three on
Linux, macOS and Windows and compares the screenshots.

## 6. Constraints and next steps

- `@tauri-apps/api` v2 is used unmodified; the frontend makes no target checks.
- `zts_webview` depends only on `zts_foundation`; `zts_tauri` sets `link_libc = false`.
- At the same resolution, screenshots must match pixel-for-pixel across OSes (CI gate).

See [the tutorials](../../docs/learn/en/tutorials/index.md) to build a smaller version yourself,
[static-site guide](../../docs/learn/en/guides/static-site.md) for `exportStaticSite`, and
[the API reference](../../docs/api/index.html) for the declarations.

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
