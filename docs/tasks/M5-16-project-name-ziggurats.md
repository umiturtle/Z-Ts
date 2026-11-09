# Task M5-16: プロジェクトのフルネームを `ziggurats` に統一する

- **Status**: `done`
- **Branch**: `arena/a52b9ce6-z-ts`（PR #16 に追加コミット。PR は増やさない）
- **Scope**: 全 `*.md`、`src/docsite/**`、`src/cli/*.zig`、`build.zig`、`zigw`、`.github/workflows/*.yml`、`scripts/*.sh|py`、`scripts/check-docs.py`（規約 14 を追加）、`scripts/doc-sync.json`（再同期）
- **Upstream Reference**: [`../contributing/writing-docs.md`](../contributing/writing-docs.md) 規約 14 / [`../contributing/doc-sync.md`](../contributing/doc-sync.md)（規約 13）
- **Next Step**: なし（完了）。リポジトリ名を変更するときは、URL / チェックアウトパスに残した旧称と、
  デモの可視テキスト（生成器 + 生成物）をまとめて更新する。

---

## 1. 決定と完了条件

**決定**: このプロジェクトのフルネームは **`ziggurats`**（常に小文字）。
**コマンド名・パッケージ名は従来どおり** `zts` / `z_ts` / `zts_*` / `ZTS_*`。
**リポジトリ名は所有者があとで変更する**ので、URL とパスは触らない。

- [x] doc / README / 索引 などに書かれた旧称（プロジェクト名）を `ziggurats` に置換
- [x] サイトの UI（ブランド・`<title>`・フッター・404・`llms.txt`・カード・パンくず）も統一
- [x] `zts` のヘルプ・生成されるプロジェクトの README・CI のリリースノート・スクリプトの表示も統一
- [x] `zts` / `z_ts` / `zts_*` / `ZTS_*` を 1 文字も壊さない（置換前後で出現数が完全一致）
- [x] リポジトリ URL / チェックアウトパス名は据え置き
- [x] 再発防止（規約 14）と、同期台帳（規約 13）の再同期
- [x] `./zigw docs-check` / `fmt --check` / 3 OS CI が緑

## 2. 置換の範囲（巻き込まないための線引き）

| 置換したもの | 置換しなかったもの |
|---|---|
| 全 `*.md`（README / 両言語の索引 / 用語集 / learn / reference / contributing / examples の README / ADR / 設計メモ / タスク票 / roadmap / `AGENTS.md`） | リポジトリ URL（`github.com/umiturtle/…`、`umiturtle.github.io/…/`、`/…/` サブパス） |
| `src/docsite/**` の UI 文字列・コメント（`site_title`、ブランド、`© …`、パンくず、メタ description、API バナー、404、パス名の見出し） | チェックアウトのパス名（`cd …`、`../…`、`/home/you/…`、`--zts-path /path/to/…`） |
| `src/cli/*.zig` のヘルプ・エラーメッセージ・生成 README・doc コメント | `zts` / `z_ts` / `zts_*` / `ZTS_*` の識別子と CLI 出力 |
| `build.zig` のステップ名・オプション説明、`zigw`、CI のコメントとリリースタイトル本文、`scripts/*.sh|py` の表示・コメント | ソースのテストデータ（`"Hello, …!"`、JSON フィクスチャ、レジストリキー、トレイの tooltip など） |
| その他の `src/**` の **doc コメント**（`///` / `//!` / `//`）＝ API リファレンスに載る散文 | ライブラリの既定ウィンドウタイトル、Protocol/Bridge の HTML フィクスチャ |
| `src/tauri/config_import.zig` のユーザー向け警告文 | デモの**画面内テキスト**とその生成器（`gen-framework-demos.mjs` / `verify-screenshots.mjs` / `examples/**` の非 MD / `tests/**`） |

デモの可視テキストは **3 OS の画素一致ゲート**の対象なので、生成器と生成物を片方だけ
変えると CI が割れます。リポジトリ名を変更するタイミングで両方を再生成する方針です。

置換は **出現単位の判定**で行いました。旧称の直前が `/` または `\`、直後が `.git`、
`cd ` の直後、`パス/…` の形 → 保護。それ以外 → `ziggurats`。
たとえば `[旧称](https://github.com/umiturtle/…)` は**リンクテキストだけ**置換され、
URL は残ります。

## 3. 規約 14（再発防止）

`scripts/check-docs.py` に追加。

- 走査: 全 `*.md` + `src/docsite/**/*.zig|css|js` + `src/cli/*.zig` + `build.zig` + `zigw`
  + `.github/workflows/*.yml` + `scripts/*.sh`
- 旧称が **URL / パス以外**に残っていたらエラー（ファイル名・行番号付き）
- 頭文字を大文字にした表記・全部大文字の表記もエラー（小文字 `ziggurats` に統一）
- `README.md` / `README.en.md` / 両索引 / `src/docsite/{site,i18n,main}.zig` /
  `src/cli/template.zig` に `ziggurats` が実際に出ることも検査
- `scripts/check-docs.py` 自身は走査対象外（規約が旧称を字面で持つ必要があるため）
- 発火テスト: `docs/glossary.md` に旧称を 1 行足す → `legacy project name … in prose` で落ちる
  → 復元済み

## 4. 検証

```
置換前後の識別子出現数（既存の識別子は 1 文字も変化なし）:
  zts 4494 → 4512 / z_ts 158 → 166 / zts_ 2716 → 2724 / ZTS_ 370 → 373
  （増分は規約 14 の説明・README の注記など、新しく書いた散文が識別子を引用した分。
    git diff の削除行/追加行を比較して「消えた識別子 0」を確認済み）
旧称 688 → 323（残りは URL・パス・テストデータ・デモ資産のみ）
ziggurats 0 → 380
置換: 365 箇所 / 122 ファイル（+ このタスク票 1）

./zigw fmt --check src/ build.zig build.zig.zon → OK
./zigw test -Mroot=src/docsite/mod.zig          → 82 tests
./zigw test -Mroot=src/cli/mod.zig              → 43 tests
./zigw quick-test                                → 7 tests
./zigw doctest                                   → 20 blocks
python3 scripts/check-docs.py                    → OK（規約 14 含む）
python3 scripts/check-docs.py --sync             → 39 pairs を再同期
./zigw build test                                → EXIT=0（3 OS CI と同じビルドグラフ）
./zigw docs-check                                → OK / pages=259 links=1173 api_undoc=0
```

旧称の字面は、チェックアウトのパス・GitHub/Pages の URL・テストデータ・デモの
可視テキストにだけ残ります。リポジトリ改名時にまとめて更新してください。
