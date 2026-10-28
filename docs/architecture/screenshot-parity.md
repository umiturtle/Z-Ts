# スクリーンショット・パリティ（3 OS で同じ表示を保証する）

`M5-04` で「3 OS の実描画を PNG に残す」仕組みができ、`M5-05` で
**「同じ解像度なら同じ表示」** を機械的に保証できるようにした。設計判断は
[`../decisions/0010-cross-os-pixel-parity.md`](../decisions/0010-cross-os-pixel-parity.md)、
取得 API は [`zts-webview-backends.md`](zts-webview-backends.md) §4 を参照。

---

## 1. パイプライン全体

```
examples/gallery (Zig)                         scripts/                      .github/workflows/ci.yml
──────────────────────                         ─────────                     ────────────────────────
17 パターンを順に描画                            verify-screenshots.mjs  ──►   ci-linux   ─┐
  ├ 8 手書きパターン（light/dark/CJK/…）          寸法・SHA-256・非空白・       ci-macos   ─┼─► ci-parity
  └ 9 フレームワーク（fw/<name>/）                テーマ輝度・中心画素・       ci-windows ─┘   3 artifact を比較
      ↓                                          font_ok・layout の存在                        ↓
  PNG + manifest.json（layout 指紋つき）          check-font-coverage.mjs          OK parity …（マーカー必須）
                                                 compare-screenshots.mjs
```

- 各 OS ジョブは `--require-native` 付きでギャラリーを実行し、`mock` フォールバックを **失敗** にする。
- `manifest.json` には `host` / `os` / パターンごとの寸法・`sha256`・`messages` に加えて
  `layout`（ページが投稿したレイアウト指紋）と `font_ok` が入る。
- `ci-parity` は 3 つの artifact を `artifacts/screenshots-<os>/` に展開し、
  ① それぞれを `verify-screenshots.mjs` で再検証 ② `compare-screenshots.mjs` で相互比較する。

---

## 2. フォント（豆腐の根絶）

| ファイル | 由来 | 用途 |
|---|---|---|
| `zts-sans-400.woff2` / `zts-sans-700.woff2` | Noto Sans JP（OFL） | 本文・見出し |
| `zts-serif-400.woff2` | Noto Serif JP（OFL） | 明朝体のデモ（`typography-cjk`） |
| `zts-mono-400.woff2` | JetBrains Mono（OFL） | コード・数値 |

- 置き場所: `examples/gallery/src/web/fonts/`、配信: `/zts/fonts/<file>`（`src/main.zig` の `font_assets`）。
- 生成: `python3 scripts/build-fonts.py`（`pip install fonttools brotli` が必要。CI では走らせない）。
- 収録文字: `examples/gallery/src/web/fonts/coverage.txt`（同スクリプトが出力）。
- ゲート: `node scripts/check-font-coverage.mjs` — デモ HTML に収録外の文字があれば
  `FAIL font-coverage <file>: U+XXXX("字"×n)` で落ちる。

**新しい文言を足したら**: `python3 scripts/build-fonts.py` → フォントと `coverage.txt` が更新される →
コミット。CI は生成物をそのまま使う。

---

## 3. レイアウト指紋

`DOCUMENT_START` で注入される `ready_script` が、`load` → `document.fonts.ready` → 2 フレーム後に
以下を `__ztsPostMessage` へ送る。

```json
{"app":"layout","boxes":[[x,y,w,h], …],"names":["body","p.lead", …],
 "chars":[0,132, …],"lines":[1,2, …],"doc_w":900,"doc_h":600,"font_ok":true,
 "probe":{…}}
```

- `boxes` は `body / .shell / .head / .card / .counter / .value / .features / h1… / button …` の
  最大 40 要素の `getBoundingClientRect()` を **1px に丸めた** もの。
- `font_ok` は「同梱 woff2 が実際に描かれているか」。**送り幅の厳密比較はゲートにしない** —
  WebKitGTK は `getBoundingClientRect()` も canvas `measureText()` も整数 px に丸めて返すため
  （8.88 → 9、9.44 → 9）、400 と 700 が区別できず、丸めだけで落ちてしまう。代わりに次を要求する:
  1. `window.__ztsParity` が `api` か `css` を立てている（ブートストラップが動いた）
  2. `document.fonts` に 4 面が `loaded` で載っている
  3. **同梱書体 vs 総称ファミリ**の canvas 画素比較が 4 本とも非ゼロ（フォールバックしていると
     両者が同一書体になり 0 になる。実際「フォント未適用」のときは `sans:0 sansCjk:0 …` だった）
  4. 構造の健全性: `ZTSMono` が等幅（`i` と `0` が同じ幅）、CJK が 1 文字 ≈ 16px（豆腐・0 幅でない）`document.fonts.check()` は WebKit では未適用でも `true` を
  返すので判定には使わない（診断値としてのみ送出）。ファミリ名に空白を入れないのは、minify で
  `"ZTS Sans"` の引用符が落ちて無効名になるのを避けるため。
- `probe` は切り分け用。DOM で測った送り幅（`sans0` / `sans0b` / `serif0` / `mono0` / `cjk` /
  `generic0` / `ch44` / `size`）と、canvas の画素比較（`paint`）、`document.fonts` の各面の状態
  （`faces`）、`check_ok` / `face_ok` / `paint_ok` を持つ。OS 間で箱がずれたとき、
  「フォントが当たっていない」のか「同じフォントでも送り幅が違う」のかを 1 回で判別できる。
  `verify-screenshots.mjs` は全ネイティブ撮影についてこの行をログに出す。
- フォントの**唯一の供給元**は `parity_script`（`DOCUMENT_START` に `init_scripts` の先頭で注入）。
  ページ側は `font-family: ZTSSans` と書くだけで `@font-face` を持たないため、この注入が抜けると
  全ページが「その OS のシステムフォント」で描かれ、Linux だけ豆腐になる。`FontFace` API を優先し、
  document-start で `<head>` が無い場合に備えて `MutationObserver` で挿入をやり直す。
  回帰防止として `main.zig` のユニットテストが「`init_scripts` が 2 本」「4 本の woff2 すべてが
  スクリプト内の URL と一致」を検査する。
- ページは `fetch('/zts/fonts/zts-sans-400.woff2')` も試し、`{"app":"fontfetch"}` を投稿する。
  `verify-screenshots.mjs` はこれが失敗した時点で落ちる（カスタムスキーム経由の取得失敗は
  レイアウトがフォールバック書体のまま進むので、`font_ok` だけでは見逃すことがある）。
- ギャラリーはこれを `manifest.json` の `layout`（JSON 文字列）に保存し、`ci-parity` が突き合わせる。

比較ルール（`scripts/compare-screenshots.mjs`）。フラグはディレクトリの前後どちらに置いてもよい:

| 項目 | ルール |
|---|---|
| パターン集合 | 3 OS で完全一致（欠けは即失敗） |
| 画素寸法 | 一致必須（`css_width × scale`） |
| ボックス | 各成分の差 ≤ `--layout-tolerance`（既定 1px）＋ 0.5px × 文字数（上限 8px） |
| 行数（折返し） | **完全一致**（`lines` = 各要素の line box 数） |
| ドキュメントサイズ | 差 ≤ 1px |
| `font_ok` | すべて `true`（同梱フォントが実際に描かれている） |
| 背景色 (1,1) | 各成分の差 ≤ `--bg-tolerance`（既定 4/255） |
| 平均輝度 | 差 ≤ 3.0（フォント欠落や背景色の誤りはこれを大きく超える） |
| 画素差分率 | ≤ `--max-diff`（既定 0.12） |
| 平均絶対差 (MAD) | ≤ `--max-mad`（既定 8.0、= 3% の明度差） |

**なぜ画素が 12% まで許されるのか**: 3 OS は別々のグリフ・ラスタライザ（FreeType / CoreText /
DirectWrite）を使うので、同じ woff2・同じ位置でも**アンチエイリアスの画素値は一致しない**。
文字密度の高いページ（`typography-cjk` / `hidpi-ruler`）では文字の輪郭が画像の大半を占めるため、
差分率が 10% 前後になる。閾値は「ラスタライザ差では超えず、別フォント・別背景・位置ずれ・
折返し変化では必ず超える」水準に置いてある（平均輝度 ≤3.0、MAD ≤6、背景色は概ね一致、
レイアウトとは行数は完全一致）。実際、フォント未適用だった頃は **画素比較の canvas 比率が
0** になり、`font_ok` ゲートで先に落ちる。

**なぜ「完全一致」ではなく「1px + 文字数依存」なのか**: WebKitGTK は cairo/FreeType のメトリクス
ヒンティングを有効にしており、**グリフ送り幅を整数 px に丸める**（8.88px の `0` が 9px）。
CoreText（macOS）と DirectWrite（Windows）は小数のまま。この差は 1 文字あたり最大 0.5px なので、
文字数ぶんの余裕を持たせる。代わりに **行数は完全一致**を要求するので、折返し・行送りの
リグレッションは 1px の話に埋もれずに検出される。フォントヒンティングを fontconfig で切っても
WebKitGTK は webfont のヒントスタイルを自前で上書きするため効かない（`ci.yml` で試行済み）。

失敗例:

```
FAIL parity fw-react: layout differs by 5px at box #3 (tolerance 1px)
  gtk3: [24,24,712,80]
  cocoa: [24,29,712,80]
```


### 決定論的な組版のための CSS 不変条件

同じ woff2 を配っても、エンジンが**グリフ送り幅を丸める**と折り返しが変わる。ギャラリーは
`parity_script` で次の 2 つを全ページに強制する（`!important`）:

| ルール | 理由 |
|---|---|
| `*,*::before,*::after { text-rendering: geometricPrecision }` | WebKitGTK は既定で FreeType のヒンティングを使い、送り幅を整数 px に丸める（8.88px の `0` が 9px）。44 文字で 5px ずれ、折り返しまで変わる。この指定でサブピクセル送りになる。 |
| `body { line-height: 24px }` | `line-height:1.7`（= 27.2px）は行ごとの丸め方が実装依存で、行数ぶん誤差が積み上がる。 |

デモ側の CSS でも次を守る（`examples/gallery/README.md` §レイアウト指紋に追記）:

- `line-height` は**整数 px**（小数の倍率は使わない）
- `letter-spacing` は **px**（`em` は丸め誤差を生む）
- 幅の制約は **px**（`ch` は `0` の送り幅依存で、エンジン差が増幅される）
- ヘッダのように**同じ文字列を OS がわずかに違う幅で測る**ブロックは、`width` を固定して
  `overflow:hidden` を付ける（幅が固定なので箱は全 OS 一致、はみ出しは `scrollWidth` を
  押し広げない）。文字そのものは画素比較で検証される
- `font-family` に**システムフォントを混ぜない**（`hidpi-ruler` が `-apple-system` を
  使っていて macOS/Linux で別書体になっていた）

---

## 4. 9 フレームワーク・デモ

| パターン | フレームワーク | ビルド方法 | 出力 |
|---|---|---|---|
| `fw-react` | React 19.3 | Vite + `@vitejs/plugin-react`（CSR） | `dist/` |
| `fw-solid` | Solid 1.9 | Vite + `vite-plugin-solid`（CSR） | `dist/` |
| `fw-svelte` | Svelte 5.57 | Vite + `@sveltejs/vite-plugin-svelte`（CSR） | `dist/` |
| `fw-angular` | Angular 22.2 | `ng build`（application builder） | `dist/browser` |
| `fw-next` | Next.js 16.4 | `next build`（`output: 'export'`） | `out/` |
| `fw-nuxt` | Nuxt 4.6 | `nuxt generate`（`nitro.preset: static`） | `.output/public` |
| `fw-astro` | Astro 6.4 | `astro build` | `dist/` |
| `fw-sveltekit` | SvelteKit 3.1 | `vite build` + `adapter-static`（prerender） | `build/` |
| `fw-solidstart` | SolidStart 2.1 | `vite build`（`ssr: false`）+ 生成した `index.html` | `dist/client` |

すべて `examples/frameworks/<name>/` にソースがあり、`node scripts/gen-framework-demos.mjs [name…]` で
再生成 → `examples/gallery/src/web/fw/<name>/` と `src/fw_assets.zig` が更新される。

デモの中身は 9 つとも同じ: ヘッダ（フレームワーク名 + バージョン）、カウンタ（`−` / `＋`）、
3 つの特徴カード、フッタ（`tauri://localhost`）。**表示文字数もそろえてある** ので、
フレームワーク名の違い以外は画素が一致するはずで、差が出ればバックエンドの差だと分かる。

---

## 5. ローカルで確認できること / できないこと

| できる | できない（CI 専用） |
|---|---|
| `cd examples/gallery && ../../zigw build screenshots`（mock で 17 枚・約 18 秒） | ネイティブ描画（サンドボックスに `DISPLAY` が無い） |
| `node scripts/verify-screenshots.mjs <dir> --require-counts 17` | 3 OS 比較（`git push` して `ci-parity` を見る） |
| `node scripts/check-font-coverage.mjs` | フォントの見た目確認（artifact の `index.html` を見る） |
| `node scripts/gen-framework-demos.mjs react`（ネットワーク必要） | — |

`bash scripts/ci-logs.sh <run_id>` で `OK parity …` と各パターンの
`layout=…px pixels=…% MAD=…` 行が読める（artifact のダウンロードは外部ストレージ制限で不可）。
