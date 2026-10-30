//! HTML `<head>` Bootstrap Script Generator (`src/bridge/js_init.zig`).
//!
//! Injects a self-contained runtime bridge into served HTML pages so browser tabs,
//! Arena Live Preview iframes, Playwright E2E tests, and remote control overlays
//! run BOTH standalone `tsgen` clients (`globalThis.__ZTS_IPC__`) AND unmodified
//! official `@tauri-apps/api` v2 packages (`window.__TAURI_INTERNALS__`,
//! `window.__TAURI_EVENT_PLUGIN_INTERNALS__`, `Channel`, `Size`, `listen`, etc.).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Renders the `<script>` block that defines `window.__TAURI_INTERNALS__` (and the `tsgen` client) for
/// a served page. `invoke_key_hex` is embedded as the CSRF token the page must echo on every
/// `ipc://` call, so the script is per-server-instance, not a constant.
pub fn allocBootstrapScript(allocator: Allocator, invoke_key_hex: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, template_fmt, .{invoke_key_hex});
}

const template_fmt =
    \\<script>
    \\(() => {{
    \\  const KEY = "{s}";
    \\  const TO_IPC = "__TAURI_TO_IPC_KEY__";
    \\  const cbs = new Map();
    \\  let nextId = 1;
    \\  const listeners = new Map();
    \\  const eventRegistry = Object.create(null);
    \\
    \\  function replacer(_k, val) {{
    \\    if (val instanceof Map) return Object.fromEntries(val.entries());
    \\    if (val instanceof Uint8Array) return Array.from(val);
    \\    if (val instanceof ArrayBuffer) return Array.from(new Uint8Array(val));
    \\    if (typeof val === "object" && val !== null && TO_IPC in val) {{
    \\      return val[TO_IPC]();
    \\    }}
    \\    return val;
    \\  }}
    \\
    \\  async function invoke(cmd, args, options) {{
    \\    const isBin = args instanceof Uint8Array || args instanceof ArrayBuffer;
    \\    const headers = Object.assign({{
    \\      "Tauri-Invoke-Key": KEY,
    \\      "Content-Type": isBin ? "application/octet-stream" : "application/json",
    \\    }}, (options && options.headers) || {{}});
    \\    const body = isBin
    \\      ? (args instanceof Uint8Array ? args : new Uint8Array(args))
    \\      : JSON.stringify(args === undefined ? {{}} : args, replacer);
    \\    const res = await fetch("/__zts_ipc__/" + encodeURIComponent(cmd), {{
    \\      method: "POST",
    \\      credentials: "same-origin",
    \\      headers,
    \\      body,
    \\    }});
    \\    const ct = res.headers.get("content-type") || "";
    \\    const isOk = (res.headers.get("tauri-response") || (res.ok ? "ok" : "error")) === "ok";
    \\    if (ct.includes("application/octet-stream")) {{
    \\      const out = new Uint8Array(await res.arrayBuffer());
    \\      if (!isOk) throw out;
    \\      return out;
    \\    }}
    \\    const data = await res.json();
    \\    if (!isOk) throw data;
    \\    if (cmd === "plugin:event|listen" && args && typeof args.event === "string") {{
    \\      registerEventListener(args.event, data, args.handler, args.target);
    \\    }}
    \\    return data;
    \\  }}
    \\
    \\  const bridge = {{
    \\    invoke,
    \\    callbacks: cbs,
    \\    metadata: {{
    \\      currentWindow: {{ label: "main" }},
    \\      currentWebview: {{ label: "main", windowLabel: "main" }},
    \\    }},
    \\    plugins: {{
    \\      path: {{ sep: "/", delimiter: ":" }},
    \\    }},
    \\    transformCallback(fn, once) {{
    \\      const id = nextId++;
    \\      cbs.set(id, (payload) => {{
    \\        if (once) cbs.delete(id);
    \\        return fn && fn(payload);
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
    \\  function registerEventListener(eventName, eventId, handlerId, target) {{
    \\    if (!eventRegistry[eventName]) eventRegistry[eventName] = Object.create(null);
    \\    eventRegistry[eventName][eventId] = {{ handlerId, target }};
    \\  }}
    \\
    \\  function deliverEvent(eventName, payload, eventIds) {{
    \\    const table = eventRegistry[eventName];
    \\    if (!table) return;
    \\    const ids = Array.isArray(eventIds) ? eventIds : Object.keys(table).map(Number);
    \\    for (const id of ids) {{
    \\      const entry = table[id];
    \\      if (entry) bridge.runCallback(entry.handlerId, {{ event: eventName, id, payload }});
    \\    }}
    \\  }}
    \\
    \\  globalThis.isTauri = true;
    \\  globalThis.__ztsRegisterEvent = registerEventListener;
    \\  globalThis.__ztsDeliverEvent = deliverEvent;
    \\  globalThis.__ZTS_IPC__ = bridge;
    \\  globalThis.__TAURI_INTERNALS__ = bridge;
    \\  globalThis.__TAURI_EVENT_PLUGIN_INTERNALS__ = {{
    \\    unregisterListener(eventName, eventId) {{
    \\      const table = eventRegistry[eventName];
    \\      if (table && table[eventId]) {{
    \\        bridge.unregisterCallback(table[eventId].handlerId);
    \\        delete table[eventId];
    \\      }}
    \\    }},
    \\  }};
    \\
    \\  if (typeof EventSource !== "undefined") {{
    \\    const es = new EventSource("/__zts_events__?key=" + KEY);
    \\    es.addEventListener("emit", (ev) => {{
    \\      const msg = JSON.parse(ev.data);
    \\      const set = listeners.get(msg.event);
    \\      if (set) for (const fn of set) fn(msg.payload);
    \\      deliverEvent(msg.event, msg.payload, null);
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
