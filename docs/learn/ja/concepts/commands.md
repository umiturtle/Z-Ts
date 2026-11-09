# コマンドが届くまで

> **対象読者**: `invoke("…")` が Zig の関数に届く仕組みを知りたい人。
> **所要時間**: 5 分。

ziggurats の中心にあるのは**「関数を書くだけで、それがコマンドになる」**という考え方です。
ルーティングテーブル、JSON のシリアライザ、TypeScript の型定義は、すべて `comptime` に
生成されます。

## 1. 流れ

```text
  TypeScript                        Zig
  ─────────────────────────────────────────────────────────────
  invoke("setStep", { step: 5 })
        │
        │ ① @tauri-apps/api が IPC メッセージに変換
        ▼
  { cmd: "setStep", args: { step: 5 } }
        │
        │ ② Host（IPC / HTTP / WASM）がバイト列で受ける
        ▼
  Schema.handler()  ── ③ コマンド名でディスパッチ
        │
        ▼
  Commands.set_step(&state, .{ .step = 5 })   ← あなたの関数
        │
        │ ④ 戻り値 / error{X} を JSON に変換
        ▼
  { count: 5 }  /  reject({ code: "StepOutOfRange" })
```

②の `Host` が違うだけで、デスクトップ・ブラウザ・WASM のどれでも同じ ③④ が動きます。

## 2. 関数がコマンドになる条件

```zig
const Commands = struct {
    // invoke("reset")
    pub fn reset(state: *State) !Snapshot { … }

    // invoke("setStep", { step: 5 })
    pub fn set_step(state: *State, args: struct { step: i53 }) !Snapshot { … }

    // コンテキストが欲しいときは *rpc.Ctx を先頭に
    pub fn long_task(ctx: *rpc.Ctx, state: *State) error{Cancelled}!void { … }
};
```

規則は 3 つだけです。

| 位置 | 何 | 省略 |
|---|---|---|
| 先頭 | `*rpc.Ctx`（イベント送信・ホスト操作） | 可能 |
| 2 番目 | 状態（`bind` で渡したポインタ） | 状態を持たない名前空間なら不要 |
| 最後 | `struct { … }`（JSON の引数オブジェクト） | 引数なしなら省略可 |

**戻り値の型は JSON に落ちる型**である必要があります（`struct` / `enum` / 整数 /
`[]const u8` / `rpc.Bytes` / `BigInt` / `Handle` など）。駄目な型は
[`assertValidRpcType`](../../../api/zts_rpc/codec.html#assertValidRpcType) が **ビルド時に**落とします。

## 3. 名前の変換

| Zig | JavaScript |
|---|---|
| `get_state` | `getState` |
| `set_step` | `setStep` |
| `http_get` | `httpGet` |

`snake_case` → `camelCase` の変換は `zts_rpc` が行います。`@tauri-apps/api` を無改造で使えるのは
この変換のおかげです（[`naming`](../../../api/zts_rpc/naming.html)）。

## 4. エラーは型で表す

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

| 層 | 形 |
|---|---|
| Zig | `error{StepOutOfRange}` |
| JSON | `{ "code": "StepOutOfRange" }` |
| HTTP（Preview） | 4xx / 5xx + JSON |
| エラー索引 | [errors.html#error.StepOutOfRange](../../../reference/errors.html) に自動で載る |

## 5. Schema が作るもの

```zig
pub const Schema = rpc.Schema(.{ .app = Commands });
```

`Schema` は **型**です。次のものを `comptime` で持ちます。

- `namespaces` — 名前空間の一覧（`.app`、`.tauri_window` など）
- `bind(env)` → `Router` — 状態を結びつけた実行時オブジェクト
- `handler()` → 2 ワードの `Handler` — トランスポートに渡せる関数ポインタ対
- `ts_bindings` — TypeScript の型定義（`zts_tsgen` が出力）

`handler` が 2 ワードしかないので、HTTP にも IPC にも、テストにもそのまま渡せます。

## 6. テストする

コマンドは普通の関数なので、普通にテストできます。

```zig
test "set_step rejects out-of-range values" {
    var state = State{};
    try std.testing.expectError(error.StepOutOfRange, Commands.set_step(&state, .{ .step = 0 }));
    try std.testing.expectEqual(@as(i53, 1), state.step);
}
```

トランスポート越しに確かめたいときは
[`RecordingHost`](../../../api/zts_core/host.html#RecordingHost) が使えます。実際の WebView を
開かずに、`invoke` → 関数 → 戻り値までを通せます。

## 次に読むもの

- 書き方の実践 → [ガイド: コマンド](../guides/rpc.md)
- プラグインのコマンド → [プラグイン](plugins.md)
- API → [`Schema`](../../../api/zts_rpc/schema.html#Schema) / [`Ctx`](../../../api/zts_rpc/ctx.html#Ctx)
