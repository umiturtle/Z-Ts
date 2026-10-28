# Task M4-01: ダイアログ & クリップボードプラグイン（`src/tauri/{dialog,clipboard}/`）

- **Status**: `done`（CI run `40691812369` で 4 ジョブすべて green）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/dialog/`, `src/tauri/clipboard/`, `src/tauri/{native,native_gtk,native_win32}.zig`, `src/tauri/native_macos_shim.m`, `build.zig`, 本ファイル, `docs/architecture/tauri-dialog-clipboard.md`, `docs/decisions/0012-dialog-and-clipboard-backends.md`, `docs/INDEX.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Upstream Reference**: `@tauri-apps/plugin-dialog` v2（`plugins/dialog/src/{commands,models}.rs` / `guest-js/index.ts`）、`@tauri-apps/plugin-clipboard-manager` v2（`plugins/clipboard-manager/src/commands.rs` / `guest-js/index.ts`）
- **Next Step**: なし。次は `M4-03`（メニュー & トレイ）または `M4-04`（config import / ACL）。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: Tauri v2 の `plugin:dialog|*` / `plugin:clipboard-manager|*` を、上流 JS を **1 行も改変せず** に
動かす。コア（`zts_tauri`）は Pure Zig のまま vtable + Mock で完結させ、OS 呼び出しは
別モジュール `zts_tauri_native` に隔離する。

- [x] `@tauri-apps/plugin-dialog` v2 の `open` / `save` / `message` を wire 互換で実装
- [x] `@tauri-apps/plugin-clipboard-manager` v2 の `write_text` / `read_text` / `write_html` / `clear` / `write_secret` を実装（画像系は保留）
- [x] 選択されたパスを `plugin:fs` の `Scope` へ **動的に付与**（本家 `tauri-plugin-dialog` と同じ挙動）
- [x] Pure Zig コア（`link_libc = false`）＋ native シム分離（`zts_tauri` は OS API を一切呼ばない）
- [x] 未使用時 0 バイト（`Backend` vtable を差し替えなければ native 層はリンクされない）
- [x] 3 OS（Linux GTK3 / macOS AppKit / Windows COM）で同一 wire 挙動
- [x] `./zigw quick-test` / `./zigw build test` / `./zigw build test -Dgtk=true` / `./zigw fmt --check` / `python3 scripts/check-docs.py` のパス
- [x] 3 OS CI グリーン（`40691812369`: Linux / macOS / Windows / parity すべて success）

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 上流仕様の確認（`/tmp` に取得した `commands.rs` / `models.rs` / `guest-js/index.ts`）:
    - `plugin:dialog|open` は `{ options }` を 1 引数で受け取り、戻り値は **untagged**（`null` / 文字列 / 文字列配列）。
    - `plugin:dialog|save` も `{ options }`、戻り値は `string | null`。
    - `plugin:dialog|message` は **フラット引数**（`message` / `title?` / `kind?` / `buttons?`）、戻り値は押下ラベル。
    - `kind` は serde で小文字（`info` / `warning` / `error`）、逆シリアライズは小文字化照合で未知 → `info`。
  - `dialog/mod.zig`: wire 型（`OpenDialogOptions` / `SaveDialogOptions` / `MessageRequest`）、
    `MessageDialogButtons`（externally tagged な 4 形状）、`Backend` vtable、`Mock`、`DialogState`（scope 付与）、
    `Commands`（`plugin:dialog|`）、`TestSchema`、`Fixture`、テスト 7 件。
  - `clipboard/mod.zig`: `Backend` vtable 6 関数（`writeText` / `readText` / `writeHtml` / `readHtml` / `clear` / `writeSecret`）、
    `Mock`、`ClipboardState`、`Commands`（`plugin:clipboard-manager|`）。
  - ネイティブ層 4 OS 分:
    - `dialog/native_gtk.zig` … `GtkFileChooserNative`（`directory` → `SELECT_FOLDER`）、`GtkMessageDialog`（response id 1..n）、`GSList` ミラー。
    - `clipboard/native_gtk.zig` … `gtk_clipboard_set_text` / `wait_for_text` / `set_with_data`（`text/html` + `text/plain;charset=utf-8`）+ `gtk_clipboard_store`。
    - `dialog/native_macos.zig` / `clipboard/native_macos.zig` … `native_macos_shim.m`（唯一の Objective-C）の C ABI を呼び、JSON を `std.json` でパース。
    - `dialog/native_windows.zig`（手書き COM vtable + `MessageBoxW`）/ `clipboard/native_windows.zig`（Win32 clipboard）。
    - `native_win32.zig` … OS 非依存の純関数（`FILEOPENDIALOGOPTIONS` ビット・フィルタレコード・UTF-16 変換・`MessageBox` ボタン/アイコン対応表）を **全 OS でコンパイル & テスト**。
- **最終状態**:
  - `./zigw quick-test` … `All 29 / 3 / 4 / 7 tests passed.`
  - `./zigw build test -Dgtk=true` … `46/46 steps succeeded; 78/80 tests passed (2 skipped)`（GTK 実機テストは `DISPLAY` 不在で skip）。
  - `./zigw build test -Dgtk=false` … `44/44 steps succeeded`。
  - Linux 側は `zts_tauri` スイート 31 件 + `zts_tauri_native` スイート（GTK 実機 2 件は `DISPLAY` 有無で skip）。
  - CI run `40691812369` = **4 ジョブすべて green**、parity は
    `OK parity hosts=gtk3,cocoa,win32 patterns=17 comparisons=34 layout=ok pixels=max:9.77% mad:6.07`（回帰なし）。
- **初回 CI run `40690192094` で踏んだこと（修正済み・再発防止）**:
  - macOS: `Allocator.dupeZ` が 0.17 に無い → `src/tauri/native_cstr.zig` の `allocZ`
    （`allocSentinel` + `@memcpy`）へ集約。`native_gtk.toZ` もこれに委譲。
  - Windows: `std.Thread.sleep` が 0.17 に無い → Win32 clipboard のリトライは `kernel32.Sleep` に。
  - macOS シム: 拡張子 → UTI は非推奨の `UTTypeCreatePreferredIdentifierForTag` ではなく
    `UTType typeWithFilenameExtension`（macOS 11 未満は `@available` でフィルタ無しに縮退）。
    `build.zig` に `-framework UniformTypeIdentifiers` を追加。
  - Windows テスト 2 件が `SyntaxError` / `.err`: テストが `C:\...` を JSON に素で埋めていた。
    → `Fixture.pathPayload`（`core.html_escape.writeJsonString`）と `path.joinWithStyle` に統一。
- **ハマりどころ（次に触る人向け）**:
  - GTK の `gboolean` は `c_int`。`if (!gtk_clipboard_set_with_data(...))` はコンパイルできない → `== 0` で判定。
  - `gtk_message_dialog_set_title` は **GTK3 に存在しない**（GTK4 のみ）→ `gtk_window_set_title(@ptrCast(widget), ...)`。
  - Pure Zig バインディングから `std.Io.Writer.Allocating` で文字列を組み立て、`gtk.toZ`（`allocSentinel` + `@memcpy`）で NUL 終端化する。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **`Backend` vtable 方式**: `dialog.Backend` は `open` / `save` / `message` の 3 関数、`clipboard.Backend` は 6 関数。
  `zts_tauri` は関数ポインタを呼ぶだけで、GTK / AppKit / COM の型を一切知らない。
  これにより **`zts_tauri` の `link_libc = false` を維持** したまま、3 OS のテストが同じコードで走る。
- **未使用時 0 バイト**: アプリがバックエンドを差し替えない限り `native_stub.zig`（全関数 `error.Unavailable`）が使われ、
  ネイティブシンボル（GTK / Cocoa / `ole32` 等）はリンクされない。
- **戻り値の untagged 性**: `plugin:dialog|open` は `rpc.RawJson` を返し、`"null"` / `"\"path\""` / `["a","b"]` を
  呼び出し側の要求に応じて組み立てる。上流 JS は `typeof result === 'string'` で分岐するため、
  **配列で返してはいけない場面**（`multiple: false`）を厳守する。
- **`MessageDialogButtons` は externally tagged**: `Ok` / `OkCancel` / `YesNo` / `YesNoCancel` はユニット、
  `OkCustom`（1 要素）/ `OkCancelCustom`（2 要素）はタプル。`serde` のデフォルト表現に合わせて
  `std.json` の `Value` を手で解釈する（`Button{ id, label }` は **id == label**、上流は押下ラベルを返す）。
- **スコープ付与**: `DialogState.scope` が非 null なら、選択されたパスを `fs.Scope` に `addRoot` する。
  `recursive` が真、または `directory` 選択のときのみ再帰許可（本家準拠）。
- **`MessageBoxW` は戻り値をラベルへ写像**: `IDOK`=1 / `IDCANCEL`=2 / `IDYES`=6 / `IDNO`=7。
  カスタムラベルは Win32 では表現できないため、`Ok` / `OkCancel` 系へ縮退させる。

---

## 4. 再開手順（Context Reset 後）

```bash
cd /home/user/Z-Ts
git status --short                       # 未コミットの M4-01 変更を確認
./zigw quick-test                        # 40 passed; 2 skipped
./zigw build test -Dgtk=true             # GTK バックエンドのコンパイル検証
./zigw fmt --check src/ build.zig
python3 scripts/check-docs.py
gh run list --branch arena/16ce0c2f-z-ts --limit 3
```

- ここが green なら `docs/tasks/M4-01-dialog-clipboard.md` の Status を `done` にして CI run ID を追記する。
