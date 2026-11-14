# Tauri v2 internals dissected (upstream code & Zig porting notes)

> **Audience**: porters and maintainers who need to know why the upstream implementation looks the
> way it does. This is an implementation autopsy, not a usage guide.
> **Time**: the section you are porting.

This page records what the upstream code (`vendor/tauri`) actually does, and what that implies for
ziggurats. It is an internal document: readers who only want to use the library should start at
[concepts](../learn/en/concepts/index.md) or the [API reference](../api/index.html).

---

## 1. Crate hierarchy and the single biggest structural fact

```text
tauri                     runtime: App/AppHandle, Window/WebviewWindow, Manager, State, IPC
├── tauri-build           build.rs helper (context generation, capability parsing)
├── tauri-codegen         compile-time asset/config embedding (`generate_context!`)
├── tauri-macros          `#[tauri::command]`, `generate_handler!`
├── tauri-runtime         backend-agnostic window/event traits
├── tauri-runtime-wry     wry/tao implementation of that runtime
├── tauri-plugin-*        fs / dialog / clipboard / shell / … (separate crates)
└── wry / tao             WebView and window creation on each OS
```

**The important finding for a port: even the core APIs are internal plugins.** Window, event, path,
resources and the app itself are registered through the same plugin machinery as the optional ones,
and their commands are namespaced `plugin:<name>|<command>`. ziggurats therefore gives `zts_tauri` a
`CorePluginStates` bundle and routes everything through one `Schema` — there is no second,
special-case command path.

## 2. The compile-time pipeline

### 2.1 `tauri-build` and `tauri-codegen` (`tauri::generate_context!()`)

At build time the config, capabilities, CSP and frontend assets are parsed, validated and embedded
into a generated `Context`. Invalid permissions fail the build, not the first user click. ziggurats does
the analogous thing with `embedFrontend` (assets + gzip twins + CSP hashes) and by generating
TypeScript types from `Schema`. Both put the check at compile time rather than at run time.

### 2.2 `#[tauri::command]` and autoref specialization (`tauri-macros`, `ipc/command.rs`)

The macro turns a function into a wrapper that deserialises arguments, injects runtime context
values, awaits async handlers, and serialises the result. Autoref specialization lets one macro
accept many signatures without a per-signature registration table. In Zig, `Schema` does this at
comptime: it inspects the function type, decides which parameter is the state (`RpcState` when
there is more than one), and emits a typed dispatcher. There is no proc-macro equivalent, and no
run-time reflection.

## 3. The IPC wire protocol (JS ⇔ native)

### 3.1 Two request paths

- **Path A (primary): custom-protocol HTTP POST.** JS posts a JSON (or binary) request to
  `ipc://localhost/<callback>`; the native side answers on the same channel. Large payloads and
  `ArrayBuffer`s take this route.
- **Path B (fallback): `window.ipc.postMessage(...)` + `webview.eval(...)`.** Used where the custom
  protocol is unavailable (notably older Windows WebView2 / Android). The response is delivered by
  evaluating a JS callback with the serialised result.

ziggurats keeps the wire format but swaps the transport: native uses the `ipc://` scheme, Live Preview
uses HTTP/1.1 + SSE, and WASM calls a function directly. The app code sees only `invoke`.

### 3.2 `Channel<T>` streaming (`ipc/channel.rs`)

A channel is a one-way, repeatedly-emitting sink separate from the command's return value. The
first message carries the channel id; subsequent messages are delivered as events on that id so a
long-running command can report progress without blocking its response. ziggurats's `Channel` follows
this shape.

### 3.3 Layered security

1. Capabilities (deny by default) decide whether a window may call a permission at all.
2. Scopes constrain the arguments (`$APPDATA/**`, allowed URLs, …).
3. CSP and the isolation pattern constrain what the WebView may load or execute.
4. `OriginPolicy` and the custom protocol reject requests from foreign origins.

None of these protects Zig code running in the same process; that boundary is not a security
boundary, and the ziggurats docs say so explicitly.

## 4. Thread model and the native layer (`tauri-runtime-wry` / `wry` / `tao`)

### 4.1 The GUI main-thread constraint

Window and WebView objects must be created and mutated on the main thread. Commands run on worker
threads and communicate with the main thread by message passing. ziggurats's `Engine.create` / `step`
and the `Host` contract keep the same shape: one event-loop turn, one owner of native handles.

### 4.2 Native APIs each backend actually calls

| OS | WebView | Window / event loop |
|---|---|---|
| Linux | WebKit2GTK (`webkit_web_view_*`, `JSCValue` evaluation) | GTK3 (`gtk_window_*`, `g_main_loop`) |
| macOS | WKWebView (`evaluateJavaScript`, `WKScriptMessageHandler`) | AppKit (`NSApplication`, `NSWindow`) |
| Windows | WebView2 (`ICoreWebView2*`, `ExecuteScript`) | Win32 (`CreateWindow`, `WM_*` message loop) |

ziggurats declares only the C functions it needs as `extern fn` Pure Zig bindings; `@cImport` and
`addTranslateC` are not used, which keeps cold builds fast and the `zts_tauri` module free of
`link_libc`.

## Where to go next

- [Tauri v2 API map](tauri-usage.en.md) — the public surface this implements
- [Concepts: how a command arrives](../learn/en/concepts/commands.md) — the ziggurats side
- [Package layout](../learn/en/concepts/architecture.md) — where each layer lives
- [ziggurats API reference](../api/index.html) — generated from `///`

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
