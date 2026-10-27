# Task M5-05: OS 間パリティ（同一フォント・同一レイアウト・9 フレームワーク比較）

- **Status**: `in_progress`
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `examples/gallery/`（`src/main.zig`, `src/web/**`, `src/fw_assets.zig`）, `examples/frameworks/**`, `scripts/{build-fonts.py,gen-framework-demos.mjs,check-font-coverage.mjs,compare-screenshots.mjs,lib/png.mjs,verify-screenshots.mjs}`, `.github/workflows/ci.yml`, `docs/tasks/M5-05-framework-os-parity.md`, `docs/decisions/0010-cross-os-pixel-parity.md`, `docs/architecture/screenshot-parity.md`, `docs/environment/github-actions.md`, `docs/INDEX.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Next Step**: CI 4 ジョブ（Linux / macOS / Windows / parity）を回し、`OK parity …` の実測値を確認して閾値（`--max-diff 0.06` / `--max-mad 6`）を確定する。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: 「Linux で文字化けする」「OS ごとに見た目が違う」を **仕組みで** 解消し、9 つの主要フレームワークで作った同じ画面を **3 OS で撮って機械比較** できるようにする。

- [ ] Linux の文字化けを根絶する
  - システムフォント（Hiragino / Yu Gothic / Noto CJK / Ubuntu は皆無）に依存しない
  - `ZTS Sans` / `ZTS Serif` / `ZTS Mono` を **同梱 woff2** としてギャラリーが配信し、3 OS のブラウザが同一ファイルを描画する
  - `node scripts/check-font-coverage.mjs` で「同梱フォントに無い文字」を CI で検出（= 豆腐の再発防止）
- [ ] 同一解像度で同一表示にする
  - スクロールバー幅（GTK オーバーレイ / Windows クラシック / macOS 自動非表示）の差を `::-webkit-scrollbar{width:0}` で消す
  - `font-synthesis:none` / `text-size-adjust:100%` / `font-display:block` で合成・再折り返しの差を消す
  - ページが `load` + `document.fonts.ready` 後に **レイアウト指紋**（要素の x/y/w/h）を投稿し、OS 間で ≤1px で一致することを検証
- [ ] 9 フレームワークのデモを作る（すべて実際のフレームワーク CLI でビルド）
  - Angular / Solid / Svelte / SolidStart / Next.js / Nuxt / Astro / SvelteKit / React
  - 同一 DOM・同一 CSS・同一文言（違うのはフレームワーク名とバージョンのみ。それらは同一文字数にそろえる）
  - `examples/gallery/src/web/fw/<name>/` に静的出力を置き、ギャラリーが `tauri://localhost/fw/<name>/` から配信
- [ ] `scripts/compare-screenshots.mjs`（依存ゼロ）で 3 OS の成果物を突き合わせ、`OK parity hosts=… patterns=17 …` を出す
- [ ] CI に `ci-parity` ジョブ（`needs: [ci-linux, ci-macos, ci-windows]`）を追加し、3 artifact を 1 か所で比較
- [ ] `./zigw fmt --check` / `./zigw quick-test` / `./zigw build test` / `python3 scripts/check-docs.py` のパス
- [ ] 3 OS + parity の 4 ジョブがグリーン

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
- **作業中・直前の状態**: ローカル（mock バックエンド）で 17 パターン撮影 + verifier + フォントカバレッジが緑。**実機 3 OS の比較は次の CI 待ち**。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **フォントを同梱する理由**: 画素比較の前に「字が違う」問題を消す必要がある。Noto Sans JP の `japanese-400` サブセットは 125 分割されているが、我々は使う文字だけに絞るので 1 ファイル ~108 KB に収まる（`fonttools` + `brotli` で生成、CI では再生成しない）。
- **`font-display: block`**: `swap` だと撮影タイミングでフォールバック字形が写る可能性がある。`block` は 3 秒ブロックした後にフォールバックするが、`document.fonts.ready` を待つので通常は間に合う。
- **丸め誤差の扱い**: レイアウト指紋は 1px に丸めて比較（Blink と WebKit のサブピクセル配置差を吸収）。画素は「3/255 を超える差の割合」で判定。
- **WebKit と Blink はアンチエイリアスが違う**: 完全一致は原理的に不可能なので、`--max-diff 0.06`（6% の画素）+ `--max-mad 6` を閾値にする。背景色 (1,1) と平均輝度は **厳密** に比較する（色の退行は許さない）。
- **インライン化は失敗した**: フレームワークの出力は複数チャンクの ES モジュールに分かれることがあり、`import "./chunk.js"` はインライン `<script type="module">` から解決できない（SvelteKit の `bundleStrategy:'single'` でも動的 import が残る）。→ 実際の `dist/` を埋め込んでスキームで配信する方式に変更（本物のアプリと同じ経路）。
- **Nuxt の `/_payload.json`**: 静的生成物が payload を fetch する。カスタムスキームでは 404 になるが、SSR 済み HTML はそのまま描画される（hydration の警告のみ）。
