# Task M6-02: 3 チュートリアル × 9 ライブラリの分岐を充実させる

- **Status**: `review` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/70a7eede-z-ts`（main `b488746` = PR #24 マージ後 / v0.1.1 リリース後）
- **Scope**: `scripts/gen-framework-tutorials.py`, `src/docsite/frameworks.json`,
  `docs/learn/{ja,en}/tutorials/{counter,todo,ui}.md`,
  `docs/learn/{ja,en}/tutorials/{counter,todo,ui}-*.md`（生成物）,
  `docs/learn/{ja,en}/tutorials/{index,frameworks}.md`, `docs/INDEX{,.en}.md`,
  `scripts/check-docs.py`（規約 22）, `scripts/doc-sync.json`, 本ファイル
- **Upstream Reference**: [`M5-20-framework-tutorial-variants.md`](M5-20-framework-tutorial-variants.md),
  [`../learn/ja/tutorials/todo.md`](../learn/ja/tutorials/todo.md),
  [`../learn/ja/tutorials/ui.md`](../learn/ja/tutorials/ui.md),
  [`../../examples/gallery/src/main.zig`](../../examples/gallery/src/main.zig)
- **Next Step**: 実装を push → PR を 1 本作成 → 3 OS CI 7/7 を確認 → `gh pr merge` →
  タスク票を `done` にする。

---

## 1. 依頼と完了条件（Definition of Done）

> 「チュートリアルをもっと各ライブラリごとにしっかりし、3つのチュートリアル全対応にして
> （signalとzig側の連携などの大事な要素をちゃんとさらって）」

- [x] `counter` / `todo` / `ui` の **3 本すべて**に 9 ライブラリ分の分岐ページを用意する
      （日英 54 ページ＋選択ハブ 2 ページ）
- [x] 各ページがライブラリ固有の**状態プリミティブ**（`createSignal` / `signal()` / Svelte 5 rune /
      `ref()` / `useState` / DOM 直接など）を説明する
- [x] **Zig 側との連携**を全ページでさらう: `zig_probe` / `zig_inc` / `zig_dec`、`ipc://` と
      `window.__ZTS_ZIG__`、SHA-256 seal、ローカル状態と Zig 所有カウンタの**二重構造**、
      「楽観更新せず Zig の戻り値だけを正にする」、`ZIG OFFLINE` / `ZIG ONLINE`、
      `invoke` 失敗時の UI 状態、SSR / ハイドレーションのガード
- [x] 各ライブラリ固有のコード断片（counter 同期 / Todo リスト / UI 3 状態）を載せる
- [x] 3 本の本体チュートリアルと選択ハブ・日英索引から全分岐へリンクする
- [x] 規約 22 で「カタログ ↔ プロファイル ↔ 生成ページ ↔ ハブ」の一致を機械検査する
      （規約 15 の verbatim excerpt は counter の実物 example に対して維持）
- [x] `learn_path.steps` の 5 ステップ・95 分は不変（分岐は追加の章ではなく代替の道）
- [x] 日英 Doc と同期台帳を更新、`AGENTS.md` / `docs/roadmap/milestones.md` の
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

- **現在**: 実装・ローカル検証まで完了。
  - `scripts/framework_tutorial_profiles.py`（9 ライブラリ × 状態プリミティブ・Zig 同期・
    SSR ガード・Todo/UI の状態・落とし穴・3 種のコード断片、日英ペア）と
    `scripts/framework_tutorial_templates.py`（Todo / UI テンプレート＋共通の
    「状態は 2 つある」章）を新設。
  - 生成器が **56 ページ**（counter / todo / ui × 9 × 2 ＋選択ハブ 2）を出力。
    counter 分岐にも `{{REACTIVITY}}` / `{{CODE_ZIG}}` / `{{SYNC}}` / `{{GUARD}}` /
    `{{PITFALL}}` と Todo/UI 分岐リンクを追加。
  - 3 本の本体・`tutorials/index.md`・選択ハブに 3×9 の分岐表を追加。
  - 規約 11 は分岐を専用ハブに委譲、規約 22 が 54 ページの存在・Zig 連携トークン・
    状態プリミティブ・カタログ↔プロファイル・3 ハブのリンクを機械検査。
  - 同期台帳 69 ペア（`--sync --date 2026-10-21`）。
  - `zig build docs` の DanglingAnchors を slugify 規則で全件解消（同一ページ内 0 / 他ページ 0）。
- **ローカル緑**: `quick-test`（37 / 10）、`build test` exit 0、`doctest blocks=20`、
  `docs-check`（86 tests + `OK docsite pages=339 links=2892 … api_undoc=0`）、`fmt --check`、
  `check-docs.py`（219 md / 53 読者ページ × 2 言語）、`gen-framework-tutorials.py --check`
  （56 pages）、`node --test` 7/7、`gitflow.sh --self-test`。
- **未実施**: PR 作成・3 OS CI・マージ。
- **次の 1 手**: 実装を push → PR 1 本 → CI 7/7 → `gh pr merge` → 票を `done`。
