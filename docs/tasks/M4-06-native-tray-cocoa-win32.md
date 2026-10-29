# Task M4-06: AppKit / Win32 のシステムトレイ（`NSStatusItem` / `Shell_NotifyIconW`）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/tray/{native_nacos→native_macos,native_windows}.zig`,
  `src/tauri/tray/native_macos_shim.m`, `src/tauri/menu/{native_macos,native_windows}.zig`
  （detached メニューの公開）, `src/tauri/native.zig`, `build.zig`, `.github/workflows/ci.yml`,
  `docs/architecture/tauri-menu-tray.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`, 本ファイル
- **Upstream Reference**: `muda` 0.20 `src/platform_impl/macos/mod.rs`（`NSStatusItem` /
  `popUpStatusItemMenu` / `setImage`）、`src/platform_impl/windows/mod.rs`
  （`Shell_NotifyIconW` + `NOTIFYICONDATAW` + `NIN_SELECT` / `WM_RBUTTONUP`）、
  `tauri` 2.12.4 `crates/tauri/src/tray/mod.rs`
- **Next Step**: `tray/native_macos_shim.m` とシムの Tray ハンドルを実装し、
  `menu/native_macos.zig` に detached メニュー（tray 用）を公開する。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `M4-05` でメニューは 3 OS 対応になったが、トレイは GTK3（`GtkStatusIcon`）だけ。
macOS の `NSStatusItem` と Windows の `Shell_NotifyIconW` を実装し、
「Linux だけトレイが出る」状態を解消する。

- [ ] `tray/native_macos.zig` + `tray/native_macos_shim.m`
      （`NSStatusItem` / ツールチップ / タイトル / 可視性 / メニュー / 画像アイコン /
      左クリック・右クリック・ダブルクリックの `Emitter`）
- [ ] `tray/native_windows.zig`
      （`NOTIFYICONDATAW` + `Shell_NotifyIconW`、自前のメッセージ専用ウィンドウ、
      コールバックメッセージで Click / DoubleClick、右クリックで `TrackPopupMenu`）
- [ ] `menu/native_{macos,windows}.zig` に **detached メニュー**（tray 用）を追加
      （`MenuState` のアクティベータを共有するので `Channel<string>` へ届く）
- [ ] アイコン: `NativeIcon` / `JsImage.path` / `JsImage.bytes`（`resource` は未対応で縮退）
- [ ] `native.zig` の `trayBackend()` を 4 分岐に一般化
- [ ] 3 OS CI: `OK tray-cocoa checks=N` / `OK tray-win32 checks=N` マーカー + grep ゲート
- [ ] `quick-test` / `build test -Dgtk=true|false` / `fmt --check` / `check-docs`

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 本タスクシートの作成、`muda` 0.20 の tray 実装の読了
- **作業中・直前の状態**:
  - 実装着手前

---

## 3. 設計判断・技術メモ・ハマりどころ

- **メニューの共有**: トレイのメニューは `plugin:menu` が作ったメニュー（`Menu` / `Submenu`
  の `rid`）を平坦化したもの。クリックは **メニューバックエンドのアクティベータ** を通して
  `Channel<string>` に流す必要があるので、`native_{macos,windows}.zig` に
  「ラベルに紐付かない一時メニュー」を作る API を足して共有する。
- **macOS**: `NSStatusItem.button` に `target`/`action` を付け、右クリックは
  `popUpStatusItemMenu:`。`visible` は `statusItem.visible`。
- **Win32**: `Shell_NotifyIconW` はタスクトレイ（explorer.exe）が必要なので、CI ランナーで
  失敗しても **バックエンド自体は動く** ようにする（`shell=0` を記録し、クリック経路は
  コールバックメッセージを直接送って検証する）。
- **Win32 の `NOTIFYICONDATAW`**: 976 バイト（x86_64）。`cbSize` を間違えると
  `NIM_ADD` が無言で失敗するので、`@sizeOf` を comptime で固定する。
- **タイトル**: macOS は `button.title`、Win32 はツールチップに併記（Win32 にタイトル欄は無い）。
