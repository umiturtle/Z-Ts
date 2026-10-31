# Task M5-08: ドキュメントの読者分離（利用者 / リポジトリ開発者）

- **Status**: `done`
- **Branch**: `arena/bf471265-z-ts`
- **Scope**: `docs/guides/`, `docs/contributing/`, `docs/reference/cli.md`, `docs/INDEX.md`,
  `README.md`, `src/docsite/main.zig`（サイドバーのグループ）, `.github/workflows/ci.yml`, 本ファイル
- **Upstream Reference**: なし（Angular CLI の `ng new` / `ng serve` / `ng build` という
  コマンド面の分け方を参考にした）
- **Next Step**: なし（完了）。残る未着手は `M5-03`（3-OS パッケージャ）と
  `M5-02` の将来課題（`--tsgen` などの利便フラグ）。

---

## 1. 目的と完了条件（Definition of Done）

**問題**: ドキュメントが「このリポジトリをどうビルド・テストするか」と「このライブラリで
アプリをどう作るか」を混ぜていた。`getting-started.md` の最初の 3 章が `./zigw` の話で、
`docs/reference/cli.md` は `./zigw` / `zig build` / `scripts/*` / `zts` 設計面の 4 系統が同居し、
`guides/troubleshooting.md` は Zig 0.17 の API 差分や Pages の有効化というリポジトリ運用の
話題だけだった。アプリ作者は `zts` の存在に辿り着けず、本体開発者にはアプリの手順が混ざる。

- [x] 利用者向け（`zts`）と開発者向け（`./zigw`）の**入口を 1 ページずつ**に分ける
- [x] コマンドリファレンスを `zts` の仕様だけにする（リポジトリのコマンドは別ページ）
- [x] トラブルシューティングを読者別に 2 分割する
- [x] ドキュメントサイトのサイドバーでも別グループ（`開発`）にする
- [x] `zts` がリポジトリの外で動くことを CI で常時検証する（`ci-cli`）

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 新設 `docs/contributing/README.md` — リポジトリ開発の入口（`./zigw` の全コマンド、
    `zig build` のオプション、`scripts/*`、地図、変更の作法、CI）
  - `docs/guides/troubleshooting.md` → `docs/contributing/troubleshooting.md` へ移動
    （中身は元々すべてリポジトリ運用の話だった）。新規 `docs/guides/troubleshooting.md` は
    `zts` のエラーメッセージ別の対処（init の拒否・fingerprint・`--zts-path`・
    `ZTS_ZIG`・`dev` のポート/リロード・Vite の埋め込み）
  - 新設 `docs/guides/installing-zts.md` — `zts` の入手（`./zigw build` → `PATH`）、
    `ZTS_ZIG`、`--zts-path`、OS ごとの前提
  - `docs/guides/getting-started.md` を全面書き換え — `zts init` → `dev` → `build` →
    `doctor` だけ。`./zigw` は一度も出てこない
  - `docs/reference/cli.md` を `zts` 仕様だけに（`init` / `dev` / `build` / `doctor` /
    `help` / `version`、全オプション、`dev` の配信・監視・リロード仕様、`doctor` の 6 項目）
  - `docs/guides/README.md` / `docs/INDEX.md` / `README.md` — 冒頭に「どちらの読者か」の
    2 択表を置き、`zts` と `./zigw` の系統を明示
  - `src/docsite/main.zig` — `docs/contributing/` をサイドバーの独立グループ `開発` に
    （テスト 1 本追加）
  - `.github/workflows/ci.yml` — `ci-cli` ジョブ（ubuntu-24.04 / macos-14 / windows-2022）で
    `zts init <sibling dir> --zts-path <checkout>` → `doctor` → `build` → 実行を検証
  - `src/cli/main.zig` — `--zts-path` に絶対パスを渡しても `build.zig.zon` に書ける相対パスへ
    変換するよう修正（`relativePath`）。`src/cli/project.zig` に `toPosix` + テスト
- **作業中・直前の状態**: なし。`./zigw build docs` は `pages=188 links=389 ... api_undoc=0`
- **再開するとき**: `python3 scripts/check-docs.py && ./zigw build docs`

## 3. 設計判断・技術メモ・ハマりどころ

- **「層」ではなく「読者」で切った**: 既存の 4 層モデル（学ぶ / 引く / 仕様 / 内部）は
  *ライブラリの使い方*の内部構造で、リポジトリ運用はそのどれでもない。5 層目を足すのではなく、
  層の**外**に `contributing/` を置き、公開サイトでも別グループにした。
- **重複は許すが矛盾は作らない**: `zts` の入手には `./zigw build` が必要なので、
  `installing-zts.md` だけはリポジトリのコマンドを 1 つ出す。その代わり「ここは入口だけ」と
  明記し、詳細（CI・スクリプト・作法）は `contributing/` に隔離した。
- **トラブルシューティングは移設が正解だった**: 元のページは 1 行目から
  `scripts/status.sh` で、アプリ作者には実行できないコマンドだった。内容を書き換えるのではなく
  置き場所を変え、アプリ側は `zts` の実エラーメッセージから書き起こした。
- **`zts init` の雛形は「ウィンドウを開かない」**: 埋め込みが動くことの最小証明で、
  アセット表を print して終わる。ドキュメントではこれを明記し、デスクトップ化は
  `examples/counter` を出発点にするよう案内する（黙って「アプリができる」と言わない）。
- **`--zts-path` の絶対パスはそのまま書けない**: Zig は `build.zig.zon` の絶対 path を拒否する。
  `--zts-path /abs/checkout` を受けたらプロジェクトからの相対に直し、`\` を `/` に統一する
  （`relativePath` + `project.toPosix`）。CI はこの経路をそのまま叩いている。
- **CI の作業ディレクトリはチェックアウトの兄弟に置く**: `mktemp -d` の既定（`/tmp`）は
  Windows ランナーでは別ドライブになり、相対パスが計算できない。

### CI が見つけた CLI のバグ 2 件（修正済み）

新しい `ci-cli` ジョブは、サンドボックスの Linux では再現しなかった問題を 2 つ出した。
**3 OS でスモークを回す価値の実証**でもある。

1. **`resolveZig` が Windows で `InvalidExe`**: チェックアウトの `./zigw` を `zig` より優先して
   いたため、Windows ではシェルスクリプトを起動しようとして `zts build` が必ず失敗。
   解決順を `ZTS_ZIG` → `PATH` の `zig`/`zig.exe` → `<checkout>/zig` → `<checkout>/zigw`
   （POSIX のみ）に変更した。`zts init` の fingerprint patch も同時に直る。
2. **`DevServer` の teardown が macOS で `EBADF` によりプロセス abort**: テストが
   `listener.deinit` で受付スレッドの `accept` を起こしていた。Zig は `accept` の `EBADF` を
   programmer bug として扱うため、`cli` のテストバイナリ全体が落ちていた。`stop()` / `deinit()`
   を追加し、`stopping` フラグ + `shutdown` + 捨て接続で accept を起こしてから `join` する
   （`shutdown` は POSIX の正規のキャンセル手段、Windows では listening socket の shutdown が
   no-op なので捨て接続が必須）。
