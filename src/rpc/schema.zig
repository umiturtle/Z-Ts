//! `comptime` RPC Router Composition (`Schema` / `bind`) (`src/rpc/schema.zig`).
//!
//! Implements the two-stage architecture established in `ADR-0002` §3.1 & §4:
//! 1. **Compile-time Schema composition (`pub const Rpc = zts.rpc.Schema(.{ ... });`)**:
//!    - Merges multiple stateless or stateful command namespaces (`""`, `"plugin:window|"`, etc.)
//!      into a single static dispatch table with **zero heap allocations** and full Dead Code Elimination.
//!    - Validates all command argument and return types via `codec.assertValidRpcType` at compile time.
//!    - Exposes full compile-time reflection metadata (`namespaces`, `commands`) + `ts_bindings` for `tsgen`.
//! 2. **Runtime State binding (`var router = Rpc.bind(.{ .app = &state, ... });`)**:
//!    - Binds runtime state pointers (stateless namespaces may pass `{}` or be omitted entirely!)
//!      and produces a type-erased `Handler` fat pointer (`router.handler()`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("../core/mod.zig");
const codec = @import("codec.zig");
const ctx_mod = @import("ctx.zig");
const naming = @import("naming.zig");
const tsgen = @import("tsgen.zig");
const types = @import("types.zig");

pub const Ctx = ctx_mod.Ctx;
pub const AuthorizeFn = ctx_mod.AuthorizeFn;
pub const Handler = ctx_mod.Handler;

/// Compile-time metadata describing one namespace passed into `Schema(.{ ... })`.
pub const NamespaceMeta = struct {
    name: [:0]const u8,
    prefix: []const u8,
    State: type,
    Cmds: type,
};

/// Compile-time metadata describing one discovered `pub fn` RPC command.
pub const CommandMeta = struct {
    ns_index: usize,
    ns_name: [:0]const u8,
    prefix: []const u8,
    fn_name: [:0]const u8,
    /// Primary wire command string (`camelCase` when `prefix == ""`, else `prefix ++ fn_name`).
    wire_name: []const u8,
    /// Secondary alias (`snake_case` when `prefix == ""`, else `prefix ++ camelCase(fn_name)`), if distinct.
    alt_wire_name: ?[]const u8,
    /// JS method name inside generated TS client namespace/root (`camelCase`).
    ts_method_name: []const u8,
    State: type,
    Args: type,
    Payload: type,
    /// True if calling this command in TS allows omitting the `args` argument (`void` or all-default struct).
    args_optional: bool,
    /// Closed `error_set` type when function returns `E!Payload`, `anyerror` if open error set, or `null` if infallible.
    ErrorSet: ?type,
};

fn parseNamespaceSpec(comptime ns_name: [:0]const u8, comptime entry: anytype) NamespaceMeta {
    const EntryType = @TypeOf(entry);
    if (EntryType == type) {
        const Cmds = entry;
        if (@typeInfo(Cmds) != .@"struct") {
            @compileError("zts_rpc.Schema: namespace '" ++ ns_name ++ "' type must be a struct containing pub fn commands.");
        }
        const prefix: []const u8 = if (@hasDecl(Cmds, "rpc_prefix")) Cmds.rpc_prefix else "";
        const State = if (@hasDecl(Cmds, "RpcState")) Cmds.RpcState else void;
        return .{
            .name = ns_name,
            .prefix = prefix,
            .State = State,
            .Cmds = Cmds,
        };
    }

    if (@typeInfo(EntryType) != .@"struct") {
        @compileError("zts_rpc.Schema: namespace '" ++ ns_name ++ "' must be a command struct type or .{ .prefix = ..., .State = ..., .Cmds = ... }.");
    }
    if (!@hasField(EntryType, "Cmds")) {
        @compileError("zts_rpc.Schema: namespace spec '" ++ ns_name ++ "' is missing required '.Cmds' field.");
    }
    const Cmds = entry.Cmds;
    const prefix: []const u8 = if (@hasField(EntryType, "prefix"))
        entry.prefix
    else if (@hasDecl(Cmds, "rpc_prefix"))
        Cmds.rpc_prefix
    else
        "";
    const State = if (@hasField(EntryType, "State")) entry.State else void;

    return .{
        .name = ns_name,
        .prefix = prefix,
        .State = State,
        .Cmds = Cmds,
    };
}

pub fn canOmitArgs(comptime Args: type) bool {
    if (Args == void) return true;
    const info = @typeInfo(Args);
    if (info != .@"struct" or info.@"struct".is_tuple) return false;
    if (types.isBigIntType(Args) or Args == types.SafeInt or Args == types.Bytes or
        Args == types.OsPath or types.isHandleType(Args) or types.isTaggedUnionWrapper(Args))
    {
        return false;
    }
    const s = info.@"struct";
    for (s.field_types, s.field_attrs) |FType, f_attr| {
        if (f_attr.defaultValue(FType) == null and !types.isPatchType(FType)) {
            return false;
        }
    }
    return true;
}

const FnSignatureInfo = struct {
    ctx_idx: ?usize,
    state_idx: ?usize,
    args_idx: ?usize,
    Args: type,
    Payload: type,
    ErrorSet: ?type,
};

fn inspectCommandFn(comptime ns: NamespaceMeta, comptime fn_name: [:0]const u8, comptime FnType: type) FnSignatureInfo {
    const fn_info = @typeInfo(FnType).@"fn";
    if (fn_info.attrs.varargs or fn_info.return_type == null) {
        @compileError("zts_rpc.Schema: command '" ++ ns.name ++ "." ++ fn_name ++ "' cannot be generic (`anytype`) or variadic.");
    }

    var ctx_idx: ?usize = null;
    var state_idx: ?usize = null;
    var args_idx: ?usize = null;
    var ArgsType: type = void;

    for (fn_info.param_types, 0..) |maybe_param_type, idx| {
        const P = maybe_param_type orelse @compileError("zts_rpc.Schema: command '" ++ ns.name ++ "." ++ fn_name ++ "' cannot use `anytype` parameters.");
        if (P == *Ctx or P == *const Ctx) {
            if (ctx_idx != null) @compileError("zts_rpc.Schema: duplicate Ctx parameter in '" ++ fn_name ++ "'");
            ctx_idx = idx;
        } else if (ns.State != void and (P == *ns.State or P == *const ns.State)) {
            if (state_idx != null) @compileError("zts_rpc.Schema: duplicate State parameter in '" ++ fn_name ++ "'");
            state_idx = idx;
        } else {
            if (args_idx != null) {
                @compileError("zts_rpc.Schema: command '" ++ ns.name ++ "." ++ fn_name ++ "' has multiple payload parameters; group command inputs into a single `args: struct { ... }`.");
            }
            args_idx = idx;
            ArgsType = P;
        }
    }

    if (ArgsType != void) {
        codec.assertValidRpcType(ArgsType);
    }

    const Ret = fn_info.return_type.?;
    var Payload: type = Ret;
    var ErrorSet: ?type = null;

    if (@typeInfo(Ret) == .error_union) {
        const eu = @typeInfo(Ret).error_union;
        Payload = eu.payload;
        ErrorSet = eu.error_set;
    }

    if (Payload != core.OwnedBytes) {
        codec.assertValidRpcType(Payload);
    }

    return .{
        .ctx_idx = ctx_idx,
        .state_idx = state_idx,
        .args_idx = args_idx,
        .Args = ArgsType,
        .Payload = Payload,
        .ErrorSet = ErrorSet,
    };
}

/// Builds a statically typed, zero-allocation RPC Router Schema from one or more command namespaces.
pub fn Schema(comptime specs: anytype) type {
    const SpecsType = @TypeOf(specs);
    const specs_info = @typeInfo(SpecsType);
    if (specs_info != .@"struct") {
        @compileError("zts_rpc.Schema expects a struct literal of namespaces, e.g. Schema(.{ .app = AppCommands })");
    }

    const ns_count = specs_info.@"struct".field_names.len;
    const parsed_namespaces: [ns_count]NamespaceMeta = comptime blk: {
        var arr: [ns_count]NamespaceMeta = undefined;
        for (specs_info.@"struct".field_names, 0..) |ns_name, i| {
            arr[i] = parseNamespaceSpec(ns_name, @field(specs, ns_name));
        }
        break :blk arr;
    };

    const total_cmds: usize = comptime blk: {
        var count: usize = 0;
        for (parsed_namespaces) |ns| {
            for (@typeInfo(ns.Cmds).@"struct".decl_names) |decl_name| {
                const DeclT = @TypeOf(@field(ns.Cmds, decl_name));
                if (@typeInfo(DeclT) == .@"fn") count += 1;
            }
        }
        break :blk count;
    };

    const parsed_commands: [total_cmds]CommandMeta = comptime blk: {
        var list: [total_cmds]CommandMeta = undefined;
        var idx: usize = 0;
        for (parsed_namespaces, 0..) |ns, ns_idx| {
            for (@typeInfo(ns.Cmds).@"struct".decl_names) |decl_name| {
                const fn_val = @field(ns.Cmds, decl_name);
                const FnT = @TypeOf(fn_val);
                if (@typeInfo(FnT) != .@"fn") continue;

                const sig = inspectCommandFn(ns, decl_name, FnT);
                const camel = naming.snakeToCamel(decl_name);
                const primary: []const u8 = if (ns.prefix.len == 0) camel else (ns.prefix ++ decl_name);
                const secondary_candidate: []const u8 = if (ns.prefix.len == 0) decl_name else (ns.prefix ++ camel);
                const alt: ?[]const u8 = if (!std.mem.eql(u8, primary, secondary_candidate)) secondary_candidate else null;

                for (list[0..idx]) |prev| {
                    if (std.mem.eql(u8, prev.wire_name, primary)) {
                        @compileError("zts_rpc.Schema: duplicate wire command name '" ++ primary ++ "'");
                    }
                }

                list[idx] = .{
                    .ns_index = ns_idx,
                    .ns_name = ns.name,
                    .prefix = ns.prefix,
                    .fn_name = decl_name,
                    .wire_name = primary,
                    .alt_wire_name = alt,
                    .ts_method_name = camel,
                    .State = ns.State,
                    .Args = sig.Args,
                    .Payload = sig.Payload,
                    .args_optional = canOmitArgs(sig.Args),
                    .ErrorSet = sig.ErrorSet,
                };
                idx += 1;
            }
        }
        break :blk list;
    };

    const route_entries_len: usize = comptime blk: {
        var n: usize = 0;
        for (parsed_commands) |c| {
            n += 1;
            if (c.alt_wire_name != null) n += 1;
        }
        break :blk n;
    };

    const route_map = comptime blk: {
        const KV = struct { []const u8, usize };
        var kvs: [route_entries_len]KV = undefined;
        var k: usize = 0;
        for (parsed_commands, 0..) |c, cmd_i| {
            kvs[k] = .{ c.wire_name, cmd_i };
            k += 1;
            if (c.alt_wire_name) |alt_name| {
                var collides = false;
                for (parsed_commands) |other| {
                    if (std.mem.eql(u8, other.wire_name, alt_name)) collides = true;
                }
                if (!collides) {
                    kvs[k] = .{ alt_name, cmd_i };
                    k += 1;
                }
            }
        }
        break :blk std.StaticStringMap(usize).initComptime(kvs[0..k]);
    };

    return struct {
        const SelfSchema = @This();

        pub const namespaces: []const NamespaceMeta = &parsed_namespaces;
        pub const commands: []const CommandMeta = &parsed_commands;

        /// Complete TypeScript bindings & client module generated entirely at `comptime`.
        pub const ts_bindings: []const u8 = tsgen.generateComptime(SelfSchema);

        /// Writes generated TypeScript bindings to any `std.Io.Writer`.
        pub fn writeTsBindings(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(ts_bindings);
        }

        const StatePtrTuple = blk: {
            var field_names: [ns_count][:0]const u8 = undefined;
            var field_types: [ns_count]type = undefined;
            var field_attrs: [ns_count]std.builtin.Type.Struct.FieldAttributes = undefined;

            for (parsed_namespaces, 0..) |ns, i| {
                field_names[i] = ns.name;
                field_types[i] = if (ns.State == void) void else *ns.State;
                field_attrs[i] = .{};
            }
            break :blk @Struct(.auto, null, &field_names, &field_types, &field_attrs);
        };

        /// Concrete stack-allocatable router holding bound state pointers (`*State`).
        pub const Router = struct {
            states: StatePtrTuple,
            authorize_fn: ?AuthorizeFn = null,
            encode_options: codec.EncodeOptions = .{},

            /// Returns a lightweight 2-word `Handler` fat pointer pointing to `self`.
            /// `self` MUST remain pinned in memory while the returned `Handler` is active.
            pub fn handler(self: *Router) Handler {
                return .{
                    .userdata = self,
                    .dispatchFn = typeErasedDispatch,
                };
            }

            pub fn withAuth(self: Router, auth_fn: AuthorizeFn) Router {
                var copy = self;
                copy.authorize_fn = auth_fn;
                return copy;
            }

            fn typeErasedDispatch(
                userdata: ?*anyopaque,
                resp_allocator: Allocator,
                ctx: *Ctx,
                command: []const u8,
                payload: []const u8,
            ) core.OutgoingResponse {
                const self: *Router = @ptrCast(@alignCast(userdata.?));

                if (self.authorize_fn) |auth| {
                    if (!auth(ctx, command)) return ctx_mod.Responses.forbidden;
                }

                const cmd_idx = route_map.get(command) orelse return ctx_mod.Responses.unknown_command;

                inline for (parsed_commands, 0..) |cmd, i| {
                    if (i == cmd_idx) {
                        return invokeSingleCommand(self, cmd, resp_allocator, ctx, payload);
                    }
                }
                unreachable;
            }
        };

        /// Binds runtime state pointers for all stateful namespaces and returns a `Router`.
        /// Stateless namespaces (`State == void`) may either pass `{}` or be omitted entirely.
        pub fn bind(bindings: anytype) Router {
            var ptrs: StatePtrTuple = undefined;
            const BType = @TypeOf(bindings);

            inline for (parsed_namespaces) |ns| {
                if (ns.State == void) {
                    @field(ptrs, ns.name) = {};
                } else {
                    if (!@hasField(BType, ns.name)) {
                        @compileError("zts_rpc.Schema.bind: missing state pointer '." ++ ns.name ++ ": *" ++ @typeName(ns.State) ++ "'");
                    }
                    @field(ptrs, ns.name) = @field(bindings, ns.name);
                }
            }
            return .{ .states = ptrs };
        }

        fn invokeSingleCommand(
            router: *Router,
            comptime cmd: CommandMeta,
            resp_allocator: Allocator,
            ctx: *Ctx,
            raw_payload: []const u8,
        ) core.OutgoingResponse {
            const ns = parsed_namespaces[cmd.ns_index];
            const fn_ptr = @field(ns.Cmds, cmd.fn_name);
            const FnT = @TypeOf(fn_ptr);
            const sig = comptime inspectCommandFn(ns, cmd.fn_name, FnT);

            const decoded_args: cmd.Args = if (cmd.Args == void) {} else if (cmd.Args == types.Bytes) blk: {
                const trimmed = std.mem.trim(u8, raw_payload, " \t\r\n");
                if (trimmed.len > 0 and (trimmed[0] == '"' or trimmed[0] == '[')) {
                    break :blk codec.decodeLeaky(types.Bytes, ctx.scratch, trimmed) catch |err| {
                        return ctx_mod.errorResponseComptime(400, err);
                    };
                }
                break :blk types.Bytes.init(raw_payload);
            } else blk: {
                const effective_json = if (std.mem.trim(u8, raw_payload, " \t\r\n").len == 0) "{}" else raw_payload;
                break :blk codec.decodeLeaky(cmd.Args, ctx.scratch, effective_json) catch |err| {
                    return ctx_mod.errorResponseComptime(400, err);
                };
            };

            var call_args: std.meta.ArgsTuple(FnT) = undefined;
            if (sig.ctx_idx) |ci| call_args[ci] = ctx;
            if (sig.state_idx) |si| call_args[si] = @field(router.states, ns.name);
            if (sig.args_idx) |ai| call_args[ai] = decoded_args;

            const payload_val: cmd.Payload = if (cmd.ErrorSet != null)
                @call(.auto, fn_ptr, call_args) catch |err| {
                    return ctx_mod.errorResponseComptime(400, err);
                }
            else
                @call(.auto, fn_ptr, call_args);

            return serializeCommandResult(cmd.Payload, resp_allocator, payload_val, router.encode_options);
        }

        fn serializeCommandResult(
            comptime Payload: type,
            resp_allocator: Allocator,
            val: Payload,
            encode_options: codec.EncodeOptions,
        ) core.OutgoingResponse {
            if (Payload == void) return ctx_mod.Responses.ok_null;
            if (Payload == bool) return if (val) ctx_mod.Responses.ok_true else ctx_mod.Responses.ok_false;
            if (Payload == core.OwnedBytes) {
                return .{
                    .status = .ok,
                    .http_code = 200,
                    .content_type = "application/octet-stream",
                    .body = val,
                };
            }
            if (Payload == types.Bytes) {
                const bin = core.OwnedBytes.dupe(resp_allocator, val.slice()) catch return ctx_mod.Responses.internal_oom;
                return .{
                    .status = .ok,
                    .http_code = 200,
                    .content_type = "application/octet-stream",
                    .body = bin,
                };
            }

            const json_slice = codec.encodeAllocWithOptions(resp_allocator, val, encode_options) catch |err| {
                return ctx_mod.errorResponseComptime(500, err);
            };
            return .{
                .status = .ok,
                .http_code = 200,
                .content_type = "application/json",
                .body = core.OwnedBytes.fromOwnedSlice(resp_allocator, json_slice),
            };
        }
    };
}

/// Alias matching `ADR-0002` `zts.rpc.merge(.{ ... })` terminology.
pub const merge = Schema;

// ============================================================================
// Unit Tests
// ============================================================================

test "Schema & bind compose stateful + Host-driven plugins with 0-allocation errors & Auth guard" {
    const AppState = struct {
        mu: std.Io.Mutex = .init,
        count: i53 = 0,
    };

    const AppCommands = struct {
        pub fn increment(ctx: *Ctx, state: *AppState, args: struct {
            delta: i53 = 1,
        }) error{ OutOfRange, NegativeStep }!i53 {
            if (args.delta < 0) return error.NegativeStep;
            if (args.delta > 1_000_000) return error.OutOfRange;
            state.mu.lockUncancelable(ctx.io);
            defer state.mu.unlock(ctx.io);
            state.count += args.delta;
            return state.count;
        }

        // JS reserved word `delete` + zero-copy string slice + void return
        pub fn delete(state: *AppState, args: struct { reason: []const u8 }) void {
            if (args.reason.len > 0) state.count = 0;
        }
    };

    const WindowPlugin = struct {
        pub const rpc_prefix = "plugin:window|";

        pub fn set_title(ctx: *Ctx, args: struct {
            window: core.WindowId,
            title: []const u8,
        }) core.HostError!void {
            try ctx.host.setWindowTitle(args.window, args.title);
        }
    };

    const Rpc = Schema(.{
        .app = .{ .prefix = "", .State = AppState, .Cmds = AppCommands },
        .window = WindowPlugin,
    });

    var state = AppState{};
    var spy = core.RecordingHost.init(testing.allocator);
    defer spy.deinit();
    const win_id = try spy.host().createWindow(.{ .title = "Before" });

    var router = Rpc.bind(.{ .app = &state }).withAuth(struct {
        fn allow(ctx: *const Ctx, cmd: []const u8) bool {
            if (std.mem.eql(u8, ctx.origin, "https://evil.example")) return false;
            return cmd.len > 0;
        }
    }.allow);
    const h = router.handler();

    // 1. Default omitted field (`""` -> `delta = 1`) + explicit delta
    {
        var r1 = h.invoke(testing.allocator, testing.io, "increment", "");
        defer r1.deinit();
        try testing.expectEqual(core.IpcStatus.ok, r1.status);
        try testing.expectEqualStrings("1", r1.body.slice());

        var r2 = h.invoke(testing.allocator, testing.io, "increment", "{\"delta\":41}");
        defer r2.deinit();
        try testing.expectEqualStrings("42", r2.body.slice());
    }

    // 2. Domain ErrorSet (`OutOfRange`) allocates literally ZERO bytes on the heap!
    {
        var ctx = Ctx.init(testing.io, testing.failing_allocator);
        var err_resp = h.dispatch(testing.failing_allocator, &ctx, "increment", "{\"delta\":9999999}");
        defer err_resp.deinit();
        try testing.expectEqual(core.IpcStatus.err, err_resp.status);
        try testing.expectEqual(@as(u16, 400), err_resp.http_code);
        try testing.expectEqualStrings("{\"code\":\"OutOfRange\"}", err_resp.body.slice());
    }

    // 3. Unknown command & Forbidden Origin also allocate literally ZERO bytes on the heap!
    {
        var ctx = Ctx.init(testing.io, testing.failing_allocator);
        var not_found = h.dispatch(testing.failing_allocator, &ctx, "noSuchCmd", "{}");
        defer not_found.deinit();
        try testing.expectEqual(@as(u16, 404), not_found.http_code);
        try testing.expectEqualStrings("{\"code\":\"UnknownCommand\"}", not_found.body.slice());

        ctx.origin = "https://evil.example";
        var denied = h.dispatch(testing.failing_allocator, &ctx, "increment", "{}");
        defer denied.deinit();
        try testing.expectEqual(@as(u16, 403), denied.http_code);
        try testing.expectEqualStrings("{\"code\":\"Forbidden\"}", denied.body.slice());
    }

    // 4. `plugin:window|set_title` mutates `RecordingHost` window title via `core.WindowId` with 0 heap allocs!
    {
        var req_buf: [128]u8 = undefined;
        const req_json = try std.fmt.bufPrint(&req_buf, "{{\"window\":{d},\"title\":\"After RPC!\"}}", .{win_id.toU53()});
        var ctx = Ctx{
            .io = testing.io,
            .scratch = testing.failing_allocator,
            .host = spy.host(),
            .window_id = win_id,
            .origin = "tauri://localhost",
        };
        var ok_win = h.dispatch(testing.failing_allocator, &ctx, "plugin:window|set_title", req_json);
        defer ok_win.deinit();
        try testing.expectEqual(core.IpcStatus.ok, ok_win.status);
        try testing.expectEqualStrings("null", ok_win.body.slice());
        try testing.expectEqualStrings("After RPC!", spy.windows.get(win_id).?.title);
    }

    // 5. Reserved word `delete` resets state with 0 heap allocations (`void` -> static `"null"`)
    {
        var ctx = Ctx.init(testing.io, testing.failing_allocator);
        var del_resp = h.dispatch(testing.failing_allocator, &ctx, "delete", "{\"reason\":\"cleanup\"}");
        defer del_resp.deinit();
        try testing.expectEqual(core.IpcStatus.ok, del_resp.status);
        try testing.expectEqual(@as(i53, 0), state.count);
    }

    // 6. Unknown command fails in O(1) with 0 heap allocations (`testing.failing_allocator`)
    {
        var ctx = Ctx.init(testing.io, testing.failing_allocator);
        var missing = h.dispatch(testing.failing_allocator, &ctx, "does_not_exist", "{}");
        defer missing.deinit();
        try testing.expectEqual(core.IpcStatus.err, missing.status);
        try testing.expectEqualStrings("{\"code\":\"UnknownCommand\"}", missing.body.slice());
    }
}

test "Schema supports binary `Bytes` responses, stateless `merge`, empty body defaults, and 2,000 concurrent RPC calls" {
    const BinaryPlugin = struct {
        pub const rpc_prefix = "blob:";

        pub fn raw_header() types.Bytes {
            return .init("\x89PNG\r\n\x1a\n");
        }
    };

    const SharedCounter = struct {
        atomic_hits: std.atomic.Value(u32) = .init(0),
    };

    const CounterCmds = struct {
        pub fn hit(state: *SharedCounter, args: struct { weight: u32 = 1 }) u32 {
            return state.atomic_hits.fetchAdd(args.weight, .monotonic) + args.weight;
        }
    };

    const CombinedRpc = merge(.{
        .counter = .{ .State = SharedCounter, .Cmds = CounterCmds },
        .blob = BinaryPlugin,
    });

    var shared = SharedCounter{};
    var router = CombinedRpc.bind(.{ .counter = &shared });
    const h = router.handler();

    // 1. Raw binary `Bytes` response sets `application/octet-stream` without Base64 wrapping
    {
        var bin_resp = h.invoke(testing.allocator, testing.io, "blob:raw_header", "");
        defer bin_resp.deinit();
        try testing.expectEqual(core.IpcStatus.ok, bin_resp.status);
        try testing.expectEqualStrings("application/octet-stream", bin_resp.content_type);
        try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", bin_resp.body.slice());
    }

    // 2. Empty raw payload `""` populates all-default `args` cleanly
    {
        var hit_resp = h.invoke(testing.allocator, testing.io, "hit", "");
        defer hit_resp.deinit();
        try testing.expectEqual(core.IpcStatus.ok, hit_resp.status);
        try testing.expectEqualStrings("1", hit_resp.body.slice());
    }

    // 3. Multi-producer concurrent dispatch stress test (8 workers x 250 calls = 2,000 invocations reusing per-worker Arenas)
    shared.atomic_hits.store(0, .release);

    const Worker = struct {
        fn run(io: std.Io, handler: Handler) std.Io.Cancelable!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();

            var i: usize = 0;
            while (i < 250) : (i += 1) {
                _ = arena.reset(.retain_capacity);
                var ctx = Ctx.init(io, arena.allocator());
                var r = handler.dispatch(testing.allocator, &ctx, "hit", "{\"weight\":1}");
                defer r.deinit();
                std.debug.assert(r.status == .ok);
            }
        }
    };

    var group: std.Io.Group = .init;
    defer group.cancel(testing.io);
    for (0..8) |_| {
        try group.concurrent(testing.io, Worker.run, .{ testing.io, h });
    }
    try group.await(testing.io);

    try testing.expectEqual(@as(u32, 2000), shared.atomic_hits.load(.acquire));
}
