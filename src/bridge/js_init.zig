//! HTML `<head>` Bootstrap Script Generator (`src/bridge/js_init.zig`).
//!
//! Injects a self-contained runtime bridge into served HTML pages so browser tabs,
//! Arena Live Preview iframes, Playwright E2E tests, and remote control overlays
//! work identically to native WebViews without touching application frontend code:
//! - Installs both `globalThis.__ZTS_IPC__` AND `window.__TAURI_INTERNALS__`.
//! - Attaches `Tauri-Invoke-Key` + `credentials: "same-origin"` on `POST /__zts_ipc__/<cmd>`.
//! - Automatically handles both JSON responses and raw `application/octet-stream` -> `Uint8Array`.
//! - Opens `EventSource("/__zts_events__?key=...")` to apply live `emit`, `eval`, and `document.title` updates.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn allocBootstrapScript(allocator: Allocator, invoke_key_hex: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, template_fmt, .{invoke_key_hex});
}

const template_fmt =
    \\<script>
    \\(() => {{
    \\  const KEY = "{s}";
    \\  const cbs = new Map();
    \\  let nextId = 1;
    \\  const listeners = new Map();
    \\
    \\  async function invoke(cmd, args, options) {{
    \\    const isBin = args instanceof Uint8Array || args instanceof ArrayBuffer;
    \\    const headers = Object.assign({{
    \\      "Tauri-Invoke-Key": KEY,
    \\      "Content-Type": isBin ? "application/octet-stream" : "application/json",
    \\    }}, (options && options.headers) || {{}});
    \\    const body = isBin
    \\      ? (args instanceof Uint8Array ? args : new Uint8Array(args))
    \\      : JSON.stringify(args === undefined ? {{}} : args);
    \\    const res = await fetch("/__zts_ipc__/" + encodeURIComponent(cmd), {{
    \\      method: "POST",
    \\      credentials: "same-origin",
    \\      headers,
    \\      body,
    \\    }});
    \\    const ct = res.headers.get("content-type") || "";
    \\    const isOk = (res.headers.get("tauri-response") || (res.ok ? "ok" : "error")) === "ok";
    \\    if (ct.includes("application/octet-stream")) {{
    \\      const buf = new Uint8Array(await res.arrayBuffer());
    \\      if (!isOk) throw buf;
    \\      return buf;
    \\    }}
    \\    const data = await res.json();
    \\    if (!isOk) throw data;
    \\    return data;
    \\  }}
    \\
    \\  const bridge = {{
    \\    invoke,
    \\    transformCallback(fn, once) {{
    \\      const id = nextId++;
    \\      cbs.set(id, (payload) => {{
    \\        if (once) cbs.delete(id);
    \\        return fn(payload);
    \\      }});
    \\      return id;
    \\    }},
    \\    unregisterCallback(id) {{ cbs.delete(id); }},
    \\    runCallback(id, payload) {{
    \\      const fn = cbs.get(id);
    \\      if (fn) fn(payload);
    \\    }},
    \\    convertFileSrc(filePath) {{
    \\      return "/__zts_asset__/" + encodeURIComponent(filePath);
    \\    }},
    \\    onEvent(eventName, handler) {{
    \\      let set = listeners.get(eventName);
    \\      if (!set) {{ set = new Set(); listeners.set(eventName, set); }}
    \\      set.add(handler);
    \\      return () => set.delete(handler);
    \\    }},
    \\  }};
    \\
    \\  globalThis.__ZTS_IPC__ = bridge;
    \\  globalThis.__TAURI_INTERNALS__ = bridge;
    \\
    \\  if (typeof EventSource !== "undefined") {{
    \\    const es = new EventSource("/__zts_events__?key=" + KEY);
    \\    es.addEventListener("emit", (ev) => {{
    \\      const msg = JSON.parse(ev.data);
    \\      const set = listeners.get(msg.event);
    \\      if (set) for (const fn of set) fn(msg.payload);
    \\      if (typeof window !== "undefined") {{
    \\        window.dispatchEvent(new CustomEvent("zts:event", {{ detail: msg }}));
    \\      }}
    \\    }});
    \\    es.addEventListener("eval", (ev) => {{
    \\      const msg = JSON.parse(ev.data);
    \\      (0, eval)(msg.script);
    \\    }});
    \\    es.addEventListener("window", (ev) => {{
    \\      const msg = JSON.parse(ev.data);
    \\      if (typeof document !== "undefined" && typeof msg.title === "string") {{
    \\        document.title = msg.title;
    \\      }}
    \\    }});
    \\  }}
    \\}})();
    \\</script>
;
