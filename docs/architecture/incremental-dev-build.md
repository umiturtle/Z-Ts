# インクリメンタル dev ビルド（`zts dev`）の設計

> **対象読者**: `src/cli/` を触る人、`zts dev` の体感速度を改善したい人。
> **対応タスク**: [`../tasks/M5-17-incremental-zig-build.md`](../tasks/M5-17-incremental-zig-build.md)
> **決定記録**: [`../decisions/0020-incremental-dev-build.md`](../decisions/0020-incremental-dev-build.md)

## 1. 問題

`zts dev` は `web/` をディスクから配信する**プレビューサーバ**で、Zig の実行ファイルを起動しない
（[`../learn/ja/tutorials/counter.md`](../learn/ja/tutorials/counter.md)）。それなのに `src/` が
変わるたびに完全な `zig build`（install ステップ）を実行していた。

Zig 0.17.0 の Debug ビルドは **LLVM ではなく自前（self-hosted）バックエンド**を使う。
同一のモジュールグラフを `zig build-exe` に直接渡して確かめた:

```text
既定（= Debug の自前バックエンド）   717 ms
-fno-llvm（明示的に自前）            690 ms
-fllvm（LLVM を強制）              3021 ms   ← 4 倍以上遅い
-fno-emit-bin（意味解析のみ）        366 ms
```

つまり cost の内訳は **コンパイラの起動 + `std` とモジュールグラフの意味解析（約 370 ms）**
＋ **自前バックエンドのコード生成・リンク（約 320 ms）** であって、LLVM ではない。
最初の版の設計メモは「LLVM codegen + link がボトルネック」と書いていたが、これは誤りだった
（レビュー指摘を受けて上記の実測で訂正）。`-fno-emit-bin` は後半を丸ごと消す。

さらに 4 つの無駄・不具合があった。

* `mtime ^ size` だけを見ていたので、`touch` やフォーマッタの同一内容書き戻しでも再ビルドする。
* 待機ウィンドウ（120 ms）の**間に届いた変更を永遠に無視する**バグがあった
  （1 回目の scan で差分を取り、2 回目の scan を baseline にしていた）。
* `build.zig` / `build.zig.zon` を監視していなかった。ビルドグラフが変わっても無視される。
* アイドル時も毎回 2 回 scan ＋ 120 ms 待機しており、実質的なポーリング周期が 370 ms になっていた。

## 2. 技術選定（実測）

生成プロジェクトの `src/main.zig` に 1 行足して 7〜9 回計測した中央値。

| 手法 | 中央値 | 判定 |
|---|---|---|
| 現状 `zig build`（install） | 708〜832 ms | baseline |
| `zig build check`（`-fno-emit-bin`） | 377〜426 ms | ✅ 採用（約 1.9x） |
| `zig build -fincremental`（毎回新規プロセス） | 1512〜1956 ms | ❌ 2.4x 遅い |
| `zig build --watch`（ビルドランナーの常駐＋ネイティブ監視） | panic `reached unreachable code` | ❌ このツールチェーンでは不安定 |
| **`zig build-exe --listen=-` 常駐＋`-fno-llvm -fincremental`** | **初回 440 ms → 2 回目以降 4 ms** | ✅ **採用**（型エラーも 11 ms で検出） |

`-fincremental` は**プロセスをまたぐと速くならない**。差分状態はコンパイラのメモリに残るため、
毎回 `zig build` を起動する形では逆に 100 ms 余分に掛かる。効くのは
「コンパイラを 1 つ常駐させ、`update` メッセージを送る」形だけだった。
`--listen=-` は当初「プロトコル実装が重い」として却下したが、これは早計だった。
Zig の `--watch` が壊れていても、**コンパイラサーバ自体は直接駆動できる**。

`--summary all` の内訳（参考）:

```text
install → compile exe bench_app debug native  836 ms  （意味解析 + 自前 codegen + link）
          └─ run exe bench_app_embed           6 ms   （compile はキャッシュ済み）
check   → compile exe bench_app_check         367 ms  （意味解析のみ）
```

## 3. 実装

### 3.1 常駐コンパイラサーバ（最大の効果）

[`src/cli/check_server.zig`](../../src/cli/check_server.zig) が
`zig build-exe … -fno-emit-bin -fno-llvm -fincremental --listen=-` を 1 プロセスだけ起動し、
Zig の `--listen=-` プロトコル（`std.zig.Client` / `std.zig.Server.Message`）で話す。

1. 起動時に `zig build check --verbose` を 1 回実行し、**実際のコンパイラ引数**を取り出す
   （`build.zig` をユーザーが改造していても追従できる）。`-fno-llvm -fincremental` を足して
   `--listen=-` で spawn する。`zig_version` ハンドシェイクを検証し、最初の `update` で
   意味解析を済ませておく（初回編集を遅くしないため）。
2. Zig の編集 1 回につき `update` を 1 通送り、終端の `error_bundle` を読む。
   バンドルにエラーがあれば `ErrorBundle.renderToStderr` で通常の `zig build` と同じ
    diagnostics を出し、`ok:false` にする。成功なら `v` を進める。
3. 引数解析・spawn・ハンドシェイク・プロトコルの**どれか 1 つでも失敗したら即座に
   `zig build check` へフォールバック**し、そのセッション中は戻さない。
   速いけど誤った成功を返すより、遅くても正しいビルドを選ぶ。

`zts dev` の**初回ビルドと `zts build` は完全ビルドのまま**。リンクエラーの検出を失わないためと、
プロジェクトに本物のバイナリを置いておくため。完全ビルドの前にはサーバを閉じる
（Zig キャッシュを同時に触らない）。

### 3.2 `check` ステップ（フォールバック／検証用）

[`src/cli/template.zig`](../../src/cli/template.zig) が生成する `build.zig` に、出力バイナリを
誰も要求しない compile step を 1 つ追加した。Zig 0.17 の
`lib/compiler/Maker/Step/Compile.zig` は `generated_bin.value == null` のとき
`-fno-emit-bin` を付ける。`--verbose` で実際のコマンドを確認済み:

```text
zig build-exe ... -Mroot=src/main.zig ... -fno-emit-bin ... --listen=-
```

この step は ① 常駐サーバの引数取得、② サーバが使えない環境でのフォールバック、
③ `zig build check` の直接ベンチ、の 3 役を持つ。

### 3.3 安全側フォールバック

| 条件 | 挙動 |
|---|---|
| 生成 `build.zig` に `check` step が無い（古いテンプレート） | 起動時に `zig build` のステップ一覧を確認 → `zig build check` を使わず完全ビルド |
| `build.zig` が `linkSystemLibrary` / `link_libc = true` / `addObject` を使う | 完全ビルド（型検査ではリンクエラーが見えない） |
| `ZTS_DEV_BUILD=full` | 完全ビルド（リンク検証、ベンチの baseline） |
| コンパイラサーバの起動・ハンドシェイク・プロトコル失敗 | `zig build check` |
| 依存グラフが incomplete（未解決 import、読み込み失敗、プロジェクト外への脱出） | 完全ビルド |
| `build.zig*` の変更、`src/` でのファイル追加・削除 | 完全ビルド＋サーバ再起動 |
| チェックが失敗 | `ok:false` / `v` 据え置き / 直前の成功物を配信し続ける |

### 3.4 dirty flag（内容ハッシュ）

[`src/cli/devserver.zig`](../../src/cli/devserver.zig) の `Snapshot` が `Stamp { stat, content }` を
持つ。`src/**/*.zig` と `build.zig*` は `Wyhash` で内容をハッシュし、`stampEqual()` は両方に
`content` があれば**ハッシュだけ**を比較する。`stat`（mtime ^ size）は「読み直すか」の安価な
事前フィルタに格下げした。

* 同一内容の書き戻し → ハッシュ一致 → 変更なし → 再ビルド 0 回。
* `stat` が動いたファイルだけ読み直す（`scanAgainst(previous)`）ので、大きな `src/` でも
  アイドル時の読み込みは増えない。
* `web/` は stat のまま。画像・フォント・バンドルを毎ポーリングで読まないため（無害な CSS
  差し替えが余分に起きるだけ）。
* `mtime` と `size` の両方を偽装する書き込みは旧実装と同様に区別できない。実用的なエディタでは起きない。

### 3.5 依存グラフ

[`src/cli/incremental.zig`](../../src/cli/incremental.zig) の `Graph` が `src/main.zig` を根として
相対 `@import("…")` / `@embedFile("…")` を BFS で辿る。コメントは読み飛ばし、
ビルドシステムのパッケージ import（`@import("std")`、`embedded_frontend` など）はパスとして
解決せず無視する。到達集合に無い `src/scratch.zig` の編集はビルドもリロードもしない。

`plan()` の決定表:

| 入力 | 決定 |
|---|---|
| `build.zig*` 変更 / `src/` の構造変化 / グラフ incomplete | `full` |
| 到達可能な `src/` 変更 | `check`（常駐サーバ → フォールバック `zig build check` → 完全ビルド） |
| 到達不能な `src/` 変更のみ | `skip`（`v` も進めない） |
| CSS のみ | `css`（差し替え、ビルドなし） |
| その他の `web/` | `assets`（リロード、ビルドなし） |
| 差分なし | `none` |

`plan()` はプロセスを起動しない純関数で、全分岐を単体テストしている。

### 3.6 ループの修正と適応ポーリング

[`src/cli/main.zig`](../../src/cli/main.zig) `runDev`:

1. `sleep → scan → 差分が無ければ即 continue`（アイドル時の 2 回目の scan と待機を廃止）。
2. 差分があれば 60 ms 待って再走査し、**最終 scan に対して** `previous.changed()` と
   `previous.structural()` を取る。待機中の編集を取りこぼさず、バーストを 1 回に畳む。
3. 変更から約 2 秒間だけポーリングを 50 ms に上げ、それ以外は 250 ms。ネイティブの
   ファイル監視は使わないので 3 OS の挙動は同一。
4. 差分文字列はイテレーションごとの arena に置き、セッション中のメモリ増加を止めた。
5. 初回ビルドを**初期化・baseline snapshot・サーバ warmup の後**に移動。`v=1` を見た
   クライアントは「もう全部準備できている」と分かる（起動直後の編集を飲み込まない）。

コンパイルが 3 ms になった結果、体感時間はポーリング（最大 50 ms）＋まとめ（60 ms）で
ほぼ決まる。ここを詰めるのが現在の残ボトルネック。

## 4. 検証

### 4.1 ベンチ（[`scripts/bench-dev-loop.py`](../../scripts/bench-dev-loop.py)）

* `bench`: `zts dev` を実プロセスで起動し、`src/main.zig` を編集して `/__zts_dev__/state` の
  `v` が進むまでの**実時間**を計測。`ZTS_DEV_BUILD=full`（同一バイナリで旧コストを再現）と
  既定（新経路）を比較。さらに `--old-zts` で**変更前リビジョンのバイナリ**を指定すると、
  変更前テンプレートで生成したプロジェクトも含めた真の A/B になる。
* `verify`: 8 つの不変条件（下記）を実プロセスで検査。Linux の CI ジョブから常時実行。

実測（Zig 0.17.0、生成プロジェクト、ウォームキャッシュ、7〜9 回の中央値）:

```text
End-to-end: edit src/main.zig -> new build visible to the browser
  legacy binary (pre-change)           median 1135.9 ms
  full builds (ZTS_DEV_BUILD=full)     median  845.2 ms
  incremental compiler server         median  116.2 ms   (compiler 4 ms)
  speedup vs legacy binary             9.77x
  same-binary full vs fast check       7.27x

Direct compiler step (no dev server, no polling)
  zig build       median  747.0 ms
  zig build check median  396.0 ms
  speedup         1.89x

Persistent compiler server (direct protocol probe)
  first update 440 ms -> subsequent updates 3 ms, type error 11 ms
```

`--min-speedup 1.3` を下回ると失敗する回帰ゲート付き。

### 4.2 `verify` の不変条件

| 検査 | 期待 |
|---|---|
| 常駐サーバが Zig 編集を ms 単位で再検査 | `zts: type-check ok (N ms)` の `N < 80` |
| 同一内容の書き戻し（`touch`） | `v` 不変 |
| import グラフ外のファイル編集 | `v` 不変 |
| `web/site.css` 編集 | `hot:"css"`、`v` +1、ビルドなし |
| `web/index.html` 編集 | `hot:"full"`、`v` +1、ビルドなし |
| `main()` に型エラー | `ok:false`、`v` 据え置き → 修正後 `ok:true`、`v` +1 |
| `build.zig` 編集 | 完全ビルド＋サーバ再起動、`v` +1 |
| 60 ms の待機ウィンドウ内に 2 回編集 | ビルドは 1 回だけ |

型エラーは「実際に解析される場所」に注入する（`main()` 内の識別子を壊す）。未参照の
トップレベル宣言は完全ビルドでも型検査でも遅延解析されるため、どちらでも検出されない。
常駐サーバ経路でも `error_bundle` から同じエラーが取れることを確認済み。

### 4.3 その他の検証

```text
./zigw test -Mroot=src/cli/mod.zig   → 57 tests（依存グラフ、plan 全分岐、内容ハッシュ、
                                        構造変化、build.zig 監視、ステップ一覧パーサ、
                                        生成テンプレートの check step、argv パーサ）
./zigw quick-test / build test        → 7 / EXIT=0
./zigw fmt --check src/ build.zig build.zig.zon → OK
python3 scripts/check-docs.py → OK（--sync で台帳を更新）
```

## 5. 制約と今後

* **`zts dev` の「ok」は型が通ったという意味**。実行ファイルの検証は `zts build`。
  これはプレビューが `web/` を配信するだけという既存の設計と整合している。
* 常駐サーバは `--verbose` 出力から引数を取る。Zig の出力形式が変わったら
  `parseArgv` が失敗して `zig build check` に落ちる（遅くなるだけで壊れない）。
  `--listen=-` プロトコルもバージョン依存なので、`zig_version` ハンドシェイクで弾く。
  当初は `-M…=` のパス実在も検証していたが、GitHub Actions では生成物がグローバル
  キャッシュ側に置かれて誤爆（`ModulePathMissing`）したため削除した。引数の正当性は
  ハンドシェイクと起動時の `update` が実際にコンパイルすることで保証する方が確実。
* サーバは `web/` の変更を追わない（生成済み `assets_manifest.zig` のパスを保持する）。
  型検査には影響しないが、`web/` を大幅に変えた後に完全ビルドが走れば再起動する。
* `src/main.zig` を根に固定している。別のエントリポイントを使うプロジェクトでは
  グラフが incomplete になり完全ビルドへ落ちる（正しいが遅い）。必要なら `build.zig` の
  `b.path("…")` を読んで根を推定する（サーバの引数は既に `--verbose` で取れている）。
* 次のボトルネックは 50 ms ポーリング＋60 ms まとめ。ネイティブのファイル監視は
  3 OS 同一挙動の制約で避けているので、必要なら「変更検知のみイベント、差分はポーリング」
  のハイブリッドを検討する。

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-11-14 -->
