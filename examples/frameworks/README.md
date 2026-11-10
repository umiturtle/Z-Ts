# `examples/frameworks` — 9 フレームワーク同一画面デモ

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


## チュートリアル（好きなライブラリで進む）

9 つの example には、それぞれ **同じカウンターチュートリアルの分岐ページ** があります。
Zig 側は共通で、フロントエンドの書き方だけが変わります。素の JS 版が
[カウンターを作る](../../docs/learn/ja/tutorials/counter.md)、全体の入口が
[好きなライブラリを選ぶ](../../docs/learn/ja/tutorials/frameworks.md) です。

| ライブラリ | 実物 | チュートリアル | 公開デモ |
|---|---|---|---|
| React | [`react/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/react) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-react.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/react/index.html) |
| Solid | [`solid/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/solid) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-solid.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/solid/index.html) |
| Svelte | [`svelte/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/svelte) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-svelte.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/svelte/index.html) |
| Angular | [`angular/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/angular) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-angular.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/angular/index.html) |
| Next.js | [`next/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/next) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-next.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/next/index.html) |
| Nuxt | [`nuxt/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/nuxt) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-nuxt.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/nuxt/index.html) |
| Astro | [`astro/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/astro) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-astro.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/astro/index.html) |
| SvelteKit | [`sveltekit/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/sveltekit) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-sveltekit.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/sveltekit/index.html) |
| SolidStart | [`solidstart/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/solidstart) | [カウンターを作る](../../docs/learn/ja/tutorials/counter-solidstart.md) | [公開デモ](https://umiturtle.github.io/Z-Ts/examples/frameworks/solidstart/index.html) |

## 公開デモへのリンク

`zig build docs` が書き出す Pages では、各フレームワークの静的出力がそのまま公開されます
（[デモ一覧](https://umiturtle.github.io/Z-Ts/examples/frameworks/index.html)）。
サイトのベース URL はリポジトリ名が変わったら 1 箇所まとめて差し替えてください。

| フレームワーク | デモ | フレームワーク | デモ |
|---|---|---|---|
| Angular | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/angular/index.html) | Astro | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/astro/index.html) |
| Next.js | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/next/index.html) | Nuxt | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/nuxt/index.html) |
| React | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/react/index.html) | SolidJS | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/solid/index.html) |
| SolidStart | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/solidstart/index.html) | Svelte | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/svelte/index.html) |
| SvelteKit | [開く](https://umiturtle.github.io/Z-Ts/examples/frameworks/sveltekit/index.html) | — | — |

スクリーンショット回帰そのものは
[`examples/gallery/README.md`](../gallery/README.md) と
[`docs/architecture/screenshot-parity.md`](../../docs/architecture/screenshot-parity.md) を参照してください。

## 何を確かめるデモか

- 9 つとも **同じ DOM・同じ CSS・同じ文言**。違うのはフレームワーク名とバージョンだけ。
- フォントは同梱の `ZTS Sans` / `ZTS Mono` のみ（`/zts/fonts/*.woff2` をギャラリーが配信）。
  システムフォントを 1 つも使わないので、Linux でも豆腐にならず、3 OS で字形が一致する。
- マウント後に `{"app":"ready"}` を `__ztsPostMessage` で送る。ギャラリーはこれを待ってから撮る
  （CSR / hydration の完了を撮り逃さないため）。9 つとも **Zig の probe が解決してから** ready を
  送るので、`ZIG ONLINE` の出ていない画面を撮ってしまうことがない。

## Zig が動いていないと成立しないパネル

カウンター本体はフレームワークごとの流儀を見るためのローカル状態ですが、その下の `.zigbar` は
**Zig が無いと絶対に埋まりません**。これで「静的 HTML と見た目が同じで裏の Zig が判別できない」
状態を解消しています。

| 見た目 | 裏側 |
|---|---|
| 赤い `ZIG OFFLINE`・`＋` `−` 無効 | 公開デモ / `zts dev` のブラウザ。`window.__ZTS_ZIG__` も `invoke` も無い |
| 緑の `ZIG ONLINE`・16 桁の seal・`＋` `−` 有効 | `ipc://` 越しに `zig_probe` / `zig_inc` / `zig_dec` へ Zig が応答している |

seal は **Zig バイナリだけが持つ秘密**と Zig のカウンタから作る SHA-256 の先頭 8 バイトです。
静的出力には秘密も計算式も入っていないため、JavaScript だけでは偽造できません。`＋` `−` は
Zig 側のカウンタを増減し、押すたびに seal が変わります。時刻・乱数は一切使わないので、
3 OS の初期画面は同一バイト列・同一画素です。

ホスト側の実物は [`examples/gallery/src/main.zig`](../gallery/src/main.zig)（`ipc` スキームと
3 コマンド）、[`examples/gallery/src/web/zig-bridge.js`](../gallery/src/web/zig-bridge.js)
（`DOCUMENT_START` で注入するブリッジ）です。無改造の `js_bootstrap` が作る
`window.__TAURI_INTERNALS__.invoke` をそのまま使います。CI は manifest の `zig_online` が
9 件すべて `true` でないと赤くなります（`scripts/verify-screenshots.mjs --require-zig`）。

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
2. **`window` の型**: 9 つすべてに `types/zts-globals.d.ts` を生成する。JS だけのプロジェクトでは
   無視され、TS プロジェクトでは `__ztsPostMessage` と `__ZTS_ZIG__` の宣言として効く
   （以前は Next / Angular / SolidStart だけに配っていた）。
3. **SolidStart の静的生成**: v2 に `preset: 'static'` は無い。SSR サーバを 1 回だけ叩いて
   HTML を得る方法と、SPA モードで `index.html` を自前生成する方法があり、本リポジトリは後者。
4. **Nuxt の payload**: 静的生成物は `/_payload.json` を fetch する。カスタムスキームでは 404 だが
   SSR 済み DOM はそのまま表示される（コンソール警告のみ）。
