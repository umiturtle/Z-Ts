# `zts_webview` バックエンド契約（Linux / macOS / Windows / Mock）

`zts_webview` は「OS ウィンドウ + WebView」だけを提供する **standalone モジュール**です
（JSON / RPC / Tauri 非依存）。4 つの実装が **同じメソッド面** を持ち、`Engine` の
`union(enum)` が実行時に 1 つを選びます。

| バックエンド | ファイル | 実体 | 有効条件 |
|---|---|---|---|
| Linux GTK | `src/webview/linux.zig` + `gtk_bindings.zig` | GTK3 + WebKit2GTK 4.1 | `builtin.os.tag == .linux` かつ `enable_gtk` |
| macOS | `src/webview/macos.zig` + `macos_shim.m` | `NSApplication` + `WKWebView` | `.macos` かつ `enable_macos` |
| Windows | `src/webview/windows.zig` + `win32.zig` + `webview2_*` | `HWND` + Direct WebView2 | `.windows` かつ `enable_windows` |
| HeadlessMock | `src/webview/mock.zig` | メモリのみ | 常に（無条件でビルドされる） |

`Engine.init(.auto)` は「ネイティブ → 失敗したら `DisplayUnavailable` を握って `HeadlessMock`」へ
フォールバックします。したがって *どのプラットフォームでも `Engine` は必ず 1 つ返る*。

---

## 1. メソッド面（全バックエンドが満たす契約）

ライフサイクル / イベントループ:

- `deinit()`, `step(StepMode) bool`, `wakeup()`, `requestQuit()`
- `step(.blocking)` は最大 1 秒待って**必ず戻る**（`MsgWaitForMultipleObjectsEx(…, 1000, …)` /
  `g_main_context_iteration(ctx, TRUE)` / `nextEventMatchingMask:untilDate:[NSDate +1s]`）
- `step(.poll)` は**絶対にブロックしない**（ホストのフレームループから毎フレーム呼べる）

スキーム & メッセージ:

- `registerScheme(name, SchemeHandler)`, `setMessageHandler`, `setCloseHandler`
- `completeRequest(request_id, SchemeResponse)` は **どのスレッドからでも安全**
  （STA へは内部キュー + `wakeup` で戻す）
- `preflightCount()`（macOS / Windows）、`runtimeVersion()`（Windows）

ウィンドウ:

- `createWindow(WindowConfig) WindowId`, `closeWindow`, `nativeHandle`
- `fitParent(win)`（`M3-03`、下記）
- `setTitle` / `setSize` / `setMinSize` / `setMaxSize` / `setPosition` / `setResizable` /
  `setMinimized` / `setMaximized` / `setFullscreen` / `setVisible` / `setDecorations` /
  `setAlwaysOnTop` / `setFocus` / `startDrag`

DOM:

- `addInitScript` / `evalJs` / `navigate` / `loadHtml` / `openDevtools`

---

## 2. Overlay 埋め込み契約（`M3-03`）

`WindowConfig.parent_native_handle` に既存のコンテナを渡すと、そのウィンドウは **子** になる。

| 項目 | 契約 |
|---|---|
| 受け取る型 | Linux: `GtkContainer*` / macOS: `NSView*` / Windows: 親 `HWND` |
| 生成物 | **toplevel を作らない**（GTK は `toplevel = null`、Cocoa は `NSWindow` なし、Win32 は `WS_CHILD`） |
| サイズ | `WindowConfig.size` は無視。**親のクライアント領域**を埋める |
| `nativeHandle()` | 埋め込み時のみ **子**（`GtkWidget*` / `WKWebView*` / 子 `HWND`）を返す |
| `fitParent()` | 埋め込み時: 親のクライアント領域に合わせて `OK` / toplevel: `error.Unsupported` |
| `closeWindow()` | 子だけを破棄する。**親には触らない** |
| `step()` | 最後のウィンドウが閉じた、または `requestQuit()` で `false` |

### 2.1 ホストがループを所有する

```c
zts_webview_engine_t *engine = NULL;
zts_webview_engine_create(ZTS_WEBVIEW_BACKEND_NATIVE, &engine);
zts_webview_register_scheme(engine, "tauri", on_scheme, &state);
zts_webview_set_message_handler(engine, on_message, &state);

zts_window_desc_t desc = {0};
desc.title = "overlay";
desc.width = 16; desc.height = 16;          /* 親が勝つので意味はない */
desc.visible = true;
desc.parent_native_handle = host_container;  /* GTK / NSView / HWND */
desc.initial_url = "tauri://localhost/index.html";
zts_window_id_t win = 0;
zts_webview_window_create(engine, &desc, &win);

while (running) {
    if (!zts_webview_poll(engine)) break;    /* 1 フレーム・非ブロッキング */
    host_pump();                             /* ホスト自身のイベント処理 */
    if (host_resized) zts_webview_window_fit_parent(engine, win);
}

zts_webview_window_close(engine, win);       /* 子だけ消える */
zts_webview_engine_destroy(engine);          /* 最後にホストが自分の窓を閉じる */
```

完全なサンプル: [`../../examples/c_embed/main.c`](../../examples/c_embed/main.c)（純粋な C99、
3 OS で CI 実行）。契約の単体テスト: `src/webview/embed_test.zig`。

### 2.2 ホスト側から埋め込みを検証する

`nativeHandle()` が子を返すので、ホストは自分のツールキットの API で配置を証明できる:

| OS | 検証 |
|---|---|
| Linux | `gtk_widget_get_parent((GtkWidget *)h) == host_container` |
| macOS | `[view superview] == host_container` |
| Windows | `GetParent((HWND)h) == host_container` |

CI の `OK c-embed` マーカーはこの検証を含む（`structural=1`）。

---

## 3. スキーム URL の正規化

WebView2 は `tauri://` を解釈できないため、Windows だけ `http://tauri.localhost` に書き換える
（`windows_util.classifyVirtualOrigin`）。ページの作者は `tauri://localhost/...` と書けば、
3 OS すべてで同じ HTML が動く。**相対 URL（`fetch('/ping')`）は全バックエンドで同一オリジン**
になるので、CORS を考えずに済む（クロスオリジンになるのは `ipc://` を明示したときだけ）。

---

## 4. テスト戦略

| 層 | どこで走るか |
|---|---|
| Mock 契約テスト（`embed_test.zig` の 4 本） | 全 OS の CI + `./zigw quick-test` |
| GTK 実埋め込み（`OK embed-gtk structural=1`） | Linux CI（Xvfb） |
| macOS E2E（`OK macos-wk checks=10 …`） | macOS CI |
| Windows E2E（`OK windows-wv2 checks=19 …`） | Windows CI（Evergreen 導入後） |
| C ABI 純 C ホスト（`OK c-embed host=…`） | 3 OS CI |
| クロスコンパイル（単一 `.exe`） | Linux CI（`-Dtarget=x86_64-windows-gnu`） |

**マーカーが無い = 失敗**。ヘッドレス環境でのスキップは終了コード 0 のまま `SKIP …` を出し、
CI は必ず `OK …` を grep する（無言スキップを成功と誤認しないため）。
