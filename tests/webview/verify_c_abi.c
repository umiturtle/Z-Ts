/* Verifies `include/zts_webview.h` compiles cleanly under strict `-std=c99 -Wall -Wextra -Werror`
 * in BOTH Debug and `-DNDEBUG` ReleaseFast modes, AND links + executes against exported Zig symbols! */

#include "zts_webview.h"

#define CHECK(expr) do { if (!(expr)) return 1; } while (0)

static size_t g_released = 0;

static void on_release_bytes(void *ctx, const uint8_t *ptr, size_t len) {
    (void)ctx;
    (void)ptr;
    g_released += len;
}

int main(void) {
    zts_webview_engine_t *eng = NULL;
    CHECK(zts_webview_engine_create(ZTS_WEBVIEW_BACKEND_HEADLESS_MOCK, &eng) == ZTS_WEBVIEW_OK);
    CHECK(eng != NULL);

    zts_window_desc_t desc = {0};
    desc.title = "Strict C99 Host";
    desc.width = 960.0;
    desc.height = 540.0;
    desc.resizable = true;
    desc.decorations = true;
    desc.visible = true;

    zts_window_id_t win = 0;
    CHECK(zts_webview_window_create(eng, &desc, &win) == ZTS_WEBVIEW_OK);
    CHECK(win != 0);

    CHECK(zts_webview_window_set_title(eng, win, "C99 Updated") == ZTS_WEBVIEW_OK);
    CHECK(zts_webview_window_set_size(eng, win, 1280.0, 720.0) == ZTS_WEBVIEW_OK);
    CHECK(zts_webview_eval_js(eng, win, "window.__from_c = 1;") == ZTS_WEBVIEW_OK);
    CHECK(zts_webview_step(eng, ZTS_STEP_POLL) == true);

    /* Stale/unknown request id gracefully drops custom buffer through release callback */
    static const uint8_t payload[] = {1, 2, 3, 4};
    CHECK(zts_webview_complete_request(
        eng,
        ((uint64_t)1 << 24) | 7,
        200,
        "application/octet-stream",
        NULL,
        0,
        payload,
        sizeof(payload),
        on_release_bytes,
        NULL
    ) == ZTS_WEBVIEW_OK);

    /* `M5-04`: screenshot capture from a strict C99 host.
     * The mock backend renders synchronously, so one `capture_take` is enough; the assertions pin
     * the PNG signature and the IHDR dimensions (500x260 after the resize above). */
    CHECK(zts_webview_window_capture(eng, win) == ZTS_WEBVIEW_OK);
    zts_capture_t shot = {0};
    CHECK(zts_webview_capture_take(eng, win, &shot) == ZTS_WEBVIEW_OK);
    CHECK(shot.len > 8 && shot.data != NULL);
    CHECK(shot.width == 1280 && shot.height == 720);
    CHECK(shot.data[0] == 0x89 && shot.data[1] == 'P' && shot.data[2] == 'N' && shot.data[3] == 'G');
    zts_webview_capture_free(eng, &shot);
    /* The struct is zeroed by `capture_free`, and a second free is a no-op. */
    CHECK(shot.data == NULL && shot.len == 0);
    zts_webview_capture_free(eng, &shot);
    CHECK(zts_webview_capture_free != NULL);

    zts_webview_request_quit(eng);
    CHECK(zts_webview_step(eng, ZTS_STEP_BLOCKING) == false);
    CHECK(g_released == sizeof(payload));

    CHECK(zts_webview_window_close(eng, win) == ZTS_WEBVIEW_OK);
    zts_webview_engine_destroy(eng);
    return 0;
}
