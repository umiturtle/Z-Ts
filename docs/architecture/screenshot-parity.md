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
{"app":"layout","boxes":[[x,y,w,h], …],"doc_w":900,"doc_h":600,"font_ok":true}
```

- `boxes` は `body / .shell / .head / .card / .counter / .value / .features / h1… / button …` の
  最大 40 要素の `getBoundingClientRect()` を **1px に丸めた** もの。
- `font_ok` は `document.fonts.check('16px "ZTS Sans"')` と `'ZTS Mono'`。
- ギャラリーはこれを `manifest.json` の `layout`（JSON 文字列）に保存し、`ci-parity` が突き合わせる。

比較ルール（`scripts/compare-screenshots.mjs`）:

| 項目 | ルール |
|---|---|
| パターン集合 | 3 OS で完全一致（欠けは即失敗） |
| 画素寸法 | 一致必須（`css_width × scale`） |
| ボックス | 各成分の差 ≤ `--layout-tolerance`（既定 1px） |
| ドキュメントサイズ | 差 ≤ 1px |
| `font_ok` | すべて `true` |
| 背景色 (1,1) | **完全一致** |
| 平均輝度 | 差 ≤ 2.0 |
| 画素差分率 | ≤ `--max-diff`（既定 0.06） |
| 平均絶対差 (MAD) | ≤ `--max-mad`（既定 6.0） |

失敗例:

```
FAIL parity fw-react: layout differs by 5px at box #3 (tolerance 1px)
  gtk3: [24,24,712,80]
  cocoa: [24,29,712,80]
```

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
| `fw-solidstart` | SolidStart 2.1 | `vite build`（SPA）+ 生成した `index.html` | `dist/client` |

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
