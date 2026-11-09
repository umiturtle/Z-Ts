# Glossary

The words used by ziggurats's documentation and API, collected in one place. Each entry has **a one-line
definition** and **a link to the page where it first appears**. A code span such as `` `Engine` `` in
the text is linked automatically to a heading here (names that are not in the glossary go to the
API reference instead).

> [!NOTE]
> If you meet a word that is not here, the glossary is incomplete. This is the only file to add it to.

---

## Pack

The unit of distribution and development. There are ten — `zts_foundation` / `zts_web` / `zts_rpc` /
`zts_bridge` / `zts_webview` / `zts_tauri` / `zts_ssg` / `zts_wasm` / `zts_build` / `zts_cli` —
each independently linkable as one Zig module. See the diagram in
[package layout](learn/en/concepts/architecture.md) for which depends on which.

## Handle

An integer ID for a reference with no body, handed to JavaScript. Passing a raw pointer would lose
both lifetime and type, so `HandlePool` issues a process-unique number that the host maps back to
the object. Who frees it is decided the same way as for `OwnedBytes` (see [ownership](#ownedbytes)).

## OwnedBytes

A byte sequence that owns its length and pointer **as one value**, not as a separate pair. The side
that allocated it is responsible for `deinit`, which the type distinguishes from a borrowed
`[]const u8`. IPC return values use this type.

## Engine

A handle to a WebView engine. Create one with `create`, then drive one turn of the event loop with
`step`. Whether GTK, AppKit or Win32 is used is chosen at run time; the app code does not change.

## Bridge

The HTTP + SSE server connecting a browser Live Preview to the host. `BridgeServer` receives
`invoke` as an HTTP POST and returns the result over SSE. Native runs do not use it.

## Ctx

The execution context of one command: an allocator (`scratch`), information about the caller
(`getEnv`), and cancellation state. Put `*Ctx` first in a handler's parameters to receive it.

## Schema

The single place, written as a type, that says **which commands exist, what arguments they take and
what they return**. `Schema(.{ .app = Commands })` creates it, `bind` attaches state, and `handler`
turns it into a dispatcher. TypeScript types are generated from this `Schema`, so **there is no
second copy to write by hand**.

## Handler

The type-erased entry point built from `Schema`. It takes a command name and JSON in the shape
`dispatch(ctx, &ctx, "name", json)` and returns `Responses` (status + body).

## Command

One function callable from JavaScript as `invoke("name", args)`. On the Zig side, a `pub fn`
registered in `Schema` becomes a command. Namespaces (`plugin:fs|read_text_file`, for example)
prevent collisions.

## Capability

A declaration that "this window holds this permission". Written in `capabilities/*.json` and folded
into the ACL at build time. A capability is **a bundle of grants**; it executes nothing by itself.

## Permission

One identifier such as `plugin:fs|read_text_file`. Whether a command can actually be called depends
on the capability containing that permission. See [ACL](#acl).

## ACL

Access Control List: the table of "who (window) may do what (permission)". `Policy.allows()` decides.
It also states **what it does not protect**: the ACL does not guard code inside the process — Zig code
running in the same process can call anything.

## Scope

A **range** attached to a permission. Even a `fs` read grant can be limited to paths under
`$APPDATA/**`, for example, or to particular URLs. Use it when the permission alone is too broad.

## Invoke

Calling a host command from JavaScript, compatible with `invoke` from `@tauri-apps/api`. The result
is JSON; errors come back as an `IpcStatus` (equivalent to an HTTP status) plus a body.

## IPC

Inter-Process Communication: here, everything exchanged between the WebView and the host. Native
uses the `ipc://` scheme, Live Preview uses HTTP, and WASM uses a function call. The app code does
not know the difference.

## Channel

A way to receive **a value that arrives more than once, later**, separate from a command's return
value. Used for progress, logs and events. Typed as `Channel<string>`, for example.

## Plugin

A reusable unit bundling commands and state. Eight are built in: `plugin:fs` / `plugin:dialog` /
`plugin:menu` / `plugin:tray` / `plugin:clipboard` / `plugin:path` / `plugin:event` /
`plugin:resources`. `CorePluginStates` is the bundle containing all of them.

## Window

The frame that carries a WebView. `WindowConfig` sets width, height, title and resizability. One
process may own several, each with its own independent `label`.

## Assets

The static files under `web/`, **embedded into the executable**. `@embedFile` pulls them in and also
generates gzip twins and CSP hashes. Nothing is read from disk at run time, so the artefact is one
file.

## CSP

Content Security Policy. Hashes of embedded scripts are listed in `script-src`, allowing inline
scripts while rejecting injection from outside.

## SSG

Static Site Generation: writing the same app as a server-less bundle (HTML + JS + WASM).
`exportStaticSite` does the work.

## WASM

WebAssembly. Desktop code is built for `wasm32-freestanding` and runs the same commands in a
browser. `exportApp` exposes the C ABI (`_zts_invoke` and friends).

## Prerender

Generating each route's HTML ahead of time during an SSG export. The first paint is faster and the
content is readable even with JavaScript disabled.

## Manifest

The `_zts/manifest.json` written by SSG. It lists every file and its hash, for cache invalidation
and integrity checks.

## Loopback

Listening on `127.0.0.1` only. The Live Preview bridge is loopback-only by default and rejects
external connections through `OriginPolicy`.

## Origin

The "which page did this come from" information a browser sends. Live Preview checks it and refuses
`invoke` from origins that are not allowed.

## Determinism

The same input produces the same bytes. Both the documentation site and the binaries avoid
depending on time, randomness or filesystem order (`.deb` uses `mtime=0`; HTML lists are sorted).

## Layer violation

Mixing internal matters (design numbers, implementation jargon) into public API documentation.
`scripts/check-docs.py` inspects `///` and fails the build. The mechanical guard keeps the split:
reasoning in `docs/decisions/`, usage in `///`.

## doctest

Compiling the code in the documentation to verify it. Only fences whose info string contains
`zig check` are included; broken examples fail CI. This is how an example never becomes "an example
that does not run".

## xref

The automatic link from a `` `Name` `` code span in the text to the matching API reference,
glossary, error index or CLI reference entry. Names come from the source, so a rename breaks the
link and fails the build.

## Related

- [API reference](api/index.html) — look a name up
- [Error index](reference/errors.html) — look an `error.Name` up
- [CLI reference](reference/cli.en.md) — `zts` subcommands
- [Your first ten minutes](learn/en/start.md) — running in ten minutes
- [Documentation index](INDEX.en.md) — the site map, in sidebar order
- [Documentation sync ledger](contributing/doc-sync.en.md) — which version was verified when
