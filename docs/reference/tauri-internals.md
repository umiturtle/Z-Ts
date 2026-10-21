# Tauri v2 内部実装の完全解剖（上流コード解説 & Zig 移植指針）

このドキュメントは、`vendor/tauri`・`vendor/wry`・`vendor/tao` の実ソースコードを直接精読して解明した **Tauri v2 の内部アーキテクチャ・IPC ワイヤープロトコル・マクロ展開・OS ネイティブ層の仕組み** と、それを **Zig (`0.17.0`) でどう再設計すべきか** をまとめた技術バイブルです。

---

## 1. クレート全体階層と最大の構造的特徴

```text
[アプリコード (main.rs / tauri.conf.json / capabilities/*.json)]
        │
        ▼  (コンパイル時: tauri-build / tauri-codegen / tauri-macros)
[crates/tauri]  ─── コアオーケストレータ（AppManager, StateManager, RuntimeAuthority, 10個の内部Plugin）
        │
        ├──► [crates/tauri-utils]       ─── 設定スキーマ, ACL/Scope 解決, HTML/CSP 書き換え, Embedded Assets
        │
        └──► [crates/tauri-runtime]     ─── GUI バックエンド抽象トレイト (Runtime, Dispatcher, WindowDispatch)
                    │
                    ▼
        [crates/tauri-runtime-wry]      ─── Wry + Tao を結びつけ メインスレッド EventLoop と通信する実装層
              │               │
              ▼               ▼
        [vendor/wry]    [vendor/tao]
        WebView 制御     Window & EventLoop 制御
        ├─ webkit2gtk   ├─ GTK3 / GDK / X11 (Linux)
        ├─ WKWebView    ├─ AppKit / Cocoa   (macOS)
        └─ WebView2     └─ Win32 WndProc    (Windows)
```

### 移植上もっとも重要な発見：コア API すらすべて「内部プラグイン」である

`vendor/tauri/crates/tauri/src/app.rs`（1259〜1269行目、2581行目）を確認すると、Tauri 本体の機能群は特別扱いされておらず、`Builder::build()` 時に以下の **10 個のビルトイン `Plugin` として `PluginStore` に登録** されています：

1. `path` (`plugin:path|...`) — OS ディレクトリパス解決・結合
2. `event` (`plugin:event|listen`, `emit`, `unlisten` 等) — イベント Pub/Sub
3. `window` (`plugin:window|set_title`, `minimize`, `close` 等) — ウィンドウ操作
4. `webview` (`plugin:webview|...`) — WebView 操作・ズーム・再描画
5. `app` (`plugin:app|version`, `name` 等) — アプリメタ情報・表示制御
6. `resources` (`plugin:resources|close`) — `ResourceTable` ハンドルの解放
7. `image` (`plugin:image|new`, `from_bytes` 等) — アイコン・画像バッファ管理
8. `menu` (`plugin:menu|...`) — ネイティブメニューバー・コンテキストメニュー
9. `tray` (`plugin:tray|...`) — システムトレイアイコン
10. `__TAURI_CHANNEL__` (`plugin:__TAURI_CHANNEL__|fetch`) — 大容量 Channel データ取得

> **Zig 移植への示唆**:
> **「IPC ルーター + `Plugin` インターフェース + `ResourceTable` + ACL 認可器」** の核さえ完成すれば、上記 9〜10 個のサブシステムは **完全に独立したモジュールとして複数エージェントで並列実装できる** ことを意味します。

---

## 2. コンパイル時パイプラインの内部実装

### 2.1 `tauri-build` & `tauri-codegen`（`tauri::generate_context!()`）
1. `tauri.conf.json` と `capabilities/*.json`、各プラグインの `permissions/*.toml` をコンパイル時に読み込む。
2. `Resolved::resolve(...)` によって許可・拒否コマンド表と Glob スコープ表を事前解決し、Rust の構造体リテラルコードとしてバイナリに直接埋め込む。
3. 本番ビルド時は `frontendDist` 配下の全静的ファイル（HTML/JS/CSS/画像）を走査し、HTML 内のインラインスクリプトハッシュや `__TAURI_SCRIPT_NONCE__` トークンを処理した上でバイト列をバイナリに埋め込む。

### 2.2 `#[tauri::command]` と Autoref Specialization（`tauri-macros` & `ipc/command.rs`）
Rust には関数の戻り値型や `async` 有無に対するオーバーロード・型リフレクションがないため、Tauri 本家は非常に複雑なマクロ技法を使っています：
1. `#[tauri::command] fn foo(user_id: u32, state: State<'_, S>) -> Result<Out, Err>` に対し、裏で隠しマクロ `__cmd__foo!` と `__tauri_command_name_foo!` を生成する（`tauri-macros/src/command/wrapper.rs`）。
2. 各引数は `CommandArg::from_command(CommandItem { plugin, name: "foo", key: "userId", message, acl })` に変換される：
   - `State` / `Window` / `Webview` / `AppHandle` / `Request` には専用の `CommandArg` 実装があり、`message` から直接取り出される。
   - 通常のデータ型 `T: Deserialize` はブランケット実装により `message.payload` の JSON オブジェクトからキー `"userId"`（デフォルト `camelCase` 変換）を `serde_json` でデシリアライズする。
3. 戻り値（`T` か `Result<T, E>` か × JSON か `Response` 生バイトか）の分岐には、**dtolnay 氏の Autoref-based Specialization**（`(&result).blocking_kind()` / `(&result).async_kind()` のメソッド解決優先順位差を利用する裏技）が使われている。
4. さらに `tauri::generate_handler![foo, bar]` は、ACL で一度も許可されていない未使用コマンドをコンパイル時に自動で剥がす DCE（Dead Code Elimination）も行う（`handler.rs`）。

> **Zig 移植での圧倒的アドバンテージ**:
> Rust が数千行の proc-macro と Autoref トリックで苦心しているこの全工程が、**Zig `0.17.0` では外部マクロゼロ・標準の `comptime` 型リフレクション（`@typeInfo(@TypeOf(func)).@"fn"`）数十行だけで完全に型安全かつ超高速コンパイルで実現できます**（戻り値がエラーユニオン `@typeInfo(Ret) == .error_union` かどうか、引数が `Context` / `State(T)` / `Window` か一般 JSON 型かを `comptime` の `inline for` で分岐するだけ！）。

---

## 3. IPC ワイヤープロトコル完全仕様（JS ⇔ Native）

参照:
- JS 側: `vendor/tauri/crates/tauri/scripts/{core.js, ipc.js, ipc-protocol.js, process-ipc-message-fn.js}`
- Rust 側: `vendor/tauri/crates/tauri/src/ipc/{protocol.rs, mod.rs, channel.rs, authority.rs}`

WebView 生成時、`DocumentStart`（ページの HTML/JS が 1 行でも動く前）に初期化スクリプトが注入され、`window.__TAURI_INTERNALS__` オブジェクトとワンタイム秘密鍵 `__TAURI_INVOKE_KEY__`（クロージャ内に隠蔽）がセットアップされます。

### 3.1 リクエスト送信の 2 経路（Custom Protocol 優先 + `postMessage` フォールバック）

Tauri v2 の大きな進化点は、v1 の文字列 `postMessage` ベースから **「カスタム URI スキームに対する `fetch()` POST リクエスト」** がプライマリ経路になったことです（これにより巨大なバイナリデータも JSON 文字列化せずそのまま送受信できます）。

#### 経路 A（プライマリ）：Custom Protocol HTTP POST
- **URL**:
  - Linux (`webkit2gtk`) / macOS (`WKWebView`) / iOS: `ipc://localhost/<encoded_cmd>`
  - Windows (`WebView2`) / Android: `http://ipc.localhost/<encoded_cmd>`（または `https://ipc.localhost/...`）
- **HTTP Method**: `POST`（CORS プリフライト用の `OPTIONS` にも応答する）
- **リクエストヘッダ**:
  - `Content-Type`: `application/json` または `application/octet-stream`（ペイロードが `ArrayBuffer` / `TypedArray` / `number[]` の場合）
  - `Tauri-Callback`: 成功時に解決する Promise 用コールバック数値 ID（`crypto.getRandomValues` で採番）
  - `Tauri-Error`: 失敗時に reject する Promise 用コールバック数値 ID
  - `Tauri-Invoke-Key`: 起動時にネイティブ側が発行・注入した秘密トークン文字列（一致しないリクエストは不正フレームからの偽装として即拒否！）
- **レスポンス（ネイティブ → JS `fetch` Promise 直結）**:
  - ステータス `200 OK` + CORS ヘッダ `Access-Control-Allow-Origin: *`, `Access-Control-Expose-Headers: Tauri-Response`
  - `Tauri-Response`: 成功なら `"ok"`、コマンドエラーなら `"error"`
  - `Content-Type`: `application/json` / `text/plain` / `application/octet-stream`
  - JS 側は `response.headers.get('Tauri-Response')` を見て `callback` か `error` の ID を選び、`window.__TAURI_INTERNALS__.runCallback(id, body)` を呼んで `invoke()` の Promise を完了させる（**つまり `eval()` すら不要で HTTP レスポンスとしてそのまま返る！**）。

#### 経路 B（フォールバック）：`window.ipc.postMessage(...)` + `webview.eval(...)`
- Android（WebView API の制約でカスタムプロトコルリクエストの POST ボディを読めない）や、CSP 等で `fetch('ipc://...')` が失敗した場合は、自動的に `customProtocolIpcFailed = true` へ切り替わり、`window.ipc.postMessage(serialized)` で送信し、ネイティブ側が完了時に WebView の JS 評価 API（`eval`）で `window.__TAURI_INTERNALS__.runCallback(...)` を呼び返す。

### 3.2 `Channel<T>` ストリーミングの 2 段階高速配送（`ipc/channel.rs`）

バックエンドからフロントエンドへ連続データを送る `Channel::send` は、データサイズに応じて賢く経路を切り替えています：
1. **小〜中サイズ（JSON ≤ 8,192 bytes / Raw ≤ 1,024 bytes）**: WebView の `eval` で直接 JS コールバックへ即時プッシュ（`fetch` ラウンドトリップを節約）。
2. **大容量データ（> 8KB JSON / > 1KB バイナリ）**: ネイティブ側の `ChannelDataIpcQueue` に一時格納して連番 ID だけを JS に通知し、JS 側が `plugin:__TAURI_CHANNEL__|fetch`（Custom Protocol GET/POST）で生バイト列を引き取りに行く。
3. 各メッセージには送信順の連番 `index` が付与されており、JS 側で追い越しが起きても必ず送信順に並び替えて `onmessage` に渡す。

### 3.3 セキュリティ多層防御

1. **Brownfield パターン vs Isolation パターン（`scripts/ipc.js`）**:
   - デフォルト（`brownfield`）はそのまま `sendIpcMessage` を呼ぶ。
   - 高セキュリティ用の `isolation` パターンでは、別オリジンの隠し `<iframe id="__tauri_isolation__">` 内に WebCrypto `AES-GCM` 鍵を持ち、全 IPC ペイロードを暗号化・検証してからネイティブ側へ渡す。
2. **`RuntimeAuthority`（`src/ipc/authority.rs`）**:
   - IPC 到達時、コマンド関数を実行する前に必ず **`(コマンド名, 呼び出し元 WebView ラベル, 現在の URL Origin [Local or Remote])`** の組を検査し、拒否リスト（Deny 優先）および許可リスト（Allow）に合致しなければ実行前にエラーを返す。

---

## 4. スレッドモデルと OS ネイティブ層（`tauri-runtime-wry` / `wry` / `tao`）

### 4.1 GUI メインスレッド制約とメッセージパッシング
Linux (GTK3)、macOS (AppKit)、Windows (Win32/WebView2) のいずれも、**ウィンドウや WebView の作成・操作 API はメインスレッド（イベントループスレッド）からしか安全に呼べない** という強い OS 制約があります。

そのため `tauri-runtime-wry` は以下の設計をとっています：
- メインスレッドが `tao::event_loop::EventLoop<Message>` を回す。
- ワーカースレッドや非同期コマンドが持つ `AppHandle` / `Window` ハンドルは、実ポインタではなく **`EventLoopProxy<Message>`（スレッドセーフな起床キュー）** を保持する。
- 別スレッドから `window.set_title(...)` や `webview.eval(...)` が呼ばれると、`Message` enum をプロキシ経由でメインループへ送り（Linux なら `glib::MainContext::invoke`、macOS なら `CFRunLoop` / GCD main queue、Windows なら `PostMessageW`）、メインスレッド側で実際の OS API を実行し、必要なら `mpsc::channel` で結果を呼び出し元スレッドへ返す。

### 4.2 各 OS バックエンドが実際に呼んでいるネイティブ API（Z-Ts L1/L2 実装対象）

| OS | Window / EventLoop (`vendor/tao`) | WebView / IPC / Custom Protocol (`vendor/wry`) |
|---|---|---|
| **Linux** | **GTK 3 (`libgtk-3.so`) + GDK + GLib**<br>- `gtk_init_check`, `GtkApplication` / `GtkWindow`<br>- `GtkBox` コンテナ配置、X11/Wayland ハンドル管理 | **WebKit2GTK 4.1 (`libwebkit2gtk-4.1.so`) + JavaScriptCoreGTK**<br>- `webkit_web_context_register_uri_scheme`（`ipc://`, `asset://`, `tauri://` 登録 & `WebKitURISchemeRequest` で非同期レスポンス返却）<br>- `WebKitUserContentManager`: `webkit_user_content_manager_add_script`（`DocumentStart` 注入）& `"script-message-received::ipc"` シグナル接続<br>- `webkit_web_view_evaluate_javascript`（JS 評価） |
| **macOS** | **AppKit / Objective-C Runtime (`libobjc.dylib`)**<br>- `NSApplication`, `NSWindow`, `NSView`, `NSEvent` | **WebKit (`WKWebView`)**<br>- `WKWebViewConfiguration.setURLSchemeHandler(_:forURLScheme:)`（`WKURLSchemeTask` で非同期返却）<br>- `WKUserContentController`: `addUserScript` & `add(_:name: "ipc")` (`WKScriptMessageHandler`)<br>- `evaluateJavaScript(_:completionHandler:)` |
| **Windows** | **Win32 API (`user32.dll`, `gdi32.dll`, `shcore.dll`)**<br>- `RegisterClassExW`, `CreateWindowExW`, Per-Monitor DPI v2, `GetMessageW` / `DispatchMessageW` | **WebView2 COM API (`ICoreWebView2`)**<br>- `CreateCoreWebView2EnvironmentWithOptions`<br>- `AddWebResourceRequestedFilter("http://ipc.localhost/*", ...)` + `add_WebResourceRequested`<br>- `AddScriptToExecuteOnDocumentCreated`, `add_WebMessageReceived`, `ExecuteScript` |
