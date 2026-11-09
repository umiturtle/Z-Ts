# Plugins — Tauri's seven, stock

> **Audience**: readers who want `window` / `event` / `path` / `fs` / `dialog` / `menu` / `tray`
> from `@tauri-apps/api`.
> **Time**: 4 minutes.

ziggurats implements Tauri v2's **wire protocol** verbatim (command names such as
`plugin:window|set_title` and the JSON shapes). So the frontend needs no changes at all, and the
backend is two steps: create the state, join it into your schema.

## 1. Which plugins exist

| Plugin | What it does | Native implementation |
|---|---|---|
| `window` | create, move, title, maximise, fullscreen | yes |
| `event` | events between backend and frontend | every host |
| `path` | resolve `$APPDATA`, `$HOME`, … | every host |
| `fs` | read and write files (restricted by scope) | every host |
| `dialog` | open / save / message | native, or Mock |
| `menu` | application menu | macOS / Windows (Stub on Linux) |
| `tray` | tray icon | macOS / Windows |

"Stub" means **it does not crash, it just shows nothing**. Tests and headless CI run on stubs.

## 2. Create the state

```zig
const app_config: tauri.AppConfig = .{
    .name = "My App",
    .version = "0.1.0",
    .identifier = "jp.example.myapp",
    .tauri_version = "2.12.4",
};

var plugins = try tauri.CorePluginStates.create(allocator, io, app_config, path_config);
defer plugins.destroy();
```

[`CorePluginStates`](../../../api/zts_tauri/mod.html#CorePluginStates) puts all seven states into
**one heap allocation**, because they refer to each other (events point at windows) and their
addresses must stay put.

## 3. Join the schema

```zig
const FullSchema = tauri.withCorePlugins(rpc.Schema(.{ .app = MyCommands }));

var router = FullSchema.bind(.{
    .app = &my_state,
    .tauri_window = &plugins.windows,
    .tauri_event = &plugins.events,
    .tauri_path = &plugins.paths,
    .tauri_app = &plugins.app_state,
    .tauri_resources = &plugins.resources,
    .tauri_menu = &plugins.menu_state,
    .tauri_tray = &plugins.tray_state,
});
```

Namespaces are prefixed `tauri_*`, so **your side keeps `.app` / `.window` / `.event`** free.
Nothing collides.

## 4. The frontend is plain Tauri

```ts
import { getCurrentWindow } from "@tauri-apps/api/window";
import { readTextFile } from "@tauri-apps/plugin-fs";
import { open } from "@tauri-apps/plugin-dialog";

await getCurrentWindow().setTitle("Hello");
const text = await readTextFile("notes.md", { baseDir: BaseDirectory.AppData });
const chosen = await open({ multiple: false });
```

Code from the Tauri documentation runs as written. That is what compatibility means here.

## 5. What is compatible, and what is not

| Item | Status |
|---|---|
| the IPC protocol (`__TAURI_INTERNALS__`) | compatible |
| command names and JSON shapes | compatible |
| reading `tauri.conf.json` | compatible ([`config_import`](../../../api/zts_tauri/config_import.html)) |
| `capabilities/*.json` ACL | compatible ([Security](security.md)) |
| the plugins' **implementation language** | **different** (Zig, not Rust) |
| community plugins | not supported (add your own commands instead) |

Community plugins are Rust crates, so they do not drop in. Re-implement the protocol in Zig, or
add the functionality as your own commands with `rpc.merge`.

## Next

- [Security](security.md) — `fs` scopes are decided there
- [Guide: plugins](../guides/plugins.md) — real code and the usual traps
- API → [`zts_tauri`](../../../api/zts_tauri/index.html)
