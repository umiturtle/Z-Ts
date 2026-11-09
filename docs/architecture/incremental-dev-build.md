# インクリメンタル dev ビルド（`zts dev`）の設計

> **対象読者**: `src/cli/` を触る人、`zts dev` の体感速度を改善したい人。
> **対応タスク**: [`../tasks/M5-17-incremental-zig-build.md`](../tasks/M5-17-incremental-zig-build.md)
> **決定記録**: [`../decisions/0020-incremental-dev-build.md`](../decisions/0020-incremental-dev-build.md)

## 1. 問題

`zts dev` は `web/` をディスクから配信する**プレビューサーバ**で、Zig の実行ファイルを起動しない
（[`../learn/ja/tutorials/counter.md`](../learn/ja/tutorials/counter.md)）。それなのに `src/` が
変わるたびに完全な `zig build`（install ステップ）を実行していた。

`--summary all` で内訳を取ると、Zig 0.17.0・ウォームキャッシュの生成プロジェクトで:

```text
install → compile exe bench_app debug native  836 ms   ← LLVM codegen + link
          └─ run exe bench_app_embed           6 ms    （compile はキャッシュ済み）
```

つまり **プロセス起動ではなくコード生成とリンク**がボトルネックだった。さらに:

* `mtime ^ size` だけを見ていたので、`touch` やフォーマッタの同一内容書き戻しでも再ビルドする。
* 待機ウィンドウ（120 ms）の**間に届いた変更を永遠に無視する**バグがあった
  （1 回目の scan で差分を取り、2 回目の scan を baseline にしていた）。
* `build.zig` / `build.zig.zon` を監視していなかった。ビルドグラフが変わっても無視される。
* アイドル時も毎回 2 回 scan ＋ 120 ms 待機しており、実質的なポーリング周期が 370 ms になっていた。

## 2. 技術選定（実測）

生成プロジェクトの `src/main.zig` に 1 行足して 7〜9 回計測した中央値。

| 手法 | 中央値 | 判定 |
|---|---|---|
| 現状 `zig build`（install） | 721〜832 ms | baseline |
| **`zig build check`**（`-fno-emit-bin`） | **377〜426 ms** | ✅ **採用**（約 1.9x） |
| `zig build -fincremental` | 1956 ms | ❌ 2.4x 遅い。0.17 の experimental incremental は小規模プロジェクトで逆効果 |
| `zig build check -fincremental` | 1512 ms | ❌ 同上 |
| `zig build --watch`（常驻ビルドサーバ + ネイティブ監視） | panic `reached unreachable code` | ❌ 不安定。しかも inotify/FSEvents 依存になり 3 OS 同一挙動の設計方針に反する |
| `zig build-exe -fno-emit-bin` をスタブ依存で直接実行 | 約 370 ms | 参考値。**コンパイラ起動 + `std` 意味解析が下限**で、build runner を bypass しても大差ない |
| 変更なし `zig build` | 29 ms | dirty flag が効けば 0 ms |
| `zig build` のステップ一覧取得 | 8 ms | `check` step の有無検出に利用 |

## 3. 実装

### 3.1 `check` ステップ（最大の効果）

[`src/cli/template.zig`](../../src/cli/template.zig) が生成する `build.zig` に、出力バイナリを
誰も要求しない compile step を 1 つ追加した:

```zig
const check_exe = b.addExecutable(.{ .name = "app_check", .root_module = app });
const check_step = b.step("check", "Type-check the app without emitting a binary");
check_step.dependOn(&check_exe.step);
```

Zig 0.17 の `lib/compiler/Maker/Step/Compile.zig` は `generated_bin.value == null` のとき
`-fno-emit-bin` を付ける。`b.installArtifact(exe)` を呼んだ step は `generated_bin` が設定されるが、
上の `check_exe` は誰も `getEmittedBin()` を呼ばないので意味解析だけで終わる。
`--verbose` で実際のコマンドを確認済み:

```text
zig build-exe ... -Mroot=src/main.zig ... -Membedded_frontend=... -fno-emit-bin ...
```

`zts dev` の**初回ビルドと `zts build` は完全ビルドのまま**。リンクエラーの検出を失わないためと、
プロジェクトに本物のバイナリを置いておくため。

### 3.2 安全側フォールバック

速さより「見落とさない」ことを優先した。

| 条件 | 挙動 |
|---|---|
| 生成 `build.zig` に `check` step が無い（古いテンプレート） | 起動時に `zig build` のステップ一覧を確認 → 完全ビルド |
| `build.zig` が `linkSystemLibrary` / `link_libc = true` / `addObject` を使う | 完全ビルド（型検査ではリンクエラーが見えない） |
| `ZTS_DEV_BUILD=full` | 完全ビルド（リンク検証、ベンチの baseline） |
| 依存グラフが incomplete（未解決 import、読み込み失敗、プロジェクト外への脱出） | 完全ビルド |
| `build.zig*` の変更、`src/` でのファイル追加・削除 | 完全ビルド |
| `check` が失敗 | `ok:false` / `v` 据え置き / 直前の成功物を配信し続ける |

### 3.3 dirty flag（内容ハッシュ）

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

### 3.4 依存グラフ

[`src/cli/incremental.zig`](../../src/cli/incremental.zig) の `Graph` が `src/main.zig` を根として
相対 `@import("…")` / `@embedFile("…")` を BFS で辿る。コメントは読み飛ばし、
ビルドシステムのパッケージ import（`@import("std")`、`embedded_frontend` など）はパスとして
解決せず無視する。到達集合に無い `src/scratch.zig` の編集はビルドもリロードもしない。

`plan()` の決定表:

| 入力 | 決定 |
|---|---|
| `build.zig*` 変更 / `src/` の構造変化 / グラフ incomplete | `full` |
| 到達可能な `src/` 変更 | `check`（step が無ければ `full`） |
| 到達不能な `src/` 変更のみ | `skip`（`v` も進めない） |
| CSS のみ | `css`（差し替え、ビルドなし） |
| その他の `web/` | `assets`（リロード、ビルドなし） |
| 差分なし | `none` |

`plan()` はプロセスを起動しない純関数で、全分岐を単体テストしている。

### 3.5 ループの修正と適応ポーリング

[`src/cli/main.zig`](../../src/cli/main.zig) `runDev`:

1. `sleep → scan → 差分が無ければ即 continue`（アイドル時の 2 回目の scan と 120 ms を廃止）。
2. 差分があれば 120 ms 待って再走査し、**最終 scan に対して** `previous.changed()` と
   `previous.structural()` を取る。待機中の編集を取りこぼさず、バーストを 1 回に畳む。
3. 変更から約 2 秒間だけポーリングを 100 ms に上げ、それ以外は 250 ms。ネイティブの
   ファイル監視は使わないので 3 OS の挙動は同一。
4. 差分文字列はイテレーションごとの arena に置き、セッション中のメモリ増加を止めた。
5. 初回ビルドを**初期化と baseline snapshot の後**に移動。`v=1` を見たクライアントは
   「もうポーリングが始まっている」と分かる（起動直後の編集を baseline が飲み込まない）。

## 4. 検証

### 4.1 ベンチ（[`scripts/bench-dev-loop.py`](../../scripts/bench-dev-loop.py)）

* `bench`: `zts dev` を実プロセスで起動し、`src/main.zig` を編集して `/__zts_dev__/state` の
  `v` が進むまでの**実時間**を計測。`ZTS_DEV_BUILD=full`（同一バイナリで旧コストを再現）と
  既定（新経路）を比較。さらに `--old-zts` で**変更前リビジョンのバイナリ**を指定すると、
  変更前テンプレートで生成したプロジェクトも含めた真の A/B になる。
* `verify`: 7 つの不変条件（下記）を実プロセスで検査。Linux の CI ジョブから常時実行。

実測（Zig 0.17.0、生成プロジェクト、ウォームキャッシュ、7〜9 回の中央値）:

```text
End-to-end: edit src/main.zig -> new build visible to the browser
  legacy binary (pre-change)           median 1110.5 ms
  full builds (ZTS_DEV_BUILD=full)     median 955.2 ms
  incremental check                    median  637.9 ms
  speedup vs legacy binary             1.74x
  same-binary full vs check            1.50x

Direct compiler step (no dev server, no polling)
  zig build       median  720.8 ms
  zig build check median  376.6 ms
  speedup         1.91x
```

ベンチは `--min-speedup 1.3` を下回ると失敗する（回帰ゲート）。

### 4.2 `verify` の不変条件

| 検査 | 期待 |
|---|---|
| 同一内容の書き戻し（`touch`） | `v` 不変 |
| import グラフ外のファイル編集 | `v` 不変 |
| `web/site.css` 編集 | `hot:"css"`、`v` +1、ビルドなし |
| `web/index.html` 編集 | `hot:"full"`、`v` +1、ビルドなし |
| `main()` に型エラー | `ok:false`、`v` 据え置き → 修正後 `ok:true`、`v` +1 |
| `build.zig` 編集 | 完全ビルド、`v` +1 |
| 120 ms の待機ウィンドウ内に 2 回編集 | ビルドは 1 回だけ |

型エラーは「実際に解析される場所」に注入する（`main()` 内の識別子を壊す）。未参照の
トップレベル宣言は完全ビルドでも型検査でも遅延解析されるため、どちらでも検出されない。

### 4.3 その他の検証

```text
./zigw test -Mroot=src/cli/mod.zig   → 55 tests（依存グラフ、plan 全分岐、内容ハッシュ、
                                        構造変化、build.zig 監視、ステップ一覧パーサ、
                                        生成テンプレートの check step）
./zigw quick-test / build test        → 7 / EXIT=0
./zigw fmt --check src/ build.zig build.zig.zon → OK
python3 scripts/check-docs.py → OK（--sync で台帳を更新）
```

## 5. 制約と今後

* **`zts dev` の「ok」は型が通ったという意味**。実行ファイルの検証は `zts build`。
  これはプレビューが `web/` を配信するだけという既存の設計と整合している。
* `-fincremental` は Zig の実装が成熟したら再評価する（今回は 2.4x 遅かった）。
* `--listen=-` 常驻ビルドサーバは、意味解析の下限（約 370 ms）を超える利がなく、
  プロトコル実装の複雑さに見合わないため見送った。
* `src/main.zig` を根に固定している。別のエントリポイントを使うプロジェクトでは
  グラフが incomplete になり完全ビルドへ落ちる（正しいが遅い）。必要なら `build.zig` の
  `b.path("…")` を読んで根を推定する。
