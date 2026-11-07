# Package layout — six layers, three artefacts

> **Audience**: readers who want to know where code belongs and why the split is what it is.
> **Time**: 5 minutes.

The three parts you saw on the [previous page](index.md) — the page, the bridge, the command — are
really **six packages**. This page is the map. There is exactly one reason for the split: producing
**three artefacts from one source**.

## The dependency graph on one screen

Dependencies point **downwards only**. Nothing ever reaches back up.

```text
  ┌──────────────────────────────────────────────┐
  │ your app (src/main.zig + web/)               │
  └──────────────────────────────────────────────┘
        │                  │                  │
        ▼                  ▼                  ▼
  zts_webview         zts_bridge          zts_wasm
  (the OS WebView)    (HTTP + SSE)        (WebAssembly)
        │                  │                  │
        └──────────┬───────┴──────────────────┘
                   ▼
              zts_tauri        … Tauri v2's protocol and the seven plugins
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
   zts_core     zts_rpc    zts_ssg     … pure Zig, no OS calls
        │          │
        ▼          ▼
     zts_web   zts_foundation             … the smallest floor
```

| Package | Job | Depends on | libc |
|---|---|---|---|
| `zts_foundation` | time, IDs, logs, byte helpers | none | no |
| `zts_web` | HTML/CSS/JS in memory (`Assets`, MIME, CSP hashes) | foundation | no |
| `zts_core` | the `Host` abstraction (windows, events, IPC door) | foundation, web | no |
| `zts_rpc` | command definitions, type checks, JSON, TypeScript output | foundation | no |
| `zts_bridge` | an HTTP/1.1 + SSE server bridging a browser and Zig | foundation, web, core, rpc | no |
| `zts_tauri` | the Tauri v2 IPC protocol and stock plugins | foundation, web, core, rpc | no |
| `zts_webview` | GTK3 / WKWebView / WebView2 | foundation, core | **yes** |
| `zts_wasm` | the `wasm32-freestanding` C ABI and WASM host | foundation, web, core, rpc, tauri | no |
| `zts_ssg` | static export, prerender, `_headers` | foundation, web, tauri, wasm | no |

**Only `zts_webview` needs libc.** That is what lets the same app code run in a WebAssembly
module with no OS, and as a static site with no server.

## Why six packages instead of one

Three reasons, each of which is "this does not work otherwise" rather than taste.

1. **Each artefact touches the OS differently.** Desktop uses GTK/Win32/Cocoa, the browser uses
   HTTP, WASM uses linear memory. Collapse those three behind a `Host` that is two words of
   function pointers, and the app needs zero `if (target)` lines.
2. **Keep tests fast.** `zts_rpc` and `zts_tauri` never call the OS, so their whole suite runs in
   under a second in the fast CI loop. Only native WebView tests need Xvfb.
3. **Link only what you use.** No commands? Leave `zts_rpc` out. No static export? Leave
   `zts_ssg` out.

## Where the three artefacts diverge

App logic lives in one file (say `src/app.zig`); only the **entry points** differ.

| Artefact | Entry point | `Host` implementation | State lives in |
|---|---|---|---|
| Desktop | `src/desktop.zig` | `WebviewHost` | the process |
| Live preview | `src/live.zig` | `BridgeHost` | the process |
| Static site | `src/wasm_app.zig` | `WasmHost` | the browser (WASM) |

```text
src/
├── app.zig        ← logic (commands, state). shared by all three
├── desktop.zig    ← main() and WebviewHost
├── live.zig       ← the HTTP server and BridgeHost
└── wasm_app.zig   ← the C ABI exports and WasmHost
```

If you find yourself wanting "a different code path on desktop", that is usually a sign that
**`Host` is missing a capability**. Look at `Host` in `zts_core` first.

## Common misconceptions

| Misconception | Reality |
|---|---|
| "Everything has to be written in Zig" | the frontend stays TypeScript; Zig covers the backend and the build |
| "Tauri plugins are unusable" | the seven stock plugins have compatible implementations ([Plugins](plugins.md)) |
| "WASM is a separate app" | same `app.zig`; only `Host` changes |
| "Adding `zts_tauri` opens a window" | windows come from `zts_webview`; `zts_tauri` is protocol only |

## Next

- [How a command travels](commands.md) — writing code on top of this layout
- [API: zts_core](../../../api/zts_core/index.html) — the whole `Host` surface
- [Assembling the packages yourself](../guides/static-site.md) — a real `build.zig`
