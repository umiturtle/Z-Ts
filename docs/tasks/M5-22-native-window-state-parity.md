# Task M5-22: ウィンドウ状態を「レジストリ止まり」からネイティブ反映へ

- **Status**: `in_progress`
- **Branch**: `arena/3ebd6625-z-ts`（main `f345741` = PR #20 マージ後）
- **Scope**: `src/core/host.zig`, `src/webview/{types,mod,linux,macos,windows,mock,c_api}.zig`,
  `src/webview/macos_shim.m`, `src/webview/gtk_bindings.zig`, `src/webview_host.zig`,
  `src/app_runtime.zig`, `src/tauri/{window,event}.zig`, `tests/tauri/*`,
  `docs/architecture/*`, `docs/learn/{ja,en}/guides/plugins.md`,
  `docs/reference/tauri-usage{,.en}.md`, `scripts/check-docs.py`, `scripts/doc-sync.json`
- **Upstream Reference**: [`M5-19-tauri-gap-implementation.md`](M5-19-tauri-gap-implementation.md)
  （P1 #8 / #10 の到達点）、[`../architecture/zts-webview-backends.md`](../architecture/zts-webview-backends.md)
- **Next Step**: ① OS イベント → `WindowRegistry` 自動反映、② `applyExtras` の `Host` 呼び出し、
  ③ `createWindow` での残り config 適用、④ 状態遷移の E2E 追加。この順で 1 項目ずつ
  `quick-test` を通しながら進める。

---

## 1. 依頼と完了条件

> 「① OS イベント→`WindowRegistry` の自動反映、② `applyExtras` の `Host` 呼び出し、
> ③ `createWindow` での残り config 適用、④ 状態遷移の E2E 追加を順にやって」

現状調査（前ターン）で判明した 3 つの穴を、この順で埋める:

- [ ] ① `is_maximized()` 等が OS 側の操作（タイトルバーボタン / OS ショートカット）に追従する
- [ ] ② 17 本の `applyExtras` setter が `WindowExtras` を書き換えるだけでなく `Host` を呼ぶ
- [ ] ③ `tauri.conf.json` の `center` / `maximized` / `skipTaskbar` / `alwaysOnBottom` / `focus` /
      `contentProtected` / `hiddenTitle` / `titleBarStyle` 等が `createWindow` で実際に効く
- [ ] ④ `minimize()` / `setFullscreen()` / 状態往復の E2E を追加し 3 OS CI で検証する
- [ ] 規約 17（ネイティブ状態配線の 3 OS 一致）を追加し、規約 1–16 を維持
- [ ] 日英 Doc 更新、同期台帳更新、`learn_path.steps` の 5 ステップ・95 分は不変
- [ ] `AGENTS.md` / `docs/roadmap/milestones.md` のチェックボックスは触らない
- [ ] `quick-test` / `build test` / `doctest` / `fmt --check` / `docs-check` / 3 OS CI が緑
- [ ] PR は 1 本だけ

## 2. 変えてはいけない制約（M5-19 から継続）

1. `@tauri-apps/api` v2 無改変、上流と同じコマンド名
2. アプリ側にターゲット別分岐 0 行（成果物差は comptime `RuntimeMode` / `Host` vtable で表現）
3. `zts_webview` は `zts_foundation` のみ依存、`zts_tauri` は `link_libc = false`
4. 決定性（時刻・乱数・ファイル順に依存しない）
5. 3 OS 同一挙動。未対応は黙って成功させず `error.Unsupported` / `error.Unavailable` で fail-closed
6. 内部 Doc と読者 Doc の分離、日英 2 言語
7. `core.Host` にメソッドを足したら `RecordingHost`（Mock）でテスト → 3 OS のバックエンドで実装

## 3. 設計方針（調査後に確定・更新する）

| # | 層 | 方針 |
|---|---|---|
| ① | `zts_webview` | `types.WindowStateEvent` + `WindowStateHandler` を追加し `Engine.setWindowStateHandler()` で登録。3 OS のネイティブイベント（GTK `window-state-event` / configure、Cocoa delegate、Win32 `WM_SIZE` / `WM_ACTIVATE`）→ `Engine` → `DesktopRuntime` → `WindowRegistry.applyNativeState()`。`is_*` が実状態を返すようになり、`tauri://resize` 等もネイティブ起点で出る |
| ② | `core.Host` | `applyWindowExtras(win, snapshot)` を 1 メソッド追加。スナップショットは所有権なしのスカラ構造体（`zts_core` 側に定義し依存方向を守る）。`applyExtras` が `t.host` を呼んでからレジストリ更新。3 OS + Mock が同じ契約で受け取り、OS で適用可能な項目を反映 |
| ③ | `createWindow` | `WindowConfig` の未読フィールドを 3 OS の `createWindow` で適用。`maximized` / `center` / `focus` / `skipTaskbar` / `alwaysOnBottom` / `contentProtected` などをウィンドウ生成直後に `setMaximized` / `setPosition` / `setFocus` / `setAlwaysOnBottom` 等へ渡す |
| ④ | E2E | `tests/tauri/src/e2e_suite.ts` に `minimize` / `unminimize` / `setFullscreen` / `is*` の往復を追加。`HeadlessMock` の `simulateWindowStateEvent` で ① を単体テスト |

## Current State / Next Step

- **現在**: 30 秒ルーチン完了（ブランチ `arena/3ebd6625-z-ts`、HEAD `f345741`、Open PR は #9 のみ、
  ワークツリー clean、`quick-test` 7 群 / `check-docs.py` / `fmt --check` すべて緑）。
  分散ロックのためこの票を先に push。
- **次**: 既存の `WindowExtras` / `TrackedWindow` / `event.dispatchRaw` / 各バックエンドの
  イベント配線を読み、① のインターフェースを確定してから実装に入る。
