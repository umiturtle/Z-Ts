# ADR-0008: 親ウィンドウ Overlay 埋め込みと「ホストがループを所有する」C ABI

- **Status**: Accepted（`M3-03`）
- **Date**: 2026-10-27
- **関連**: [`0007-windows-win32-webview2.md`](0007-windows-win32-webview2.md)、
  [`0006-macos-appkit-wkwebview-backend.md`](0006-macos-appkit-wkwebview-backend.md)、
  [`../architecture/zts-webview-backends.md`](../architecture/zts-webview-backends.md)、
  [`../tasks/M3-03-overlay-embed-c-abi.md`](../tasks/M3-03-overlay-embed-c-abi.md)

---

## 1. 背景

`zts_webview` は「自分で OS ウィンドウを作る」用途（`Engine.createWindow`）だけを想定していた。
しかし実際の組み込み先は **すでにウィンドウとイベントループを持っている**:

- SDL3 / GLFW / raylib のゲームループ（毎フレーム `present` を呼ぶ）
- 放送・配信ツールのドックパネル（Qt / WPF / AppKit のホストウィンドウ）
- 既存 GTK アプリの `GtkBox` の 1 枠、既存 Win32 アプリの子 `HWND`、既存 Cocoa アプリの `NSView`

これらは「ループをライブラリに明け渡せない」ため、`zts_webview_step(.blocking)` を内部で回す
`run()` API は使えない。`M1-06` で `zts_window_desc_t.parent_native_handle` だけは用意して
あったが、*C ABI から実際に埋め込みを成立させる* ための契約（サイズ追従・親の生存・
ポーリング API）が未定義だった。

## 2. 決定事項

### 2.1 埋め込みは「親のクライアント領域を埋める」1 つの意味だけを持つ

`parent_native_handle` を渡した瞬間から、そのウィンドウは **Overlay** とみなす:

| バックエンド | 親として受け取る型 | 子の生成 | サイズの決め方 |
|---|---|---|---|
| Linux | `GtkContainer*`（`GtkBox` / `GtkFixed` / `GtkWindow`） | `gtk_container_add(parent, webview)` | `hexpand/vexpand` + 親の allocation |
| macOS | `NSView*` | `[parent addSubview:webview]` | `webview.frame = parent.bounds` + autoresizing |
| Windows | `HWND` | `CreateWindowExW(WS_CHILD, parent)` | 親の `GetClientRect` |

- `WindowConfig.size` は **無視** される（呼び出し側が 16x16 を渡してもホストが勝つ）。
  これは `M3-03` の E2E が明示的に検証している（`initial host=640x480 child=640x480`）。
- 埋め込みウィンドウは **toplevel を 1 つも作らない**。Linux は `toplevel = null`、
  macOS は `NSWindow` を生成しない、Windows は `WS_CHILD`（`WS_EX_APPWINDOW` なし）。
- `nativeHandle()` は埋め込み時のみ **子（`GtkWidget*` / `NSView*` / `HWND`）** を返す。
  ホストはこれで `gtk_widget_get_parent()` / `[view superview]` / `GetParent()` を呼び、
  本当に自分のツリーに入ったことを **ホスト側の言語で** 証明できる（E2E がそうしている）。

### 2.2 サイズ追従は `fit_parent()` に集約する（暗黙の追従に頼らない）

GTK の `GtkBox` や Cocoa の autoresizing は「だいたい」追従するが、
`GtkFixed` / `GtkOverlay` / 自前レイアウトのホストでは追従しない。そこで
**明示的な 1 関数** を 3 バックエンドに用意した:

```
Engine.fitParent(win)                          // Zig
zts_webview_window_fit_parent(engine, win)     // C ABI
```

- 埋め込みウィンドウ: 親のクライアント領域に合わせて子をリサイズして `OK`
- toplevel ウィンドウ: `error.Unsupported` / `ZTS_WEBVIEW_ERR_UNSUPPORTED`
  （「持っていない親に合わせる」は誤用なので、黙って成功させない）

`step(.poll)` の隣で毎フレーム呼ぶ使い方と、ホストの resize ハンドラで 1 回だけ呼ぶ使い方の
両方を許す。`set_size_request` / `SetWindowPos` は同値なら early-return してチラつきを避ける。

### 2.3 ホストループ API は `zts_webview_poll()` 1 本

`zts_webview_step(engine, ZTS_STEP_POLL)` と完全に同義の薄いラッパーを C ABI の
「埋め込みの入口」として公開する。SDL3 / GLFW / Win32 `WM_TIMER` のいずれも

```c
while (running) {
    if (!zts_webview_poll(engine)) break;   /* 1 フレーム分・非ブロッキング */
    host_pump();                            /* ホスト自身のイベント処理 */
}
```

の 3 行に収まる。戻り値 `false` は「`request_quit()` 済み、または最後のウィンドウが閉じた」。

### 2.4 終了順序: 子 → エンジン → ホスト

埋め込みでは「ウィンドウの寿命」と「コンテナの寿命」が分離している。契約は:

1. `zts_webview_window_close()` は **子だけ** を破棄する（Linux は `gtk_widget_destroy(webview)`、
   macOS は `[webview removeFromSuperview]` 相当、Windows は `DestroyWindow(child)`）。
   親の `GtkContainer` / `HWND` / `NSView` には一切触らない。
2. その後もホストは生きている（`gtk_widget_get_realized` / `IsWindow(host)` / `[window isVisible]`）。
3. `zts_webview_engine_destroy()` の後にホストが自分のウィンドウを破棄する。

これを破ると「アプリのメインウィンドウが WebView と一緒に消える」という最悪のバグになるため、
`src/webview/embed_test.zig` と `examples/c_embed` の両方で検証している。

### 2.5 C ABI の実証は「純粋な C99 ホスト」で行う

Zig のテストだけでは「C から本当に使えるか」は証明できない。`examples/c_embed/main.c` は
`-std=c99 -Wall -Wextra -Werror` でコンパイルされる **Zig を 1 行も含まない** プログラムで、
3 OS それぞれのネイティブ API（GTK3 / Win32 / Objective-C ランタイム）だけを使って
ホストウィンドウを作る。macOS だけは Objective-C が必要になるが、`objc_msgSend` の
関数ポインタキャスト（Apple が文書化している純 C の作法）だけで済ませ、`.m` ファイルを
増やしていない。

## 3. 却下した代替案

| 代替案 | 却下理由 |
|---|---|
| 埋め込み専用の `Engine.createEmbedded(...)` を新設 | API が 2 系統に分裂し、`WindowConfig` の他の項目（透過・DPI・スケジュール）が二重管理になる |
| `size` を尊重してホスト内で固定サイズにする | 「ドックパネルに埋め込む」用途では常にホストが正であり、固定サイズは必ず破綻する |
| 親のリサイズをライブラリ側でフック（GTK の `size-allocate` シグナル等） | ホストのツールキットに踏み込みすぎる。`fit_parent()` の明示呼び出しならホストの裁量が残る |
| `run()`（内部ループ）を埋め込みにも提供 | ホストがループを失う＝ゲームエンジンでは致命。`poll()` 1 本に絞る |
| macOS の例だけ `.m` で書く | 「C ABI の実証」という主旨が崩れる。`objc_msgSend` で 40 行に収まる |
| `EXIT_SKIP` を 77 にして CI を終了コードで判定 | ヘッドレス開発機で `zig build test` が落ちる。**マーカー文字列で判定**すれば両立する |

## 4. 結果とトレードオフ

**実測値（Run [`#40503143705`](https://github.com/umiturtle/Z-Ts/actions/runs/40503143705)、3/3 GREEN）**

| OS | マーカー |
|---|---|
| Linux (Xvfb) | `OK c-embed host=gtk3 checks=9 structural=1 child=520x380 pong=1 frames=43` + `OK embed-gtk structural=1` |
| macOS | `OK c-embed host=cocoa checks=9 structural=1 child=520x380 pong=1 frames=197` |
| Windows | `OK c-embed host=win32 checks=9 structural=1 child=520x380 pong=1 frames=138` |

**得られたもの**
- 既存アプリ（自前ウィンドウ + 自前ループ）に 3 行で WebView を重ねられる。Zig も C++ も不要。
- 埋め込みの正しさを **ホスト側の API** で検証できる（`gtk_widget_get_parent` / `GetParent` /
  `[view superview]`）ので、「ライブラリがそう言っている」以上の証明になる。
- `embed_test.zig` の Mock 契約テスト 4 本が全 OS の CI で走り、GTK 実装は Xvfb で構造まで検証。

**受け入れたコスト**
- 埋め込み時の DPI はホストのスケーリングに従う（Windows は子 HWND の DPI を
  `GetDpiForWindow` で取得し直すが、ホストが `SetThreadDpiAwarenessContext` を切り替えると
  追従できない）。
- `fit_parent()` はポーリングではなく明示呼び出しなので、ホストがリサイズを検知して呼ぶ責任を持つ
  （`GtkBox` / autoresizing NSView は暗黙に追従するので、実質的に必要なのは固定レイアウトのホストだけ）。
- Linux の `gtk_container_add` は `GtkBox` では `expand=TRUE` になるが、`GtkWindow` 直挿しは
  1 子までという GTK の制約をそのまま受ける。
- C の例は `EXIT_SKIP`（=0）で終わるため、**CI は必ずマーカーで判定する** 約束を守る必要がある。
  この約束は `ci.yml` の 3 箇所のゲートで機械化してある。
