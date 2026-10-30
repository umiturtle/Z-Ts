# ADR-0009: poll 駆動スクリーンショット API と 3-OS 回帰ギャラリー

- **Status**: Accepted（`M5-04`）
- **Date**: 2026-10-27
- **関連**: [`0008-overlay-embedding-and-c-abi.md`](0008-overlay-embedding-and-c-abi.md)、
  [`0007-windows-win32-webview2.md`](0007-windows-win32-webview2.md)、
  [`0006-macos-appkit-wkwebview-backend.md`](0006-macos-appkit-wkwebview-backend.md)、
  [`../architecture/zts-webview-backends.md`](../architecture/zts-webview-backends.md)、
  [`../environment/github-actions.md`](../environment/github-actions.md)、
  [`../tasks/M5-04-ci-screenshot-matrix.md`](../tasks/M5-04-ci-screenshot-matrix.md)

---

## 1. 背景

`M3-03` までで「3 OS のネイティブウィンドウが起動し、DOM が動き、C ABI が往復する」ことは
マーカー文字列で検証できていた。しかし検証できていなかったのは **「実際に何が描かれたか」** である:

- E2E は `document.title` や `evalJs` の戻り値しか見ていないため、**真っ白な画面**でも通る。
  `windows-latest` の WebView2 は初回起動が数秒遅く、まさにこの穴に落ちた（後述 §4.1）。
- ダークテーマ・CJK フォント・スクロール位置・HiDPI スケーリング・Overlay 埋め込みは
  「数値」では表現できず、**画像でしか回帰検出できない**。
- 手元の Linux ヘッドレス環境（`DISPLAY` 無し）では GTK の実描画ができず、macOS / Windows は
  クロスコンパイルしかできない。**画像を残せるのは CI だけ**。

そこで「CI が各 OS の実描画を PNG で残し、機械検証し、artifact として人が見られる」仕組みを
`zts_webview` の正式 API として追加した。

## 2. 決定事項

### 2.1 キャプチャは「キュー投入 → poll → 取り出し」の 3 段にする

```
captureWindow(id)  →  OK（描画開始を指示するだけ。まだ画像は無い）
step(.poll) × n    →  バックエンドの非同期完了コールバックが内部バッファを埋める
takeCapture(id)    →  Capture{ bytes, width, height }（所有権は呼び出し側へ移動）
```

理由:

1. 3 バックエンドすべてでキャプチャは **非同期**（`webkit_web_view_get_snapshot` の
   `GAsyncReadyCallback` / `takeSnapshotWithConfiguration:completionHandler:` /
   `ICoreWebView2::CapturePreview` の `Invoke`）。同期 API にすると GTK / AppKit の
   イベントループをライブラリ内部で回すことになり、`M3-03` の「ホストがループを所有する」
   契約（`step(.poll)` を毎フレーム呼ぶ SDL / raylib のフレームループ）を壊す。
2. 既存の `completeRequest`（スキーム応答）と **同じ状態機械** にできる。学習コストが増えない。
3. C ABI では `zts_webview_window_capture` / `zts_webview_capture_take` /
   `zts_webview_capture_free` の 3 関数にそのまま対応し、C ホストのフレームループに乗る。

`takeCapture` は「まだ描画中なら `len == 0` の `OK`」を返し、**失敗にしない**。
呼び出し側（ギャラリー / C ホスト）は `len > 0` になるまで `step(.poll)` を刻む。

### 2.2 形式は PNG 固定

| 項目 | 理由 |
|---|---|
| 可逆 | 文字・UI のアンチエイリアスが潰れず、画素検証（中心画素の RGB）が成立する |
| 自己記述 | IHDR に幅・高さがあり、`Capture` の寸法を自前で持たなくてよい（`png.zig` が解析） |
| 3 OS のネイティブ出力 | GTK は cairo、Cocoa は `NSBitmapImageRep`、WebView2 は `COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG = 0` |
| 依存ゼロ検証 | Node 標準の `zlib` だけでデコードでき、CI に追加パッケージが要らない |

JPEG は非可逆で画素検証に使えず、BMP は 32bpp のアルファで膨らむ。PNG 一択。

### 2.3 `nativeHandle` ではなく `captureWindow` を用意する

`nativeHandle()` から `CGWindowListCreateImage` / `PrintWindow` / X11 の `XGetImage` で
撮る案は捨てた。バックエンドごとに「ウィンドウ装飾を含む/含まない」「他ウィンドウに隠れる」
「HiDPI で 2 倍の解像度が返る」がばらつき、**同じ HTML を撮っても OS で画素が一致しない**。
WebView 自身のスナップショット API は「Web コンテンツの CSS 画素」を返すので、比較が安定する。

### 2.4 CI には「8 パターンのギャラリー」と「機械検証」を入れる

`examples/gallery/` は独立パッケージで、1 プロセスが 8 つのウィンドウを順に作って撮る:

| パターン | 寸法 (CSS px) | テーマ | 何を守るか |
|---|---|---|---|
| `hero-light` | 900×600 | light | 基本の描画・大きな見出し・サブピクセル AA |
| `dashboard-dark` | 1000×620 | dark | ダークテーマ・CSS グリッド・`backdrop-filter` 無しでの可読性 |
| `typography-cjk` | 860×620 | light | 日本語フォントのフォールバック・行間・禁則 |
| `scroll-offset` | 720×520 | dark | ネイティブからの `scrollIntoView()`（= `evalJs` 往復） |
| `js-roundtrip` | 640×420 | mixed | `fetch('/api/state')` → スキームハンドラ → DOM 更新の**画素**での確認 |
| `hidpi-ruler` | 560×400 | light | `devicePixelRatio` と 1px 罫線（Retina / 200% スケーリング） |
| `wide-split` | 1000×600 | mixed | 1024 幅超のレイアウトでもクリップしないこと |
| `compact-grid` | 320×240 | dark | 最小サイズ・タイル描画の下限 |

検証は 2 段:

1. **ギャラリー自身**が `manifest.json`（名前・実ビューポート・バイト数・メッセージ数・
   SHA-256・`expect_center_rgb`）を書き、`OK gallery host=<gtk3|cocoa|win32> patterns=8 captured=8`
   を出力する。`--require-native` を付けると `mock` フォールバック時に **exit 1**。
2. **`scripts/verify-screenshots.mjs`**（Node 22・依存ゼロ）が PNG を `zlib` で展開し、
   寸法・ユニーク色数・輝度レンジ・テーマ別平均輝度・中心画素・マニフェスト整合・
   manifest 未登録 PNG（= ブラウザ撮影分）の非空白を検証して `OK screenshots …` を出す。

CI は両方のマーカーを grep する（**マーカーが無い = 失敗**）。画像は
`actions/upload-artifact@v4` で `screenshots-<os>` として 14 日保存し、
`index.html` のコンタクトシートで目視できる。

### 2.5 「準備完了」の定義はページ自身に申告させる

固定 sleep で待つ方式は **捨てた**（§4.1）。`DOCUMENT_START` の init script で

```js
window.addEventListener('load', () => window.__ztsPostMessage(JSON.stringify({
  ready: true, w: innerWidth, h: innerHeight, dpr: devicePixelRatio,
})));
```

を注入し、`load` の申告（最大 20 秒、10ms 刻みの `step(.poll)`）を待ってから撮る。
撮影寸法も**要求サイズではなくページが申告した実ビューポート**を使う（§4.2）。
mock バックエンドは JS を実行しないため待機をスキップする（20 秒 × 8 パターンの無駄を排除）。

## 3. 影響

- `zts_webview` の公開面が `captureWindow` / `takeCapture` の 2 つ増えた。`zts_foundation` 以外への
  依存は増えていない（PNG 解析は `png.zig` 内の 60 行）。
- C ABI に 3 関数と `zts_capture_t` が増えた（`include/zts_webview.h` §4）。
- CI の実行時間が 3 OS 合計で約 2〜3 分増える（gallery 8 枚 × 3 OS + Linux のブラウザ撮影）。
  ビルドキャッシュは既存の `actions/cache@v4` に乗るため、増分はほぼ実行時間のみ。
- `examples/gallery/` は「スクショを撮るためだけのパッケージ」だが、`build test` に
  3 本の単体テスト（パターン表の一貫性・`solicit` ルーティング・SHA-256）を持つ。

## 4. CI で実際に踏んだ罠（再発防止）

### 4.1 Windows は「撮れた」のに真っ白だった

初回 Run `#40510539739` の Windows ジョブは `captured=8` で成功したが、PNG は 762〜3601 bytes
の **1 色だけの画像**だった。原因は WebView2 のブラウザプロセス起動が遅く、`navigate` 後
固定 900ms では `ContentLoading` すら終わっていないこと。`CapturePreview` は
`ContentLoading` 前だと **S_OK を返したままハンドラが発火しない**（= 空ストリームが PNG になる）。

→ §2.5 の「ページ申告 + `waitForReady`」に変更。**固定 sleep 方式へは戻さない。**

### 4.2 macOS はウィンドウがクランプされ、中心画素が UI に隠れた

runner の画面は 1024×674 しかないため、1200×700 を要求しても 1024×645 にクランプされる。
さらに `js-roundtrip` はカードが中央にあり、`expect_center_rgb`（スウォッチの `#123456`）を
覆っていた。

→ 要求サイズを 1000×620 / 860×620 / 1000×600 に縮め、**撮影はページ申告の実ビューポート**
（`innerWidth`/`innerHeight`）で行い、manifest にも実寸を書く。カードは
`justify-content:flex-end` + `padding-bottom` で下に寄せ、中央 1 画素をスウォッチに明け渡す。

### 4.3 WebView2 は `gallery://` を解釈できない

ギャラリーは当初 `gallery://localhost/<pattern>` を自分でハンドラ登録していたが、Windows だけ
**真っ白**（`messages=0`）だった。`windows.zig` は WebView2 にカスタムスキーム API が無いため
`tauri` / `ipc` / `asset` の 3 スキームだけを `http://<scheme>.localhost` に写像し、
`AddWebResourceRequestedFilter` もこの 3 つにしか張らない（[`../architecture/zts-webview-backends.md`](../architecture/zts-webview-backends.md) §3）。
他のスキームは **ナビゲーション自体が不成立** になる。

→ ギャラリーのスキーム名を `tauri` にし、ページ側は相対 URL `fetch('/api/state')` を使う。
これは「アプリ作者が 3 OS で同じ HTML を動かす」ための Z-Ts の既定ルールそのもので、
ギャラリーだけの特例ではない。`pathOf()` は `tauri://localhost/x` と
`http://tauri.localhost/x` の両方を受け付ける（単体テストで固定）。

### 4.4 ギャラリー自身が ready report をリークしていた

`WindowState.report`（ページ申告の `{ready,w,h,dpr}`）を `dupe` したままウィンドウを閉じており、
`DebugAllocator` が 8 件（1 パターン 1 件）のリークを毎回出力していた。**リークを報告しても
プロセスは exit 0** なので、マーカーゲートでは検出できない。ウィンドウ破棄時に
`free` するよう修正し、Run `#40526416028` のログで `error(SafeAllocator)` が 0 件であることを確認した。

### 4.5 browser 撮影は SSE で永久に終わらない

Linux の追加ステップで Live Preview を `--virtual-time-budget=6000` で撮っていたが、
EventSource（SSE）の接続が開いている間は仮想時間が進まず、Chrome が終了しないまま
ジョブが 26 分ハングした（Run `#40519060481`）。→ Live は budget を付けず `load` 直後に撮影、
撮影全体を `timeout 90` でラップし、`SKIP browser-shot <name>` を明示、3 ジョブに
`timeout-minutes: 45` を設定した。

## 5. 却下した代替案

| 案 | 却下理由 |
|---|---|
| 同期 `captureNow()` API | 3 バックエンドとも非同期。内部でループを回すとホストのフレームループを止める |
| `nativeHandle` + OS のスクショ API | 装飾・遮蔽・HiDPI で OS 差が出て画素比較が壊れる（§2.3） |
| HTML を JS で SVG 化して `toDataURL()` | 外部フォント・画像で CORS に落ち、`backdrop-filter` 等が再現しない |
| ギャラリーを E2E テストに同居させる | テストランナー内で実ウィンドウを回すと exit code 3 で落ちる既知の罠がある。独立バイナリにする |
| 画素比較を全画像で行う | フォントレンダリングは OS で必ず差が出る。比較は「同一 OS 内のテーマ・非空白・中心画素」に限定する |
