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
import {
  CheckMenuItem,
  Menu,
  Submenu,
  type MenuItem as MenuItemType,
} from "@tauri-apps/api/menu";
import { LogicalPosition as MenuLogicalPosition } from "@tauri-apps/api/dpi";
import { TrayIcon } from "@tauri-apps/api/tray";
import { createIpcTransport, createRpcClient } from "./generated_api";

export interface SuiteOptions {
  readonly mode: "webkit" | "bridge" | "wasm";
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

      // 9a. Clicking `<button>` inside drag region MUST NOT trigger window drag!
      closeBtn.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, button: 0, buttons: 1, detail: 1 }));
      await new Promise((r) => setTimeout(r, 30));
      check((await api.dragCount()) === 0, "<button> inside drag region must NOT start drag");

      // 9b. Per upstream Tauri v2 `drag.js`, `data-tauri-drag-region=""` only drags direct target (`el === path[0]`), NOT child `<span>`!
      caption.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, button: 0, buttons: 1, detail: 1 }));
      await new Promise((r) => setTimeout(r, 30));
      check((await api.dragCount()) === 0, 'Child <span> under data-tauri-drag-region="" must NOT start drag');

      // 9c. Direct click on `bar` (`el === path[0]`) MUST invoke `plugin:window|start_dragging`!
      bar.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, button: 0, buttons: 1, detail: 1 }));
      const deadlineDirect = Date.now() + 2000;
      while ((await api.dragCount()) < 1 && Date.now() < deadlineDirect) {
        await new Promise((r) => setTimeout(r, 15));
      }
      check((await api.dragCount()) === 1, 'Direct click on [data-tauri-drag-region=""] must trigger start_dragging');

      // 9d. Switching to `data-tauri-drag-region="deep"` MUST also drag non-clickable child `<span>`!
      bar.setAttribute("data-tauri-drag-region", "deep");
      caption.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, button: 0, buttons: 1, detail: 1 }));
      const deadlineDeep = Date.now() + 2000;
      while ((await api.dragCount()) < 2 && Date.now() < deadlineDeep) {
        await new Promise((r) => setTimeout(r, 15));
      }
      dragTriggered = (await api.dragCount()) === 2;
      check(dragTriggered, "Single-click on [data-tauri-drag-region] must trigger start_dragging");

      // Double-clicking `<span>` inside drag region MUST invoke `plugin:window|internal_toggle_maximize`!
      const beforeMax = await win.isMaximized();
      caption.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, buttons: 1, detail: 2 }));
      const deadlineMax = Date.now() + 2000;
      while ((await win.isMaximized()) === beforeMax && Date.now() < deadlineMax) {
        await new Promise((r) => setTimeout(r, 15));
      }
      check((await win.isMaximized()) === !beforeMax, "Double-click on drag region must toggle maximize");
    } else if (opts.mode === "wasm") {
      // 9'. Serverless WebAssembly: `convertFileSrc` resolves to a relative static asset path so the
      // same `dist/` works at domain root or any GitHub Pages subpath, served with native CDN `206`.
      const assetUrl = convertFileSrc("audio/voice_clip.bin");
      check(assetUrl === "./_zts/assets/audio/voice_clip.bin", `Unexpected Wasm asset URL: ${assetUrl}`);
      const rangeResp = await fetch(assetUrl, { headers: { Range: "bytes=4-11" } });
      check(rangeResp.status === 206, `static asset Range expected 206, got ${rangeResp.status}`);
      check((await rangeResp.text()) === "CLIPDATA", "static asset 206 slice mismatch");
      await emit("wasm:smoke", { ok: true });
    } else {
      // Even in non-WebKit mode, verify `emit` roundtrip via `EventBus`
      await emit("bridge:smoke", { ok: true });
    }

    // 10. `@tauri-apps/api/menu` (`M4-03`) — unmodified upstream `plugin:menu|*` wire.
    //     Covering the whole resource graph: nested submenus, predefined items, check state,
    //     text/enabled setters, `items()` readback and `close()`.
    const activations: string[] = [];
    const fileMenu = await Submenu.new({
      id: "zts-file",
      text: "File",
      items: [
        {
          id: "zts-open",
          text: "Open",
          accelerator: "CmdOrCtrl+O",
          action: (id: string) => {
            activations.push(id);
          },
        },
        { item: "Separator" },
        { item: "Quit" },
      ],
    });
    const gridItem = await CheckMenuItem.new({ id: "zts-grid", text: "Grid", checked: true });
    const menu = await Menu.new({ id: "zts-menu", items: [fileMenu, gridItem] });

    check(menu.id === "zts-menu", `Menu.id expected zts-menu, got ${menu.id}`);
    const listed = await menu.items();
    check(listed.length === 2, `menu.items() returned ${listed.length}, expected 2`);
    check(listed[0]?.kind === "Submenu", `items()[0].kind got ${listed[0]?.kind}`);
    check(listed[1]?.kind === "Check", `items()[1].kind got ${listed[1]?.kind}`);

    const nested = await fileMenu.items();
    check(nested.length === 3, `submenu.items() returned ${nested.length}, expected 3`);
    check(nested[1]?.kind === "Predefined", `items()[1].kind got ${nested[1]?.kind}`);

    check((await gridItem.isChecked()) === true, "CheckMenuItem.isChecked() must be true");
    await gridItem.setChecked(false);
    check((await gridItem.isChecked()) === false, "CheckMenuItem.setChecked(false)");
    await gridItem.setText("Grid + rulers");
    check((await gridItem.text()) === "Grid + rulers", "MenuItem.text()/setText()");
    await gridItem.setEnabled(false);
    check((await gridItem.isEnabled()) === false, "MenuItem.setEnabled(false)");
    await gridItem.setEnabled(true);
    const openItem = nested[0] as MenuItemType;
    check((await openItem.text()) === "Open", "MenuItem.text() for a nested item");
    await openItem.setAccelerator("CmdOrCtrl+Shift+O");
    await openItem.setAccelerator(null);

    // Setting the app / window menu and popping a context menu need a native backend: the desktop
    // gates run a `Mock` that records what the JS asked for, while the serverless `wasm` build has
    // no toolkit and must **fail closed** instead of pretending the menu is on screen.
    const contextMenu = await Menu.new({ items: [{ id: "zts-copy", text: "Copy" }] });
    if (opts.mode === "wasm") {
      let rejected = false;
      try {
        await menu.setAsAppMenu();
      } catch {
        rejected = true;
      }
      check(rejected, "setAsAppMenu() must fail closed without a native backend");
      let trayRejected = false;
      try {
        await TrayIcon.new({ id: "zts-tray", tooltip: "Z-Ts Studio" });
      } catch {
        trayRejected = true;
      }
      check(trayRejected, "TrayIcon.new() must fail closed without a native backend");
    } else {
      const previousAppMenu = await menu.setAsAppMenu();
      check(previousAppMenu === null, "setAsAppMenu() must report no previous menu");
      await menu.setAsWindowMenu(win);
      await contextMenu.popup(new MenuLogicalPosition(12, 24));
      await menu.setAsAppMenu();

      // 11. `@tauri-apps/api/tray` (`M4-03`)
      const tray = await TrayIcon.new({
        id: "zts-tray",
        menu,
        tooltip: "Z-Ts Studio",
        title: "ZTS",
      });
      await tray.setTooltip("2 unread messages");
      await tray.setTitle("42");
      await tray.setVisible(false);
      await tray.setVisible(true);
      const foundTray = await TrayIcon.getById("zts-tray");
      check(foundTray !== null, "TrayIcon.getById() must find the tray created above");
      await TrayIcon.removeById("zts-tray");
      check((await TrayIcon.getById("zts-tray")) === null, "TrayIcon.removeById()");
    }
    await contextMenu.close();

    // Resources are released through the shared `plugin:resources` table.
    await menu.close();
    check(activations.length === 0, "no menu action may fire without a real activation");

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
