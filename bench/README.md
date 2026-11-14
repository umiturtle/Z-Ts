# `bench/` — ziggurats / Tauri 定量比較（M5-03 スライス C）

上流 Rust Tauri と ziggurats を**同じ 6 指標**で測る、依存ゼロのハーネスです。
Node.js の標準モジュールだけを使い、`npm install` も Rust ツールチェーンも表示サーバも要りません。

```bash
./zigw build                              # zig-out/bin/zts を作る
node bench/run.mjs                        # 両側（Rust が無ければ skipped）
node bench/run.mjs --skip-rust            # ziggurats 側だけ
node bench/run.mjs --ipc-iterations 100 --out /tmp/bench-out
```

出力は `<out>/results.json` と `<out>/results.md`。CI は Linux の `ci-cli` ジョブでこれを実行し、
`results.md` を `$GITHUB_STEP_SUMMARY` と Check Run Summary に出し、`results.json` をアーティファクトに
保存します。**数値を README や設計メモに手で書き写さないでください**（環境が変わると即嘘になります）。

## 指標

| 指標 | ziggurats 側の測り方 | 単位 |
|---|---|---|
| Clean build | `zts init` の一時プロジェクトから `.zig-cache` / `zig-out` を消して `zts build` | ms |
| Incremental | 同じプロジェクトの `src/main.zig` に 1 行足して再ビルド（ウォームキャッシュ） | ms |
| Binary size | `zig-out/bin/<name>` のサイズ（ReleaseSmall） | bytes |
| Startup | 生成バイナリを起動 → stdout の `embedded assets` までの中央値（複数回） | ms |
| RSS (idle) | `examples/counter` の Live Preview 常駐プロセスの `VmRSS`（Linux `/proc`） | KiB |
| IPC round-trip | Live Preview の `POST /__zts_ipc__/getState` 往復の中央値 | ms |

### 測れないときは `skipped`

数値を捏造しません。各指標は `{"status":"measured"|"skipped","value":…,"unit":…,"reason":…}` で
出力され、Markdown にも理由が出ます。典型的な `skipped`:

* **Rust 側**: `cargo` が無い / `vendor/tauri` の helloworld crate が未 checkout。
  `scripts/setup-toolchains.sh --rust --submodules` で有効になります。
  Rust 側の起動・RSS・IPC は実ウィンドウ（表示サーバ）が必要なので、ヘッドレス CI では
  意図的に計測しません。
* **RSS**: Linux の `/proc` 限定。他 OS では `skipped`。
* **IPC / RSS**: `counter-live` がビルドできない環境（`tests/tauri/node_modules` 未導入など）。

## ファイル

```text
bench/
├── run.mjs              オーケストレータ。引数解析・JSON/Markdown 出力・終了コード
├── lib/probe.mjs        共通ヘルパ（spawn / 計時 / 中央値 / RSS / 空きポート / which）
├── apps/
│   ├── ziggurats.mjs    zts init → build → 起動 → Live Preview → IPC
│   └── rust-tauri.mjs   cargo build（利用可能なときだけ）
└── out/                 生成物（.gitignore）
```

被測定アプリは「ビルドコマンド / 実行ファイル / 起動判定 / 停止」の 4 つで記述します。
新しいアプリを足すときは `apps/` に 1 ファイル足し、`run.mjs` の `measure` 呼び出しを 1 行増やすだけです。

## 設計の正本

[`../docs/architecture/packaging-and-bench.md`](../docs/architecture/packaging-and-bench.md) §4。
タスク票は [`../docs/tasks/M5-03-packager-and-bench.md`](../docs/tasks/M5-03-packager-and-bench.md)。

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-11-14 -->
