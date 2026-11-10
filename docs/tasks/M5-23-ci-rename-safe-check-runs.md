# Task M5-23: リポジトリ名変更中でも CI の Check Run ログ公開で赤くしない

- **Status**: `in_progress` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/55f07ace-z-ts`（main `b5b8f6b` = PR #21 マージ後）
- **Scope**: `.github/workflows/ci.yml`, `.github/workflows/pages.yml`,
  `scripts/publish-check-run-summary.js`（新規）, `tests/ci/publish-check-run-summary.test.cjs`（新規）,
  `docs/environment/github-actions.md`, `docs/environment/github-actions.en.md`（存在する場合）,
  `scripts/doc-sync.json`, 本ファイル
- **Upstream Reference**: [`../environment/github-actions.md`](../environment/github-actions.md)
  （Check Run Summary にログをミラーする運用）、[`M5-22-native-window-state-parity.md`](M5-22-native-window-state-parity.md)
  （最終 3 OS CI 7/7 green の到達点）
- **Next Step**: `.github/workflows/ci.yml` の 6 本の Check Run 公開ステップを
  `scripts/publish-check-run-summary.js` に集約し、実行時に `GET /repos/{owner}/{repo}` で
  正規のリポジトリ名を解決してから `checks.update` する。API 失敗は警告に落としてジョブを失敗させない。
  ローカルで `node --test tests/ci/publish-check-run-summary.test.cjs` と
  `python3 scripts/check-docs.py` / `./zigw quick-test` / `./zigw fmt --check` を通し、
  push 後に 3 OS CI を確認する。

---

## 1. 依頼と完了条件（Definition of Done）

> 「CIでエラー吐いてるので対応して」「途中でレポジトリ名変更したからかも」

- [ ] 失敗原因をログで特定し、リネームが原因であることを記録する
- [ ] `GITHUB_REPOSITORY`（ラン開始時点で固定）に依存せず、実行時の API から正規の
      `owner/repo` を解決して `checks.update` する
- [ ] Check Run API の 500 / ネットワーク障害・リネーム競合・summary サイズ超過で
      CI 本体が失敗しない（診断用ステップは non-fatal、ログは Step Summary にも残す）
- [ ] `actions/github-script` の 6 本の重複スクリプトを 1 つのヘルパーに集約する
- [ ] `pages.yml` の `gh api repos/${GITHUB_REPOSITORY}/pages` も正規名に正規化する
- [ ] ヘルパーの単体テスト（正常系・旧名解決・リトライ・永続失敗・UTF-8 切り詰め・
      ジョブ名不一致）を追加し `node --test` で通す
- [ ] 日英 Doc と同期台帳を更新、`learn_path.steps` / `AGENTS.md` /
      `docs/roadmap/milestones.md` のチェックボックスは非編集
- [ ] 新しいランで 3 OS CI が 7/7 緑、PR は 1 本だけ

## 2. 原因（確定）

- `main` への PR #21 マージで開始した CI run [`42810958509`](https://github.com/umiturtle/ZigguraTs/actions/runs/42810958509)
  と Pages run [`42810958523`](https://github.com/umiturtle/ZigguraTs/actions/runs/42810958523)
  の実行中にリポジトリが `umiturtle/Z-Ts` → `umiturtle/ZigguraTs` へ改名された。
- ランナーの `GITHUB_REPOSITORY` はラン開始時の旧名のまま（`checkout` のログにも
  `repository: umiturtle/Z-Ts`）。`actions/github-script@v7` の `context.repo.repo` も旧名。
- 失敗した 6 ジョブはすべて「Check Run API にログを公開する」ステップだけが失敗。
  生ログの `PATCH https://api.github.com/repos/umiturtle/Z-Ts/check-runs/129811951323` が
  `HttpError: fetch failed` / `status: 500`。ビルド・テスト・スクショ・parity 本体は全成功。
- リネーム前に 11:52:45 に完了した `CLI smoke (macos-latest)` は同じステップが成功しており、
  リネーム後に完了したジョブだけが失敗。ユーザーの指摘どおりリネームが原因。
- `GET /repos/umiturtle/Z-Ts` は 301 で `full_name: umiturtle/ZigguraTs` を返すため、
  GET で正規名を解決してから PATCH すれば回避できる。

## 3. 設計判断

| # | 判断 | 理由 |
|---|---|---|
| 1 | `checks.update` 前に `github.rest.repos.get` で `full_name` を解決 | 旧名は GET ならリダイレクトされるが PATCH は 500 になる。ランの `context` を書き換えずに済む |
| 2 | 公開ステップは `core.warning` に落として例外を投げない | ログ公開は Arena サンドボックス向けの**診断機能**であり、GitHub API の一時障害で 3 OS CI を赤くしてはならない |
| 3 | 2 回リトライ＋`$GITHUB_STEP_SUMMARY` へのミラー | 瞬断でもログを失わない。Step Summary は API 不通でも残る |
| 4 | summary は「文字数」ではなく UTF-8 バイト数で 60000 に丸める | 日本語ログを含むため 65535 バイト制限を超え得る |
| 5 | 旧リポジトリ URL / パス名は規約 14 どおり据え置き | 継続制約。`github.com` 側はリダイレクトされる。Pages の `/Z-Ts/` が 404 になる点は別途報告 |

## Current State / Next Step

- **現在**: 原因調査完了。30 秒ルーチン（`quick-test` / `check-docs.py` / `fmt --check`）は緑。
  旧 CI run は `conclusion: failure` だが、コード・テストの失敗ではない。
- **次の 1 手**: `scripts/publish-check-run-summary.js` とその Node テストを追加し、
  `ci.yml` / `pages.yml` を書き換えてコミットする。
