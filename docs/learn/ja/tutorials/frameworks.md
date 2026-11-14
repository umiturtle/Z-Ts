# 好きなライブラリでチュートリアルを選ぶ

> **対象読者**: いつものフロントエンドのまま ziggurats を試したい人。
> **所要時間**: 選ぶだけなら 1 分。counter は 15 分、Todo / 画面は各 20 分。

チュートリアル 3 本は **Zig 側が共通**です。フロントエンドは実物の example が
コミットされている 9 ライブラリ＋素の JS から、**好きなものを 1 つ選んで**進められます。
どの分岐を選んでも `increment` の Zig コード、`zts dev`、`zts build` は同じです。

<!-- framework-picker -->

## どう分岐しているか

| 元のチュートリアル | 共通なもの | ライブラリごとに変わるもの |
|---|---|---|
| [カウンターを作る](counter.md) | `increment` コマンド・`zts dev`・`zts build` | 状態プリミティブとボタンの書き方（9 本） |
| [Todo リストを作る](todo.md) | 3 つの Zig コマンド・`error{}`・テスト | 一覧の状態・キー付き繰り返し・再読込（9 本） |
| [画面を作る](ui.md) | 状態の境界・CSP | 3 状態の条件分岐・エラー表示（9 本） |

> [!NOTE]
> `learn_path.zig` の 5 ステップ・所要時間は変えていません。分岐は**追加の章ではなく代替の道**で、
> 選んだ 1 本だけ読めば、その 1 本の所要時間で終わります。

## 実物の example 一覧

| 実物 | バージョン | ビルド | 出力先 | カウンター | Todo | 画面 | 公開デモ |
|---|---|---|---|---|---|---|---|
| [`react/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/react) | 19.3 | `vite build` | `dist` | [counter](counter-react.md) | [todo](todo-react.md) | [ui](ui-react.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/react/index.html) |
| [`solid/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/solid) | 1.9 | `vite build` | `dist` | [counter](counter-solid.md) | [todo](todo-solid.md) | [ui](ui-solid.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/solid/index.html) |
| [`svelte/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/svelte) | 5.57 | `vite build` | `dist` | [counter](counter-svelte.md) | [todo](todo-svelte.md) | [ui](ui-svelte.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/svelte/index.html) |
| [`angular/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/angular) | 22.2 | `ng build` | `dist/browser` | [counter](counter-angular.md) | [todo](todo-angular.md) | [ui](ui-angular.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/angular/index.html) |
| [`next/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/next) | 16.4 | `next build` | `out` | [counter](counter-next.md) | [todo](todo-next.md) | [ui](ui-next.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/next/index.html) |
| [`nuxt/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/nuxt) | 4.6 | `nuxt generate` | `.output/public` | [counter](counter-nuxt.md) | [todo](todo-nuxt.md) | [ui](ui-nuxt.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/nuxt/index.html) |
| [`astro/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/astro) | 6.4 | `astro build` | `dist` | [counter](counter-astro.md) | [todo](todo-astro.md) | [ui](ui-astro.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/astro/index.html) |
| [`sveltekit/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/sveltekit) | 3.1 | `vite build` | `build` | [counter](counter-sveltekit.md) | [todo](todo-sveltekit.md) | [ui](ui-sveltekit.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/sveltekit/index.html) |
| [`solidstart/`](https://github.com/umiturtle/ZigguraTs/tree/main/examples/frameworks/solidstart) | 2.1 | `vite build` | `dist/client` | [counter](counter-solidstart.md) | [todo](todo-solidstart.md) | [ui](ui-solidstart.md) | [開く](https://umiturtle.github.io/ZigguraTs/examples/frameworks/solidstart/index.html) |

リポジトリの [`examples/frameworks/README.md`](../../../../examples/frameworks/README.md) に
ビルド方法と 3 OS のスクリーンショット比較の仕組みをまとめてあります。

## 裏で Zig が動いているかを見分ける

9 つの公開デモは静的 HTML なので、どれも下部のパネルが赤い **`ZIG OFFLINE`** になり、
`＋` `−` は押せません。これで「ブラウザだけでは ziggurats は動いていない」ことが一目で分かります。
ネイティブのギャラリー（`examples/gallery`）で開くと同じパネルが緑の **`ZIG ONLINE`** になり、
Zig だけが作れる 16 桁の seal と、Zig が保持するカウンタが表示されます。
`zig_probe` / `zig_inc` / `zig_dec` は `ipc://` 越しに Zig が答えるコマンドで、
静的ファイルには実装がありません。各分岐ページの付録に配線の実物へのリンクがあります。

## 次に読むもの

- まず 1 本通す → [カウンターを作る](counter.md)（素の JS）または上の表から 1 つ
- 分岐の元に戻る → [チュートリアルの入口](index.md)
- 概念から知りたい → [概念の索引](../concepts/index.md)
- コマンドの設計 → [実用パターン](../patterns/index.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
