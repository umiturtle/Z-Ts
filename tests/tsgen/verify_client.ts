// Strict compile-time (`tsc`) + live Node <-> Zig RPC roundtrip test suite (`M1-04`).
import {
  createRpcClient,
  ZtsRpcError,
  type FileHandle,
  type RpcTransport,
  type TransferLedgerError,
  type WindowHandle,
  type WireResponse,
} from "./bindings.gen.ts";

// Minimal ambient declarations so `tsc --strict --erasableSyntaxOnly` checks cleanly without downloading `@types/node`.
declare const process: {
  readonly stdin: AsyncIterable<Uint8Array> & {
    setEncoding(enc: "utf8"): AsyncIterable<string>;
    pause(): void;
  };
  readonly stdout: { write(chunk: string): boolean };
};

// ============================================================================
// 1. Negative Compile-Time Type Assertions (`@ts-expect-error`)
//    If `tsgen` ever weakens types to `any` / plain `number` / `string`,
//    `tsc --strict --exactOptionalPropertyTypes --erasableSyntaxOnly` FAILS here!
// ============================================================================
function _compileTimeTypeProofs(client: ReturnType<typeof createRpcClient>): void {
  const winId = 1 as WindowHandle;
  const fileId = 2 as FileHandle;

  // Branded handles MUST NOT be interchangeable!
  // @ts-expect-error FileHandle is not assignable to WindowHandle
  const _badHandleSwap: WindowHandle = fileId;
  void _badHandleSwap;

  // Plain unbranded `number` MUST NOT be accepted where `WindowHandle` is required!
  // @ts-expect-error plain number is not assignable to WindowHandle
  void client.inspectHandle({ win: 123, file: fileId });

  // Required nullable field `reqToken: string | null` CANNOT be omitted!
  // @ts-expect-error missing required property `reqToken`
  void client.updateProfile({ shape: { kind: "clear" } });

  // Under `--exactOptionalPropertyTypes`, passing explicit `undefined` to `retryLimit?: number` is rejected!
  // @ts-expect-error exactOptionalPropertyTypes forbids explicit `undefined` on optional property
  void client.transferLedger({
    delta: 1n,
    signature: new Uint8Array([1]),
    "aria-label": "test",
    retryLimit: undefined,
  });

  // Exhaustive ErrorSet narrowing proof: `TransferLedgerError` is strictly `"InsufficientFunds" | "InvalidSignature"`!
  const checkExhaustive = (code: TransferLedgerError): number => {
    switch (code) {
      case "InsufficientFunds":
        return 1;
      case "InvalidSignature":
        return 2;
      default: {
        const _exhaustive: never = code;
        return _exhaustive;
      }
    }
  };
  void checkExhaustive;
  void winId;
}
void _compileTimeTypeProofs;

// ============================================================================
// 2. Live Bi-Directional Node.js <-> Zig `Router` E2E Execution over Stdio Pipe
// ============================================================================
function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

async function* readLinesUtf8(): AsyncGenerator<string, void, undefined> {
  let buf = "";
  for await (const chunk of process.stdin.setEncoding("utf8")) {
    buf += chunk;
    let nl = buf.indexOf("\n");
    while (nl !== -1) {
      const line = buf.slice(0, nl).replace(/\r$/, "");
      buf = buf.slice(nl + 1);
      yield line;
      nl = buf.indexOf("\n");
    }
  }
}

async function main(): Promise<void> {
  const lines = readLinesUtf8();

  const stdioZigTransport: RpcTransport = {
    async invoke(command: string, args: unknown): Promise<WireResponse> {
      const packet = JSON.stringify({ command, payload: JSON.stringify(args) });
      process.stdout.write(packet + "\n");
      const next = await lines.next();
      if (next.done) {
        throw new Error("Unexpected EOF from Zig RPC host");
      }
      return JSON.parse(next.value) as WireResponse;
    },
  };

  const rpc = createRpcClient(stdioZigTransport);

  // Roundtrip 1: >53-bit `bigint` (`9007199254740995n + 5n = 9007199254741000n`), `Uint8Array` binary, and `"aria-label"`
  const sig = new Uint8Array([0x00, 0xde, 0xad, 0xbe, 0xef, 0xff]);
  const tx = await rpc.transferLedger({
    delta: 5n,
    signature: sig,
    "aria-label": "Z-Ts送金",
  });
  assert(typeof tx.newBalance === "bigint", "newBalance must be native JS bigint");
  assert(tx.newBalance === 9007199254741000n, `expected exact 9007199254741000n, got ${tx.newBalance}`);
  assert(tx.echoSig instanceof Uint8Array, "echoSig must be native Uint8Array");
  assert(tx.echoSig.length === sig.length && tx.echoSig[2] === 0xad && tx.echoSig[5] === 0xff, "Uint8Array bytes mismatch");
  assert(tx.labelLen === 10, `expected UTF-8 byte len 10, got ${tx.labelLen}`);

  // Roundtrip 2: `$try` mode returns typed `{ ok: false, error: { code: "InsufficientFunds" } }` with 0 Zig heap allocs
  const failedTx = await rpc.$try.transferLedger({
    delta: -99999999999999999999n,
    signature: sig,
    "aria-label": "overdraft",
  });
  assert(!failedTx.ok && failedTx.error.code === "InsufficientFunds", "expected InsufficientFunds error code");

  // Roundtrip 3: Throwing mode throws `ZtsRpcError` with `.code === "InvalidSignature"`
  let caughtCode = "";
  try {
    await rpc.transferLedger({
      delta: 1n,
      signature: new Uint8Array([]),
      "aria-label": "empty-sig",
    });
  } catch (e: unknown) {
    if (e instanceof ZtsRpcError) caughtCode = e.code;
  }
  assert(caughtCode === "InvalidSignature", `expected InvalidSignature, got ${caughtCode}`);

  // Roundtrip 4: `Patch(T)` 3-state proof — omitted (`unchanged`) keeps `"initial"`, then `null` clears to `"cleared-bio"`
  const unchangedBio = await rpc.updateProfile({
    reqToken: null,
    shape: { kind: "clear" },
  });
  assert(unchangedBio === "initial", `expected unchanged bio 'initial', got ${unchangedBio}`);

  const clearedBio = await rpc.updateProfile({
    reqToken: "tok_1",
    bio: null,
    shape: { kind: "clear" },
  });
  assert(clearedBio === "cleared-bio", `expected 'cleared-bio', got ${clearedBio}`);

  // Roundtrip 5: Generational 53-bit `Handle` rejects forged `generation == 0` handles AND echoes valid `(gen=1, idx=42)` handles!
  const forgedRes = await rpc.$try.inspectHandle({
    win: 42 as WindowHandle,
    file: 99 as FileHandle,
  });
  assert(!forgedRes.ok && (forgedRes.error.code as string) === "InvalidHandle", "expected forged gen=0 handle to be rejected");

  const validWin = (4294967296 + 42) as WindowHandle; // generation = 1, index = 42
  const validFile = (4294967296 + 99) as FileHandle; // generation = 1, index = 99
  const echoedWin = await rpc.inspectHandle({
    win: validWin,
    file: validFile,
  });
  assert((echoedWin as number) === (validWin as number), "expected echoed 53-bit generational WindowHandle");

  assert((await rpc.delete()) === false, "delete() default force should be false");
  assert((await rpc.delete({ force: true })) === true, "delete({ force: true }) should be true");

  await rpc.window.setTitle({ window: validWin, title: "Updated Window" });
  const winErr = await rpc.$try.window.setTitle({ window: validWin, title: "" });
  assert(!winErr.ok && winErr.error.code === "WindowNotFound", "expected WindowNotFound");

  process.stdout.write("DONE\n");
  process.stdin.pause();
}

await main();
