# Task M4-06: AppKit / Win32 のシステムトレイ（`NSStatusItem` / `Shell_NotifyIconW`）

- **Status**: `done`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/tray/{native_macos,native_windows}.zig`,
  `src/tauri/tray/native_macos_shim.m`, `src/tauri/menu/{native_macos,native_windows}.zig`
  （detached メニューの公開）, `src/tauri/native.zig`, `build.zig`, `.github/workflows/ci.yml`,
  `docs/architecture/tauri-menu-tray.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`, 本ファイル
- **Upstream Reference**: `muda` 0.20 `src/platform_impl/macos/mod.rs`（`NSStatusItem` /
  `popUpStatusItemMenu` / `setImage`）、`src/platform_impl/windows/mod.rs`
  （`Shell_NotifyIconW` + `NOTIFYICONDATAW` + `NIN_SELECT` / `WM_RBUTTONUP`）、
  `tauri` 2.12.4 `crates/tauri/src/tray/mod.rs`
- **Next Step**: なし（完了）。次の候補は ACL の権限スコープ `{path:…}` 適用、`zts migrate` CLI、
  Win32 のショートカット実動作（`TranslateAcceleratorW`）。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `M4-05` でメニューは 3 OS 対応になったが、トレイは GTK3（`GtkStatusIcon`）だけ。
macOS の `NSStatusItem` と Windows の `Shell_NotifyIconW` を実装し、
「Linux だけトレイが出る」状態を解消する。

- [x] `tray/native_macos.zig` + `tray/native_macos_shim.m`
      （`NSStatusItem` / ツールチップ / タイトル / 可視性 / メニュー / 画像アイコン /
      左クリック・右クリック・ダブルクリックの `Emitter`）
- [x] `tray/native_windows.zig`
      （`NOTIFYICONDATAW` + `Shell_NotifyIconW`、自前のメッセージ専用ウィンドウ、
      コールバックメッセージで Click / DoubleClick、右クリックで `TrackPopupMenu`）
- [x] `menu/native_{macos,windows}.zig` に **detached メニュー**（tray 用）を追加
      （`MenuState` のアクティベータを共有するので `Channel<string>` へ届く）
- [x] アイコン: `NativeIcon` / `JsImage.path` / `JsImage.bytes`（`resource` は未対応で縮退）
- [x] `native.zig` の `trayBackend()` を 4 分岐に一般化
- [x] 3 OS CI: `OK tray-cocoa checks=N` / `OK tray-win32 checks=N` マーカー + grep ゲート
      （ゲートは `ci.yml` の macOS / Windows ジョブ）
- [x] `quick-test` / `build test -Dgtk=true|false` / `fmt --check` / `check-docs`

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 本タスクシートの作成、`muda` 0.20 の tray 実装の読了
  - `menu/native_macos.zig`: `detached` レジストリ + `buildDetached` / `freeDetached` / `nsMenuOf`
  - `menu/native_windows.zig`: `Detached{hmenu, entries, deinit, idForCommand}` + `buildDetached` + `fire`
  - `tray/native_macos_shim.m`: `zts_tray_*`（22 関数、SF Symbol 表、`target`/`action`、
    `popUpStatusItemMenu:`）
  - `tray/native_macos.zig`: vtable 5 関数 + 参照系 + テスト 3 本
  - `tray/native_windows.zig`: vtable 5 関数 + メッセージ専用ウィンドウ + テスト 3 本
  - `native.zig` の tray 4 分岐化 / `build.zig` に tray シム / `ci.yml` に grep ゲート 2 本
- **検証済み**:
  - `build test -Dgtk=false` → `44/44 steps`
  - `build test -Dgtk=true` → `46/46 steps; 55/62 tests (7 skipped)`
  - `build test -Dtarget=x86_64-windows-gnu` → 全ステップ **コンパイル成功**
    （`unable to spawn foreign binary` は Linux ホストでの想定内）
  - `aarch64-macos` の Zig 型チェック（`zig test -fno-emit-bin`、C シム抜き）→ 成功
  - `fmt --check src/ tests/ build.zig` → 成功
- **3 OS CI（run `40839036292`、commit `3c8017e`）**:
  - macOS: `OK tray-cocoa checks=4 menu=2`（`OK menu-cocoa checks=6 items=3` と併存）
  - Windows: `OK tray-win32 checks=9 shell=<0|1> menu=2`（`shell=` はタスクトレイの有無。
    ランナーに `explorer.exe` が無くてもテストはコールバックメッセージ直送で通る）
  - Linux: `46/46 steps; 55/62 tests (7 skipped)` / parity ジョブも success → **4/4 green**
- **作業中・直前の状態**:
  - 完了。ADR-0016・architecture §5・ロードマップ・INDEX を追記済み

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
