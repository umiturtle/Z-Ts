# Task M5-20: チュートリアルを全フレームワーク example へ分岐する

- **Status**: `in_progress`
- **Branch**: `arena/e54ae0fb-z-ts`（PR #19 に追加コミット。PR は増やさない）
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

- **現在**: 現状復元・設計完了。分散ロックのためこの票を先に push。
- **次**: `frameworks.json` → `frameworks.zig` → picker directive → 生成スクリプト → 規約 15。
