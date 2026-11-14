# `zts` を手元に用意する

> **対象読者**: `zts` をまだ持っていない人。
> **所要時間**: 3 分（Linux / macOS / Windows）。
> **前提**: Zig 0.17 系。`zts` は Zig を同梱せず、子プロセスとして呼びます。

`zts` は ziggurats でアプリを作るための CLI です（Angular CLI のような位置づけ）。
`init` / `dev` / `build` / `doctor` の 4 つだけ覚えれば、プロジェクトの生成から
単一バイナリのビルドまで完結します。

配布物は **`zts` の単体バイナリ 1 個**です。コンパイラは同梱しないので、0.17 系の `zig` を
`PATH` に置いてください。**アプリを作るのに必要なのは、この 2 つだけ**です。

> [!TIP]
> このページは**インストールだけ**を詳しく知りたい人向けです。とにかく動かしたいなら
> [はじめての ziggurats](../start.md)（10 分）の 1〜2 章が同じ内容を 4 分で終わらせます。

---

## 1. `zts` を置く

[GitHub Releases](https://github.com/umiturtle/ZigguraTs/releases) から、使う OS のバイナリを
1 つ落とします（`zts-0.1.1-linux-x86_64` のような名前）。約 300 KB、**libc に依存しない
単体ファイル**で、隣に置くものはありません。

```bash
# Linux / macOS（`linux-aarch64` など、実行環境に合う名前を選ぶ）
curl -LO https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/zts-0.1.1-linux-x86_64
chmod +x zts-0.1.1-linux-x86_64
mkdir -p ~/.local/bin
mv zts-0.1.1-linux-x86_64 ~/.local/bin/zts
export PATH="$HOME/.local/bin:$PATH"
zts version             # → zts 0.1.1
```

```powershell
# Windows（PowerShell）
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest `
  https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/zts-0.1.1-windows-x86_64.exe `
  -OutFile "$HOME\bin\zts.exe"
$env:PATH = "$HOME\bin;$env:PATH"
zts version
```

各リリースには `SHA256SUMS` が付きます。確認したい場合だけ使ってください。

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

## 2. `zig` を `PATH` に入れる

`zts` は `zig build` を子プロセスで起動するだけで、コンパイラを持ちません。0.17 系の `zig` を
`PATH` に入れてください（[ziglang.org/download](https://ziglang.org/download/)）。

```bash
zig version             # → 0.17.0
zts doctor              # release の zts なら checkout 行は "(none — release build)"
```

Zig を `PATH` 以外の場所に置いている場合は `ZTS_ZIG` で指定します。

```bash
export ZTS_ZIG=/opt/zig/zig
```

## 3. 最初のプロジェクト

```bash
zts init my-app
cd my-app
zts build
./zig-out/bin/my_app    # Windows は .\zig-out\bin\my_app.exe
```

`zts build` の初回だけ、生成されたプロジェクトが **ziggurats のソースアーカイブを取得**します。
`build.zig.zon` に次の 1 行が入っているためです（バイナリに焼き込まれた値で、あなたが書く
必要はありません）。

```zig
.z_ts = .{ .url = "https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz", .hash = "z_ts-0.1.1-…" },
```

取得物は Zig のキャッシュに入るので、2 回目以降はオフラインでもビルドできます。**チェックアウト
を clone しておく必要はありません**。

> `zig fetch` を自分で叩いて中身を確かめることもできます。
> `zig fetch https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz`

## 4. チェックアウトから自分でビルドする場合

ziggurats 本体を直したい人、公開バイナリを使わずに済ませたい人はソースから作れます。
`zig` は自分で用意してください。

```bash
git clone https://github.com/umiturtle/ZigguraTs.git
cd Z-Ts
zig build                # → zig-out/bin/zts（Zig 0.17 が PATH に必要）
```

このやり方で作った `zts` は、**そのチェックアウトを覚えます**。生成するプロジェクトの
`build.zig.zon` には相対パスが入ります。

```zig
.z_ts = .{ .path = "../../../home/you/Z-Ts" },
```

チェックアウトを動かすと、生成済みのプロジェクトはそのパスを見失います。次のどれかで直します。

| 方法 | コマンド |
|---|---|
| プロジェクトを作り直す（公開URLを指定） | `zts init my-app --zts-url <url> --zts-hash <hash>` |
| プロジェクトを作り直す（パスを指定） | `zts init my-app --zts-path /path/to/Z-Ts` |
| 生成済みプロジェクトを書き換える | `build.zig.zon` の `.z_ts` を `.url`+`.hash` か新しい `.path` に |
| `zts` を作り直す | 新しいチェックアウトで `zig build` |

> リポジトリ自体のビルド・テスト（CI、スクリプト、ドキュメントサイトの生成）は**開発者向け**の
> 手順で、[`../../contributing/README.md`](../../../contributing/README.md) にまとめてあります。
> アプリを作る側では読む必要はありません。

## 5. プラットフォームごとの前提

| OS | 必要なもの | 備考 |
|---|---|---|
| Linux | GTK3 + WebKit2GTK 4.1（`libgtk-3-dev libwebkit2gtk-4.1-dev`） | 無い場合 `zts build` は GTK バックエンドを外してビルドします |
| macOS | Xcode Command Line Tools | Cocoa バックエンドは macOS SDK を使います |
| Windows | WebView2 Runtime（Windows 11 は標準搭載） | 単一 `.exe`、DLL の配布は不要 |

---

## 次に読むもの

- 最初のアプリ: [`counter.md`](../tutorials/counter.md)
- 全コマンドと全オプション: [`reference/cli.md`](../../../reference/cli.md)
- 動かないとき: [`troubleshooting.md`](troubleshooting.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
