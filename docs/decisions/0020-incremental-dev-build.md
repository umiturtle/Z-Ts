# ADR-0020: `zts dev` は常駐コンパイラサーバで型検査し、dirty flag と依存グラフで不要なビルドを消す

- **Status**: Accepted（2026-10-21 改訂: バックエンドの誤認を訂正し、常駐サーバを追加）
- **Date**: 2026-10-21
- **Related**: [`../architecture/incremental-dev-build.md`](../architecture/incremental-dev-build.md) /
  [`../tasks/M5-17-incremental-zig-build.md`](../tasks/M5-17-incremental-zig-build.md) /
  [`../architecture/documentation-site.md`](../architecture/documentation-site.md)

## 1. 背景

`zts dev` は `web/` をディスクから配信するプレビューサーバで、Zig の実行ファイルを起動しない。
にもかかわらず `src/` の変更ごとに完全な `zig build`（install）を実行していた。

当初の設計メモは「LLVM の codegen + link が 836 ms のボトルネック」と書いたが、**これは誤りだった**。
Zig 0.17.0 の Debug は自前バックエンドを使う。同一モジュールグラフを `zig build-exe` に直接渡すと:

```text
既定（自前バックエンド）   717 ms
-fno-llvm                 690 ms
-fllvm（LLVM 強制）       3021 ms   ← 4 倍以上遅い
-fno-emit-bin              366 ms
```

つまり内訳は **コンパイラ起動 + `std`/モジュール意味解析（約 370 ms）** と
**自前バックエンドの codegen + link（約 320 ms）**。LLVM ではない。
`-fno-emit-bin` は後半を消すが、前半 370 ms は毎回のプロセス起動で必ず払う。

加えて 3 つの不具合・無駄があった。

1. `mtime ^ size` だけの監視なので、同一内容の書き戻しでも再ビルドする。
2. 120 ms の待機後に再走査していたが、**差分は待機前の scan から取っていた**。待機中に届いた
   変更は baseline に紛れて二度と報告されない。
3. `build.zig` / `build.zig.zon` を監視しておらず、ビルドグラフの変更が無視されていた。
   アイドル時も毎回 2 回走査していたため実質ポーリング周期は 370 ms だった。

## 2. 検討した選択肢

| 選択肢 | 中央値 | 評価 |
|---|---|---|
| 現状（完全 `zig build`） | 708〜832 ms | baseline |
| emit されない compile step（`-fno-emit-bin`） | 377〜426 ms | ✅ 約 1.9x。ただし毎回 370 ms の意味解析が残る |
| `-fincremental`（毎回新規プロセス） | 1512〜1956 ms | ❌ 2.4 倍**遅い**。差分状態はプロセス内にしか残らない |
| `--watch`（ビルドランナー常駐＋ネイティブ監視） | panic | ❌ このツールチェーンで不安定 |
| `zig build-exe` を直接呼んで build runner を bypass | 約 370 ms | ❌ 意味解析が下限で効果なし |
| **コンパイラを 1 つ常駐させ `--listen=-` で `update` を送る** | **初回 440 ms → 4 ms** | ✅ **採用**。型エラーも 11 ms で検出 |

重要な訂正点: 最初の版では `--listen=-` を「プロトコル実装が重い」として却下し、
`-fincremental` の実測だけを見て「Zig の incremental は遅い」と結論していた。
**`-fincremental` が効くのはコンパイラプロセスが生き残る場合だけ**で、
`zig build` を毎回起動する形では逆に遅くなる。`--watch` が壊れていてもコンパイラサーバ
自体は直接駆動できる、というレビュー指摘がこの判断を変えた。

## 3. 決定

### 3.1 通常の Zig 編集は常駐コンパイラサーバの `update` にする

`zig build check --verbose` で**実際のコンパイラ引数**を 1 回取得し、
`-fno-llvm -fincremental --listen=-` を付けて `zig build-exe` を 1 プロセスだけ spawn する。
`std.zig.Client` で `zig_version` ハンドシェイク → 起動時に 1 回 `update`（意味解析を温める）
→ 以後は編集 1 回につき `update` を 1 通。終端の `error_bundle` を
`ErrorBundle.renderToStderr` で表示し、成否を `ok` / `v` に反映する。

**初回ビルドと `zts build` は完全ビルドのまま**。リンクエラーの検出と、プロジェクトに本物の
バイナリが存在することを保証するため。完全ビルドの前にはサーバを閉じてキャッシュ競合を避ける。

### 3.2 速さより「見落とさない」を優先する

`check` step が無い古いテンプレート、ネイティブライブラリをリンクする `build.zig`、
`--verbose` の解析失敗、spawn / ハンドシェイク / プロトコルの失敗、依存グラフを完全に
構築できない場合、ファイルの追加削除、`build.zig*` の変更、`ZTS_DEV_BUILD=full` ——
すべて `zig build check` または完全ビルドへフォールバックする。
**誤って成功を返すより遅いほうがまし**という方針を `plan()` と `runDev` に埋め込んだ。

### 3.3 dirty flag と依存グラフで「そもそもビルドしない」を増やす

* Zig ソースは内容ハッシュ（`Wyhash`）で比較し、stat は読み直しの事前フィルタに格下げ。
  `touch` / フォーマッタの同一内容書き戻しは 0 回。
* `src/main.zig` から相対 `@import` / `@embedFile` を辿った到達集合を作り、
  到達不能なファイルの編集はビルドもリロードもしない。
* 待機後の**最終 scan** に対して差分を取り、バーストを 1 回に畳む（3. のバグ修正）。
* 変更直後だけポーリングを 50 ms に上げる（アイドル 250 ms、まとめ 60 ms）。
  ネイティブ監視は使わない。

### 3.4 検証を成果物にする

`scripts/bench-dev-loop.py` を追加した。`bench` は編集→`v` 加算の実時間を測り、
`--old-zts` で変更前リビジョンのバイナリとの真の A/B も取れる。`--min-speedup` を下回ると
失敗する回帰ゲート。`verify` は型エラーと回復・dirty flag・到達不能ファイル・CSS 差し替え・
`build.zig` 変更・デバウンの 8 不変条件を実プロセスで検査し、CI の CLI ジョブから常時実行する。

## 4. 結果

```text
旧バイナリ（変更前リビジョン） 1096.1 ms → 新バイナリ 115.5 ms  = 9.49x
同一バイナリ full vs fast check 827.4 ms → 115.5 ms  = 7.17x
コンパイルそのもの             4 ms（初回 update 440 ms）
zig build vs zig build check  727.6 ms → 385.6 ms  = 1.89x
単体テスト 57 件 / quick-test 7 件 / build test / fmt / docs-check すべて緑
```

## 5. 帰結・注意点

* **`zts dev` の「ok」は「型が通った」という意味に変わる**。実行ファイルの検証は `zts build`。
  ドキュメント（`docs/reference/cli*.md`、学習ページ、トラブルシューティング）に明記した。
  これは「プレビューは `web/` だけ」という既存の設計と矛盾しない。
* 未参照のトップレベル宣言は完全ビルドでも遅延解析されるため、型検査でも常駐サーバでも
  検出されない。両者で検出能力は変わらない（実験で確認）。
* 常駐サーバは `--verbose` の出力形式と `--listen=-` プロトコルに依存する。
  どちらが変わってもハンドシェイク／引数検証で弾いて `zig build check` に落ちる
  （遅くなるだけで壊れない）。`zig_version` も検証する。
* `--watch` の panic はこのツールチェーンのファイル監視実装に起因する。自前のポーリングを
  維持したので 3 OS 同一挙動は保たれている。
* グラフの根を `src/main.zig` に固定した。別エントリのプロジェクトは完全ビルドに落ちる
  （正しいが遅い）。必要なら `--verbose` で得た引数から根を推定する。
