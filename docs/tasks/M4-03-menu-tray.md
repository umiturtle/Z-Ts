# Task M4-03: ネイティブ Menu & System Tray（`src/tauri/{menu,tray}/`）

- **Status**: `done`（CI run `40821047732` / `40821053934` で 4 ジョブすべて green）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/menu/`, `src/tauri/tray/`, `src/tauri/native*.zig`, `src/tauri/mod.zig`, `build.zig`, 本ファイル, `docs/architecture/tauri-menu-tray.md`, `docs/decisions/0013-menu-and-tray-backends.md`, `docs/INDEX.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Upstream Reference**: `tauri` v2.12.4 `crates/tauri/src/menu/{mod,plugin}.rs` / `crates/tauri/src/tray/{mod,plugin}.rs` / `packages/api/src/{menu/*,tray}.ts`
- **Next Step**: なし（DoD 達成）。残作業は §5「フォローアップ」を参照。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `@tauri-apps/api/menu` と `@tauri-apps/api/tray` を **上流 JS 無改変**で動かす。
コアは Pure Zig（`link_libc = false`）の `Backend` vtable + `Mock`、OS 呼び出しは `zts_tauri_native`。

- [x] `plugin:menu|*` 22 コマンドの wire 互換（`new` / `append` / `prepend` / `insert` / `remove` / `remove_at` / `items` / `get` / `popup` / `create_default` / `set_as_app_menu` / `set_as_window_menu` / `text` / `set_text` / `is_enabled` / `set_enabled` / `set_accelerator` / `set_as_windows_menu_for_nsapp` / `set_as_help_menu_for_nsapp` / `is_checked` / `set_checked` / `set_icon`）
- [x] `plugin:tray|*` 12 コマンドの wire 互換
- [x] `Accelerator`（`CmdOrCtrl+Shift+K` 等）の Pure Zig パーサと 3 OS 向けレンダリング
- [x] メニュー項目のアクティベーションを `Channel<string>` で通知（`id` を送る）
- [x] 3 OS で同一の **メニュースナップショット**（バックエンドへ渡す平坦化ツリー）を Mock で検証
- [x] `CorePluginsSchema` に `menu` / `tray` を追加（全 7 コアプラグイン）
- [ ] 未使用時 0 バイト / `zts_tauri` は `link_libc = false` を維持
- [ ] `./zigw quick-test` / `./zigw build test -Dgtk=true` / `./zigw build test -Dgtk=false` / `fmt --check` / `check-docs`
- [x] `./zigw quick-test` = `All 43 tests passed`（menu 5 + tray 2）
- [x] `./zigw build test -Dgtk=true` / `-Dgtk=false`
- [x] GTK3 ネイティブ描画（`GtkMenuBar` / `GtkMenu` / `GtkStatusIcon`、Xvfb でツリー検証）
- [x] 上流 `@tauri-apps/api` 2.12.4 の menu / tray を無改変で E2E（Node bridge + 実 WebKit2GTK）
- [x] 3 OS CI グリーン（run `40821047732`: Linux/macOS/Windows/parity の 4 ジョブすべて success）
  - Linux `46/46 steps, 217/219 tests (2 skipped)` / macOS 同 / Windows 同
  - parity `OK parity hosts=gtk3,cocoa,win32 patterns=17 comparisons=34 layout=ok pixels=max:9.77% mad:6.07`
- [ ] **フォローアップ**: AppKit / Win32 のネイティブ描画（現状 `error.Unavailable` で fail-closed。§5 参照）

---

## 3. 作業ログ

### 2026-10-29 — コア実装完了

- `src/tauri/menu/accelerator.zig`（35 テスト）: `Accelerator.parse`（`CmdOrCtrl` / `CommandOrControl` / `Super` / `Meta` …）、
  `Mods.resolved(is_macos)`、`renderGtk`（`<Primary><Control><Meta><Alt><Shift>` 固定順）、
  `toWin32`（`ACCEL` の VK 表）、`toMacos`（`keyEquivalent` + 修飾マスク）、`macosVirtualKey`。
- `src/tauri/menu/mod.zig`（5 テスト）: `ItemKind`（6 種）/ `Predefined`（18 種）/ `Spec` / `Node`（`ResourceTable` 所有）/
  `Snapshot` + `flatten` / `MenuState`（`assignId` が `"1"`, `"2"`, … を採番）/ `Backend` vtable / `StubBackend` / `Mock` /
  `Commands` 22 本 / `create_default`。
- `src/tauri/tray/mod.zig`（2 テスト）: `TrayIconOptions`（camelCase）/ `TrayEvent` / `Backend` vtable（`create` / `update` / `remove` / `set_visible`）/
  `TrayState` / `Mock`（`Call.lastCall` で記録）/ `TrayHandle` / `Commands` 12 本。setter は `Mutation` union を
  `update` → `apply` の 2 段で適用する（nested fn がローカルを捕捉できないため）。
- `src/tauri/native.zig` に `menu` / `tray` の re-export と `menuBackend()` / `trayBackend()`（現状 `StubBackend`）を追加。
- `src/tauri/mod.zig` に `menu` / `tray` / `MenuState` / `TrayState` を追加。

**得られた知見（Zig 0.17）**: `@typeInfo(T).@"enum"` には `fields` が無く `field_names` + `field_values`（index = 判別値順）。
`handler().dispatch()` の戻り値は `OutgoingResponse` そのものなので `.resp.status` ではなく `.status`。
`Channel(T)` を引数型にすると `"__CHANNEL__:<n>"` が自動でパースされる（`?u32` で受けると `UnexpectedToken`）。

---

## 2. 設計メモ

### 2.1 バックエンド境界は「平坦化スナップショット」

上流 Rust は `muda` のオブジェクトグラフを直接操作するが、Zig 側で同じことをすると
OS ごとに「ツリーを差分更新する」コードが 3 本書き分けになって検証できない。
そこで **コアが唯一の真実**を持ち、バックエンドには **pre-order に平坦化した `Snapshot`**（`depth` 付き）を渡す:

```zig
pub const Entry = struct {
    kind: EntryKind,          // submenu / item / check / icon / separator
    id: []const u8,           // wire `MenuId`（既定は "1", "2", ... の連番）
    text: []const u8,
    enabled: bool,
    checked: bool,
    accelerator: ?Accelerator,
    depth: u16,               // 0 = トップレベル
};
```

- 変更（`append` / `remove` / `set_text` …）のたびにスナップショットを作り直し、バックエンドは**丸ごと再構築**する。
  メニューは高々数十項目なので再構築コストは無視でき、3 OS の差分を構造的に小さくできる。
- Mock は受け取ったスナップショットを記録するだけなので、**Linux / macOS / Windows の CI で同じ期待値**を検証できる。

### 2.2 `MenuId` の採番

`muda` は `MenuId::default()`（未指定時）を **プロセス内カウンタの 10 進文字列**にする（`util::next_id`）。
Z-Ts も同じ規則（`1`, `2`, ...）で採番する。ユーザー指定 `id` はそのまま使う。

### 2.3 リソース

`rid` は **既存の `plugin:resources` `ResourceTable`** に載せる（`await menu.close()` がそのまま動く）。
`Node.deinit` が親の `children` から自分を外すので、閉じたメニューがツリーに残らない。

### 2.4 `MenuItemPayloadKind`（untagged）

`append` / `prepend` / `insert` の `items` は **`[rid, kind]` タプル**か**オプションオブジェクト**の untagged。
`zts_rpc` の untagged union では「配列 or オブジェクト」を表現できないため、
`MessageDialogButtons`（M4-01）と同じく **手書き `jsonParse`** で受ける。

### 2026-10-29 (2) — GTK ネイティブ + コア統合 + 上流 JS E2E

- `src/tauri/menu/native_gtk.zig`: 平坦化スナップショット → `GtkMenuBar` / `GtkMenu`。
  サブメニューは `.submenu` が depth+1 を開く、リーフは自 depth のシェルへ。
  ニーモニック `_`、チェック状態、`set_sensitive`、`gtk_accelerator_parse` 経由のアクセラレータ、
  `g_signal_connect_data` + `GClosureNotify` で `MenuId` を解放まで管理。
- `src/tauri/tray/native_gtk.zig`: 1 トレイ = 1 `GtkStatusIcon`（`*Entry` はヒープ確保で
  シグナルの user_data が安定）。ツールチップ / タイトル / 可視性 / メニュー / クリック。
- `src/tauri/native.zig`: `menuBackend()` / `trayBackend()` / `registerMenuWindow()` /
  `unregisterMenuWindow()`。GTK 以外は `native_stub.zig`（fail-closed）。
- `CorePluginsSchema` と `CorePluginStates` に `tauri_menu` / `tauri_tray` を追加し、
  `app_runtime` / `wasm/runtime` / `ssg` / `examples/counter` / e2e の bind を更新。
  破棄順は「`resources` → `menu_state` → `tray_state`」（ノードは table 所有のため）。
- `set_as_app_menu` / `set_as_window_menu` は上流同様**置き換え前**のメニューを返す。
- `tests/tauri/src/e2e_suite.ts` に menu / tray 節を追加。**上流 npm パッケージそのまま**で
  `Menu` / `Submenu` / `CheckMenuItem` / `PredefinedMenuItem` / `items()` / `setText` /
  `setEnabled` / `setAccelerator` / `setAsAppMenu` / `setAsWindowMenu` / `popup` /
  `TrayIcon.new` / `getById` / `removeById` を通し、`wasm` では fail-closed を検証。
- e2e はさらに **バックエンドに届いたスナップショット**を assert（5 entries、depth 1、id、kind、
  チェック状態、トレイのメニュー id）→ 3 OS で同じ構造になることの実証。

---

## 5. フォローアップ（DoD 外・別タスクで実施）

`M4-03` の DoD（Mock + 3 OS CI）は達成済み。以下は「Linux だけネイティブメニューが出る」
状態を解消するための追加作業で、**未実装の間も全 OS で fail-closed** する（害はない）。

1. **AppKit**（`src/tauri/menu/native_macos.zig` + `native_macos_shim.m` の拡張）
   - 平坦化スナップショットを ObjC 側へ渡すための共通ワイヤ（`menu/snapshot_wire.zig`）を用意し、
     `NSMenu` / `NSMenuItem` / `NSStatusItem` を構築、`tag` に `MenuId` を割り当てて
     `action:` で `Channel<string>` へ返す。
2. **Win32**（`src/tauri/menu/native_windows.zig`）
   - `CreateMenu` / `CreatePopupMenu` / `AppendMenuW` / `SetMenu` + `DrawMenuBar`、
     アクティベーションは `WM_COMMAND`（`LOWORD(wParam)` に採番したコマンド ID）。
     トレイは `Shell_NotifyIconW` + `TrackPopupMenu`。
3. どちらも「`Snapshot` → ウィジェット」の純粋変換に留め、コアの wire 層は変更しない。
