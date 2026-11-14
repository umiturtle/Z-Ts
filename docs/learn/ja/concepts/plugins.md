# プラグイン — Tauri 標準の 7 つを使う

> **対象読者**: `@tauri-apps/api` の `window` / `event` / `path` / `fs` / `dialog` / `menu` / `tray`
> を使いたい人。
> **所要時間**: 4 分。

ziggurats は Tauri v2 の**ワイヤプロトコル**（`plugin:window|set_title` のようなコマンド名と
JSON の形）をそのまま実装しています。したがってフロントエンドは無改造で動き、バックエンドは
「状態を作る → スキーマに合流させる」の 2 手順だけです。

## 1. どのプラグインがあるか

| プラグイン | できること | ネイティブ実装 |
|---|---|---|
| `window` | ウィンドウの生成・移動・タイトル・最大化・フルスクリーン | あり |
| `event` | バックエンド ↔ フロントエンドのイベント | 全ホスト |
| `path` | `$APPDATA` `$HOME` などの解決 | 全ホスト |
| `fs` | ファイル読み書き（scope で制限） | 全ホスト |
| `dialog` | open / save / message | OS ネイティブ or Mock |
| `menu` | アプリケーションメニュー | macOS / Windows（Linux は Stub） |
| `tray` | トレイアイコン | macOS / Windows |

「Stub」は**呼んでも落ちないが何も表示しない**実装です。テストとヘッドレス CI はこれで回ります。

## 2. 状態を作る

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

[`CorePluginStates`](../../../api/zts_tauri/mod.html#CorePluginStates) は 7 つの状態を **1 回の
ヒープ確保**にまとめたものです（イベントがウィンドウを指すなど、内部で相互参照するため
アドレスが固定されている必要があります）。

## 3. スキーマに合流させる

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

名前空間は `tauri_*` に分かれているので、**あなたの側では `.app` / `.window` / `.event` を
自由に使えます**。衝突しません。

## 4. フロントエンドは普通の Tauri

```ts
import { getCurrentWindow } from "@tauri-apps/api/window";
import { readTextFile } from "@tauri-apps/plugin-fs";
import { open } from "@tauri-apps/plugin-dialog";

await getCurrentWindow().setTitle("Hello");
const text = await readTextFile("notes.md", { baseDir: BaseDirectory.AppData });
const chosen = await open({ multiple: false });
```

Tauri のドキュメントに書いてあるコードが、そのまま動きます。これが ziggurats の互換性の意味です。

## 5. 何が「互換」で、何が違うか

| 項目 | 状態 |
|---|---|
| IPC プロトコル（`__TAURI_INTERNALS__`） | 互換 |
| コマンド名と JSON の形 | 互換 |
| `tauri.conf.json` の読み込み | 互換（[`config_import`](../../../api/zts_tauri/config_import.html)） |
| `capabilities/*.json` の ACL | 互換（[セキュリティ](security.md)） |
| プラグインの**実装言語** | **違う**（Rust ではなく Zig） |
| コミュニティ製プラグイン | 未対応（自分で `Schema` に足す） |

コミュニティプラグインは Rust の crate なので、そのままでは動きません。プロトコルだけを
見て Zig で書き直すか、[`rpc.merge`](../../../api/zts_rpc/schema.html) で自作コマンドとして
足してください。

## 次に読むもの

- [セキュリティ](security.md) — `fs` の scope はここで決まる
- [ガイド: プラグイン](../guides/plugins.md) — 実際のコードとつまずきどころ
- API → [`zts_tauri`](../../../api/zts_tauri/index.html)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
