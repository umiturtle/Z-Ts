# ADR 0006: Objective-C シム + Flat C ABI による macOS `WKWebView` バックエンド

- **日付**: 2026-10-23
- **ステータス**: 採択（Accepted）
- **関連タスク**: [`M3-01`](../tasks/M3-01-macos-wkwebview.md)

---

## 1. 背景

`zts_webview` は「OS ごとに完全分離された極薄 WebView エンジン」を掲げ、M1-06 で Linux GTK3 +
WebKit2GTK 4.1 バックエンドを完成させた。残る macOS / Windows のうち、macOS は次の理由で
最初の難所になる：

1. **API が Objective-C でしか存在しない**（`NSWindow`, `WKWebView`, `WKURLSchemeHandler`）。
   C 関数ポインタだけで完結する GTK とは異なり、`objc_msgSend` / クラス定義 / デリゲートが必須。
2. **Zig 0.17 では `@cImport` が廃止**され、`addTranslateC` で `Cocoa.h` / `WebKit.h` を取り込むと
   キャッシュ揮発環境（毎チャット新規コンテナ）で **+50 秒** のペナルティが発生する
   （[`AGENTS.md`](../../AGENTS.md) §2.3、[`ADR-0001`](0001-zig-017-and-sharded-agent-workflow.md)）。
3. **座標系が逆**（Cocoa は左下原点・Y 上向き、CSS は左上原点・Y 下向き）。
4. **`WKURLSchemeTask` の競合クラッシュ**: `stopURLSchemeTask:` 後に `didFinish` を呼ぶと
   `NSInternalInconsistencyException` でプロセスが即死する。Linux の `finish_with_response` には
   存在しない失敗モード。

---

## 2. 決定事項

### 2.1 Objective-C は 1 ファイル（`src/webview/macos_shim.m`）に閉じ込め、境界は Flat C ABI のみ

- 公開するのは `zts_macos_*` という **C 関数 30 個程度**だけ。
- Zig 側（`src/webview/macos.zig`）は `extern fn` 宣言のみで、**Objective-C 型を一切知らない**。
- `addTranslateC` も `@cImport` も使わないため、コールドビルドは 2 秒台に収まる。

```
zts_webview/mod.zig            ← 純 Zig。OS 分岐はこの 1 箇所だけ
        ├── linux.zig          ← GTK3 / WebKit2GTK（extern C）
        ├── macos.zig          ← Cocoa / WKWebView（extern C）
        │     └── macos_shim.m ← 唯一の Objective-C。`-fobjc-arc` でビルド
        └── mock.zig           ← 全 OS 共通 HeadlessMock
```

### 2.2 Zig 側の `Engine` に `.macos_wk` を追加し、既存 API を一切変えない

`Engine` union に `macos_wk: *macos.MacOsBackend` を追加し、`linux_gtk` と **完全に同じ
メソッド面**（`createWindow` / `completeRequest` / `evalJs` / …）を実装する。これにより
`zts_core.Host`、`zts_tauri.ProtocolRouter`、`DesktopRuntime`、果ては `examples/counter` の
アプリコードまで **1 行も変更せずに** macOS 実機で動く。

`macos_shim.m` のコンパイルは `build.zig` の `target.result.os.tag == .macos` 判定でのみ行うため、
Linux / Windows のビルドには一切影響しない（`.m` が存在しない CI でも壊れない）。

### 2.3 座標変換は純 Zig（`src/webview/coords.zig`）に置き、全 OS で単体テストする

```zig
pub fn cssToCocoaY(screen_top: f64, css_y: f64, window_height: f64) f64 {
    return screen_top - css_y - window_height;
}
```

- 唯一のプラットフォーム固有情報は `zts_macos_screen_visible_frame()` が返す `NSScreen.visibleFrame`
  （メニューバー / Dock を除いた領域）だけ。
- 2 台目ディスプレイ（`NSScreen.origin.y < 0`）も扱えるよう、原点オフセットを引数に含める。
- **Linux CI でも実行できる**ため、「座標変換の回帰」が macOS ランナーなしで検出できる。

### 2.4 `stopURLSchemeTask:` 競合は「二重世代チェック」で根絶する

| 層 | 機構 |
|---|---|
| Objective-C シム | `NSMutableDictionary<NSNumber*, ZtsSchemeTask*>` をトークン表として保持。`stopURLSchemeTask:` で即座に削除し、以後の `zts_macos_scheme_respond(token, …)` は **nil 参照で no-op** |
| Zig | `pending.PendingTable` の 53-bit 世代付き `RequestId`。窓の再読み込み / クローズで世代が進むため、遅延した worker の完了は `take()` が `null` を返して破棄 |
| 例外安全 | `didReceiveResponse:` / `didFinish` を `@try/@catch` で包み、万一 WebKit が内部矛盾を検出してもプロセスを落とさない |

### 2.5 クロスオリジン `fetch` のために CORS ヘッダを自動付与する

`WKWebView` はカスタムスキーム間の `fetch()` に CORS を適用する。無改造 `@tauri-apps/api` v2 は
`Tauri-Response` ヘッダを読むため、シムは全応答に以下を付ける：

```
Access-Control-Allow-Origin: *
Access-Control-Expose-Headers: Tauri-Response,Tauri-Callback,Tauri-Error,Content-Type,...
```

（GTK 版では `webkit_security_manager_register_uri_scheme_as_cors_enabled` が同じ役割を担う。）

### 2.6 `step(.blocking)` は AppKit の `nextEventMatchingMask:` を 1 回だけ回す

`nextEventMatchingMask:untilDate:(blocking ? distantFuture : distantPast) inMode:... dequeue:YES` を
1 回呼ぶ。`wakeup()` はスレッドセーフな `[NSApp postEvent:]` で `NSEventTypeApplicationDefined` を
積むため、ブロック中のループが即座に復帰する（GTK の `g_idle_add_full` と同じ設計）。
`dispatch_get_main_queue` / ブロック構文は使わない（`libBlocksRuntime` への依存を作らない）。

---

## 3. 検討した代替案

| 代替案 | 却下理由 |
|---|---|
| `addTranslateC` で `Cocoa.h` + `WebKit.h` を取り込む | ヘッダが巨大で毎回 +50 秒。`AGENTS.md` §2.3 で原則禁止 |
| `objc_msgSend` を Zig から直接叩く | シグネチャ可変・構造体返却（`NSRect` 等）で ABI 事故が起きやすい。可読性も最悪 |
| wry 相当の Rust staticlib を FFI | ビルドに Rust ツールチェーン + crates.io が必要（サンドボックス非接続）。単一バイナリ思想にも反する |
| macOS を `HeadlessMock` のままにする | `M3-01` の DoD を満たさない。ネイティブ体験が Linux のみになる |

---

## 4. 結果とトレードオフ

**得られたもの**
- macOS 実機で `DesktopRuntime` / `zts_tauri` / `examples/counter` がゼロ変更で動作。
- Objective-C は 1 ファイル・約 900 行。監査範囲が明確で、他 OS のビルドには一切混入しない。
- 座標変換ロジックが **Linux CI でもテストされる**（`coords.zig` の 4 テスト）。

**受け入れたコスト**
- シムは C ABI なので、AppKit の新 API を使うたびに `extern fn` + ラッパーを 1 対で書く必要がある。
- `WKWebView` の応答は **非同期チャンクストリーミングではなく単発 `didReceiveData:`**。
  巨大ファイル（>64 MiB）はメモリに載る。動画ストリーミングが必要になった時点で
  `didReceiveData:` の分割送出へ拡張する（`M3-03` 以降）。
- macOS の E2E は GitHub Actions `macos-latest` でしか実走できない（ローカル Arena は Linux のみ）。
  そのため CI に `OK macos-wk checks=...` の **痕跡検証ステップ**を置き、無言スキップを防いでいる。
