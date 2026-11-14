# Task M6-03: サイト MD の出所メタ・バージョン統一・互換性の正直な記述

- **Status**: `in_progress` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/f40ad6b0-z-ts`（main `326e55a` = PR #25 マージ後）
- **Scope**: `scripts/doc_meta.py`（新規）, `scripts/check-docs.py`（規約 23・規約 20 拡張・`--sync` 改修）,
  `scripts/gen-framework-tutorials.py`, `scripts/doc-sync.json`, 全サイト MD 末尾メタ,
  `docs/learn/{ja,en}/start.md`, `docs/learn/{ja,en}/tutorials/counter.md`,
  `docs/reference/compatibility{,.en}.md`（新規）, `docs/learn/{ja,en}/guides/plugins.md`,
  `docs/INDEX{,.en}.md`, `docs/contributing/doc-sync{,.en}.md`,
  `src/docsite/frameworks.zig`, `src/cli/template.zig`, `src/tauri/plugins.zig`（コメントのみ）, 本ファイル
- **Upstream Reference**: [`../contributing/doc-sync.md`](../contributing/doc-sync.md)（規約 13）,
  [`../architecture/tauri-feature-gap.md`](../architecture/tauri-feature-gap.md),
  [`../reference/tauri-usage.md`](../reference/tauri-usage.md)
- **Next Step**: `scripts/doc_meta.py` にメタの書式・strip・本文ハッシュを集約し、
  `--sync` が全サイト MD に 1 行メタを付与するよう改修。規約 23 で機械判別し、
  生成器も同じメタを出して rule 15 との整合を保つ。その後 2 の統一と 3〜9 の Doc 化。

---

## 1. 依頼（9 項目）と今回の範囲

| # | 指摘 | 今回の対応 |
|---|---|---|
| 1 | サイト関係の MD 自身に「いつのソースに対応」「最終書き換えはいつ」をメモし、後々機械判別 | **実装**: 全サイト MD 末尾に `zts-doc-meta` 1 行、`--sync` が付与、規約 23 が検査 |
| 2 | 入門ページが `0.1.0` を指す／リポジトリ URL 表記が混在 | **修正**: `0.1.1` 統一、`github.com` URL を `ZigguraTs` に統一、規約 20 で再発防止 |
| 3 | ネイティブは実装済みだが `CorePluginStates.create()` は Stub 初期化で配線が必要／GTK トレイは deprecated `GtkStatusIcon` | **Doc 化**＋`plugins.md` の「Linux は StubBackend」誤記を訂正 |
| 4 / 9 | `process.pid=0` / `os.version="ziggurats"` / `locale=null`、通知はアプリ内イベント、`opener` は provider 必須、HTTP/Updater/SQL は設計上不対応 | **Doc 化**: 「同じ書き方」と「同じ実機能」を分けて評価する互換性表 |
| 5 | `store.set/delete/clear` はメモリのみ、`save` が別コマンド、`clear` のコメントと実装が矛盾、初期化 `catch {}`、single-instance は stale lock 未回復 | **Doc 化**＋`clear` の doc comment を実装に合わせて修正（矛盾不可） |
| 6 | `zts dev` は `web/` 配信の開発サーバーで、ネイティブ WebView 上の IPC 確認ではない | **Doc 化** |
| 7 | `PathState` の既定が `/home/user` `/app/resources` `/app/bin` `/` 等の固定値、`DesktopConfig.paths` も空 | **Doc 化** |
| 8 | `monitor` の既定は 1920×1080 @1.0 の 1 台、カーソル (0,0)、実 OS provider 未登録 | **Doc 化** |
| — | 3〜9 の**実装側の修正**（3 OS 実装・E2E を伴う） | **今回は範囲外**。§4 に後続タスクとして明記し、1 つの PR に混ぜない |

## 2. 完了条件（Definition of Done）

- [ ] サイトが公開する全 MD（内部資料・生成 56 ページを含む）の末尾に
      `<!-- zts-doc-meta: source-version=… verified=… last-rewritten=… -->` が 1 つだけ付く
- [ ] メタの `source-version` が `build.zig.zon`、`verified` が台帳 `verified.date`、
      `last-rewritten` が台帳のページ日付と一致することを**規約 23 が機械検査**する
- [ ] `--sync` がメタを自動付与し、`changed` 判定はメタを除いた本文で行う（日付が無限に進まない）
- [ ] 生成 56 ページも同じメタを持ち、`gen-framework-tutorials.py --check` が緑のまま
- [ ] 読者向けの `zts version` / ダウンロード例がすべて `0.1.1`、
      `github.com/umiturtle/Z-Ts` が読者面に残らない（規約 20 拡張）
- [ ] 日英の互換性リファレンスが 3〜9 を正確に記述し、既存の過大評価・誤記を訂正
- [ ] `StoreCommands.clear` のコメントと実装の矛盾を解消
- [ ] `learn_path.steps` の 5 ステップ・95 分不変、`AGENTS.md` / `docs/roadmap/milestones.md` の
      チェックボックス非編集、日英 2 言語、同期台帳更新
- [ ] `quick-test` / `build test` / `doctest` / `docs-check` / `fmt --check` / 3 OS CI 緑、PR は 1 本だけ

## 3. 調査で確定した事実

| # | 事実 | 根拠 |
|---|---|---|
| 1 | `check-docs.py` の `md_files` は `AGENTS.md` + `README*` + `docs/**/*.md` の 219 件。`examples/*/README*.md` も docsite は公開 | 181 行目 / `zig-out/docs/examples/` |
| 2 | 規約 13 は `sha256_file()` で**全文**ハッシュ、`run_sync()` は `changed = prev != jh` で判定 | 700 行付近 |
| 3 | docsite は `<!-- ... -->` を directive として扱う。`framework-picker` / `source:` は展開、未知のコメントは Markdown が出力しない | `src/docsite/main.zig:583-593` |
| 4 | `start.md` 日英が `v0.1.0` / `zts-0.1.0-*` / `zts 0.1.0`、`counter.md` 日英も `zts 0.1.0` | grep |
| 5 | `github.com/umiturtle/Z-Ts` が 97 箇所、`ZigguraTs` が 27 箇所 | grep |
| 6 | `src/tauri/native.zig` は `is_gtk` / `is_macos` / `is_win32` で menu/tray/dialog/clipboard を選択 | 43-91 行 |
| 7 | `src/tauri/tray/native_gtk.zig` は自ら `GtkStatusIcon is deprecated` と記述 | 3 行目 |
| 8 | `plugins.zig`: `os.version → "ziggurats"`、`locale → null`、`pid → 0` | 403, 408, 432 行 |
| 9 | `StoreCommands.clear` の doc comment は「writes the empty state back to disk」だが実体は `clearRetainingCapacity()` のみ | 283-291 行 |
| 10 | `runDev` は `DevServer.start(...)` で `web/` を配信 | `src/cli/main.zig:443-462` |
| 11 | `PathState` 既定は `/home/user` `/app/resources` `/app/bin` `/` | `src/tauri/path.zig:93-117` |
| 12 | `Monitor` 既定は 1920×1080 / scale 1.0 / (0,0)。コメントも「deterministic default」と明記 | `src/tauri/monitor.zig:6-35` |
| 13 | **`docs/learn/ja/guides/plugins.md:257` に「Linux では `StubBackend`」という誤記が残る**（ご指摘 3 の訂正対象）。`:152` の「未実装の WindowOptions は無視される」も M5-22 で実装済みなのに古い | grep |

## 4. 設計判断

| # | 判断 | 理由 |
|---|---|---|
| 1 | メタは **末尾の 1 行 HTML コメント** | 規約 7 の「先頭 12 行の banner」を壊さない。docsite は未知のコメントを出力しない。front matter は H1 位置をずらす |
| 2 | 「いつのソース」は `source-version` + `verified`（台帳の確認日）で表し、**コミット SHA は台帳 1 箇所** | 全 MD に SHA を埋めると `--sync` のたびに 219 ファイルが変わる。台帳を引けば SHA に辿れるので機械判別は可能 |
| 3 | `changed` 判定は**メタを strip した本文**、台帳 `*_sha256` は**メタ込み全文** | メタの書き換え自体で `last-rewritten` が進む自己言及を防ぎつつ、規約 13 の全文ハッシュ検査を維持 |
| 4 | 内部資料（ADR / tasks / architecture）の `last-rewritten` は git の最終コミット日 | 台帳対象外なので `--sync` が `git log -1 --format=%cs` で埋める |
| 5 | 生成器も同じ `doc_meta.meta_line()` を呼ぶ | rule 15 の verbatim 比較を壊さない。書式の単一の真実は `doc_meta.py` |
| 6 | github.com URL は **`ZigguraTs` に統一**、チェックアウトのパス名（`/path/to/Z-Ts`）は据え置き | 実在リポジトリ名。規約 14 は「旧称を URL に残してよい」のであって「残す義務」ではない。履歴資料は除外 |
| 7 | 実装弱点の修正は別タスク | 3 OS ネイティブ実装・provider 登録・E2E を伴い、Doc 整合の PR と混ぜるとレビュー不能 |

### 後続タスク（未着手・この票で宣言のみ）

1. `PathState` を実 OS の `$HOME` / `%APPDATA%` / `XDG_*` / exe パスから初期化し、`DesktopConfig` の既定に注入
2. 実 OS 用 monitor provider を 3 バックエンドに登録（マルチモニター・HiDPI・カーソル位置）
3. `store` の `save` 自動化方針の決定、`clear` の保存呼び出し、初期化 `catch {}` の診断化
4. `single-instance` の stale lock 検出・回復（PID / タイムスタンプ）とブラウザ環境の挙動定義
5. `zts init` テンプレートに最小の RPC コマンドと `invoke` 呼び出しを同梱し、`zts dev` の範囲を明示
6. `CorePluginStates.create()` からネイティブ backend への配線を 1 箇所に集約する手順の整備
7. GTK トレイの `GtkStatusIcon` を `libayatana-appindicator` 等へ移行

## Current State / Next Step

- **現在**: 30 秒ルーチン緑（`quick-test` / `check-docs.py` / `fmt --check`）、現ブランチは
  `main 326e55a` 起点で clean。9 項目の事実確認完了。分散ロック（この票）を push した直後。
- **次の 1 手**: `scripts/doc_meta.py` を作り、`check-docs.py` の `run_sync()` と規約 23、
  生成器を同じ書式に揃える。その後 2 の統一と互換性 Doc を書く。
