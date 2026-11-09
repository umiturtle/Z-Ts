# Migrating from Tauri v2

> **Audience**: readers moving a Tauri v2 app onto ziggurats.
> **Time**: 30 minutes (the frontend needs no changes).

How to move an existing Tauri v2 app (Rust + `@tauri-apps/api`) onto ziggurats. **The goal is zero
frontend edits.** ziggurats implements Tauri's IPC protocol (`tauri://` internals,
`__TAURI_INTERNALS__`, plugin command names) verbatim, so JavaScript keeps working.

---

## 1. The mapping

| Tauri (Rust) | ziggurats (Zig) | Status |
|---|---|---|
| `tauri.conf.json` | [`config_import.load`](../../../api/zts_tauri/config_import.html#load) | supported (unknown keys warn, wrong types error) |
| `capabilities/*.json` + `acl` | [`acl.Policy`](../../../api/zts_tauri/acl.html#Policy) | supported (`fromImported`) |
| `#[tauri::command]` | [`zts_rpc.Schema`](../../../api/zts_rpc/schema.html#Schema) + `bind` | supported |
| `plugin:dialog` | [`zts_tauri.dialog`](../../../api/zts_tauri/dialog/mod.html) | supported (GTK / AppKit / Win32) |
| `plugin:clipboard-manager` | [`zts_tauri.clipboard`](../../../api/zts_tauri/clipboard/mod.html) | supported |
| `plugin:fs` | [`zts_tauri.fs`](../../../api/zts_tauri/fs/mod.html) | supported (scoped) |
| `plugin:menu` / `plugin:tray` | [`menu`](../../../api/zts_tauri/menu/mod.html) / [`tray`](../../../api/zts_tauri/tray/mod.html) | supported (Cocoa / Win32 / GTK) |
| `tauri build` (bundler) | [`zts package`](package.md) | supported (deb / AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz`) |
| `tauri dev` | `zts dev` | supported (HTTP serving + change detection + reload) |

## 2. Read the existing configuration as-is

```zig
const imported = try zts_tauri.config_import.load(alloc, io, cwd);
// imported.config      : the contents of tauri.conf.json (unknown keys warn, wrong types error)
// imported.capabilities: capabilities/*.json, merged into one ACL
// imported.warnings    : entries that could not be read or understood
```

Turn the `Imported` value into an ACL policy and consult it when a command runs:

```zig
var policy = try zts_tauri.acl.Policy.fromImported(alloc, imported);
const allowed = policy.allows("plugin:fs|read_text_file", .{ .window_label = "main" });
// e.g. the capability's `fs:allow-read-text-file` becomes `plugin:fs|read_text_file`
```

It is **fail-closed**: a command not granted by a capability is denied, exactly like upstream. The
details are in [`docs/architecture/tauri-config-import-acl.md`](../../../architecture/tauri-config-import-acl.md).

## 3. Port a command

Rust:

```rust
#[tauri::command]
fn greet(name: &str) -> String { format!("Hello, {name}!") }
```

Zig:

```zig
pub const Commands = struct {
    pub const rpc_prefix = "";
    pub fn greet(ctx: *zts_rpc.Ctx, args: struct { name: []const u8 }) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena, "Hello, {s}!", .{args.name});
    }
};
```

Register it in `zts_rpc.Schema` and the frontend's `invoke("greet", { name })` arrives unchanged.
`Channel<T>` (streaming) and `Event` (`listen`/`emit`) are implemented too.

## 4. Generate the TypeScript types

```bash
# after adding a tsgen step to your project's build.zig
zig build tsgen             # regenerates web/bindings.gen.ts
```

See [Commands §5](rpc.md) and [`examples/counter/build.zig`](../../../../examples/counter/build.zig)
for the step definition.

`@tauri-apps/api` v2 works **unmodified**, so the minimal migration is to swap only the `invoke`
typing for your own `bindings.gen.ts`.

## 5. Choose how the frontend is served

Tauri switches between `devUrl` and `frontendDist`; ziggurats **embeds at build time** by default (see
[build tools](../../../architecture/build-tools.md)). `dist/` is `@embedFile`d, so no asset
directory has to ship next to the binary.

| Before | After |
|---|---|
| `"devUrl": "http://localhost:5173"` | `zts dev` (serves `web/`, reloads on change) |
| `"frontendDist": "../dist"` | embed it into the `embedded_frontend` module |
| `tauri build` | [`zts build`](../tutorials/counter.md) → [`zts package`](package.md) (deb / AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz`) |

## 6. Where migrations trip

1. **`withGlobalTauri`**: ziggurats always exposes `window.__TAURI_INTERNALS__`. Code that expects
   `window.__TAURI__` is covered by the compatibility layer
   ([`js_bootstrap`](../../../api/zts_tauri/js_bootstrap.html)).
2. **`invoke` return values**: Tauri returns `Result<T, E>` as JSON; ziggurats uses the same envelope
   (`{"result": …}` / `{"error": …}`), so `try/catch` behaves identically.
3. **ACL path scopes**: scopes like `{ "path": "$APPDATA/db/*" }` are resolved by `Policy`.
   Unresolvable variables **warn and deny** (fail-closed).
4. **Menus / trays**: predefined items (`Copy` / `Quit` / `Separator`, …) map to OS selectors
   (macOS) or `MF_*` (Win32); custom items report by ID through `WM_COMMAND` / selectors.
5. **`tauri build` output**: `.deb` / AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz` come from
   [`zts package`](package.md). `.msi` and AppImage are **not** produced yet — you do get an
   AppDir, so an external tool can make the AppImage.

---

## Next

- Looking things up: [API index](../../../api/index.html) (it maps
  `plugin:window|set_title` → `Commands.set_title`)
- Plugin coverage: [Plugins](plugins.md)
- Broken after migrating: [Troubleshooting](troubleshooting.md)
- Importing an existing Tauri config:
  [`config_import`](../../../api/zts_tauri/config_import.html)
