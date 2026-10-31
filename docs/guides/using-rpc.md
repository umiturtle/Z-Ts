# RPC 層の使い方（`zts_rpc`）

> **対象読者**: アプリのコマンド（`invoke("…")` で呼ばれる関数）を書きたい人。
> **5 分で読めます。** API の全体像は [`../api/zts_rpc/index.html`](../api/zts_rpc/index.html) にあります。

`zts_rpc` は「Zig の関数を、そのまま TypeScript から呼べるコマンドにする」ための層です。
ルーティングテーブルを手で書くことはありません。**関数を書いて、構造体にまとめて、`Schema` に渡すだけ**です。

---

## 1. 30 秒でわかる全体像

```zig
const rpc = @import("zts_rpc");

const Counter = struct {
    /// `invoke("getState")` で呼ばれる。
    pub fn get_state(state: *State) Snapshot { … }

    /// 引数を取るコマンド（`invoke("setStep", { step: 5 })`）。
    pub fn set_step(state: *State, args: struct { step: i53 }) !Snapshot { … }
};

pub const Schema = rpc.Schema(.{ .app = Counter });   // ① スキーマ（型）
var router = Schema.bind(.{ .app = &state });          // ② 状態を結びつける
const handler = router.handler();                      // ③ 型消去されたディスパッチャ
```

```
TypeScript                          Zig
invoke("getState")          →       Counter.get_state(&state)
invoke("setStep", {step:5}) →       Counter.set_step(&state, .{ .step = 5 })
```

| 段階 | 何が起きるか | 型 |
|---|---|---|
| `rpc.Schema(.{ … })` | `comptime` でコマンド表・JSON 型検査・TS 型定義を作る | **型**（`type`） |
| `Schema.bind(env)` | 各名前空間の状態ポインタを束縛する | `Schema.Router` |
| `router.handler()` | 呼び出し規約を隠した 2 ワードの `Handler` | [`Handler`](../api/zts_rpc/ctx.html#Handler) |

`handler` は関数ポインタ 2 語だけの値なので、`zts_bridge`（HTTP+SSE）にも `zts_tauri`（IPC）にも、
テストにもそのまま渡せます。

---

## 2. コマンドを書く

コマンドは**普通の Zig 関数**です。引数の形で 3 通りに分かれます。

```zig
pub const Commands = struct {
    // ① 引数なし: invoke("reset")
    pub fn reset(state: *State) !Snapshot { … }

    // ② 引数あり: invoke("setStep", { step: 5 })  — 匿名 struct が JSON の形になる
    pub fn set_step(state: *State, args: struct { step: i53 }) !Snapshot { … }

    // ③ コンテキストが欲しいとき: *rpc.Ctx を第 1 引数に置く（状態より前）
    pub fn increment(ctx: *rpc.Ctx, state: *State) error{CounterOverflow}!Snapshot { … }
};
```

規則は 3 つだけです。

1. **第 1 引数が `*rpc.Ctx` なら「コンテキスト付き」**と解釈されます。`Ctx` は
   [`Ctx`](../api/zts_rpc/ctx.html#Ctx) で、イベント送出やホスト操作の入口です。
2. **次の引数が「状態」**（`bind` で渡したポインタ）。状態が `void` の名前空間では省略できます。
3. **最後の引数が匿名 `struct`** なら、それが JSON の引数オブジェクトになります。
   引数オブジェクトが不要なら [`canOmitArgs`](../api/zts_rpc/schema.html#canOmitArgs) が真になり、
   `invoke("reset")` と `invoke("reset", {})` の両方を受け付けます。

### 名前の変換

Zig の `snake_case` は JavaScript 側で **`camelCase`** になります（`get_state` → `getState`）。
`@tauri-apps/api` を無改造で使えるのはこの変換のおかげです。変換規則そのものは
[`../api/zts_rpc/naming.html`](../api/zts_rpc/naming.html) にあります。

---

## 3. 戻り値とエラー

戻り値の型は **JSON に落ちる型**である必要があります（`struct` / `enum` / 整数 / `[]const u8` /
`zts_rpc.Bytes` / `BigInt` / `Handle` など）。検査は `comptime` に行われ、駄目な型は
**ビルド時に**落ちます（[`assertValidRpcType`](../api/zts_rpc/codec.html#assertValidRpcType)、
理由の文字列は [`checkRpcType`](../api/zts_rpc/codec.html#checkRpcType)）。

エラーは `error{X}` を返せば、HTTP/IPC のエラー応答になります。

```zig
pub fn set_step(state: *State, args: struct { step: i53 }) error{StepOutOfRange}!Snapshot {
    if (args.step < 1 or args.step > 100) return error.StepOutOfRange;
    …
}
```

```
invoke("setStep", { step: 0 })  →  reject({ code: "StepOutOfRange" })
```

| 層 | 形 |
|---|---|
| Zig | `error{CounterOverflow}` |
| JSON（本文） | `{"code":"CounterOverflow"}` |
| `OutgoingResponse.status` | `.err`（HTTP では 4xx/5xx） |

より細かい制御が要るなら [`Responses`](../api/zts_rpc/ctx.html#Responses) と
[`errorResponseComptime`](../api/zts_rpc/ctx.html#errorResponseComptime) で、HTTP ステータスや
追加フィールドを自分で決められます。認可は [`AuthorizeFn`](../api/zts_rpc/ctx.html#AuthorizeFn) を
`Router.withAuth` に渡すと、全コマンドの前で 1 回だけ走ります。

---

## 4. 状態とコンテキストを渡す

```zig
var state = State.init(allocator, plugins);
var router = Schema.bind(.{ .app = &state });     // 名前空間名 → 状態ポインタ
```

状態を持たない名前空間（純粋関数だけのもの）は `bind(.{ .util = {} })` と書けます。

`Ctx` には**任意の環境ポインタ**を 1 つ載せられます。デスクトップなら
「今どのウィンドウから呼ばれたか」を載せるのが典型です。

```zig
const call_ctx: core.CallContext = .{ .host = host, .window_id = win };
var ctx = rpc.Ctx.init(io, scratch_allocator).withEnv(&call_ctx);

// コマンドの中から:
if (ctx.getEnv(core.CallContext)) |call| {          // 無ければ null
    try state.plugins.events.emit(call.host, ctx.scratch, "counter:changed", snapshot);
}
```

`ctx.scratch` は**その呼び出しの間だけ生きる**アリーナです。レスポンス用の一時確保はここから取ります
（呼び出し終了時にまとめて解放されるので、リークの心配がありません）。

---

## 5. TypeScript を生成する

スキーマから `bindings.gen.ts` を作れます。生成物は**コミット対象**にして、ビルド前に
「古くなっていないか」を検証するのがおすすめです（`zts` はこの検証を自動では行いません）。

```zig
// 手で呼ぶ場合
const ts = try zts_rpc.tsgen.generateAlloc(allocator, Schema);
try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "web/bindings.gen.ts", .data = ts });
```

```zig
// build.zig に組み込む場合（推奨・M5-01）
const gen = zts_build.tsgenBindings(b, .{
    .schema_mod = b.createModule(.{ .root_source_file = b.path("src/bindings_schema.zig") }),
    .output_path = "web/bindings.gen.ts",
});
b.step("tsgen", "Regenerate the TypeScript bindings").dependOn(gen.step);
```

生成される型は `--strict` / `--exactOptionalPropertyTypes` / `--erasableSyntaxOnly` を通る形で、
`i53` は `number`、`u64`/`i64` は `bigint`、`[]const u8` は `string`、`Bytes` は `Uint8Array` に落ちます。
コマンドごとの `Args` / `Result` 型と `invoke` のオーバーロードが付くので、
**フロントエンド側で型を手書きする必要はありません**。

```ts
import { invoke } from "@tauri-apps/api/core";
const s = await invoke("getState");        // s は Snapshot 型に推論される
```

---

## 6. ディスパッチを自分で呼ぶ（テスト・独自トランスポート）

`Handler` は「コマンド名 + JSON 本文」を受け取る普通の関数です。テストではこれを直接叩けます。

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

`resp.body` は [`OwnedBytes`](../api/zts_foundation/owned_bytes.html#OwnedBytes) です。
大きい応答ではスタックにコピーせず、内部バッファを参照したまま返るので、
**`deinit()` を忘れない**でください（`defer` で十分です）。

---

## 7. つまずきどころ

| 症状 | 原因と対処 |
|---|---|
| `Schema expects a struct literal of namespaces` | `rpc.Schema(Commands)` と書いた。`rpc.Schema(.{ .app = Commands })` が正しい。 |
| `… is not a valid RPC type` | `i128` / `*T` / `HashMap` など JSON に落ちない型を戻り値にした。`i53` か `BigInt` を使う。 |
| `invoke` が `undefined` を返す | コマンド名が `camelCase` になっているか確認（`get_state` → `getState`）。 |
| 引数が `null` になる | 引数 struct のフィールド名も `camelCase` に変換される。`step` はそのまま、`max_count` は `maxCount`。 |
| 生成した `.ts` と実装がずれた | プロジェクトに足した `tsgen` ステップ（`zig build tsgen`）で再生成し、**生成物もコミット**する。 |

---

## 次に読むもの

- API: [`zts_rpc`](../api/zts_rpc/index.html) / [`Schema`](../api/zts_rpc/schema.html#Schema) /
  [`Ctx`](../api/zts_rpc/ctx.html#Ctx) / [`codec`](../api/zts_rpc/codec.html) /
  [`tsgen`](../api/zts_rpc/tsgen.html)
- 実例: [`../../examples/counter/README.md`](../../examples/counter/README.md)（全コマンドが実装済み）
- 設計の背景: [`../architecture/rpc-codec.md`](../architecture/rpc-codec.md)（内部資料）,
  [`../decisions/0004-tauri-v2-wire-and-deterministic-tsgen.md`](../decisions/0004-tauri-v2-wire-and-deterministic-tsgen.md)
- API ページの読み方: [`using-the-api-reference.md`](using-the-api-reference.md)
- 送り手側: [`using-plugins.md`](using-plugins.md)（Tauri 標準プラグイン） /
  [`using-ssg.md`](using-ssg.md)（同じスキーマを WASM で動かす）
