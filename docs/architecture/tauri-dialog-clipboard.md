# `plugin:dialog` / `plugin:clipboard-manager` — OS ダイアログ & クリップボード

`src/tauri/{dialog,clipboard}/` は `@tauri-apps/plugin-dialog` v2 と
`@tauri-apps/plugin-clipboard-manager` v2 の wire 互換実装。**コアは Pure Zig（`link_libc = false`）** で、
OS の GUI / クリップボードに触れるのは別モジュール `zts_tauri_native` だけ（設計判断は
[ADR-0012](../decisions/0012-dialog-and-clipboard-backends.md)）。

```text
フロントエンド（上流 JS を無改変）
  import { open, save, message } from '@tauri-apps/plugin-dialog'
  import { writeText, readText } from '@tauri-apps/plugin-clipboard-manager'
        │  invoke('plugin:dialog|open', { options })
        ▼
zts_tauri  dialog.Commands.open → DialogState.backend.open(...)   ← 関数ポインタ（vtable）
        │                                   │
        │（未使用時は native_stub: error.Unavailable を返すだけ。シンボル 0）
        ▼                                   ▼
zts_tauri_native                      Mock（テスト用・全 OS 共通）
  native_gtk.zig  / native_macos.zig  / native_windows.zig
  └─ GTK3            AppKit(+ObjC シム)   COM + MessageBoxW
        │
        ▼
  選択パス → fs.Scope.addRoot（`recursive` または `directory` のとき再帰）
```

## 1. モジュール構成

| ファイル | モジュール | 役割 |
|---|---|---|
| `dialog/mod.zig` | `zts_tauri` | wire 型、`MessageDialogButtons`（手書き JSON フック）、`Backend` vtable、`Mock`、`DialogState`（scope 付与）、`Commands` |
| `clipboard/mod.zig` | `zts_tauri` | `Backend` vtable 6 関数、`Mock`、`ClipboardState`、`Commands` |
| `native.zig` | `zts_tauri_native` | ターゲット別バックエンド選択（`dialogBackend()` / `clipboardBackend()` / `describe()`） |
| `native_gtk.zig` | `zts_tauri_native` | GTK3 / GDK3 / GLib の Pure Zig バインディング（`@cImport` 不使用）。`toZ` / `fromGtkAlloc` も提供 |
| `native_win32.zig` | `zts_tauri_native` | **OS 非依存の純関数**（`FILEOPENDIALOGOPTIONS` ビット、フィルタレコード、UTF-16 変換、`MessageBox` 対応表）。全 OS でコンパイル＆テスト |
| `dialog/native_gtk.zig` | `zts_tauri_native` | `GtkFileChooserNative` + `GtkMessageDialog`（`GSList` ミラー） |
| `dialog/native_macos.zig` | `zts_tauri_native` | C ABI シムの JSON を `std.json` でパース |
| `dialog/native_windows.zig` | `zts_tauri_native` | 手書き COM vtable（`IFileOpenDialog` / `IFileSaveDialog`）+ `MessageBoxW` |
| `clipboard/native_*.zig` | `zts_tauri_native` | `GtkClipboard` / `NSPasteboard` / Win32 clipboard |
| `native_macos_shim.m` | `zts_tauri_native` | **唯一の Objective-C**。`zts_native_*` C ABI |
| `dialog/native_stub.zig`, `clipboard/native_stub.zig` | `zts_tauri_native` | 全関数 `error.Unavailable`（GUI 無しターゲット） |

## 2. `plugin:dialog|*`

### 2.1 コマンド表

| コマンド | 引数（wire） | 戻り値 |
|---|---|---|
| `plugin:dialog\|open` | `{ "options": OpenDialogOptions }` | `string` / `string[]` / `null`（**untagged**） |
| `plugin:dialog\|save` | `{ "options": SaveDialogOptions }` | `string` / `null` |
| `plugin:dialog\|message` | **フラット**: `message`, `title?`, `kind?`, `buttons?` | 押下されたボタンのラベル |

`open` / `save` は戻り値が型付き union で表現できないため **`rpc.RawJson`** を返す。
上流 JS は `typeof result === 'string'` で分岐するので、次の規則を厳守する:

| 条件 | 返す JSON |
|---|---|
| キャンセル（`Selection.paths.len == 0`） | `null` |
| 1 件のみ（`multiple == false` または `directory == true`） | `"path"`（文字列。**配列にしない**） |
| 複数件（`multiple == true` かつ `directory == false`） | `["a","b"]` |

### 2.2 `OpenDialogOptions` のフィールド

`title?` / `filters` / `multiple` / `directory` / `defaultPath?` / `recursive` / `canCreateDirectories?` /
`pickerMode?` / `fileAccessMode?`（デスクトップのバックエンドは `pickerMode` / `fileAccessMode` を無視するが、
wire 形状を落とさないために型として保持する）。

- `defaultPath` は **末尾 `/` でディレクトリ判定**（上流準拠）。
- `filters` は `{ name, extensions }`。`*` はワイルドカードとして扱う（Win32 では `*.*` に写像）。

### 2.3 `message` の `buttons`（externally tagged）

serde のデフォルト表現は 3 形状が混在するため、`MessageDialogButtons` は `jsonParse` / `jsonStringify` を
自前で持つ（`zts_rpc` の union スタイルでは表現できない）。

| wire | 意味 | 既定ラベル |
|---|---|---|
| `"Ok"` | OK のみ | `Ok` |
| `"OkCancel"` | OK / Cancel | `Ok` / `Cancel` |
| `"YesNo"` | Yes / No | `Yes` / `No` |
| `"YesNoCancel"` | Yes / No / Cancel | `Yes` / `No` / `Cancel` |
| `{"OkCustom":"Accept"}` | 単一カスタム | `Accept` |
| `{"OkCancelCustom":["Accept","Decline"]}` | 2 カスタム | — |
| `{"YesNoCancelCustom":["Y","N","C"]}` | 3 カスタム | — |

`Button.id == Button.label`（上流は押下ラベルをそのまま返す）。並び順は **yes → no → ok → cancel**
（`labels(&out)` の順）。`kind` は小文字化照合で `info` / `warning` / `error`、未知は `info`。

### 2.4 選択結果のスコープ付与

`DialogState.scope`（`withScope` で注入）が非 null のとき、選択された全パスを `fs.Scope.addRoot` する。
`recursive` は `directory and recursive` のときのみ真（本家 `tauri-plugin-dialog` と同じ）。

```zig
var dialog_state = tauri.dialog.DialogState
    .init(alloc, io, native.dialogBackend())
    .withScope(&fs_state.scope);
```

`addRoot` が失敗した場合のエラーコードは `ScopeRejected`（→ RPC の `OutOfScope` 系）。

## 3. `plugin:clipboard-manager|*`

| コマンド | 引数 | 戻り値 |
|---|---|---|
| `plugin:clipboard-manager\|write_text` | `{ text, label? }` | `null` |
| `plugin:clipboard-manager\|read_text` | `{}` | `string` |
| `plugin:clipboard-manager\|write_html` | `{ html, altText? }` | `null` |
| `plugin:clipboard-manager\|clear` | `{}` | `null` |
| `plugin:clipboard-manager\|write_secret` | `{ text }` | `null` |

画像系（`write_image` / `read_image`）は **未実装**（`plugin:resources|` の `rid` 連携が必要なため保留）。

## 4. ネイティブ実装の対応表

| OS | ダイアログ | クリップボード |
|---|---|---|
| Linux | `GtkFileChooserNative`（`directory` → `SELECT_FOLDER`）、`GtkMessageDialog`（response id は 1 始まり） | `gtk_clipboard_set_with_data`（`text/html` info=0 / `text/plain;charset=utf-8` info=1）+ `gtk_clipboard_store` |
| macOS | `NSOpenPanel` / `NSSavePanel` / `NSAlert`（ObjC シムが JSON を返し、Zig が `std.json` でパース） | `NSPasteboard`（`org.nspasteboard.ConcealedType` で履歴マネージャに秘匿を通知） |
| Windows | `IFileOpenDialog` / `IFileSaveDialog`（手書き COM vtable・27 スロット）+ `MessageBoxW` | `CF_UNICODETEXT` / `HTML Format`（`Version:0.9` ヘッダ + Start/EndHTML/Fragment）、`write_secret` は履歴除外 |

`write_secret` の「履歴に残さない」は OS ごとに手段が異なるためベストエフォート（上流も同様）。

## 5. エラーコード

| エラー | 発生条件 |
|---|---|
| `Unavailable` | ネイティブバックエンドが無い（`native_stub`、`DISPLAY` 不在など） |
| `Failed` | OS がダイアログ提示 / クリップボード操作に失敗 |
| `ScopeRejected` | 選択パスを `fs.Scope` に付与できなかった |
| `OutOfMemory` | 確保失敗 |

## 6. テスト戦略

- **全 OS 共通**: `native_win32.zig` の純関数（オプションビット、フィルタレコード、`MessageBox` 対応表）、
  `dialog` / `clipboard` の wire 層（`Mock` バックエンド経由の RPC 往復、untagged 戻り値、scope 付与）。
- **GTK 実機**: `DISPLAY` がある場合のみ実行し、無ければ `error.SkipZigTest`（CI は Xvfb 前提にしない）。
- **コンパイル検証**: `./zigw build test -Dgtk=true` が GTK バックエンドの C シンボル解決まで行う。
  macOS / Windows は CI の 3 OS マトリクスでコンパイルされる。
