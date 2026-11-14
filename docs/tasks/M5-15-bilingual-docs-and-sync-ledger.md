# Task M5-15: 英語版を完成させ、Doc / 言語別 Doc / 実装の同期台帳を作る

- **Status**: `done`
- **Branch**: `arena/a52b9ce6-z-ts`（PR #16 に追加コミット。PR は増やさない）
- **Scope**: `scripts/{check-docs.py,doc-sync.json}`, `src/docsite/{main,i18n}.zig`, `docs/INDEX{,.en}.md`, `README{,.en}.md`, `docs/glossary{,.en}.md`, `docs/reference/*.en.md`, `docs/contributing/*.en.md`, `examples/*/README.en.md`, `docs/tasks/M5-15-*.md`
- **Upstream Reference**: [`../contributing/writing-docs.md`](../contributing/writing-docs.md) 規約 11〜13 / [`../architecture/docs-as-a-product.md`](../architecture/docs-as-a-product.md)
- **Next Step**: なし（完了）。本文か `SYNC_IMPL` のファイルを変えたら
  `python3 scripts/check-docs.py --sync` → 差分を確認 → コミット。

---

## 1. 依頼と完了条件

依頼は 2 つ:

1. **「Doc と言語別ドックと実装をずれないようにするために、いつ最終書き換えか、どのバージョンまで
   無矛盾を確認したかを記録するの必要じゃない？」**
2. **「あと英語版完成させて」**

- [x] 全読者向けページの日本語版・英語版 1 組につき、最終書き換え日・確認バージョン・確認コミット・
      確認コマンド・本文 sha256・実装 sha256 を記録する台帳を作る
- [x] 記録が**機械的に検査**されること（書き換え忘れ・実装変更後の再確認忘れ・片言語だけの更新を検出）
- [x] サイトの英語版を完成させる（`learn/en/` 以外も English で読める）
- [x] 言語切替が両方向に動き、英語のサイドバーが英語ページだけを指すこと
- [x] 両言語の索引がそれぞれの全ページを網羅すること
- [x] `./zigw docs-check` / `fmt --check` / 3 OS CI が緑

## 2. 英訳の範囲

**公開サイトの読者向けページ（サイドバー 11 グループのうち「内部資料」を除く全ページ）**を
日英 2 言語にしました。

| 種別 | 日本語 | 英語 | 方式 |
|---|---|---|---|
| 学習ツリー | `docs/learn/ja/**`（24） | `docs/learn/en/**`（24） | 既存。同名ファイル |
| 1 回しか存在しないページ | `README.md`, `docs/INDEX.md`, `docs/glossary.md`, `docs/reference/*.md`（3）, `docs/contributing/*.md`（5）, `examples/*/README.md`（4） | **`*.en.md` ミラー**（15） | 新規 |
| 内部資料 | `architecture/`, `decisions/`, `tasks/`, `roadmap/`, `environment/`, `AGENTS.md` | **日本語専用のまま** | プロジェクトの記憶・並列エージェント運用であり読者マニュアルではない。英語の索引・台帳に明記 |

新規英語ページ 15 本: 索引 / 用語集 / ルート README / CLI / Tauri 使い方 / Tauri 内部実装 /
contributing 5 本（README・地図・トラブルシュート・書き方・同期台帳）/ examples 4 本。
`zig check` の例やコマンド・フラグは日本語版と同じ値を保持（規約 4 を両言語に拡張）。

`doc-sync.md` / `doc-sync.en.md` は `--sync` が生成するビューで、台帳の正本は
`scripts/doc-sync.json`。

## 3. 設計判断

### 3.1 `*.en.md` ミラー方式

`docs/learn/` は `ja/` ↔ `en/` のディレクトリ対、それ以外は **同じディレクトリに
`<stem>.en.md`** を置く。`i18n.Lang.fromPath()` が `.en.md` を `.en` と判定し、
`alternateHref()` が双方向に変換する。`main.altHref()` が実在を確認してから
`alt_href` を返すので、ミラーの無い内部ページでは言語切替を**隠す**（404 に飛ばさない）。

- `groupFor()` / `pageKind()` / `navRank()` は `docStem()` で `.en.md` を正規化し、
  日本語版と**同じグループ・同じ位置**に置く
- `buildGroups()` は `page.alt_href != null && page.lang != lang` で片方だけを採用
  （`isTranslated()` のハードコードを廃止）。 counterpart の無い内部ページは両方の
  サイドバーに残り、英語側では `englishNavTitle()` がラベルだけ英訳する
- 英語のランディングカード・404 も英語ページを指す。404 は `en/404.html` を追加し、
  両方に言語切替を付けた
- ディレクトリ索引・`llms.txt` は日本語版を正本とし、ミラーを二重掲載しない

URL は `docs/INDEX.en.html` のように `.en.html` になる。相対リンクは日本語版と同じ
階層なので既存のリンク検査がそのまま効く。

### 3.2 同期台帳（規約 13）

`scripts/doc-sync.json`:

```json
{
  "schema": 1,
  "verified": {
    "date": "2026-10-21", "commit": "6613147",
    "zts_version": "0.1.0", "zig_version": "0.17.0",
    "checks": ["python3 scripts/check-docs.py", "./zigw docs-check", ...],
    "implementation": ["src/cli/args.zig", "src/docsite/main.zig", ...],
    "implementation_sha256": "…"
  },
  "pages": [
    { "ja": "…", "en": "…", "last_rewritten": "2026-10-21",
      "ja_sha256": "…", "en_sha256": "…" }
  ]
}
```

- **日英 1 組 = 1 行**。片方だけ更新しても、もう片方のハッシュがずれない限り同じ
  `last_rewritten` を共有する = 片言語だけ直すことができない
- **本文ハッシュ** → 「書き換えたのに最終書き換え日を更新していない」を検出
- **実装ハッシュ**（CLI・生成器・パス表・`check-docs.py` の 10 ファイル） →
  「実装が変わったのに再確認していない」を検出
- **バージョン**は `build.zig.zon` の `.version` / `minimum_zig_version` と突き合わせ、
  確認コミット・確認コマンドも記録
- **英語版の実在**・英語 H1 に日本語が残っていないこと・日本語版のバイトコピーでないことを検査
- `--sync` は内容が変わったページの日付だけ更新し、未変更ページの日付は保持。
  台帳ビュー（日英）も生成するため**正本は 1 ファイル**。2 回連続で実行しても
  出力が変わらないことを確認済み

Git 履歴に依存しない（sha256 のみ）ので、`actions/checkout` の shallow clone でも動く。
`fetch-depth: 0` のような CI の変更は不要。

発火テスト: `glossary.en.md` に 1 行足す → 本文ハッシュ不一致で落ちる /
`src/docsite/i18n.zig` に 1 行足す → 実装ハッシュ不一致で落ちる /
`README.en.md` を一時退避 → 「missing English counterpart」で落ちる。すべて復元済み。

### 3.3 規約 4・10・11・12 の拡張

| 規約 | 変更 |
|---|---|
| 4 | CLI フラグ・サブコマンドの照合を `cli.md` と `cli.en.md` の両方に |
| 10 | `README.en.md` を読者向け走査に追加（ルート README も `md_files` に追加） |
| 11 | 日本語索引は日本語ページ、英語索引は英語ページを網羅するよう 2 本化 |
| 12 | ステップ表の分の照合に `INDEX.en.md` / `README.en.md` を追加 |

## 4. 検証

```
python3 scripts/check-docs.py            → OK（144 Markdown / 24 pages × 2 / 39 pairs）
python3 scripts/check-docs.py --sync     → 39 bilingual pairs（2 回連続でも出力不変）
./zigw test -Mroot=src/docsite/mod.zig  → 82 tests
./zigw quick-test / cli                  → 7 / 43 tests
./zigw doctest                           → 20 blocks
./zigw fmt --check src/ build.zig ...   → OK
./zigw docs-check                        → OK
./zigw build docs
  pages=258 links=1171 words=598528 api_undoc=0
  （241 → 258: 英語ミラー 15 + 日本語台帳 1 + このタスク票 1。404 も en/ に追加）
```

生成 HTML の全ページ走査: サイドバーは **全ページ 11 グループ**、
英語ミラー 15 ページすべてに `hreflang="ja"` の切替と `data-lang="en"`、
英語サイドバーに日本語ラベルは 0 件、404 も日英 2 枚。

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-11-14 -->
