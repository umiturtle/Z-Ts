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
- **Next Step**: 生成器と Gallery の IPC を実装し、9 デモを再生成 → 規約 16 → 3 OS CI → PR 1 本。

---

## 1. 依頼と完了条件

> 「Exampleで裏でZig走らせれてるかわからないので全フレームワークのデモでZigが動いてないとできないことして」

9 つのデモは今 **ローカル JS の状態だけ**で動いており、静的 HTML として開いても同じに見える。
「裏で Zig が動いているか」を画面から判定できないのが問題。したがって:

- [ ] 9 デモすべてに **Zig 側の秘密鍵でしか作れない署名（seal）** を表示する
- [ ] 9 デモすべてに **Zig が保持するカウンタ** を置き、`＋` / `−` が Zig のコマンドを呼ぶ
- [ ] Zig が居ない（GitHub Pages の静的デモ）ときは **`ZIG OFFLINE`** と明示し、ボタンを無効化する
- [ ] Gallery を **本物の Zig ホスト**にする（`ipc` スキーム＋ `js_bootstrap` の `invoke`）
- [ ] 3 OS 同一バイト列・同一画素（seal / 初期値 / 文言を固定、時刻・乱数を使わない）
- [ ] 日英 Doc 更新、規約 11 / 12 / 13 / 14 / 15 維持、`AGENTS.md` と `milestones.md` のチェックボックスは触らない
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

## Current State / Next Step

- **現在**: 現状復元・設計完了。分散ロックのためこの票を先に push。
- **次**: `gen-framework-demos.mjs` に共有パネル／CSS／`ZIG_READY` を追加し、Gallery に IPC を実装。
