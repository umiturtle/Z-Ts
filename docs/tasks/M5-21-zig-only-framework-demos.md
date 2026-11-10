# Task M5-21: 全フレームワークデモに「Zig が無いと動かない」機能を入れる

- **Status**: `in_progress`
- **Branch**: `arena/23e66c7e-z-ts`（main `94a94db` = PR #19 マージ後）
- **Scope**: `examples/gallery/src/{main.zig,fw_assets.zig}`,
  `examples/gallery/build.zig`, `examples/gallery/src/web/fw/**`（9 デモの生成物）,
  `examples/frameworks/**`（9 デモのソース）, `scripts/gen-framework-demos.mjs`,
  `scripts/gen-framework-tutorials.py`, `src/docsite/frameworks.json`,
  `docs/learn/{ja,en}/tutorials/*`, `docs/INDEX{,.en}.md`,
  `examples/{gallery,frameworks}/README{,.en}.md`,
  `docs/architecture/screenshot-parity.md`, `scripts/check-docs.py`, `scripts/doc-sync.json`
- **Upstream Reference**: [`../architecture/screenshot-parity.md`](../architecture/screenshot-parity.md),
  [`../tasks/M5-20-framework-tutorial-variants.md`](../tasks/M5-20-framework-tutorial-variants.md)
- **Next Step**: 全チェックを通し、PR を 1 本作って 3 OS CI（特に `--require-zig`）を確認してマージ。

---

## 1. 依頼と完了条件

> 「Exampleで裏でZig走らせれてるかわからないので全フレームワークのデモでZigが動いてないとできないことして」

9 つのデモは今 **ローカル JS の状態だけ**で動いており、静的 HTML として開いても同じに見える。
「裏で Zig が動いているか」を画面から判定できないのが問題。したがって:

- [x] 9 デモすべてに **Zig 側の秘密鍵でしか作れない署名（seal）** を表示する
- [x] 9 デモすべてに **Zig が保持するカウンタ** を置き、`＋` / `−` が Zig のコマンドを呼ぶ
- [x] Zig が居ない（GitHub Pages の静的デモ）ときは **`ZIG OFFLINE`** と明示し、ボタンを無効化する
- [x] Gallery を **本物の Zig ホスト**にする（`ipc` スキーム＋ `js_bootstrap` の `invoke`）
- [x] 3 OS 同一バイト列・同一画素（seal / 初期値 / 文言を固定、時刻・乱数を使わない）
- [x] 日英 Doc 更新、規約 11 / 12 / 13 / 14 / 15 維持、**規約 16 を追加**、`AGENTS.md` と `milestones.md` のチェックボックスは触らない
- [ ] `quick-test` / `build test` / `doctest` / `fmt --check` / `docs-check` / 3 OS CI が緑
- [ ] PR は 1 本だけ

## 2. 設計

| 層 | 内容 |
|---|---|
| Zig ホスト | `examples/gallery/src/main.zig` が `ipc` スキームを登録し、`zig_probe` / `zig_inc` / `zig_dec` を実装。応答は `application/json`＋`Tauri-Response: ok`＋CORS ヘッダ |
| 署名 | `std.crypto.hash.sha2.Sha256(秘密 || コマンド || count)` の先頭 8 byte を hex 化。**秘密は Zig バイナリにだけ**あり、静的 JS では絶対に作れない |
| 注入 | 実物の [`js_bootstrap`](../../src/tauri/js_bootstrap.zig) を `DOCUMENT_START` に注入 → `window.__TAURI_INTERNALS__.invoke` が使える。さらに `__ZTS_ZIG__` ブリッジを注入 |
| 画面 | 共有 `APP_CSS` に `.zigbar` を追加。全 9 デモが **同じ DOM・同じ文言** のパネルを描く（3 OS 比較を壊さない） |
| 各 FW | 自分のライフサイクル（`useEffect` / `onMount` / `ngAfterViewInit` / `<script>`）から `mount()` を呼ぶ。probe が解決してから `{"app":"ready"}` を送るのでスクショが安定 |
| 静的デモ | ブリッジも bootstrap も無い → `ZIG OFFLINE`。**これ自体が「Zig が必要」の証明** |

## 3. 決定事項・注意

- 既存のローカルカウンタは残す（FW ごとの流儀と画素一致の比較対象として必要）。Zig パネルは**別枠**。
- 生成器を 1 箇所直して 9 個すべてを再ビルドする（コミット済み静的出力を手で継ぎ接ぎしない）。
  `node scripts/gen-framework-demos.mjs [name]` は npm registry 到達済みで 8 秒/個程度。
- 規約 16 で「9 つの `index.html` に Zig パネルがある」「Gallery が 3 コマンドを実装している」を機械検査し、
  デモだけ直してホストを忘れる／その逆を防ぐ。
- `learn_path.steps` の 5 ステップ・95 分は不変（分岐は代替の道のまま）。

## 4. 実装メモ（決定の追加分）

- 生成器は `ZIG_PANEL_HTML` / `ZIG_READY_JS` / `.zigbar` CSS を **1 箇所**だけ持ち、5 つのテンプレート
  （`appBody` / `jsxBody` / `svelteBody` / `angularBody` / `vueBody`）に `${ZIG_PANEL_HTML}` を差し込む。
  `reactBody` / `svelteKitBody` / `astroBody` はそこから派生するので 9 個すべてに波及する。
- `types/zts-globals.d.ts` は 9 プロジェクトすべてへ配布（従来は 3 つだけ）。`__ZTS_ZIG__` の
  宣言を規約 16 で検査する。
- トランスポートは 2 段: 本命は `fetch('ipc://localhost/<cmd>')`（`Tauri-Response: ok`＋CORS）、
  失敗時は `js_bootstrap` の `__ztsPostMessage` フォールバックを `onMessage` で受け、
  `evalJs` で `__TAURI_INTERNALS__.runCallback` を呼ぶ。WebKitGTK が独自スキーム POST を
  拒否しても同じ 3 コマンドに到達する。
- `manifest.json` の 9 件に `zig_online` を追加。`scripts/verify-screenshots.mjs --require-zig` を
  3 OS の CI と `ci-parity` の再検証に付けた。
- `ready_script` の計測セレクタに `.zigbar` 一式を追加し、3 OS の layout 指紋が新しいパネルも
  比較するようにした。`zig_count` はパターンごとに 0 へ戻す。
- `docs/learn/{ja,en}/tutorials/counter-*.md` の 18 本＋ chooser 2 本は
  `python3 scripts/gen-framework-tutorials.py` で再生成（付録「Zig が動いているかを画面で確かめる」）。
  `scripts/doc-sync.json` は `--sync --date 2026-10-21` で更新。

## Current State / Next Step

- **現在**: 実装・9 デモ再生成・規約 16・日英 Doc・同期台帳まで完了。ローカルでは
  `examples/gallery` の `build test` 8/8、`build install`、HeadlessMock 17 パターン、
  `gen-framework-tutorials.py --check` 20 ページ、`check-docs.py` 緑を確認済み。
- **次**: `quick-test` / `build test` / `doctest` / `fmt --check` / `build docs` を通し、
  PR を **1 本**作って 3 OS CI の `--require-zig` と Cross-OS parity を確認する。
