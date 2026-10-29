# Task M4-05: AppKit / Win32 のネイティブメニュー描画（`M4-03` の残り）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/menu/{snapshot_wire,native_macos,native_windows}.zig`,
  `src/tauri/menu/native_macos_shim.m`, `src/tauri/native.zig`, `build.zig`,
  `.github/workflows/ci.yml`, `docs/architecture/tauri-menu-tray.md`,
  `docs/roadmap/m2-m5-platform-and-ecosystem.md`, 本ファイル
- **Upstream Reference**: `muda` 0.20 `src/platform_impl/macos/mod.rs`（`init_for_nsapp` /
  `create_ns_item` / `PredefinedMenuItemType::selector` / `show_context_menu`）、
  `src/platform_impl/windows/mod.rs`（`init_for_hwnd` / `menu_subclass_proc` /
  `insert_into` / `show_context_menu_for_hwnd`）、`src/accelerator/macos.rs`
  （`key_equivalent` の文字表）。`tauri` 2.12.4 の `Menu::set_as_app_menu` /
  `set_as_window_menu` / `popup`。
- **Next Step**: `snapshot_wire.zig`（純粋な共通ワイヤ + ラベル/アクセラレータ変換）を
  実装し、`./zigw quick-test` で全 OS 共通テストを通す。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `M4-03` で GTK3 だけだった `plugin:menu` のネイティブ描画を macOS（AppKit）と
Windows（Win32）にも広げ、「Linux だけメニューが出る」状態を解消する。`Snapshot` →
ネイティブウィジェットの**純粋変換**に留め、コアの wire 層は一切変更しない。

- [ ] `src/tauri/menu/snapshot_wire.zig`（OS 非依存・全 OS で単体テスト）
  - `Snapshot` → 検証済みの平坦リスト（depth の飛びは `error.InvalidMenuDepth`）
  - ラベルのニーモニック変換: コアの `_` を Win32 の `&` へ、macOS は除去（`__` → `_`）
  - macOS `keyEquivalent` 文字列（英数記号 + ファンクションキーの私用領域）
  - Win32 コマンド ID 採番（1 始まり / 上限 / `WM_COMMAND` からの逆引き）
- [ ] `src/tauri/menu/native_macos.zig` + `native_macos_shim.m`
  - `NSMenu` / `NSMenuItem` / サブメニュー / セパレータ / チェック状態 / 有効・無効
  - `Predefined` を AppKit のセレクタ（`terminate:`、`hide:`、`copy:` …）へ
  - `set_as_app_menu` = `[NSApp setMainMenu:]`、`set_as_window_menu` = `[window setMenu:]`
  - `popup` = `popUpMenuPositioningItem:atLocation:inView:`（`Position` は Cocoa 座標へ反転）
  - アクティベーションは `tag` → ブリッジオブジェクトの `action:` → `Activator`
- [ ] `src/tauri/menu/native_windows.zig`
  - `CreateMenu` / `CreatePopupMenu` / `AppendMenuW` / `SetMenu` / `DrawMenuBar`
  - ウィンドウのサブクラス化（`SetWindowSubclass`）で `WM_COMMAND` →
    `LOWORD(wParam)` を `MenuId` に戻して `Activator` へ
  - `popup` = `TrackPopupMenu(TPM_RETURNCMD)`（戻り値をそのまま起動、`WM_COMMAND` 非依存）
  - `WM_NCDESTROY` でサブクラスを外し、スタックしたウィンドウ登録を掃除（リーク 0）
- [ ] `native.zig` の `menuBackend()` / `registerMenuWindow()` を 4 分岐に一般化
- [ ] 3 OS CI: macOS / Windows で**実際に NSMenu / HMENU が組めた**ことを示すマーカー
      （`OK menu-cocoa checks=N` / `OK menu-win32 checks=N`）と、CI の grep ゲート
- [ ] `./zigw quick-test` / `./zigw build test -Dgtk=true|false` / `fmt --check` / `check-docs`

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `muda` 0.20 の macOS / Windows 実装を読了（セレクタ表・`MF_*` フラグ・
    `key_equivalent` の文字表・`menu_subclass_proc` の `WM_COMMAND` 処理）
  - 本タスクシートの作成
- **作業中・直前の状態**:
  - `src/tauri/menu/snapshot_wire.zig` 未着手

---

## 3. 設計判断・技術メモ・ハマりどころ

- **`_` がコアのニーモニック記号**（`M4-03` の GTK 実装が `*_with_mnemonic` を使う）。
  muda は逆に `&` を共有状態の記号にしているが、Z-Ts は既存テスト（`_New`）と
  GTK の自然な記法を維持し、**バックエンド側で変換**する。
- **macOS にウィンドウ固有のメニューバーは無い**が `NSWindow.menu` は存在する
  （そのウィンドウがキーのときのメニューバー）。muda も `set_as_window_menu` で
  `[window setMenu:]` を使うため、同じ挙動にする。
- **Win32 のサブメニューは `MF_POPUP` の ID 引数が HMENU**（コマンド ID ではない）。
  リーフだけが `WM_COMMAND` の対象。
- **`TrackPopupMenu(TPM_RETURNCMD)` は同期的に ID を返す**ので、ポップアップ中の
  アクティベーションに `WM_COMMAND` は不要（muda と同じ）。
- **macOS の Predefined は `target = nil`** にしてレスポンダチェーンへ流す
  （`terminate:` 等）。`About` だけはアプリ側で受ける必要があるため別扱い。
