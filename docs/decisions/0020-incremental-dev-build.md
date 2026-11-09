# ADR-0020: `zts dev` の Zig 編集は「型検査」までにし、dirty flag と依存グラフで不要なビルドを消す

- **Status**: Accepted
- **Date**: 2026-10-21
- **Related**: [`../architecture/incremental-dev-build.md`](../architecture/incremental-dev-build.md) /
  [`../tasks/M5-17-incremental-zig-build.md`](../tasks/M5-17-incremental-zig-build.md) /
  [`../architecture/documentation-site.md`](../architecture/documentation-site.md)

## 1. 背景

`zts dev` は `web/` をディスクから配信するプレビューサーバで、Zig の実行ファイルを起動しない。
にもかかわらず `src/` の変更ごとに完全な `zig build`（install: LLVM codegen + link + copy）を
実行していた。実測の内訳は `compile exe … 836 ms` がほぼ全部で、プロセス起動は誤差だった。

加えて 3 つの不具合・無駄があった。

1. `mtime ^ size` だけの監視なので、同一内容の書き戻しでも再ビルドする。
2. 120 ms の待機後に再走査していたが、**差分は待機前の scan から取っていた**。待機中に届いた
   変更は baseline に紛れて二度と報告されない。
3. `build.zig` / `build.zig.zon` を監視しておらず、ビルドグラフの変更が無視されていた。
   アイドル時も毎回 2 回走査していたため実質ポーリング周期は 370 ms だった。

## 2. 検討した選択肢

Zig 0.17.0 の生成プロジェクトで `src/main.zig` に 1 行追加し、7 回計測した中央値。

| 選択肢 | 中央値 | 評価 |
|---|---|---|
| 現状（完全 `zig build`） | 832 ms | baseline |
| **emit されない compile step（`-fno-emit-bin`）** | **426 ms** | ✅ 約 2 倍。意味解析のみ |
| `-fincremental` | 1956 ms | ❌ 2.4 倍**遅い**。小規模プロジェクトでは experimental 機能が逆効果 |
| `--watch` / `--listen=-` 常驻ビルドサーバ | panic | ❌ 不安定＋ inotify/FSEvents 依存で 3 OS 同一挙動を壊す |
| `zig build-exe` を直接呼んで build runner を bypass | 約 370 ms | ❌ 意味解析が下限で効果なし。`build.zig` のモジュール構成を CLI が推測することになり脆い |

`-fincremental` を最初に試して**遅くなる**ことを確認できたのが、この判断の要だった。
「インクリメンタル」という名前のフラグを無批判に採用しなくてよかった。

## 3. 決定

### 3.1 通常の Zig 編集は `zig build check` にする

生成 `build.zig` に、出力バイナリを誰も要求しない compile step を追加する。Zig 0.17 は自動で
`-fno-emit-bin` を付け、LLVM codegen・リンク・install を省略する。`zts dev` が必要とするのは
「型が通ったか」だけなので、これで十分。

**初回ビルドと `zts build` は完全ビルドのまま**。リンクエラーの検出と、プロジェクトに本物の
バイナリが存在することを保証するため。

### 3.2 速さより「見落とさない」を優先する

`check` step が無い古いテンプレート、ネイティブライブラリをリンクする `build.zig`、
依存グラフを完全に構築できない場合、ファイルの追加削除、`build.zig*` の変更、
`ZTS_DEV_BUILD=full` —— すべて完全ビルドへフォールバックする。
**誤ってスキップするより遅いほうがまし**という方針を `plan()` に埋め込んだ。

### 3.3 dirty flag と依存グラフで「そもそもビルドしない」を増やす

* Zig ソースは内容ハッシュ（`Wyhash`）で比較し、stat は読み直しの事前フィルタに格下げ。
  `touch` / フォーマッタの同一内容書き戻しは 0 回。
* `src/main.zig` から相対 `@import` / `@embedFile` を辿った到達集合を作り、
  到達不能なファイルの編集はビルドもリロードもしない。
* 待機後の**最終 scan** に対して差分を取り、バーストを 1 回に畳む（2. のバグ修正）。
* 変更直後だけポーリングを 100 ms に上げる（アイドル 250 ms）。ネイティブ監視は使わない。

### 3.4 検証を成果物にする

`scripts/bench-dev-loop.py` を追加した。`bench` は編集→`v` 加算の実時間を測り、
`--old-zts` で変更前リビジョンのバイナリとの真の A/B も取れる。`--min-speedup` を下回ると
失敗する回帰ゲート。`verify` は型エラーと回復・dirty flag・到達不能ファイル・CSS 差し替え・
`build.zig` 変更・デバウンの 7 不変条件を実プロセスで検査し、CI の CLI ジョブから常時実行する。

## 4. 結果

```text
旧バイナリ（変更前リビジョン） 1110.5 ms → 新バイナリ 637.9 ms  = 1.74x
同一バイナリ full vs check   955.2 ms → 637.9 ms  = 1.50x
zig build vs zig build check 720.8 ms → 376.6 ms  = 1.91x
単体テスト 55 件 / quick-test 7 件 / build test / fmt / docs-check すべて緑
```

## 5. 帰結・注意点

* **`zts dev` の「ok」は「型が通った」という意味に変わる**。実行ファイルの検証は `zts build`。
  ドキュメント（`docs/reference/cli*.md`、学習ページ、トラブルシューティング）に明記した。
  これは「プレビューは `web/` だけ」という既存の設計と矛盾しない。
* 未参照のトップレベル宣言は完全ビルドでも遅延解析されるため、型検査でも完全ビルドでも
  検出されない。両者で検出能力は変わらない（実験で確認）。
* `-fincremental` は Zig 側が成熟した時点で再評価する。`--listen=-` は意味解析の下限を
  超えられないため、今のところ実装コストに見合わない。
* グラフの根を `src/main.zig` に固定した。別エントリのプロジェクトは完全ビルドに落ちる
  （正しいが遅い）。必要なら `build.zig` の `b.path()` から根を推定する。
