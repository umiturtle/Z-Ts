# Task M5-05: OS 間パリティ（同一フォント・同一レイアウト・9 フレームワーク比較）

- **Status**: `done`（CI run `40634580935` で 4 ジョブすべて green）
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `examples/gallery/`（`src/main.zig`, `src/web/**`, `src/fw_assets.zig`）, `examples/frameworks/**`, `scripts/{build-fonts.py,gen-framework-demos.mjs,check-font-coverage.mjs,compare-screenshots.mjs,lib/png.mjs,verify-screenshots.mjs}`, `.github/workflows/ci.yml`, `docs/tasks/M5-05-framework-os-parity.md`, `docs/decisions/0010-cross-os-pixel-parity.md`, `docs/architecture/screenshot-parity.md`, `docs/environment/github-actions.md`, `docs/INDEX.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Next Step**: なし。実測 `OK parity hosts=gtk3,cocoa,win32 patterns=17 comparisons=34 layout=ok pixels=max:9.77% mad:6.07`。
- **実測（2025-10-28, run `40634580935`）**: Linux `OK screenshots host=gtk3 … loose=2` / macOS `host=cocoa … loose=0` /
  Windows `host=win32 … loose=0`、parity は 34 比較すべて通過（17 パターン × gtk3/cocoa/win32）。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 「Linux で文字化けする」「OS ごとに見た目が違う」を **仕組みで** 解消し、9 つの主要フレームワークで作った同じ画面を **3 OS で撮って機械比較** できるようにする。

- [x] Linux の文字化けを根絶する
  - システムフォント（Hiragino / Yu Gothic / Noto CJK / Ubuntu は皆無）に依存しない
  - `ZTS Sans` / `ZTS Serif` / `ZTS Mono` を **同梱 woff2** としてギャラリーが配信し、3 OS のブラウザが同一ファイルを描画する
  - `node scripts/check-font-coverage.mjs` で「同梱フォントに無い文字」を CI で検出（= 豆腐の再発防止）
- [x] 同一解像度で同一表示にする
  - スクロールバー幅（GTK オーバーレイ / Windows クラシック / macOS 自動非表示）の差を `::-webkit-scrollbar{width:0}` で消す
  - `font-synthesis:none` / `text-size-adjust:100%` / `font-display:block` で合成・再折り返しの差を消す
  - ページが `load` + `document.fonts.ready` 後に **レイアウト指紋**（要素の x/y/w/h）を投稿し、OS 間で ≤1px で一致することを検証
- [x] 9 フレームワークのデモを作る（すべて実際のフレームワーク CLI でビルド）
  - Angular / Solid / Svelte / SolidStart / Next.js / Nuxt / Astro / SvelteKit / React
  - 同一 DOM・同一 CSS・同一文言（違うのはフレームワーク名とバージョンのみ。それらは同一文字数にそろえる）
  - `examples/gallery/src/web/fw/<name>/` に静的出力を置き、ギャラリーが `tauri://localhost/fw/<name>/` から配信
- [x] `scripts/compare-screenshots.mjs`（依存ゼロ）で 3 OS の成果物を突き合わせ、`OK parity hosts=… patterns=17 …` を出す
- [x] CI に `ci-parity` ジョブ（`needs: [ci-linux, ci-macos, ci-windows]`）を追加し、3 artifact を 1 か所で比較
- [x] `./zigw fmt --check` / `./zigw quick-test` / `./zigw build test` / `python3 scripts/check-docs.py` のパス
- [x] 3 OS + parity の 4 ジョブがグリーン

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - フォント同梱パイプライン `scripts/build-fonts.py`（Noto Sans JP 400/700・Noto Serif JP 400・JetBrains Mono 400 を、デモで使う文字だけにサブセット化。合計 ~382 KB）
  - ギャラリーのスキームハンドラが `/zts/fonts/*.woff2` を配信。`DOCUMENT_START` 注入スクリプトで `@font-face`（4 本）+ スクロールバー無効化を全ページに適用
  - 8 つの既存パターンの `font-family` をすべて `ZTS Sans` / `ZTS Serif` / `ZTS Mono` に置換（システムフォント 0 参照）
  - レイアウト指紋（`{"app":"layout", boxes:[…], doc_w, doc_h, font_ok}`）を `manifest.json` の `layout` に記録
  - 9 フレームワークのデモを実ビルドして `examples/gallery/src/web/fw/<name>/` に配置（55 ファイル・2.4 MB、`src/fw_assets.zig` は自動生成）
  - `scripts/compare-screenshots.mjs` + `scripts/lib/png.mjs`（PNG デコーダの共有化）
  - `scripts/check-font-coverage.mjs`（豆腐ゲート）
  - `ci-parity` ジョブ追加（3 artifact → 検証 → 比較 → `OK parity` マーカー必須 → artifact 保存）
- **最終状態**: 3 OS ネイティブ撮影 + parity 比較 + フォントカバレッジがすべて CI で緑。
- **根因（当日発見）**: `@font-face` を宣言する `parity_script` が `init_scripts` に入っておらず、
  **どの OS でも同梱フォントが一度も適用されていなかった**（`document.fonts` が空、`faces=""`）。
  各 OS が自前のシステムフォントで描いていたため「Linux だけ豆腐」に見えていた。
  修正後は Linux も `faces=4` / `paint_ok=true`（同梱 woff2 を描画）になる。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **フォントを同梱する理由**: 画素比較の前に「字が違う」問題を消す必要がある。Noto Sans JP の `japanese-400` サブセットは 125 分割されているが、我々は使う文字だけに絞るので 1 ファイル ~108 KB に収まる（`fonttools` + `brotli` で生成、CI では再生成しない）。
- **`font-display: block`**: `swap` だと撮影タイミングでフォールバック字形が写る可能性がある。`block` は 3 秒ブロックした後にフォールバックするが、`document.fonts.ready` を待つので通常は間に合う。
- **丸め誤差の扱い**: レイアウト指紋は 1px に丸めて比較（Blink と WebKit のサブピクセル配置差を吸収）。画素は「3/255 を超える差の割合」で判定。
- **WebKit と Blink はアンチエイリアスが違う**: 完全一致は原理的に不可能なので、実測に基づき
  `--max-diff 0.12`（12% の画素）+ `--max-mad 8`（3% の明度差）+ 平均輝度 ≤3.0 を閾値にする。
  代わりに *構造* を厳密に比較する: 要素リスト・**行数（折返し）は完全一致**、ボックスは ±1px
  ＋ 0.5px/文字（GTK の送り幅整数丸めの上限）、ドキュメント幅は **CSS viewport と完全一致**
  （横スクロール禁止）。この「厳密な構造 + 緩い画素」の組み合わせで、フォント欠落・折返し変化・
  レイアウト崩れはすべて検出できる。
- **WebKitGTK はグリフ送り幅を整数に丸める**（8.88px → 9px）。`text-rendering:geometricPrecision`
  も fontconfig の `hinting=false` も効かない（WebKit が webfont のヒントスタイルを自前で上書きする）。
  → 比較側で 0.5px/文字の余裕を持たせ、テキスト幅に依存するヘッダブロックは `width` 固定 +
  `overflow:hidden` にして箱を全 OS 一致させた。
- **Svelte / SvelteKit のコンポーネント `<style>` はスコープされる**: `html,body,*` などの要素
  セレクタは **黙って捨てられる**（UA 既定の 8px body margin に戻り、ヘッダの箱が OS ごとにズレた）。
  → CSS は `src/app.css` としてグローバルに import する。同種の罠として `.brand > div` が
  `.logo` にも当たり、ロゴが 300px に広がってバッジが画面外へ押し出された（`:not(.logo)` で解決）。
- **`check-font-coverage.mjs` はコメントも検査する**: `examples/gallery/src/web/**` の
  HTML/CSS/JS に新しい漢字（例: 目盛・座標）を書くと CI が落ちる。英語で書くか
  `python3 scripts/build-fonts.py` でサブセットを作り直す。
- **インライン化は失敗した**: フレームワークの出力は複数チャンクの ES モジュールに分かれることがあり、`import "./chunk.js"` はインライン `<script type="module">` から解決できない（SvelteKit の `bundleStrategy:'single'` でも動的 import が残る）。→ 実際の `dist/` を埋め込んでスキームで配信する方式に変更（本物のアプリと同じ経路）。
- **Nuxt の `/_payload.json`**: 静的生成物が payload を fetch する。カスタムスキームでは 404 になるが、SSR 済み HTML はそのまま描画される（hydration の警告のみ）。
