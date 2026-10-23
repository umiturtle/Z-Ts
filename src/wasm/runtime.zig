//! Generic Isomorphic Wasm Application Container & C ABI Exporter (`src/wasm/runtime.zig`).
//!
//! Turns ANY Z-Ts application (`rpc.Schema` + `tauri.CorePluginStates` + user state) into a
//! standalone `wasm32-freestanding` `.wasm` binary with a single `comptime` declaration:
//!
//! ```zig
//! pub const wasm_exports = zts_wasm.exportApp(MyWasmSpec);
//! ```
//!
//! And equally allows instantiating `Instance(MyWasmSpec)` in native unit tests (`std.testing.allocator`)
//! to verify zero-leak lifecycles at 0ms speed!

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const foundation = @import("zts_foundation");
const core = @import("zts_core");
const rpc = @import("zts_rpc");
const tauri = @import("zts_tauri");

const host_mod = @import("host.zig");
const io_stub = @import("io_stub.zig");

pub const ResponseKind = enum(u32) {
    json = 0,
    binary = 1,
    text = 2,
};

fn responseKindOf(resp: *const foundation.OutgoingResponse) ResponseKind {
    const ct = resp.content_type;
    if (std.mem.startsWith(u8, ct, "application/octet-stream")) return .binary;
    if (std.mem.startsWith(u8, ct, "application/json")) return .json;
    return .text;
}

/// Instantiates a heap-pinned isomorphic runtime housing `WasmHost`, `tauri.CorePluginStates`,
/// and user-defined state & `rpc.Schema` bindings.
///
/// Expected `Spec` declarations:
/// - `pub const UserSchema = rpc.Schema(...);`
/// - `pub const UserState: type;`
/// - `pub const app_config: tauri.AppConfig;`
/// - `pub const path_config: tauri.PathState;`
/// - `pub const main_window: core.WindowSpec;`
/// - `pub fn initUserState(allocator: Allocator, plugins: *tauri.CorePluginStates, host: *host_mod.WasmHost) Allocator.Error!UserState`
/// - `pub fn deinitUserState(state: *UserState) void`
/// - `pub fn bindAll(comptime FullSchema: type, user_state: *UserState, plugins: *tauri.CorePluginStates) FullSchema.Router`
pub fn Instance(comptime Spec: type) type {
    const MergedSchema = tauri.withCorePlugins(Spec.UserSchema);

    return struct {
        const Self = @This();
        pub const FullSchema = MergedSchema;

        allocator: Allocator,
        wasm_host: host_mod.WasmHost,
        plugins: *tauri.CorePluginStates,
        user_state: Spec.UserState,
        /// Pinned router storage — `bound.handler()` points directly into this struct.
        bound: MergedSchema.Router,
        main_win_id: core.WindowId,
        last_response: foundation.OutgoingResponse = .{
            .status = .ok,
            .content_type = "application/json",
            .body = foundation.OwnedBytes.static("null"),
        },

        pub fn create(allocator: Allocator) !*Self {
            const io = io_stub.wasmIo();
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const wh = host_mod.WasmHost.init(allocator);
            errdefer {
                var copy = wh;
                copy.deinit();
            }

            const plugins = try tauri.CorePluginStates.create(
                allocator,
                io,
                Spec.app_config,
                Spec.path_config,
            );
            errdefer plugins.destroy();

            self.* = .{
                .allocator = allocator,
                .wasm_host = wh,
                .plugins = plugins,
                .user_state = undefined,
                .bound = undefined,
                .main_win_id = .invalid,
            };

            self.user_state = try Spec.initUserState(allocator, self.plugins, &self.wasm_host);
            errdefer Spec.deinitUserState(&self.user_state);

            self.bound = Spec.bindAll(MergedSchema, &self.user_state, self.plugins);

            const wid = try self.wasm_host.host().createWindow(Spec.main_window);
            try self.plugins.windows.registerWindow(wid, Spec.main_window);
            self.main_win_id = wid;

            return self;
        }

        pub fn destroy(self: *Self) void {
            const alloc = self.allocator;
            self.last_response.body.deinit();
            Spec.deinitUserState(&self.user_state);
            self.plugins.destroy();
            self.wasm_host.deinit();
            alloc.destroy(self);
        }

        /// Dispatches `cmd` with `body` exactly like the native `ipc://` / HTTP bridge transports.
        pub fn invokeRaw(self: *Self, cmd: []const u8, body: []const u8, is_binary: bool) i32 {
            self.last_response.body.deinit();

            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();

            var call_ctx: core.CallContext = .{
                .host = self.wasm_host.host(),
                .window_id = self.main_win_id,
            };

            var ctx = rpc.Ctx.init(io_stub.wasmIo(), arena_state.allocator())
                .withEnv(&call_ctx);
            ctx.origin = "https://zts-ssg.local";
            ctx.raw_body = body;
            _ = is_binary;

            self.last_response = self.bound.handler().dispatch(self.allocator, &ctx, cmd, body);
            return if (self.last_response.status == .ok) 1 else 0;
        }

        pub fn responseKind(self: *const Self) ResponseKind {
            return responseKindOf(&self.last_response);
        }
    };
}

/// Emits standard C ABI WebAssembly exports (`zts_wasm_*`) for `Spec` when targeting `wasm32`.
pub fn exportApp(comptime Spec: type) type {
    return struct {
        const AppInstance = Instance(Spec);
        var global_instance: ?*AppInstance = null;

        fn backingAllocator() Allocator {
            if (builtin.cpu.arch.isWasm()) return std.heap.wasm_allocator;
            return std.heap.page_allocator;
        }

        pub fn init() callconv(.c) i32 {
            if (global_instance != null) return 0;
            global_instance = AppInstance.create(backingAllocator()) catch return -1;
            return 0;
        }

        pub fn deinit() callconv(.c) void {
            if (global_instance) |inst| {
                inst.destroy();
                global_instance = null;
            }
        }

        pub fn alloc(len: usize) callconv(.c) ?[*]u8 {
            if (len == 0) return null;
            const buf = backingAllocator().alloc(u8, len) catch return null;
            return buf.ptr;
        }

        pub fn free(ptr: [*]u8, len: usize) callconv(.c) void {
            if (len == 0) return;
            backingAllocator().free(ptr[0..len]);
        }

        pub fn invoke(
            cmd_ptr: [*]const u8,
            cmd_len: usize,
            body_ptr: [*]const u8,
            body_len: usize,
            is_binary: u32,
        ) callconv(.c) i32 {
            if (global_instance == null) {
                if (init() != 0) return -1;
            }
            const inst = global_instance.?;
            const cmd = if (cmd_len > 0) cmd_ptr[0..cmd_len] else "";
            const body = if (body_len > 0) body_ptr[0..body_len] else "";
            return inst.invokeRaw(cmd, body, is_binary != 0);
        }

        pub fn responsePtr() callconv(.c) ?[*]const u8 {
            const inst = global_instance orelse return null;
            const slice = inst.last_response.body.slice();
            return if (slice.len > 0) slice.ptr else null;
        }

        pub fn responseLen() callconv(.c) usize {
            const inst = global_instance orelse return 0;
            return inst.last_response.body.slice().len;
        }

        pub fn responseKind() callconv(.c) u32 {
            const inst = global_instance orelse return 0;
            return @backingInt(inst.responseKind());
        }

        pub fn responseDispose() callconv(.c) void {
            const inst = global_instance orelse return;
            inst.last_response.body.deinit();
            inst.last_response.body = foundation.OwnedBytes.static("");
        }

        comptime {
            if (builtin.cpu.arch.isWasm()) {
                @export(&init, .{ .name = "zts_wasm_init", .linkage = .strong });
                @export(&deinit, .{ .name = "zts_wasm_deinit", .linkage = .strong });
                @export(&alloc, .{ .name = "zts_wasm_alloc", .linkage = .strong });
                @export(&free, .{ .name = "zts_wasm_free", .linkage = .strong });
                @export(&invoke, .{ .name = "zts_wasm_invoke", .linkage = .strong });
                @export(&responsePtr, .{ .name = "zts_wasm_response_ptr", .linkage = .strong });
                @export(&responseLen, .{ .name = "zts_wasm_response_len", .linkage = .strong });
                @export(&responseKind, .{ .name = "zts_wasm_response_kind", .linkage = .strong });
                @export(&responseDispose, .{ .name = "zts_wasm_response_dispose", .linkage = .strong });
            }
        }
    };
}

test "Wasm Instance executes user RPC + Tauri core plugins with zero leaks in-memory" {
    const CounterCmds = struct {
        pub const RpcState = u32;

        pub fn add(state: *u32, args: struct { delta: u32 }) u32 {
            state.* += args.delta;
            return state.*;
        }
    };
    const CounterSchema = rpc.Schema(.{ .app = CounterCmds });
    const Spec = struct {
        pub const UserSchema = CounterSchema;
        pub const UserState = u32;
        pub const app_config: tauri.AppConfig = .{ .name = "WasmUnit", .version = "1.0.0", .identifier = "jp.zts.wasm" };
        pub const path_config: tauri.PathState = .{};
        pub const main_window: core.WindowSpec = .{ .label = "main", .title = "Boot" };
        pub fn initUserState(_: Allocator, _: *tauri.CorePluginStates, _: *host_mod.WasmHost) Allocator.Error!u32 {
            return 10;
        }
        pub fn deinitUserState(_: *u32) void {}
        pub fn bindAll(comptime Full: type, user_state: *u32, plugins: *tauri.CorePluginStates) Full.Router {
            return Full.bind(.{
                .app = user_state,
                .tauri_window = &plugins.windows,
                .tauri_event = &plugins.events,
                .tauri_path = &plugins.paths,
                .tauri_app = &plugins.app_state,
                .tauri_resources = &plugins.resources,
            });
        }
    };

    const inst = try Instance(Spec).create(testing.allocator);
    defer inst.destroy();

    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("add", "{\"delta\":32}", false));
    try testing.expectEqualStrings("42", inst.last_response.body.slice());
    try testing.expectEqual(@as(i32, 1), inst.invokeRaw("plugin:app|name", "{}", false));
    try testing.expectEqualStrings("\"WasmUnit\"", inst.last_response.body.slice());
}
