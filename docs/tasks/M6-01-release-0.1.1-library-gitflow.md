# Task M6-01: 0.1.1 リリース・ライブラリ配布・gitflow 受け皿

- **Status**: `done` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/c1ae6863-z-ts`（main `8870ff6` = PR #23 マージ後）
- **Scope**: `build.zig.zon`, `scripts/doc-sync.json`, `scripts/check-docs.py`（規約 20/21）,
  `src/cli/{main,template}.zig`, `docs/reference/cli{,.en}.md`, `README{,.en}.md`,
  `.github/workflows/{ci,release}.yml`, `.github/PULL_REQUEST_TEMPLATE.md`（新規）,
  `scripts/verify-library-consumer.sh`（新規）, `scripts/gitflow.sh`（新規）,
  `tests/library-consumer/`（新規）, `docs/learn/{ja,en}/guides/library.md`（新規）,
  `docs/learn/{ja,en}/guides/index.md`, `docs/INDEX{,.en}.md`,
  `docs/contributing/gitflow{,.en}.md`（新規）, `docs/contributing/doc-sync{,.en}.md`, 本ファイル
- **Upstream Reference**: [`../environment/github-actions.md`](../environment/github-actions.md),
  [`../reference/cli.md`](../reference/cli.md), [`.github/workflows/release.yml`](../../.github/workflows/release.yml),
  [`M5-24-pages-url-rename.md`](M5-24-pages-url-rename.md)
- **Next Step**: 完了。PR #24 は `main b488746` にマージ済み、タグ `v0.1.1` と
  GitHub Release を公開済み。`develop` 等の実ブランチはオーナーが作る。次の作業は別タスク票で宣言する。

---

## 1. 依頼とユーザー確認（確定）

> 「バージョンをbeta-1.0にし、リリースパイプラインを作り、他のzigプロジェクトからライブラリとして呼べる段階に運び、gitflowを導入して」

| 論点 | ユーザー回答 | 採用 |
|---|---|---|
| バージョン | 「**0.1.1にする**」 | `build.zig.zon` を `0.1.1`、タグ `v0.1.1`。`beta-1.0` は `std.SemanticVersion.parse` が `InvalidVersion` を返すため破棄（実測） |
| gitflow | 「**僕が自分でやります**。僕が自分でやった場合君はそれに従ったブランチ名を作れる？」 | 実ブランチは作らない（セッションが `arena/c1ae6863-z-ts` 固定）。CI トリガー・命名検証・日英 Doc・PR テンプレで**受け皿**を用意。PR の base は将来 `develop` 指定可 |
| リリース | A（**タグを打って実リリースまで**） | `v0.1.1` → Release workflow 実走 → GitHub Release 公開 → 公開アーカイブを `zig fetch` で検証 |

## 2. 完了条件（Definition of Done）

- [x] `build.zig.zon` と全ユーザー向け表記が `0.1.1` で一致（規約 20 で機械検査）
- [x] 配布アーカイブから `b.dependency("z_ts", …)` → `zts_foundation` / `zts_core` /
      `zts_rpc` / `zts_web` を import してビルド・実行できることを **CI 常時検証**
      （`tests/library-consumer/` + `scripts/verify-library-consumer.sh`、コールドキャッシュ）
- [x] その使い方を日英の読者 Doc に追加し、索引・同期台帳を更新（51 ペア）
- [x] `release.yml` がソースアーカイブ + 3 OS バイナリ + SHA256SUMS + GitHub Release を公開し、
      公開前にアーカイブのライブラリ性を検証する
- [x] タグ `v0.1.1` を打ち、Release が実際に公開され、公開アーカイブと同一ハッシュの
      アーカイブから `zig fetch` + ライブラリビルドが通る（GitHub Actions 側は公開 URL から実取得）
- [x] gitflow: `develop` / `feature/**` / `release/**` / `hotfix/**` が CI 対象になり、
      命名検証スクリプト・日英の運用 Doc・PR テンプレが揃う（規約 21 で機械検査）
- [x] `AGENTS.md` / `docs/roadmap/milestones.md` のチェックボックス、`learn_path.steps` は非編集
- [x] `quick-test` / `build test` / `doctest` / `docs-check` / `fmt --check` / 3 OS CI 緑、PR は 1 本だけ

## 3. 調査で確定した事実

| # | 事実 | 根拠 |
|---|---|---|
| 1 | `beta-1.0` は Zig の SemVer として不正 | `std.SemanticVersion.parse` が `InvalidVersion`。`1.0.0-beta.1` 等は有効 |
| 2 | `release.yml` は既にタグ `v*` 発火・`zig fetch` ハッシュ焼き込み・3 OS バイナリ・`--verify-tag` まで実装済み | ファイル精読。ただし **Release / タグは 1 件も無い**（`gh release list` 空、`git tag` 空） |
| 3 | 配布アーカイブは**既にライブラリとして動作する** | `git archive` → `zig fetch` → 別プロジェクトから `b.dependency("z_ts")` + `zts.module("zts_core")` / `zts_rpc` → コールドキャッシュで `zig build` → `consumer: core + rpc imported OK` を実測 |
| 4 | `build.zig` は `zts_*` を `b.addModule` で公開済み | 97–314 行目 |
| 5 | `build.zig.zon` の `.paths` に `examples` / `include` は無いが、tarball 全体が展開されるため `b.path()` は通る | コールドキャッシュ実験で解決 |
| 6 | `ci.yml` の push トリガーは `main` と `arena/**` のみ | 1–8 行目 |
| 7 | `check-docs.py` 規約 13 が `zts_version` と `build.zig.zon` の一致を検査 | 772 行目 |

## 4. 設計判断

| # | 判断 | 理由 |
|---|---|---|
| 1 | バージョンの正本は `build.zig.zon` の 1 箇所、規約 20 で全表記を照合 | 「実装と Doc のズレを機械検証」する継続制約。release.yml は `sed` で読むので自動追随 |
| 2 | ライブラリ E2E は `git archive` + `zig fetch` + コールド `ZIG_GLOBAL_CACHE_DIR` | リリースと同じアーカイブを、チェックアウトに依存しない別プロジェクトから使うことを証明 |
| 3 | gitflow は「受け皿」のみ。実ブランチはユーザーが作る | セッション固定制約。PR の head は `arena/*`、base は将来 `develop` 可 |
| 4 | タグは main のマージコミットに打つ | `release.yml` の `--verify-tag` と `git archive HEAD` が公開対象を一致させる |
| 5 | 0.1.1 は通常リリース（`--prerelease` なし） | ユーザーが beta 表記を破棄したため |

## Current State / Next Step

- **完了**: 実装・マージ・実リリースまで全て完了。
  - **PR [#24](https://github.com/umiturtle/ZigguraTs/pull/24)**: 1 本のみ。
    CI [`42948892443`](https://github.com/umiturtle/ZigguraTs/actions/runs/42948892443) が 7/7 緑、
    Check Run Summary に `OK gitflow names=8 rejected=6` と
    `OK library consumer modules=4 …` が実際に出た。`gh pr merge 24 --merge` → `main b488746`。
  - **マージ後 `main`**: CI
    [`42949949005`](https://github.com/umiturtle/ZigguraTs/actions/runs/42949949005) 7/7 緑、
    Pages [`42949948970`](https://github.com/umiturtle/ZigguraTs/actions/runs/42949948970) build + deploy 成功。
  - **実リリース**: `git tag v0.1.1 b488746` → `git push origin v0.1.1` →
    Release [`42949965026`](https://github.com/umiturtle/ZigguraTs/actions/runs/42949965026) 成功。
    GitHub Release `v0.1.1` に `z_ts-0.1.1.tar.gz` / 3 OS `zts` / `SHA256SUMS` の 5 assets。
    リリースノートの hash は `z_ts-0.1.1-TK0XgcBlLgAQDKSc390FcGHUBrMvjmGKD2RUwUDMabJN`。
  - **公開アーカイブ検証**: タグコミットから再生成した `git archive` の `zig fetch` hash が
    リリースノートと**完全一致**、同じアーカイブをコールドキャッシュからライブラリとして
    ビルド・実行成功。Release workflow の 3 OS `binary` ジョブは公開 URL を焼き込んだ
    `zts` で `zts doctor` / `zig build` を通しており、GitHub 側で実取得も証明済み。
    （Arena サンドボックスは `release-assets.githubusercontent.com` に到達できないため、
    直接 `zig fetch <公開URL>` は不可。代替検証で同一バイト列を確認した。）
- **実装**: バージョン `0.1.1`（規約 20、`zts version` 実測）、
  `tests/library-consumer/` + `scripts/verify-library-consumer.sh` + 日英 `guides/library.md`、
  `release.yml` の公開前ライブラリ検証、gitflow 受け皿（`ci.yml` triggers / `scripts/gitflow.sh` /
  日英 `contributing/gitflow*.md` / PR テンプレ / 規約 21）、同期台帳 51 ペア。
- **ローカル緑**: `quick-test`（37 / 10）、`build test` exit 0、`doctest blocks=20`、
  `docs-check`（86 tests + `OK docsite pages=302 links=1863 … api_undoc=0`）、`fmt --check`、
  `check-docs.py`（182 md / 35 読者ページ × 2）、`gen-framework-tutorials.py --check`、
  `node --test` 7/7、`gitflow.sh --self-test`、`verify-library-consumer.sh`。
- **オーナー側の残作業**: `develop` ブランチの作成（gitflow の実ブランチは作らない方針）。
  作られた後は PR を `--base develop` に切り替えられる。CI トリガーは既に受け入れ済み。
- **次の 1 手**: なし。`AGENTS.md` / `docs/roadmap/milestones.md` のチェックボックスは非編集のまま。
