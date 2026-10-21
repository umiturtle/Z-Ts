# ADR-0002: Z-Ts 最適実装方針（Rev 3）— 「Rust コピー病」の完全排除と 6 パッケージ直交分離

- **Date**: 2026-10-21
- **Status**: Proposed（Rev 4 — コンパイラ制約・OS 非同期競合・JS 数値精度の深層精査反映版）

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

## 3. 深層精査（第 2 次監査）で追加特定・解消した 6 つの実装爆弾

6 パッケージ構成（Rev 3）を Zig `0.17.0` コンパイラ規則・IEEE 754 仕様・3 OS WebView 内部挙動で最終シミュレーションし、実装途中で詰む原因になる残り 6 個のエッジケースを事前に潰した：

1. **【`comptime` と実行時ポインタの混在エラー】`merge(.{ .state = &state })` の罠**
   - ローカル変数 `&state` は runtime 値のため、`type` を返す `comptime` 関数に直接渡すと `unable to evaluate comptime expression` になり、かつ `main()` 内に閉じ込められて `build.zig` から `.ts` 型を取り出せない。
   - **解決**: **トップレベルの型定義 `pub const Rpc = zts.rpc.Schema(.{ .app = AppCommands, ... });`** と、**実行時のインスタンス束縛 `var router = Rpc.bind(.{ .app = &state, ... });`** に 2 段分離する。これにより `zig build tsgen` からも `Rpc.ts_bindings` を直接参照できる。
2. **【JSON 64-bit 整数のサイレント丸め破壊】JS `MAX_SAFE_INTEGER (2^53 - 1)` 問題**
   - `i64` / `u64` をそのまま JSON 数値で返すと JS 側の `JSON.parse` で下位ビットが静かに壊れ、逆に JS の `BigInt` は標準 `JSON.stringify` で `TypeError` を投げる。
   - **解決**: `i8`〜`i53` / `u8`〜`u53`（Zig 標準の任意ビット幅整数）は `number` として扱い、素の `i64`/`u64`/`usize` を RPC 型に使った場合は **`@compileError` で暗黙の精度喪失をコンパイル時に阻止** し、文字列転送＋TS `bigint` 自動変換ラッパー `zts.BigInt(i64)` または `i53` の明示指定を促す。
3. **【ニワトリと卵の初期化循環 & GTK リンク漏れ】`zts_tauri` ⇔ `zts_webview` 間依存**
   - `window.Commands` が具体的な `zts_webview` 型に依存したり初期化前の `App` ポインタを要求すると、循環依存が起き、さらにヘッドレス `zts_bridge` 単体ビルド時に GTK シンボルを要求してしまう。
   - **解決**: OS 非依存の `Host` 操作 VTable 型定義を最下層 `zts_core` に置き、`rpc.Ctx` 経由で渡す。これにより **`zts_tauri` は `zts_webview` を一切 `@import` せず**、GTK 未導入環境でもフルスタックでビルド・動作する。
4. **【macOS / Windows 特有の非同期応答クラッシュ】`WKURLSchemeTask` & COM STA 競合**
   - macOS でページリロード（`stopURLSchemeTask`）直後にワーカースレッドから `didFinish` を呼ぶとキャッチ不能な Objective-C 例外で即死し、Windows WebView2 COM オブジェクトを別スレッドから触ると `RPC_E_WRONG_THREAD` で失敗する。
   - **解決**: **OS の生 Request ポインタはメインスレッドの `HandlePool(PendingRequest)` から外へ一歩も出さない**。ワーカーには世代付き整数 `req_id` と入力バイト列だけを渡し、完了時はメインスレッド起床コールバック内で世代照合してから応答を返す（途中キャンセル済みなら安全に破棄）。
5. **【`@tauri-apps/api` の隠しワイヤー規約】`"__CHANNEL__:<id>"` 文字列フォーマット**
   - 本家 `@tauri-apps/api` の `Channel` インスタンスは JSON 上で数値ではなく `"__CHANNEL__:<callback_id>"` 文字列にシリアライズされる。
   - **解決**: Zig `std.json` 標準の `pub fn jsonParse` カスタムフックを `zts.rpc.Channel(T)` に実装し、`"__CHANNEL__:<id>"` と数値 `<id>` の両方を受け付ける。
6. **【`@embedDir` 不在問題】Vite ハッシュ付きアセット群の単一バイナリ埋め込み**
   - Zig にはディレクトリ一括 `@embedDir` 組み込みがないため、手書き `@embedFile` ではビルドごとにファイル名ハッシュが変わる Vite 出力を扱えない。
   - **解決**: `build.zig` ヘルパー `zts.embedFrontend(b, exe, .{ .dir = "dist" })` を提供し、ビルドステップで `dist/` を走査して静的アセットマップ Zig モジュールを自動生成・注入する。

---

## 4. Rev 4 最終 API イメージ（100% コンパイル成立・循環ゼロ版）

```zig
const std = @import("std");
const zts = @import("zts");

pub const AppState = struct {
    mu: std.Io.Mutex = .init,
    files: zts.core.HandlePool(std.Io.File) = .empty,
    count: i53 = 0, // JS `number` と 1bit の誤差もなく往復できる Zig ネイティブ 53-bit 整数！
};

pub const AppCommands = struct {
    pub fn increment(ctx: *zts.rpc.Ctx, state: *AppState, args: struct {
        delta: i53 = 1,
    }) error{ OutOfRange, Canceled }!i53 {
        if (args.delta > 1_000_000) return error.OutOfRange;
        try state.mu.lock(ctx.io);
        defer state.mu.unlock(ctx.io);
        state.count += args.delta;
        return state.count;
    }
};

/// 1. トップレベル comptime スキーマ宣言（`zig build tsgen` からそのまま `.ts` 生成可能！）
pub const Rpc = zts.rpc.Schema(.{
    .app = .{ .prefix = "", .State = AppState, .Cmds = AppCommands },
    .window = zts.tauri.window.spec, // Host VTable 経由で動くため追加 State 不要！
});

pub fn main(init: std.process.Init) !void {
    var state: AppState = .{};
    defer state.files.deinit(init.gpa);

    // 2. 実行時ポインタを Pinned 束縛して具体型 Handler Fat Pointer を得る
    var router = Rpc.bind(.{ .app = &state, .window = {} });

    var app: zts.App = undefined;
    try app.init(init.gpa, init.io, .{
        .app_id = "dev.zts.app",
        .windows = &.{.{ .label = "main", .title = "Z-Ts", .width = 1024, .height = 768 }},
        .assets = zts.core.Assets.fromModule(@import("zts_assets")),
        .handler = router.handler(),
    });
    defer app.deinit();

    while (app.step(.blocking)) {}
}
```

---

## 5. 実装着手の並列分割プラン（Phase 1：コンフリクトゼロの 4 並列構成）

この切り分けにより、最初の一歩から完全に独立したディレクトリ単位で実装・テストが進められる：

1. **`M1-01` (`src/core/`)**: `HandlePool(T)` (`u53`), `OwnedBytes`, MPSC Queue, URL/Glob/CSP/MIME ユーティリティ（Pure Zig・テスト 0.01s）
2. **`M1-02` (`src/rpc/`)**: `codec` (`camelCase` + `.alloc_if_needed`), `router` & `merge` (`comptime`), `ErrorSet` 対応 `tsgen`（Pure Zig・GUI 依存ゼロ）
3. **`M1-03` (`src/bridge/`)**: `std.Io.net` セキュア HTTP + SSE トランスポート（Live Preview & E2E 基盤）
4. **`M1-04` (`src/webview/`)**: C ABI 定義 (`zts_webview.h` 相当 VTable) + Mock Backend + Linux `GTK3 + WebKit2GTK 4.1` 非同期ストリーム実装
