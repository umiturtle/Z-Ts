# The scope of Tauri v2 compatibility — same call, not always same behaviour

> **Audience**: teams evaluating a move from Tauri v2, or anyone who needs the real feature boundary
> before adopting ziggurats.
> **Time**: 10 minutes.
> **Before you start**: skim [the Tauri v2 API map](tauri-usage.en.md).

`@tauri-apps/api` v2 is called **unmodified**. Command names, arguments and response shapes follow
upstream. That is **wire compatibility**, not a promise that every OS side effect or value matches
Tauri. This page separates "I can write the same call" from "I get the same result".

## In three lines

1. **Wire**: `invoke("plugin:…|…")` uses the upstream command names and payloads.
2. **State**: the window `is*` getters follow real OS window events.
3. **Native behaviour**: native implementations need **explicit wiring**, some APIs return
   **fixed placeholders**, and unsupported plugins are a **deliberate design choice** (below).

## Compatibility has three layers

| Layer | Example | Status |
|---|---|---|
| Wire | `plugin:window\|set_title`, `plugin:webview\|create_webview_window` | implemented; the unmodified JS package can call it |
| State | `isMinimized()` / `isMaximized()` / `isFullscreen()` | OS-originated events update the registry |
| Native behaviour | OS notification centre, multi-monitor data, real user paths, OS process info | **reduced or unwired by default** |

A successful `invoke` is not proof that the expected OS behaviour happened. Always check layer 3
before you decide to adopt.

## 1. Native code exists — it simply is not wired automatically

`zts_tauri_native` **selects GTK / Cocoa / Win32 implementations at compile time** for menus, tray,
dialogs and the clipboard. A Linux menu and tray implementation does exist. (An earlier version of
these docs said "the Linux menu is a Stub"; that was incorrect.)

But [`CorePluginStates.create()`](../api/zts_tauri/plugins.html) initialises menus and tray with a
**Stub**, and the native implementations are injected explicitly from a separate module. Dialog and
clipboard each build their own state plus backend as well.

```text
app startup
  ├─ CorePluginStates.create()      → menu / tray are Stubs
  └─ inject zts_tauri_native        → GTK / Cocoa / Win32 implementations replace them
```

So the issue is **not missing implementations**: it is that **the application must wire them, and
those steps are scattered** across the [plugins guide](../learn/en/guides/plugins.md) and the
[feature-gap notes](../architecture/tauri-feature-gap.en.md).

> [!WARNING]
> The GTK tray implementation depends on `GtkStatusIcon`, removed in GTK 4 and marked deprecated in
> the source itself. It works on GTK 3.24 but needs a migration path.

## 2. Optional plugins can have the right API name and reduced behaviour

| Command | What it actually returns | Meaning |
|---|---|---|
| `plugin:process\|pid` | `0` | fixed value, not the real process id |
| `plugin:os\|version` | `"ziggurats"` | fixed string, not the OS version |
| `plugin:os\|locale` | `null` | no OS locale API connected |
| `plugin:notification\|*` | an in-app event | does not reach the OS notification centre |
| `plugin:opener\|*` | `Unsupported` without a provider | fail-closed, not a silent success |
| HTTP / Updater / SQL | not supported | an explicit design choice ([feature gap](../architecture/tauri-feature-gap.en.md)) |

`Unsupported` is the deny-by-default contract, not a bug. Configure a provider or handle the
unsupported case in your app.

## 3. Persistence and single-instance caveats

| Item | Actual behaviour | What you must know |
|---|---|---|
| `store.set` / `delete` / `clear` | change **in-memory state only** | a separate `save` command writes to disk |
| `store.clear` | drops entries without saving | call `save` after `clear` |
| load at startup | errors are ignored with `catch {}` | a corrupt or unreadable store file can start **empty** |
| `single-instance` | exclusive lock file, removed on clean exit | no stale-lock recovery after a crash; the next launch may see itself as locked |
| browser builds | lock-file behaviour undefined | do not rely on it in Live Preview or static sites |

Nothing survives shutdown without `save`. Persist deliberately, and let the UI handle the possibility
that state started empty.

## 4. `zts dev` is not a native app run

[`zts dev`](cli.en.md) starts a development server that serves `web/`. It watches `src/` for
type-checking and rebuilds, but it does **not open a native WebView and exercise IPC with Zig**. The
[`zts init`](cli.en.md) template embeds the front end but does not start out as an RPC app that
calls Zig commands.

| First success | What you verify | What you do not |
|---|---|---|
| browser render + reload in `zts dev` | HTML / CSS / hot reload | `invoke` round trips, native windows |
| the executable from `zts build` | the window and Zig commands | — |

Getting Tauri's "IPC works the moment it starts" experience requires adding command definitions and
an `invoke` call in the app ([build a counter](../learn/en/tutorials/counter.md)).

## 5. Default path values are not the real environment

When `PathState` is left unspecified these fixed values come back:

| Field | Default |
|---|---|
| `home_dir` | `/home/user` |
| `resource_dir` | `/app/resources` |
| `executable_dir` | `/app/bin` |
| `cwd` | `/` |
| `config` / `data` | **string-built** as `~/.config` / `~/.local/share` |

Windows `%APPDATA%` and the real per-OS user directory are not queried. `DesktopConfig.paths` also
defaults to an empty `PathState`, so `appDataDir()` and friends can return a **location that does
not exist**. Build `PathState` from the real environment and inject it in production.

## 6. Monitor defaults are fixed values

| Item | Default |
|---|---|
| monitors | one 1920×1080 display at scale 1.0 |
| cursor | `(0, 0)` |

A replaceable provider exists, but no real-OS provider is registered anywhere in the repository.
The default is a **deterministic value** for HeadlessMock, CI and screenshot parity. Multi-monitor
layout, HiDPI and the real cursor position are unavailable until you register a provider.

## 7. Checklist before you judge compatibility

- [ ] Does this feature need native behaviour, or only wire compatibility?
- [ ] Did you inject the native backends into `CorePluginStates`?
- [ ] Is the returned value possibly fixed, `null` or a placeholder?
- [ ] If state must persist, do you call `save`, and do you handle a corrupt file?
- [ ] Did you inject a real `PathState` and a monitor provider?
- [ ] Did you verify IPC with the `zts build` executable, not just `zts dev`?

## Related

- [Tauri v2 API map](tauri-usage.en.md) — commands, config and capabilities
- [Plugins guide](../learn/en/guides/plugins.md) — how to swap backends
- [Feature-gap notes](../architecture/tauri-feature-gap.en.md) — the build / skip rationale (internal)
- [`zts` command reference](cli.en.md)
- [API reference](../api/index.html)

## 8. The follow-up work is implemented

Every item previously listed as a weakness has since been implemented. The sections above remain
as **background**; the current behaviour is:

| Former weakness | Current behaviour |
|---|---|
| `PathState` returned `/home/user` and other fixed paths | `PathState.fromEnvironment()` reads `HOME` / `USERPROFILE` / `XDG_*` / `APPDATA` / `LOCALAPPDATA` / `TMPDIR`; `DesktopConfig` auto-detects when unspecified. Only headless/CI without an `environ` map keeps deterministic fallbacks |
| Monitors were a fixed 1920x1080 with no provider | All four `zts_webview` backends expose `screens()` / `cursorPosition()`, and `DesktopRuntime.create()` registers the `tauri.monitor` provider automatically. Linux: every GDK monitor with HiDPI; macOS: `NSScreen`; Windows: primary + system DPI; Mock: one deterministic display |
| `set` / `delete` / `clear` did not persist | `PluginState.Options.autosave` (default true) calls `save()` after every mutation; a no-op without `store_path`. The explicit `save` command still exists |
| `catch {}` silently ignored a corrupt save file | `RestoreDiagnostics` records `ok` / `missing` / `unreadable` / `malformed` plus the restored key count, so the app can detect why state started empty |
| A crash left a stale lock behind | The lock file records `zts-lock-v2 <pid>`; a `process_alive` provider proving the owner dead lets it be removed and retried once. **No timestamps** (determinism). Without a provider the lock is kept (fail-closed) |
| `zts dev` had no RPC at all | The `zts init` template ships `State` / `Commands.increment` / `rpc.Schema` and an `invoke("increment")` call; `zts dev` prints "browser preview only — Zig commands need `zts build`" |
| Native backend wiring was scattered | `zts_tauri`'s `RuntimeProviders` gathers path / monitor / menu / tray / dialog / clipboard / pid, applied in one place by `DesktopRuntime.create()`; `applyToPluginOptions()` configures the P2 state too |
| GTK tray depended on deprecated `GtkStatusIcon` | `libayatana-appindicator3`'s `AppIndicator` is now the primary backend (already a CI dependency). `GtkStatusIcon` is demoted to a compatibility fallback, keeping the click emitter identical on all three OSes |

> [!NOTE]
> This does **not** mean every Tauri feature now exists. The placeholders in §2 (`pid=0`,
> `os.version`, `locale=null`, in-app notifications, `Unsupported` from `opener`) and the unsupported
> HTTP / Updater / SQL plugins remain **deliberate design choices**.

### Wiring it once, in the app

```zig
var providers: tauri.RuntimeProviders = .{
    .menu = tauri_native.menuBackend(),
    .tray = tauri_native.trayBackend(),
    .dialog = tauri_native.dialogBackend(),
    .clipboard = tauri_native.clipboardBackend(),
    .current_pid = tauri_native.currentPid,
    .process_alive = tauri_native.processAlive,
};
providers.detectPath(allocator, init.environ_map, exe_dir, cwd, app.identifier);
const runtime = try tauri.app_runtime.DesktopRuntime.create(allocator, init.io, .{
    .providers = providers,
    .environ = init.environ_map,
});
var plugin_options: tauri.plugins.Options = .{ .store_path = "state.json" };
providers.applyToPluginOptions(&plugin_options);
```

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
