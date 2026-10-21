# ADR-0002: Z-Ts 最適実装方針の提案 — Tauri v2 × Zig `comptime`/Arena × WebUI ハイブリッド設計

- **Date**: 2026-10-21
- **Status**: Proposed（ユーザーレビュー待ち）

---

## 1. 背景と問い

`Z-Ts` の目的は、単に Rust 製 Tauri（`tauri` + `wry` + `tao` 計 15 万行超）を盲目的に 1:1 逐語翻訳することではない。
**「なぜ開発者は Electron ではなく Tauri を選ぶのか（Tauri の本質的強み）」** を 100% 継承しつつ、**Rust 版 Tauri が構造的に抱えている弱点** を Zig `0.17.0` の言語特性と、他の WebUI 系フレームワーク（Wails, `webui-dev/webui`, `webview/webview`, Electrobun, Neutralinojs）の優れた設計知見を取り入れて根本解決する最適アーキテクチャを定義する。

---

## 2. 既存 WebUI 系アプローチの比較と教訓

| アプローチ | 代表例 | 取り入れるべき最大の強み | 回避すべき構造的弱点 |
|---|---|---|---|
| **OS WebView + Custom Protocol + ACL** | **Tauri v2** | ・バイナリ数 MB、省メモリ<br>・ポートを開かない `ipc://` 高速・バイナリ IPC<br>・Capabilities / Scope / Isolation による堅牢なセキュリティ<br>・`@tauri-apps/api` エコシステム | ・proc-macro とビルドの重さ（数分・数 GB）<br>・`Arc<Mutex<T>>` / `async Send + 'static` の複雑さ<br>・標準では Rust⇔TS 間の型が自動同期されない<br>・GUI 環境がないと結合テストやプレビューが困難 |
| **型付きバインディング自動生成** | **Wails (Go)** | ・バックエンド関数を書くだけで **TypeScript の型付きクライアント関数 (`.ts`) を自動生成** する圧倒的 DX | ・Go GC ランタイム同梱サイズ<br>・CGO 強制によるクロスコンパイルの難しさ<br>・細粒度 ACL セキュリティ層の欠如 |
| **任意のブラウザ / HTTP・WS ブリッジ** | **`webui-dev/webui`**, **Neutralinojs** | ・ネイティブ WebView がない環境やクラウド環境でも **通常のブラウザ・DevTools・Playwright からそのまま接続・デバッグ可能** | ・ローカルポート常時開放のみだと他プロセスからのアクセス制御が弱い<br>・ネイティブ OS 統合・アセット保護が弱い |
| **極薄 C ABI WebView 抽象** | **`webview/webview`**, **Electrobun** | ・3 OS（GTK/WebKit2GTK, Cocoa/WKWebView, Win32/WebView2）の本質シムは **数千行の C ABI** で完結するシンプルさと爆速ビルド<br>・C ABI 公開により他言語からも FFI 利用可能 | ・単体では Tauri のような Custom Protocol バイナリ RPC・複数ウィンドウ・ACL・プラグイン機構を持たない |

---

## 3. 提案する Z-Ts の 5 大設計ピラー（いいとこ取りの最適解）

### ピラー ①：【Dual-Mode Transport】本番は「ポートレス Native WebView」、開発・CI・クラウドでは「Browser HTTP Bridge」も選べる二刀流
- コア層とトランスポート層を 1 つの `Transport` VTable で分離し、**アプリコードもフロントエンド（`@tauri-apps/api`）も 1 行も変えずに** 2 つの実行エンジンを切り替え可能にする：
  1. **`NativeWebViewTransport`（デフォルト・本番配布用）**:
     - Tauri v2 完全互換。OS ネイティブ WebView + インメモリ Custom Protocol（`ipc://localhost/<cmd>`, `asset://localhost/`）+ `Tauri-Invoke-Key` 秘密鍵検証。**TCP ポート開放ゼロ・最小バイナリ（1〜2 MB 台）・最高セキュリティ**。
  2. **`HttpBridgeTransport`（`webui` 流・Dev / Cloud Live Preview / E2E テスト用）**:
     - 開発フラグ有効時のみ組み込み HTTP/SSE ブリッジを起動し、通常の Chrome/Firefox や **Arena の Live Preview ブラウザ**、ヘッドレス Playwright から直接アプリの GUI と全 IPC・ACL・State をリアルタイム実行・自動テストできる。
     - **本番ビルドでは `comptime` フラグにより完全にバイナリから除去（Dead Code Elimination）** されるため、サイズ増加もセキュリティリスクもゼロ。

### ピラー ②：【`comptime` Zero-Macro RPC & TypeScript 自動型生成】`@tauri-apps/api` 100% 互換 ＋ Wails 流の型安全 DX
- **マクロ一切不要**: 通常の Zig 関数をそのまま登録するだけで、`@typeInfo(@TypeOf(fn_ptr)).@"fn"` がコンパイル時に以下を自動構築する：
  - 引数ごとの自動 DI 解決（`zts.Context`, `zts.AppHandle`, `zts.Window`, `zts.State(T)`, `zts.Channel(T)`, `zts.RawBody`, `std.mem.Allocator`）と JSON デシリアライズ（`snake_case` ⇔ `camelCase` 自動対応）
  - 戻り値が `T` か `!T`（エラーユニオン）か `zts.RawResponse`（生バイト列）かの自動分岐
  - `comptime` 静的ディスパッチテーブル（実行時の動的登録オーバーヘッドなし）
- **TypeScript 型定義・クライアントの自動出力**:
  - 同じ Zig コマンド定義から `comptime` / ビルドステップで `bindings.gen.ts` を自動出力する。
  - **既存の `@tauri-apps/api` フロントエンドを無修正で動かす互換性** と、**Wails / `tauri-specta` のような 100% 型安全な TS 補完体験** を標準機能だけで両立する。

### ピラー ③：【Zig 特化メモリ設計】4KB スタック・ファストパス ＋ Per-Request `ArenaAllocator` ＋ ゼロコピー Binary IPC
- **4KB Stack Fallback + Request Arena**:
  - IPC 1 往復ごとに `stackFallback(4096, pool_allocator)` ベースの `ArenaAllocator` を張り、コマンド関数へ渡す。
  - ペイロード 4KB 以下の一般的な GUI RPC では **ヒープ `malloc`/`free` 回数 = 完全ゼロ**、それ以上のリクエストでもコマンド完了時に **O(1) で一括解放** される（リーク不能・断片化なし・GC 停止なし）。
- **Raw Binary Fast Path**:
  - `Uint8Array` / `ArrayBuffer` ⇔ `[]const u8` は Tauri v2 の `application/octet-stream` 経路で JSON 変換を完全にバイパスする。

### ピラー ④：【OS ネイティブ層の極薄 C ABI 設計】`tao`+`wry` 10万行の再発明を避け、25個の C ABI プリミティブに凝縮
- ゲームエンジン由来の肥大な `tao` を丸ごと移植するのではなく、`webview/webview` や Electrobun が実証した **「WebView ホストに必要な最小 OS シム（約 25〜30 個の C ABI 関数）」** に責務を絞る：
  - **Linux**: Pure Zig から `libgtk-3.so` + `libwebkit2gtk-4.1.so` を直接 `extern "c"` 呼び出し（ビルド 4.8 秒、追加 C コード不要）。
  - **macOS**: `zig cc` 同梱 Clang を活かし、約 300〜400 行の極薄 Objective-C シム（`WKWebView` + `WKURLSchemeHandler` + `NSWindow`）を C ABI でリンク（無理な `objc_msgSend` メタプログラミングを避け、可読性と安定性を最大化）。
  - **Windows**: Win32 API + WebView2 COM VTable を Zig から直接バインド（C++/WRL テンプレート依存ゼロ、`x86_64-windows` への高速クロスコンパイル対応）。
- さらに `Z-Ts` 自体もクリーンな **`include/zts.h`（C ABI）** を公開可能にし、Zig だけでなく C / Python / Bun / Go 等からも組み込めるユニバーサル WebUI エンジンにする。

### ピラー ⑤：【スレッドモデル & プラグイン構造】UI フリーズゼロの Worker Pool ＋ 10 個の独立内部プラグイン
- **スレッドモデル**:
  - メインスレッドは OS GUI イベントループ専任。
  - コマンドは軽量同期実行（メインスレッドまたは呼び出しコンテキスト即時返却）と、組み込み `std.Thread.Pool` バックグラウンド実行（完了時に `EventLoopProxy` でメインスレッドへ応答をポスト）を自動/宣言的に使い分ける。Rust のような複雑な `Pin<Box<dyn Future + Send + 'static>>` 地獄を持ち込まない。
- **プラグイン・ファースト構造（並列開発最適化）**:
  - Tauri v2 本家と同様、`window`, `webview`, `event`, `path`, `app`, `resources`, `image`, `menu`, `tray`, `fs`, `dialog`, `clipboard` をすべて同一の `zts.Plugin` インターフェース上の独立ディレクトリ（`src/plugins/<name>.zig`）として分離し、複数エージェントがコンフリクトゼロで並列実装できるようにする。

---

## 4. ユーザー様からの Zig API イメージ（ここまでシンプルになる！）

```zig
const std = @import("std");
const zts = @import("zts");

const Counter = struct {
    mu: std.Thread.Mutex = .{},
    count: i64 = 0,
};

fn increment(state: zts.State(*Counter), delta: i64) i64 {
    state.get().mu.lock();
    defer state.get().mu.unlock();
    state.get().count += delta;
    return state.get().count;
}

fn greet(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    // Request Arena なので free 不要！レスポンス送信後に自動で一括解放される
    return std.fmt.allocPrint(arena, "Hello, {s} from Zig!", .{name});
}

pub fn main() !void {
    var counter = Counter{};

    var app = try zts.Builder(.{
        .config = @embedFile("tauri.conf.json"), // comptime で検証・パース可能！
        .commands = .{ increment, greet },       // マクロ不要！TS型定義もここから自動生成！
    })
        .manage(&counter)
        .build(std.heap.smp_allocator);
    defer app.deinit();

    try app.run();
}
```

---

## 5. 推奨実装ロードマップ（段階的・常時動作検証可能な順序）

1. **Phase 1 — Pure Zig コア & Dual Transport 基盤（OS 非依存・コールド 5 秒テスト完結！）**
   - `Config` / `Capabilities (ACL & Glob Scope)` パーサ（`comptime` & ランタイム両対応）
   - `StateManager`, `ResourceTable`, `EventHub`
   - `comptime` コマンドルーター + Request Arena + JS 初期化スクリプト生成 + `.d.ts`/`.ts` 自動生成器
   - **`HttpBridgeTransport` 実装** → この時点で **実ブラウザ & Arena Live Preview 上で `@tauri-apps/api` フロントエンドと Zig バックエンドのフルスタック Tauri アプリが動く！！**
2. **Phase 2 — Linux ネイティブ WebView (`GTK3 + WebKit2GTK 4.1`) & 標準内部プラグイン並列実装**
   - `NativeWebViewTransport`（Linux: `ipc://`, `asset://`, `Tauri-Invoke-Key`, `eval`）+ CI Xvfb 自動 GUI テスト
   - 標準内部プラグイン群（`window`, `webview`, `event`, `path`, `app`, `resources`, `dialog`, `fs`, `clipboard`, `menu`, `tray`）を並列実装
3. **Phase 3 — macOS (`Cocoa + WKWebView`) & Windows (`Win32 + WebView2`) ネイティブバックエンド + C ABI 公開**
   - 3 OS ネイティブバイナリ完成 & GitHub Actions 3 OS マトリクスでの実機 E2E 検証・対 Rust Tauri ベンチマーク比較
4. **Phase 4 — CLI & Cross-Bundler (`zts init / dev / build / tsgen`)**
   - Vite ホットリロード連携、`.deb` / `AppImage` / `.app` / `.dmg` / NSIS インストーラ生成、単一バイナリ圧縮埋め込み
