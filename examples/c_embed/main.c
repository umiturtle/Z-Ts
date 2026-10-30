/*
 * examples/c_embed/main.c — Z-Ts Overlay embedding from **pure C99** (`M3-03`).
 *
 * Proves three things that a Zig-only test cannot:
 *
 * 1. `zts_webview` is consumable from a plain C program: `#include "zts_webview.h"`, link
 *    `libzts_webview`, no Zig in the caller, no C++/ObjC compiler for *this* file.
 * 2. **Overlay mode** works: the host application creates and owns its own window + container
 *    (GTK3 `GtkBox` / Win32 child `HWND` / Cocoa `NSView`) and Z-Ts mounts its WebView **inside**
 *    it — the tiny `width`/`height` in `zts_window_desc_t` is deliberately ignored.
 * 3. The host owns the event loop: every frame it calls `zts_webview_poll()` (a non-blocking
 *    `zts_webview_step(..., ZTS_STEP_POLL)`) plus its own toolkit pump. Ctrl/Cmd-C style loops in
 *    SDL3 / GLFW / a game engine map 1:1 onto this shape.
 *
 * Exit codes: 0 = every check passed (the `OK c-embed …` marker is printed), 1 = a check failed.
 * An environment without a display / WebView2 runtime prints `SKIP c-embed …` and still exits 0 so
 * that `zig build test` stays green on a headless dev box — CI therefore gates on the **marker**,
 * never on the exit code, and a silent skip can never be mistaken for a pass.
 */

#include "zts_webview.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__)
#define ZTS_HOST_GTK 1
#include <gtk/gtk.h>
#elif defined(_WIN32)
#define ZTS_HOST_WIN32 1
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#elif defined(__APPLE__)
#define ZTS_HOST_COCOA 1
#include <objc/message.h>
#include <objc/runtime.h>
#else
#error "examples/c_embed supports GTK3 (Linux), Win32 and Cocoa hosts"
#endif

#define EXIT_SKIP 0 /* see the header comment: the CI gate greps for `OK c-embed`, not for status 0 */
#define MAX_FRAMES 12000 /* x the 1 ms frame budget below = 12 s worst case */

/* ------------------------------------------------------------------------- */
/* Host window + container (the "existing application" we embed into)         */
/* ------------------------------------------------------------------------- */

typedef struct host {
#if defined(ZTS_HOST_GTK)
    GtkWidget *window;
    GtkWidget *container; /* GtkBox: what gets passed as parent_native_handle */
#elif defined(ZTS_HOST_WIN32)
    HWND window;
    HWND container; /* child HWND acting as a dock area */
#elif defined(ZTS_HOST_COCOA)
    id window;    /* NSWindow* */
    id container; /* NSView* (contentView) */
#endif
    const char *name;
} host_t;

static int failures = 0;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL c-embed %s\n", what);
        failures++;
    }
}

/* --- Cocoa helpers: `objc_msgSend` is the documented pure-C entry point. --- */

#if defined(ZTS_HOST_COCOA)
typedef struct {
    double x, y;
} zts_point;
typedef struct {
    double w, h;
} zts_size;
typedef struct {
    zts_point origin;
    zts_size size;
} zts_rect;

static id zts_msg(id obj, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}
static void zts_msg_void(id obj, const char *sel) {
    ((void (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}
static void zts_msg_long(id obj, const char *sel, long value) {
    ((void (*)(id, SEL, long))objc_msgSend)(obj, sel_registerName(sel), value);
}
static void zts_msg_bool(id obj, const char *sel, int value) {
    ((void (*)(id, SEL, signed char))objc_msgSend)(obj, sel_registerName(sel), (signed char)(value ? 1 : 0));
}
static id zts_msg_new_window(id cls, zts_rect rect, unsigned long style, unsigned long backing) {
    /* `-initWithContentRect:styleMask:backing:defer:` */
    typedef id (*zts_new_window_fn)(id, SEL, zts_rect, unsigned long, unsigned long, signed char);
    return ((zts_new_window_fn)objc_msgSend)(cls, sel_registerName("initWithContentRect:styleMask:backing:defer:"), rect, style, backing, 0);
}
static void zts_msg_set_size(id obj, const char *sel, zts_size size) {
    /* `-setContentSize:` takes a single NSSize (16 bytes). */
    ((void (*)(id, SEL, zts_size))objc_msgSend)(obj, sel_registerName(sel), size);
}
static zts_rect zts_msg_bounds(id obj, const char *sel) {
    return ((zts_rect(*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}
static int zts_msg_bool_get(id obj, const char *sel) {
    return ((signed char (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel)) != 0;
}
#endif

static int host_create(host_t *h, int width, int height) {
#if defined(ZTS_HOST_GTK)
    h->name = "gtk3";
    if (!gtk_init_check(NULL, NULL)) {
        printf("SKIP c-embed no GTK display ($DISPLAY unset)\n");
        return EXIT_SKIP;
    }
    h->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(h->window), "Z-Ts C host (GTK3)");
    gtk_window_set_default_size(GTK_WINDOW(h->window), width, height);
    h->container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(h->window), h->container);
    gtk_widget_show_all(h->window);
    for (int i = 0; i < 8; i++) {
        gtk_main_iteration_do(FALSE);
    }
    return 0;
#elif defined(ZTS_HOST_WIN32)
    h->name = "win32";
    h->window = CreateWindowExW(0, L"STATIC", L"Z-Ts C host (Win32)",
                                WS_OVERLAPPEDWINDOW | WS_VISIBLE, 80, 80, width + 16, height + 39,
                                NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (h->window == NULL) {
        printf("SKIP c-embed CreateWindowExW failed (%lu)\n", (unsigned long)GetLastError());
        return EXIT_SKIP;
    }
    /* The "dock area" the overlay lives in — a real child window, not the toplevel. */
    h->container = CreateWindowExW(0, L"STATIC", NULL, WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN,
                                   0, 0, width, height, h->window, NULL, GetModuleHandleW(NULL), NULL);
    if (h->container == NULL) {
        printf("FAIL c-embed host container creation\n");
        return 1;
    }
    UpdateWindow(h->window);
    return 0;
#elif defined(ZTS_HOST_COCOA)
    h->name = "cocoa";
    {
        id app = zts_msg((id)objc_getClass("NSApplication"), "sharedApplication");
        if (app == NULL) {
            printf("SKIP c-embed NSApplication unavailable\n");
            return EXIT_SKIP;
        }
        /* Accessory policy: a CI runner must not pop a Dock icon / steal focus. */
        zts_msg_long(app, "setActivationPolicy:", 1);
        zts_msg_void(app, "finishLaunching");

        id cls = (id)objc_getClass("NSWindow");
        zts_rect rect = {{80.0, 80.0}, {(double)width, (double)height}};
        /* NSWindowStyleMaskTitled = 1, NSBackingStoreBuffered = 2 */
        h->window = zts_msg_new_window(zts_msg(cls, "alloc"), rect, 1, 2);
        if (h->window == NULL) {
            printf("SKIP c-embed NSWindow creation failed\n");
            return EXIT_SKIP;
        }
        zts_msg_bool(h->window, "setReleasedWhenClosed:", 0);
        zts_msg_void(h->window, "orderFrontRegardless");
        h->container = zts_msg(h->window, "contentView");
        if (h->container == NULL) {
            printf("FAIL c-embed host contentView is nil\n");
            return 1;
        }
    }
    return 0;
#endif
}

/* Called once the Z-Ts engine exists: the macOS backend forces `NSApplicationActivationPolicyRegular`
 * (a Dock icon), which a CI runner must not show. No-op on the other hosts. */
static void host_post_engine(host_t *h) {
    (void)h;
#if defined(ZTS_HOST_COCOA)
    id app = zts_msg((id)objc_getClass("NSApplication"), "sharedApplication");
    if (app != NULL) zts_msg_long(app, "setActivationPolicy:", 1);
#endif
}

/* A real host runs at some frame rate; without a budget this loop spins through its whole frame
 * allowance in a few milliseconds and returns before WebKit/WebKit2 has even started its web
 * process (that is exactly how the first CI run of this example failed on GTK and Cocoa). */
static void host_frame_wait(void) {
#if defined(ZTS_HOST_GTK)
    g_usleep(1000); /* glib, always present next to GTK; no <unistd.h> in strict C99 */
#elif defined(ZTS_HOST_WIN32)
    Sleep(1);
#elif defined(ZTS_HOST_COCOA)
    /* `+[NSThread sleepForTimeInterval:]` keeps this file free of POSIX feature-test macros. */
    ((void (*)(id, SEL, double))objc_msgSend)((id)objc_getClass("NSThread"),
                                             sel_registerName("sleepForTimeInterval:"), 0.001);
#endif
}

static void host_pump(host_t *h) {
#if defined(ZTS_HOST_GTK)
    (void)h;
    /* One non-blocking iteration of *our* GTK loop; `zts_webview_poll` pumps the same context. */
    gtk_main_iteration_do(FALSE);
    host_frame_wait();
#elif defined(ZTS_HOST_WIN32)
    (void)h;
    {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        host_frame_wait();
    }
#elif defined(ZTS_HOST_COCOA)
    /* AppKit is pumped by `zts_webview_poll` itself (the same NSApp loop), so the host only has to
     * yield this frame. A game engine would swap this line for its own present call. */
    (void)h;
    host_frame_wait();
#endif
}

static void host_resize(host_t *h, int width, int height) {
#if defined(ZTS_HOST_GTK)
    gtk_window_resize(GTK_WINDOW(h->window), width, height);
#elif defined(ZTS_HOST_WIN32)
    MoveWindow(h->container, 0, 0, width, height, TRUE);
#elif defined(ZTS_HOST_COCOA)
    zts_size size = {(double)width, (double)height};
    zts_msg_set_size(h->window, "setContentSize:", size);
#endif
}

typedef struct {
    int w;
    int h;
} zts_extent;

static zts_extent host_container_size(host_t *h) {
    zts_extent e = {0, 0};
#if defined(ZTS_HOST_GTK)
    e.w = gtk_widget_get_allocated_width(h->container);
    e.h = gtk_widget_get_allocated_height(h->container);
#elif defined(ZTS_HOST_WIN32)
    {
        RECT rc;
        if (GetClientRect(h->container, &rc)) {
            e.w = (int)(rc.right - rc.left);
            e.h = (int)(rc.bottom - rc.top);
        }
    }
#elif defined(ZTS_HOST_COCOA)
    {
        zts_rect bounds = zts_msg_bounds(h->container, "bounds");
        e.w = (int)bounds.size.w;
        e.h = (int)bounds.size.h;
    }
#endif
    return e;
}

static zts_extent host_child_size(void *native) {
    zts_extent e = {0, 0};
#if defined(ZTS_HOST_GTK)
    if (native != NULL) {
        e.w = gtk_widget_get_allocated_width(GTK_WIDGET(native));
        e.h = gtk_widget_get_allocated_height(GTK_WIDGET(native));
    }
#elif defined(ZTS_HOST_WIN32)
    if (native != NULL) {
        RECT rc;
        if (GetClientRect((HWND)native, &rc)) {
            e.w = (int)(rc.right - rc.left);
            e.h = (int)(rc.bottom - rc.top);
        }
    }
#elif defined(ZTS_HOST_COCOA)
    if (native != NULL) {
        zts_rect bounds = zts_msg_bounds((id)native, "bounds");
        e.w = (int)bounds.size.w;
        e.h = (int)bounds.size.h;
    }
#endif
    return e;
}

/* Structural proof, evaluated entirely on the host side of the ABI. */
static int host_carries(host_t *h, void *native) {
    if (native == NULL) return 0;
#if defined(ZTS_HOST_GTK)
    return gtk_widget_get_parent(GTK_WIDGET(native)) == h->container;
#elif defined(ZTS_HOST_WIN32)
    return GetParent((HWND)native) == h->container;
#elif defined(ZTS_HOST_COCOA)
    return zts_msg((id)native, "superview") == h->container;
#endif
}

static int host_alive(host_t *h) {
#if defined(ZTS_HOST_GTK)
    return GTK_IS_WIDGET(h->window) && gtk_widget_get_realized(h->window);
#elif defined(ZTS_HOST_WIN32)
    return IsWindow(h->window) && IsWindow(h->container);
#elif defined(ZTS_HOST_COCOA)
    /* A closed `NSWindow` reports `isVisible == 0`; if the overlay teardown had destroyed the
     * host we would already have crashed on the very first message send. */
    return zts_msg_bool_get(h->window, "isVisible");
#endif
}

static void host_destroy(host_t *h) {
#if defined(ZTS_HOST_GTK)
    gtk_widget_destroy(h->window);
#elif defined(ZTS_HOST_WIN32)
    if (h->window != NULL) DestroyWindow(h->window);
#elif defined(ZTS_HOST_COCOA)
    zts_msg_void(h->window, "close");
#endif
}

/* ------------------------------------------------------------------------- */
/* Z-Ts scheme handler: one HTML page + `/ping`                              */
/* ------------------------------------------------------------------------- */

typedef struct app_state {
    zts_webview_engine_t *engine;
    int schemes;
    int messages;
    int pong_seen;
    int reported;
    int structural_ok;
    char report[512];
} app_state_t;

/* The page fetches `/ping` (same-origin on every backend: `tauri://localhost` on GTK/Cocoa,
 * `http://tauri.localhost` on WebView2) and posts the result back through the message bridge. */
static const char *page_html =
    "<!doctype html><meta charset=\"utf-8\"><title>Z-Ts C embed</title>"
    "<body style=\"margin:0;font:15px system-ui;background:#101014;color:#eee\">"
    "<p style=\"padding:12px\">Z-Ts WebView embedded in a C host</p>"
    "<script>\n"
    "(async () => {\n"
    "  const out = { tag: 'embed', injected: typeof window.__ztsPostMessage === 'function' };\n"
    "  try {\n"
    "    const r = await fetch('/ping');\n"
    "    out.pong = (await r.json()).pong;\n"
    "    out.w = window.innerWidth;\n"
    "    out.h = window.innerHeight;\n"
    "  } catch (e) { out.err = String(e); }\n"
    "  window.__ztsPostMessage(JSON.stringify(out));\n"
    "})();\n"
    "</script>";

static const char *ping_json = "{\"pong\":42}";

static void on_scheme(void *userdata, const zts_scheme_request_view_t *req) {
    app_state_t *st = (app_state_t *)userdata;
    static const char acao_name[] = "Access-Control-Allow-Origin";
    static const char acao_value[] = "*";
    const zts_webview_header_t cors = {acao_name, sizeof(acao_name) - 1, acao_value, sizeof(acao_value) - 1};
    const int is_ping = req->uri_len >= 5 && memcmp(req->uri + req->uri_len - 5, "/ping", 5) == 0;
    st->schemes++;

    if (is_ping) {
        (void)zts_webview_complete_request(st->engine, req->request_id, 200, "application/json", &cors, 1,
                                           (const uint8_t *)ping_json, strlen(ping_json), NULL, NULL);
        return;
    }
    (void)zts_webview_complete_request(st->engine, req->request_id, 200, "text/html; charset=utf-8", &cors, 1,
                                       (const uint8_t *)page_html, strlen(page_html), NULL, NULL);
}

static void on_message(void *userdata, zts_window_id_t window_id, const uint8_t *message, size_t len) {
    (void)window_id;
    app_state_t *st = (app_state_t *)userdata;
    st->messages++;
    if (len >= sizeof(st->report)) len = sizeof(st->report) - 1;
    memcpy(st->report, message, len);
    st->report[len] = '\0';
    st->reported = 1;
    st->pong_seen = strstr(st->report, "\"pong\":42") != NULL;
}

/* ------------------------------------------------------------------------- */

int main(void) {
    app_state_t state;
    host_t host;
    memset(&state, 0, sizeof(state));
    memset(&host, 0, sizeof(host));

    /* 1. The host owns its window first — this is an *existing* application. */
    int rc = host_create(&host, 640, 480);
    if (rc != 0) return rc;

    /* 2. Z-Ts engine on top of it. */
    zts_webview_engine_t *engine = NULL;
    rc = zts_webview_engine_create(ZTS_WEBVIEW_BACKEND_NATIVE, &engine);
    if (rc != ZTS_WEBVIEW_OK || engine == NULL) {
        printf("SKIP c-embed zts_webview_engine_create failed (status=%d)\n", (int)rc);
        host_destroy(&host);
        return EXIT_SKIP;
    }
    state.engine = engine;
    host_post_engine(&host);

    rc = zts_webview_register_scheme(engine, "tauri", on_scheme, &state);
    check(rc == ZTS_WEBVIEW_OK, "register_scheme(tauri)");
    zts_webview_set_message_handler(engine, on_message, &state);

    /* 3. Embed with a deliberately tiny size: the host container must win. */
    zts_window_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.title = "Z-Ts overlay";
    desc.width = 16.0;
    desc.height = 16.0;
    desc.resizable = true;
    desc.visible = true;
    desc.parent_native_handle = (void *)host.container;
    desc.initial_url = "tauri://localhost/index.html";

    zts_window_id_t win = 0;
    rc = zts_webview_window_create(engine, &desc, &win);
    if (rc != ZTS_WEBVIEW_OK || win == 0) {
        printf("FAIL c-embed window_create status=%d\n", (int)rc);
        zts_webview_engine_destroy(engine);
        host_destroy(&host);
        return 1;
    }

    void *native = zts_webview_window_native_handle(engine, win);
    state.structural_ok = host_carries(&host, native);
    check(native != NULL, "native_handle is exposed");
    check(state.structural_ok, "WebView mounted inside the host container");

    for (int i = 0; i < 32; i++) {
        if (!zts_webview_poll(engine)) break;
        host_pump(&host);
    }

    /* 4. The child fills the host, not the 16x16 it asked for. */
    zts_extent host_size = host_container_size(&host);
    zts_extent child_size = host_child_size(native);
    printf("c-embed: initial host=%dx%d child=%dx%d\n", host_size.w, host_size.h, child_size.w, child_size.h);
    check(host_size.w > 0 && host_size.h > 0, "host container has a real client area");
    check(child_size.w + 4 >= host_size.w && child_size.h + 4 >= host_size.h,
          "embedded WebView fills the host client area");

    /* 5. Host-driven frame loop until the page reports back (bounded). */
    int frames = 0;
    while (!state.reported && frames < MAX_FRAMES) {
        if (!zts_webview_poll(engine)) break;
        host_pump(&host);
        frames++;
    }
    printf("c-embed: frames=%d messages=%d schemes=%d report=%s\n", frames, state.messages, state.schemes,
           state.reported ? state.report : "(none)");

    check(state.reported, "page reported back through zts_webview_poll()");
    check(state.schemes >= 1, "custom scheme served the document");
    check(state.pong_seen, "same-origin fetch('/ping') round-tripped");
    check(strstr(state.report, "\"injected\":true") != NULL, "message bridge injected at document start");

    /* 6. Host resize: the overlay follows through `zts_webview_window_fit_parent`. */
    host_resize(&host, 520, 380);
    for (int i = 0; i < 60; i++) {
        if (!zts_webview_poll(engine)) break;
        host_pump(&host);
    }
    check(zts_webview_window_fit_parent(engine, win) == ZTS_WEBVIEW_OK, "fit_parent on an embedded window");
    for (int i = 0; i < 60; i++) {
        if (!zts_webview_poll(engine)) break;
        host_pump(&host);
    }
    zts_extent resized_host = host_container_size(&host);
    zts_extent resized_child = host_child_size(native);
    printf("c-embed: resized host=%dx%d child=%dx%d\n", resized_host.w, resized_host.h, resized_child.w, resized_child.h);
    check(resized_host.w <= 528 && resized_host.h <= 388, "host container accepted the shrink");
    check(resized_child.w > 0 && resized_child.h > 0, "overlay survived the host resize");
    check(resized_child.w + 8 >= resized_host.w && resized_child.h + 8 >= resized_host.h,
          "overlay tracked the resized host container");

    /* 7. Closing the overlay must leave the host application fully alive. */
    check(zts_webview_window_close(engine, win) == ZTS_WEBVIEW_OK, "window_close");
    for (int i = 0; i < 16; i++) {
        if (!zts_webview_poll(engine)) break;
        host_pump(&host);
    }
    check(host_alive(&host), "host window survived the overlay teardown");

    zts_webview_engine_destroy(engine);
    host_destroy(&host);

    if (failures != 0) {
        printf("FAIL c-embed %d check(s) failed\n", failures);
        return 1;
    }

    printf("OK c-embed host=%s checks=9 structural=%d child=%dx%d pong=%d frames=%d\n", host.name, state.structural_ok,
           resized_child.w, resized_child.h, state.pong_seen, frames);
    return 0;
}
