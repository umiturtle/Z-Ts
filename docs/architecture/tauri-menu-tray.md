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
| `plugin:menu` 22 コマンド（wire / ツリー / リソース / チャネル） | ✅ 全 OS でテスト |
| `plugin:tray` 12 コマンド | ✅ 全 OS でテスト |
| `Accelerator` パーサ & 3 OS レンダリング | ✅ 全 OS でテスト |
| `Mock` バックエンド（スナップショット記録） | ✅ 全 OS でテスト |
| 上流 `@tauri-apps/api` 2.12.4 の menu / tray を**無改変**で E2E 実行 | ✅ Node bridge + 実 WebKit2GTK |
| GTK3 ネイティブ描画（`GtkMenuBar` / `GtkMenu` / `GtkStatusIcon`） | ✅ 実装済み（Xvfb でウィジェットツリーを検証） |
| AppKit 描画（`NSMenu`） | ✅ `M4-05`（`native_macos.zig` + `native_macos_shim.m`） |
| Win32 描画（`HMENU`） | ✅ `M4-05`（`native_windows.zig`） |
| AppKit / Win32 のトレイ（`NSStatusItem` / `Shell_NotifyIconW`） | ⏳ 未実装 → `error.Unavailable` で fail-closed |
| 画像アイコン（`JsImage` の bytes / path / rid） | ⏳ wire としては受理するが描画は未対応 |
| Win32 のショートカット**動作**（`TranslateAcceleratorW`） | ⏳ 表示のみ（下記 4.4） |

ネイティブ層が無い OS でも、`plugin:menu` を使わないアプリのバイナリは 0 バイト増えず、
使った場合は `error.Unavailable` で **fail-closed** する（黙って成功したように見せない）。
サーバーレス `wasm32` ビルドも同じで、E2E スイートがその fail-closed 挙動を検証している。

### 4.1 GTK3 のウィンドウ契約

GTK にはアプリケーションメニューバーが存在しない（メニューはウィンドウに詰めるウィジェット）。
ホストは `native.registerMenuWindow(label, gtk_window)` でトップレベルウィンドウを登録し、
`GtkMenuBar` はウィンドウ直下の子（`GtkBox`）の index 0 に挿入される。
`GtkBox` 以外が直下にある場合は `error.Unsupported`（黙って何もしない、はしない）。

トレイは `GtkStatusIcon` を使う。非推奨 API だが **追加のシステム依存が無い**ため、
素のランナーでも `zig build -Dgtk=true` が通る（上流 `tauri` は `libappindicator` を使う）。
wire 層は共通なので、将来 `libayatana-appindicator` に差し替えてもプラグイン側は無変更で済む。

### 4.2 3 OS 共通の変換層（`menu/snapshot_wire.zig`）

ネイティブ描画のうち **OS に依存しない部分** は全部ここに寄せてある（Pure Zig・全 OS でテスト）:

| 変換 | macOS | Win32 |
|---|---|---|
| ラベルのニーモニック `_F` | 除去（`File`） | `&F` へ（Windows の慣習） |
| リテラルの `_` / `&` | `__` → `_` | `__` → `_` / `&&` |
| アクセラレータ | `keyEquivalent` + modifier mask（**そのまま動作する**） | `\t` 右寄せの表示テキストのみ |
| コマンド ID | `NSMenuItem.tag` | `AppendMenuW` の ID（1 始まり、`WM_COMMAND` で戻る） |
| 深さ検証 | 「飛び級は `error.InvalidMenuDepth`」を 3 実装で共有 | 同左 |

`muda` は共有状態のラベルに `&` を使うが、Z-Ts は GTK の `_` を採用している
（既存の GTK 実装とそのテストを壊さないため）。**変換はバックエンド側** で行う。

### 4.3 AppKit / Win32 のアタッチ契約

| | macOS | Win32 |
|---|---|---|
| `set_as_app_menu` | `[NSApp setMainMenu:menu]` | 登録済みの全ウィンドウへ `SetMenu`（後から作られたウィンドウにも replay） |
| `set_as_window_menu` | `[window setMenu:menu]`（AppKit にウィンドウ固有のバーは無いが、`NSWindow.menu` はキーウィンドウ時のバー） | そのウィンドウだけ差し替え（ウィンドウメニューがアプリメニューに勝つ） |
| `popup` | `[NSMenu popUpMenuPositioningItem:atLocation:inView:]`（`Position` は top-left → Cocoa の下原点へ反転） | `TrackPopupMenu(TPM_RETURNCMD)`（同期で ID が返るので `WM_COMMAND` 不要） |
| 登録 API | `native.registerMenuWindow(label, ns_window)` | `native.registerMenuWindow(label, hwnd)` |

アクティベーションは macOS が共有ターゲットオブジェクトの `action:`、Win32 が
`SetWindowSubclass` で拾う `WM_COMMAND`（`LOWORD(wParam)`）。どちらも
`command - 1` を平坦リストの添字として `MenuId` に戻し、`Channel<string>` へ流す。
**webview 側は一切変更していない**（サブクラス化はメニュー側で完結する）。

### 4.4 Win32 のキーボードショートカット（既知の制限）

`HMENU` にはアイテム単位のショートカット欄が無いため、`Accelerator` は
`AppendMenuW` のラベルに `\tCtrl+N` として **表示** している。実際のキー入力は
ホストのメッセージループが `TranslateAcceleratorW` を呼ばないと動かない（未実装）。
macOS は `keyEquivalent` が AppKit 側で解決されるため、この制限は無い。

### 4.5 画面なし環境での検証

メニューはヘッドレスだと開けないが、**ウィジェットツリーは検証できる**。
`native_gtk.zig` は `GType` 名と `gtk_container_get_children` でツリーを読み返す
`describeMenuItem` / `nthChild` / `childCount` を公開し、テストは
「`_File` の下に New / separator / Exit、`Exit` は disabled、`Grid` はチェック済み」を
実際の GTK オブジェクトから assert する（CI は Xvfb 上で実行）。
アクティベーションは `g_signal_emit_by_name(item, "activate")` で発火させ、
`Channel<string>` に `MenuId` が届くことまで確認している。

macOS / Windows も同じ考え方で **実物を読み返す**:

* macOS: シムの `zts_menu_item_title` / `_key_equivalent` / `_state` / `_has_role` /
  `_submenu_at` で `NSMenuItem` を検査し、`zts_menu_fire` で `action:` を発火。
* Win32: `GetMenuItemCount` / `GetSubMenu` / `GetMenuStringW` / `GetMenuState` で `HMENU` を検査し、
  `SendMessageW(hwnd, WM_COMMAND, id, 0)` で **本物のメッセージ** を流して発火
  （サブクラス → `Activator` の経路が実際に通る）。

CI はこの実行を `OK menu-cocoa checks=` / `OK menu-win32 checks=` マーカーで機械的に確認する
（マーカーが無ければ「黙ってスキップされた」とみなして fail）。
