# `examples/c_embed` — overlay embedding in an existing app (pure C99)

A host written in **pure C99** calls the Z-Ts C ABI and gets a WebView overlay. There are zero lines
of Zig in the host: this example proves the library can be consumed by an existing C/C++ application
rather than requiring a Zig build.

## What it proves

| Property | How |
|---|---|
| Standalone library | `zts_webview` depends only on `zts_foundation` |
| Stable C ABI | `include/zts_webview.h` declares the whole surface |
| No C compiler in the host build | the host links a prebuilt static/shared library |
| Same behaviour on three OSes | GTK3+WebKit2GTK / Cocoa+WKWebView / Win32+WebView2 |
| Deterministic headless tests | `HeadlessMock` runs the same calls in CI without a display |

The header exposes create/step/destroy, window sizing, script evaluation and the invoke callback.
Handles are integer ids, never raw pointers, so lifetime and type survive the FFI boundary.

## Run it

```bash
# Linux (GTK3 + WebKit2GTK; a virtual display is fine)
cc -Iinclude examples/c_embed/main.c -Lzig-out/lib -lzts_webview -o /tmp/c_embed
Xvfb :99 & DISPLAY=:99 /tmp/c_embed

# macOS (Cocoa / WKWebView)
cc -Iinclude examples/c_embed/main.c -Lzig-out/lib -lzts_webview -framework Cocoa -framework WebKit -o /tmp/c_embed

# Windows (Win32 + WebView2; the Evergreen runtime is required)
cl /Iinclude examples/c_embed/main.c zig-out/lib/zts_webview.lib
```

CI builds and runs the host on all three OSes.

## Reading `main.c`

1. `zts_engine_create` returns a handle.
2. The caller registers an invoke callback and sets an initial window config.
3. `zts_engine_step` drives one turn of the event loop; the host owns the loop, not the library.
4. `zts_engine_destroy` releases everything; every allocation is accounted for.

There are no target-specific branches in the host either — the library chooses the backend at run
time.

## Where to go next

- [Concepts: package layout](../../docs/learn/en/concepts/architecture.md)
- [C API reference](../../docs/api/zts_webview/index.html) (generated from `///`)
- [The overlay embedding ADR](../../docs/decisions/0008-overlay-embedding-and-c-abi.md) (Japanese, internal)
