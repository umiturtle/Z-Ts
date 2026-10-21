# Tauri v2 の使い方リファレンス（開発者 API 全体像）

このドキュメントは、上流リファレンス（`vendor/tauri`）に基づき、**Tauri アプリケーションがどのように構成され、バックエンド（Rust）とフロントエンド（JS/TS）からどの API が使われるか**を整理したリファレンスです。`Z-Ts`（Zig 版）の公開 API 設計および互換性設計の基準となります。

---

## 1. 標準的な Tauri v2 プロジェクト構成

```text
my-tauri-app/
├── package.json
├── index.html / src/                 # Web フロントエンド（Vite / React / Svelte / Vanilla TS 等）
└── src-tauri/                        # ネイティブバックエンド
    ├── Cargo.toml                    # `tauri` (runtime) + `tauri-build` (build-dep)
    ├── build.rs                      # `tauri_build::build()` を呼ぶコンパイル時フック
    ├── tauri.conf.json               # アプリ識別子・ウィンドウ設定・バンドル設定・CSP 設定
    ├── capabilities/                 # Tauri v2 の権限設定（最小権限 ACL）
    │   └── default.json              # どのウィンドウにどのコマンド権限・スコープを与えるか
    ├── icons/                        # 各 OS 用アプリアイコン
    └── src/
        └── main.rs (または lib.rs)    # コマンド定義・State 登録・Builder 起動
```

---

## 2. バックエンド API の使い方（Rust 側：`crates/tauri`）

### 2.1 最小構成と Builder パイプライン

参照: `vendor/tauri/bench/tests/helloworld/src-tauri/src/main.rs`, `vendor/tauri/crates/tauri/src/app.rs`

```rust
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

fn main() {
    tauri::Builder::default()
        .manage(MyAppState::default())                       // 1. グローバル共有 State の登録
        .plugin(my_plugin::init())                           // 2. プラグインの登録
        .setup(|app| {                                       // 3. 起動時初期化フック（ウィンドウ生成等）
            let main_win = app.get_webview_window("main").unwrap();
            main_win.set_title("My App")?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![greet])     // 4. フロントエンド公開コマンドのルーター登録
        .run(tauri::generate_context!())                     // 4. コンパイル時生成 Context を渡してイベントループ開始
        .expect("error while running tauri application");
}
```

### 2.2 コマンド定義（`#[tauri::command]`）の多彩なシグネチャ

参照: `vendor/tauri/crates/tauri/src/ipc/command.rs`

Tauri のコマンド関数は、**フロントエンドから渡される JSON 引数** と **ランタイムが自動注入するコンテキスト引数** を任意の順序で混在させることができます。

```rust
use tauri::{AppHandle, State, WebviewWindow, ipc::{Channel, Request, Response}};

// 1. 同期コマンド + エラーハンドリング (Result<T, E> where E: Serialize / Into<InvokeError>)
//    引数名はデフォルトで JS 側の camelCase (`userId`) から Rust の snake_case (`user_id`) へ自動変換される
#[tauri::command]
fn get_user(user_id: u64, state: State<'_, DbPool>) -> Result<User, String> {
    state.find_user(user_id).map_err(|e| e.to_string())
}

// 2. 非同期コマンド（async fn: Tokio ランタイム上で非ブロッキング実行）+ Window / AppHandle 自動注入
#[tauri::command]
async fn heavy_task(
    url: String,
    app: AppHandle,
    window: WebviewWindow,
    on_progress: Channel<u8>,   // Rust → JS へのリアルタイムストリーム送信用チャネル
) -> Result<Vec<u8>, String> {
    on_progress.send(50).map_err(|e| e.to_string())?;
    let bytes = download(&url).await?;
    window.emit("download-complete", bytes.len()).ok();
    on_progress.send(100).map_err(|e| e.to_string())?;
    Ok(bytes)
}

// 3. ゼロオーバーヘッド生バイナリ送受信（JSON シリアライズを通さない高速経路）
#[tauri::command]
fn transform_binary(req: Request<'_>) -> Response {
    let raw_bytes: &[u8] = match req.body() {
        tauri::ipc::InvokeBody::Raw(bytes) => bytes,
        _ => &[],
    };
    Response::new(raw_bytes.to_vec()) // Content-Type: application/octet-stream で JS へ ArrayBuffer 返却
}
```

#### コマンド引数として自動注入可能な主な型（JS 側からの指定不要）
- `AppHandle<R>`: アプリ全体の操作ハンドル（`Clone` + `Send` + `Sync`、別スレッドへ移動可能）
- `Window<R>` / `Webview<R>` / `WebviewWindow<R>`: 呼び出し元のウィンドウ・WebView インスタンス
- `State<'_, T>`: `.manage(T)` で登録された型 `T` への参照（内部は `TypeId` をキーにしたスレッドセーフマップ）
- `tauri::ipc::Request<'_>`: 生の HTTP ライクなヘッダとボディ（`InvokeBody::Json` / `InvokeBody::Raw`）
- `tauri::ipc::CommandScope<T>` / `GlobalScope<T>`: ACL（Capabilities）で許可されたスコープ条件（許可パス一覧など）

### 2.3 イベントシステム（双方向 Pub/Sub）

コマンド（`invoke`）が「JS 主導の 1:1 RPC（リクエスト・レスポンス）」であるのに対し、イベントは「任意のタイミングでの 1:N ブロードキャスト / ターゲット送信」です。

```rust
use tauri::{Emitter, Listener};

// バックエンド → 全 WebView へ送信
app.emit("update-available", Payload { version: "1.2.0" })?;

// バックエンド → 特定ウィンドウ/WebView のみへ送信
app.emit_to("settings-window", "theme-changed", "dark")?;

// フロントエンドや他コンポーネントからのイベントを購読
let id = app.listen("user-logged-out", |event| {
    println!("payload: {}", event.payload());
});
app.unlisten(id);
```

### 2.4 `Manager` トレイトと `ResourceTable`

- **`Manager<R>`**: `App`, `AppHandle`, `Window`, `Webview`, `WebviewWindow` が共通実装するトレイト。どこからでも `.manage()`, `.state::<T>()`, `.try_state::<T>()`, `.get_webview_window("label")`, `.path()`（OS 標準ディレクトリ解決）を呼び出せる。
- **`ResourceTable`**: Rust 側の非シリアライズオブジェクト（ファイルハンドル・ソケット・DB カーソル・画像等）を **連番の整数 ID（`ResourceId = u32`）** として保持し、JS 側には `rid` 数値だけを渡して操作・解放（`plugin:resources|close`）させる仕組み。**Zig 移植においてもポインタを直接 JS に露出させない安全なハンドルテーブルとしてそのまま有効なパターンです。**

### 2.5 プラグイン作成 API（`tauri::plugin::Builder`）

```rust
pub fn init<R: Runtime>() -> TauriPlugin<R> {
    tauri::plugin::Builder::new("my-store")
        .invoke_handler(tauri::generate_handler![get_item, set_item])
        .js_init_script("window.__MY_STORE_READY__ = true;")
        .setup(|app, api| {
            app.manage(StoreState::default());
            Ok(())
        })
        .on_navigation(|webview, url| {
            url.scheme() != "malicious" // false を返すとナビゲーションをブロック
        })
        .build()
}
```
プラグイン内のコマンドは自動的に **`"plugin:<plugin-name>|<command-name>"`**（例: `"plugin:my-store|get_item"`）という名前空間でルーティングされます。

---

## 3. フロントエンド API の使い方（JS/TS 側：`@tauri-apps/api`）

参照: `vendor/tauri/packages/api/src/`

```typescript
import { invoke, Channel, convertFileSrc } from '@tauri-apps/api/core';
import { listen, emit } from '@tauri-apps/api/event';
import { getCurrentWindow } from '@tauri-apps/api/window';

// 1. コマンド呼び出し（JSON 引数 → 型付きレスポンス）
const user = await invoke<User>('get_user', { userId: 42 });

// 2. バイナリ送信（Uint8Array / ArrayBuffer を直接渡すと application/octet-stream 送信になる）
const echoed = await invoke<ArrayBuffer>('transform_binary', new Uint8Array([1, 2, 3, 4]));

// 3. ストリーミング受信（Channel）
const progress = new Channel<number>((pct) => {
  console.log(`Progress: ${pct}%`);
});
await invoke('heavy_task', { url: 'https://example.com/file.bin', onProgress: progress });

// 4. イベント購読・発火
const unlisten = await listen<{ version: string }>('update-available', (event) => {
  console.log(event.payload.version);
});
await emit('user-logged-out', { reason: 'manual' });
unlisten();

// 5. ネイティブウィンドウ操作（内部では `plugin:window|...` IPC コマンドが呼ばれる）
const win = getCurrentWindow();
await win.setTitle('Updated from TypeScript');
await win.minimize();

// 6. ローカルファイルパスを WebView 表示用 URI (`asset://localhost/...`) へ変換
const imgUrl = convertFileSrc('/path/to/photo.png');
```

---

## 4. 設定ファイルとセキュリティ（`tauri.conf.json` & Capabilities）

1. **`tauri.conf.json`**:
   - `identifier`: アプリ固有の逆ドメイン識別子（例: `"com.example.app"`）
   - `build`: `devUrl`（例: `"http://localhost:5173"`）、`frontendDist`（例: `"../dist"`）、`beforeDevCommand` / `beforeBuildCommand`
   - `app.windows`: 初期ウィンドウ配列（`label`, `title`, `width`, `height`, `resizable`, `transparent`, `decorations`, `url` 等）
   - `app.security`: `csp`（Content Security Policy）、`pattern`（`"brownfield"` デフォルト または `"isolation"` 暗号化 iframe モード）、`assetProtocol`
   - `bundle`: インストーラ生成設定（Linux `.deb` / `.rpm` / `AppImage`、macOS `.app` / `.dmg`、Windows `.msi` / NSIS `.exe`）
2. **Capabilities（`src-tauri/capabilities/*.json` — Tauri v2 の特徴）**:
   - **デフォルト拒否（Deny by default）**: 明示的に許可されていない組み込みプラグインコマンドやリモート URL からの IPC 呼び出しは `RuntimeAuthority` によってブロックされる。
   - ウィンドウごとに「どの権限（例: `"core:window:allow-set-title"`, `"fs:allow-read-text-file"`）とどの引数スコープ（例: `"$APPDATA/**"`）を許可するか」を宣言的に記述する。
