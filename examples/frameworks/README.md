# `examples/frameworks` — 9 フレームワーク同一画面デモ（`M5-05`）

Angular / Solid / Svelte / SolidStart / Next.js / Nuxt / Astro / SvelteKit / React の 9 つで
**まったく同じ 1 画面**（760×520 のダッシュボード風カウンター）を作り、それぞれの静的出力を
スクリーンショット・ギャラリーで撮って **3 OS で相互比較** するためのサンプル集です。
仕組み全体は [`../../docs/architecture/screenshot-parity.md`](../../docs/architecture/screenshot-parity.md)。

```
examples/frameworks/<name>/          ソース（ビルドすると dist/ が出る。node_modules はコミットしない）
examples/gallery/src/web/fw/<name>/  公開用の静的出力（ギャラリーが tauri://localhost/fw/<name>/ で配信）
examples/gallery/src/fw_assets.zig   上記を @embedFile する表（自動生成）
```

## 再生成

```bash
# 依存の導入とビルドはこのスクリプトだけ（ネットワークが必要）
node scripts/gen-framework-demos.mjs            # 9 つ全部
node scripts/gen-framework-demos.mjs react      # 1 つだけ（他はそのまま残る）
```

生成物は **コミットする** ので、CI は `npm install` をしません（毎チャットのコールドスタート対策）。

## 何を確かめるデモか

- 9 つとも **同じ DOM・同じ CSS・同じ文言**。違うのはフレームワーク名とバージョンだけ。
- フォントは同梱の `ZTS Sans` / `ZTS Mono` のみ（`/zts/fonts/*.woff2` をギャラリーが配信）。
  システムフォントを 1 つも使わないので、Linux でも豆腐にならず、3 OS で字形が一致する。
- マウント後に `{"app":"ready"}` を `__ztsPostMessage` で送る。ギャラリーはこれを待ってから撮る
  （CSR / hydration の完了を撮り逃さないため）。

## 各フレームワークのビルド方法と注意点

| ディレクトリ | バージョン | ビルド | メモ |
|---|---|---|---|
| `react/` | 19.3 | `vite build` | `class` → `className` の変換だけスクリプト側で行う |
| `solid/` | 1.9 | `vite build` | — |
| `svelte/` | 5.57 | `vite build` | `mount()` API |
| `angular/` | 22.2 | `ng build` | builder は `@angular/build`。`index.html` に `<script>` を書かない（builder が注入） |
| `next/` | 16.4 | `next build` | `output: 'export'`。TS は `types/zts-globals.d.ts` が必要 |
| `nuxt/` | 4.6 | `nuxt generate` | `nitro.preset: 'static'`。`/_payload.json` はカスタムスキームで 404 になるが SSR 済み HTML で描画される |
| `astro/` | 6.4 | `astro build` | 7.x は Node ≥22.23.4 を要求するため 6.4 系を使用 |
| `sveltekit/` | 3.1 | `vite build` | **`svelte.config.js` は廃止**。adapter は `sveltekit({ adapter })` で渡す |
| `solidstart/` | 2.1 | `vite build` | v2 は Vite プラグイン。SPA モード（`ssr:false`）で `index.html` を生成して配信 |

## ハマりどころ（実測）

1. **インライン化は不可**: 複数チャンクの ES モジュールは `<script type="module">` にインライン化すると
   `import "./chunk.js"` が解決できず真っ白になる（SvelteKit / SolidStart で発生）。→ ディレクトリを
   そのまま埋め込んでスキームで配信する方式にした。
2. **`window.__ztsPostMessage` の型**: TypeScript プロジェクトは `types/zts-globals.d.ts` で
   `declare global { interface Window { __ztsPostMessage?: … } }` が必要（Next / Angular / SolidStart のみ）。
3. **SolidStart の静的生成**: v2 に `preset: 'static'` は無い。SSR サーバを 1 回だけ叩いて
   HTML を得る方法と、SPA モードで `index.html` を自前生成する方法があり、本リポジトリは後者。
4. **Nuxt の payload**: 静的生成物は `/_payload.json` を fetch する。カスタムスキームでは 404 だが
   SSR 済み DOM はそのまま表示される（コンソール警告のみ）。
