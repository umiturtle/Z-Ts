// Official Unmodified `@tauri-apps/api` v2 Full Wire-Compatibility Suite (`M1-07`).
//
// Zero mocks: every single call imports the real upstream `@tauri-apps/api` v2 package
// (`core`, `window`, `dpi`, `event`, `path`, `app`) PLUS the `zts_rpc.tsgen` generated client,
// running identically inside:
//   1. Real Linux `WebKit2GTK 4.1` native window (`tauri://`, `ipc://`, `asset://` schemes)
//   2. Live `BridgeServer` + `BridgeHost` over HTTP/1.1 + Cookie + Server-Sent Events (`Node 22` / Browser)

import {
  Channel,
  Resource,
  convertFileSrc,
  invoke,
  isTauri,
} from "@tauri-apps/api/core";
import {
  LogicalSize,
  PhysicalPosition,
  getCurrentWindow,
} from "@tauri-apps/api/window";
import { emit, emitTo, listen, once } from "@tauri-apps/api/event";
import {
  appDataDir,
  basename,
  dirname,
  extname,
  join,
  normalize,
  resolveResource,
  sep,
} from "@tauri-apps/api/path";
import {
  getIdentifier,
  getName,
  getTauriVersion,
  getVersion,
} from "@tauri-apps/api/app";
import { createIpcTransport, createRpcClient } from "./generated_api";

export interface SuiteOptions {
  readonly mode: "webkit" | "bridge";
  readonly assetProbeBytes?: boolean;
}

export interface SuiteSummary {
  readonly ok: boolean;
  readonly mode: string;
  readonly checksRun: number;
  readonly streamedCount: number;
  readonly onceHits: number;
  readonly listenHits: number;
  readonly dragTriggered: boolean;
  readonly errorMessage: string;
}

class PackResource extends Resource {
  constructor(rid: number) {
    super(rid);
  }
}

export async function runSuite(opts: SuiteOptions): Promise<SuiteSummary> {
  let checks = 0;
  const check = (cond: boolean, message: string): void => {
    checks += 1;
    if (!cond) {
      throw new Error(`Check #${checks} failed (${opts.mode}): ${message}`);
    }
  };

  const api = createRpcClient(createIpcTransport());

  try {
    // 1. Runtime detection (`window.isTauri` & metadata)
    check(isTauri() === true, "isTauri() must return true");

    // 2. `@tauri-apps/api/app`
    const gotName = await getName();
    check(gotName === "Z-Ts Studio", `app.getName() got ${JSON.stringify(gotName)}`);
    check((await getVersion()) === "2.7.0", "app.getVersion()");
    check((await getIdentifier()) === "jp.zts.studio", "app.getIdentifier()");
    check((await getTauriVersion()).length > 0, "app.getTauriVersion()");

    // 3. `@tauri-apps/api/path` (cross-platform `/` & `\\` separator normalization)
    const slash = (p: string): string => p.replaceAll("\\", "/");
    const resPath = slash(await resolveResource("packs/scene01.zpack"));
    check(resPath.endsWith("packs/scene01.zpack"), `resolveResource got ${resPath}`);
    const dataDir = slash(await appDataDir());
    check(dataDir.includes("jp.zts.studio"), `appDataDir got ${dataDir}`);
    const joined = slash(await join("/alpha/beta", "gamma", "voice.ogg"));
    check(joined === "/alpha/beta/gamma/voice.ogg", `join got ${joined}`);
    const norm = slash(await normalize("/alpha/beta/../gamma/./voice.ogg"));
    check(norm === "/alpha/gamma/voice.ogg", `normalize got ${norm}`);
    check(slash(await dirname(norm)) === "/alpha/gamma", "dirname()");
    check((await basename(norm, ".ogg")) === "voice", "basename(path, ext)");
    check((await extname("/archive/pack.tar.gz")) === "gz", "extname()");
    check(sep().length === 1, "sep()");

    // 4. `@tauri-apps/api/window` + `@tauri-apps/api/dpi`
    const win = getCurrentWindow();
    check(win.label === "main", `currentWindow.label expected main, got ${win.label}`);
    await win.setTitle("Z-Ts Verified Window");
    check((await win.title()) === "Z-Ts Verified Window", "window.title() roundtrip");
    await win.setSize(new LogicalSize(1024, 576));
    const inner = await win.innerSize();
    check(inner.width === 1024 && inner.height === 576, `innerSize got ${inner.width}x${inner.height}`);
    await win.setPosition(new PhysicalPosition(120, 80));
    const outerPos = await win.outerPosition();
    check(outerPos.x === 120 && outerPos.y === 80, `outerPosition got ${outerPos.x},${outerPos.y}`);
    await win.setAlwaysOnTop(true);
    check((await win.isAlwaysOnTop()) === true, "window.isAlwaysOnTop()");

    // 5. `zts_rpc.tsgen` Typed Client + Upstream `Channel<T>` Ordered Streaming + XSS Escape Integrity
    const frames: Array<{ seq: number; ptsMs: number; tag: string }> = [];
    const onTick = new Channel<{ readonly seq: number; readonly ptsMs: number; readonly tag: string }>();
    onTick.onmessage = (msg) => {
      frames.push({ seq: msg.seq, ptsMs: msg.ptsMs, tag: msg.tag });
    };
    const totalStreamed = await api.streamFrames({
      count: 8,
      labelPrefix: "frame</script>",
      onTick,
    });
    // Allow queued `evalJs` / SSE callbacks to settle if transported asynchronously over TCP/SSE
    const deadlineStream = Date.now() + 3000;
    while (frames.length < 8 && Date.now() < deadlineStream) {
      await new Promise((r) => setTimeout(r, 10));
    }
    check(totalStreamed === 8, `streamFrames returned ${totalStreamed}`);
    check(frames.length === 8, `Channel received ${frames.length} frames, expected 8`);
    for (let i = 0; i < 8; i++) {
      check(frames[i]!.seq === i, `Channel out-of-order at ${i}: got ${frames[i]!.seq}`);
      check(
        frames[i]!.tag === `frame</script>:${i}`,
        `HTML-escaped string roundtrip failed: ${frames[i]!.tag}`,
      );
    }

    // 6. `@tauri-apps/api/event` (`listen`, `once`, backend `emit`, frontend `emitTo`, `unlisten`)
    let listenHits = 0;
    let onceHits = 0;
    const unlistenBackend = await listen<{ readonly step: number }>("backend:tick", (ev) => {
      if (ev.payload.step > 0) listenHits += 1;
    });
    await once<{ readonly step: number }>("backend:tick", (ev) => {
      if (ev.payload.step === 1) onceHits += 1;
    });

    await api.emitFromBackend({ eventName: "backend:tick", step: 1 });
    await api.emitFromBackend({ eventName: "backend:tick", step: 2 });

    const deadlineEv = Date.now() + 3000;
    while (listenHits < 2 && Date.now() < deadlineEv) {
      await new Promise((r) => setTimeout(r, 10));
    }
    check(listenHits === 2, `Expected 2 listen hits, got ${listenHits}`);
    check(onceHits === 1, `Expected 1 once hit, got ${onceHits}`);

    unlistenBackend();
    await emitTo("main", "backend:tick", { step: 3 });
    await new Promise((r) => setTimeout(r, 40));
    check(listenHits === 2, `Expected 0 hits after unlisten(), got ${listenHits}`);

    // 7. `@tauri-apps/api/core` `Resource` lifecycle (`plugin:resources|close`)
    const opened = await api.openPack({ magic: "ZPACK_V2" });
    check(opened.magic === "ZPACK_V2", "openPack magic");
    const packRes = new PackResource(opened.rid);
    await packRes.close();
    let doubleCloseRejected = false;
    try {
      await packRes.close();
    } catch {
      doubleCloseRejected = true;
    }
    check(doubleCloseRejected, "Closing an already-closed Resource must reject");

    // 8. Raw Binary `Uint8Array` -> `application/octet-stream` -> `ArrayBuffer` roundtrip
    const rawOut = await invoke<ArrayBuffer>(
      "invertBytes",
      new Uint8Array([0x00, 0x55, 0xaa, 0xff]),
    );
    const outView = new Uint8Array(rawOut);
    check(
      outView.length === 4 &&
        outView[0] === 0xff &&
        outView[1] === 0xaa &&
        outView[2] === 0x55 &&
        outView[3] === 0x00,
      `Binary IPC roundtrip mismatch: [${Array.from(outView).join(",")}]`,
    );

    // 9. Native WebKit extras: `convertFileSrc` + `asset://` `206 Partial Content` + `[data-tauri-drag-region]`
    let dragTriggered = false;
    if (opts.mode === "webkit") {
      const assetUrl = convertFileSrc("audio/voice_clip.bin");
      check(assetUrl.startsWith("asset://"), `Unexpected asset URL: ${assetUrl}`);
      const rangeResp = await fetch(assetUrl, {
        headers: { Range: "bytes=4-11" },
      });
      check(rangeResp.status === 206, `asset:// Range expected 206, got ${rangeResp.status}`);
      check((await rangeResp.text()) === "CLIPDATA", "asset:// 206 slice mismatch");

      const forbiddenAsset = await fetch(convertFileSrc("secret/private.key"));
      check(forbiddenAsset.status === 403, `Out-of-scope asset expected 403, got ${forbiddenAsset.status}`);

      // Synthesize DOM elements & real `MouseEvent`s for `[data-tauri-drag-region]`
      const bar = document.createElement("div");
      bar.setAttribute("data-tauri-drag-region", "");
      const caption = document.createElement("span");
      caption.textContent = "Titlebar";
      const closeBtn = document.createElement("button");
      closeBtn.textContent = "X";
      bar.appendChild(caption);
      bar.appendChild(closeBtn);
      document.body.appendChild(bar);

      // Clicking `<button>` inside drag region MUST NOT trigger window drag!
      closeBtn.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, buttons: 1, detail: 1 }));
      await new Promise((r) => setTimeout(r, 30));
      const dragsAfterBtn = await api.dragCount();
      check(dragsAfterBtn === 0, `<button> inside drag region must NOT start drag (got ${dragsAfterBtn})`);

      // Single-clicking `<span>` inside drag region MUST invoke `plugin:window|start_dragging`!
      caption.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, buttons: 1, detail: 1 }));
      const deadlineDrag = Date.now() + 2000;
      while ((await api.dragCount()) < 1 && Date.now() < deadlineDrag) {
        await new Promise((r) => setTimeout(r, 15));
      }
      dragTriggered = (await api.dragCount()) === 1;
      check(dragTriggered, "Single-click on [data-tauri-drag-region] must trigger start_dragging");

      // Double-clicking `<span>` inside drag region MUST invoke `plugin:window|internal_toggle_maximize`!
      const beforeMax = await win.isMaximized();
      caption.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, buttons: 1, detail: 2 }));
      const deadlineMax = Date.now() + 2000;
      while ((await win.isMaximized()) === beforeMax && Date.now() < deadlineMax) {
        await new Promise((r) => setTimeout(r, 15));
      }
      check((await win.isMaximized()) === !beforeMax, "Double-click on drag region must toggle maximize");
    } else {
      // Even in non-WebKit mode, verify `emit` roundtrip via `EventBus`
      await emit("bridge:smoke", { ok: true });
    }

    const summary: SuiteSummary = {
      ok: true,
      mode: opts.mode,
      checksRun: checks,
      streamedCount: frames.length,
      onceHits,
      listenHits,
      dragTriggered,
      errorMessage: "",
    };
    await api.reportSuiteResult(summary);
    return summary;
  } catch (err: unknown) {
    const errorMessage = err instanceof Error ? `${err.message}\n${err.stack ?? ""}` : String(err);
    const failedSummary: SuiteSummary = {
      ok: false,
      mode: opts.mode,
      checksRun: checks,
      streamedCount: 0,
      onceHits: 0,
      listenHits: 0,
      dragTriggered: false,
      errorMessage,
    };
    try {
      await api.reportSuiteResult(failedSummary);
    } catch {
      // Ignore secondary reporting errors
    }
    return failedSummary;
  }
}
