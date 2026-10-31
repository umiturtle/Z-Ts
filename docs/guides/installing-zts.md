# `zts` を手元に用意する

`zts` は Z-Ts でアプリを作るための CLI です（Angular CLI のような位置づけ）。
`init` / `dev` / `build` / `doctor` の 4 つだけ覚えれば、プロジェクトの生成から
単一バイナリのビルドまで完結します。

> Z-Ts の**リポジトリ自体**をビルド・テストする手順は
> [`../contributing/README.md`](../contributing/README.md) にあります。このページは
> 「`zts` というコマンドを手に入れる」ところまでです。

---

## 1. ビルド済みバイナリを用意する（現状の唯一の方法）

`zts` はまだ配布バイナリを公開していません。チェックアウトからビルドします。

```bash
git clone https://github.com/umiturtle/Z-Ts.git
cd Z-Ts
./zigw build            # Zig 0.17 を自動導入して zig-out/bin/zts を作る
```

できたものを `PATH` に置けば、以降はリポジトリの外から使えます。

```bash
mkdir -p ~/.local/bin
cp zig-out/bin/zts ~/.local/bin/
export PATH="$HOME/.local/bin:$PATH"
zts version             # → zts 0.1.0
```

> `./zigw` は Python 3.8 以上だけを要求し、Zig 0.17.0 を `/tmp` に導入します
> （コンテナをまたぐと再導入されます）。`zig` を既に持っているなら
> `zig build` でも同じものが出来ます。

## 2. `zts` が使う Zig

`zts` はビルド時に**自分をビルドしたチェックアウトの場所**を覚え、生成するプロジェクトの
`build.zig.zon` にその相対パスを書きます。実行時には `zig` を子プロセスとして起動するため、
**同じ 0.17 系の Zig が `PATH` に必要**です。

```bash
export ZTS_ZIG=/path/to/zig     # PATH に無い場合はここで指定
zts doctor                      # zig / z_ts / package / dependency / web を点検
```

`zts doctor` が `all checks passed` と言えば準備完了です。

## 3. チェックアウトを動かした / 別の場所を使いたい

`zts` を別のマシンへコピーした場合、覚えているチェックアウトのパスは存在しません。
`zts doctor` が次のように教えます。

```text
  z_ts         MISSING at /home/you/Z-Ts — rebuild zts or pass --zts-path
```

対処は 3 つです。

| 方法 | コマンド |
|---|---|
| その場所にチェックアウトを置く | `cp -r Z-Ts /home/you/Z-Ts` |
| 生成時にパスを指定する | `zts init my-app --zts-path /path/to/Z-Ts` |
| 既存プロジェクトの依存を書き換える | `build.zig.zon` の `.z_ts = .{ .path = "…" }` |

`zts` を新しいチェックアウトから作り直すのが一番確実です。

## 4. プラットフォームごとの前提

| OS | 必要なもの | 備考 |
|---|---|---|
| Linux | GTK3 + WebKit2GTK 4.1（`libgtk-3-dev libwebkit2gtk-4.1-dev`） | 無い場合 `zts build` は GTK バックエンドを外してビルドします |
| macOS | Xcode Command Line Tools | Cocoa バックエンドは macOS SDK を使います |
| Windows | WebView2 Runtime（Windows 11 は標準搭載） | 単一 `.exe`、DLL の配布は不要 |

Zig は `zts` が子プロセスとして呼びます。**0.17 系の `zig` が `PATH`（または `ZTS_ZIG`）に
あることが前提**で、`zts` 自身は Zig を同梱していません。

---

## 次に読むもの

- 最初のアプリ: [`getting-started.md`](getting-started.md)
- 全コマンドと全オプション: [`../reference/cli.md`](../reference/cli.md)
- 動かないとき: [`troubleshooting.md`](troubleshooting.md)
