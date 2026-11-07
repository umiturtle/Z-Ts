# How a command travels

> **Audience**: readers who want to know how `invoke("…")` reaches a Zig function.
> **Time**: 5 minutes.

The idea at the centre of Z-Ts: **write a function and it becomes a command**. The routing
table, the JSON serialiser and the TypeScript declarations are all generated at `comptime`.

## 1. The path

```text
  TypeScript                        Zig
  ─────────────────────────────────────────────────────────────
  invoke("setStep", { step: 5 })
        │
        │ ① @tauri-apps/api turns it into an IPC message
        ▼
  { cmd: "setStep", args: { step: 5 } }
        │
        │ ② a Host (IPC / HTTP / WASM) receives the bytes
        ▼
  Schema.handler()  ── ③ dispatch on the command name
        │
        ▼
  Commands.set_step(&state, .{ .step = 5 })   ← your function
        │
        │ ④ turn the return value or error{X} into JSON
        ▼
  { count: 5 }  /  reject({ code: "StepOutOfRange" })
```

Only ② differs between desktop, browser and WASM. ③ and ④ are identical everywhere.

## 2. When a function becomes a command

```zig
const Commands = struct {
    // invoke("reset")
    pub fn reset(state: *State) !Snapshot { … }

    // invoke("setStep", { step: 5 })
    pub fn set_step(state: *State, args: struct { step: i53 }) !Snapshot { … }

    // want the context? put *rpc.Ctx first
    pub fn long_task(ctx: *rpc.Ctx, state: *State) error{Cancelled}!void { … }
};
```

Three rules, that is all.

| Position | What | Optional |
|---|---|---|
| first | `*rpc.Ctx` (emit events, drive the host) | yes |
| second | state (the pointer passed to `bind`) | yes, for stateless namespaces |
| last | `struct { … }` (the JSON argument object) | yes, when there are no arguments |

**Return types must be JSON-able** (`struct` / `enum` / integers / `[]const u8` / `rpc.Bytes` /
`BigInt` / `Handle`, …). Anything else is rejected **at build time** by
[`assertValidRpcType`](../../../api/zts_rpc/codec.html#assertValidRpcType).

## 3. Name mapping

| Zig | JavaScript |
|---|---|
| `get_state` | `getState` |
| `set_step` | `setStep` |
| `http_get` | `httpGet` |

`snake_case` → `camelCase` is done by `zts_rpc`, which is exactly what lets unmodified
`@tauri-apps/api` work ([`naming`](../../../api/zts_rpc/naming.html)).

## 4. Errors are types

```zig
pub fn set_step(state: *State, args: struct { step: i53 }) error{StepOutOfRange}!Snapshot {
    if (args.step < 1 or args.step > 100) return error.StepOutOfRange;
    state.step = args.step;
    return state.snapshot();
}
```

```ts
try {
  await invoke("setStep", { step: 0 });
} catch (e) {
  console.log(e); // "StepOutOfRange"
}
```

| Layer | Shape |
|---|---|
| Zig | `error{StepOutOfRange}` |
| JSON | `{ "code": "StepOutOfRange" }` |
| HTTP (preview) | 4xx / 5xx plus a JSON body |
| Error index | appears automatically at [errors.html#error.StepOutOfRange](../../../reference/errors.html) |

## 5. What `Schema` produces

```zig
pub const Schema = rpc.Schema(.{ .app = Commands });
```

`Schema` is a **type**. At `comptime` it carries:

- `namespaces` — the namespace list (`.app`, `.tauri_window`, …)
- `bind(env)` → `Router` — a runtime object with state attached
- `handler()` → a two-word `Handler` — a pair of function pointers any transport can accept
- `ts_bindings` — the TypeScript declarations (`zts_tsgen` writes them out)

Because `handler` is two words, it goes straight into HTTP, IPC, or a test.

## 6. Testing

Commands are ordinary functions, so test them ordinarily.

```zig
test "set_step rejects out-of-range values" {
    var state = State{};
    try std.testing.expectError(error.StepOutOfRange, Commands.set_step(&state, .{ .step = 0 }));
    try std.testing.expectEqual(@as(i53, 1), state.step);
}
```

To exercise the transport too, use
[`RecordingHost`](../../../api/zts_core/host.html#RecordingHost): it runs `invoke` → function →
return value without opening a WebView.

## Next

- How to write them for real → [Guide: commands](../guides/rpc.md)
- Plugin commands → [Plugins](plugins.md)
- API → [`Schema`](../../../api/zts_rpc/schema.html#Schema) / [`Ctx`](../../../api/zts_rpc/ctx.html#Ctx)
