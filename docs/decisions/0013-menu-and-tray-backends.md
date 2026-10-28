# ADR-0013: メニュー / トレイは「コアが真実・バックエンドは平板スナップショット」で実装する

- **Status**: Accepted（`M4-03`・ネイティブ描画は段階実装）
- **Date**: 2026-10-29
- **関連**: [`../tasks/M4-03-menu-tray.md`](../tasks/M4-03-menu-tray.md)、
  [`../architecture/tauri-menu-tray.md`](../architecture/tauri-menu-tray.md)、
  [`0012-dialog-and-clipboard-backends.md`](0012-dialog-and-clipboard-backends.md)

---

## 1. 背景

`@tauri-apps/api/menu` は **リソースグラフ**を操作する API である。`Menu` / `Submenu` /
`MenuItem` … はすべて `plugin:resources` の `rid` を持ち、`append` / `insert` / `remove` /
`set_text` がツリーを直接書き換え、項目の押下は `Channel<string>` で `MenuId` が返る。

Tauri 本家は `muda` が OS ごとにツリーを差分更新する。Z-Ts で同じ構成にすると:

- GTK / AppKit / Win32 の 3 実装がそれぞれ「差分適用」ロジックを持ち、**Linux 以外は CI で
  実行できない**（ヘッドレスでメニューを開けない）。
- どの OS でも検証できないコードパスがアプリの中核に入る。

## 2. 決定事項

### 2.1 コアが唯一の真実、バックエンドは `Snapshot` を受けて丸ごと再構築する

`menu.MenuState` が `Node` のツリーと `rid` / `MenuId` / チャネルを所有し、
**変更のたびに pre-order の平坦化リスト（`depth` 付き）**を作ってバックエンドに渡す。

- バックエンドは `applyAppMenu` / `applyWindowMenu` / `popup` の 3 関数だけを実装する。
- `Mock` はスナップショットを記録するので、**Linux / macOS / Windows の CI が同じ期待値を検証**できる。
- メニューは数十項目なので再構築コストは無視できる。

### 2.2 `rid` は既存の `plugin:resources` テーブルに載せる

`await menu.close()` を上流と同じ意味で動かすため。`Node.deinit` が親の子リストから自分を外し、
`app_menu` / `window_menus` の登録も解除するので、閉じたノードがツリーに残らない。

### 2.3 `MenuItemPayloadKind` は手書きデコード

`[rid, kind]` とオプションオブジェクトが混在する untagged 形状は `zts_rpc` の union では
表現できない。M4-01 の `MessageDialogButtons` と同じく、`std.json.Value` を経由する
`decodeZtsJson` フックで受ける。

### 2.4 アクセラレータはコアでパースする

`CmdOrCtrl+Shift+K` を各バックエンドが個別に解釈すると 3 実装がばらける。Pure Zig の
`accelerator.zig` が 1 か所でパースし、GTK 文字列 / Win32 `ACCEL` / macOS 修飾マスクへ
レンダリングする。**不正な文字列はエラー**（黙って無視しない）。

## 3. 検討した代替案

| 案 | 却下理由 |
|---|---|
| `muda` 相当の差分 API を vtable にする | 3 OS の差分ロジックがテスト不能なまま中核に入る |
| メニューを WebView の HTML で描く | OS ネイティブのメニューバー / トレイにならない |
| `plugin:menu` を丸ごと `comptime` で切り替える | 「アプリ側の分岐 0 行」制約に反する |
| アイコンの PNG デコードをコアに持つ | `zts_tauri` が `link_libc = false` を維持できなくなる（`zts_webview/png.zig` は別モジュール） |

## 4. 結果

- メニュー / トレイの **wire・ツリー・リソース・チャネル**が 3 OS で同一コードとして検証済み。
- ネイティブ描画は `Snapshot` を受けるだけなので、GTK / AppKit / Win32 の実装は
  「平坦化リストをウィジェットにする」純粋な変換になる（`M4-03` の後半で実装）。
- トレードオフ: 画像アイコン（`JsImage`）は wire として受理するが描画しない。
  ネイティブの stock icon（`NativeIcon`）とテキストのみ対応する。
