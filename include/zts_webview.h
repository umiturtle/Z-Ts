/*
 * include/zts_webview.h — Minimal Standalone C ABI for `zts_webview` (C99 / C++17)
 *
 * Pure OS Window + WebView embedding engine with zero JSON / RPC / Tauri coupling.
 * Can be linked directly into C, C++, Rust, Zig, SDL3/GLFW engines, or plugin hosts.
 *
 * Threading Contract:
 * - Window & DOM creation/mutation functions run on the main UI thread (or enqueue automatically).
 * - `zts_webview_wakeup`, `zts_webview_request_quit`, and `zts_webview_complete_request` are
 *   100% thread-safe and lock-free/wait-free from ANY worker thread.
 *
 * Embedding (Overlay) Contract (`M3-03`):
 * - Pass an existing container as `zts_window_desc_t.parent_native_handle` and the WebView becomes
 *   a child of it: `GtkContainer*` (GTK3), `NSView*` (AppKit), `HWND` (Win32).
 * - The child fills the host's client area; call `zts_webview_window_fit_parent()` after a host
 *   resize, or let the native layout do it (expanding GtkBox / autoresizing NSView / WS_CHILD).
 * - Drive everything from *your* loop with `zts_webview_poll()`; closing the embedded window never
 *   destroys the host container.
 */

#ifndef ZTS_WEBVIEW_H
#define ZTS_WEBVIEW_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zts_webview_engine zts_webview_engine_t;

/* 53-bit IEEE-754-safe generational handles (`0` == invalid handle). */
typedef uint64_t zts_window_id_t;
typedef uint64_t zts_request_id_t;

typedef enum zts_webview_status {
    ZTS_WEBVIEW_OK = 0,
    ZTS_WEBVIEW_ERR_INVALID_ARG = -1,
    ZTS_WEBVIEW_ERR_OUT_OF_MEMORY = -2,
    ZTS_WEBVIEW_ERR_UNSUPPORTED = -3,
    ZTS_WEBVIEW_ERR_WINDOW_NOT_FOUND = -4,
    ZTS_WEBVIEW_ERR_REQUEST_CANCELED = -5,
    ZTS_WEBVIEW_ERR_DISPLAY_UNAVAILABLE = -6,
    ZTS_WEBVIEW_ERR_PLATFORM_FAILURE = -7,
} zts_webview_status_t;

typedef enum zts_webview_backend {
    ZTS_WEBVIEW_BACKEND_AUTO = 0,
    ZTS_WEBVIEW_BACKEND_HEADLESS_MOCK = 1,
    ZTS_WEBVIEW_BACKEND_NATIVE = 2,
} zts_webview_backend_t;

typedef enum zts_step_mode {
    ZTS_STEP_BLOCKING = 0,
    ZTS_STEP_POLL = 1,
} zts_step_mode_t;

typedef struct zts_webview_header {
    const char *name;
    size_t name_len;
    const char *value;
    size_t value_len;
} zts_webview_header_t;

typedef struct zts_scheme_request_view {
    zts_request_id_t request_id;
    zts_window_id_t window_id;
    const char *scheme;
    size_t scheme_len;
    const char *method;
    size_t method_len;
    const char *uri;
    size_t uri_len;
    const uint8_t *body;
    size_t body_len;
    const zts_webview_header_t *headers;
    size_t headers_len;
} zts_scheme_request_view_t;

typedef void (*zts_scheme_handler_fn)(
    void *userdata,
    const zts_scheme_request_view_t *request
);

typedef void (*zts_message_handler_fn)(
    void *userdata,
    zts_window_id_t window_id,
    const uint8_t *message,
    size_t message_len
);

typedef void (*zts_window_close_fn)(
    void *userdata,
    zts_window_id_t window_id
);

typedef void (*zts_bytes_release_fn)(
    void *release_ctx,
    const uint8_t *ptr,
    size_t len
);

typedef struct zts_window_desc {
    const char *title;
    double width;
    double height;
    bool resizable;
    bool decorations;
    bool transparent;
    bool always_on_top;
    bool visible;
    bool fullscreen;
    bool devtools;
    bool has_background_color;
    uint8_t bg_r;
    uint8_t bg_g;
    uint8_t bg_b;
    uint8_t bg_a;
    /* Optional native parent container (`GtkContainer*` / `NSView*` / `HWND`) for child embedding. */
    void *parent_native_handle;
    const char *initial_url;
    const char *initial_html;
} zts_window_desc_t;

/* --- 1. Engine Lifecycle & Event Loop Control --- */
int32_t zts_webview_engine_create(uint32_t backend, zts_webview_engine_t **out_engine);
void zts_webview_engine_destroy(zts_webview_engine_t *engine);
bool zts_webview_step(zts_webview_engine_t *engine, uint32_t mode);
/* Non-blocking single iteration for hosts that own the loop (`== zts_webview_step(engine, ZTS_STEP_POLL)`). */
bool zts_webview_poll(zts_webview_engine_t *engine);
void zts_webview_wakeup(zts_webview_engine_t *engine);
void zts_webview_request_quit(zts_webview_engine_t *engine);

/* --- 2. Custom URI Scheme & IPC Message Hooks --- */
int32_t zts_webview_register_scheme(
    zts_webview_engine_t *engine,
    const char *scheme,
    zts_scheme_handler_fn handler,
    void *userdata
);

void zts_webview_set_message_handler(
    zts_webview_engine_t *engine,
    zts_message_handler_fn handler,
    void *userdata
);

void zts_webview_set_close_handler(
    zts_webview_engine_t *engine,
    zts_window_close_fn handler,
    void *userdata
);

int32_t zts_webview_complete_request(
    zts_webview_engine_t *engine,
    zts_request_id_t request_id,
    uint16_t status_code,
    const char *content_type,
    const zts_webview_header_t *extra_headers,
    size_t extra_headers_len,
    const uint8_t *body,
    size_t body_len,
    zts_bytes_release_fn release_fn,
    void *release_ctx
);

/* --- 3. Window & WebView Operations --- */
int32_t zts_webview_window_create(
    zts_webview_engine_t *engine,
    const zts_window_desc_t *desc,
    zts_window_id_t *out_window_id
);

int32_t zts_webview_window_close(zts_webview_engine_t *engine, zts_window_id_t win);
/* Resizes an embedded window to fill its host container. Toplevel windows: ZTS_WEBVIEW_ERR_UNSUPPORTED. */
int32_t zts_webview_window_fit_parent(zts_webview_engine_t *engine, zts_window_id_t win);
void *zts_webview_window_native_handle(zts_webview_engine_t *engine, zts_window_id_t win);
int32_t zts_webview_window_set_title(zts_webview_engine_t *engine, zts_window_id_t win, const char *title);
int32_t zts_webview_window_set_size(zts_webview_engine_t *engine, zts_window_id_t win, double width, double height);
int32_t zts_webview_window_set_min_size(zts_webview_engine_t *engine, zts_window_id_t win, bool enabled, double width, double height);
int32_t zts_webview_window_set_max_size(zts_webview_engine_t *engine, zts_window_id_t win, bool enabled, double width, double height);
int32_t zts_webview_window_set_position(zts_webview_engine_t *engine, zts_window_id_t win, double x, double y);
int32_t zts_webview_window_set_resizable(zts_webview_engine_t *engine, zts_window_id_t win, bool resizable);
int32_t zts_webview_window_set_minimized(zts_webview_engine_t *engine, zts_window_id_t win, bool minimized);
int32_t zts_webview_window_set_maximized(zts_webview_engine_t *engine, zts_window_id_t win, bool maximized);
int32_t zts_webview_window_set_fullscreen(zts_webview_engine_t *engine, zts_window_id_t win, bool fullscreen);
int32_t zts_webview_window_set_visible(zts_webview_engine_t *engine, zts_window_id_t win, bool visible);
int32_t zts_webview_window_set_decorations(zts_webview_engine_t *engine, zts_window_id_t win, bool decorations);
int32_t zts_webview_window_set_always_on_top(zts_webview_engine_t *engine, zts_window_id_t win, bool on_top);
int32_t zts_webview_window_set_focus(zts_webview_engine_t *engine, zts_window_id_t win);
int32_t zts_webview_window_start_drag(zts_webview_engine_t *engine, zts_window_id_t win);

/* --- 4. Screenshot Capture (PNG) --- */
/*
 * Capture is asynchronous on every backend (WebKit snapshot / WKWebView snapshot / WebView2
 * CapturePreview), so it integrates with the same host loop as everything else:
 *
 *     zts_webview_window_capture(engine, win);
 *     for (;;) {
 *         zts_webview_poll(engine);
 *         zts_capture_t shot = {0};
 *         if (zts_webview_capture_take(engine, win, &shot) != ZTS_WEBVIEW_OK) break;  // failed
 *         if (shot.len > 0) { write(shot.data, shot.len); zts_webview_capture_free(engine, &shot); break; }
 *         host_sleep_ms(1);                       // still rendering
 *     }
 */
typedef struct zts_capture {
    uint8_t *data;   /* PNG bytes, owned by the caller after `capture_take` returns 0/len>0 */
    size_t len;      /* 0 == not ready yet */
    uint32_t width;  /* pixels, parsed from the PNG IHDR (may be 2x on hi-DPI displays) */
    uint32_t height;
} zts_capture_t;

int32_t zts_webview_window_capture(zts_webview_engine_t *engine, zts_window_id_t win);
/* ZTS_WEBVIEW_OK + len == 0 => still rendering; ZTS_WEBVIEW_OK + len > 0 => caller owns `data`. */
int32_t zts_webview_capture_take(zts_webview_engine_t *engine, zts_window_id_t win, zts_capture_t *out);
void zts_webview_capture_free(zts_webview_engine_t *engine, zts_capture_t *capture);

/* --- 5. Script Injection, Evaluation, Navigation & DevTools --- */
int32_t zts_webview_add_init_script(zts_webview_engine_t *engine, zts_window_id_t win, const char *js_source);
int32_t zts_webview_eval_js(zts_webview_engine_t *engine, zts_window_id_t win, const char *js_source);
int32_t zts_webview_navigate(zts_webview_engine_t *engine, zts_window_id_t win, const char *url);
int32_t zts_webview_load_html(zts_webview_engine_t *engine, zts_window_id_t win, const char *html, const char *base_uri);
int32_t zts_webview_open_devtools(zts_webview_engine_t *engine, zts_window_id_t win);

#ifdef __cplusplus
}
#endif

#endif /* ZTS_WEBVIEW_H */
