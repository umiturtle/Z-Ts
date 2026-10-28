//! Z-Ts ショーケースサンプル「Counter」の共有アプリケーション実装 (`M2-02`)。
//!
//! **このファイルだけがアプリのロジックを持ちます。** 3 つの成果物は、同じ `App(RuntimeMode)`
//! を comptime パラメータ違いでインスタンス化するだけで生成されます（`if (target)` 分岐 0 行）:
//!
//! | 成果物 | エントリポイント | `RuntimeMode` | `zts_core.Host` 実装 |
//! |---|---|---|---|
//! | デスクトップ単一バイナリ | `src/desktop.zig` | `.desktop` | `WebviewHost`（GTK3 / 将来 WKWebView・WebView2） |
//! | Live Preview（ブラウザ） | `src/live.zig` | `.bridge` | `BridgeHost`（HTTP/1.1 + SSE） |
//! | 静的 SSG Web (`dist/`) | `src/wasm_app.zig` | `.wasm` | `WasmHost`（WebAssembly 線形メモリ） |
//!
//! フロントエンド（`web/main.ts`）は無改造の `@tauri-apps/api` v2 の `invoke` / `listen` だけを
//! 使い、`mode` フィールドを表示する以外に環境判定を一切行いません。

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");
const tauri = @import("zts_tauri");
const wasm = @import("zts_wasm");

/// 3 成果物を区別するための comptime マーカー（JS 側の UA 判定を不要にする）。
pub const RuntimeMode = enum {
    desktop,
    bridge,
    wasm,
};

/// カウンタの値を変更したときにバックエンド → フロントエンドへ配送するイベント名。
pub const changed_event = "counter:changed";

/// `step` / `count` の許容範囲（`i53` = JavaScript の安全整数域と一致）。
pub const step_min: i53 = 1;
pub const step_max: i53 = 100;
pub const count_limit: i53 = std.math.maxInt(i53); // = 2^52 - 1（`i53` は符号込み 53 ビット）

/// フロントエンドへ返すスナップショット（`snake_case` は RPC codec が camelCase へ変換）。
pub const Snapshot = struct {
    count: i53,
    step: i53,
    mutations: u32,
    /// `@tagName(RuntimeMode)` — 表示専用。状態復元には使わない。
    mode: []const u8,
};

/// 指定した実行形態向けのアプリ型を生成する。
pub fn App(comptime runtime: RuntimeMode) type {
    return struct {
        const Self = @This();

        pub const mode: RuntimeMode = runtime;
        pub const mode_name: []const u8 = @tagName(runtime);

        // ------------------------------------------------------------------
        // State
        // ------------------------------------------------------------------

        pub const State = struct {
            allocator: Allocator,
            plugins: *tauri.CorePluginStates,
            count: i53 = 0,
            step: i53 = step_min,
            mutations: u32 = 0,

            pub fn init(allocator: Allocator, plugins: *tauri.CorePluginStates) State {
                return .{ .allocator = allocator, .plugins = plugins };
            }

            pub fn deinit(self: *State) void {
                // 現状は所有ヒープを持たない（`M4-02` のセーブデータ導入時にここで解放する）。
                _ = self;
            }

            pub fn snapshot(self: *const State) Snapshot {
                return .{
                    .count = self.count,
                    .step = self.step,
                    .mutations = self.mutations,
                    .mode = mode_name,
                };
            }
        };

        // ------------------------------------------------------------------
        // RPC commands（`@tauri-apps/api` からは camelCase で見える）
        // ------------------------------------------------------------------

        pub const Commands = struct {
            pub const RpcState = State;

            /// `invoke("getState")` — 現在値を返す（副作用なし）。
            pub fn get_state(state: *State) Snapshot {
                return state.snapshot();
            }

            /// `invoke("increment")` — `step` だけ加算し、`counter:changed` を発火する。
            pub fn increment(ctx: *rpc.Ctx, state: *State) error{CounterOverflow}!Snapshot {
                if (state.count > count_limit - state.step) return error.CounterOverflow;
                state.count += state.step;
                return commit(ctx, state);
            }

            /// `invoke("decrement")` — `step` だけ減算する。
            pub fn decrement(ctx: *rpc.Ctx, state: *State) error{CounterOverflow}!Snapshot {
                if (state.count < -count_limit + state.step) return error.CounterOverflow;
                state.count -= state.step;
                return commit(ctx, state);
            }

            /// `invoke("reset")` — 0 に戻す（`step` は保持）。
            pub fn reset(ctx: *rpc.Ctx, state: *State) !Snapshot {
                state.count = 0;
                return commit(ctx, state);
            }

            /// `invoke("setStep", { step })` — 1〜100 のみ許可。
            pub fn set_step(ctx: *rpc.Ctx, state: *State, args: struct { step: i53 }) !Snapshot {
                if (args.step < step_min or args.step > step_max) return error.StepOutOfRange;
                if (state.step == args.step) {
                    // 値が変わらない場合はイベントを発火しない（フロントエンドの再描画を抑止）。
                    return state.snapshot();
                }
                state.step = args.step;
                return commit(ctx, state);
            }
        };

        /// アプリ独自コマンドのみのスキーマ。Tauri 標準プラグインは `withCorePlugins` で合流させる。
        pub const Schema = rpc.Schema(.{ .app = Commands });

        /// 状態変更を確定し、バックエンド → フロントエンドのイベントを配送する。
        fn commit(ctx: *rpc.Ctx, state: *State) Snapshot {
            state.mutations +%= 1;
            const snapshot = state.snapshot();
            if (ctx.getEnv(core.CallContext)) |call_ctx| {
                // イベント配送はベストエフォート（配送不能でもコマンド自体は成功させる）。
                state.plugins.events.emit(call_ctx.host, ctx.scratch, changed_event, snapshot) catch {};
            }
            return snapshot;
        }

        // ------------------------------------------------------------------
        // `zts_wasm.Instance(Spec)` / `zts_wasm.exportApp(Spec)` 用の Spec
        // ------------------------------------------------------------------

        pub const Spec = struct {
            pub const UserSchema = Schema;
            pub const UserState = State;

            pub const app_config: tauri.AppConfig = .{
                .name = "Z-Ts Counter",
                .version = "0.1.0",
                .identifier = "jp.zts.counter",
                .tauri_version = "2.12.4",
            };
            pub const path_config: tauri.PathState = .{
                .app_identifier = "jp.zts.counter",
                .home_dir = "/home/zts",
                .resource_dir = "/app/resources",
                .executable_dir = "/app/bin",
            };
            pub const main_window: core.WindowSpec = .{
                .label = "main",
                .title = "Z-Ts Counter",
                .size = .wh(520, 620),
                .initial_url = "index.html",
            };

            pub fn initUserState(
                allocator: Allocator,
                plugins: *tauri.CorePluginStates,
                _: *wasm.WasmHost,
            ) Allocator.Error!State {
                return State.init(allocator, plugins);
            }

            pub fn deinitUserState(state: *State) void {
                state.deinit();
            }

            pub fn bindAll(
                comptime Full: type,
                state: *State,
                plugins: *tauri.CorePluginStates,
            ) Full.Router {
                return Full.bind(.{
                    .app = state,
                    .tauri_window = &plugins.windows,
                    .tauri_event = &plugins.events,
                    .tauri_path = &plugins.paths,
                    .tauri_app = &plugins.app_state,
                    .tauri_resources = &plugins.resources,
                    .tauri_menu = &plugins.menu_state,
                    .tauri_tray = &plugins.tray_state,
                });
            }
        };
    };
}

/// デスクトップ / Live Preview の両方で使う Tauri v2 設定値。
pub const app_config: tauri.AppConfig = .{
    .name = "Z-Ts Counter",
    .version = "0.1.0",
    .identifier = "jp.zts.counter",
    .tauri_version = "2.12.4",
};

pub const path_config: tauri.PathState = .{
    .app_identifier = "jp.zts.counter",
    .home_dir = "/home/zts",
    .resource_dir = "/app/resources",
    .executable_dir = "/app/bin",
};

// ============================================================================
// Tests（正常系・異常系・境界値・リーク検査）
// ============================================================================

const TestApp = App(.desktop);

fn newTestState(allocator: Allocator, plugins: *tauri.CorePluginStates) TestApp.State {
    return TestApp.State.init(allocator, plugins);
}

fn dispatchJson(
    handler: rpc.Handler,
    ctx: *rpc.Ctx,
    cmd: []const u8,
    body: []const u8,
) core.OutgoingResponse {
    return handler.dispatch(ctx.scratch, ctx, cmd, body);
}

test "counter: getState defaults, increment/decrement honour step, reset zeroes the count" {
    const plugins = try tauri.CorePluginStates.create(testing.allocator, testing.io, app_config, path_config);
    defer plugins.destroy();
    var state = newTestState(testing.allocator, plugins);
    defer state.deinit();

    var router = TestApp.Schema.bind(.{ .app = &state });
    const handler = router.handler();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = rpc.Ctx.init(testing.io, arena.allocator());

    {
        var resp = dispatchJson(handler, &ctx, "getState", "{}");
        defer resp.deinit();
        try testing.expect(resp.status == .ok);
        try testing.expectEqualStrings(
            "{\"count\":0,\"step\":1,\"mutations\":0,\"mode\":\"desktop\"}",
            resp.body.slice(),
        );
    }

    {
        var resp = dispatchJson(handler, &ctx, "increment", "{}");
        defer resp.deinit();
        try testing.expectEqualStrings(
            "{\"count\":1,\"step\":1,\"mutations\":1,\"mode\":\"desktop\"}",
            resp.body.slice(),
        );
    }

    {
        var resp = dispatchJson(handler, &ctx, "setStep", "{\"step\":5}");
        defer resp.deinit();
        try testing.expectEqualStrings(
            "{\"count\":1,\"step\":5,\"mutations\":2,\"mode\":\"desktop\"}",
            resp.body.slice(),
        );
    }

    {
        var resp = dispatchJson(handler, &ctx, "increment", "{}");
        defer resp.deinit();
        try testing.expectEqualStrings(
            "{\"count\":6,\"step\":5,\"mutations\":3,\"mode\":\"desktop\"}",
            resp.body.slice(),
        );
    }

    {
        var resp = dispatchJson(handler, &ctx, "decrement", "{}");
        defer resp.deinit();
        try testing.expectEqualStrings(
            "{\"count\":1,\"step\":5,\"mutations\":4,\"mode\":\"desktop\"}",
            resp.body.slice(),
        );
    }

    {
        var resp = dispatchJson(handler, &ctx, "reset", "{}");
        defer resp.deinit();
        try testing.expectEqualStrings(
            "{\"count\":0,\"step\":5,\"mutations\":5,\"mode\":\"desktop\"}",
            resp.body.slice(),
        );
    }
}

test "counter: setStep rejects 0/101 and leaves state untouched; equal step does not emit" {
    const plugins = try tauri.CorePluginStates.create(testing.allocator, testing.io, app_config, path_config);
    defer plugins.destroy();
    var state = newTestState(testing.allocator, plugins);
    defer state.deinit();

    var router = TestApp.Schema.bind(.{ .app = &state });
    const handler = router.handler();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = rpc.Ctx.init(testing.io, arena.allocator());

    // 境界値: 0 は下限外、101 は上限外。
    for ([_][]const u8{ "{\"step\":0}", "{\"step\":101}", "{\"step\":-3}" }) |body| {
        var resp = dispatchJson(handler, &ctx, "setStep", body);
        defer resp.deinit();
        try testing.expect(resp.status == .err);
        try testing.expect(std.mem.indexOf(u8, resp.body.slice(), "StepOutOfRange") != null);
        try testing.expectEqual(@as(i53, 1), state.step);
        try testing.expectEqual(@as(u32, 0), state.mutations);
    }

    // 境界値: 1 と 100 は許可。
    {
        var resp = dispatchJson(handler, &ctx, "setStep", "{\"step\":100}");
        defer resp.deinit();
        try testing.expect(resp.status == .ok);
        try testing.expectEqual(@as(i53, 100), state.step);
    }
    {
        var resp = dispatchJson(handler, &ctx, "setStep", "{\"step\":100}");
        defer resp.deinit();
        try testing.expect(resp.status == .ok);
        // 同一値では mutations を進めない。
        try testing.expectEqual(@as(u32, 1), state.mutations);
    }
}

test "counter: i53 overflow is rejected instead of trapping" {
    const plugins = try tauri.CorePluginStates.create(testing.allocator, testing.io, app_config, path_config);
    defer plugins.destroy();
    var state = newTestState(testing.allocator, plugins);
    defer state.deinit();

    var router = TestApp.Schema.bind(.{ .app = &state });
    const handler = router.handler();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = rpc.Ctx.init(testing.io, arena.allocator());

    state.count = count_limit - 1;
    state.step = 2;
    {
        var resp = dispatchJson(handler, &ctx, "increment", "{}");
        defer resp.deinit();
        try testing.expect(resp.status == .err);
        try testing.expect(std.mem.indexOf(u8, resp.body.slice(), "CounterOverflow") != null);
        try testing.expectEqual(count_limit - 1, state.count);
    }

    state.count = -count_limit + 1;
    {
        var resp = dispatchJson(handler, &ctx, "decrement", "{}");
        defer resp.deinit();
        try testing.expect(resp.status == .err);
        try testing.expectEqual(-count_limit + 1, state.count);
    }

    // ちょうど上限に収まる加算は成功する。
    state.count = count_limit - 2;
    state.step = 2;
    {
        var resp = dispatchJson(handler, &ctx, "increment", "{}");
        defer resp.deinit();
        try testing.expect(resp.status == .ok);
        try testing.expectEqual(count_limit, state.count);
    }
}

test "counter: unknown command is rejected and every mutation emits `counter:changed`" {
    const plugins = try tauri.CorePluginStates.create(testing.allocator, testing.io, app_config, path_config);
    defer plugins.destroy();
    var state = newTestState(testing.allocator, plugins);
    defer state.deinit();

    const Recorder = struct {
        var count: usize = 0;
        var last: [256]u8 = undefined;
        var last_len: usize = 0;

        fn onEvent(_: ?*anyopaque, _: []const u8, json: []const u8) void {
            count += 1;
            last_len = @min(json.len, last.len);
            @memcpy(last[0..last_len], json[0..last_len]);
        }
    };
    Recorder.count = 0;
    Recorder.last_len = 0;
    _ = try plugins.events.onNative(changed_event, null, Recorder.onEvent);

    var router = TestApp.Schema.bind(.{ .app = &state });
    const handler = router.handler();

    var spy = core.RecordingHost.init(testing.allocator);
    defer spy.deinit();
    const win = try spy.host().createWindow(.{ .label = "main", .title = "Counter" });
    var call_ctx: core.CallContext = .{ .host = spy.host(), .window_id = win };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = rpc.Ctx.init(testing.io, arena.allocator()).withEnv(&call_ctx);

    {
        var resp = dispatchJson(handler, &ctx, "nope", "{}");
        defer resp.deinit();
        try testing.expect(resp.status == .err);
        try testing.expectEqual(@as(usize, 0), Recorder.count);
    }

    {
        var resp = dispatchJson(handler, &ctx, "increment", "{}");
        defer resp.deinit();
        try testing.expect(resp.status == .ok);
    }
    try testing.expectEqual(@as(usize, 1), Recorder.count);
    try testing.expect(std.mem.indexOf(u8, Recorder.last[0..Recorder.last_len], "\"count\":1") != null);

    {
        var resp = dispatchJson(handler, &ctx, "decrement", "{}");
        defer resp.deinit();
        try testing.expectEqual(@as(usize, 2), Recorder.count);
    }
    {
        var resp = dispatchJson(handler, &ctx, "reset", "{}");
        defer resp.deinit();
        try testing.expectEqual(@as(usize, 3), Recorder.count);
    }
}

test "counter: `Instance(Spec)` lifecycle is leak-free and identical to the native router" {
    const inst = try wasm.Instance(TestApp.Spec).create(testing.allocator);
    defer inst.destroy();

    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("getState", "{}", false));
    try testing.expectEqualStrings(
        "{\"count\":0,\"step\":1,\"mutations\":0,\"mode\":\"desktop\"}",
        inst.last_response.body.slice(),
    );

    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("increment", "{}", false));
    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("increment", "{}", false));
    try testing.expectEqualStrings(
        "{\"count\":2,\"step\":1,\"mutations\":2,\"mode\":\"desktop\"}",
        inst.last_response.body.slice(),
    );

    try testing.expectEqual(@as(i32, 0), inst.invokeRaw("setStep", "{\"step\":0}", false));
    try testing.expectEqualStrings(
        "{\"code\":\"StepOutOfRange\"}",
        inst.last_response.body.slice(),
    );
    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("getState", "{}", false));
    try testing.expectEqualStrings(
        "{\"count\":2,\"step\":1,\"mutations\":2,\"mode\":\"desktop\"}",
        inst.last_response.body.slice(),
    );

    // バックエンドからのイベントは `WasmHost.evalJs` → JS コールバックへ届く。
    const Recorder = struct {
        var frames: usize = 0;
        fn call(_: ?*anyopaque, script: []const u8) void {
            if (std.mem.indexOf(u8, script, "runCallback(") != null) frames += 1;
        }
    };
    Recorder.frames = 0;
    inst.wasm_host.eval_hook = .{ .callFn = Recorder.call };
    defer inst.wasm_host.eval_hook = null;

    try testing.expectEqual(@as(i32, 1), inst.invokeRaw(
        "plugin:event|listen",
        "{\"event\":\"counter:changed\",\"handler\":21}",
        false,
    ));
    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("reset", "{}", false));
    try testing.expect(Recorder.frames >= 1);
}

test "counter: bridge and wasm modes report their own mode tag" {
    inline for (.{ .bridge, .wasm }) |runtime| {
        const Impl = App(runtime);
        try testing.expectEqualStrings(@tagName(runtime), Impl.mode_name);

        const inst = try wasm.Instance(Impl.Spec).create(testing.allocator);
        defer inst.destroy();
        try testing.expectEqual(@as(i32, 1), inst.invokeRaw("getState", "{}", false));
        const body = inst.last_response.body.slice();
        try testing.expect(std.mem.indexOf(u8, body, "has no effect") == null);
        try testing.expect(std.mem.indexOf(u8, body, @tagName(runtime)) != null);
    }
}
