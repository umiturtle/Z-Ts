# Commands in practice (`zts_rpc`)

> **Audience**: readers writing app commands (the functions `invoke("…")` reaches).
> **Time**: 10 minutes. The full API surface is in
> [`zts_rpc`](../../../api/zts_rpc/index.html).

`zts_rpc` exists so that **a Zig function becomes a command TypeScript can call**. You never write
a routing table: write the function, group it in a struct, hand the struct to `Schema`.

---

## 1. The whole picture in 30 seconds

```zig
const rpc = @import("zts_rpc");

const Counter = struct {
    /// Called by `invoke("getState")`.
    pub fn get_state(state: *State) Snapshot { … }

    /// Takes arguments: `invoke("setStep", { step: 5 })`.
    pub fn set_step(state: *State, args: struct { step: i53 }) !Snapshot { … }
};

pub const Schema = rpc.Schema(.{ .app = Counter });   // ① the schema (a type)
var router = Schema.bind(.{ .app = &state });          // ② attach state
const handler = router.handler();                      // ③ type-erased dispatcher
```

```text
TypeScript                          Zig
invoke("getState")          →       Counter.get_state(&state)
invoke("setStep", {step:5}) →       Counter.set_step(&state, .{ .step = 5 })
```

| Step | What happens | Type |
|---|---|---|
| `rpc.Schema(.{ … })` | builds the command table, JSON type checks and TS declarations at `comptime` | **a type** (`type`) |
| `Schema.bind(env)` | binds the state pointer of each namespace | `Schema.Router` |
| `router.handler()` | a two-word `Handler` that hides the calling convention | [`Handler`](../../../api/zts_rpc/ctx.html#Handler) |

### A minimal example that compiles (CI checks it)

This is the diagram above with the `…` filled in. Blocks tagged `zig check` are compiled by
[`scripts/doc-tests.py`](../../../../scripts/doc-tests.py), so a renamed API turns this page red.

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const State = struct { count: i32 = 0, step: i32 = 1 };

const Commands = struct {
    pub fn get_state(state: *State) !struct { count: i32, step: i32 } {
        return .{ .count = state.count, .step = state.step };
    }

    pub fn increment(state: *State) !i32 {
        state.count += state.step;
        return state.count;
    }
};

const Schema = rpc.Schema(.{ .app = Commands });

test "the schema has one namespace" {
    try std.testing.expectEqual(@as(usize, 1), Schema.namespaces.len);
}
```

`handler` is only two words of function pointers, so `zts_bridge` (HTTP + SSE), `zts_tauri` (IPC)
and your tests can all take it directly.

---

## 2. Writing a command

Commands are **ordinary Zig functions**. The argument shape picks one of three forms.

```zig
pub const Commands = struct {
    // ① no arguments: invoke("reset")
    pub fn reset(state: *State) !Snapshot { … }

    // ② arguments: invoke("setStep", { step: 5 }) — the anonymous struct is the JSON shape
    pub fn set_step(state: *State, args: struct { step: i53 }) !Snapshot { … }

    // ③ wanting the context: *rpc.Ctx goes first (before state)
    pub fn increment(ctx: *rpc.Ctx, state: *State) error{CounterOverflow}!Snapshot { … }
};
```

Three rules.

1. **A first parameter of `*rpc.Ctx` means "context attached"**. `Ctx` is
   [`Ctx`](../../../api/zts_rpc/ctx.html#Ctx), the door to event emission and host calls.
2. **The next parameter is "state"** (the pointer given to `bind`). It can be omitted for a
   stateless namespace.
3. **A trailing anonymous `struct` is the JSON argument object.** With no argument object
   [`canOmitArgs`](../../../api/zts_rpc/schema.html#canOmitArgs) becomes true, so both
   `invoke("reset")` and `invoke("reset", {})` are accepted.

### Name mapping

Zig `snake_case` becomes **`camelCase`** on the JavaScript side (`get_state` → `getState`). That
one rule is what makes `@tauri-apps/api` work unmodified. The rules themselves live in
[`naming`](../../../api/zts_rpc/naming.html).

---

## 3. Return values and errors

Return types must **fall out as JSON** (`struct` / `enum` / integers / `[]const u8` /
`zts_rpc.Bytes` / `BigInt` / `Handle`, …). The check runs at `comptime`, so a bad type fails **at
build time** ([`assertValidRpcType`](../../../api/zts_rpc/codec.html#assertValidRpcType); the
human-readable reason comes from [`checkRpcType`](../../../api/zts_rpc/codec.html#checkRpcType)).

An `error{X}` return turns into an error response over HTTP/IPC.

```zig
pub fn set_step(state: *State, args: struct { step: i53 }) error{StepOutOfRange}!Snapshot {
    if (args.step < 1 or args.step > 100) return error.StepOutOfRange;
    …
}
```

```text
invoke("setStep", { step: 0 })  →  reject({ code: "StepOutOfRange" })
```

| Layer | Shape |
|---|---|
| Zig | `error{CounterOverflow}` |
| JSON body | `{"code":"CounterOverflow"}` |
| `OutgoingResponse.status` | `.err` (4xx/5xx over HTTP) |

Need finer control? [`Responses`](../../../api/zts_rpc/ctx.html#Responses) and
[`errorResponseComptime`](../../../api/zts_rpc/ctx.html#errorResponseComptime) let you choose the
HTTP status and extra fields. For authorisation, pass an
[`AuthorizeFn`](../../../api/zts_rpc/ctx.html#AuthorizeFn) to `Router.withAuth`; it runs once
before every command.

---

## 4. Passing state and context

```zig
var state = State.init(allocator, plugins);
var router = Schema.bind(.{ .app = &state });     // namespace name → state pointer
```

A stateless namespace (pure functions only) is written `bind(.{ .util = {} })`.

`Ctx` carries **one arbitrary environment pointer**. On desktop the typical payload is "which
window called this".

```zig
const call_ctx: core.CallContext = .{ .host = host, .window_id = win };
var ctx = rpc.Ctx.init(io, scratch_allocator).withEnv(&call_ctx);

// inside the command:
if (ctx.getEnv(core.CallContext)) |call| {          // null when absent
    try state.plugins.events.emit(call.host, ctx.scratch, "counter:changed", snapshot);
}
```

`ctx.scratch` is an arena that **lives only for this call**. Response buffers come from it and are
freed together at the end — no leaks to chase.

---

## 5. Generating TypeScript

You can generate `bindings.gen.ts` from the schema. **Commit the output** and verify before a build
that it is not stale (`zts` does not check this for you).

```zig
// by hand
const ts = try zts_rpc.tsgen.generateAlloc(allocator, Schema);
try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "web/bindings.gen.ts", .data = ts });
```

```zig
// wired into build.zig (recommended)
const gen = zts_build.tsgenBindings(b, .{
    .schema_mod = b.createModule(.{ .root_source_file = b.path("src/bindings_schema.zig") }),
    .output_path = "web/bindings.gen.ts",
});
b.step("tsgen", "Regenerate the TypeScript bindings").dependOn(gen.step);
```

The generated types pass `--strict`, `--exactOptionalPropertyTypes` and `--erasableSyntaxOnly`;
`i53` becomes `number`, `u64`/`i64` become `bigint`, `[]const u8` becomes `string` and `Bytes`
becomes `Uint8Array`. Every command gets `Args` / `Result` types and an `invoke` overload, so
**you never hand-write frontend types**.

```ts
import { invoke } from "@tauri-apps/api/core";
const s = await invoke("getState");        // inferred as Snapshot
```

---

## 6. Calling dispatch yourself (tests, custom transports)

A `Handler` is a plain function taking "command name + JSON body". Tests can call it directly.

```zig
var router = Schema.bind(.{ .app = &state });
const handler = router.handler();

var ctx = rpc.Ctx.init(testing.io, arena.allocator());
var resp = handler.dispatch(ctx.scratch, &ctx, "getState", "{}");
defer resp.deinit();

try std.testing.expectEqual(core.IpcStatus.ok, resp.status);
try std.testing.expectEqualStrings(
    "{\"count\":0,\"step\":1,\"mutations\":0,\"mode\":\"desktop\"}", resp.body.slice());
```

`resp.body` is an [`OwnedBytes`](../../../api/zts_foundation/owned_bytes.html#OwnedBytes). Large
responses are returned by reference to an internal buffer instead of being copied onto the stack,
so **do not forget `deinit()`** (`defer` is enough).

---

## 7. Usual traps

| Symptom | Cause and fix |
|---|---|
| `Schema expects a struct literal of namespaces` | you wrote `rpc.Schema(Commands)`; the correct form is `rpc.Schema(.{ .app = Commands })` |
| `… is not a valid RPC type` | the return type is `i128` / `*T` / `HashMap` — not JSON-able. Use `i53` or `BigInt` |
| `invoke` returns `undefined` | check the camelCase name (`get_state` → `getState`) |
| arguments arrive as `null` | struct field names are camelCased too: `step` stays, `max_count` becomes `maxCount` |
| the generated `.ts` drifted from the code | regenerate with your `tsgen` step (`zig build tsgen`) and **commit the output** |

---

## Next

- API: [`zts_rpc`](../../../api/zts_rpc/index.html) / [`Schema`](../../../api/zts_rpc/schema.html#Schema) /
  [`Ctx`](../../../api/zts_rpc/ctx.html#Ctx) / [`codec`](../../../api/zts_rpc/codec.html) /
  [`tsgen`](../../../api/zts_rpc/tsgen.html)
- A real app: [`examples/counter/README.md`](../../../../examples/counter/README.md) (every command implemented)
- Design background: [`docs/architecture/rpc-codec.md`](../../../architecture/rpc-codec.md),
  [`docs/decisions/0004-tauri-v2-wire-and-deterministic-tsgen.md`](../../../decisions/0004-tauri-v2-wire-and-deterministic-tsgen.md)
- The transport side: [Plugins](plugins.md) and [Static sites](static-site.md) (the same schema
  running in WASM)
