# Tauri 標準プラグインの使い方（`zts_tauri`）

> **対象読者**: `@tauri-apps/api` の `window` / `event` / `path` / `fs` / `dialog` / `menu` / `tray`
> を使いたい人。API の一覧は [`../api/zts_tauri/index.html`](../api/zts_tauri/index.html)。

Z-Ts は Tauri v2 の**ワイヤプロトコル**（`plugin:window|set_title` のようなコマンド名と JSON の形）を
そのまま実装しています。したがってフロントエンドは**無改造の `@tauri-apps/api` v2** が使え、
バックエンドは「プラグインの状態を持つ → スキーマに合流させる」の 2 手順だけです。

---

## 1. プラグインの状態を作る

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

[`CorePluginStates`](../api/zts_tauri/mod.html#CorePluginStates) は 7 つのプラグインの状態を
**1 つのヒープ確保**にまとめたものです（`events` が `windows` を指すなど、内部で相互参照するため
アドレスが固定されている必要があります）。

| フィールド | プラグイン | 型 |
|---|---|---|
| `windows` | `plugin:window\|*` | [`WindowRegistry`](../api/zts_tauri/window.html#WindowRegistry) |
| `events` | `plugin:event\|*` | [`EventBus`](../api/zts_tauri/event.html#EventBus) |
| `paths` | `plugin:path\|*` | [`PathState`](../api/zts_tauri/path.html#PathState) |
| `app_state` | `plugin:app\|*` | [`AppState`](../api/zts_tauri/app.html#AppState) |
| `resources` | `plugin:resources\|*` | `ResourceTable` |
| `menu_state` | `plugin:menu\|*` | [`MenuState`](../api/zts_tauri/menu/mod.html#MenuState) |
| `tray_state` | `plugin:tray\|*` | [`TrayState`](../api/zts_tauri/tray/mod.html#TrayState) |

---

## 2. 自分のスキーマに合流させる

```zig
const UserCommands = struct {
    pub fn greet(name: []const u8) []const u8 { … }
};

// ① 自分のスキーマと標準 7 プラグインを 1 行で合成
const FullSchema = tauri.withCorePlugins(rpc.Schema(.{ .app = UserCommands }));

// ② 状態を束縛（標準プラグインの状態は plugins から渡す）
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

名前空間が `tauri_*` に分かれているので、**ユーザー側は `.app` / `.window` / `.event` を自由に使えます**
（衝突しません）。[`withCorePlugins`](../api/zts_tauri/mod.html#withCorePlugins) は
`rpc.merge` の薄いラッパで、`zts_rpc` の `comptime` 検査はそのまま効きます。

---

## 3. プラグインごとの入り口

### window — [`Commands`](../api/zts_tauri/window.html#Commands)

```ts
import { getCurrentWindow } from "@tauri-apps/api/window";
await getCurrentWindow().setTitle("Hello");
```

Zig 側では `plugins.windows` を直接触れます。

```zig
const win = try plugins.windows.create(allocator, .{
    .label = "main", .title = "Z-Ts", .size = .wh(520, 620), .initial_url = "index.html",
});
try plugins.windows.setTitle(&win, "Renamed");
```

サイズ・位置は **論理 / 物理**の両方を受け付けます（[`WireSize`](../api/zts_tauri/window.html#WireSize)）。
`Xvfb` のようなヘッドレス CI でも同じ値が返るよう、`HeadlessMock` でも同じ経路を通ります。

### event — [`EventBus`](../api/zts_tauri/event.html#EventBus)

バックエンド → フロントエンドの通知です。

```zig
// JS: const un = await listen("counter:changed", e => …)
try plugins.events.emit(call_ctx.host, ctx.scratch, "counter:changed", snapshot);

// バックエンド内で受け取る（テストで便利）
_ = try plugins.events.onNative("counter:changed", null, struct {
    fn on(_: ?*anyopaque, _: []const u8, json: []const u8) void { … }
}.on);
```

イベント名は [`isValidEventName`](../api/zts_tauri/event.html#isValidEventName) で検証されます
（英数字・`-`・`/`・`:`・`_`）。配信先は [`EventTarget`](../api/zts_tauri/event.html#EventTarget)
（`Any` / `App` / `Window` / `Webview`）で絞れます。

### path — [`PathState`](../api/zts_tauri/path.html#PathState)

```ts
import { appDataDir } from "@tauri-apps/api/path";
const dir = await appDataDir();
```

[`BaseDirectory`](../api/zts_tauri/path.html#BaseDirectory)（`audio` … `video` の 12 種）と、
POSIX / Windows の**両方の流儀**を 1 つの実装で扱う [`PathStyle`](../api/zts_tauri/path.html#PathStyle)
があります。Windows のパスを Linux 上で正規化する必要があるテストでも同じ関数が使えます。

### fs — [`Commands`](../api/zts_tauri/fs/commands.html#Commands)

`plugin:fs|*` は **スコープ付き**です。`base_dir` を起点に正規化 → シンボリックリンク解決 →
包含判定を行い、外に出るパスは `forbidden path` で拒否します。

```zig
// スコープの設定（capability か、テストなら直接）
var scope = try tauri.fs.Scope.init(allocator, &.{
    .{ .path = "$APPDATA/saves" },          // `$APPDATA` などの変数を展開
});
defer scope.deinit();
```

設計の全文は [`../architecture/tauri-fs-plugin.md`](../architecture/tauri-fs-plugin.md)（内部資料）。

### dialog / clipboard — [`dialog`](../api/zts_tauri/dialog/mod.html) / [`clipboard`](../api/zts_tauri/clipboard/mod.html)

どちらも **vtable + ネイティブ分離**です。ヘッドレスでは `Mock` が入り、CI でも同じコードが走ります。

```zig
var mock = tauri.dialog.Mock.init(allocator);
mock.queueOpenResult("/tmp/picked.txt");
// … Commands 経由の呼び出しは mock に落ちる
```

```ts
import { open } from "@tauri-apps/plugin-dialog";
const file = await open({ multiple: false });
```

### menu / tray — [`menu`](../api/zts_tauri/menu/mod.html) / [`tray`](../api/zts_tauri/tray/mod.html)

デスクトップでは **ネイティブ**（macOS は `NSApp setMainMenu:`、Windows は `CreateMenu` +
`WM_COMMAND`）、それ以外は `StubBackend` です。バックエンドは差し替え可能なので、
テストでは [`Mock`](../api/zts_tauri/menu/mod.html#Mock) で「どの項目が押されたか」を再現できます。

```zig
plugins.menu_state.setBackend(tauri.menu.Mock.backend());
```

---

## 4. capability（ACL）で権限を絞る

既存の Tauri プロジェクトから移行するときは、`tauri.conf.json` と `capabilities/*.json` を
**そのまま**読めます。

```zig
const imported = try tauri.config_import.load(allocator, io, "src-tauri");
defer imported.deinit();

var policy = try tauri.acl.Policy.init(allocator, .{
    .files = imported.capabilities,
    .platform = .linux,                  // 3 OS ぶんをテストで回せる
});
defer policy.deinit();

if (!policy.allows("main-window", "plugin:fs|read_text_file")) return error.Forbidden;
```

* **未知のパーミッションは警告**、**型違いはエラー**、そして**既定は拒否**（fail-closed）。
* `build` 時に `Imported.warnings` を CI で表示しておくと、上流の設定変更に気づけます。

---

## 5. つまずきどころ

| 症状 | 原因と対処 |
|---|---|
| `invoke("plugin:window\|set_title")` が `command not found` | `withCorePlugins` を経由せず `rpc.Schema` だけを使っている。 |
| メニューが何も出ない | Linux では `StubBackend`。ネイティブが必要なら `native.menuBackend()` を挿す（対応 OS のみ）。 |
| `path` が `$APPDATA` を解決しない | `PathState.app_identifier` が既定値のまま。`app_config.identifier` と揃える。 |
| `fs` が常に `forbidden path` | capability の `scope` が空。`{ "path": "$APPDATA/**" }` のように glob で許可する。 |
| ヘッドレス CI でだけ落ちる | ダイアログ/クリップボードは `Mock` を使う（`Backend` を差し替える）。 |

---

## 次に読むもの

- API: [`zts_tauri`](../api/zts_tauri/index.html) / [`withCorePlugins`](../api/zts_tauri/mod.html#withCorePlugins) /
  [`window`](../api/zts_tauri/window.html) / [`event`](../api/zts_tauri/event.html) /
  [`fs`](../api/zts_tauri/fs/commands.html) / [`menu`](../api/zts_tauri/menu/mod.html)
- コマンドの書き方: [`using-rpc.md`](using-rpc.md)
- API ページの読み方（`@import` の 1 行・`L43` の意味）: [`using-the-api-reference.md`](using-the-api-reference.md)
- 移行: [`migrating-from-tauri.md`](migrating-from-tauri.md)
- 内部資料: [`../architecture/tauri-menu-tray.md`](../architecture/tauri-menu-tray.md) /
  [`../architecture/tauri-dialog-clipboard.md`](../architecture/tauri-dialog-clipboard.md) /
  [`../decisions/0014-config-import-and-acl.md`](../decisions/0014-config-import-and-acl.md)
