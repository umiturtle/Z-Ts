# Tauri v2 feature gap — what is worth implementing

> Internal design note. App authors do not need this. The upstream API map is
> [`../reference/tauri-usage.en.md`](../reference/tauri-usage.en.md); the internals are in
> [`../reference/tauri-internals.en.md`](../reference/tauri-internals.en.md).
> 日本語: [`tauri-feature-gap.md`](tauri-feature-gap.md)

This is **not** a list of everything missing. It lists only the gaps that are both worth closing and
compatible with the project's philosophy. §4 states what we deliberately will not build, and why.

## 1. The constraints

| # | Principle | What it rules out |
|---|---|---|
| 1 | Pure Zig, `link_libc = false` (`zts_tauri` in particular) | Anything requiring a C runtime shared library |
| 2 | Use `@tauri-apps/api` v2 **unmodified** | Inventing a private JS API |
| 3 | Zero target-specific branches; artefacts differ by comptime parameter | Adding `if (target)` |
| 4 | `zts_webview` depends on `zts_foundation` only | Mixing upper layers into the WebView layer |
| 5 | Deterministic: no time, randomness or filesystem order | Artefacts that change per build |
| 6 | Identical behaviour on Linux / macOS / Windows | One-OS conveniences |
| 7 | One app → three artefacts, one self-contained binary | Runtime DLLs or asset directories |
| 8 | Keep internals out of the reader-facing docs | Design rationale in `///`, internal pages in the learning path |

"Tauri has it" is not a reason. **Can the same thing be done in Pure Zig, identically on three OSes?**

## 2. Already covered

| Area | Where |
|---|---|
| `invoke`, sync/async-style commands, `*Ctx` / `*State` injection, `error{}` → TS union | `src/rpc/` |
| Raw binary (`Bytes`, `application/octet-stream`), `RawJson`, `Channel<T>` | `src/rpc/codec.zig`, `src/tauri/channel.zig` |
| `emit` / `emit_to` / `listen` / `unlisten` | `src/tauri/event.zig` |
| `ResourceTable` (integer rids, `plugin:resources|close`) | `src/tauri/resources.zig` |
| 7 core plugins: window / event / path / app / resources / menu / tray (`withCorePlugins`) | `src/tauri/mod.zig` |
| ~40 window commands (size, position, fullscreen, min/max, show/hide/close, `is_*`, main `set_*`) | `src/tauri/window.zig` |
| `tauri.conf.json` major keys, capability Platform/Window/Origin matching | `src/tauri/{config_import,acl}.zig` |
| `Policy.allows` / `grantingCapability`, permission glob resolution | `src/tauri/acl.zig` |
| Scoped FS, dialog, clipboard — native on all three OSes | `src/tauri/{fs,dialog,clipboard}/` |
| Native menu / tray / accelerators / snapshots | `src/tauri/{menu,tray}/` |
| `tauri://` / `ipc://` / `asset://`, `convertFileSrc`, CSP, 206 Range | `src/tauri/{protocol,js_bootstrap}.zig`, `src/core/assets.zig` |
| desktop / Live Preview / static SSG | `src/{webview,bridge,wasm,ssg}/` |

## 3. Worth implementing

### P0 — compatibility and security holes

| # | Tauri v2 feature | Gap | Why it fits | Where |
|---|---|---|---|---|
| 1 | `new WebviewWindow(label, opts)`, `getByLabel()` — creating a second window from JS | `Host.createWindow()` and `WindowRegistry.registerWindow()` exist, but **no JS command**; `create: false` in config is ignored | The Host contract is already Pure Zig; one command reuses it | `src/tauri/window.zig`, `src/tauri/config_import.zig` |
| 2 | Enforcing capability **scopes** (`{"identifier":"fs:allow-read","allow":[{"path":"$APPDATA/**"}]}`) | `Permission.scope_json` is carried but `Policy.allows()` checks identifiers only; `FsScope` only enforces config-derived scopes | `std.json` + reuse `src/tauri/fs/scope.zig` | `src/tauri/acl.zig`, `src/rpc/ctx.zig` |
| 3 | `app.security.pattern: "isolation"` (encrypted iframe) | `config_import.zig` explicitly ignores `pattern` and `dangerousDisableAssetCspModification` | `std.crypto.aead.aes_gcm` is Pure Zig; keys can be build-time deterministic | `src/tauri/protocol.zig`, `src/tauri/js_bootstrap.zig` |
| 4 | Serving the gzip twins (`Content-Encoding: gzip`) | `embedFrontend` generates `gzip_entries` / `csp_hashes` but `zts_web.Assets` has no consumer — **dead generated data** | One `content_encoding` field on `AssetResponse`; generation is already deterministic | `src/core/assets.zig`, `src/build_tools/assets.zig`, `src/tauri/protocol.zig` |
| 5 | `zts migrate` (convert an existing `src-tauri/` project) | [`migrate-from-tauri.md`](../learn/en/guides/migrate-from-tauri.md) is a manual guide; no CLI command | `config_import` already parses `tauri.conf.json`; file generation extends `src/cli/template.zig` | `src/cli/{args,migrate}.zig` |


> **Progress (M5-19 / 2026-10-21)**: P0-2, P0-3, P0-1 and P0-4 are implemented. See the
> [task sheet](../tasks/M5-19-tauri-gap-implementation.md) for the remaining checkpoints, and
> [Security concepts](../learn/en/concepts/security.md) for per-permission scopes and isolation.

### P1 — lets app authors write the same code as Tauri

| # | Feature | Gap | Where |
|---|---|---|---|
| 6 | Webview control: `eval` / `reload` / `openDevtools` / `closeDevtools` / `isDevtoolsOpen` / `print` / `setZoom` / `clearAllBrowsingData` | `Host.evalJs` / `openDevtools` / `navigate` exist, **no `plugin:webview|*` commands** | `src/tauri/window.zig` |
| 7 | Window events: `onResized` / `onMoved` / `onCloseRequested` / `onFocusChanged` / `onScaleChanged` / `onFileDrop` / `onThemeChanged` / `onPageLoad` / `onNavigation` | `EventBus` exists but native→JS event kinds are narrow | `src/tauri/event.zig`, `src/webview/` |
| 8 | Remaining setters: `setIcon` / `setTheme` / `setSkipTaskbar` / `setProgressBar` / `setBadgeCount` / `setCursor*` / `center` / `requestUserAttention` / `setContentProtected` / `setVisibleOnAllWorkspaces` / `setShadow` / `setEffects` / `setBackgroundColor` | `WindowSpec` holds some values but no setter commands | `src/tauri/window.zig`, `src/core/host.zig` |
| 9 | Monitor / DPI: `currentMonitor` / `primaryMonitor` / `availableMonitors` / `monitorFromPoint` / `cursorPosition` | Only `scale_factor` | `src/webview/{types,linux,macos,windows}.zig` |
| 10 | Unapplied config fields: `center` / `maximized` / `skipTaskbar` / `titleBarStyle` / `hiddenTitle` / `userAgent` / `alwaysOnBottom` / `focus` / `dragDropEnabled` / `zoomHotkeysEnabled` / `windowEffects` / `contentProtected` / `tabbingIdentifier` | Parsed into `WindowConfig` but **dropped** by `toWindowSpec()` | `src/tauri/config_import.zig`, `src/core/host.zig` |
| 11 | `once` and webview-level `emitTo` targets | `emit_to` is window-label scoped | `src/tauri/event.zig` |
| 12 | Runtime updates of the `asset://` scope (persist dialog grants) | Initial scope only; no `persisted-scope` equivalent | `src/tauri/fs/scope.zig` |

### P2 — useful later

| # | Official plugin | Fit / effort |
|---|---|---|
| 13 | `opener` / `shell` | Low: `std.process.run` with `xdg-open` / `open` / `cmd /c start`, same pattern as the CLI's `openBrowser`; `link_libc` untouched. Must be capability-gated. |
| 14 | `store`, `window-state`, `log`, `os`, `process`, `cli` | Low–medium: `std.fs` + `std.json` + `builtin`; reuse `PathState` base dirs. |
| 15 | `single-instance`, `deep-link`, `autostart` | Medium: lock files / `.desktop` / plist / registry; OS-specific code stays inside the existing `native_*.zig` boundary. |
| 16 | `global-shortcut`, `notification`, `positioner` | Medium–high: new `extern fn` bindings; Pure Zig bindings are required to keep `link_libc = false`. |
| 17 | `.icns`, code signing, notarisation, MSI / NSIS / AppImage | Already deferred by design ([`packaging-and-bench.md`](packaging-and-bench.md) §5). Acceptable at P2 as external-tool calls like `hdiutil`. |

### Recommended order

```text
P0-2 (ACL scope) → P0-3 (isolation) → P0-1 (multi-window) → P0-4 (gzip) → P0-5 (migrate)
  → P1-6/7/8/9/10 (window/webview remainder) → P1-11/12 → P2
```

**Why ACL scope first**: every new feature widens the blast radius of "the policy never checks
scopes". That is a pre-existing hole, not a feature. P0-4 is cheap: the data is already generated.

## 4. Out of scope (conflicts with the philosophy)

| Feature | Reason |
|---|---|
| `plugin-http`, `websocket`, `upload`, `updater` | Need TLS; `std` has no TLS client and pulling in OpenSSL / Rust `reqwest` breaks #1 and #7. A separate `zts_http` package would be a different discussion. |
| `sql`, `stronghold` | External DB / crypto engine dependency, breaks #1. |
| `biometric`, `nfc`, `haptics`, `geolocation`, `barcode-scanner`, `torch` | Mobile-only; this project targets three desktop OSes (#6). |
| iOS / Android backends | Same. |
| Porting a Tokio-like async runtime | `std.Io` suffices; adding a runtime breaks #1 / #3. |
| Adding private methods to `@tauri-apps/api` | #2 — add the **upstream command name** on the Zig side instead. |
| Wrapping WebView2 in C++/COM | Pure Zig `extern fn` bindings already exist (#4). |
| More `if (windows) …` in app code | #3 — express differences via `RuntimeMode` / `Host` comptime substitution. |
| Putting internal design pages in the learning path | #8. |

## 5. Sources

- Upstream API map: [`../reference/tauri-usage.en.md`](../reference/tauri-usage.en.md),
  [`../reference/tauri-internals.en.md`](../reference/tauri-internals.en.md)
- Official plugin list: `github.com/tauri-apps/plugins-workspace`, `v2.tauri.app/plugin/`
- Implementation: `src/tauri/{mod,window,event,path,app,resources,acl,config_import,protocol,channel}.zig`,
  `src/core/{host,assets}.zig`, `src/rpc/{ctx,codec}.zig`, `src/cli/args.zig`
- Principles: [`../decisions/0002-hybrid-architecture-proposal.md`](../decisions/0002-hybrid-architecture-proposal.md),
  [`00-overview.md`](00-overview.md), `AGENTS.md`

> Do not hand-write counts here. `zig build docs` (`api_decls` / `api_members`) is the source of
> truth; this page is a qualitative list on purpose.
