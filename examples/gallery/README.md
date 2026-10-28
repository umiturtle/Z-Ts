# `examples/gallery` — スクリーンショット回帰ギャラリー（`M5-04` / `M5-05`）

1 つの実行ファイルが **17 パターンのウィンドウを順に作り、それぞれを PNG に落として
`manifest.json` を書く** 検証用ギャラリーです（8 つの手書きパターン + 9 フレームワーク）。CI（Linux / macOS / Windows）がこれを実行し、
`scripts/verify-screenshots.mjs` が画素を機械検証したうえで artifact に保存します。
設計判断は [`../../docs/decisions/0009-screenshot-capture-and-ci-gallery.md`](../../docs/decisions/0009-screenshot-capture-and-ci-gallery.md)。

## 使い方

```bash
cd examples/gallery
../../zigw build test --summary all      # 3 本の単体テスト
../../zigw build screenshots             # zig-out/screenshots/ に 17 枚 + manifest.json
../../zigw build install
./zig-out/bin/zts_gallery --out /tmp/shots --require-native
./zig-out/bin/zts_gallery --out /tmp/shots --only js-roundtrip
cd ../.. && node scripts/verify-screenshots.mjs /tmp/shots --require-native --require-counts 17
node scripts/check-font-coverage.mjs      # 同梱フォントに無い文字（= 豆腐）を検出
```

| フラグ | 効果 |
|---|---|
| `--out <dir>` | PNG と `manifest.json` の出力先（既定 `zig-out/screenshots`） |
| `--only <name>` | 1 パターンだけ撮る（デバッグ用） |
| `--require-native` | ネイティブバックエンドが使えず `HeadlessMock` に落ちたら **exit 1**（`FAIL gallery native backend unavailable (host=mock)`） |

`DISPLAY` の無い Linux では GTK が起動できず `SKIP gallery … (DisplayUnavailable)` + exit 0 に
なります。CI は `xvfb-run` で実行し `--require-native` を付けているため、この経路は通りません。

## 17 パターン

| 名前 | 寸法 (CSS px) | テーマ | 何を検証するか |
|---|---|---|---|
| `hero-light` | 900×600 | light | 基本描画・大きな見出し |
| `dashboard-dark` | 1000×620 | dark | ダークテーマ・CSS グリッド |
| `typography-cjk` | 860×620 | light | 日本語フォントのフォールバック・行間 |
| `scroll-offset` | 720×520 | dark | ネイティブからの `scrollIntoView()`（`evalJs` 往復） |
| `js-roundtrip` | 640×420 | mixed | `fetch('/api/state')` → スキームハンドラ → DOM（中心画素 `#123456`） |
| `hidpi-ruler` | 560×400 | light | `devicePixelRatio` と 1px 罫線 |
| `wide-split` | 1000×600 | mixed | 1024 幅前後のレイアウト崩れ |
| `compact-grid` | 320×240 | dark | 最小サイズの下限 |
| `fw-react` … `fw-solidstart` | 760×520 | light | 9 フレームワークの同一画面（[`../frameworks/`](../frameworks/README.md)） |

出力名は `<host>-<name>.png`（`host` は `gtk3` / `cocoa` / `win32` / `mock`）。HTML は
`src/web/*.html` を `@embedFile` で同梱しているため、実行時にファイルを探しません。

## フォント（3 OS で画素を一致させる要）

ページは **システムフォントを使いません**。`ZTS Sans` / `ZTS Serif` / `ZTS Mono` を
`src/web/fonts/*.woff2` に同梱し、`/zts/fonts/<file>` として配信します（3 OS のブラウザが
同一ファイルを描画するので字形・字幅が一致します）。`DOCUMENT_START` で `@font-face` 4 本と
「スクロールバーを隠す」CSS を注入します。

- 再生成: `python3 scripts/build-fonts.py`（使う文字だけにサブセット化）
- カバレッジ検査: `node scripts/check-font-coverage.mjs`（収録外の文字があれば CI が落ちる）

## レイアウト指紋

`load` と `document.fonts.ready` の後、要素の矩形（最大 40 個・1px 丸め）と
`font_ok` を `{"app":"layout", …}` として投稿し、`manifest.json` の `layout` に保存します。
`scripts/compare-screenshots.mjs` が 3 OS でこれを突き合わせ、**1px を超える差があれば失敗** にします。

### 決定論的な組版のための CSS 不変条件

同じ woff2 を配っても、エンジンが送り幅を丸めると折り返しが変わる。9 デモと 8 ページは次を守る:

- `line-height` は**整数 px**（`1.7` のような倍率は行ごとの丸め誤差が積み上がる）
- `letter-spacing` は **px**（`em` は丸めを生む）
- 幅の制約は **px**（`ch` は `0` の送り幅依存でエンジン差が増幅される）
- `font-family` に**システムフォントを混ぜない**（`ZTSSans` / `ZTSSerif` / `ZTSMono` のみ）
- HTML/CSS/JS の**コメントも** `check-font-coverage.mjs` の対象（同梱フォントの文字集合で
  書く）。新しい漢字を含む日本語コメントを足すと CI が落ちるので、英語で書くか
  `python3 scripts/build-fonts.py` でサブセットを作り直す
- ギャラリーは `parity_script` で `text-rendering: geometricPrecision` を全要素に強制する
  （これが無いと WebKitGTK が送り幅を整数に丸め、44 文字で 5px ずれる）

## カスタムスキームは `tauri://`（重要）

ページは `tauri://localhost/<pattern>` から配信されます。**WebView2 はカスタムスキームを
解釈できない** ため `windows.zig` が `http://tauri.localhost/<pattern>` に写像します。
`gallery://` のような独自名にすると Windows だけ真っ白になります（`M5-04` の CI で実測）。
ページ側は相対 URL（`fetch('/api/state')`）を使うため、3 OS で同じ HTML が動きます。

## 準備完了の待ち方

`DOCUMENT_START` の init script が `load` 時に
`{"ready":true,"w":…,"h":…,"dpr":…}` を `__ztsPostMessage` で送ります。ギャラリーは
最大 20 秒・10ms 刻みの `step(.poll)` でこれを待ち、申告された **実ビューポート**で撮影します
（macOS runner の画面は 1024×674 しかなく、要求サイズはクランプされるため）。
`HeadlessMock` は JS を実行しないので待機をスキップします。

## 出力

- `<host>-<name>.png` — Web コンテンツの CSS 画素をそのまま PNG にしたもの（ウィンドウ装飾なし）
- `manifest.json` — `{host, os, generated_by, patterns:[{name, file, theme, css_width, css_height,
  width, height, bytes, messages, sha256, expect_center_rgb?, layout, font_ok}]}`
  （`layout` はページが投稿した JSON を文字列のまま保存したもの）

`index.html`（コンタクトシート）は検証スクリプトが生成します。
