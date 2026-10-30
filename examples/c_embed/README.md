# `examples/c_embed` — 既存アプリへの Overlay 埋め込み（純粋な C99）

`zts_webview` を **Zig を使わない純粋な C99 プログラム**から使い、自分のウィンドウの
**子として** WebView を重ねるサンプルです（`M3-03`）。ゲームエンジン（SDL3 / GLFW）、
放送用ツール、エディタのドックパネルなど「すでに自前のウィンドウとイベントループを持っている」
ホストへ組み込む形をそのまま再現しています。

## 何を証明しているか

| 検証 | 方法 |
|---|---|
| C ABI だけで完結する | `#include "zts_webview.h"` + `libzts_webview` をリンクするだけ（Zig のコードは 0 行、このファイルは C99） |
| **Overlay 埋め込み** | ホストが `GtkBox` / 子 `HWND` / `NSView` を作り、`zts_window_desc_t.parent_native_handle` に渡す |
| ホストのレイアウトが優先される | `desc.width/height = 16x16` と小さく指定しても、WebView は**ホストのクライアント領域**を埋める |
| 構造的な証明 | 子の親をホスト側 API で確認（`gtk_widget_get_parent` / `GetParent` / `[view superview]`） |
| ホストがループを所有する | 毎フレーム `zts_webview_poll()` → 自分のポンプ（`gtk_main_iteration_do` / `PeekMessage`） |
| ホストリサイズに追従 | `zts_webview_window_fit_parent()`（GTK の `size_request` / `SetWindowPos` / `setFrame:`） |
| 後片付けが安全 | 埋め込み側だけを閉じても、ホストウィンドウは生きたまま |

成功時は次の 1 行を出力します（CI はこのマーカーをゲートにしています）:

```text
OK c-embed host=gtk3|win32|cocoa checks=9 structural=1 child=520x380 pong=42 frames=…
```

ディスプレイや WebView2 ランタイムが無い環境では `SKIP c-embed …` を出して終了コード 0 で
終わります（`zig build test` をヘッドレス開発機でも緑に保つため）。**CI は終了コードではなく
`OK c-embed` の有無で判定**するので、無言スキップが成功扱いになることはありません。

## 実行

```bash
# Linux（GTK3 + WebKit2GTK、仮想ディスプレイでも可）
bash scripts/setup-toolchains.sh --sysroot
./zigw build                                  # zig-out/bin/zts_c_embed
xvfb-run -a ./zig-out/bin/zts_c_embed

# macOS（Cocoa / WKWebView）
./zigw build && ./zig-out/bin/zts_c_embed

# Windows（Win32 + WebView2、Evergreen ランタイム必須）
zig build && .\zig-out\bin\zts_c_embed.exe
```

`zig build test` はこのサンプルを自動でビルド & 実行します（3 OS の CI も同じ経路）。

## コードの読み方（`main.c`）

1. `host_create()` — ホスト側のウィンドウと**コンテナ**を作る（これが「既存アプリ」）。
2. `zts_webview_engine_create(ZTS_WEBVIEW_BACKEND_NATIVE, &engine)` — WebView エンジン。
3. `zts_webview_window_create()` に `parent_native_handle = コンテナ` を渡す → 埋め込み完了。
4. `while (!reported) { zts_webview_poll(engine); host_pump(&host); }` — **ホストのループ**。
5. `zts_webview_window_fit_parent()` — ホストがリサイズしたときの追従。
6. `zts_webview_window_close()` → ホストは生きたまま → `zts_webview_engine_destroy()`。

スキームハンドラ（`on_scheme`）は `tauri://localhost/index.html` に HTML を返し、
ページは同一オリジンの `fetch('/ping')`（WebView2 では `http://tauri.localhost/ping`）で
往復してから `window.__ztsPostMessage()` で C 側へ報告します。
