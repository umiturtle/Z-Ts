# 他プロジェクトからライブラリとして使う

> **対象読者**: 既存の Zig 0.17 プロジェクトに ziggurats を依存として足したい人。
> **所要時間**: 5 分。
> **前提**: `zig 0.17.0` が `PATH` にあること。`zts` CLI は不要です。

`zts init` はアプリの雛形を作りますが、**ziggurats はそれとは別に普通の Zig パッケージとしても
使えます**。`build.zig.zon` に依存を 1 行足し、`build.zig` で `b.dependency("z_ts", …)` を
呼ぶと、`zts_*` モジュールを自分の好きな組み合わせで import できます。CLI を経由する必要は
ありません。

## 1. 依存を足す

ハッシュは手で計算せず、`zig fetch --save` に任せます。リリースごとに URL とハッシュが
変わるので、コピー＆ペーストではなく次のコマンドを実行してください。

```bash
zig fetch --save=z_ts https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz
```

`build.zig.zon` にこう書き込まれます（`…` は実際のハッシュ）:

```zon
.dependencies = .{
    .z_ts = .{ .url = "https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz", .hash = "z_ts-0.1.1-…" },
},
```

> [!WARNING]
> このリポジトリを clone した人だけが使える `.path = "../Z-Ts"` を配布用の設定に残さないで
> ください。自分の手元では動くのに、他人の `zig build` は失敗します。開発中だけ `.path` を使い、
> 公開するときは必ず `.url` + `.hash` に戻してください。

## 2. `build.zig` でモジュールを渡す

使いたいモジュールだけを `imports` に並べます。全部リンクする必要はありません。

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zts = b.dependency("z_ts", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zts_foundation", .module = zts.module("zts_foundation") },
                .{ .name = "zts_core", .module = zts.module("zts_core") },
                .{ .name = "zts_rpc", .module = zts.module("zts_rpc") },
            },
        }),
    });
    b.installArtifact(exe);
}
```

`b.dependency` の第 2 引数に `.target` と `.optimize` を渡すのを忘れないでください。これが
無いと、クロスコンパイル時に依存だけホスト向けに構築されます。

## 3. import して使う

```zig
const std = @import("std");
const foundation = @import("zts_foundation");
const core = @import("zts_core");

pub fn main() !void {
    const ResourceId = foundation.Handle(.resource);
    var pool: foundation.HandlePool([]const u8, .resource) = .empty;
    defer pool.deinit(std.heap.page_allocator);

    const handle: ResourceId = try pool.acquire(std.heap.page_allocator, "pack://scene.bin");
    std.debug.print("handle: {any}\n", .{handle});

    const size = core.LogicalSize{ .width = .{ .v = 640 }, .height = .{ .v = 480 } };
    std.debug.print("size: {d}x{d}\n", .{ size.width.v, size.height.v });
}
```

`zts_core` は `zts_foundation` の型を再エクスポートしているので、幾何・ハンドル・キューを
1 つの import で扱えます。逆に、デスクトップ層を一切要しないなら `zts_core` を import せず
`zts_foundation` だけにすると依存グラフが小さくなります。

## 使えるモジュール

| モジュール名 | 中身 | 追加の OS 依存 |
|---|---|---|
| `zts_foundation` | ハンドル・ジオメトリ・キュー・所有権 | なし（Pure Zig） |
| `zts_web` | 埋め込みアセット・MIME・HTTP Range・CSP | なし |
| `zts_core` | `foundation` / `web` の再エクスポートと `Host` vtable | なし |
| `zts_rpc` | コマンド・スキーマ・TypeScript 生成 | なし |
| `zts_bridge` | Live Preview の HTTP / SSE サーバ | なし |
| `zts_webview` | ネイティブ WebView（GTK / Cocoa / Win32 / Mock） | OS の WebKit / WebView2 |
| `zts_tauri` | Tauri v2 互換プラグイン | `zts_webview` 経由 |
| `zts_wasm` / `zts_ssg` | WASM ランタイムと静的サイト書き出し | wasm32 |
| `z_ts` | 全モジュールを束ねるルート | 上記すべて |

> `zts_webview` は `zts_foundation` だけに依存します。ウィンドウを出さないサーバサイドの
> コードで `zts_core` と `zts_rpc` だけを使う、といった組み合わせが安全にできます。

## うまくいかないとき

| 症状 | 原因と直し方 |
|---|---|
| `hash mismatch` | アーカイブを差し替えたのに `.hash` が古い。`zig fetch --save=z_ts <URL>` で更新する |
| `unable to find module "zts_core"` | `imports` に渡す名前と `@import` の名前が違うか、`b.dependency` の第 2 引数を忘れている |
| `missing fingerprint` | 自分の `build.zig.zon` の `.fingerprint`。Zig が提案する値をそのまま書く |
| `file not found: examples/...` | 開発用の `.path` 依存が残っている。リリースの `.url` に切り替える |

## この手順は CI で検証されています

[`tests/library-consumer/`](https://github.com/umiturtle/ZigguraTs/tree/main/tests/library-consumer) に、
上の 3 ステップをそのまま実装した別パッケージがあります。CI はリリースと同じ
`git archive` を作り、`zig fetch` でハッシュを求め、**コールドなグローバルキャッシュ**から
`zts_foundation` / `zts_core` / `zts_rpc` / `zts_web` を import してビルド・実行します。
`build.zig` がモジュールの公開をやめた瞬間に赤くなるので、このページのコードが古くなる
ことはありません。

## 次に読むもの

- アプリの雛形から始める → [はじめての ziggurats](../start.md)
- コマンドを定義する → [コマンド（RPC）](rpc.md)
- 公開宣言を名前から引く → [API リファレンス](../../../api/index.html)
- 配布バイナリとバージョン → [インストール](install.md)
