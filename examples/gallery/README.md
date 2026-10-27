# `examples/gallery` — スクリーンショット回帰ギャラリー（`M5-04`）

1 つの実行ファイルが **8 パターンのウィンドウを順に作り、それぞれを PNG に落として
`manifest.json` を書く** 検証用ギャラリーです。CI（Linux / macOS / Windows）がこれを実行し、
`scripts/verify-screenshots.mjs` が画素を機械検証したうえで artifact に保存します。
設計判断は [`../../docs/decisions/0009-screenshot-capture-and-ci-gallery.md`](../../docs/decisions/0009-screenshot-capture-and-ci-gallery.md)。

## 使い方

```bash
cd examples/gallery
../../zigw build test --summary all      # 3 本の単体テスト
../../zigw build screenshots             # zig-out/screenshots/ に 8 枚 + manifest.json
../../zigw build install
./zig-out/bin/zts_gallery --out /tmp/shots --require-native
./zig-out/bin/zts_gallery --out /tmp/shots --only js-roundtrip
cd ../.. && node scripts/verify-screenshots.mjs /tmp/shots --require-native --require-counts 8
```

| フラグ | 効果 |
|---|---|
| `--out <dir>` | PNG と `manifest.json` の出力先（既定 `zig-out/screenshots`） |
| `--only <name>` | 1 パターンだけ撮る（デバッグ用） |
| `--require-native` | ネイティブバックエンドが使えず `HeadlessMock` に落ちたら **exit 1**（`FAIL gallery native backend unavailable (host=mock)`） |

`DISPLAY` の無い Linux では GTK が起動できず `SKIP gallery … (DisplayUnavailable)` + exit 0 に
なります。CI は `xvfb-run` で実行し `--require-native` を付けているため、この経路は通りません。

## 8 パターン

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

出力名は `<host>-<name>.png`（`host` は `gtk3` / `cocoa` / `win32` / `mock`）。HTML は
`src/web/*.html` を `@embedFile` で同梱しているため、実行時にファイルを探しません。

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
  width, height, bytes, messages, sha256, expect_center_rgb?}]}`

`index.html`（コンタクトシート）は検証スクリプトが生成します。
