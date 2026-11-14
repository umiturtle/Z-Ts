# Tauri's stock plugins (`zts_tauri`)

> **Audience**: readers who want `window` / `event` / `path` / `fs` / `dialog` / `menu` / `tray`
> from `@tauri-apps/api`. Full listing: [`zts_tauri`](../../../api/zts_tauri/index.html).

ziggurats implements Tauri v2's **wire protocol** verbatim (command names such as
`plugin:window|set_title` plus the JSON shapes). So the frontend is **unmodified
`@tauri-apps/api` v2**, and the backend is two steps: hold the plugin state, join it into the
schema.

---

## 1. Create the plugin state

```zig
const tauri = @import("zts_tauri");

const app_config: tauri.AppConfig = .{
    .name = "My App",
    .version = "0.1.0",
    .identifier = "jp.example.myapp",
    .tauri_version = "2.12.4",
};

const path_config: tauri.PathState = .{
    .app_identifier = "jp.example.myapp",
    .home_dir = "/home/me",
    .resource_dir = "/app/resources",
    .executable_dir = "/app/bin",
};

const plugins = try tauri.CorePluginStates.create(allocator, io, app_config, path_config);
defer plugins.destroy();
```

[`CorePluginStates`](../../../api/zts_tauri/mod.html#CorePluginStates) keeps all seven states in
**one heap allocation**: `events` points into `windows`, so the addresses must not move.

| Field | Plugin | Type |
|---|---|---|
| `windows` | `plugin:window\|*` | [`WindowRegistry`](../../../api/zts_tauri/window.html#WindowRegistry) |
| `events` | `plugin:event\|*` | [`EventBus`](../../../api/zts_tauri/event.html#EventBus) |
| `paths` | `plugin:path\|*` | [`PathState`](../../../api/zts_tauri/path.html#PathState) |
| `app_state` | `plugin:app\|*` | [`AppState`](../../../api/zts_tauri/app.html#AppState) |
| `resources` | `plugin:resources\|*` | `ResourceTable` |
| `menu_state` | `plugin:menu\|*` | [`MenuState`](../../../api/zts_tauri/menu/mod.html#MenuState) |
| `tray_state` | `plugin:tray\|*` | [`TrayState`](../../../api/zts_tauri/tray/mod.html#TrayState) |

---

## 2. Join your schema

```zig
const UserCommands = struct {
    pub fn greet(name: []const u8) []const u8 { … }
};

// ① merge your schema and the seven stock plugins in one line
const FullSchema = tauri.withCorePlugins(rpc.Schema(.{ .app = UserCommands }));
```

```zig
// ② bind every namespace, including the plugin ones
var router = FullSchema.bind(.{
    .app = &state,
    .tauri_window = &plugins.windows,
    .tauri_event = &plugins.events,
    .tauri_path = &plugins.paths,
    .tauri_app = &plugins.app_state,
    .tauri_resources = &plugins.resources,
    .tauri_menu = &plugins.menu_state,
    .tauri_tray = &plugins.tray_state,
});
const handler = router.handler();
```

The namespaces are prefixed `tauri_*`, so `.app` stays yours.

---

## 3. Per-plugin entry points

### window — [`Commands`](../../../api/zts_tauri/window.html#Commands)

```ts
import { getCurrentWindow } from "@tauri-apps/api/window";
await getCurrentWindow().setTitle("Hello");
```

On the Zig side you can drive `plugins.windows` directly.

```zig
const win = try plugins.windows.create(allocator, .{
    .label = "main", .title = "ziggurats", .size = .wh(520, 620), .initial_url = "index.html",
});
try plugins.windows.setTitle(&win, "Renamed");
```

Sizes and positions accept **logical or physical** units
([`WireSize`](../../../api/zts_tauri/window.html#WireSize)). `HeadlessMock` follows the same path,
so headless CI (Xvfb) sees the same values as a real window.

#### OS-driven changes are reflected too

`isMinimized()` / `isMaximized()` / `isFullscreen()` / `isFocused()` report the **real window
state**, not the last value JavaScript sent. When the user clicks a title-bar button or uses an
OS shortcut, a GTK / Cocoa / Win32 native event travels through `WindowStateEvent` →
`Engine.setWindowStateHandler()` → `WindowRegistry.applyNativeState()`. Only an actual change
emits `tauri://resize` / `tauri://move` / `tauri://focus` / `tauri://blur` /
`tauri://window-flags-changed`, so duplicate OS notifications never produce duplicate events.

All 19 `applyExtras` setters (`setSkipTaskbar()`, `setAlwaysOnBottom()`,
`setContentProtected()`, …) do more than mutate `WindowExtras`: they push a **complete**
scalar-only snapshot to `core.Host.applyWindowExtras()`. All three OSes and `HeadlessMock`
receive the same contract and apply whatever their platform can express. `center`, `maximized`,
`focus`, `skipTaskbar`, `alwaysOnBottom`, `contentProtected` and `visibleOnAllWorkspaces`
from `tauri.conf.json` take effect inside `createWindow()`; the remaining target-specific
options are recorded as `WindowCreationOptions` on every backend.


### webview / multiple windows — [`Commands`](../../../api/zts_tauri/webview.html#Commands)

You can open a second window from JS **without modifying `@tauri-apps/api`**. The upstream
`plugin:webview|create_webview_window` / `plugin:window|create` commands arrive unchanged.

```ts
import { WebviewWindow } from "@tauri-apps/api/webviewWindow";
import { Window } from "@tauri-apps/api/window";
import { getAllWebviews } from "@tauri-apps/api/webview";

const settings = new WebviewWindow("settings", {
  url: "settings.html", width: 640, height: 480,
});
settings.once("tauri://created", () => console.log("ready"));

const bare = new Window("docs", { title: "Docs" });
console.log(await getAllWebviews()); // [{ label, windowLabel }, …]
```

| JS | Command | ziggurats behaviour |
|---|---|---|
| `new WebviewWindow(label, opts)` | `plugin:webview\|create_webview_window` | `Host.createWindow()` opens a native window; its own label-specific bootstrap is injected |
| `new Window(label, opts)` | `plugin:window\|create` | same (a window with one webview) |
| `new Webview(win, label, opts)` | `plugin:webview\|create_webview` | mounts a child `<iframe>` in the parent window (upstream's unstable feature) |
| `getAllWebviews()` | `plugin:webview\|get_all_webviews` | returns `[{ label, windowLabel }]` |
| `getAllWebviewWindows()` / `getAllWindows()` | `plugin:window\|get_all_windows` | returns label strings |

Labels accept `a-zA-Z0-9-/:_` (max 128 chars). `url` allows `http(s)`, `tauri`, `asset`,
`isolation` and `ipc`; relative paths resolve under `tauri://localhost/`. `javascript:` / `file:`
are rejected with `InvalidUrl` and duplicate labels with `DuplicateLabel`. `WindowOptions` such as
`center`, `skipTaskbar` and `titleBarStyle` are passed to the backend by `createWindow()`;
options an OS cannot apply are recorded as state rather than dropped.

### event — [`EventBus`](../../../api/zts_tauri/event.html#EventBus)

Backend → frontend notifications.

```zig
// JS: const un = await listen("counter:changed", e => …)
try plugins.events.emit(call_ctx.host, ctx.scratch, "counter:changed", snapshot);

// receive it inside the backend too (handy in tests)
_ = try plugins.events.onNative("counter:changed", null, struct {
    fn on(_: ?*anyopaque, _: []const u8, json: []const u8) void { … }
}.on);
```

Event names are validated by [`isValidEventName`](../../../api/zts_tauri/event.html#isValidEventName)
(alphanumerics, `-`, `/`, `:`, `_`). Delivery can be narrowed with
[`EventTarget`](../../../api/zts_tauri/event.html#EventTarget) (`Any` / `App` / `Window` /
`Webview`).

### path — [`PathState`](../../../api/zts_tauri/path.html#PathState)

```ts
import { appDataDir } from "@tauri-apps/api/path";
const dir = await appDataDir();
```

[`BaseDirectory`](../../../api/zts_tauri/path.html#BaseDirectory) covers the twelve Tauri
directories (`audio` … `video`), and [`PathStyle`](../../../api/zts_tauri/path.html#PathStyle)
handles POSIX **and** Windows conventions in one implementation — useful for tests that normalise
Windows paths on Linux.

### fs — [`Commands`](../../../api/zts_tauri/fs/commands.html#Commands)

`plugin:fs|*` is **scoped**. Paths are joined with `base_dir`, normalised, symlink-resolved, and
then containment-checked; anything that escapes is rejected with `forbidden path`.

```zig
// the scope (from a capability, or directly in a test)
var scope = try tauri.fs.Scope.init(allocator, &.{
    .{ .path = "$APPDATA/saves" },          // expands `$APPDATA` and friends
});
defer scope.deinit();
```

The full design is in [`docs/architecture/tauri-fs-plugin.md`](../../../architecture/tauri-fs-plugin.md)
(internal notes).

### dialog / clipboard — [`dialog`](../../../api/zts_tauri/dialog/mod.html) / [`clipboard`](../../../api/zts_tauri/clipboard/mod.html)

Both are **vtable + native split**. Headless builds install a `Mock`, so CI runs the same code.

```zig
var mock = tauri.dialog.Mock.init(allocator);
mock.queueOpenResult("/tmp/picked.txt");
// … calls through Commands land on the mock
```

```ts
import { open } from "@tauri-apps/plugin-dialog";
const file = await open({ multiple: false });
```

### menu / tray — [`menu`](../../../api/zts_tauri/menu/mod.html) / [`tray`](../../../api/zts_tauri/tray/mod.html)

Native implementations exist for **GTK, Cocoa and Win32** (macOS `NSApp setMainMenu:`,
Windows `CreateMenu` + `WM_COMMAND`, Linux GTK). The default `CorePluginStates`, however, starts
with a `StubBackend`, so **the application must wire the native one explicitly**; see
[the compatibility scope](../../../reference/compatibility.en.md). The backend is swappable, so
tests can use [`Mock`](../../../api/zts_tauri/menu/mod.html#Mock) to replay "which item was clicked".

```zig
plugins.menu_state.setBackend(tauri.menu.Mock.backend());
```

---

## 4. Narrowing permissions with capabilities (ACL)

When migrating from an existing Tauri project, `tauri.conf.json` and `capabilities/*.json` are read
**unchanged**.

```zig
const imported = try tauri.config_import.load(allocator, io, "src-tauri");
defer imported.deinit();

var policy = try tauri.acl.Policy.init(allocator, .{
    .files = imported.capabilities,
    .platform = .linux,                  // all three OSes can be exercised in tests
});
defer policy.deinit();

if (!policy.allows("plugin:fs|read_text_file", "main", "tauri://localhost")) return error.Forbidden;
```

* **Unknown permissions warn**, **wrong types error**, and **the default is deny** (fail-closed).
* Printing `Imported.warnings` during `build` makes upstream config changes visible.
* **Creating windows is NOT granted by `core:default`.** Add
  `core:webview:allow-create-webview-window`, `core:window:allow-create` or
  `core:webview:allow-create-webview` explicitly (see
  [per-permission scopes](../concepts/security.md)).

---

## 5. Usual traps

| Symptom | Cause and fix |
|---|---|
| `invoke("plugin:window\|set_title")` says `command not found` | you used `rpc.Schema` alone; go through `withCorePlugins` |
| no menu appears | the default is `StubBackend`; inject the GTK / Cocoa / Win32 implementation with `native.menuBackend()` (Linux included) |
| `path` does not resolve `$APPDATA` | `PathState.app_identifier` is still the default; match `app_config.identifier` |
| `fs` always returns `forbidden path` | the capability `scope` is empty; allow a glob such as `{ "path": "$APPDATA/**" }` |
| only headless CI fails | dialogs and clipboard need `Mock` (swap the `Backend`) |

---


## 6. P1 — commands that make upstream idioms work

The command surface now covers the remaining `plugin:window` / `plugin:webview` / `plugin:event`
calls. Every one is a `pub fn` on
[`Commands`](../../../api/zts_tauri/window.html#Commands),
[`webview`](../../../api/zts_tauri/webview.html#Commands) or
[`event`](../../../api/zts_tauri/event.html#Commands).

| Area | Example commands | Behaviour |
|---|---|---|
| webview control | `plugin:webview\|eval` / `reload` / `print` / `set_zoom` / `open_devtools` / `close_devtools` / `is_devtools_open` / `internal_toggle_devtools` / `clear_all_browsing_data` | routed through the existing `Host.evalJs` / `openDevtools`; child webviews target the parent window's `<iframe>` |
| window events | `plugin:window\|emit_window_event` | allowlisted `tauri://resize`, `move`, `focus`, `theme-changed`, `file-drop`, `page-load`, `navigation`, …; setters emit automatically |
| remaining setters | `set_theme` / `set_skip_taskbar` / `set_progress_bar` / `set_badge_count` / `set_cursor_*` / `center` / `request_user_attention` / `set_content_protected` / `set_visible_on_all_workspaces` / `set_shadow` / `set_effects` / `set_background_color` / `set_icon` / `set_always_on_bottom` / `set_enabled` | recorded in `WindowExtras` and followed by an event; OS-specific visuals are applied where the backend supports them |
| Monitor / DPI | `available_monitors` / `primary_monitor` / `current_monitor` / `monitor_from_point` / `cursor_position` | deterministic 1920×1080 @1.0 by default; real displays are installed through the [`MonitorRegistry`](../../../api/zts_tauri/monitor.html#MonitorRegistry) provider — no OS branch in app code |
| config fields | `center` / `maximized` / `skipTaskbar` / `titleBarStyle` / `hiddenTitle` / `userAgent` / `alwaysOnBottom` / `focus` / `dragDropEnabled` / `zoomHotkeysEnabled` / `windowEffects` / `contentProtected` / `tabbingIdentifier` / `visibleOnAllWorkspaces` | carried from `tauri.conf.json` into `core.WindowSpec` instead of being warned about and dropped; `windowEffects` stays as raw JSON |
| `once` / webview-level `emitTo` | `plugin:event\|once` / `emit_to({kind:"Webview"})` | `once` removes its listener after the first delivery; a `Webview` target resolves to the hosting window label |
| runtime `asset://` scope | `plugin:fs\|asset_scope_add` / `remove` / `clear` / `list` | file-dialog grants persist in [`AssetScope`](../../../api/zts_tauri/asset_scope.html#AssetScope), shared between `ProtocolConfig.asset_scope` and `FsState.withAssetScope()` |

> [!WARNING]
> `plugin:webview|eval`, `clear_all_browsing_data`, `plugin:window|emit_window_event` and
> `asset_scope_add` / `remove` / `clear` are **NOT granted by `core:default` / `fs:default`**.
> They can execute arbitrary JS, forge events or widen the asset scope; add
> `core:webview:allow-eval` and friends explicitly (see [Security concepts](../concepts/security.md)).


## 7. P2 — optional plugins and the macOS icon

P2 namespaces are **not** part of `CorePluginsSchema`. An app merges only what it uses, so an app
that never calls `store` links zero bytes of it (the same unused-module / zero-byte rule).

```zig
const S = rpc.Schema(.{
    .store = tauri.plugins.StoreCommands,
    .log = tauri.plugins.LogCommands,
    .os = tauri.plugins.OsCommands,
});
var state = try tauri.plugins.PluginState.init(allocator, io, .{ .argv = argv[1..] });
defer state.deinit();
var bound = S.bind(.{ .store = &state, .log = &state, .os = &state });
```

| Namespace | Main commands | What it does |
|---|---|---|
| `plugin:store\|*` | `get` / `set` / `delete` / `clear` / `keys` / `has` / `length` / `save` / `load` | JSON KV; pass `store_path` to persist under `$APPDATA` |
| `plugin:log\|*` | `log` / `logs` / `clear` | bounded 256-line ring buffer |
| `plugin:os\|*` | `platform` / `arch` / `family` / `exe_extension` / `version` / `locale` | from `builtin`; **never reads kernel version or locale** (would break 3-OS parity) |
| `plugin:process\|*` | `exit` / `pid` | `exit` delegates to `Host.requestQuit()` instead of killing the process |
| `plugin:cli\|*` | `args` / `matches` | startup argv snapshot |
| `plugin:window-state\|*` | `save` / `restore` / `clear` | window geometry in a reserved `store` key |
| `plugin:opener\|*` | `open_url` / `open_path` | **provider based**; returns `Unsupported` when none is installed, rejects non-`http(s)`/`mailto` URLs |
| `plugin:single-instance\|*` | `request_lock` / `is_primary` / `release` | exclusive lock file, identical on all 3 OSes |
| `plugin:notification\|*` | `notify` / `pending` | in-app `zts:event` + bounded 64-item ring; does **not** fake the OS notification center |
| `plugin:positioner\|*` | `move_window` | pure geometry from a monitor rect and a window size |
| `.icns` | `icns.buildAlloc`（`src/bundler/icns.zig` / in `src/bundler/icns.zig`） | Pure-Zig macOS icon container; no `iconutil`, byte-identical on all 3 OSes |

> [!WARNING]
> Side-effecting commands (`open_*`, `process|exit`, `request_lock`, `*_clear`, `notify`) are
> **NOT granted by any `*_default` set**. Add `opener:allow-open-url` and friends explicitly.

### Deliberately not implemented (with reasons)

| Feature | Reason |
|---|---|
| `plugin-http` / `websocket` / `upload` / `updater` | needs a TLS stack; Pure Zig `std` has no TLS client |
| `sql` / `stronghold` / mobile-only plugins | external DB/crypto engine, or outside the 3 desktop OS targets |
| `global-shortcut` / OS notifications / `deep-link` / `autostart` | needs OS hooks, registry, plist or `.desktop` writes; breaks `link_libc = false` and 3-OS parity |
| signing / notarytool / MSI / NSIS / AppImage | only external tool calls; no value in rewriting them in Zig ([`packaging-and-bench.md`](../../../architecture/packaging-and-bench.md) §5) |

## Next

- API: [`zts_tauri`](../../../api/zts_tauri/index.html) /
  [`withCorePlugins`](../../../api/zts_tauri/mod.html#withCorePlugins) /
  [`window`](../../../api/zts_tauri/window.html) / [`event`](../../../api/zts_tauri/event.html) /
  [`fs`](../../../api/zts_tauri/fs/commands.html) / [`menu`](../../../api/zts_tauri/menu/mod.html)
- Writing commands: [Commands](rpc.md)
- Reading API pages (`@import` lines, what `L43` means): [API index](../../../api/index.html)
- Migration: [Migrating from Tauri](migrate-from-tauri.md)
- Internals: [`docs/architecture/tauri-menu-tray.md`](../../../architecture/tauri-menu-tray.md) /
  [`docs/architecture/tauri-dialog-clipboard.md`](../../../architecture/tauri-dialog-clipboard.md) /
  [`docs/decisions/0014-config-import-and-acl.md`](../../../decisions/0014-config-import-and-acl.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
