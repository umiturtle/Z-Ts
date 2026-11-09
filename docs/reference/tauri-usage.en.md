# Tauri v2 API map (upstream reference)

> **Audience**: readers comparing the upstream Tauri v2 surface with ziggurats.
> **Time**: just the section you need (this is a long reference).

Based on the upstream reference (`vendor/tauri`), this page describes **how a Tauri application is
laid out and which APIs the backend (Rust) and frontend (JS/TS) actually use**. It is the baseline
for ziggurats's public API and compatibility decisions. For the internal anatomy of those APIs, see
[the implementation autopsy](tauri-internals.en.md); for the ziggurats side, start with
[concepts](../learn/en/concepts/index.md).

---

## 1. A standard Tauri v2 project

```text
my-tauri-app/
├── package.json
├── index.html / src/                 # web frontend (Vite / React / Svelte / vanilla TS …)
└── src-tauri/                        # native backend
    ├── Cargo.toml                    # `tauri` (runtime) + `tauri-build` (build-dep)
    ├── build.rs                      # compile-time hook calling `tauri_build::build()`
    ├── tauri.conf.json               # identifier, windows, bundle and CSP settings
    ├── capabilities/                 # Tauri v2 permissions (least-privilege ACL)
    │   └── default.json              # which commands/scopes each window may use
    ├── icons/                        # per-OS application icons
    └── src/
        └── main.rs (or lib.rs)        # commands, State registration, Builder startup
```

## 2. Backend API (Rust: `crates/tauri`)

### 2.1 The minimum app and the Builder pipeline

Upstream: `vendor/tauri/bench/tests/helloworld/src-tauri/src/main.rs`, `vendor/tauri/crates/tauri/src/app.rs`

```rust
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

fn main() {
    tauri::Builder::default()
        .manage(MyAppState::default())                       // 1. shared global State
        .plugin(my_plugin::init())                           // 2. plugin registration
        .setup(|app| {                                       // 3. startup hook (window creation, …)
            let main_win = app.get_webview_window("main").unwrap();
            main_win.set_title("My App")?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![greet])     // 4. router for frontend-visible commands
        .run(tauri::generate_context!())                     // 5. compile-time Context → event loop
        .expect("error while running tauri application");
}
```

### 2.2 Command signatures (`#[tauri::command]`)

Upstream: `vendor/tauri/crates/tauri/src/ipc/command.rs`

A command function may mix **JSON arguments supplied by the frontend** with **context arguments the
runtime injects**, in any order.

```rust
#[tauri::command]
fn simple(args: MyArgs) -> Result<String, String> { /* … */ Ok("ok".into()) }

#[tauri::command]
async fn with_state(state: tauri::State<'_, MyState>, id: u32) -> Result<Item, Error> { /* … */ }

#[tauri::command]
fn with_window(window: tauri::Window, app: tauri::AppHandle, body: String) { /* … */ }

#[tauri::command]
fn streaming(channel: tauri::ipc::Channel<u8>) { /* emits values repeatedly */ }
```

Automatically injected types (never supplied from JS): `State<'_, T>`, `AppHandle`, `Window`,
`WebviewWindow`, `Manager` implementors, `ipc::Channel<T>`, `ipc::Request`, `ipc::Response`, and
`Invoke` internals. ziggurats mirrors this with `*Ctx`, `*State`, `RpcState`, and `Channel`.

### 2.3 Events (bidirectional pub/sub)

`emit` / `emit_to` / `listen` / `once` / `unlisten` on `AppHandle` and the JS `event` module. Events
carry a name and a serialisable payload; `listen` returns an unlisten function. ziggurats's `EventBus`
and `changed_event` cover the same contract.

### 2.4 `Manager` and `ResourceTable`

`Manager` is the universal lookup trait (`app.state::<T>()`, `app.get_webview_window("main")`,
`app.path().app_data_dir()`). `ResourceTable` maps integer resource ids to owned values so a file or
channel can be handed to JS and closed later — the same idea as ziggurats's `HandlePool` and
`plugin:resources`.

### 2.5 Writing a plugin (`tauri::plugin::Builder`)

A plugin bundles commands, state (`manage`), setup hooks and a JS API package. It is registered with
`.plugin(...)` and its commands are namespaced `plugin:<name>|<command>`. ziggurats's `CorePluginStates`
is the equivalent bundle for the built-in plugins.

## 3. Frontend API (JS/TS: `@tauri-apps/api`)

Upstream: `vendor/tauri/packages/api/src/`. **ziggurats uses this package unmodified.**

```typescript
import { invoke, Channel, convertFileSrc } from '@tauri-apps/api/core';
import { listen, emit } from '@tauri-apps/api/event';
import { getCurrentWindow } from '@tauri-apps/api/window';

// 1. call a command (JSON arguments → typed response)
const user = await invoke<User>('get_user', { userId: 42 });

// 2. binary payload (Uint8Array / ArrayBuffer → application/octet-stream)
const echoed = await invoke<ArrayBuffer>('transform_binary', new Uint8Array([1, 2, 3, 4]));

// 3. streaming (Channel)
const progress = new Channel<number>((pct) => console.log(`Progress: ${pct}%`));
await invoke('heavy_task', { url: 'https://example.com/file.bin', onProgress: progress });

// 4. subscribe and emit
const unlisten = await listen<{ version: string }>('update-available', (event) => {
  console.log(event.payload.version);
});
await emit('user-logged-out', { reason: 'manual' });
unlisten();

// 5. native window operations (internally `plugin:window|…` IPC commands)
const win = getCurrentWindow();
await win.setTitle('Updated from TypeScript');
await win.minimize();

// 6. local file path → WebView URI (`asset://localhost/…`)
const imgUrl = convertFileSrc('/path/to/photo.png');
```

## 4. Configuration and security (`tauri.conf.json` & Capabilities)

1. **`tauri.conf.json`**
   - `identifier`: reverse-domain id, e.g. `"com.example.app"`
   - `build`: `devUrl` (`"http://localhost:5173"`), `frontendDist` (`"../dist"`),
     `beforeDevCommand` / `beforeBuildCommand`
   - `app.windows`: initial windows (`label`, `title`, `width`, `height`, `resizable`,
     `transparent`, `decorations`, `url`, …)
   - `app.security`: `csp`, `pattern` (`"brownfield"` by default, or `"isolation"` for the encrypted
     iframe mode), `assetProtocol`
   - `bundle`: installer output (Linux `.deb` / `.rpm` / AppImage, macOS `.app` / `.dmg`,
     Windows `.msi` / NSIS `.exe`)
2. **Capabilities (`src-tauri/capabilities/*.json` — the defining Tauri v2 feature)**
   - **Deny by default**: `RuntimeAuthority` blocks built-in plugin commands and IPC from remote
     URLs unless explicitly allowed.
   - Each window declares which permissions (`"core:window:allow-set-title"`,
     `"fs:allow-read-text-file"`, …) and which argument scopes (`"$APPDATA/**"`, …) it may use.

## Where to go next

- [Concepts: security](../learn/en/concepts/security.md) — how ziggurats enforces this
- [Guide: standard plugins](../learn/en/guides/plugins.md) — the same plugins in Zig
- [Migrating from Tauri v2](../learn/en/guides/migrate-from-tauri.md) — a side-by-side table
- [ziggurats API reference](../api/index.html) — the public declarations, generated from `///`
