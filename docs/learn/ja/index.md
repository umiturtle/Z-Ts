# Z-Ts を学ぶ

> **対象読者**: Z-Ts でアプリを作りたい人（Zig と Web の基礎があると読みやすい）。
> **所要時間**: このページ 3 分。そこから先は選んだ道で 10 分〜1 時間。

Z-Ts は **Tauri v2 のプロトコルとプラグインを Zig 0.17 で再実装したツールキット**です。
1 つのアプリコードから 3 つの成果物を作ります。

| 成果物 | 動く場所 | 何が特別か |
|---|---|---|
| デスクトップアプリ | OS の WebView（GTK / WKWebView / WebView2） | 単一バイナリ。`web/` は中に埋め込まれる |
| ブラウザ Live Preview | 開発中のブラウザ | ビルドが失敗しても直前の成功物を配信し続ける |
| 静的サイト | 任意の静的ホスティング | サーバ不要。状態は `app.wasm` が持つ |

フロントエンドは **無改変の `@tauri-apps/api` v2** です。`invoke` も `listen` も、Tauri と
同じ名前・同じ形で動きます。

---

## 4 つの入口

読む順番は自由ですが、**「概念 → チュートリアル → ガイド」**が最短です。
急いでいる人はチュートリアルだけでも動くものができます。

| 入口 | こんな人に | 中身 |
|---|---|---|
| [概念](concepts/index.md) | 設計から理解したい | 6 パッケージの役割、コマンドが届くまで、権限の考え方 |
| [チュートリアル](tutorials/counter.md) | まず動かしたい | 10 分でカウンターを完成させる（バックエンド → 画面 → ビルド） |
| [ガイド](guides/index.md) | 特定のことをしたい | コマンド、プラグイン、静的サイト、配布、移行、トラブル |
| [API リファレンス](../../api/index.html) | 名前から引きたい | 全公開宣言（`///` から自動生成） |

## 何を知っている前提か

Z-Ts は「初めてのプログラミング」向けではありません。次のどれかが欠けていると感じたら、
先にその基礎を済ませたほうが結果的に速いです。

| 前提 | どこで必要か | 足りないとき |
|---|---|---|
| Zig の基本（`comptime`、エラー集合、`defer`） | コマンドを書く、WASM に載せる | [Zig Language Reference](https://ziglang.org/documentation/master/) |
| Web の基本（HTML / CSS / `fetch` / イベント） | 画面側すべて | [MDN: Learn Web Development](https://developer.mozilla.org/en-US/docs/Learn) |
| ターミナル操作 | すべて | — |

Tauri v2 の経験は **不要** です。移行したい人だけ [移行ガイド](guides/migrate-from-tauri.md) を読んでください。

## 30 秒で全体像

```bash
zts init my-app      # 6 ファイルの雛形（build.zig, src/main.zig, web/index.html …）
cd my-app
zts dev              # http://127.0.0.1:5173 — 保存すると自動リロード
zts build            # zig-out/bin/my_app — web/ を埋め込んだ単一バイナリ
```

バックエンドは「関数を書いて、構造体にまとめて、`Schema` に渡す」だけです。

```zig
const Commands = struct {
    pub fn increment(state: *State) !i32 {
        state.count += 1;
        return state.count;
    }
};

pub const Schema = rpc.Schema(.{ .app = Commands });
```

これで JavaScript 側から `invoke("increment")` が呼べます。ルーティングテーブルも、
JSON の手書きも、TypeScript の型定義も要りません（`zig build` が生成します）。

## 学習の道順（所要時間の目安）

```text
  概念（15 分）
     6 パッケージ → コマンドの流れ → プラグイン → 権限
        │
        ├──► チュートリアル（10 分）  動くカウンターを作る
        │
        └──► ガイド（必要なとき）
               install / rpc / plugins / static-site / package / troubleshooting / migrate
                        │
                        └──► API リファレンス（名前で引く）
```

## このページの次に

- 設計から知りたい → [概念の索引](concepts/index.md)
- 手を動かしたい → [チュートリアル: カウンター](tutorials/counter.md)
- 用語で迷った → [用語集](../../glossary.md)
- エラーが出た → [エラー索引](../../reference/errors.html) / [トラブルシューティング](guides/troubleshooting.md)
