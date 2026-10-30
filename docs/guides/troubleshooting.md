# トラブルシューティング

「動かない」ときに最初に見る 1 ページです。すべて**実際に踏んだ**問題だけを載せています。

---

## まず実行するもの

```bash
bash scripts/status.sh          # ブランチ・並列エージェント・直近 CI を一望
./zigw quick-test               # 単体テスト（ツールチェーン確認を兼ねる）
./zigw fmt --check src/ tests/ build.zig
python3 scripts/check-docs.py   # ドキュメント構造・リンク
```

3 つとも通れば、少なくとも「壊れているのは自分の変更」です。

---

## ビルド・ツールチェーン

### `error: FileNotFound` で Zig が見つからない

`./zigw` は PyPI の wheel から Zig 0.17.0 を `/tmp/zts-toolchains/` に導入します。
プロキシ環境で失敗する場合:

```bash
export HTTPS_PROXY=http://…   # 必要なら
./zigw version                  # 導入だけを先に実行して切り分ける
```

`/tmp` はコンテナごとに消えます。**チャットをまたぐと毎回 4 秒の再導入が走る**のは仕様です
（内部資料 [`../environment/arena-and-caching.md`](../environment/arena-and-caching.md)）。

### `zig build` が異様に遅い（コールドで 90 秒以上）

`std.Build` ランナー自体のビルドに ~94 秒かかります。開発中は `./zigw quick-test` と
`./zigw build-exe` を使ってください。`build.zig` の検証は CI（キャッシュあり）に任せるのが
このリポジトリの既定です。

### `-Dgtk=true` でヘッダが見つからない

GTK3 / WebKit2GTK 4.1 の開発パッケージが要ります:

```bash
bash scripts/setup-toolchains.sh --sysroot   # Debian 12 の sysroot を導入
```

CI と同じ Ubuntu 24.04 なら `libgtk-3-dev libwebkit2gtk-4.1-dev`。

---

## テスト

### `expected type '*Build.Step', found '*const *Build.Step'`

`Step.dependOn` は `*Step` を要求します。`tsgenBindings(...).step` は `*const *Step` なので
`&` を付けずに渡してください:

```zig
test_step.dependOn(check_bindings.step);   // ← & を付けない
```

### `bindings.gen.ts is stale` で CI が落ちる

スキーマを変えたら生成し直します:

```bash
./zigw build tsgen
```

`--check` はキャッシュされると「常に緑」になるため、検証 Run には
`has_side_effects = true` を付けています（内部資料 [`../architecture/build-tools.md`](../architecture/build-tools.md) §3）。

### `error: invalid fingerprint: 0x…`（`build.zig.zon`）

Zig 0.17 は `.name` があるパッケージに `.fingerprint` を要求します。エラーメッセージが
**正しい値を教えてくれる**ので、それをそのまま書きます:

```text
build.zig.zon:1:2: error: invalid fingerprint: 0x0; if this is a new or forked package,
use this value: 0xe244585b08949903
```

上位 32 bit だけが名前から検証され、下位 32 bit は fork 識別子（毎回変わってよい）です。
`zts init` はこの値を自動で拾って patch します（`src/cli/template.zig`）。

### `error: WriteFailed` が `Allocator.Error!` から出る

`std.Io.Writer.Allocating` のエラー集合は `error{WriteFailed}` です。`Allocator.Error!T` を
宣言した関数から `try w.writeAll(...)` は通らないので、内部は
`Allocator.Error || error{WriteFailed}` で受け、公開境界で `OutOfMemory` に畳みます
（`src/docsite/*.zig` の `Error` がその例）。

### 0.17 の std API 違い

| 0.14 まで | 0.17 |
|---|---|
| `std.mem.trimLeft/trimRight` | **`std.mem.trimStart/trimEnd`** |
| `b.addWriteFiles()` | `b.addUpdateSourceFiles()` |
| `@cImport(...)` | 廃止（`extern fn … callconv(.c)` を手書き） |
| `std.compress.flate.Options` | `flate.Compress.Options` |
| `fn main() !void` | `fn main(init: std.process.Init) !void`（`init.io` / `init.gpa`） |

---

## ネイティブ WebView

### Linux で文字が豆腐になる / OS ごとに表示が違う

同梱フォント（`ZTS Sans` / `ZTS Mono`）を使っているか確認してください。システムフォントを
参照すると Linux だけ字形が変わります。`node scripts/check-font-coverage.mjs` が
「使っている文字が全部フォントに入っているか」を検証します。

### スクリーンショットが真っ黒 / 取得できない

Xvfb 上ではソフトウェアレンダリングを強制します:

```bash
WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 \
ZTS_WEBVIEW_SOFTWARE_RENDER=1 \
xvfb-run -a ./zigw build test -Dgtk=true
```

### macOS の C シムがクロスビルドできない

Objective-C シムは macOS の SDK を要求します。Linux からは**構文チェックだけ**行います:

```bash
./zigw test -fno-emit-bin -target aarch64-macos -mcpu baseline \
  --dep zts_foundation -Mroot=src/tauri/native.zig …
```

実ビルド・実行は macOS の CI ジョブが担当します。

---

## ドキュメントサイト

### `docsite: N broken link(s)` で `zig build docs` が落ちる

生成器は**全相対リンクを実際の出力と突き合わせます**。メッセージの `-> 解決後パス` を見て、
リンク先を直すか、そのファイルをサイトに含めてください（`.md` は自動で含まれます）。
`src/**.zig` のようなサイト外ファイルへのリンクは、リポジトリに実在すれば自動で GitHub の
blob URL に差し替わります。

### 検索が 0 件になる

`assets/search-index.js` が読み込まれていない可能性があります。`file://` で開くと
ブラウザによっては `script` の読み込みが制限されます。`python3 -m http.server` 経由で確認して
ください。

### GitHub Pages の公開だけがスキップされる（`Pages not enabled` の警告）

ビルドは成功していて、**公開だけ**が止まっています。初回のみ、リポジトリ管理者が
Settings → Pages → Build and deployment → Source を **GitHub Actions** にしてください。
次の `main` push で、コードを変えずに公開が始まります。

> **`enablement: true` では作れない** — `GITHUB_TOKEN` は Pages サイトを**作成できません**
> （実測: `Create Pages site failed. Error: Resource not accessible by integration`）。
> 作成は管理者権限の操作なので、Bot からは `GET` しか通りません。ワークフローは
> `GET` → 失敗時のみ `POST` → それも失敗なら警告、という順で判定しているため、
> CI が赤くなることはありません。

---

## フロントエンド

### `bindings.gen.ts` と `@tauri-apps/api` の型が合わない

`@tauri-apps/api` は**無改変**で同梱しています。型が合わない場合は、生成された
`bindings.gen.ts` のコマンド名が `Schema` と一致しているか確認してください
（`plugin:fs|read_text_file` のような `plugin:` 接頭辞まで含めて一致が必要です）。

### Vite の出力を埋め込んだら真っ白

複数チャンクの ES モジュールを 1 つの `<script type="module">` にインライン化すると
`import "./chunk.js"` が解決できません。`dist/` **ディレクトリごと**埋め込み、
`/assets/…` の相対解決は `zts_web.Assets` に任せてください
（[`../../examples/frameworks/README.md`](../../examples/frameworks/README.md) の実例）。

---

## CI

### `gh run view --log` が `EOF` で失敗する

ログは外部ホストへリダイレクトされます。代わりに:

```bash
bash scripts/ci-logs.sh <run_id>     # Check Run API 経由で Step Summary を取得
```

### 3 OS の画素比較だけが落ちる

`OK parity …` の行に `layout` と `pixels=max:…% mad:…` が出ます。許容差は
「レイアウト 1px + 0.5px×文字数、背景 ±4/255、平均輝度 ≤3.0、画素 ≤12%、MAD ≤8」。
フォント同梱と `--require-native` を確認してください
（内部資料 [`../architecture/screenshot-parity.md`](../architecture/screenshot-parity.md)）。

---

## 次に読むもの

- 使い方の全体像: [`getting-started.md`](getting-started.md)
- エラーに対応する API の引き方: [`using-the-api-reference.md`](using-the-api-reference.md)
- ログの取得: [`../../scripts/ci-logs.sh`](../../scripts/ci-logs.sh) / [`../../AGENTS.md`](../../AGENTS.md)
