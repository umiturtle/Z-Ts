# API リファレンスの読み方

このライブラリの API リファレンスは、**ソースの `///` から生成**しています。
`zig doc` と同じ発想で、宣言・シグネチャ・コメント・ソース位置が 1 ページに並びます。
このガイドは「ページのどこを見れば何が分かるか」だけを説明します（網羅的な使い方指南は
[`getting-started.md`](getting-started.md) / [`using-rpc.md`](using-rpc.md) にあります）。

- 公開サイト: <https://umiturtle.github.io/Z-Ts/docs/api/index.html>
- 手元で生成: `./zigw build docs` → `zig-out/docs/docs/api/index.html`

## 1. 3 種類のページ

| ページ | 例 | 載っているもの |
|---|---|---|
| 全体 | `docs/api/index.html` | パッケージ一覧・文書化率・**A–Z 索引**（全公開宣言への直リンク） |
| パッケージ | `docs/api/zts_tauri/index.html` | そのパッケージのモジュール一覧（宣言数つき）と合計 |
| モジュール | `docs/api/zts_tauri/window.html` | `//!` のモジュール説明 + **読み込み 1 行** + **宣言ごとの節** |

モジュールページの冒頭には、そのまま自分のファイルに貼れる 1 行があります。

```zig
const window = @import("zts_tauri").window;
```

`@import("zts_tauri").fs.scope` のように、パッケージのルートが再エクスポートしている深さまで
自動で解決します（`pub const fs = @import("fs/mod.zig")` を辿る）。再エクスポートされていない
内部ファイルには、この行は出ません（たどり着く手段が無いものを、あるかのように書かないため）。

モジュールページの 1 宣言はこの形です。

```text
[種類] pub const WireSize = union(enum)        L43   ← シグネチャとソース行
      説明文（/// をそのまま描画。`code` とリンクも効く）
      メンバ 4 件 · うち 0 件はドキュメントコメント未記述
        ├ field  Logical: RawDims                 L45
        ├ fn     toLogical(self, scale)           L51
        └ …
```

- **`L43`** は GitHub の該当行へのリンクです。「この説明は本当か？」を 1 クリックで確かめられます。
- **`///` が無い宣言**は「ドキュメントコメント未記述 — シグネチャは上記のとおりです」と出ます。
  隠さずに出す方針なので、未文書が残っている場所はページ上でそのまま分かります。
- **型のメンバ**（構造体フィールド・enum ケース・メソッド）は 1 段下のインデントで並びます。
  ページ内リンクは `#WireSize.toLogical` の形です。

## 2. 文書化率の読み方

パッケージページには次の行があります。

```text
公開モジュール 10 件 · 公開宣言 455 件 · ドキュメントコメント 455 件（100%）
宣言とは別に、型メンバと enum ケースが 1,477 件あります（うちドキュメントコメントあり 1,476 件、99%）。
```

**宣言と型メンバは別々に数えます。** 上の行が `pub const` / `pub fn` の数、下の行が
その中のフィールド・enum ケース・メソッドの数です（`WindowConfig` は宣言 1 件 + メンバ 24 件）。
**再エクスポート（別名）は数えません**（ドキュメントは定義元にあります）。ネイティブ FFI のバインディングと契約テスト
（`*_test.zig`、`gtk_bindings.zig`、`win32.zig` など）は**内部モジュール**として分母から外し、
パッケージページの折り畳み（「内部モジュール」）にだけ載せています。

## 3. JS の API から Zig の実装を引く

`@tauri-apps/api` の関数は、ほぼ 1 対 1 で `plugin:<name>|<command>` に対応します。
コマンドの実装は各モジュールの `Commands` 型にあります。

| JS | ワイヤ | Zig |
|---|---|---|
| `getCurrentWindow().setTitle(t)` | `plugin:window|set_title` | `zts_tauri/window.zig` の `Commands.set_title` |
| `invoke("greet", { name })` | `greet` | 自分で `Schema` に登録したコマンド |
| `readText()`（clipboard） | `plugin:clipboard-manager|read_text` | `zts_tauri/clipboard/mod.zig` の `Commands.read_text` |

探し方は 3 通りです。

1. サイトの検索（`/` キー）で JS 側の名前（`set_title` / `setTitle`）を引く
2. パッケージページの A–Z 索引から型名で入る
3. `zig-out/docs/docs/api/index.html` を `grep` する（生成物はただの HTML）

`Commands` の関数名は **snake_case** です。ワイヤ名は `prefix ++ fn_name` と
`prefix ++ camelCase(fn_name)` の両方を受け付けるので、`set_title` でも `setTitle` でも同じ
ハンドラに届きます。

## 4. 型がワイヤでどう表れるか

`zts_rpc` のラッパー型は、`///` の代わりに**型マーカー**で振る舞いが決まります。
API ページでは `zts_rpc_type` の値として見えます。

| Zig の型 | JSON / TS | 使うとき |
|---|---|---|
| `rpc.Bytes` | Base64 文字列 ⇔ `Uint8Array` | バイナリを運ぶ |
| `rpc.RawJson` | そのまま ⇔ `unknown` | 中身を解釈しないペイロード |
| `rpc.SafeInt` | 数値（±2^53-1 を検査） | 64bit を安全に渡す |
| `rpc.BigInt(T)` | 10 進文字列 ⇔ `bigint` | 64/128bit を厳密に |
| `rpc.Patch(T)` | 省略 / `null` / 値 | 部分更新 |
| `rpc.TaggedUnion(U, cfg)` | `kind` で分岐 | `union(enum)` の形を選ぶ |
| `rpc.OsPath` | `{ raw, display }` | 非 UTF-8 のパス |

## 5. 内部資料との境目

API ページに「内部モジュール」の折り畳みや、ページ上部の「内部モジュール」バナーが出てきたら、
そこは**利用者のための面ではありません**。読み飛ばして構いません（検索にも出ません）。
「なぜこうなっているか」を知りたいときだけ、サイドバー最後の
[内部資料](https://umiturtle.github.io/Z-Ts/docs/internals/index.html) から入れます。

層の分け方は [`README.md`](README.md) にまとめてあります。
