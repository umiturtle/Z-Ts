# Task M5-20: チュートリアルを全フレームワーク example へ分岐する

- **Status**: `review`（PR #19 に追加。CI 確認待ち）
- **Branch**: `arena/e54ae0fb-z-ts`（PR #19 に追加コミット。PR は増やさない）
- **Scope**: `src/docsite/{frameworks.json,frameworks.zig,main.zig,assets/site.js,assets/site.css}`,
  `scripts/{gen-framework-tutorials.py,check-docs.py,doc-sync.json}`,
  `docs/learn/{ja,en}/tutorials/*`, `docs/INDEX{,.en}.md`,
  `docs/contributing/writing-docs.md`, `examples/frameworks/README{,.en}.md`
- **Next Step**: PR #19 の 3 OS CI が緑になったら完了。
- **依頼**: 「Docのチュートリアルを分岐して同様のものをexample入りさせてる全ライブラリそれぞれ好きなライブラリでチュートリアルできるようにして」
- **解釈**: `examples/frameworks/` に実物がある 9 ライブラリ（React / Solid / Svelte / Angular /
  Next.js / Nuxt / Astro / SvelteKit / SolidStart）＋フレームワーク無し（素の JS）の 10 択で、
  同じ「カウンターを作る」チュートリアルを**好きなライブラリで**通せるようにする。
  Todo / 画面の 2 本も picker と「読み替え表」で全ライブラリ対応にする（全 3 本を 9 倍に
  複製すると Doc がぐちゃぐちゃになるため、Zig 側が共通なことを明示して分岐を 1 箇所に集約）。

## スコープ

- `src/docsite/frameworks.json`（9 件の**単一の真実**: id / label / version / build / dist / source / note / state / demo）
- `src/docsite/frameworks.zig`（JSON を `@embedFile` → picker の Markdown 表を生成。 existence テスト付き）
- `src/docsite/main.zig`（`<!-- framework-picker -->` directive、日英）
- `src/docsite/assets/site.js` / `site.css`（表を `<select>` に progressive enhance。JS 無しでも表が残る）
- `scripts/gen-framework-tutorials.py`（カタログから 18 バリアント + 2 選択ページを生成）
- `docs/learn/{ja,en}/tutorials/frameworks.md`（選択ハブ）
- `docs/learn/{ja,en}/tutorials/counter-<id>.md` × 9（実 example のソースを埋め込む）
- `docs/learn/{ja,en}/tutorials/{index,counter,todo,ui}.md`（picker と導線を追加）
- `docs/INDEX{,.en}.md`（規約 11）、`docs/contributing/writing-docs.md`（規約 15 の説明）
- `examples/frameworks/README{,.en}.md`（チュートリアルへの導線）
- `scripts/check-docs.py`（規約 15: カタログ ↔ example ディレクトリ ↔ バリアント ↔ 埋め込みコードの一致）
- `scripts/doc-sync.json`（規約 13）

## 設計の理由

1. **分岐は「代替」であって「追加の章」ではない** → `learn_path.zig` の 5 ステップ・50 分は
   変更しない（規約 12）。選んだ 1 本を読めば 15 分で終わる。
2. **example を本文に埋め込む** → `<!-- source: <path> -->` の直後のコードフェンスが
   コミット済み example の連続部分文字列であることを規約 15 が検査。Doc と実装がズレたら赤。
3. **UI は日英** → picker の見出し・ラベル・ボタンは `frameworks.zig` の `Text` と
   `site.js` の `isJa` で切り替え。静的表（JS 無し）も日英。
4. **`zigw` を読者に出さない**（規約 10）／`ziggurats` 表記（規約 14）／内部 ID を出さない（規約 3）。

## 完了条件

- [ ] 10 択の picker が日英の全チュートリアルに出る
- [ ] 9 ライブラリ × 日英 = 18 バリアントが実 example 込みで存在
- [ ] 規約 11 / 12 / 13 / 14 / 15 が緑
- [ ] `quick-test` / `build test` / `doctest` / `fmt --check` / `docs-check` / 3 OS CI が緑
- [ ] PR は #19 の 1 本だけ

## Current State / Next Step

- **完了**:
  - `frameworks.json`（9 件の単一の真実）＋ `frameworks.zig`（`@embedFile` → picker 表、
    example ディレクトリとソースの存在テスト）
  - `<!-- framework-picker -->`（日英の 10 行表）と `<!-- source: … -->`（日英の出典キャプション）
    を `expandDirectives` に追加。4 本の既存チュートリアル × 2 言語すべてに picker を設置
  - `site.js` が表を `<select>` へ progressive enhance（JS 無しでも 10 個の実リンク）、
    `site.css` にライト／ダーク両対応のスタイル
  - `scripts/gen-framework-tutorials.py` が 9 ライブラリ × 日英 = 18 バリアントと
    日英の選択ハブを生成。各ページに**コミット済み example の実コード抜粋**を埋め込み
  - 規約 15: カタログ ↔ example ディレクトリ ↔ バリアント ↔ 埋め込みコード片 ↔
    生成ページの鮮度 ↔ サイト UI 资产 を機械検査
  - 規約 11（索引 10 行 × 2 言語）・12（5 ステップ / 95 分は不変、`page_order` に選択ハブを追加）
    ・13（49 組へ再同期）・14 を維持
  - `README{,.en}.md` / 学習ハブ / `examples/frameworks/README{,.en}.md` / 書き方ガイドに導線
  - ローカル検証: `quick-test` 90/3/4/62/86/37/8、`build test` exit 0、`doctest` 20、
    `fmt --check`、`docs-check`（`docsite pages=292 links=1828 api_undoc=0`）、
    `gen-framework-tutorials.py --check`、`node --check site.js` すべて緑
- **CI 追加修正**: `bench-dev-loop.py verify` の「同一内容の再書込み」不変条件が
  `Path.write_text()` の truncate→write の隙間を watcher が読んで誤検知する競合を修正。
  `atomic_write()`（一時ファイル → `os.replace`）に統一し、ローカルで 4 連続すべて
  `OK: all dev-loop invariants hold`。Docs 作業とは無関係な既存の flake だが、
  3 OS CI を緑にするため同一 PR で解消。
- **現在**: PR #19 へ追加コミット済み。3 OS CI の再実行を確認中。

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-11-14 -->
