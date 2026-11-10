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
are rejected with `InvalidUrl` and duplicate labels with `DuplicateLabel`. `WindowOptions` we do
not act on (`center`, `skipTaskbar`, `titleBarStyle`, …) are ignored rather than failing the call.

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

Native on desktop (macOS `NSApp setMainMenu:`, Windows `CreateMenu` + `WM_COMMAND`), a
`StubBackend` elsewhere. The backend is swappable, so tests can use
[`Mock`](../../../api/zts_tauri/menu/mod.html#Mock) to replay "which item was clicked".

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
| no menu appears | Linux uses `StubBackend`; install `native.menuBackend()` (supported OSes only) |
| `path` does not resolve `$APPDATA` | `PathState.app_identifier` is still the default; match `app_config.identifier` |
| `fs` always returns `forbidden path` | the capability `scope` is empty; allow a glob such as `{ "path": "$APPDATA/**" }` |
| only headless CI fails | dialogs and clipboard need `Mock` (swap the `Backend`) |

---

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
