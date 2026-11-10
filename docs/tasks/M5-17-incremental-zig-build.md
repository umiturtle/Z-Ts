# Task M5-17: Zig ソース編集時のインクリメンタルビルドを高速化する

- **Status**: `done`
- **Branch**: `arena/e32503eb-z-ts`（main `aa2a054` 起点）
- **Scope**: `src/cli/{devserver,main,template,mod,incremental,check_server}.zig`, `scripts/bench-dev-loop.py`（新規）, `docs/reference/cli{,.en}.md`, `docs/learn/{ja,en}/{start,tutorials/counter,guides/troubleshooting}.md`, `docs/architecture/incremental-dev-build.md`（新規）, `docs/decisions/0020-incremental-dev-build.md`（新規）, `scripts/doc-sync.json`
- **Upstream Reference**: [`../architecture/00-overview.md`](../architecture/00-overview.md) / `AGENTS.md` §2（キャッシュ揮発）
- **Next Step**: なし（完了）。次のボトルネックはポーリング（50 ms）＋まとめ（60 ms）。
  [`../architecture/incremental-dev-build.md`](../architecture/incremental-dev-build.md) §5 を参照。

---

## 1. 依頼と完了条件

> 「Zigのソースをいじった時のインクリメンタルビルドを高速化して（dirty flag なり依存グラフなり
> 良さげな技術を検討してから実装（ちゃんとその実装で早くなったか？バグがないかなどはしっかり検証して））」

- [x] 候補技術を**実測してから**選定（§2。`-fllvm` 強制が 4x 遅い＝ Debug は自前バックエンド、と訂正）
- [x] 実装して、`zts dev` の Zig 編集→リロードまでの時間が短縮されたことを**再現可能なベンチ**で示す
- [x] 型エラーを依然として検出できること、失敗後に回復できること、不要な再ビルドが起きないことを検証
- [x] 既存の挙動（CSS 差し替え / `web/` リロード / 3 OS 同じポーリング）を壊さない
- [x] `./zigw quick-test` / `build test` / `docs-check` / `fmt --check` / 3 OS CI が緑
- [x] 設計判断を ADR（`../decisions/0020-*.md`）・設計メモ・タスク票に残す

## 2. 技術選定（実測・レビュー指摘で訂正）

生成プロジェクトの `src/main.zig` に 1 行足して 7〜9 回計測。
**当初「LLVM codegen + link がボトルネック」と書いたのは誤り**。Zig 0.17.0 の Debug は
自前バックエンドで、同一モジュールグラフを `zig build-exe` に直接渡すと
既定 717 ms / `-fno-llvm` 690 ms / `-fllvm` **3021 ms** / `-fno-emit-bin` 366 ms だった。
内訳は「コンパイラ起動 + `std` 意味解析（約 370 ms）」＋「自前 codegen + link（約 320 ms）」。

| 手法 | 中央値 | 判定 |
|---|---|---|
| 現状 `zig build`（install） | 708〜832 ms | baseline |
| `zig build check`（`-fno-emit-bin`） | 377〜426 ms | ✅ 採用（約 1.9x、フォールバック兼用） |
| `zig build -fincremental`（毎回新規プロセス） | 1512〜1956 ms | ❌ 2.4x 遅い。差分状態はプロセス内にしか残らない |
| `zig build --watch` | panic `reached unreachable code` | ❌ このツールチェーンのファイル監視が不安定 |
| **`zig build-exe --listen=-` 常驻＋`-fno-llvm -fincremental`** | **初回 440 ms → 4 ms** | ✅ **採用**（型エラーも 11 ms） |
| `zig build-exe` 直接＋スタブ依存 | 約 370 ms | 参考：意味解析が下限 |
| 変更なし `zig build` | 29 ms | dirty flag が効けば 0 ms |
| `zig build` のステップ一覧取得 | 8 ms | `check` step の有無検出に利用 |

`-fincremental` は**プロセスをまたぐと速くならない**。効くのはコンパイラを 1 つ常驻させて
`update` を送る形だけ。最初の版は `--listen=-` を「プロトコルが重い」と早計に却下していたが、
`--watch` が壊れていてもコンパイラサーバ自体は直接駆動できる（レビュー指摘で再検証）。

### 採用した手法

1. **常驻コンパイラサーバ**（`src/cli/check_server.zig`）— 最大の効果。
   `zig build check --verbose` で実際の引数を取得し、`-fno-llvm -fincremental --listen=-` で
   spawn。`std.zig.Client` で handshake → 起動時に 1 回 `update` で温める → 編集ごとに `update`、
   `error_bundle` を `ErrorBundle.renderToStderr` で表示。**失敗したら即 `zig build check` に
   フォールバック**し、そのセッション中は戻さない。
2. **check-only build step**（生成 `build.zig`）— 引数取得・フォールバック・直接ベンチの 3 役。
3. **dirty flag（内容ハッシュ）** — `src/**/*.zig` / `build.zig*` を `Wyhash` で比較。
   `touch` / 同一内容書き戻しは 0 回。stat は読み直しの事前フィルタ。
4. **依存グラフ** — `src/main.zig` から `@import` / `@embedFile` を辿り、到達不能ファイルは
   ビルドもリロードもしない。未解決 import・増減・`build.zig*` 変更は完全ビルドへ。
5. **デバウンのバグ修正＋適応ポーリング** — 最終 scan から差分を取り、アイドル 250 ms /
   編集後 2 秒だけ 50 ms、まとめ 60 ms。待機中の編集の取りこぼしを解消。

### 却下した手法

- `-fincremental` 単体（毎回新規プロセス）: 実測で 2.4x 遅い。
- `--watch`: panic。3 OS 同一挙動のポーリング設計も崩れる。
- スタブ `embedded_frontend` で直接 `build-exe`: build runner を bypass しても 370 ms の下限は
  変わらず、`build.zig` のモジュール構成を CLI が推測することになり脆い。

## 3. 検証（実施済み）

### 3.1 ベンチ（`scripts/bench-dev-loop.py bench --old-zts …`）

変更前リビジョン `aa2a054` を `git archive` で別ディレクトリに展開して `zts` をビルドし、
そのバイナリで生成したプロジェクトを baseline にした**真の A/B**。

```text
End-to-end: edit src/main.zig -> new build visible to the browser
  legacy binary (pre-change)           median 1096.1 ms
  full builds (ZTS_DEV_BUILD=full)     median  827.4 ms
  incremental compiler server         median  115.5 ms   (compiler 4 ms)
  speedup vs legacy binary             9.49x
  same-binary full vs fast check       7.17x

Direct compiler step (no dev server, no polling)
  zig build       median  727.6 ms
  zig build check median  385.6 ms
  speedup         1.89x

Persistent compiler server: first update 440 ms -> 3 ms, type error 11 ms
```

`--min-speedup 1.3` を下回るとベンチが失敗する回帰ゲート付き。

### 3.2 `verify` の 8 不変条件（すべて PASS）

| 検査 | 結果 |
|---|---|
| 常駐サーバが Zig 編集を ms 単位で再検査 | PASS |
| 同一内容の書き戻し（`touch`）で `v` が動かない | PASS |
| import グラフ外のファイル編集で `v` が動かない | PASS |
| `web/site.css` は `hot:"css"` で差し替え（ビルドなし） | PASS |
| `web/index.html` は `hot:"full"` でリロード（ビルドなし） | PASS |
| `main()` の型エラーで `ok:false` / `v` 据え置き → 修正で回復 | PASS（常驻サーバの `error_bundle` から検出） |
| `build.zig` 編集で完全ビルド＋サーバ再起動 | PASS |
| 60 ms の待機ウィンドウ内の 2 編集が 1 回のビルドに畳まれる | PASS |

`verify` は `.github/workflows/ci.yml` の CLI ジョブ（Linux）から常時実行。

### 3.3 単体・全体テスト

```text
./zigw test -Mroot=src/cli/mod.zig   → 57 tests
./zigw quick-test                    → 7 tests
./zigw build test                    → EXIT=0
./zigw fmt --check src/ build.zig build.zig.zon → OK
python3 scripts/check-docs.py        → OK（--sync で台帳再同期）
./zigw docs-check                    → OK
```

詳細は [`../architecture/incremental-dev-build.md`](../architecture/incremental-dev-build.md) §4。

## 4. 最終状態

- **完了**: 選定・実装・単体テスト・統合ベンチ・回帰検証・ドキュメント・ADR・同期台帳の再同期。
- **残タスク**: なし。PR は 1 本（`arena/e32503eb-z-ts` → `main`、#17）。
- **既知の制約**: `zts dev` の「ok」は型検査の成功を意味する（実行ファイルの検証は `zts build`）。
  常驻サーバは `--verbose` 出力と `--listen=-` プロトコルに依存するが、どちらが変わっても
  フォールバックする。依存グラフの根は `src/main.zig` 固定。詳細は設計メモ §5。
