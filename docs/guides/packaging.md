# 配布物を作る（`zts package`）

`zts build` までは「動く実行ファイル」までです。このガイドでは、それを**人に渡せる形** —
`.deb`、AppDir、`.app`、`.dmg`、アイコン入り `.exe`、ポータブルな `.tar.gz` — にするところまで
を扱います。

```bash
zts build            # 実行ファイルを作る
zts package          # ホスト OS の既定形式に包む
```

出力は `<プロジェクト>/zig-out/package/` です。

> `zts package` は**実行ファイルを包むだけ**で、ビルドはしません。先に `zts build` を
> 走らせてください（忘れると `zig-out/bin/<name> not found — run zts build first` で止まります）。

---

## 1. どの OS で何が作れるか

| ホスト | `deb` | `appdir` | `app` | `dmg` | `exe` | `tar.gz` |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Linux | ✅ | ✅ | ✅ | ❌ | ✅（PE があれば） | ✅ |
| macOS | ✅ | ✅ | ✅ | ✅ | ✅（PE があれば） | ✅ |
| Windows | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |

* `dmg` だけは macOS の `hdiutil` を呼ぶので macOS 専用です。
* それ以外は**ホスト非依存**です。Windows の `.exe` は Linux からでも作れます（クロスビルド +
  `--format exe`）。
* 「PE があれば」は、`zts build --target x86_64-windows` のように Windows 向けにビルドした
  実行ファイルを指します。形式と中身が食い違うと、書く前にエラーで止まります。

---

## 2. まずは 1 つ作る

```bash
zts build
zts package
ls zig-out/package/
```

ホストが Linux なら `.deb`、macOS なら `.app`、Windows なら `.exe` が 1 つできます。
複数欲しいときは `--format` にカンマ区切りで並べます。

```bash
zts package --format deb,appdir,tar.gz
zts package --format app,dmg --icon icon.png
```

すでにある出力は上書きされます。`--out` で別の場所にも出せます。

```bash
zts package --out dist
```

---

## 3. 名前・バージョン・アイコン

パッケージ名は `build.zig.zon` の `.name`、バージョンは `.version` から取ります。変えたいときは
フラグで上書きします。

```bash
zts package --version 1.2.0 --maintainer "Your Name <you@example.com>"
```

`--maintainer` を省くと `ZTS_MAINTAINER` を読み、それも無ければプレースホルダを使って
警告を出します（公開するパッケージでは必ず指定してください）。

| アイコン | 使う形式 | 作り方の例 |
|---|---|---|
| `deb` / `appdir` / `app` | PNG（256×256 推奨） | `magick icon.svg -resize 256x256 icon.png` |
| `exe` | `.ico`（16/32/48/256 など複数サイズ） | `magick icon.png -define icon:auto-resize=256,48,32,16 icon.ico` |

```bash
zts package --icon icon.png --icon-ico icon.ico --manifest app.manifest
```

`.icns` は不要です。macOS のバンドルには `Contents/Resources/<name>.png` を置きます
（テンプレートから配る開発ビルド向け。App Store 提出用の `.icns` 化は `iconutil` で行ってください）。

---

## 4. Linux

### `.deb` を入れる

```bash
sudo dpkg -i zig-out/package/my_app_0.1.0_amd64.deb
my_app
sudo dpkg -r my-app        # 名前はアンダースコアがハイフンになったもの
```

入るもの:

```text
/usr/bin/<name>
/usr/share/applications/<name>.desktop
/usr/share/icons/hicolor/128x128/apps/<name>.png   （--icon を渡したとき）
/usr/share/doc/<name>/copyright
```

`Architecture:` は実行ファイルのヘッダから読みます。`--target aarch64-linux` でビルドしたものは
`arm64` になり、`amd64` と誤記されません。

`Depends:` は**実行ファイルが実際にリンクしているライブラリ**から作ります。ウィンドウを開かない
アプリに GTK が付くことはありません。GTK/WebKitGTK を使うアプリなら
`libgtk-3-0, libwebkit2gtk-4.1-0` が入ります。

### AppDir を AppImage にする

`appdir` は AppImage の入力形式です。`appimagetool` があれば 1 コマンドです。

```bash
zts package --format appdir --icon icon.png
appimagetool zig-out/package/my-app-0.1.0-amd64.AppDir my-app.AppImage
chmod +x my-app.AppImage && ./my-app.AppImage
```

AppDir はそのままでも動きます（`AppRun` が実行ファイルを呼びます）。

```bash
./zig-out/package/my-app-0.1.0-amd64.AppDir/AppRun
```

### ポータブルな `.tar.gz`

```bash
zts package --format tar.gz
tar -xzf zig-out/package/my-app-0.1.0-amd64.tar.gz
./my-app-0.1.0/my-app
```

`<name>-<version>/` の中に実行ファイル・`.desktop`・アイコンが入ります。

---

## 5. macOS

```bash
zts build
zts package --format app --icon icon.png
open zig-out/package/My\ App.app
```

`Contents/Info.plist` の `CFBundleIdentifier` は `--identifier`（既定 `com.example.<name>`）です。
Finder から起動する場合は**表示名**（`my_app` → `My App`）がバンドル名になります。

`.dmg` は `.app` を作ってから包みます。

```bash
zts package --format dmg --icon icon.png
open zig-out/package/My\ App-0.1.0.dmg
```

配布した `.dmg` / `.app` は**署名していません**。受け取った人が Gatekeeper に止められた場合は
`xattr -dr com.apple.quarantine <app>` で解除できます。正式配布には `codesign` と
`notarytool` が必要です（`zts` はどちらも呼びません）。

---

## 6. Windows

アイコンとマニフェストは、ビルド済みの `.exe` に**後から埋め込みます**。

```bash
zts build --target x86_64-windows
zts package --format exe --icon-ico icon.ico --manifest app.manifest
```

最小の `app.manifest`（DPI 対応を宣言する例）:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="MyApp" version="1.0.0.0"/>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">permonitorv2</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
```

埋め込まれたかどうかは、エクスプローラで `my_app.exe` のアイコンが変わっていることで確認できます。

---

## 7. クロスビルドした実行ファイルを包む

`zts build --target <triple>` のあとは、そのまま `zts package` で構いません。アーキテクチャは
実行ファイルから読むので、`--arch` のようなフラグはありません。

```bash
zts build --target aarch64-linux      # zig-out/bin/my_app
zts package --format deb,tar.gz       # my_app_0.1.0_arm64.deb など
```

`--binary` で別の実行ファイルを指定することもできます。

```bash
zts package --binary path/to/other-exe --format tar.gz
```

---

## 8. CI で配布する

ビルドとパッケージを 1 ジョブにまとめ、成果物をそのままアップロードします。

```yaml
- run: zts build
- run: zts package --format deb,tar.gz --icon icon.png
- uses: actions/upload-artifact@v4
  with:
    name: packages-${{ runner.os }}
    path: zig-out/package/*
```

`zts` 自体の入手は [`installing-zts.md`](installing-zts.md) を参照してください。

---

## 9. つまずきどころ

| メッセージ | 意味と直し方 |
|---|---|
| `zig-out/bin/<name> not found — run zts build first` | ビルドしていない。`zts build` を先に。`--target` を変えたら再度ビルド |
| `--format exe needs a Windows PE image` | `--format exe` は PE 専用。`zts build --target x86_64-windows` でビルドする |
| `--format deb needs a POSIX executable, got a PE image` | Windows 向けビルドを Linux 形式に包もうとしている。形式と対象を揃える |
| `--format dmg needs macOS` | `dmg` は macOS のみ。他のホストでは `app` を使う |
| `the executable is not an ELF, Mach-O or PE image` | `--binary` の指す先が実行ファイルでない（スクリプトなど） |
| `unknown format 'foo'` | `deb` / `appdir` / `app` / `dmg` / `exe` / `tar.gz` のいずれか |
| `names are [a-z][a-z0-9_-]*` | パッケージ名が規約外。`build.zig.zon` の `.name` を直すか、`zts init` で作り直す |
| `no --maintainer (or ZTS_MAINTAINER)` | 公開前に `--maintainer "Name <email>"` を渡す |

同じ入力からは**同じバイト列**が出ます（タイムスタンプは固定）。「ビルドし直したら `.deb` の
ハッシュが変わる」ことはないので、リリースの再現性チェックに使えます。

---

## 次に読むもの

- コマンドの全オプション: [`../reference/cli.md`](../reference/cli.md#zts-package)
- はじめかたに戻る: [`getting-started.md`](getting-started.md)
- 内部の作り（なぜ PE を書き換えるのか等）: [`../architecture/packaging-and-bench.md`](../architecture/packaging-and-bench.md)
