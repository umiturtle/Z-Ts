# Task M5-10: `zts` の配布形態（バイナリ 1 個 + `.url` 依存）

- **Status**: `in_progress` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/7ef6be00-z-ts`
- **Scope**: `src/cli/{args,main,project,template}.zig`, `build.zig`, `.github/workflows/{ci,release}.yml`, `docs/reference/cli.md`, `docs/learn/{ja,en}/guides/install.md`, `docs/learn/{ja,en}/start.md`, `docs/contributing/README.md`, `docs/architecture/packaging-and-bench.md`, `README.md`, 本ファイル
- **Upstream Reference**: Angular CLI（`npm i -g` で CLI 1 個）／`cargo install`（ツールチェーンは利用者側）／Tauri v2 の配布ページ
- **Next Step**: `gh pr checks` で CI（特に `ci-cli` の release モード）を確認し、`release.yml` を `workflow_dispatch` で 1 回ドライランする

---

## 1. 目的と完了条件（Definition of Done）

問い: **「`zigw` を配布するのか。ノーマル環境（通常の `zig`）で使わせた方が良くないか」**

- [x] `zigw` は**リポジトリ開発者専用**と明記し、配布物から外す（`docs/contributing/README.md` §6）
- [x] 配布物は `zts` の単体バイナリ 1 個（`ReleaseSmall` で約 300 KB、`link_libc = false`）
- [x] 通常の `zig`（0.17 系）がある環境で `zts` がそのまま動く（`resolveZig`: `ZTS_ZIG` → `PATH`）
- [x] `zts init` が書く `.z_ts` を、チェックアウトの `.path` ではなく公開アーカイブの `.url` + `.hash` にする
- [x] `--zts-url` / `--zts-hash` を CLI に追加（片方だけなら `IncompleteZtsRelease`）
- [x] release ビルドでは `zts_root` を空にし、`zts doctor` が `(none — release build)` と表示する
- [x] `zts doctor` が `.url` 依存を「MISSING」と誤報しない（`dependency … (fetched by zig)`）
- [x] `zts doctor` が Zig を見つけられないとき `zig MISSING` を出す（exit 1）
- [x] `.github/workflows/release.yml`: アーカイブ → hash → 3 OS バイナリ → GitHub Releases
- [x] `ci-cli`（Linux）で release モードの E2E（空の Zig キャッシュから `.url` 解決）
- [x] 日英の install / start ページと README を「バイナリを落とす」動線に更新
- [ ] 実タグ（`v0.1.0`）でのリリース実行

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `template.Options` に `zts_url` / `zts_hash` / `usesRelease()` と `{{Z_TS_DEP}}` トークンを追加。
    url+hash が揃えば `.url` 形式、片方でも欠ければ `.path` にフォールバック（Zig が読めない zon を出さない）。
  - `args.zig`: `--zts-url` / `--zts-hash` と `IncompleteZtsRelease`（usage にも追記）。
  - `main.zig`: 依存の決定（CLI 指定 > 焼き込み > チェックアウト）、doctor の release 対応、`zig MISSING`。
  - `project.zig`: `dependencyUrl()`（`.url` を読む純粋関数）と単体テスト。
  - `build.zig`: `-Dzts-pkg-url` / `-Dzts-pkg-hash`。両方揃ったときだけ `zts_root = ""`。
  - 実測: 焼き込みバイナリ 302,160 B。`file://` アーカイブ（2.1 MB）を焼き込んだ `zts` で
    `init` → `doctor` → 空キャッシュから `build` → 実行（`1 embedded assets`）まで確認。
- **作業中・直前の状態**:
  - CI の `ci-cli` に release モードのステップを追加済み（Linux のみ）。`release.yml` は未実行。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **なぜ `.url` か**: `zts init` は build 時の `zts_root`（`build.zig` が焼き込む絶対パス）を
  `build.zig.zon` に書く。配布バイナリではそのパスが存在しないため、生成物が初回ビルドで壊れる。
  `.url` + `.hash` なら Zig が取得するので、利用者に clone を要求しない。
- **hash は先に決まる必要がある**: release アーカイブ → `zig fetch` → その値を焼き込んでバイナリ、の順。
  だから `release.yml` は `archive` ジョブを `binary` ジョブの `needs` に置いている。
- **片方だけの指定を許さない**: Zig は `.url` に `.hash` が無い依存を読めない。`build.zig` は両方
  揃わなければ `panic`、CLI は `IncompleteZtsRelease`。中途半端な zon を書き出さないための一貫した規則。
- **doctor の 2 行が消える**: release ビルドはチェックアウトを持たないので、`checkout` は
  `(none — release build)`、`z_ts` 行は出さない。存在しないパスを `MISSING` と言わない。
- **`std.testing.allocator` の落とし穴**: `defer for (files) |f| alloc.free(f.contents);` の後に
  `defer alloc.free(files);` を置くと **配列が先に解放され**、要素の読み出しで ABRT する。
  1 つの `defer { … }` ブロックにまとめる（今回の ABRT の原因）。
- **CI の `file://` 制約**: Windows ランナーはドライブが違い `file://` URL が壊れるので、
  release モードの E2E は Linux に限定。3 OS での確認は `release.yml` の各ランナーが行う。
