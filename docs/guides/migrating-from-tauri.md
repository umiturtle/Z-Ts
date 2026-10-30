# Tauri v2 からの移行ガイド

既存の Tauri v2 アプリ（Rust + `@tauri-apps/api`）を Z-Ts に載せ替える手順です。
**ゴールは「フロントエンドを 1 行も変えない」**こと。Z-Ts は Tauri の IPC プロトコル
（`tauri://` の内部呼び出し、`__TAURI_INTERNALS__`、plugin コマンド名）をそのまま実装しているので、
JavaScript 側は原則そのまま動きます。

---

## 1. 対応表

| Tauri（Rust） | Z-Ts（Zig） | 状態 |
|---|---|---|
| `tauri.conf.json` | [`src/tauri/config_import.zig`](../../src/tauri/config_import.zig)（`load`） | `M4-04` 対応済み |
| `capabilities/*.json` + `acl` | [`src/tauri/acl.zig`](../../src/tauri/acl.zig)（`Policy`） | `M4-04` 対応済み |
| `#[tauri::command]` | `zts_rpc` の `Schema` + `bind` | `M1-04` 対応済み |
| `plugin:dialog` | [`src/tauri/dialog`](../../src/tauri/) | `M4-01` 対応済み |
| `plugin:clipboard-manager` | 同上 | `M4-01` 対応済み |
| `plugin:fs` | [`src/tauri/fs/scope.zig`](../../src/tauri/fs/scope.zig) | `M4-02` 対応済み（スコープ付き） |
| `plugin:menu` / `plugin:tray` | [`src/tauri/menu`](../../src/tauri/menu/)、[`src/tauri/tray`](../../src/tauri/tray/) | `M4-03`/`M4-05`/`M4-06` 対応済み |
| `tauri build`（バンドラ） | `M5-03`（3-OS パッケージャ） | **未実装** |
| `tauri dev` | `zts dev`（`M5-02`） | **未実装**（`zig build` を直接使う） |

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
仕様の詳細は内部資料 [`../architecture/tauri-config-import-acl.md`](../architecture/tauri-config-import-acl.md)。

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
./zigw build tsgen          # examples/counter/web/bindings.gen.ts を再生成
./zigw build check-bindings # 差分があれば exit 1（CI 用）
```

`@tauri-apps/api` v2 は**無改変**で動くので、`invoke` の型付けだけ自前の
`bindings.gen.ts` に置き換えるのが最小の移行です。

## 5. フロントエンドの配信方法を選ぶ

Tauri は `devUrl` / `frontendDist` で切り替えますが、Z-Ts では**ビルド時に埋め込む**のが基本です
（`M5-01` のエンベッダ）。`dist/` をそのまま `@embedFile` するので、実行時にアセットディレクトリを
配る必要がありません。

| 移行前 | 移行後 |
|---|---|
| `"devUrl": "http://localhost:5173"` | `zig build preview`（`zts_bridge` の Live Preview） |
| `"frontendDist": "../dist"` | エンベッダで `embedded_frontend` モジュールに埋め込む |
| `tauri build` | `zig build`（`M5-03` のパッケージャは未実装。まずは単一バイナリまで） |

## 6. 移行時に踏みやすいところ

1. **`withGlobalTauri`**: Z-Ts は常に `window.__TAURI_INTERNALS__` を公開します。
   `window.__TAURI__` を前提にした古いコードは `M1-05` の互換レイヤで吸収済みです。
2. **`invoke` の戻り値**: Tauri は `Result<T, E>` を JSON で返します。Z-Ts も同じ封筒
   （`{"result": …}` / `{"error": …}`）を使うので、`try/catch` の挙動は変わりません。
3. **ACL のパススコープ**: `{ "path": "$APPDATA/db/*" }` のようなスコープは
   `Policy` が解決します。解決できない変数は**警告して拒否**（fail-closed）です。
4. **メニュー / トレイ**: predefined 項目（`Copy` / `Quit` / `Separator` …）は OS 標準の
   セレクタ（macOS）／`MF_*`（Win32）へ写されます。カスタム項目は ID で
   `WM_COMMAND` / セレクタ経由で通知されます。
5. **`tauri build` の成果物**: `.dmg` / `.msi` / `AppImage` はまだ作れません（`M5-03`）。
   単一バイナリ（`zig-out/bin/<name>`）までは `zig build` で作れます。
