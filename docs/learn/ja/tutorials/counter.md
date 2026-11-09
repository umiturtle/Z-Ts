# チュートリアル: カウンターを作る

> **対象読者**: はじめて ziggurats に触る人。Zig の基本文法は知っている前提です。
> **所要時間**: 15 分（写経すれば動くところまで）。
> **前提**: まだ 1 度も動かしていないなら、[はじめての ziggurats](../start.md)（10 分）が先です。

`zts init` でプロジェクトを作り、**Zig の関数をボタンから呼び**、保存で自動リロードしながら
育てて、最後に単一バイナリにするまでの一本道です。**このページのコマンドは `zts` だけ**です。
ziggurats リポジトリの操作（ビルド手順や CI）は
[`docs/contributing/README.md`](../../../contributing/README.md) に分けてあります。

| 章 | やること | 終わったとき |
|---|---|---|
| [0](#0-前提) | 前提の確認 | `zts doctor` が緑 |
| [1](#1-プロジェクトを作る) | `zts init` | 6 ファイルができる |
| [2](#2-編集しながら動かす（zts-dev）) | `zts dev` | ブラウザに画面が出る |
| [3](#3-数えるコマンドを書く) | Zig に関数を書く | `invoke("increment")` が動く |
| [4](#4-単一バイナリにビルドする) | `zts build` | 単体で動く実行ファイル |
| [5](#5-つまずいたら-zts-doctor) | `zts doctor` | どこで詰まったか分かる |

---

## 0. 前提

| 項目 | 要件 |
|---|---|
| `zts` | [`install.md`](../guides/install.md) のとおり、Releases のバイナリ 1 個を `PATH` に（clone 不要） |
| Zig | 0.17 系が `PATH` か `ZTS_ZIG` に（`zts` が子プロセスとして呼びます） |
| OS | Linux（GTK3 + WebKit2GTK 4.1）/ macOS / Windows |

```bash
zts version      # zts 0.1.0
zts doctor       # all checks passed なら準備完了
```

## 1. プロジェクトを作る

```bash
zts init my-app
cd my-app
```

生成されるのは 6 ファイルです。

```text
my-app/
├── build.zig          # 共通エンベッダで web/ を埋め込む
├── build.zig.zon      # ziggurats への path 依存
├── src/main.zig       # アプリ本体（assets を列挙する最小構成）
├── web/index.html     # フロントエンド
├── .gitignore         # zig-out/ と .zig-cache/ を無視
└── README.md
```

`zts init` は生成直後に 1 回ビルドし、Zig が要求する `build.zig.zon` の
`.fingerprint` を自動で書き戻します。既存ディレクトリに書きたいときは `--force`、
パッケージ名を変えたいときは `--name my_app` を付けます。

> **雛形は「動く最小構成」です。** `zts build` すると `my_app: 1 embedded assets` のように
> 埋め込まれたアセットを列挙して終わります。ウィンドウを開くデスクトップアプリに育てるには
> [`examples/counter/README.md`](../../../../examples/counter/README.md) の
> `build.zig` と `src/main.zig` を出発点にしてください。

## 2. 編集しながら動かす（`zts dev`）

```bash
zts dev               # http://127.0.0.1:5173
```

`web/` を配信し、`web/`・`src/`・`build.zig*` を走査して、**変わった種類に応じて最小の更新**を
します（アイドル時 250 ms、連続編集時は 100 ms）。

| 変えたもの | `zts dev` のすること | 待ち時間 |
|---|---|---|
| `web/**/*.css` | ビルドせず、`<link>` を差し替える（**リロードしない**） | 0.2 秒ほど |
| `web/` のその他 | ビルドせず、ページをリロード（配信元はディスク） | 0.2 秒ほど |
| `src/` の Zig | `zig build check` で型を検査し、成功したらリロード | 0.4 秒ほど |
| 内容が変わらない保存 / 使われていない `.zig` | 何もしない | 0 |
| `build.zig` / `build.zig.zon` | 完全ビルド（`zig build`） | 0.8 秒ほど |

Zig のソースは内容ハッシュで比較し、`src/main.zig` からの `@import` を辿った依存グラフで
「そのファイルはコンパイルに影響するか」を判定します。初回ビルドは完全ビルドなので、
リンクまで確認したいときは `zts build` を使ってください。

> `zts dev` が見せているのは `web/` だけで、Zig のアプリは動いていません。`invoke` の往復まで
> 確かめるときは `zts build` して `zig-out/bin/` の実行ファイルを起動してください。

* `--browser` で起動時に既定ブラウザを開く
* `--host 0.0.0.0` でコンテナや LAN の外から見られる（Arena の Live Preview など）
* `--port 5199` でポート変更
* ビルドが失敗している間は**直前の成功物を配信し続け**、壊れた画面は出しません。
  現在の状態は次の 1 行で分かります。

```bash
curl http://127.0.0.1:5173/__zts_dev__/state
{"v":3,"ok":true,"hot":"css"}
```

`v` は**成功した更新**のたびに増え、`hot` は `"css"`（その場で差し替え）か `"full"`（リロード）、
`ok` は直前の結果です。`ok:false` のままなら
ターミナルに出ている Zig のエラーを直してください。

## 3. 数えるコマンドを書く

ここからが ziggurats の本体です。**Zig に関数を書くと、それがそのまま JavaScript の
`invoke("…")` になります。** まず `build.zig` に `zts_rpc` を足します。

```zig
// build.zig の const app = b.createModule(...) に 1 行足すだけ
const zts_rpc = dep.module("zts_rpc");
// .imports に追加:
//     .{ .name = "zts_rpc", .module = zts_rpc },
```

コマンドは 3 行で書けます。

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const State = struct { count: i32 = 0 };

const Commands = struct {
    /// `invoke("increment")` → `state.count += 1`
    pub fn increment(state: *State) !i32 {
        state.count += 1;
        return state.count;
    }
};

pub const Schema = rpc.Schema(.{ .app = Commands });

test "increment は 1 ずつ増える" {
    var state = State{};
    try std.testing.expectEqual(@as(i32, 1), try Commands.increment(&state));
    try std.testing.expectEqual(@as(i32, 2), try Commands.increment(&state));
}
```

このブロックは CI の doctest でコンパイルしています。**古い API を書くと CI が
赤くなる**ので、ここに書いてあるコードは今のバージョンで通ります。

画面側は Tauri とまったく同じです。`@tauri-apps/api` をそのまま使います。

```html
<button id="inc">+1</button>
<span id="count">0</span>
<script type="module">
  import { invoke } from "@tauri-apps/api/core";
  document.getElementById("inc").addEventListener("click", async () => {
    document.getElementById("count").textContent = await invoke("increment");
  });
</script>
```

> [!NOTE]
> `web/index.html` のインラインスクリプトは、ビルド時に **CSP ハッシュ**が自動で付きます。
> `unsafe-inline` を書く必要はありません。ビルドが失敗するときは、`<script>` を閉じ忘れて
> いないか確認してください（ハッシュは要素全体から計算されます）。

アプリ側は、状態を作って `bind` するだけです。

```zig
var state = State{};
var router = Schema.bind(.{ .app = &state });
const handler = router.handler(); // これを Host に渡す
```

これで「ボタン → `invoke` → Zig の関数 → 戻り値」が通りました。次は配布物にします。

## 4. 単一バイナリにビルドする

```bash
zts build
# → zig-out/bin/my_app
```

`web/` の内容は**バイナリに埋め込まれます**（gzip 双子と CSP ハッシュ付き）。隣にアセット
ディレクトリを置く必要はありません。

```bash
zts build --target aarch64-macos    # クロスコンパイル
zts build --debug                  # Debug（既定は ReleaseSmall）
zts build --frontend-only          # web/ の再埋め込みだけ
```

`zts build` は `--target` / `--debug` / `--frontend-only` / `--dir` 以外のフラグを解釈しません。
`build.zig` のオプション（`-Dgtk=false` など）を使いたいときは、プロジェクト直下で
`zig build` を直接叩いてください。

## 5. つまずいたら `zts doctor`

```text
$ zts doctor
zts 0.1.0
  checkout     /home/you/Z-Ts
  z_ts         present
  zig          /tmp/zts-toolchains/zig/zig
  package      my_app
  dependency   ../../home/you/Z-Ts
  web/         present

all checks passed
```

`MISSING` が出た行がそのまま対処のヒントになります（詳細は
[`troubleshooting.md`](../guides/troubleshooting.md)）。

---

## ここから先

おつかれさまでした。「作る → 動かす → 配る」の 1 周が終わりました。

| 次に知りたいこと | 行き先 |
|---|---|
| コマンドの引数・エラー・TypeScript 型生成 | [ガイド: コマンド](../guides/rpc.md) |
| ウィンドウ・ファイル・メニュー | [ガイド: プラグイン](../guides/plugins.md) |
| サーバなしの静的サイト | [ガイド: 静的サイト](../guides/static-site.md) |
| `.deb` / `.dmg` / `.exe` を作る | [ガイド: 配布物](../guides/package.md) |
| Tauri v2 からの移行 | [ガイド: 移行](../guides/migrate-from-tauri.md) |
| うまく動かないとき | [トラブルシューティング](../guides/troubleshooting.md) |
| 全コマンド・全オプション | [`docs/reference/cli.md`](../../../reference/cli.md) |
| 動くサンプル（3 成果物） | [`examples/counter/README.md`](../../../../examples/counter/README.md) |
| 設計から理解したい | [概念の索引](../concepts/index.md) |
