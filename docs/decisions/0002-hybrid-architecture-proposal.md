# ADR-0002: Z-Ts 最適実装方針（Rev 3）— 「Rust コピー病」の完全排除と 6 パッケージ直交分離

- **Date**: 2026-10-21
- **Status**: Proposed（Rev 3 — ライブラリ切り分け明確化 & 残存 Rust 由来問題の徹底除去版）

---

## 1. Rev 2 にまだ残っていた「Rust（Tauri）丸パクリによる 7 つの構造的問題」

Rev 2 で関数シグネチャやメモリ寿命を改善した後も、**「Tauri がなぜその設計になっているか（＝Rust の言語制約や歴史的経緯の産物）」を疑わずに無意識にコピーしていた 7 つの重大問題** が残っていた。これらをすべて排除し、Zig 本来の設計へ置き換える。

| # | 無意識にパクっていた Rust/Tauri 設計 | なぜそれが Zig では悪手・バグになるのか | Zig ネイティブの最適解（Rev 3） |
|---|---|---|---|
| **1** | **巨大モノリス `zts.App`（God Object）** | WebView・RPC・ACL・アセット・プラグインが密結合し、「WebView だけ使いたい」「HTTP サーバーで TS 型付き RPC だけ使いたい」需要に応えられない。 | 独立して単体利用できる **6 つの直交 Zig パッケージ**（`zts_core`, `zts_rpc`, `zts_webview`, `zts_bridge`, `zts_tauri`, `zts`）に明確に分離する。 |
| **2** | **実行時 `Plugin` VTable 配列への動的登録** (`&zts.plugins.defaults`) | リンカから全プラグイン関数が到達可能になり **Dead Code Elimination が死ぬ**（未使用のトレイやダイアログの OS シンボルまで強制リンクされる）。また `tsgen` からプラグインの型が見えなくなる。 | プラグインは単なる **`Commands` 構造体を持つ Zig モジュール** とし、**`zts_rpc.merge(.{ ... })` で `comptime` 静的結合** する。使わない機能は **物理的に 0 バイト** になる。 |
| **3** | **動的型マップ `ResourceTable` + 単純連番 `u32` ID** | Rust の借用制約回避用の `Box<dyn Resource>` の丸写しであり、① 個別ヒープ確保多発、② 閉じた直後の ID 再利用による **ABA 誤アクセスバグ** が起きる。 | JS `number`（`f64` 整数精度 53 bit）に完全収まる **53-bit 世代番号付き `HandlePool(T)`（`packed struct(u53) { index: u24, gen: u29 }`）** を採用。ABA バグゼロ・連続配列・ダウンキャストゼロ。 |
| **4** | **メインスレッドを乗っ取って戻らない `run()`（Inversion of Control）** | Rust `winit`/`tao` の `'static` クロージャ制約の悪習。`defer deinit()` によるリーク検査を阻害し、既存のゲームループ（SDL/GLFW）や DAW プラグインへの埋め込みを不可能にする。 | OS イベント処理の基礎を **`step(.blocking)` / `step(.poll)` の 1 ステップ関数** とする。`run()` は単なる `while (app.step(.blocking)) {}` の 3 行糖衣に過ぎず、`defer` が 100% 確実に走る。 |
| **5** | **エラーを `String` にフォーマット確保して返す悪習** (`Result<T, String>`) | エラーのたびにヒープ確保が発生し、かつフロントエンド側でエラー種別の網羅的な型分岐ができない。 | **Zig の Error Set (`error{ NotFound, Denied }!T`) をそのまま活かす**。`@errorName(err)` により **0 バイト確保** でエラーコードを返し、**`tsgen` が自動で TypeScript の `"NotFound" \| "Denied"` Union 型を生成** する。 |
| **6** | **Tauri の 1 万行級 JSON ACL / Glob エンジンを全アプリに強制** | 単一ローカルウィンドウの 9 割のアプリにとって設定コストとバイナリサイズが無駄に増え、「なぜ動かないか分からない」最大原因になる。 | コアの認可境界は **1 つの明快な Zig 関数フック `AuthorizeFn`** のみとする。Tauri 互換 `capabilities/*.json` パーサ＆Glob スコープは `zts_tauri.acl` のオプション機能として分離する。 |
| **7** | **JSON 文字列の毎回コピー確保 & 高頻度イベントでの毎回 `eval(文字列)`** | ・Rust では `'de` 借用がエスケープ文字で失敗するため `String` コピーが多発。<br>・イベントごとに `eval("runCallback(...)")` を呼ぶと JS パーサ負荷が高い。 | ・`std.json` の **`.allocate = .alloc_if_needed`** を活用し、非エスケープ文字列（99%）は入力バッファへのゼロコピースライスにする。<br>・高頻度ストリームは JS 再パース不要の Binary Pull / Stream チャネルを併用可能にする。 |

---

## 2. 明確化された 6 つの Zig ライブラリ切り分け（`build.zig` 公開モジュール）

外部プロジェクトは統合 `zts` だけでなく、以下の個別モジュールを単独で `addImport` できる：

1. **`zts_core` (`src/core/`)** — *Zero-Dep Data Structures & Web Primitives*
   - 依存: `std` のみ（`link_libc = false`、OS I/O なし）
   - 提供: `HandlePool(T)`（`u53` 世代ハンドル）、`OwnedBytes`（完了コールバック解放スライス）、スレッドセーフ MPSC キュー、Origin/URL パーサ、Glob マッチャ、MIME 判定、CSP Nonce/SHA-256 注入、埋め込みアセットルックアップ。
2. **`zts_rpc` (`src/rpc/`)** — *Standalone Comptime RPC & TypeScript Codegen*
   - 依存: `zts_core` のみ（**GUI / WebView に一切依存しない完全独立パッケージ**）
   - 提供:
     - `codec`: `snake_case` ⇔ `camelCase` 変換、`.alloc_if_needed` ゼロコピー JSON デコーダ、単一ソース型スキーマ。
     - `router` / `merge`: 複数の名前空間付き `Commands` 構造体を `comptime` で単一の静的ディスパッチ関数へ合成。
     - `tsgen`: Zig の引数 `struct`・戻り値型・**起こりうる全 `ErrorSet`** から TypeScript の完全型付きクライアントコード `.ts` を `comptime` 生成。
3. **`zts_webview` (`src/webview/` + `include/zts_webview.h`)** — *Minimal Cross-Platform Native WebView Engine*
   - 依存: OS ネイティブ API のみ（**JSON にも RPC にも Tauri 仕様にも一切依存しない純粋 WebView ライブラリ**）
   - 提供: C ABI (`zts_webview.h`) としてもそのまま使える約 25 関数の極薄レイヤ。
     - ステップ実行イベントループ（`poll` / `wait` / 他スレッドからの `wakeup`）
     - マルチウィンドウ管理 ＋ 既存 OS ウィンドウ（`HWND` / `NSView` / `GtkWidget`）への子 WebView 埋め込み
     - Custom URI Scheme 非同期ストリーム応答（Linux `g_input_stream_read_all_async`、macOS `WKURLSchemeTask`、Windows 内蔵 80 行 `WebView2` ローダー）
4. **`zts_bridge` (`src/bridge/`)** — *Dev / Cloud Preview / E2E Browser Transport*
   - 依存: `std.Io.net`, `zts_core`（OS GUI 依存ゼロ）
   - 提供: 通常のブラウザ・Arena Live Preview・Playwright から直接アプリを実行・テストできる HTTP + SSE トランスポート（`HttpOnly; SameSite=Strict` + `Tauri-Invoke-Key` + `Origin` 三重検証）。本番ネイティブビルドでは `@import` しない限り **0 バイト**。
5. **`zts_tauri` (`src/tauri/`)** — *Tauri v2 Wire Compatibility & Modular Commands*
   - 依存: `zts_core`, `zts_rpc` (+ トランスポート抽象)
   - 提供: `@tauri-apps/api` v2 を無修正で動かす JS ブートストラップ、`Tauri-Response` / `Channel` プロトコル実装、および **必要なものだけ `zts_rpc.merge` で組み込める独立コマンド群**（`window`, `webview`, `event`, `path`, `app`, `dialog`, `fs`, `clipboard`, `menu`, `tray`）、オプションの `tauri.conf.json` / `capabilities` インポータ。
6. **`zts` (`src/root.zig`)** — *Ergonomic Umbrella Facade*
   - 上記パッケージを再公開し、一般的なデスクトップアプリを最小記述で配線する薄い統合レイヤ。

---

## 3. Rev 3 最終 API イメージ（6 パッケージの疎結合がそのまま表れる Zig コード）

```zig
const std = @import("std");
const zts = @import("zts"); // または個別パッケージ `@import("zts_rpc")` 等を単体利用可能！

pub const AppState = struct {
    mu: std.Io.Mutex = .init,
    files: zts.core.HandlePool(std.Io.File) = .empty, // u53 世代ハンドル（ABA バグゼロ）
    count: i64 = 0,
};

pub const AppCommands = struct {
    /// エラーセット `error{OutOfRange}` がそのまま TS 側で
    /// `Result<bigint, "OutOfRange" | "Canceled">` として自動型付けされる！
    pub fn increment(ctx: *zts.rpc.Ctx, state: *AppState, args: struct {
        delta: i64 = 1,
    }) error{ OutOfRange, Canceled }!i64 {
        if (args.delta > 1_000_000) return error.OutOfRange;
        try state.mu.lock(ctx.io);
        defer state.mu.unlock(ctx.io);
        state.count += args.delta;
        return state.count;
    }
};

pub fn main(init: std.process.Init) !void {
    var state: AppState = .{};
    defer state.files.deinit(init.gpa);

    var wm: zts.tauri.WindowManager = .empty;
    defer wm.deinit(init.gpa);

    // 1. 使いたい機能だけを comptime 静的結合（未使用プラグインは 0 バイト！）
    const Router = zts.rpc.merge(.{
        .{ .prefix = null,     .state = &state, .cmds = AppCommands },
        .{ .prefix = "window", .state = &wm,    .cmds = zts.tauri.window.Commands },
    });

    // 2. ビルド時に `Router.ts_bindings` 定数文字列を書き出せば `bindings.gen.ts` 完成！
    //    `comptime { _ = Router.ts_bindings; }`

    // 3. Pinned 初期化 & ステップ実行（自分のゲームループに混ぜるのも `while (app.step(.poll))` 1行！）
    var app: zts.App = undefined;
    try app.init(init.gpa, init.io, .{
        .app_id = "dev.zts.app",
        .windows = &.{.{ .label = "main", .title = "Z-Ts", .width = 1024, .height = 768 }},
        .assets = zts.core.Assets.embed(embed_table),
        .router = Router.erase(), // ここで具体型関数ポインタ 1 本に型消去
    });
    defer app.deinit(); // ループを普通に抜けるため 100% 確実に実行されリークゼロ！

    while (app.step(.blocking)) {}
}
```

---

## 4. 実装着手の並列分割プラン（Phase 1：コンフリクトゼロの 4 並列構成）

この切り分けにより、最初の一歩から完全に独立したディレクトリ単位で実装・テストが進められる：

1. **`M1-01` (`src/core/`)**: `HandlePool(T)` (`u53`), `OwnedBytes`, MPSC Queue, URL/Glob/CSP/MIME ユーティリティ（Pure Zig・テスト 0.01s）
2. **`M1-02` (`src/rpc/`)**: `codec` (`camelCase` + `.alloc_if_needed`), `router` & `merge` (`comptime`), `ErrorSet` 対応 `tsgen`（Pure Zig・GUI 依存ゼロ）
3. **`M1-03` (`src/bridge/`)**: `std.Io.net` セキュア HTTP + SSE トランスポート（Live Preview & E2E 基盤）
4. **`M1-04` (`src/webview/`)**: C ABI 定義 (`zts_webview.h` 相当 VTable) + Mock Backend + Linux `GTK3 + WebKit2GTK 4.1` 非同期ストリーム実装
