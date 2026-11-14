# Task M6-02: 3 チュートリアル × 9 ライブラリの分岐を充実させる

- **Status**: `in_progress` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/70a7eede-z-ts`（main `b488746` = PR #24 マージ後 / v0.1.1 リリース後）
- **Scope**: `scripts/gen-framework-tutorials.py`, `src/docsite/frameworks.json`,
  `docs/learn/{ja,en}/tutorials/{counter,todo,ui}.md`,
  `docs/learn/{ja,en}/tutorials/{counter,todo,ui}-*.md`（生成物）,
  `docs/learn/{ja,en}/tutorials/{index,frameworks}.md`, `docs/INDEX{,.en}.md`,
  `scripts/check-docs.py`（規約 22）, `scripts/doc-sync.json`, 本ファイル
- **Upstream Reference**: [`M5-20-framework-tutorial-variants.md`](M5-20-framework-tutorial-variants.md),
  [`../learn/ja/tutorials/todo.md`](../learn/ja/tutorials/todo.md),
  [`../learn/ja/tutorials/ui.md`](../learn/ja/tutorials/ui.md),
  [`../../examples/gallery/src/main.zig`](../../../examples/gallery/src/main.zig)
- **Next Step**: 調査完了後、生成器にライブラリ別プロファイル（状態プリミティブ・Zig 同期・SSR ガード・
  Todo/UI の読み替え・落とし穴・コード断片）を追加し、counter / todo / ui の 3 テンプレートから
  9×3×2 = 54 分岐ページを生成する。規約 22 で完全性を機械検査し、PR 1 本にまとめる。

---

## 1. 依頼と完了条件（Definition of Done）

> 「チュートリアルをもっと各ライブラリごとにしっかりし、3つのチュートリアル全対応にして
> （signalとzig側の連携などの大事な要素をちゃんとさらって）」

- [ ] `counter` / `todo` / `ui` の **3 本すべて**に 9 ライブラリ分の分岐ページを用意する
      （日英 54 ページ＋選択ハブ 2 ページ）
- [ ] 各ページがライブラリ固有の**状態プリミティブ**（`createSignal` / `signal()` / Svelte 5 rune /
      `ref()` / `useState` / DOM 直接など）を説明する
- [ ] **Zig 側との連携**を全ページでさらう: `zig_probe` / `zig_inc` / `zig_dec`、`ipc://` と
      `window.__ZTS_ZIG__`、SHA-256 seal、ローカル状態と Zig 所有カウンタの**二重構造**、
      「楽観更新せず Zig の戻り値だけを正にする」、`ZIG OFFLINE` / `ZIG ONLINE`、
      `invoke` 失敗時の UI 状態、SSR / ハイドレーションのガード
- [ ] 各ライブラリ固有のコード断片（counter 同期 / Todo リスト / UI 3 状態）を載せる
- [ ] 3 本の本体チュートリアルと選択ハブ・日英索引から全分岐へリンクする
- [ ] 規約 22 で「カタログ ↔ プロファイル ↔ 生成ページ ↔ ハブ」の一致を機械検査する
      （規約 15 の verbatim excerpt は counter の実物 example に対して維持）
- [ ] `learn_path.steps` の 5 ステップ・95 分は不変（分岐は追加の章ではなく代替の道）
- [ ] 日英 Doc と同期台帳を更新、`AGENTS.md` / `docs/roadmap/milestones.md` の
      チェックボックスは非編集
- [ ] `quick-test` / `build test` / `doctest` / `docs-check` / `fmt --check` / 3 OS CI が緑、PR は 1 本だけ

## 2. 現状調査

| # | 事実 | 根拠 |
|---|---|---|
| 1 | チュートリアル本体は `counter.md` / `todo.md` / `ui.md` の 3 本（日英） | `docs/learn/{ja,en}/tutorials/` |
| 2 | ライブラリ分岐は `counter-<fw>.md` の 9 本だけ。`todo-<fw>.md` / `ui-<fw>.md` は存在しない | 同上 |
| 3 | `tutorials/index.md` は「3 本ともフロントエンドだけ 9 ライブラリから選べる」と書いているが実装が追いついていない | `docs/learn/ja/tutorials/index.md` |
| 4 | 生成器は 20 ページ（`VARIANT_JA/EN` ×9 + `CHOOSER_JA/EN`） | `scripts/gen-framework-tutorials.py` |
| 5 | `frameworks.json` に `state_ja/en`・`note_ja/en` はあるが、Zig 連携の記述は薄い | `src/docsite/frameworks.json` |
| 6 | Zig 側の正本は `examples/gallery/src/main.zig` の `zig_probe` / `zig_inc` / `zig_dec` + `ipc://` + seal | 同ファイル 78–95, 334–407 行 |
| 7 | `todo.md` は「構造体に閉じた状態・失敗の返し方」、`ui.md` は「画面は戻り値だけから描く」を説く | 両ファイル |
| 8 | 規約 11 は `docs/learn/**/*.md` 全ページを `docs/INDEX.md` がリンクすることを要求 | `scripts/check-docs.py` 447 行付近 |

## 3. 設計判断（調査後に更新）

| # | 判断 | 理由 |
|---|---|---|
| 1 | 分岐ページは「本体の読み替え差分」として作り、Zig 側のコードは 1 文字も変えない | 既存 `counter-<fw>.md` の約束と規約 15 を維持 |
| 2 | ライブラリ別プロファイルは生成器内の 1 辞書に集約し、規約 22 がカタログと照合 | 単一の真実。日英の解説・コード断片を 1 箇所で管理 |
| 3 | 分岐ページの索引カバレッジは `tutorials/index.md` の 3×9 表に集約し、規約 11 に明示的な例外を置く | 54 行を `docs/INDEX.md` に並べると読みやすさが壊れる。代わりに規約 22 が完全性を検査 |
| 4 | counter の実物 example 抜粋はそのまま。`todo` / `ui` のコードは「読者が書くコード」として明示 | 規約 15 の verbatim 契約を守りつつ、3 本とも動く手順を示す |
| 5 | 二重状態（ローカル signal と Zig 所有カウンタ）を全ページの共通章で説明 | ユーザーが特に求めた「signal と zig 側の連携」の中核 |

## Current State / Next Step

- **現在**: 30 秒ルーチン（`quick-test` / `check-docs.py` / `fmt --check`）は緑。現ブランチは
  `main b488746` 起点で clean。分散ロック（この票）を push した直後。
- **次の 1 手**: `examples/gallery/src/web/zig-bridge.js` と `counter-<fw>.md` の付録、
  `todo.md` / `ui.md` の「別のライブラリで読む」章、規約 11/15 の実装を読み切ってから
  生成器のプロファイル辞書と 3 テンプレートを書く。
