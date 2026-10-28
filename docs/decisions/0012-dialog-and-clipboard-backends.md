# ADR-0012: `dialog` / `clipboard` を vtable + ネイティブ分離で実装する

- **Status**: Accepted（`M4-01`）
- **Date**: 2026-10-28
- **関連**: [`../tasks/M4-01-dialog-clipboard.md`](../tasks/M4-01-dialog-clipboard.md)、
  [`../architecture/tauri-dialog-clipboard.md`](../architecture/tauri-dialog-clipboard.md)、
  [`0011-scoped-fs-plugin.md`](0011-scoped-fs-plugin.md)、
  [`0004-tauri-v2-wire-and-deterministic-tsgen.md`](0004-tauri-v2-wire-and-deterministic-tsgen.md)

---

## 1. 背景

`plugin:dialog` と `plugin:clipboard-manager` は、これまでの `zts_tauri` のプラグインと決定的に性質が異なる:
**OS の GUI / クリップボード API を直接叩く必要がある**。

一方、Z-Ts の `zts_tauri` は **`link_libc = false` の Pure Zig** であり、GTK / Cocoa / Win32 に依存できない。
さらに上位の制約として、`zts_webview` は `zts_foundation` のみに依存する独立ライブラリであり続ける必要があり、
共通基盤に OS GUI の型が漏れてはならない。

さらに実運用上、次の 3 つが同時に求められる:

| 要件 | 内容 |
|---|---|
| **wire 互換** | 上流 `@tauri-apps/plugin-dialog` / `-clipboard-manager` の JS を 1 行も変えずに動く |
| **3 OS 同一挙動** | Linux / macOS / Windows で `null` / 文字列 / 配列 の返し分けが完全一致する |
| **未使用時 0 バイト** | プラグインを使わないアプリに GTK / Cocoa / `ole32` のシンボルを 1 つもリンクしない |

## 2. 決定事項

### 2.1 コアは `Backend` vtable、OS 呼び出しは別モジュール

```text
zts_tauri（Pure Zig, link_libc = false）
  src/tauri/dialog/mod.zig      … wire 型 + Commands + DialogState + Backend vtable + Mock
  src/tauri/clipboard/mod.zig   … Commands + Backend vtable + Mock
        ▲ 関数ポインタ 3 本 / 6 本
        │
zts_tauri_native（OS GUI に触れてよい唯一のモジュール）
  src/tauri/native.zig          … Backend の束ね役 + describe()
  native_gtk.zig / native_win32.zig … OS 非依存の純関数（全 OS でコンパイル・テスト）
  dialog/native_{gtk,macos,windows,stub}.zig
  clipboard/native_{gtk,macos,windows,stub}.zig
  native_macos_shim.m           … 唯一の Objective-C
```

- `zts_tauri` は GTK / AppKit / COM の**型名すら知らない**（関数ポインタのシグネチャだけを知る）。
- バックエンドを差し替えない限り `native_stub.zig`（全関数 `error.Unavailable`）が使われ、
  ネイティブシンボルはリンクされない → **未使用時 0 バイト** が自然に成立する。
- DCE は「`Backend` をフィールドに持つ状態構造体をアプリが構築するか」だけで決まり、
  `comptime` フラグの分岐を各所に書く必要がない。

### 2.2 `open` / `save` の戻り値は `rpc.RawJson`（untagged）

上流は `open()` の戻り値を `string | string[] | null`、`save()` を `string | null` として返す。
RPC 層の型付き戻り値では表現できないため、**生 JSON をそのまま組み立てて返す**。

- `multiple: false` または `directory: true` で 1 件 → **文字列**（配列にしない）。
- キャンセル → **`null`**（`""` でも `[]` でもない）。
- 選択結果は `DialogState.scope` がある場合 `fs.Scope` に `addRoot` する（本家と同じ「選んだものは触れる」挙動）。

### 2.3 `message` の `buttons` は externally tagged のまま受ける

`MessageDialogButtons` は serde のデフォルト表現で `Ok` / `OkCancel` / `YesNo` / `YesNoCancel`（ユニット）と
`OkCustom(String)` / `OkCancelCustom(String, String)`（タプル）が混在する。
`std.json` の `Value` を手で解釈し、押下された **ラベル文字列** を返す（`Button.id == Button.label`）。

### 2.4 ネイティブ実装の OS 別方針

| OS | ダイアログ | クリップボード |
|---|---|---|
| Linux | `GtkFileChooserNative`（`directory` → `SELECT_FOLDER`）+ `GtkMessageDialog`（response id 1..n） | `gtk_clipboard_set_with_data`（`text/html` + `text/plain;charset=utf-8`）+ `gtk_clipboard_store` |
| macOS | `NSOpenPanel` / `NSSavePanel`（`Cocoa` シムが JSON を返す）+ `NSAlert` | `NSPasteboard`（`org.nspasteboard.ConcealedType` で履歴マネージャに秘匿を通知） |
| Windows | `IFileOpenDialog` / `IFileSaveDialog`（手書き COM vtable）+ `MessageBoxW` | `Win32` clipboard（`CF_UNICODETEXT` / `HTML Format`、`write_secret` は履歴除外） |

`write_secret` は OS ごとに「履歴に残さない」手段が異なるため、**ベストエフォート** とし、
失敗しても書き込み自体は成立させる（上流も同様）。

### 2.5 macOS だけ Objective-C シムを許可する

`@cImport` を使わない方針のため、ObjC のメッセージ送信は Pure Zig では書けない。
**`src/tauri/native_macos_shim.m` の 1 ファイルのみ** を ObjC とし、C ABI（`zts_native_*`）で公開する。
Zig 側は `extern "c"` 宣言 + `std.json` パースのみを行う。

## 3. 検討した代替案

| 案 | 却下理由 |
|---|---|
| `zts_tauri` から直接 `@cImport` で GTK / Cocoa を呼ぶ | `link_libc = false` が崩れ、3 OS テストが GUI 無しで走らなくなる |
| プラグイン全体を `comptime` フラグで丸ごと切り替える | アプリ側の分岐が 0 行という制約に反する。テストも OS ごとに別物になる |
| ダイアログを WebView の JS で実装する | OS ネイティブのファイル選択 UI にならず、上流と体験が一致しない |
| 戻り値を型付き `union` にする | 上流の untagged 性（`string` か `string[]` か）を表現できず、JS 側の `typeof` 分岐が壊れる |

## 4. 結果

- `zts_tauri` は **Pure Zig のまま**、`dialog` / `clipboard` の wire 層と 3 OS のテストを同一コードで実行できる。
- `zts_tauri_native` は OS GUI に触れる唯一のモジュールとなり、依存の漏洩がモジュール境界で止まる。
- 未使用時 0 バイトは「バックエンドを差し替えるか」という 1 点で決まり、`comptime` 分岐の散在を避けられる。
- トレードオフ: 実 OS のダイアログ / クリップボードはテストできない（`DISPLAY` 不在時は `error.SkipZigTest`）。
  代わりに **OS 非依存の純関数（`native_win32.zig`）と wire 層** を全 OS でテストし、
  ネイティブ層は CI のコンパイル検証に留める。
