# Task M6-04: 後続 7 タスクの実装

- **Status**: `in_progress` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/54b5d11d-z-ts`（main `9530b03` = PR #26 マージ後）
- **Scope**: `src/tauri/providers.zig`（新規）, `src/tauri/{path,plugins,monitor,mod}.zig`,
  `src/tauri/native.zig`, `src/tauri/native_gtk.zig`, `src/tauri/tray/native_gtk.zig`,
  `src/tauri/native_macos_shim.m`, `src/tauri/native_win32.zig`, `src/app_runtime.zig`,
  `src/cli/{template,main}.zig`, `build.zig`, `.github/workflows/ci.yml`,
  `docs/reference/compatibility{,.en}.md`, `docs/learn/{ja,en}/guides/plugins.md`,
  `scripts/check-docs.py`（規約 24）, `scripts/doc-sync.json`, 本ファイル
- **Upstream Reference**: [`M6-03-doc-meta-and-compatibility.md`](M6-03-doc-meta-and-compatibility.md) §4,
  [`../reference/compatibility.md`](../reference/compatibility.md)
- **Next Step**: `src/tauri/providers.zig` に `RuntimeProviders` を定義し、
  `DesktopConfig.providers` → `DesktopRuntime.create()` の 1 箇所で適用する。
  その後 store/single-instance → path → monitor → native wiring → template → GTK tray の順にコミット。

---

## 1. 依頼

> 「後続7タスクを実行して」

M6-03 §4 に記録した 7 件を**すべて実装**する。Doc に弱点を書くだけで終わらせない。

| # | タスク | 実装方針 |
|---|---|---|
| 1 | `PathState` の実 OS 初期化と `DesktopConfig` 既定への注入 | `PathState.fromEnvironment(allocator, io, identifier)` を追加。`RuntimeProviders.auto()` が呼び、`DesktopRuntime.create()` が `providers.path == null` なら自動適用。テストは `auto_detect=false` で決定論的 fixed values を維持 |
| 2 | 実 OS monitor provider を 3 バックエンドに登録 | `zts_tauri_native.providers()` が GDK `gdk_display_get_n_monitors` / `NSScreen.screens` / `EnumDisplayMonitors` + `GetDpiForMonitor` + カーソル位置の provider を返す。未登録なら既定の決定論的 1 台を維持（fail-closed） |
| 3 | `store` の保存方針・`clear` の保存・初期化診断 | `Options.autosave: bool = true` を追加し `set` / `delete` / `clear` がすべて `save()` を呼ぶ。`save` 明示コマンドは残す。初期化の `catch {}` を `RestoreDiagnostics`（`ok/missing/unreadable/malformed`）に記録し、黙って捨てない |
| 4 | `single-instance` の stale lock 回復とブラウザ挙動定義 | ロックファイルに `zts-lock-v2 <pid>` を書く。`PathAlreadyExists` 時に PID を読み、`process_alive` provider が「死んでいる」と判定したら削除して 1 回だけ再試行。**時刻は使わない**（決定性）。provider 未登録は fail-closed（ロック維持）。`lock_path=null` は「メモリのみ・常に primary」と Doc で定義 |
| 5 | `zts init` テンプレートの RPC 化と `zts dev` 範囲の明示 | `main.zig` に `State` + `Commands.increment` + `rpc.Schema` を同梱、`web/index.html` に `invoke("increment")` を呼ぶボタンと `ZIG OFFLINE` パネルを追加（1 embedded asset 維持で CLI smoke 互換）。`zts dev` の出力に「ブラウザでは Zig コマンドは届かない／`zts build` で確認」を明示 |
| 6 | ネイティブ backend 配線の 1 箇所集約 | `zts_tauri` に `RuntimeProviders` を置き、`DesktopRuntime.create()` が menu / tray / dialog / clipboard / monitor / path / process_alive を**一度に**適用。`zts_tauri_native.providers()` が OS 実装を全部詰めて返すので、アプリ側は 1 行で済む |
| 7 | GTK トレイの脱 `GtkStatusIcon` | CI に `libayatana-appindicator3-dev` が**既に入っている**ことを確認済み。`native_gtk.zig` に `AppIndicator` extern を追加し `tray/native_gtk.zig` を `app_indicator_new` / `app_indicator_set_menu` ベースへ移行、`build.zig` に `linkSystemLibrary` を追加。追加システム依存なし |

## 2. 完了条件（Definition of Done）

- [ ] 7 タスクすべてが実装され、それぞれに単体テストがある
- [ ] `RuntimeProviders` が `zts_tauri` にあり、`z_ts` は `zts_tauri_native` に依存しない（依存 DAG 維持、wasm 安全）
- [ ] `zts_tauri` は `link_libc = false` のまま。OS API はすべて `zts_tauri_native` 側
- [ ] 既定挙動は fail-closed（provider 未登録なら決定論的既定／Stub／`Unsupported`）
- [ ] 時刻・乱数・ファイル順に依存しない（stale lock は PID のみ、タイムスタンプ不使用）
- [ ] 3 OS 同一挙動。未対応は `error.Unsupported` 等で黙って成功させない
- [ ] 日英 Doc を更新（互換性ページの「弱点」を「実装済み／解決済み」へ）、規約 24 で再発を機械検査
- [ ] `learn_path.steps` の 5 ステップ・95 分不変、`AGENTS.md` / `milestones.md` チェックボックス非編集、
      規約 1–23 維持、同期台帳更新
- [ ] `quick-test` / `build test` / `doctest` / `docs-check` / `fmt --check` / 3 OS CI 緑、PR は 1 本だけ

## 3. 調査で確定した事実

| # | 事実 | 根拠 |
|---|---|---|
| 1 | `CorePluginStates.create(allocator, io, cfg.app, cfg.paths)` が `app_runtime.zig:86` で呼ばれ、`withMenuBackend` / `withTrayBackend` が別途存在 | `src/tauri/mod.zig:93-163` |
| 2 | `z_ts` モジュールの imports に `zts_tauri_native` は無い。ここに足すと wasm / クロスビルドが壊れる恐れ | `build.zig:314-329` |
| 3 | `zts_tauri_native` は `zts_tauri` に依存し、`link_libc` は OS ごとに true | `build.zig:236-254` |
| 4 | CI の apt に **`libayatana-appindicator3-dev` が既にある** | `.github/workflows/ci.yml:64` |
| 5 | `PluginState.init()` は `self.restore() catch {}`、`restore()` は `error.PersistFailed` を返す | `plugins.zig:133, 209` |
| 6 | `requestLock()` は `createFile(.exclusive=true)` のみ。ロックファイルに中身が無い | `plugins.zig:225-239` |
| 7 | `StoreCommands.save` は別コマンド、`set/delete/clear` は保存しない | `plugins.zig:256-325` |
| 8 | `monitor.Provider` は既に vtable（`list` / `cursor`）として完成、`setProvider` もある | `monitor.zig:57-130` |
| 9 | テンプレートの `main.zig` は `embedded_frontend` を print するだけ。`web/index.html` は 1 asset | `template.zig:320-337` |
| 10 | `z_ts` は `pub const rpc = @import("zts_rpc")` を再エクスポート | `src/root.zig:22` |
| 11 | `zts dev` は `DevServer.start` + `rebuild` で、`src/` も監視 | `src/cli/main.zig:443-520` |

## 4. 設計判断

| # | 判断 | 理由 |
|---|---|---|
| 1 | `RuntimeProviders` は **`zts_tauri` に置く** | `z_ts` と `zts_tauri_native` の両方が `zts_tauri` に依存するので、追加の import なしで共有できる |
| 2 | `z_ts` は `zts_tauri_native` を import しない | 依存 DAG と wasm / クロスビルドを守る。OS 実装は `providers()` の戻り値として**外から差し込む** |
| 3 | `DesktopConfig.providers` の既定 `.{}` で **path だけ自動検出** | ユーザー指摘 7「明示しないアプリが実在環境と違う場所を返す」を既定で解消。他は fail-closed のまま |
| 4 | stale lock は **PID のみ**、タイムスタンプ禁止 | 決定性。時刻は CI のスクリーンショット比較・再現性を壊す |
| 5 | `process_alive` は provider 経由、未登録なら「生きている」とみなしてロック維持 | 誤って解放するより fail-closed。3 OS 実装は `zts_tauri_native` に置く |
| 6 | `autosave` は既定 true、`store_path=null` なら no-op | 「保存を呼ばなければ残らない」を解消しつつ、既存のヘッドレス／テストを壊さない |
| 7 | テンプレートは **1 embedded asset を維持** | `ci-smoke` が `1 embedded assets` を検証しているため |
| 8 | appindicator 移行は追加依存なし | CI に既に入っており、`build.zig` の link を足すだけ |

## Current State / Next Step

- **現在**: 30 秒ルーチン緑、現ブランチは `main 9530b03` 起点で clean。7 タスクの対象ソースを精読し、
  `RuntimeProviders` を `zts_tauri` に置く共通設計を確定。分散ロック（この票）を push した直後。
- **次の 1 手**: `src/tauri/providers.zig` と `PathState.fromEnvironment()` を実装し、
  `DesktopRuntime.create()` に `providers` 適用を追加する（タスク 1・6 の骨格）。
