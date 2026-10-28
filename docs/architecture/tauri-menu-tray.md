# `plugin:menu` / `plugin:tray` — ネイティブメニュー & システムトレイ

`src/tauri/{menu,tray}/` は `@tauri-apps/api/menu` と `@tauri-apps/api/tray`（v2.12.4）の
wire 互換実装。コアは **Pure Zig（`link_libc = false`）**、OS ツールキットに触れるのは
`zts_tauri_native` のみ（設計判断は [ADR-0013](../decisions/0013-menu-and-tray-backends.md)）。

```text
Menu.new({ items: [...] })               ← 上流 JS を無改変で利用
   │ invoke('plugin:menu|new', { kind, options, handler })
   ▼
Commands.new ──► Node（plugin:resources の rid で管理）を組み立てる
   │                    │
   │                    └─ 子ノードは *Node のポインタで接続（親 → 子）
   ▼
set_as_app_menu / popup / 変更系 ──► flatten（pre-order + depth）
   │
   ▼
Backend.applyAppMenu(Snapshot) / applyWindowMenu / popup
   ├─ Mock   … スナップショットを記録（Linux / macOS / Windows で同じ検証）
   └─ native … GTK / AppKit / Win32 が Snapshot を丸ごと再描画する
```

## 1. なぜ「平坦化スナップショット」なのか

上流 Rust は `muda` のオブジェクトグラフを直接操作する。Zig で同じことをすると
「ツリーを差分更新するコード」が 3 OS 分必要になり、しかも**どの OS でも検証できない**。
Z-Ts は **コアが唯一の真実**を持ち、バックエンドには平坦化した `Snapshot` だけを渡す:

```zig
pub const Entry = struct {
    kind: EntryKind,      // .submenu / .item / .separator
    id: []const u8,       // wire `MenuId`（activation で JS に返る文字列）
    text: []const u8,
    enabled: bool,
    checked: bool,
    accelerator: ?Accelerator,
    depth: u16,           // 0 = トップレベル、submenu の中は +1
    predefined: ?Predefined,
    item_kind: ItemKind,
};
```

メニューは高々数十項目なので、変更のたびにスナップショットを作り直して**丸ごと再構築**する方が
3 OS の差分が小さく、Mock による検証もそのまま本番の挙動になる。

## 2. コマンド表

| `plugin:menu\|…` | 引数 | 戻り値（wire） |
|---|---|---|
| `new` | `kind`, `options?`, `handler` (`Channel<string>`) | `[rid, id]` |
| `append` / `prepend` | `rid`, `kind`, `items: MenuItemPayloadKind[]` | `null` |
| `insert` | 上記 + `position` | `null` |
| `remove` | `rid`, `kind`, `item: [rid, kind]` | `null` |
| `remove_at` | `rid`, `kind`, `position` | `[rid, id, kind] \| null` |
| `items` / `get` | `rid`, `kind`（`get` は `id` も） | `[rid, id, kind][]` / `… \| null` |
| `popup` | `rid`, `kind`, `window?`, `at?` (`{Logical\|Physical:{x,y}}`) | `null` |
| `create_default` | — | `[rid, id]` |
| `set_as_app_menu` / `set_as_window_menu` | `rid`（後者は `window?`） | `[rid, id] \| null` |
| `text` / `set_text` / `is_enabled` / `set_enabled` | `rid`, `kind`（+ 値） | `string` / `bool` / `null` |
| `set_accelerator` | `rid`, `kind`, `accelerator?` | `null` |
| `is_checked` / `set_checked` | `rid`（+ `checked`） | `bool` / `null` |
| `set_icon` | `rid`, `kind`, `icon?` | `null` |
| `set_as_windows_menu_for_nsapp` / `set_as_help_menu_for_nsapp` | `rid` | `null`（macOS 以外は no-op） |

`plugin:tray|…` は `new`（`options`, `handler`）/ `get_by_id` / `remove_by_id` /
`set_icon` / `set_menu` / `set_tooltip` / `set_title` / `set_visible` / `set_temp_dir_path` /
`set_icon_as_template` / `set_icon_with_as_template` / `set_show_menu_on_left_click` の 12 個。

## 3. ワイヤ上の落とし穴

- **`MenuItemPayloadKind` は untagged**（`[rid, kind]` タプル or オプションオブジェクト）。
  `zts_rpc` の union 表現では書けないため、`std.json.Value` を経由する手書き `decodeZtsJson` で受ける。
- **`MenuId` は `muda` 準拠**: ユーザー指定はそのまま、未指定は `"1"`, `"2"`, … の連番。
- **`rid` は `plugin:resources` の共有テーブル**に載る。`await menu.close()` はそのまま動き、
  閉じられたノードは `Node.deinit` で親の子リストから外れる（dangling しない）。
- **`accelerator`** は `CmdOrCtrl+Shift+K` 形式。Pure Zig の
  [`menu/accelerator.zig`](../../src/tauri/menu/accelerator.zig) が
  GTK 文字列 / Win32 `ACCEL` / macOS 修飾キーマスクへ変換する。不正な文字列は
  黙って無視せず `InvalidAccelerator` で失敗させる。
- **アクティベーション**は `Channel<string>` に `MenuId` を流す（上流 `MenuChannels` と同じ）。
  `TrayIcon` のイベントは `{type, id, position:{x,y}, rect:{position,size}, button, buttonState}` で、
  `@tauri-apps/api/tray` の `mapEvent` がそのまま `PhysicalPosition` / `PhysicalSize` に包める形。

## 4. 現状のスコープ

| 項目 | 状態 |
|---|---|
| `plugin:menu` 22 コマンド（wire / ツリー / リソース / チャネル） | ✅ 実装済み・全 OS でテスト |
| `plugin:tray` 12 コマンド | ✅ 実装済み・全 OS でテスト |
| `Accelerator` パーサ & 3 OS レンダリング | ✅ 実装済み・全 OS でテスト |
| `Mock` バックエンド（スナップショット記録） | ✅ 実装済み |
| GTK / AppKit / Win32 のネイティブ描画 | ⏳ 未実装（`native.menuBackend()` はスタブ） |
| 画像アイコン（`JsImage` の bytes / path / rid） | ⏳ wire としては受理するが描画は未対応（`NativeIcon` のみ） |

ネイティブ層が未実装の間も、`plugin:menu` を使わないアプリのバイナリは 0 バイト増えず、
使った場合は `error.Unavailable` で fail-closed する。
