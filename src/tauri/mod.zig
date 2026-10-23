//! `zts_tauri` — Standalone Tauri v2 Wire Protocol, Streaming `Channel(T)` & Core Plugins (`link_libc = false`).
//!
//! Designed strictly around `ADR-0002` & multi-product reuse constraints:
//! - Depends ONLY on `zts_foundation`, `zts_web`, `zts_core`, and `zts_rpc` (`link_libc = false`).
//! - Zero compile-time or link-time dependency on GTK, Cocoa, Win32, or HTTP sockets.
//! - Runs identically atop `WebviewHost` (native desktop), `BridgeHost` (browser / Live Preview),
//!   or `RecordingHost` (0ms deterministic unit tests).
//! - Every plugin (`window`, `event`, `path`, `app`, `resources`) is an ordinary `zts_rpc` namespace
//!   so applications that only cherry-pick specific plugins pay **0 bytes** for the rest via DCE.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const core = @import("zts_core");
const rpc = @import("zts_rpc");

pub const app = @import("app.zig");
pub const channel = @import("channel.zig");
pub const event = @import("event.zig");
pub const js_bootstrap = @import("js_bootstrap.zig");
pub const path = @import("path.zig");
pub const protocol = @import("protocol.zig");
pub const resources = @import("resources.zig");
pub const window = @import("window.zig");

pub const AppConfig = app.AppConfig;
pub const AppState = app.AppState;
pub const BaseDirectory = path.BaseDirectory;
pub const BootstrapOptions = js_bootstrap.BootstrapOptions;
pub const Channel = channel.Channel;
pub const ChannelError = channel.ChannelError;
pub const EventBus = event.EventBus;
pub const EventTarget = event.EventTarget;
pub const HeaderPair = protocol.HeaderPair;
pub const IncomingSchemeRequest = protocol.IncomingSchemeRequest;
pub const OsTarget = js_bootstrap.OsTarget;
pub const PathState = path.PathState;
pub const ProtocolConfig = protocol.ProtocolConfig;
pub const ProtocolRouter = protocol.ProtocolRouter;
pub const ResourceTable = resources.ResourceTable;
pub const RoutedResponse = protocol.RoutedResponse;
pub const WindowRegistry = window.WindowRegistry;
pub const WirePosition = window.WirePosition;
pub const WireSize = window.WireSize;

/// Pre-built schema combining all 5 official `@tauri-apps/api` v2 core plugin namespaces.
/// Prefixed with `tauri_*` so user schemas can freely declare `.app`, `.window`, `.event`, or `.path`!
pub const CorePluginsSchema = rpc.Schema(.{
    .tauri_window = window.Commands,
    .tauri_event = event.Commands,
    .tauri_path = path.Commands,
    .tauri_app = app.Commands,
    .tauri_resources = resources.Commands,
});

/// Merges a user's application `rpc.Schema(...)` (or `.{ .ns = Cmds }` struct literal)
/// with all 5 Tauri v2 core plugins in one line.
pub fn withCorePlugins(comptime app_schema_or_specs: anytype) type {
    if (@TypeOf(app_schema_or_specs) == type) {
        return rpc.merge(.{ app_schema_or_specs, CorePluginsSchema });
    }
    return rpc.merge(.{ rpc.Schema(app_schema_or_specs), CorePluginsSchema });
}

/// Bundles runtime state for all 5 Tauri v2 core plugins and wires automatic window-label lookup.
pub const CorePluginStates = struct {
    windows: WindowRegistry,
    events: EventBus,
    paths: PathState,
    app_state: AppState,
    resources: ResourceTable,

    /// Heap-allocated bundle because internal cross-references (`events.window_labels -> &self.windows`)
    /// require a stable memory address.
    pub fn create(
        allocator: Allocator,
        io: Io,
        app_cfg: AppConfig,
        path_cfg: PathState,
    ) Allocator.Error!*CorePluginStates {
        const self = try allocator.create(CorePluginStates);
        var effective_paths = path_cfg;
        if (std.mem.eql(u8, effective_paths.app_identifier, "com.zts.app")) {
            effective_paths.app_identifier = app_cfg.identifier;
        }
        self.* = .{
            .windows = WindowRegistry.init(allocator, io),
            .events = EventBus.init(allocator, io),
            .paths = effective_paths,
            .app_state = AppState.init(io, app_cfg),
            .resources = ResourceTable.init(allocator, io),
        };
        self.events.window_labels = lookupWindowLabel;
        self.events.window_labels_ctx = &self.windows;
        return self;
    }

    pub fn destroy(self: *CorePluginStates) void {
        const alloc = self.windows.allocator;
        self.resources.deinit();
        self.events.deinit();
        self.windows.deinit();
        alloc.destroy(self);
    }

    fn lookupWindowLabel(ud: ?*anyopaque, alloc: Allocator, wid: core.WindowId) Allocator.Error!?[]u8 {
        const reg: *WindowRegistry = @ptrCast(@alignCast(ud.?));
        return reg.labelForIdAlloc(alloc, wid);
    }
};

test {
    _ = app;
    _ = channel;
    _ = event;
    _ = js_bootstrap;
    _ = path;
    _ = protocol;
    _ = resources;
    _ = window;
}
