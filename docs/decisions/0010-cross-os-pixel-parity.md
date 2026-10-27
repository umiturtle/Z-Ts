# ADR-0010: OS 間で「同じ表示」を保証する（同梱フォント + レイアウト指紋 + 画素許容差）

- **Status**: Accepted（`M5-05`）
- **Date**: 2026-10-27
- **関連**: [`0009-screenshot-capture-and-ci-gallery.md`](0009-screenshot-capture-and-ci-gallery.md)、
  [`../architecture/screenshot-parity.md`](../architecture/screenshot-parity.md)、
  [`../environment/github-actions.md`](../environment/github-actions.md)、
  [`../tasks/M5-05-framework-os-parity.md`](../tasks/M5-05-framework-os-parity.md)

---

## 1. 背景

`M5-04` で 3 OS のスクリーンショットが撮れるようになったが、Linux の成果物は **文字化け** していた。
原因はページがシステムフォントを指定していたこと:

| OS | `-apple-system, "Hiragino Sans", "Noto Sans CJK JP", sans-serif` の解決先 |
|---|---|
| macOS | Hiragino Sans（ヒンティング・字幅とも独自） |
| Windows | Segoe UI + Yu Gothic UI |
| Linux (ubuntu-24.04 runner) | **どれも無い** → `sans-serif` → DejaVu Sans（CJK 無し）→ **豆腐（□）** |

結果として、同じ HTML でも OS ごとに字幅・行送りが変わり、比較が成立しなかった。
さらに OS ごとの差として次が残っていた:

1. **スクロールバー**: GTK はオーバーレイ（幅 0）、Windows はクラシック（17px 消費）、macOS は自動非表示。
   本文の折り返し位置が変わる。
2. **アンチエイリアス**: WKWebView（macOS/GTK は WebKit）と WebView2（Blink）で方式が違う。
3. **DPR**: Retina では 2 倍の画素で撮れる。

## 2. 決定事項

### 2.1 描画に使うフォントは「同梱 woff2」だけにする

`ZTS Sans`（Noto Sans JP 400/700）、`ZTS Serif`（Noto Serif JP 400）、`ZTS Mono`（JetBrains Mono 400）を
`examples/gallery/src/web/fonts/` に置き、ギャラリーのスキームハンドラが
`/zts/fonts/*.woff2` として **3 OS に同一バイト列** を配信する。

- サブセットは `scripts/build-fonts.py`（`fonttools` + `brotli`）で生成。デモに出る文字だけに絞るので合計 ~382 KB。
- 生成物と `coverage.txt`（収録文字一覧）は **コミットする**。CI は再生成しない（毎チャットの
  コールドスタートを守る）。
- ページ側の `font-family` は `ZTS Sans` / `ZTS Serif` / `ZTS Mono` のみ。`DOCUMENT_START` で
  `@font-face` を 4 本注入するので、ページに宣言が無くても効く。
- `font-display: block`（フォールバック字形を撮らない）+ `font-synthesis: none`（擬似ボールド禁止）。

**豆腐の再発防止はゲートで行う**: `node scripts/check-font-coverage.mjs` が
`examples/gallery/src/web/**/*.html` の全文字を `coverage.txt` と突き合わせ、1 文字でも
収録外なら `FAIL font-coverage …` で CI を落とす。文言を足したら
`python3 scripts/build-fonts.py` を再実行する、という運用を機械的に強制する。

### 2.2 スクロールバーを全ページで消す

```css
html { scrollbar-width: none; }
::-webkit-scrollbar { width: 0; height: 0; }
```

OS ごとに幅が違うと **本文の折り返しが変わる**（＝画素が変わる）。ギャラリーは
「アプリの画面を撮る」ためのものなので、スクロール位置はページ側の工夫（`scroll-offset` パターン）
で表現する。

### 2.3 「同じ表示」は 2 段で検証する

| 層 | 何を比べるか | 許容差 | 実装 |
|---|---|---|---|
| **レイアウト** | 各要素の `getBoundingClientRect()`（x/y/w/h を 1px に丸め）+ ドキュメントサイズ + `font_ok` | **1px** | ページが `{"app":"layout", …}` を投稿 → `manifest.json` の `layout` → `compare-screenshots.mjs` |
| **画素** | 全画素の差（3/255 超の割合 + 平均絶対差）+ 背景色 (1,1) + 平均輝度 | 差分率 6% / MAD 6.0（背景色・輝度は厳密） | `scripts/lib/png.mjs`（依存ゼロの PNG デコーダ） |

レイアウト指紋を **画素とは別に** 持つ理由:

- 画素は AA の差で必ずずれるため、「レイアウトが崩れた」のか「AA が違う」のか切り分けられない。
- 指紋は数値の配列なので、失敗時に `box #12 が 5px ずれた` と **そのまま原因** を出せる。
- フォントが 1 つでも欠けると字幅が変わり、指紋が真っ先に壊れる（豆腐の検出にもなる）。

### 2.4 9 フレームワークは「本物のビルド」を埋め込む

Angular / Solid / Svelte / SolidStart / Next.js / Nuxt / Astro / SvelteKit / React の 9 つを
**それぞれの CLI で実際にビルド**し、静的出力を `examples/gallery/src/web/fw/<name>/` に置く。
ギャラリーは `tauri://localhost/fw/<name>/` から配信する（本物のアプリが `dist/` を配信するのと同じ形）。

- 生成は `node scripts/gen-framework-demos.mjs`（ネットワーク必要・開発時のみ）。生成物は **コミット** する
  ので CI は `npm install` をしない。
- 埋め込み表 `examples/gallery/src/fw_assets.zig` も同スクリプトが自動生成（55 ファイル・2.4 MB）。
- 9 デモは **同じ DOM・同じ CSS・同じ文言** で、違うのはフレームワーク名とバージョンだけ。
  したがって 3 OS 比較で差が出れば、それはフレームワークではなく **バックエンドの差** である。

## 3. 影響

- ギャラリーのスクショは「どの OS でも同じ画素」に近づき、差分は AA のみになった（実測値は CI のログ）。
- リポジトリに約 3 MB の静的成果物（フォント + 9 フレームワーク）が増える。`node_modules` は
  `examples/frameworks/.gitignore` で除外。
- 文言を足すとフォントの再生成が必要になる（`check-font-coverage` が落ちるので忘れない）。

## 4. 却下した代替案

| 案 | 却下理由 |
|---|---|
| システムフォント + `font-family` を一致させる | Linux runner に CJK フォントが無い以上不可能。`fonts-noto-cjk` を CI で入れる案は、Windows/macOS の字形が違うままなので比較にならない |
| 画素の完全一致（しきい値 0）を要求する | WebKit と Blink は AA 実装が違い、原理的に一致しない。開発者が無視する「常時赤いゲート」になる |
| スクリーンショットを目視だけにする | 回帰を検出できない（`M5-04` の白紙 PNG がまさにそれ） |
| フレームワーク出力を 1 枚の HTML にインライン化する | 複数チャンクの ES モジュールはインライン `<script>` から相対 import できない（実測で SvelteKit / SolidStart が壊れた） |
| 9 フレームワークを CI で毎回ビルドする | `npm install` が 1.3 GB / 数分。毎チャットのコールドスタート制約に反する |
