# ADR-0016: トレイは「メニュー backend の detached メニュー」を共有して描画する

- **Status**: Accepted（`M4-06`）
- **Date**: 2026-10-29
- **関連**: [`../tasks/M4-06-native-tray-cocoa-win32.md`](../tasks/M4-06-native-tray-cocoa-win32.md)、
  [`../architecture/tauri-menu-tray.md`](../architecture/tauri-menu-tray.md) §5、
  [`0015-native-menu-cocoa-win32.md`](0015-native-menu-cocoa-win32.md)、
  [`0013-menu-and-tray-backends.md`](0013-menu-and-tray-backends.md)

---

## 1. 背景

`M4-05` でメニューは 3 OS 対応になったが、トレイは GTK3（`GtkStatusIcon`）だけで、
macOS / Windows では `StubBackend` が `error.Unavailable` を返していた。結果として
「Linux だけトレイが出る」状態で、3 OS パリティに反していた。

トレイには **メニューを付けられる**（`TrayIcon.setMenu`）ことが必須要件で、しかも
クリックは `Channel<string>`（`MenuId`）に届かなければならない。ここが本質的な設計問題で、
「トレイ専用のメニュー実装」を書くとアクティベーション経路が二重化する。

## 2. 決定事項

### 2.1 メニュー backend に「detached メニュー」を公開し、トレイはそれを使う

`plugin:menu` のメニューは `MenuState`（`NSMenu` / `HMENU`）に紐付く。トレイのメニューは
ユーザーが作った `Menu` リソースを平坦化したものなので、**同じ変換層とアクティベータ**を
通す必要がある。そこで各バックエンドに「ラベルに紐付かないメニュー」を作る API を足した:

| | macOS | Win32 |
|---|---|---|
| 構築 | `menu/native_macos.zig buildDetached(snapshot) → *anyopaque` | `menu/native_windows.zig buildDetached(snapshot) → Detached` |
| 実体 | `NSMenu *`（`nsMenuOf(handle)`） | `HMENU` + `entries`（コマンド ID → `MenuId`） |
| 解放 | `freeDetached(handle)` | `Detached.deinit()` |
| 発火 | シムの共有ターゲット → `Activator` | `Detached.idForCommand(cmd)` → `fire(id)` |

これによりトレイのメニュー項目クリックは、メニューバーの項目クリックと
**同一のコードパス**で `Channel<string>` に到達する（新しい経路を増やさない）。

### 2.2 macOS は `target` / `action`、Win32 はメッセージ専用ウィンドウ

- **macOS**: `NSStatusItem.button` に `target`/`action` を付け、
  `sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)` で左右両方を受ける。
  右クリック（および `show_menu_on_left_click` 時は左クリック）は
  `[statusItem popUpStatusItemMenu:]`。`visible` は `NSStatusItem.visible`。
- **Win32**: `Shell_NotifyIconW` はコールバックメッセージの送り先 `HWND` を要求する。
  トレイ専用の **メッセージ専用ウィンドウ**（`CreateWindowExW` + `HWND_MESSAGE`）を
  1 枚だけ作り、`uID`（1 始まり）でトレイを引く。`NIN_SELECT` / `WM_LBUTTONUP` /
  `WM_LBUTTONDBLCLK` / `WM_RBUTTONUP` を `Emitter` に変換し、右クリックは
  `TrackPopupMenu(TPM_RETURNCMD)` の戻り値を `fire` に渡す。
  **webview のウィンドウプロシージャには一切触れない**（ADR-0015 §2.2 と同じ理由）。

### 2.3 トレイが無い環境は「バックエンドごと落とす」のではなく「シェルだけ諦める」

`Shell_NotifyIconW(NIM_ADD)` はタスクトレイ（`explorer.exe`）が無いと失敗する。
CI ランナーでは実際に失敗しうるので、`shell=0` を記録して **バックエンドは動かし続ける**
（ウィンドウ・状態・コールバック経路は実在する）。テストはシェルではなく
コールバックメッセージ `SendMessageW(hwnd, msg, uID, WM_LBUTTONUP)` を直接流し、
`Emitter` まで届くことを検証する。これで「画面なしでもアクティベーション経路は本物」を保てる。

### 2.4 アイコンは 3 形態を Map し、`resource(rid)` だけは明示的に縮退する

| 入力 | macOS | Win32 |
|---|---|---|
| `NativeIcon`（21 種） | SF Symbol 表（`About` → `info.circle` など、macOS 11+） | `IDI_APPLICATION`（Win32 にストックアイコン表が無い） |
| `JsImage.path` | `[NSImage initWithContentsOfFile:]` | `LoadImageW(LR_LOADFROMFILE)` |
| `JsImage.bytes` | `[NSImage initWithData:]` | `CreateIconFromResourceEx`（ICO / PNG 圧縮 ICO） |
| `JsImage.resource(rid)` | **縮退**（現状のトレイアイコンを維持） | 同左 |

`resource` は `plugin:resources` のテーブル（`zts_tauri_native` から見えない）を引く必要が
あるため、`M4-06` では **fail-closed ではなく現状維持**（＝黙って成功したふりをしない）とし、
未対応であることをロードマップに残す。画像として解釈できないバイト列も同様に落とさず、
既存のアイコン（無ければストック）へフォールバックする。

## 3. 検討した代替案

1. **トレイ専用にメニューを再実装する** — アクティベーション経路が二重化し、
   `MenuId` → `Channel` の対応表も二重になる。却下（§2.1）。
2. **Win32 でトレイの `HWND` に webview のウィンドウを使う** — コアが webview に依存する
   ことになり、`zts_webview` の依存方向（`zts_foundation` のみ）が壊れる。却下（§2.2）。
3. **`Shell_NotifyIconW` が失敗したらバックエンドを `Unavailable` にする** — CI で
   常に失敗し、テストが「何も検証しない」まま緑になる。却下（§2.3）。
4. **`resource` アイコンを黙って成功扱いにする** — ユーザーには「アイコンが消えた」としか
   見えず、原因も分からない。却下（§2.4）。

## 4. 結果

- トレイは 3 OS で描画される（GTK3 `GtkStatusIcon` / `NSStatusItem` / `Shell_NotifyIconW`）。
- トレイのメニュー項目は、メニューバーと同じ `Activator` を通って `Channel<string>` に届く。
- 画像アイコンは `NativeIcon` / `path` / `bytes` の 3 形態が動き、`resource` だけが未対応。
- 検証は CI の `OK tray-cocoa checks=4 menu=2` / `OK tray-win32 checks=9 ...` マーカーで機械化。
  マーカーが無い場合は「黙ってスキップされた」とみなして fail する。
- **残課題**: `resource(rid)` アイコン、Win32 のキーボードショートカット実動作
  （`TranslateAcceleratorW`、ADR-0015 §4.4 と同じ制限）。
