//! Overlay (parent-window) embedding contract tests (`M3-03`).
//!
//! `zts_webview` can mount its WebView as a **child** of a container the application already owns
//! (`GtkContainer*` / `NSView*` / `HWND`), which is what game engines, editor docks and broadcast
//! tools need. The behaviour is spread over a hand-written C shim (macOS), a GTK widget tree
//! (Linux) and a `WS_CHILD` window (Windows), so the *contract* is pinned here rather than
//! re-derived per backend:
//!
//! 1. An embedded window's native handle **is** the child, not a toplevel of its own.
//! 2. `fitParent()` succeeds for embedded windows and returns `error.Unsupported` for toplevels.
//! 3. Closing an embedded window drops only the child: the host container stays alive and usable.
//! 4. `step(.poll)` never blocks, so a host can call it once per frame (`zts_webview_poll`).
//!
//! Cases 1–4 run on the `HeadlessMock` on **every** OS; the GTK case additionally proves the mount
//! structurally (`gtk_widget_get_parent`) on a real X11 display (Xvfb in CI).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const root = @import("mod.zig");
const types = @import("types.zig");
const mock_mod = @import("mock.zig");

const has_gtk = root.has_native_gtk;
const gtk = if (has_gtk) @import("gtk_bindings.zig") else struct {};

/// Stand-in for a host container pointer. Never dereferenced by the mock backend.
var fake_host_container: u8 = 0;

fn hostPointer() *anyopaque {
    return @ptrCast(&fake_host_container);
}

// ---------------------------------------------------------------------------
// 1. Mock contract (runs on Linux / macOS / Windows)
// ---------------------------------------------------------------------------

test "embedding: an embedded mock window records the host handle and supports fit_parent" {
    var m = mock_mod.HeadlessMock.init(testing.allocator, testing.io);
    defer m.deinit();

    const host = try m.createWindow(.{ .title = "host", .size = .wh(1280, 720) });
    const child = try m.createWindow(.{
        .title = "overlay",
        .size = .wh(64, 64),
        .parent_native_handle = hostPointer(),
        .initial_url = "tauri://localhost/index.html",
    });

    // The child remembered the host it was mounted into…
    const child_ptr = m.windows.getPtr(child).?;
    try testing.expectEqual(hostPointer(), child_ptr.parent_native_handle.?);
    // …and the toplevel host has no parent at all.
    try testing.expect(m.windows.getPtr(host).?.parent_native_handle == null);

    try m.fitParent(child);
    try testing.expectEqual(@as(usize, 1), m.windows.getPtr(child).?.fit_count);

    // A toplevel window cannot be "fitted" into a container it does not have.
    try testing.expectError(error.Unsupported, m.fitParent(host));
    try testing.expectEqual(@as(usize, 0), m.windows.getPtr(host).?.fit_count);
}

test "embedding: closing the child leaves the host window alive, closing the host is independent" {
    var m = mock_mod.HeadlessMock.init(testing.allocator, testing.io);
    defer m.deinit();

    const host = try m.createWindow(.{ .title = "host", .size = .wh(800, 600) });
    const child = try m.createWindow(.{ .title = "overlay", .parent_native_handle = hostPointer() });

    try m.closeWindow(child);
    try testing.expect(m.windows.getPtr(child) == null);
    // The host is still registered, still has its geometry, and can still be queried.
    const host_ptr = m.windows.getPtr(host) orelse return error.HostWindowDestroyed;
    try testing.expectEqual(@as(f64, 800), host_ptr.size.width.v);
    try testing.expectEqual(@as(f64, 600), host_ptr.size.height.v);

    // Closing the child again is a plain "not found", not a crash.
    try testing.expectError(error.WindowNotFound, m.closeWindow(child));
    try m.closeWindow(host);
}

test "embedding: fit_parent on an unknown or already-closed window is WindowNotFound" {
    var m = mock_mod.HeadlessMock.init(testing.allocator, testing.io);
    defer m.deinit();

    const stale = try m.createWindow(.{ .parent_native_handle = hostPointer() });
    try m.closeWindow(stale);
    try testing.expectError(error.WindowNotFound, m.fitParent(stale));

    const unknown: types.WindowId = .{ .index = 4095, .generation = 7 };
    try testing.expectError(error.WindowNotFound, m.fitParent(unknown));
}

test "embedding: step(.poll) is non-blocking and survives a host-driven frame loop" {
    var m = mock_mod.HeadlessMock.init(testing.allocator, testing.io);
    defer m.deinit();

    _ = try m.createWindow(.{ .parent_native_handle = hostPointer() });

    // 500 host frames must all return immediately: `step(.poll)` may never enter the blocking
    // condition-variable wait (a regression there would freeze the host's frame loop, so the
    // deadline below turns it into a clean assertion failure instead of a CI timeout).
    const start = std.Io.Clock.Timestamp.now(testing.io, .awake);
    var frames: usize = 0;
    while (frames < 500) : (frames += 1) {
        try testing.expect(m.step(.poll));
    }
    const elapsed = start.untilNow(testing.io).raw.nanoseconds;
    try testing.expect(elapsed >= 0 and elapsed < 2 * std.time.ns_per_s);

    m.requestQuit();
    try testing.expect(!m.step(.poll));
}

// ---------------------------------------------------------------------------
// 2. Real GTK3 embed (Xvfb under CI; skipped without a display)
// ---------------------------------------------------------------------------

test "embedding: a real GtkBox host mounts the WebView as its expanding child and outlives it" {
    if (comptime !has_gtk) return error.SkipZigTest;

    if (comptime has_gtk) {
        const gtkb = @import("gtk_bindings.zig");
        if (gtkb.gtk_init_check(null, null) == 0) return error.SkipZigTest;

        // --- host-owned GTK tree: GtkWindow → GtkBox → our WebView ---------------------------
        const host_window = gtkb.gtk_window_new(gtkb.GTK_WINDOW_TOPLEVEL);
        defer gtkb.gtk_widget_destroy(host_window);
        gtkb.gtk_window_set_default_size(@ptrCast(host_window), 640, 480);
        gtkb.gtk_window_set_title(@ptrCast(host_window), "M3-03 embed host");

        const box = gtkb.gtk_box_new(gtkb.GTK_ORIENTATION_VERTICAL, 0);
        gtkb.gtk_container_add(@ptrCast(host_window), box);
        gtkb.gtk_widget_show_all(host_window);
        // Let GTK allocate the host tree so `fit_parent` sees a non-zero client area.
        for (0..8) |_| _ = gtkb.g_main_context_iteration(null, 0);

        const backend = root.linux.LinuxGtkBackend.init(testing.allocator, testing.io) catch |err| {
            // No display in this environment: the mock contract tests above already covered the
            // semantics, so skip rather than fail (CI runs this under Xvfb).
            if (err == error.DisplayUnavailable) return error.SkipZigTest;
            return err;
        };
        defer backend.deinit();
        backend.force_software_render = true;

        const win = try backend.createWindow(.{
            .title = "overlay",
            .size = .wh(32, 32), // deliberately wrong: the host container must win
            .parent_native_handle = box,
            .initial_html = "<!doctype html><title>embed</title><p>overlay</p>",
        });

        // (1) Structural proof of the mount, inspected from the host side of the tree.
        const handle = backend.nativeHandle(win) orelse return error.NoNativeHandle;
        const webview_widget: *gtkb.GtkWidget = @ptrCast(@alignCast(handle));
        const mounted_parent = gtkb.gtk_widget_get_parent(webview_widget) orelse return error.NotMounted;
        try testing.expectEqual(box, mounted_parent);
        try testing.expect(mounted_parent != host_window);
        // No `GtkWindow` of its own: an embedded window must never spawn a second OS window.
        try testing.expect(backend.windows.getPtr(win).?.toplevel == null);

        // (2) `fit_parent` succeeds because the window is embedded…
        for (0..4) |_| _ = gtkb.g_main_context_iteration(null, 0);
        try backend.fitParent(win);

        // …while a toplevel window refuses it.
        const toplevel = try backend.createWindow(.{ .title = "toplevel", .size = .wh(120, 90) });
        try testing.expectError(error.Unsupported, backend.fitParent(toplevel));
        try testing.expect(backend.windows.getPtr(toplevel).?.toplevel != null);

        // (3) Drive a few host frames (`zts_webview_poll` equivalent): each one must return.
        var frames: usize = 0;
        while (frames < 30 and backend.step(.poll)) : (frames += 1) {}
        try testing.expectEqual(@as(usize, 30), frames);

        // (4) Closing the child leaves the host tree alive and usable.
        try backend.closeWindow(win);
        try testing.expectEqual(@as(u32, 1), backend.windows.count()); // only the toplevel remains
        gtkb.gtk_widget_show_all(host_window);
        _ = gtkb.g_main_context_iteration(null, 0);
        // The host is still realised, i.e. we did not destroy somebody else's window.
        try testing.expect(gtkb.gtk_widget_get_parent(box) == host_window);

        try backend.closeWindow(toplevel);
    }
}
