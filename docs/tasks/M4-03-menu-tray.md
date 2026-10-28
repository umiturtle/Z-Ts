# Task M4-03: ネイティブ Menu & System Tray（`src/tauri/{menu,tray}/`）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/menu/`, `src/tauri/tray/`, `src/tauri/native*.zig`, `src/tauri/mod.zig`, `build.zig`, 本ファイル, `docs/architecture/tauri-menu-tray.md`, `docs/decisions/0013-menu-and-tray-backends.md`, `docs/INDEX.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Upstream Reference**: `tauri` v2.12.4 `crates/tauri/src/menu/{mod,plugin}.rs` / `crates/tauri/src/tray/{mod,plugin}.rs` / `packages/api/src/{menu/*,tray}.ts`
- **Next Step**: コア（wire 層 + Mock + アクセラレータ）を実装 → GTK ネイティブ → macOS シム → Win32。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: `@tauri-apps/api/menu` と `@tauri-apps/api/tray` を **上流 JS 無改変**で動かす。
コアは Pure Zig（`link_libc = false`）の `Backend` vtable + `Mock`、OS 呼び出しは `zts_tauri_native`。

- [ ] `plugin:menu|*` 22 コマンドの wire 互換（`new` / `append` / `prepend` / `insert` / `remove` / `remove_at` / `items` / `get` / `popup` / `create_default` / `set_as_app_menu` / `set_as_window_menu` / `text` / `set_text` / `is_enabled` / `set_enabled` / `set_accelerator` / `set_as_windows_menu_for_nsapp` / `set_as_help_menu_for_nsapp` / `is_checked` / `set_checked` / `set_icon`）
- [ ] `plugin:tray|*` 12 コマンドの wire 互換
- [ ] `Accelerator`（`CmdOrCtrl+Shift+K` 等）の Pure Zig パーサと 3 OS 向けレンダリング
- [ ] メニュー項目のアクティベーションを `Channel<string>` で通知（`id` を送る）
- [ ] 3 OS で同一の **メニュースナップショット**（バックエンドへ渡す平坦化ツリー）を Mock で検証
- [ ] 未使用時 0 バイト / `zts_tauri` は `link_libc = false` を維持
- [ ] `./zigw quick-test` / `./zigw build test -Dgtk=true` / `./zigw build test -Dgtk=false` / `fmt --check` / `check-docs`
- [ ] 3 OS CI グリーン

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
