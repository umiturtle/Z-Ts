# ADR-0002: Z-Ts 最適実装方針（v2）— 初期案の欠陥監査と Zig 0.17 ネイティブ API 設計

- **Date**: 2026-10-21
- **Status**: Proposed（Rev 2 — 欠陥洗い出し・Zig 0.17 イディオム全面見直し反映版）

---

## 1. 初期提案（Rev 1）に対する厳格な欠陥監査（洗い出された 8 つの問題点）

初期案を Zig `0.17.0` の実機標準ライブラリ（`lib/std/process.zig`, `lib/std/Io.zig`）および各 OS WebView の実挙動に照らして再検証した結果、実装前に潰すべき **8 つの重大な欠陥（Rust 引きずりのアンチパターンおよび実行時地雷）** を特定した。

| # | 初期案の問題点 | 何が起きるか（具体的な破綻シナリオ） | Rev 2 での根本解決策 |
|---|---|---|---|
| **1** | **関数の仮引数名に依存した RPC 設計**<br>`fn greet(arena, name: []const u8)` | **【コンパイル不能バグ】** Zig の `@typeInfo(Fn).params` には `type` しかなく仮引数名（`"name"`）は存在しないため、JSON キー名も TS 型名も原理的に取得できない。 | JSON 入力は **明示的な `args: struct { ... }` 引数** に統一する。構造体フィールドなら名前・型・デフォルト値・`?T` が 100% `comptime` 取得でき、`std.json` とも直結する。 |
| **2** | **4KB スタック Arena の即時解放**<br>`stackFallback(4096)` を関数終了時に破棄 | **【Use-After-Free クラッシュ】** WebKit2GTK の `WebKitURISchemeRequest`（`GInputStream`）や非同期 IPC 応答は、関数リターン後に別イテレーション/別スレッドでバイト列を読むためスタック破壊が起きる。 | メモリ寿命を **① Scratch Arena（スレッドローカル再利用バッファ・コマンド内一時計算用）** と **② Owned Response Buffer（WebView 側の送信完了 callback で解放される出力バッファ）** の 2 層に分離する。 |
| **3** | **メインスレッドとワーカースレッドの混同** | **【デッドロック / OS 即死】** メインスレッド上で待機を行うと GUI ループが永久停止し、逆にワーカーから GTK/Cocoa/Win32 の生ハンドルを触ると即クラッシュする。 | 通常の IPC ハンドラは `std.Io` のタスク（`Io.Group`）上で動かし、ウィンドウ操作・`eval`・`emit` は **すべてメインループ起床キューへの非同期コマンド投入** に一本化する。 |
| **4** | **`HttpBridgeTransport` での `ipc://` 不整合と Localhost 攻撃リスク** | 通常のブラウザは `fetch('ipc://...')` を `ERR_UNKNOWN_URL_SCHEME` で拒否する。また無防備な HTTP サーバーは別タブの悪意あるサイトから DNS Rebinding / CSRF 攻撃を受ける。 | `@tauri-apps/api` が `window.__TAURI_INTERNALS__` のみを呼ぶ構造を活用し、ブリッジモード時は相対 URL `/__zts_ipc__/<cmd>` + SSE `/__zts_events__` 用 init script を注入。さらに **`HttpOnly; SameSite=Strict` Cookie + `Tauri-Invoke-Key` + `Origin` 厳格一致** を強制する。 |
| **5** | **Linux / Windows WebView 固有の地雷の見落とし** | ・WebKit2GTK 4.1 で大容量 POST ボディを同期 `read` するとプロセス間パイプが詰まりデッドロックする。<br>・Windows で `WebView2Loader.dll` に動的依存すると「単一 `.exe` 配布」が崩れる。 | ・Linux は必ず `g_input_stream_read_all_async` で非同期読み出しを行う。<br>・Windows は `EmbeddedBrowserWebView.dll` を Zig から直接 `LoadLibraryExW` で解決する内蔵ローダー（約 80 行）を採用し完全単一 `.exe` を守る。 |
| **6** | **コア構造体のジェネリクス汚染と C ABI 断絶** + **値返し `Builder.build()`** | ・`App(State)` にすると全下層コードが単相化で肥大化し C ABI も切れない。<br>・`build()` で `App` を値返しすると、OS シグナルに登録した `&app` ポインタがムーブ後にダングリングポインタになる。 | ・`zts.router(&state, Commands)` の入口 1 箇所で **`userdata + fn_ptr` に型消去** し、`zts.App` 本体は 100% 具体型にする。<br>・初期化は **Pinned Pointer 方式（`app.init(...)`）** としアドレス不変性を保証する。 |
| **7** | **Zig `0.17.0` 標準 `std.process.Init` / `std.Io` との不整合** | 独自スレッドプール等を勝手に隠蔽すると、Zig 0.17 の `Io` エコシステム・キャンセル機構・`std.testing.io` によるリーク検査と噛み合わない。 | `Allocator` と `std.Io` を明示的に受け取る設計に統一し、インフライト IPC タスクを `Io.Group` で一括管理・シャットダウン時安全キャンセルする。 |
| **8** | **`std.json` と Serde（`@tauri-apps/api`）の表現差異** | フィールド名の `snake_case` vs `camelCase` や Tagged Union の JSON 形式が食い違う。 | 薄い `comptime` 変換層 `zts.json` を 1 つ置き、**JSON シリアライザと TypeScript `.ts` 生成器が完全に同一の型規則テーブルを参照** する単一ソース設計にする。 |

---

## 2. 「Zig らしさ（Zen of Zig）」に基づく API 全面再設計

### 捨てた「Rust 引きずり」要素 vs 採用した「本物の Zig イディオム」

1. **No Fluent Builder → Plain Config Struct Literal**: メソッドチェーン（`.manage().plugin().build()`）を廃止し、`std.Build` と同じデフォルト値付き構造体リテラル `.{ ... }` で宣言的に構成する。
2. **No Runtime `TypeId` Map → Explicit Typed Pointer (`*AppState`)**: 実行時型マップ検索（`StateManager`）による隠れた失敗を排除し、アプリケーション状態はただの Zig 構造体ポインタ `*AppState` としてコンパイル時に型検査する。
3. **No Hidden Allocations / Threads → Explicit `Allocator` & `std.Io`**: すべての確保と I/O 実行主体を呼び出し側が明示的に渡す（テスト時は `std.testing.allocator` と `std.testing.io` で 100% リーク検知）。
4. **Fat-Pointer Interfaces (`userdata + vtable`)**: `zts.Handler`, `zts.Backend`（Native WebView / HTTP Bridge / Mock Test Backend）, `zts.Plugin` をすべて `std.mem.Allocator` や `std.Io` と同じ Fat Pointer パターンで統一する。これにより **GUI を一切立ち上げない In-Memory Mock Backend でアプリの 100% 単体テストがミリ秒単位で回る**。

---

## 3. 見直し後の Zig 0.17 ネイティブ API イメージ

```zig
const std = @import("std");
const zts = @import("zts");

/// 1. 状態はただの Zig 構造体（TypeId マップも Box<dyn Any> も不要）
pub const AppState = struct {
    mu: std.Io.Mutex = .init,
    count: i64 = 0,
};

/// 2. コマンドは名前空間構造体の `pub fn` 群（マクロ不要・二重登録不要）
///    引数構造体のフィールド名・デフォルト値・Optional から
///    「@tauri-apps/api 互換ルーター」と「bindings.gen.ts」が同時生成される。
pub const Commands = struct {
    /// ゼロヒープ確保の高速コマンド
    pub fn increment(ctx: *zts.Ctx, state: *AppState, args: struct {
        delta: i64 = 1,
    }) !i64 {
        try state.mu.lock(ctx.io);
        defer state.mu.unlock(ctx.io);
        state.count += args.delta;
        return state.count;
    }

    /// 一時アロケーションはスレッドローカル再利用 `ctx.scratch` へ（個別 free 不要）
    /// 戻り値のシリアライズ結果は自動的に Response Buffer へコピーされ安全に非同期送信される。
    pub fn greet(ctx: *zts.Ctx, args: struct {
        user_name: []const u8, // JSON "userName" & TS `userName: string`
        excited: bool = false, // JSON 省略可 & TS `excited?: boolean`
    }) !struct { message: []const u8 } {
        const suffix = if (args.excited) "!!!" else ".";
        return .{
            .message = try std.fmt.allocPrint(ctx.scratch, "Hello, {s}{s}", .{ args.user_name, suffix }),
        };
    }

    /// ゼロコピー生バイナリ入力 + イベント通知
    pub fn sha256(ctx: *zts.Ctx, raw: zts.RawBody) ![32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw.bytes, &digest, .{});
        try ctx.emit("hash-done", .{ .byte_len = raw.bytes.len });
        return digest;
    }
};

/// 3. Zig 0.17 標準の `std.process.Init` を受け取り、Pinned `init` で安全に起動
pub fn main(init: std.process.Init) !void {
    var state: AppState = .{};

    var app: zts.App = undefined; // C コールバックに渡す &app アドレスを固定
    try app.init(init.gpa, init.io, .{
        .app_id = "dev.zts.example",
        .windows = &.{
            .{ .label = "main", .title = "Z-Ts App", .width = 1024, .height = 768 },
        },
        // 既存 Tauri 資産を使う場合は `.config = comptime zts.Config.fromTauriJson(@embedFile("tauri.conf.json"))` も可
        .assets = .{ .dir = zts.embedAssets("dist") },
        .handler = zts.router(&state, Commands), // ← ここで具体型 Handler に型消去！
        .plugins = &zts.plugins.defaults,
    });
    defer app.deinit(); // Io.Group 内の全実行中タスク完了を待ってから安全に解放

    try app.run();
}
```

### 単体テストでの圧倒的な威力（GUI 不要・ポート不要・0.01 秒で E2E 検証！）

`Backend` が Fat Pointer で分離されており、`App` が `Allocator` と `Io` を受け取るため、**ウィンドウも HTTP サーバーも開かずにアプリの IPC・ACL・シリアライズ・エラー処理を直接テストできる**：

```zig
test "increment and ACL check without GUI" {
    var state: AppState = .{};
    var app: zts.App = undefined;
    try app.init(std.testing.allocator, std.testing.io, .{
        .app_id = "dev.zts.test",
        .handler = zts.router(&state, Commands),
        .backend = .headless_mock,
    });
    defer app.deinit(); // 1バイトでもリークがあれば std.testing.allocator が即検出！

    const res = try app.dispatchTestIpc(.{
        .window_label = "main",
        .origin = "tauri://localhost",
        .cmd = "increment",
        .json = "{\"delta\": 5}",
    });
    defer res.deinit();
    try std.testing.expectEqualStrings("5", res.body);
}
```

---

## 4. 最終アーキテクチャ境界（4 つのクリーンな層）

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ Layer 3: User App & Comptime Surface (Generics 許可領域 — 極薄)          │
│   `zts.router(&state, Commands)` / `zts.json` / `zts.tsgen` / `fromJson` │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │ 型消去境界 (`zts.Handler` / `zts.Plugin`)
                                ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Layer 2: Concrete Core Engine (100% 具体型・Pure Zig・libc 不要・C ABI可) │
│   `App` / `Authority (ACL & Scope)` / `EventHub` / `ResourceTable`       │
│   `ScratchPool & ResponseBuffer` / Built-in Plugins (`window`, `fs`...)  │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │ Fat Pointer (`zts.Backend` VTable)
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
┌───────────────────┐ ┌───────────────────┐ ┌──────────────────────────────┐
│ Backend A: Mock   │ │ Backend B: Bridge │ │ Backend C: Native WebView    │
│ In-Memory Direct  │ │ Zig `std.Io.net`  │ │ Thin C ABI Platform Shims    │
│ (0ms Unit/Fuzz    │ │ HTTP + SSE        │ │  - Linux: GTK3 + WebKit2GTK  │
│  Testing)         │ │ (Browser/Arena    │ │  - macOS: ObjC WKWebView     │
│                   │ │  Live Preview/E2E)│ │  - Win32: WebView2 Direct    │
└───────────────────┘ └───────────────────┘ └──────────────────────────────┘
```
