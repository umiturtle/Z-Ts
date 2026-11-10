# Task M5-22: ウィンドウ状態を「レジストリ止まり」からネイティブ反映へ

- **Status**: `done`
- **Branch**: `arena/3ebd6625-z-ts`（main `f345741` = PR #20 マージ後）
- **Scope**: `src/core/host.zig`, `src/webview/{types,mod,linux,macos,windows,mock,c_api}.zig`,
  `src/webview/macos_shim.m`, `src/webview/gtk_bindings.zig`, `src/webview_host.zig`,
  `src/app_runtime.zig`, `src/tauri/{window,event}.zig`, `tests/tauri/*`,
  `docs/architecture/*`, `docs/learn/{ja,en}/guides/plugins.md`,
  `docs/reference/tauri-usage{,.en}.md`, `scripts/check-docs.py`, `scripts/doc-sync.json`
- **Upstream Reference**: [`M5-19-tauri-gap-implementation.md`](M5-19-tauri-gap-implementation.md)
  （P1 #8 / #10 の到達点）、[`../architecture/zts-webview-backends.md`](../architecture/zts-webview-backends.md)
- **Next Step**: 完了。PR [#21](https://github.com/umiturtle/Z-Ts/pull/21) のマージ待ち。

---

## 1. 依頼と完了条件

> 「① OS イベント→`WindowRegistry` の自動反映、② `applyExtras` の `Host` 呼び出し、
> ③ `createWindow` での残り config 適用、④ 状態遷移の E2E 追加を順にやって」

現状調査（前ターン）で判明した 3 つの穴を、この順で埋める:

- [x] ① `is_maximized()` 等が OS 側の操作（タイトルバーボタン / OS ショートカット）に追従する
- [x] ② 17 本の `applyExtras` setter が `WindowExtras` を書き換えるだけでなく `Host` を呼ぶ
- [x] ③ `tauri.conf.json` の `center` / `maximized` / `skipTaskbar` / `alwaysOnBottom` / `focus` /
      `contentProtected` / `hiddenTitle` / `titleBarStyle` 等が `createWindow` で実際に効く
- [x] ④ `minimize()` / `setFullscreen()` / 状態往復の E2E を追加し 3 OS CI で検証する
- [x] 規約 17（ネイティブ状態配線の 3 OS 一致）を追加し、規約 1–16 を維持
- [x] 日英 Doc 更新、同期台帳更新、`learn_path.steps` の 5 ステップ・95 分は不変
- [x] `AGENTS.md` / `docs/roadmap/milestones.md` のチェックボックスは触らない
- [x] `quick-test` / `build test` / `doctest` / `fmt --check` / `docs-check` / 3 OS CI が緑
- [x] PR は 1 本だけ

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

- **現在**: ①〜④・規約 17・日英 Doc・同期台帳まで実装済み。ブランチ
  `arena/3ebd6625-z-ts`（分散ロック済み）。ローカル検証はすべて緑:
  `quick-test` 7 群（91 / 3 / 4 / 62 / 86 / 37 / 10）、`build test` exit 0、
  `doctest blocks=20`、`docs-check`（86 tests + `api_undoc=0`）、`fmt --check`、
  `gen-framework-tutorials.py --check` 20 pages、`prepare-tauri-e2e.mjs`（tsc + esbuild）、
  `x86_64-windows-gnu` クロスコンパイル 11/11 steps。
- **実装メモ**: `WindowStateKind` / `NativeStateKind` は同名・同順の 10 種。Cocoa shim の
  `ZTS_STATE_*` ordinal も規約 17 で照合。② の `WindowExtrasSnapshot` は `zts_foundation`
  に置き依存方向を維持。③ は `Engine.createWindow()` の 1 箇所で共通 6 オプションを適用し、
  残りは `WindowCreationOptions`（スカラ＋ハッシュ）として 4 バックエンドに記録。
  `tauri.conf.json` の未対応 OS 項目は capability として `docs/architecture/zts-webview-backends.md`
  に明記（黙って成功とはしない）。
- **3 OS CI**: run [`42792348569`](https://github.com/umiturtle/Z-Ts/actions/runs/42792348569)
  7/7 緑（Linux 9m34s / macOS 2m57s / Windows 6m55s / CLI smoke ×3 / Cross-OS parity）。
  PR #21 の 1 本のみ。macOS の Objective-C shim 実リンク・GTK の C ABI 埋め込み E2E も通過。
- **CI で直した 2 点**: Zig 0.17 に `Allocator.dupeZ` が無い（`dupeSentinel` に修正、規約 17 で
  再発防止）、および `createWindow()` の共通オプション適用が GTK 埋め込みウィンドウで
  `error.Unsupported` を返した（`toplevel` ガードを追加、規約 17 で検査）。
- **次**: 完了。`AGENTS.md` / `docs/roadmap/milestones.md` は触っていない。
