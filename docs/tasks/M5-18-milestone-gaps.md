# Task M5-18: マイルストーンの未実装を埋め、Tauri 機能ギャップを整理する

- **Status**: `in_progress`
- **Branch**: `arena/124099a7-z-ts`（main `d428cf2` 起点 = PR #17 マージ後）
- **Scope**: `bench/`（新規）, `.github/workflows/ci.yml`, `docs/tasks/M5-03-packager-and-bench.md`,
  `docs/architecture/{packaging-and-bench,tauri-feature-gap}.md`（後者は新規）,
  `examples/frameworks/README{,.en}.md`, `docs/INDEX{,.en}.md`, `scripts/doc-sync.json`
- **Upstream Reference**: [`../architecture/packaging-and-bench.md`](../architecture/packaging-and-bench.md) §4 /
  [`../reference/tauri-usage.md`](../reference/tauri-usage.md) / `AGENTS.md` §1
- **Next Step**: `bench/run.mjs` と `bench/apps/*.mjs` を実装し、ローカルで
  `node bench/run.mjs --out bench/out` が 6 指標の JSON + Markdown を出すことを確認する。

---

## 1. 依頼と完了条件

> 「マイルストーンの未実装の部分を実装して / あと tauri で出来てこのライブラリでできないもののうち
> 実装すべきもの（理念に反さないもの）をリストアップして」

- [ ] ロードマップ／タスク票を走査し、**本当に未実装のもの**を確定する（§2、完了）
- [ ] `M5-03` スライス C: `bench/` の依存ゼロランナー + 6 指標 JSON/Markdown 出力
- [ ] CI（Linux）で ziggurats 側を実測し Check Run Summary に出す。Rust 側は `skipped` と明示
- [ ] `M5-06` の残り: `examples/frameworks/README{,.en}.md` から各デモへのリンク
- [ ] Tauri v2 の機能ギャップを調査し、**理念に反さず実装すべきもの**を優先度付きで
      `docs/architecture/tauri-feature-gap.md` にリストアップ
- [ ] `./zigw quick-test` / `build test` / `docs-check` / `fmt --check` / 3 OS CI が緑
- [ ] PR は 1 本だけ（「一回一回必要以上にプルリクを出さない」）

## 2. 未実装の確定（調査結果）

`docs/roadmap/milestones.md` 自体にチェックボックスは無く、進捗は `docs/tasks/*.md` の
`Status` とチェックボックスで管理されている（`AGENTS.md` §1）。全 `- [ ]` を走査した結果:

| 箇所 | 見た目 | 実際 |
|---|---|---|
| **`M5-03` スライス C**（3 行） | 未完了 | **本当に未実装**。`bench/` が存在しない。設計は `packaging-and-bench.md` §4 にある |
| `M5-06`（3 行） | 未完了 | スクショ／デモ公開は `publishDemos` で実装済み。**`examples/frameworks/README.md` からの各デモリンクだけ未実装**。Pages 初回有効化は管理者操作（GITHUB_TOKEN では不可と実測済み）でコード対象外 |
| `M4-03`（3 行） | 未完了 | AppKit / Win32 ネイティブ描画は `M4-05` / `M4-06` で実装済み（`status.sh` が `done`）。タスク票が古いだけ |
| `M5-09` | `in_progress` | Wave 2 の概念／チュートリアル／ACL／API 例は PR #14・#16 で完成（`docs/learn/` 24 ページ × 2 言語、`zig check` 20 ブロック）。タスク票が古いだけ |
| `M5-10`（1 行） | 未完了 | 実タグ `v0.1.0` のリリース実行。コードではなく公開操作なので今回は対象外 |

**結論**: 実装すべきは `M5-03` スライス C ＋ `M5-06` のリンク 1 箇所。
加えて「リストアップ」依頼に答える調査ドキュメントを 1 本作る。

## 3. 設計（ベンチ）

`packaging-and-bench.md` §4 の 6 指標をそのまま採用し、**測れないものは数値を捏造せず
`skipped` と理由を出力する**（「数値を README に手で書かない」方針の徹底）。

```text
bench/
├── run.mjs              依存ゼロのオーケストレータ（Node 標準モジュールのみ）
├── apps/
│   ├── ziggurats.mjs    zts init → zts build（コールド／インクリメンタル）・生成バイナリ
│   └── rust-tauri.mjs   cargo / vendor/tauri が揃う時だけ実測、無ければ skipped
├── out/                 生成物（.gitignore）
└── README.md
```

| 指標 | ziggurats 側の測り方 | 備考 |
|---|---|---|
| クリーンビルド | 一時プロジェクト + 専用 `ZIG_GLOBAL_CACHE_DIR` で `zts build` | ローカル `.zig-cache` も毎回新規 |
| インクリメンタル | 同じプロジェクトの `src/main.zig` に 1 行足して再ビルド | ウォームキャッシュ |
| バイナリサイズ | `zig-out/bin/<name>` の byte 数 | — |
| 起動 | 生成バイナリを spawn → stdout の `embedded assets` まで | ヘッドレスで動作する最小アプリ |
| RSS | 起動中の `/proc/<pid>/status` をポーリング | Linux のみ、他 OS は `skipped` |
| IPC | `examples/counter` の Live Preview に `invoke` を N 回 POST | サーバが無い環境は `skipped` |

Rust 側は `scripts/setup-toolchains.sh --rust` を明示的に呼んだときだけ実測し、
CI ではツールチェーンを入れず `skipped` を Check Summary に明記する（タスク票の指定通り）。

## 4. 進捗チェックポイント

- **完了**: 現状調査・未実装の確定・このタスク票の作成と push（分散ロック）。
- **作業中**: `bench/run.mjs` の実装。
- **未着手**: CI ジョブ、frameworks README リンク、Tauri ギャップ調査、ドキュメント、同期台帳、PR。
