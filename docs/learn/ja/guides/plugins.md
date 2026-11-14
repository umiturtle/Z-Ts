# Tauri 標準プラグイン（`zts_tauri`）

> **対象読者**: `@tauri-apps/api` の `window` / `event` / `path` / `fs` / `dialog` / `menu` / `tray`
> を使いたい人。API の一覧は [`zts_tauri`](../../../api/zts_tauri/index.html)。
> **所要時間**: 8 分。**前提**: コマンドを 1 つ書いたことがある（[コマンド](rpc.md)）。

ziggurats は Tauri v2 の**ワイヤプロトコル**（`plugin:window|set_title` のようなコマンド名と JSON の形）を
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

[`CorePluginStates`](../../../api/zts_tauri/mod.html#CorePluginStates) は 7 つのプラグインの状態を
**1 つのヒープ確保**にまとめたものです（`events` が `windows` を指すなど、内部で相互参照するため
アドレスが固定されている必要があります）。

| フィールド | プラグイン | 型 |
|---|---|---|
| `windows` | `plugin:window\|*` | [`WindowRegistry`](../../../api/zts_tauri/window.html#WindowRegistry) |
| `events` | `plugin:event\|*` | [`EventBus`](../../../api/zts_tauri/event.html#EventBus) |
| `paths` | `plugin:path\|*` | [`PathState`](../../../api/zts_tauri/path.html#PathState) |
| `app_state` | `plugin:app\|*` | [`AppState`](../../../api/zts_tauri/app.html#AppState) |
| `resources` | `plugin:resources\|*` | `ResourceTable` |
| `menu_state` | `plugin:menu\|*` | [`MenuState`](../../../api/zts_tauri/menu/mod.html#MenuState) |
| `tray_state` | `plugin:tray\|*` | [`TrayState`](../../../api/zts_tauri/tray/mod.html#TrayState) |

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
（衝突しません）。[`withCorePlugins`](../../../api/zts_tauri/mod.html#withCorePlugins) は
`rpc.merge` の薄いラッパで、`zts_rpc` の `comptime` 検査はそのまま効きます。

---

## 3. プラグインごとの入り口

### window — [`Commands`](../../../api/zts_tauri/window.html#Commands)

```ts
import { getCurrentWindow } from "@tauri-apps/api/window";
await getCurrentWindow().setTitle("Hello");
```

Zig 側では `plugins.windows` を直接触れます。

```zig
const win = try plugins.windows.create(allocator, .{
    .label = "main", .title = "ziggurats", .size = .wh(520, 620), .initial_url = "index.html",
});
try plugins.windows.setTitle(&win, "Renamed");
```

サイズ・位置は **論理 / 物理**の両方を受け付けます（[`WireSize`](../../../api/zts_tauri/window.html#WireSize)）。
`Xvfb` のようなヘッドレス CI でも同じ値が返るよう、`HeadlessMock` でも同じ経路を通ります。

#### OS 側の操作も状態に反映される

`isMinimized()` / `isMaximized()` / `isFullscreen()` / `isFocused()` などは、JS が最後に
設定した値ではなく **実ウィンドウの状態** を返します。タイトルバーのボタンや OS の
ショートカットで状態が変わると、GTK / Cocoa / Win32 のネイティブイベントが
`WindowStateEvent` → `Engine.setWindowStateHandler()` → `WindowRegistry.applyNativeState()`
の順に届きます。値が変わったときだけ `tauri://resize` / `tauri://move` /
`tauri://focus` / `tauri://blur` / `tauri://window-flags-changed` が emit されるので、
OS が同じ通知を重複して送っても余分なイベントは出ません。

19 本の `applyExtras` 系セッター（`setSkipTaskbar()` / `setAlwaysOnBottom()` /
`setContentProtected()` など）は `WindowExtras` を書き換えるだけでなく、
`core.Host.applyWindowExtras()` へスカラだけの**完全な**スナップショットを渡します。
3 OS と `HeadlessMock` は同じ契約で受け取り、その OS が表現できる項目を適用します。
`tauri.conf.json` の `center` / `maximized` / `focus` / `skipTaskbar` /
`alwaysOnBottom` / `contentProtected` / `visibleOnAllWorkspaces` は `createWindow()` の
時点で効き、残りのターゲット固有オプションも `WindowCreationOptions` として
4 バックエンドすべてに記録されます。


### webview / 複数ウィンドウ — [`Commands`](../../../api/zts_tauri/webview.html#Commands)

`@tauri-apps/api` を**改造せずに** JS から 2 枚目のウィンドウを作れます。上流と同じ
`plugin:webview|create_webview_window` / `plugin:window|create` がそのまま届きます。

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

| JS | コマンド | ziggurats の挙動 |
|---|---|---|
| `new WebviewWindow(label, opts)` | `plugin:webview\|create_webview_window` | `Host.createWindow()` でネイティブウィンドウを生成。label 専用のブートストラップも注入 |
| `new Window(label, opts)` | `plugin:window\|create` | 同上（Webview を 1 枚持つウィンドウ） |
| `new Webview(win, label, opts)` | `plugin:webview\|create_webview` | 親ウィンドウ内に子 `<iframe>` を生成（上流の unstable 機能に相当） |
| `getAllWebviews()` | `plugin:webview\|get_all_webviews` | `[{ label, windowLabel }]` を返す |
| `getAllWebviewWindows()` / `getAllWindows()` | `plugin:window\|get_all_windows` | ラベル配列を返す |

ラベルは `a-zA-Z0-9-/:_` のみ（最大 128 文字）。`url` は `http(s)` / `tauri` / `asset` /
`isolation` / `ipc` のみ通し、相対パスは `tauri://localhost/` に解決します。
`javascript:` や `file:` は `InvalidUrl`、`label` の重複は `DuplicateLabel` で拒否します。
`center` / `skipTaskbar` / `titleBarStyle` などの `WindowOptions` は `createWindow()` で
バックエンドへ渡され、適用可能な範囲が反映されます（未対応の項目は状態として記録のみ）。

### event — [`EventBus`](../../../api/zts_tauri/event.html#EventBus)

バックエンド → フロントエンドの通知です。

```zig
// JS: const un = await listen("counter:changed", e => …)
try plugins.events.emit(call_ctx.host, ctx.scratch, "counter:changed", snapshot);

// バックエンド内で受け取る（テストで便利）
_ = try plugins.events.onNative("counter:changed", null, struct {
    fn on(_: ?*anyopaque, _: []const u8, json: []const u8) void { … }
}.on);
```

イベント名は [`isValidEventName`](../../../api/zts_tauri/event.html#isValidEventName) で検証されます
（英数字・`-`・`/`・`:`・`_`）。配信先は [`EventTarget`](../../../api/zts_tauri/event.html#EventTarget)
（`Any` / `App` / `Window` / `Webview`）で絞れます。

### path — [`PathState`](../../../api/zts_tauri/path.html#PathState)

```ts
import { appDataDir } from "@tauri-apps/api/path";
const dir = await appDataDir();
```

[`BaseDirectory`](../../../api/zts_tauri/path.html#BaseDirectory)（`audio` … `video` の 12 種）と、
POSIX / Windows の**両方の流儀**を 1 つの実装で扱う [`PathStyle`](../../../api/zts_tauri/path.html#PathStyle)
があります。Windows のパスを Linux 上で正規化する必要があるテストでも同じ関数が使えます。

### fs — [`Commands`](../../../api/zts_tauri/fs/commands.html#Commands)

`plugin:fs|*` は **スコープ付き**です。`base_dir` を起点に正規化 → シンボリックリンク解決 →
包含判定を行い、外に出るパスは `forbidden path` で拒否します。

```zig
// スコープの設定（capability か、テストなら直接）
var scope = try tauri.fs.Scope.init(allocator, &.{
    .{ .path = "$APPDATA/saves" },          // `$APPDATA` などの変数を展開
});
defer scope.deinit();
```

設計の全文は [`../architecture/tauri-fs-plugin.md`](../../../architecture/tauri-fs-plugin.md)（内部資料）。

### dialog / clipboard — [`dialog`](../../../api/zts_tauri/dialog/mod.html) / [`clipboard`](../../../api/zts_tauri/clipboard/mod.html)

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

### menu / tray — [`menu`](../../../api/zts_tauri/menu/mod.html) / [`tray`](../../../api/zts_tauri/tray/mod.html)

ネイティブ実装は **GTK / Cocoa / Win32 の 3 つ** にあります（macOS は `NSApp setMainMenu:`、
Windows は `CreateMenu` + `WM_COMMAND`、Linux は GTK）。ただし既定の `CorePluginStates` は
`StubBackend` で初期化されるため、**アプリ側で明示的な差し込みが必要**です。
[互換性の範囲](../../../reference/compatibility.md) も参照してください。バックエンドは差し替え可能なので、
テストでは [`Mock`](../../../api/zts_tauri/menu/mod.html#Mock) で「どの項目が押されたか」を再現できます。

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

if (!policy.allows("plugin:fs|read_text_file", "main", "tauri://localhost")) return error.Forbidden;
```

* **未知のパーミッションは警告**、**型違いはエラー**、そして**既定は拒否**（fail-closed）。
* `build` 時に `Imported.warnings` を CI で表示しておくと、上流の設定変更に気づけます。
* **ウィンドウ生成は `core:default` では許可されません。** `core:webview:allow-create-webview-window`
  / `core:window:allow-create` / `core:webview:allow-create-webview` を明示してください
  （[セキュリティの権限ごとの scope](../concepts/security.md) も参照）。

---

## 5. つまずきどころ

| 症状 | 原因と対処 |
|---|---|
| `invoke("plugin:window\|set_title")` が `command not found` | `withCorePlugins` を経由せず `rpc.Schema` だけを使っている。 |
| メニューが何も出ない | 既定は `StubBackend`。`native.menuBackend()` で GTK / Cocoa / Win32 の実装を差し込む（Linux にも実装あり）。 |
| `path` が `$APPDATA` を解決しない | `PathState.app_identifier` が既定値のまま。`app_config.identifier` と揃える。 |
| `fs` が常に `forbidden path` | capability の `scope` が空。`{ "path": "$APPDATA/**" }` のように glob で許可する。 |
| ヘッドレス CI でだけ落ちる | ダイアログ/クリップボードは `Mock` を使う（`Backend` を差し替える）。 |

---


## 6. P1 — 上流と同じ書き方を支えるコマンド

`@tauri-apps/api` を改造せずに使えるコマンドを広げました。すべて
[`Commands`](../../../api/zts_tauri/window.html#Commands) /
[`webview`](../../../api/zts_tauri/webview.html#Commands) /
[`event`](../../../api/zts_tauri/event.html#Commands) に `pub fn` としてあります。

| 分類 | コマンド例 | 挙動 |
|---|---|---|
| webview 制御 | `plugin:webview\|eval` / `reload` / `print` / `set_zoom` / `open_devtools` / `close_devtools` / `is_devtools_open` / `internal_toggle_devtools` / `clear_all_browsing_data` | 既存の `Host.evalJs` / `openDevtools` 経由。子 webview は親ウィンドウの `<iframe>` を対象にする |
| ウィンドウイベント | `plugin:window\|emit_window_event` | `tauri://resize` / `move` / `focus` / `theme-changed` / `file-drop` / `page-load` / `navigation` など**許可リスト制**。setter は自動で emit する |
| 残りの setter | `set_theme` / `set_skip_taskbar` / `set_progress_bar` / `set_badge_count` / `set_cursor_*` / `center` / `request_user_attention` / `set_content_protected` / `set_visible_on_all_workspaces` / `set_shadow` / `set_effects` / `set_background_color` / `set_icon` / `set_always_on_bottom` / `set_enabled` | 値を `WindowExtras` に記録してイベントを出す。OS 固有の見た目は backend が適用できる範囲で反映 |
| Monitor / DPI | `available_monitors` / `primary_monitor` / `current_monitor` / `monitor_from_point` / `cursor_position` | 既定は決定論的な 1920×1080 @1.0。実ディスプレイは [`MonitorRegistry`](../../../api/zts_tauri/monitor.html#MonitorRegistry) の provider で差し替える（アプリに OS 分岐を書かない） |
| config フィールド | `center` / `maximized` / `skipTaskbar` / `titleBarStyle` / `hiddenTitle` / `userAgent` / `alwaysOnBottom` / `focus` / `dragDropEnabled` / `zoomHotkeysEnabled` / `windowEffects` / `contentProtected` / `tabbingIdentifier` / `visibleOnAllWorkspaces` | `tauri.conf.json` から `core.WindowSpec` まで運ぶようにした（以前は警告して破棄）。`windowEffects` は JSON のまま保持 |
| `once` / webview 単位 `emitTo` | `plugin:event\|once` / `emit_to({kind:"Webview"})` | `once` は初回配送でリスナを自動削除。`Webview` ターゲットは親ウィンドウのラベルへ解決 |
| `asset://` scope の実行時更新 | `plugin:fs\|asset_scope_add` / `remove` / `clear` / `list` | ファイルダイアログの許可を [`AssetScope`](../../../api/zts_tauri/asset_scope.html#AssetScope) に永続化。`ProtocolConfig.asset_scope` と `FsState.withAssetScope()` で共有 |

> [!WARNING]
> `plugin:webview|eval`、`clear_all_browsing_data`、`plugin:window|emit_window_event`、
> `asset_scope_add` / `remove` / `clear` は **`core:default` / `fs:default` では許可されません**。
> 任意コード実行・イベント偽装・scope 拡大につながるため、capability に
> `core:webview:allow-eval` などを明示してください（[権限の考え方](../concepts/security.md)）。


## 7. P2 — 任意プラグインと macOS アイコン

P2 は **`CorePluginsSchema` に入れません**。使う名前空間だけを `rpc.Schema` に合成するので、
`store` を使わないアプリには 0 バイトしかリンクされません（未使用モジュールは 0 バイトになる方針）。

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

| 名前空間 | 主なコマンド | 中身 |
|---|---|---|
| `plugin:store\|*` | `get` / `set` / `delete` / `clear` / `keys` / `has` / `length` / `save` / `load` | JSON KV。`store_path` を渡すと `$APPDATA` の JSON に永続化 |
| `plugin:log\|*` | `log` / `logs` / `clear` | 上限 256 行のリングバッファ |
| `plugin:os\|*` | `platform` / `arch` / `family` / `exe_extension` / `version` / `locale` | `builtin` から。**カーネル版数やロケールは読まない**（3 OS パリティを壊すため） |
| `plugin:process\|*` | `exit` / `pid` | `exit` は `Host.requestQuit()` に委譲。プロセスを実際に殺さない |
| `plugin:cli\|*` | `args` / `matches` | 起動時 argv のスナップショット |
| `plugin:window-state\|*` | `save` / `restore` / `clear` | 位置・サイズを `store` の予約キーに保存 |
| `plugin:opener\|*` | `open_url` / `open_path` | **provider 方式**。未設定なら `Unsupported`。`http(s)` / `mailto` 以外の URL は拒否 |
| `plugin:single-instance\|*` | `request_lock` / `is_primary` / `release` | 排他ロックファイル（3 OS 同一） |
| `plugin:notification\|*` | `notify` / `pending` | アプリ内 `zts:event` と上限 64 件のリング。OS 通知センターは**偽らない** |
| `plugin:positioner\|*` | `move_window` | モニタ矩形とウィンドウサイズからの純粋な座標計算 |
| `.icns` | `icns.buildAlloc`（`src/bundler/icns.zig` / in `src/bundler/icns.zig`） | Pure Zig の macOS アイコンコンテナ。`iconutil` 不要・3 OS 同一バイト列 |

> [!WARNING]
> 副作用のあるコマンド（`open_*` / `process|exit` / `request_lock` / `*_clear` / `notify`）は
> **`*_default` では許可されません**。capability に `opener:allow-open-url` などを明示してください。

### 実装しないもの（理由つき）

| 機能 | 理由 |
|---|---|
| `plugin-http` / `websocket` / `upload` / `updater` | TLS スタックの外部依存が必要。Pure Zig `std` には TLS クライアントが無い |
| `sql` / `stronghold` / モバイル専用プラグイン | DB / 暗号ライブラリの外部依存、または 3 デスクトップ OS 対象外 |
| `global-shortcut` / OS 通知 / `deep-link` / `autostart` | OS フック・レジストリ・plist・`.desktop` 書き込みが必要。`link_libc = false` と 3 OS 同一挙動を壊す |
| コード署名 / notarytool / MSI / NSIS / AppImage | 外部ツール呼び出しに留まり、純 Zig で書く価値が無い（[`packaging-and-bench.md`](../../../architecture/packaging-and-bench.md) §5） |

## 次に読むもの

- API: [`zts_tauri`](../../../api/zts_tauri/index.html) / [`withCorePlugins`](../../../api/zts_tauri/mod.html#withCorePlugins) /
  [`window`](../../../api/zts_tauri/window.html) / [`event`](../../../api/zts_tauri/event.html) /
  [`fs`](../../../api/zts_tauri/fs/commands.html) / [`menu`](../../../api/zts_tauri/menu/mod.html)
- コマンドの書き方: [`rpc.md`](rpc.md)
- API ページの読み方（`@import` の 1 行・`L43` の意味）: [API リファレンスの索引](../../../api/index.html)
- 移行: [`migrate-from-tauri.md`](migrate-from-tauri.md)
- 内部資料: [`../architecture/tauri-menu-tray.md`](../../../architecture/tauri-menu-tray.md) /
  [`../architecture/tauri-dialog-clipboard.md`](../../../architecture/tauri-dialog-clipboard.md) /
  [`../decisions/0014-config-import-and-acl.md`](../../../decisions/0014-config-import-and-acl.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
