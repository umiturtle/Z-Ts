# ADR-0015: AppKit / Win32 のメニュー描画は「共通ワイヤ + サブクラス化」で行う

- **Status**: Accepted（`M4-05`）
- **Date**: 2026-10-29
- **関連**: [`../tasks/M4-05-native-menu-cocoa-win32.md`](../tasks/M4-05-native-menu-cocoa-win32.md)、
  [`../architecture/tauri-menu-tray.md`](../architecture/tauri-menu-tray.md)、
  [`0013-menu-and-tray-backends.md`](0013-menu-and-tray-backends.md)

---

## 1. 背景

`M4-03` は `plugin:menu` の wire 層と GTK3 実装を完成させたが、macOS と Windows の
バックエンドは `error.Unavailable` で fail-closed するスタブのままだった。結果として
「Linux だけメニューが出る」状態で、3 OS パリティ（`M5-05` の思想）に反していた。

## 2. 決定事項

### 2.1 OS 非依存の変換は 1 ファイルに集約する（`menu/snapshot_wire.zig`）

ラベルのニーモニック、macOS の `keyEquivalent` 表、Win32 のコマンド ID 採番、
深さ検証は **OS に依存しない**。これらを `native_*.zig` に分散させると、
Linux 上で検証できないコードが増える。`snapshot_wire.zig` に寄せれば
`./zigw quick-test`（Linux）で全 OS 分のロジックが回り、
バックエンドは「ツールキットを呼ぶだけ」の薄い層になる。

`muda` は共有状態のラベルに `&` を採用しているが、Z-Ts は既存の GTK 実装
（`gtk_menu_item_new_with_mnemonic` とそのテスト）を壊さないため `_` を維持し、
**バックエンド側で変換**する。

### 2.2 Win32 のアクティベーションは `SetWindowSubclass` で拾う

Win32 のメニューは `WM_COMMAND` をウィンドウプロシージャへ送る。Z-Ts の wndproc は
`zts_webview`（`link_libc = false` の純 Zig モジュール）にあり、**コアが
`zts_tauri` に依存してはならない**（`zts_webview` は `zts_foundation` のみ依存）。
したがって webview にメニュー用フックを足すのではなく、メニュー側が
`SetWindowSubclass`（`comctl32`）で自分だけのサブクラスを差し込む。
`WM_NCDESTROY` で自分を外すので、ウィンドウが先に壊れても dangling にならない。

### 2.3 `set_as_app_menu` は「登録済みの全ウィンドウ」に対する操作

Win32 にアプリケーションメニューバーは存在しない。GTK と同じく、
**メニューはウィンドウに属する** ので、ホストが `registerMenuWindow` で登録した
全ウィンドウへ `SetMenu` し、後から作られたウィンドウにも記録を replay する。
ウィンドウ固有のメニュー（`set_as_window_menu`）はアプリメニューに優先する。

### 2.4 macOS の `set_as_window_menu` は `NSWindow.menu`

AppKit のメニューバーはアプリ全体で 1 本だが、`NSWindow.menu` は
「そのウィンドウがキーのときに表示するバー」を指定できる。`muda` も同じ API を使うため、
「ウィンドウメニュー」はこの意味に統一する（何もしない、よりは意味がある）。

### 2.5 Win32 のショートカットは「表示のみ」

`HMENU` にはアイテム単位のアクセラレータ欄が無く、実際のキー入力は
メッセージループの `TranslateAcceleratorW` が解決する。Z-Ts はホストの
イベントループを持たない（`zts_webview` が持つ）ため、`\tCtrl+N` の**表示**に留め、
キー動作は既知の制限として文書化する。macOS は `keyEquivalent` が AppKit 側で
解決されるので制限が無い。

## 3. 検討した代替案

| 案 | 却下理由 |
|---|---|
| `zts_webview` の wndproc に `WM_COMMAND` フックを追加 | 依存方向が逆（webview → tauri）。`link_libc = false` も崩れる |
| `SetWindowLongPtrW(GWLP_WNDPROC)` でプロシージャを差し替え | 元のプロシージャを自前で保持/復元する必要があり、`SetWindowSubclass` の方が安全 |
| すべての描画を ObjC 側で行い、Zig は文字列を投げるだけ | 平坦リストの解釈が 2 言語に分裂し、テストも 2 箇所になる |
| Win32 でも `NSMenu` 相当の中間表現を作る | 中間表現が増えるだけで、`HMENU` は十分に宣言的 |
| `muda` に合わせてラベルを `&` に統一 | GTK 実装と既存テスト（`_New`）を書き換える価値が無い |

## 4. 結果

- 3 OS で **実際のツールキットオブジェクト** を組み、ツリー・ラベル・状態・
  アクセラレータ・アクティベーションをネイティブ API で読み返すテストが走る
  （CI は `OK menu-cocoa checks=` / `OK menu-win32 checks=` を必須マーカーとして検査）。
- 変換ロジック（ニーモニック・キー表・ID 採番）は Linux の `quick-test` でも検証できる。
- トレードオフ: Win32 のショートカットは表示のみ（§2.5）、
  macOS / Win32 のトレイと画像アイコンは未実装のまま `error.Unavailable`。
