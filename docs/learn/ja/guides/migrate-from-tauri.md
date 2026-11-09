# Tauri v2 からの移行

> **対象読者**: Tauri v2 のアプリを ziggurats に載せ替えたい人。
> **所要時間**: 30 分（フロントエンドは変更不要です）。
> **前提**: Tauri v2 のプロジェクトが手元にあり、`zts` が使える（[インストール](install.md)）。

既存の Tauri v2 アプリ（Rust + `@tauri-apps/api`）を ziggurats に載せ替える手順です。
**ゴールは「フロントエンドを 1 行も変えない」**こと。ziggurats は Tauri の IPC プロトコル
（`tauri://` の内部呼び出し、`__TAURI_INTERNALS__`、plugin コマンド名）をそのまま実装しているので、
JavaScript 側は原則そのまま動きます。

---

## 1. 対応表

| Tauri（Rust） | ziggurats（Zig） | 状態 |
|---|---|---|
| `tauri.conf.json` | [`config_import.load`](../../../api/zts_tauri/config_import.html#load) | 対応（未知キーは警告、型違いはエラー） |
| `capabilities/*.json` + `acl` | [`acl.Policy`](../../../api/zts_tauri/acl.html#Policy) | 対応（`fromImported` で取り込み） |
| `#[tauri::command]` | [`zts_rpc.Schema`](../../../api/zts_rpc/schema.html#Schema) + [`bind`](../../../api/zts_rpc/schema.html#Schema) | 対応 |
| `plugin:dialog` | [`zts_tauri.dialog`](../../../api/zts_tauri/dialog/mod.html) | 対応（GTK / AppKit / Win32） |
| `plugin:clipboard-manager` | [`zts_tauri.clipboard`](../../../api/zts_tauri/clipboard/mod.html) | 対応 |
| `plugin:fs` | [`zts_tauri.fs`](../../../api/zts_tauri/fs/mod.html) | 対応（スコープ付き） |
| `plugin:menu` / `plugin:tray` | [`menu`](../../../api/zts_tauri/menu/mod.html) / [`tray`](../../../api/zts_tauri/tray/mod.html) | 対応（Cocoa / Win32 / GTK） |
| `tauri build`（バンドラ） | [`zts package`](package.md) | 対応（deb / AppImage 風 AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz`） |
| `tauri dev` | [`zts dev`](../tutorials/counter.md) | 対応（HTTP 配信 + 変更検知 + 自動リロード） |

## 2. 設定ファイルはそのまま読ませる

```zig
const imported = try zts_tauri.config_import.load(alloc, io, cwd);
// imported.config      : tauri.conf.json の内容（未知キーは警告、型違いはエラー）
// imported.capabilities: capabilities/*.json をまとめた ACL
// imported.warnings    : 読めなかった／解釈できなかった項目
```

得られた `Imported` から ACL ポリシーを作り、コマンド実行時に判定します:

```zig
var policy = try zts_tauri.acl.Policy.fromImported(alloc, imported);
const allowed = policy.allows("plugin:fs|read_text_file", .{ .window_label = "main" });
// 例: capability の `fs:allow-read-text-file` が `plugin:fs|read_text_file` に写される
```

**fail-closed** です。capability に書かれていないコマンドは拒否されます（上流と同じ）。
仕様の詳細は内部資料 [`../architecture/tauri-config-import-acl.md`](../../../architecture/tauri-config-import-acl.md)。

## 3. コマンドを写す

Rust:

```rust
#[tauri::command]
fn greet(name: &str) -> String { format!("Hello, {name}!") }
```

Zig:

```zig
pub const Commands = struct {
    pub const rpc_prefix = "";
    pub fn greet(ctx: *zts_rpc.Ctx, args: struct { name: []const u8 }) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena, "Hello, {s}!", .{args.name});
    }
};
```

`zts_rpc.Schema` に登録すると、フロントエンドの `invoke("greet", { name })` がそのまま届きます。
`Channel<T>`（ストリーミング）と `Event`（`listen`/`emit`）も同様に実装済みです。

## 4. TypeScript の型を生成する

```bash
# 自分のプロジェクトの build.zig に tsgen ステップを足してから
zig build tsgen             # web/bindings.gen.ts を再生成
```

ステップの足し方は [`rpc.md`](rpc.md) §5 と
[`../../examples/counter/build.zig`](../../../../examples/counter/build.zig) を参照してください。

`@tauri-apps/api` v2 は**無改変**で動くので、`invoke` の型付けだけ自前の
`bindings.gen.ts` に置き換えるのが最小の移行です。

## 5. フロントエンドの配信方法を選ぶ

Tauri は `devUrl` / `frontendDist` で切り替えますが、ziggurats では**ビルド時に埋め込む**のが基本です
（[埋め込みの仕組み](../../../architecture/build-tools.md)）。`dist/` をそのまま `@embedFile` するので、実行時にアセットディレクトリを
配る必要がありません。

| 移行前 | 移行後 |
|---|---|
| `"devUrl": "http://localhost:5173"` | `zts dev`（`web/` を配信 + 自動リロード） |
| `"frontendDist": "../dist"` | エンベッダで `embedded_frontend` モジュールに埋め込む |
| `tauri build` | [`zts build`](../tutorials/counter.md) → [`zts package`](package.md)（deb / AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz`） |

## 6. 移行時に踏みやすいところ

1. **`withGlobalTauri`**: ziggurats は常に `window.__TAURI_INTERNALS__` を公開します。
   `window.__TAURI__` を前提にした古いコードは互換レイヤ（[`js_bootstrap`](../../../api/zts_tauri/js_bootstrap.html)）で吸収済みです。
2. **`invoke` の戻り値**: Tauri は `Result<T, E>` を JSON で返します。ziggurats も同じ封筒
   （`{"result": …}` / `{"error": …}`）を使うので、`try/catch` の挙動は変わりません。
3. **ACL のパススコープ**: `{ "path": "$APPDATA/db/*" }` のようなスコープは
   `Policy` が解決します。解決できない変数は**警告して拒否**（fail-closed）です。
4. **メニュー / トレイ**: predefined 項目（`Copy` / `Quit` / `Separator` …）は OS 標準の
   セレクタ（macOS）／`MF_*`（Win32）へ写されます。カスタム項目は ID で
   `WM_COMMAND` / セレクタ経由で通知されます。
5. **`tauri build` の成果物**: `.deb` / AppDir / `.app` / `.dmg` / `.exe` / `.tar.gz` は
   [`zts package`](package.md) が作ります。`.msi` と AppImage は**まだ**作れません
   （AppDir までは作れるので、AppImage 化は外部ツールに渡せます）。

---

## 次に読むもの

- API の引き方: [API リファレンスの索引](../../../api/index.html)（`plugin:window|set_title` →
  `Commands.set_title` の対応表があります）
- プラグインの実装状況: [`plugins.md`](plugins.md)
- 移行後に動かないとき: [`troubleshooting.md`](troubleshooting.md)
- 既存の Tauri アプリの設定取り込み: [`../api/zts_tauri/config_import.html`](../../../api/zts_tauri/config_import.html)
