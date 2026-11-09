# 概念

> **対象読者**: `zts dev` を 1 度は動かした人。まだなら先に [はじめての Z-Ts](../start.md) へ。
> **所要時間**: 4 ページ・約 15 分。

## あなたがさっき見たものを、3 つの登場人物で言い直す

[はじめての Z-Ts](../start.md) では、`web/index.html` を書き換えるとブラウザが変わるところまで
やりました。同じことを、**ボタンが Zig の関数を呼ぶ**形にすると、登場人物は 3 つだけです。

```text
  ①  ページ            ②  ブリッジ                     ③  コマンド
  web/index.html  ──►  invoke("increment")  ──►  fn increment(state: *State) !i32
  (HTML / JS)          @tauri-apps/api そのまま       (src/main.zig のふつうの関数)
                              ▲                              │
                              └──────── 戻り値（数値・構造体・エラー）──┘
```

| 登場人物 | 役割 | どこに書くか |
|---|---|---|
| ページ | 画面と操作。Tauri と同じ `@tauri-apps/api` がそのまま動く | `web/` |
| ブリッジ | 名前と型を突き合わせ、JSON にして運ぶ。手書きはゼロ | `Schema`（`comptime` が組み立てる） |
| コマンド | Zig の関数。引数を受け取り、状態を触り、値を返す | `src/` |

**この 2 番目が Z-Ts の仕事です。** ルーティング、シリアライズ、型検査、TypeScript の型定義は
すべて `Schema` から生成されるので、あなたは ① と ③ だけを書きます。

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const State = struct { count: i32 = 0 };
const Commands = struct {
    pub fn increment(state: *State) !i32 {
        state.count += 1;
        return state.count;
    }
};

const Schema = rpc.Schema(.{ .app = Commands });

test "コマンド表には increment が 1 本だけ入る" {
    try std.testing.expectEqual(@as(usize, 1), Schema.commands.len);
}
```

## 4 ページで埋める残り

上の図は「1 本のコマンド」の話です。実際には、状態をどこに置くか、どのプラグインを積むか、
誰にそのコマンドを許すか、という 4 つの問いが残ります。

| ページ | 1 文でいうと | 読むと分かること |
|---|---|---|
| [パッケージ構成](architecture.md) | 6 つのパッケージが 1 方向にだけ依存する | どこに何を書くか、なぜコアが libc を要求しないか |
| [コマンドが届くまで](commands.md) | TypeScript の `invoke` が Zig の関数になるまで | `Schema` の役割、型検査、命名変換 |
| [プラグイン](plugins.md) | Tauri 標準の 7 プラグインをそのまま使う | `withCorePlugins`、状態の束縛 |
| [セキュリティ](security.md) | 既定は拒否。許可は capability に書く | ACL、scope、CSP、守らないこと |

## 先に覚える 5 つの言葉

この 4 ページで何度も出てくる言葉です。読みながら戻ってきてください。

| 言葉 | 意味 |
|---|---|
| **Pack** | 配布単位の Zig モジュール（`zts_rpc` など）。使うものだけリンクする |
| **Host** | OS に触る唯一の層。デスクトップ・ブラウザ・WASM で実装が差し替わる |
| **Ctx** | コマンドに渡される実行コンテキスト（I/O、状態、イベント送信の入口） |
| **Schema** | コマンド名・引数・戻り値の型表。`comptime` で作られる |
| **Capability** | 「このウィンドウはこのコマンドを呼んでよい」という宣言 |

もっと詳しくは [用語集](../../../glossary.md) に定義があります（本文からも随時リンクしています）。

## 読む順番

上の 5 つの言葉のうち、**Pack と Host だけ先に**知っておくと残りが読みやすくなります。

1. [パッケージ構成](architecture.md) — 全体の地図。ここだけは飛ばさないでください
2. [コマンドが届くまで](commands.md) — Z-Ts を使うときに最も頻繁に触れる部分
3. [プラグイン](plugins.md) — ウィンドウ・ファイル・メニューなど
4. [セキュリティ](security.md) — 配布前には必ず

## 次に読むもの

- 手を動かす → [チュートリアル](../tutorials/index.md)（カウンター / Todo / 画面の 3 本）
- 書きはじめて迷った → [実用パターン](../patterns/index.md)
- すぐ書きたい → [ガイド: コマンド](../guides/rpc.md)
- 言葉で迷った → [用語集](../../../glossary.md)
