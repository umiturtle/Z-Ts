//! `@tauri-apps/api/menu` v2 wire-compatible Menu plugin (`plugin:menu|*`, `link_libc = false`).
//!
//! The JS surface (`Menu`, `Submenu`, `MenuItem`, `CheckMenuItem`, `IconMenuItem`,
//! `PredefinedMenuItem`) talks to Rust through a **resource graph**: every node is registered in the
//! app `ResourceTable`, mutations (`append` / `insert` / `remove` / `set_text` …) address it by
//! `rid`, and activations are pushed back over a `Channel<string>` carrying the node's `MenuId`.
//!
//! Z-Ts keeps that exact wire shape but stores the tree itself, so the whole plugin — including the
//! flattening step every backend consumes — is deterministic Pure Zig:
//!
//! ```text
//! Menu (root)                 Node { kind = .Menu, children = … }
//!  ├─ File      (Submenu)      ├─ Node { kind = .Submenu, children = … }
//!  │   └─ Quit   (Predefined)   │    └─ Node { kind = .Predefined, predefined = .Quit }
//!  └─ Edit…                     └─ …
//!        │  flatten (pre-order, depth)
//!        ▼
//!   Backend.applyAppMenu(Snapshot)   ← Mock records it (tested on every OS),
//!                                       GTK / AppKit / Win32 render it natively
//! ```
//!
//! Design notes:
//! - `MenuId` matches `muda::MenuId`: user-supplied ids are used verbatim, otherwise a per-state
//!   counter renders `"1"`, `"2"`, … (`muda::util::next_id`).
//! - `rid`s live in the shared `plugin:resources` table, so `await menu.close()` works unchanged and
//!   a closed node detaches itself from its parent (no dangling children).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const core = @import("zts_core");
const rpc = @import("zts_rpc");

const Channel = @import("../channel.zig").Channel;
const ResourceTable = @import("../resources.zig").ResourceTable;
const accelerator = @import("accelerator.zig");

test {
    _ = accelerator;
}

pub const Accelerator = accelerator.Accelerator;
pub const Mods = accelerator.Mods;

pub const MenuError = error{
    /// No usable native backend (headless session, unsupported platform).
    Unavailable,
    /// The platform rejected the menu (bad accelerator, unsupported operation, …).
    Failed,
    /// `rid` is unknown, already closed, or refers to a different item kind.
    BadResourceId,
    /// The operation is not valid for this item kind (e.g. `UnexpectedMenuKind` upstream).
    UnexpectedMenuKind,
    /// `get` / `remove_at` found nothing at that position or id.
    NotFound,
    /// A `Predefined` item was created without the required `item` option.
    MissingPredefinedItem,
    /// The `accelerator` string could not be parsed.
    InvalidAccelerator,
    OutOfMemory,
};

// ============================================================================
// Wire types
// ============================================================================

/// `muda::ItemKind` — serde serializes the unit variants as their names.
pub const ItemKind = enum {
    Menu,
    Submenu,
    MenuItem,
    Predefined,
    Check,
    Icon,

    /// Only containers (`Menu` / `Submenu`) hold children.
    pub fn isContainer(self: ItemKind) bool {
        return self == .Menu or self == .Submenu;
    }
};

/// `muda::NativeIcon` — the platform-provided stock icons.
pub const NativeIcon = enum {
    Add,
    Remove,
    About,
    Services,
    Separator,
    Copy,
    Cut,
    Paste,
    SelectAll,
    Undo,
    Redo,
    Minimize,
    Maximize,
    Fullscreen,
    Hide,
    HideOthers,
    ShowAll,
    CloseWindow,
    Quit,
    BringAllToFront,
};

/// `tauri::menu::AboutMetadata` (`camelCase` on the wire).
pub const AboutMetadata = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    short_version: ?[]const u8 = null,
    authors: ?[]const []const u8 = null,
    comments: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    license: ?[]const u8 = null,
    website: ?[]const u8 = null,
    website_label: ?[]const u8 = null,
    credits: ?[]const u8 = null,
};

/// `tauri::menu::PredefinedMenuItem` payload (`serde` externally tagged).
pub const Predefined = union(enum) {
    Separator,
    Copy,
    Cut,
    Paste,
    SelectAll,
    Undo,
    Redo,
    Minimize,
    Maximize,
    Fullscreen,
    Hide,
    HideOthers,
    ShowAll,
    CloseWindow,
    Quit,
    About: ?AboutMetadata,
    Services,
    BringAllToFront,

    /// Human-readable fallback label used when the frontend did not pass `text`.
    pub fn defaultText(self: Predefined) []const u8 {
        return switch (self) {
            .Separator => "",
            .Copy => "Copy",
            .Cut => "Cut",
            .Paste => "Paste",
            .SelectAll => "Select All",
            .Undo => "Undo",
            .Redo => "Redo",
            .Minimize => "Minimize",
            .Maximize => "Maximize",
            .Fullscreen => "Toggle Fullscreen",
            .Hide => "Hide",
            .HideOthers => "Hide Others",
            .ShowAll => "Show All",
            .CloseWindow => "Close Window",
            .Quit => "Quit",
            .About => "About",
            .Services => "Services",
            .BringAllToFront => "Bring All to Front",
        };
    }

    pub fn fromName(name: []const u8) ?Predefined {
        inline for (@typeInfo(Predefined).@"union".field_names) |field_name| {
            if (std.mem.eql(u8, name, field_name)) {
                if (comptime std.mem.eql(u8, field_name, "About")) return .{ .About = null };
                return @unionInit(Predefined, field_name, {});
            }
        }
        return null;
    }
};

/// `tauri::image::JsImage` — untagged: path string, raw ICO/PNG bytes, or an `plugin:image` `rid`.
pub const JsImage = union(enum) {
    path: []const u8,
    bytes: []const u8,
    resource: u53,
};

/// `tauri::menu::Icon` — untagged between a stock icon name and a `JsImage`.
pub const Icon = union(enum) {
    native: NativeIcon,
    image: JsImage,

    pub fn fromValue(value: std.json.Value) ?Icon {
        switch (value) {
            .string => |s| {
                inline for (@typeInfo(NativeIcon).@"enum".field_names, 0..) |field_name, index| {
                    if (std.mem.eql(u8, s, field_name)) return .{ .native = @fromBackingInt(@intCast(index)) };
                }
                return .{ .image = .{ .path = s } };
            },
            .integer => |n| return .{ .image = .{ .resource = @intCast(@max(n, 0)) } },
            .float => |f| return .{ .image = .{ .resource = @intFromFloat(@max(f, 0)) } },
            .array => |arr| {
                // Raw ICO/PNG bytes are accepted (wire compatibility) but not decoded: menu icons
                // are rendered from `NativeIcon` only, so the payload is recorded as empty.
                _ = arr;
                return .{ .image = .{ .bytes = "" } };
            },
            else => return null,
        }
    }
};

/// `MenuItemPayloadKind` — untagged: either `[rid, kind]` (an existing resource) or an inline
/// options object. `zts_rpc` cannot express "array **or** object", so decoding is manual.
pub const Spec = struct {
    resource: ?ResourceRef = null,
    options: ?Options = null,

    pub const ResourceRef = struct {
        rid: u53,
        kind: ItemKind,
    };

    pub fn decodeZtsJson(allocator: Allocator, raw: []const u8) rpc.DecodeError!Spec {
        const value = parseValue(allocator, raw) catch |err| return toDecodeError(err);
        switch (value) {
            .array => |arr| {
                if (arr.items.len != 2) return error.UnexpectedToken;
                const rid = asU53(arr.items[0]) orelse return error.UnexpectedToken;
                const kind = asItemKind(arr.items[1]) orelse return error.UnknownField;
                return .{ .resource = .{ .rid = rid, .kind = kind } };
            },
            .object => |obj| return .{ .options = try Options.fromObject(allocator, obj) },
            else => return error.UnexpectedToken,
        }
    }
};

/// `MenuItemOptions | SubmenuOptions | CheckMenuItemOptions | IconMenuItemOptions |
/// PredefinedMenuItemOptions` — the superset that `plugin:menu|new` and nested `items` accept.
pub const Options = struct {
    id: ?[]const u8 = null,
    text: ?[]const u8 = null,
    enabled: ?bool = null,
    checked: ?bool = null,
    accelerator: ?[]const u8 = null,
    /// `Predefined` payload (the wire key is `item`, not `predefined`).
    item: ?Predefined = null,
    icon: ?Icon = null,
    items: ?[]const Spec = null,
    /// `Channel<string>` injected by `@tauri-apps/api/menu` for nested items with an `action`.
    handler: ?u32 = null,

    pub fn decodeZtsJson(allocator: Allocator, raw: []const u8) rpc.DecodeError!Options {
        const value = parseValue(allocator, raw) catch |err| return toDecodeError(err);
        const obj = switch (value) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        return Options.fromObject(allocator, obj);
    }

    fn fromObject(allocator: Allocator, obj: std.json.ObjectMap) rpc.DecodeError!Options {
        var out: Options = .{};
        var it = obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "id")) {
                out.id = asString(value) orelse return error.UnexpectedToken;
            } else if (std.mem.eql(u8, key, "text")) {
                out.text = asString(value) orelse return error.UnexpectedToken;
            } else if (std.mem.eql(u8, key, "enabled")) {
                out.enabled = asBool(value) orelse return error.UnexpectedToken;
            } else if (std.mem.eql(u8, key, "checked")) {
                out.checked = asBool(value) orelse return error.UnexpectedToken;
            } else if (std.mem.eql(u8, key, "accelerator")) {
                out.accelerator = if (value == .null) null else (asString(value) orelse return error.UnexpectedToken);
            } else if (std.mem.eql(u8, key, "item")) {
                out.item = try parsePredefined(allocator, value);
            } else if (std.mem.eql(u8, key, "icon")) {
                out.icon = if (value == .null) null else (Icon.fromValue(value) orelse return error.UnexpectedToken);
            } else if (std.mem.eql(u8, key, "items")) {
                if (value == .null) continue;
                const arr = switch (value) {
                    .array => |a| a,
                    else => return error.UnexpectedToken,
                };
                const specs = try allocator.alloc(Spec, arr.items.len);
                errdefer allocator.free(specs);
                for (arr.items, 0..) |item, i| {
                    specs[i] = switch (item) {
                        .array => |tuple| blk: {
                            if (tuple.items.len != 2) return error.UnexpectedToken;
                            break :blk .{ .resource = .{
                                .rid = asU53(tuple.items[0]) orelse return error.UnexpectedToken,
                                .kind = asItemKind(tuple.items[1]) orelse return error.UnknownField,
                            } };
                        },
                        .object => |sub| .{ .options = try Options.fromObject(allocator, sub) },
                        else => return error.UnexpectedToken,
                    };
                }
                out.items = specs;
            } else if (std.mem.eql(u8, key, "handler")) {
                out.handler = try parseChannelId(value);
            } else {
                // `action` is deleted client-side; unknown keys are ignored like serde's default.
                continue;
            }
        }
        return out;
    }

    fn parsePredefined(_: Allocator, value: std.json.Value) rpc.DecodeError!?Predefined {
        switch (value) {
            .null => return null,
            .string => |s| {
                const bare = Predefined.fromName(s) orelse return error.UnknownField;
                return bare;
            },
            .object => |obj| {
                var it = obj.iterator();
                const entry = it.next() orelse return error.UnexpectedToken;
                const tag = entry.key_ptr.*;
                if (!std.mem.eql(u8, tag, "About")) return error.UnknownField;
                // The metadata itself is not retained: Z-Ts renders the About panel from
                // `AppConfig` (name / version / identifier) instead of per-item strings, which keeps
                // every node free of borrowed decoded memory.
                return Predefined{ .About = null };
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseChannelId(value: std.json.Value) rpc.DecodeError!u32 {
        const raw = asString(value) orelse return error.UnexpectedToken;
        const prefix = "__CHANNEL__:";
        if (!std.mem.startsWith(u8, raw, prefix)) return error.UnexpectedToken;
        return std.fmt.parseInt(u32, raw[prefix.len..], 10) catch error.InvalidNumber;
    }
};

/// Verbatim JSON argument (`null` collapses to `value == null`).
///
/// `plugin:menu|popup`'s `at` and `set_icon`'s `icon` are untagged shapes owned by `@tauri-apps/api`,
/// so they are decoded lazily through this hook instead of a rigid Zig struct.
pub const JsonArg = struct {
    value: ?std.json.Value = null,

    pub fn decodeZtsJson(allocator: Allocator, raw: []const u8) rpc.DecodeError!JsonArg {
        const value = parseValue(allocator, raw) catch |err| return toDecodeError(err);
        return .{ .value = if (value == .null) null else value };
    }
};

/// `tauri_runtime::dpi::Position` — `{"Logical": {x, y}}` or `{"Physical": {x, y}}`.
pub const Position = struct {
    x: f64,
    y: f64,
    logical: bool = true,

    pub fn fromJsonValue(value: std.json.Value) ?Position {
        const obj = switch (value) {
            .object => |o| o,
            else => return null,
        };
        if (obj.get("Logical")) |inner| {
            if (readPoint(inner)) |p| return .{ .x = p.x, .y = p.y, .logical = true };
        }
        if (obj.get("Physical")) |inner| {
            if (readPoint(inner)) |p| return .{ .x = p.x, .y = p.y, .logical = false };
        }
        return null;
    }

    const Point2 = struct { x: f64, y: f64 };

    fn readPoint(value: std.json.Value) ?Point2 {
        const coords = switch (value) {
            .object => |o| o,
            else => return null,
        };
        const x = asF64(coords.get("x") orelse return null) orelse return null;
        const y = asF64(coords.get("y") orelse return null) orelse return null;
        return .{ .x = x, .y = y };
    }
};

// ============================================================================
// Snapshot — the only thing a backend ever sees
// ============================================================================

pub const EntryKind = enum {
    /// A `Submenu`: opens its children (`depth + 1`).
    submenu,
    /// A plain / check / icon / predefined item (leaf).
    item,
    /// A `Predefined::Separator`.
    separator,

    pub fn of(kind: ItemKind, predefined: ?Predefined) EntryKind {
        if (kind == .Submenu) return .submenu;
        if (predefined) |p| if (p == .Separator) return .separator;
        return .item;
    }
};

pub const Entry = struct {
    kind: EntryKind,
    /// Wire `MenuId` (what `Channel<string>` reports on activation).
    id: []const u8,
    text: []const u8,
    enabled: bool = true,
    checked: bool = false,
    accelerator: ?Accelerator = null,
    /// 0 for top-level entries, `parent.depth + 1` inside a submenu.
    depth: u16 = 0,
    /// Set for `Predefined` leaves so backends can map them to native roles.
    predefined: ?Predefined = null,
    /// `ItemKind` (`Check` / `Icon` / `MenuItem` / `Predefined`).
    item_kind: ItemKind = .MenuItem,
};

pub const Snapshot = struct {
    entries: []const Entry,

    pub fn len(self: Snapshot) usize {
        return self.entries.len;
    }
};

/// Flattens a tree in pre-order. Entries borrow the nodes' strings, so the snapshot is only valid
/// while the nodes live (every backend consumes it synchronously).
pub fn flatten(allocator: Allocator, root: *const Node) Allocator.Error![]Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer out.deinit(allocator);
    try appendEntries(allocator, &out, root, 0);
    return out.toOwnedSlice(allocator);
}

fn appendEntries(allocator: Allocator, out: *std.ArrayListUnmanaged(Entry), node: *const Node, depth: u16) Allocator.Error!void {
    for (node.children.items) |child| {
        try out.append(allocator, .{
            .kind = EntryKind.of(child.kind, child.predefined),
            .id = child.id,
            .text = child.text,
            .enabled = child.enabled,
            .checked = child.checked,
            .accelerator = child.accelerator,
            .depth = depth,
            .predefined = child.predefined,
            .item_kind = child.kind,
        });
        if (child.kind.isContainer()) try appendEntries(allocator, out, child, depth + 1);
    }
}

// ============================================================================
// Tree node (stored inside the shared `plugin:resources` table)
// ============================================================================

pub const Node = struct {
    state: *MenuState,
    allocator: Allocator,
    /// `plugin:resources` handle (set right after insertion; `0` while unregistered).
    rid: u53 = 0,
    kind: ItemKind,
    id: []const u8,
    text: []const u8,
    enabled: bool = true,
    checked: bool = false,
    accelerator: ?Accelerator = null,
    predefined: ?Predefined = null,
    icon: ?Icon = null,
    /// `Channel<string>` for this item's activation (`action` in JS).
    handler: ?u32 = null,
    parent: ?*Node = null,
    children: std.ArrayListUnmanaged(*Node) = .empty,
    /// Every string this node owns (freed in `deinit`).
    owned: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Node) void {
        // Detach from the parent so a closed node never leaves a dangling child pointer.
        self.state.detach(self);
        if (self.parent) |p| {
            for (p.children.items, 0..) |child, i| {
                if (child == self) {
                    _ = p.children.orderedRemove(i);
                    break;
                }
            }
        }
        for (self.children.items) |child| child.parent = null;
        self.children.deinit(self.allocator);
        for (self.owned.items) |s| self.allocator.free(s);
        self.owned.deinit(self.allocator);
    }

    fn adopt(self: *Node, bytes: []const u8) Allocator.Error![]const u8 {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.owned.append(self.allocator, copy);
        return copy;
    }
};

// ============================================================================
// Backend vtable
// ============================================================================

pub const Backend = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Installs `snapshot` as the app-wide (menu bar) menu.
        apply_app_menu: *const fn (ctx: ?*anyopaque, snapshot: Snapshot) MenuError!void,
        /// Installs `snapshot` as the menu bar of `window` (label; `null` = every window).
        apply_window_menu: *const fn (ctx: ?*anyopaque, window: ?[]const u8, snapshot: Snapshot) MenuError!void,
        /// Shows `snapshot` as a context menu at `at` (`null` = current mouse position).
        popup: *const fn (ctx: ?*anyopaque, window: ?[]const u8, snapshot: Snapshot, at: ?Position) MenuError!void,
    };

    pub fn applyAppMenu(self: Backend, snapshot: Snapshot) MenuError!void {
        return self.vtable.apply_app_menu(self.ctx, snapshot);
    }
    pub fn applyWindowMenu(self: Backend, window: ?[]const u8, snapshot: Snapshot) MenuError!void {
        return self.vtable.apply_window_menu(self.ctx, window, snapshot);
    }
    pub fn popup(self: Backend, window: ?[]const u8, snapshot: Snapshot, at: ?Position) MenuError!void {
        return self.vtable.popup(self.ctx, window, snapshot, at);
    }
};

// ============================================================================
// State
// ============================================================================

pub const MenuState = struct {
    allocator: Allocator,
    io: Io,
    /// The shared `plugin:resources` table (menu `rid`s live there, like upstream).
    resources: *ResourceTable,
    backend: Backend,
    /// `muda::util::next_id` replacement: ids default to `"1"`, `"2"`, …
    next_id: u32 = 1,
    app_menu: ?*Node = null,
    window_menus: std.StringHashMapUnmanaged(*Node) = .empty,
    /// Menu id → activation channel. Values are fixed-size so the map never reallocates payloads.
    channels: std.StringHashMapUnmanaged(ChannelEntry) = .empty,

    pub const ChannelEntry = struct {
        channel: Channel([]const u8),
        call_ctx: ?core.CallContext = null,
    };

    pub fn init(allocator: Allocator, io: Io, resources: *ResourceTable) MenuState {
        return .{ .allocator = allocator, .io = io, .resources = resources, .backend = Backend{ .vtable = &StubBackend.vtable } };
    }

    pub fn withBackend(self: MenuState, backend: Backend) MenuState {
        var copy = self;
        copy.backend = backend;
        return copy;
    }

    /// Frees bookkeeping only: every `Node` is owned by `resources`, so call `resources.deinit()`
    /// **before** this.
    pub fn deinit(self: *MenuState) void {
        var ch = self.channels.iterator();
        while (ch.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.channels.deinit(self.allocator);
        self.window_menus.deinit(self.allocator);
    }

    /// Assigns `node.id`: user-supplied ids verbatim, otherwise `"1"`, `"2"`, … (`muda`).
    fn assignId(self: *MenuState, node: *Node, explicit: ?[]const u8) Allocator.Error!void {
        if (explicit) |id| {
            node.id = try node.adopt(id);
            return;
        }
        const rendered = try std.fmt.allocPrint(self.allocator, "{d}", .{self.next_id});
        defer self.allocator.free(rendered);
        self.next_id += 1;
        node.id = try node.adopt(rendered);
    }

    fn registerChannel(self: *MenuState, id: []const u8, handler: ?u32, call_ctx: ?core.CallContext) Allocator.Error!void {
        const number = handler orelse return;
        const key = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(key);
        try self.channels.put(self.allocator, key, .{ .channel = Channel([]const u8).init(number), .call_ctx = call_ctx });
    }

    /// Pushes an activation for `id` into its channel (called by native backends / the `Mock`).
    pub fn activate(self: *MenuState, scratch: Allocator, id: []const u8) void {
        const entry = self.channels.getPtr(id) orelse return;
        const call_ctx = entry.call_ctx orelse return;
        entry.channel.send(call_ctx.host, call_ctx.window_id, scratch, id) catch {};
    }

    /// Drops `node` from the app/window registries (called from `Node.deinit`).
    fn detach(self: *MenuState, node: *Node) void {
        if (self.app_menu == node) self.app_menu = null;
        var it = self.window_menus.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == node) {
                self.window_menus.removeByPtr(entry.key_ptr);
                return;
            }
        }
    }

    fn snapshotOf(_: *MenuState, scratch: Allocator, root: *const Node) MenuError![]Entry {
        return flatten(scratch, root) catch error.OutOfMemory;
    }

    /// Re-pushes every attached menu to the backend after a mutation.
    pub fn refresh(self: *MenuState, scratch: Allocator) MenuError!void {
        if (self.app_menu) |root| {
            try self.backend.applyAppMenu(.{ .entries = try self.snapshotOf(scratch, root) });
        }
        var it = self.window_menus.iterator();
        while (it.next()) |entry| {
            try self.backend.applyWindowMenu(entry.key_ptr.*, .{ .entries = try self.snapshotOf(scratch, entry.value_ptr.*) });
        }
    }

    /// Builds a node (and its nested children) from decoded options.
    fn createNode(
        self: *MenuState,
        scratch: Allocator,
        kind: ItemKind,
        options: Options,
        call_ctx: ?core.CallContext,
    ) MenuError!*Node {
        if (kind == .Predefined and options.item == null) return error.MissingPredefinedItem;

        // Insert a shell first: `ResourceTable` owns the storage, so the `*Node` every tree edge
        // and every `rid` lookup uses is the *table* copy (stable address for the table's lifetime).
        const rid = self.resources.insertOwned(Node, .{
            .state = self,
            .allocator = self.allocator,
            .kind = kind,
            .id = "",
            .text = "",
        }) catch return error.OutOfMemory;
        errdefer self.resources.closeRid(rid) catch {};
        const node = self.resources.getPtr(Node, rid) catch return error.BadResourceId;
        node.rid = rid;

        self.assignId(node, options.id) catch return error.OutOfMemory;
        node.text = node.adopt(options.text orelse switch (kind) {
            .Predefined => if (options.item) |p| p.defaultText() else "",
            else => "",
        }) catch return error.OutOfMemory;

        node.enabled = options.enabled orelse true;
        node.checked = options.checked orelse false;
        node.predefined = options.item;
        node.icon = options.icon;
        node.handler = options.handler;
        if (options.accelerator) |raw| {
            node.accelerator = Accelerator.parse(raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidAccelerator => return error.InvalidAccelerator,
            };
        }

        if (options.items) |specs| {
            for (specs) |spec| {
                const child = try self.createChild(scratch, spec, call_ctx);
                child.parent = node;
                node.children.append(self.allocator, child) catch return error.OutOfMemory;
            }
        }

        try self.registerChannel(node.id, node.handler, call_ctx);
        return node;
    }

    fn createChild(self: *MenuState, scratch: Allocator, spec: Spec, call_ctx: ?core.CallContext) MenuError!*Node {
        if (spec.resource) |ref| {
            const existing = self.lookup(ref.rid, ref.kind) orelse return error.BadResourceId;
            if (existing.parent != null) return error.UnexpectedMenuKind;
            return existing;
        }
        const opts = spec.options orelse return error.UnexpectedMenuKind;
        return self.createNode(scratch, inferKind(opts), opts, call_ctx);
    }

    /// Looks up a node by resource id, verifying the caller's `kind` claim.
    pub fn lookup(self: *MenuState, rid: u53, kind: ItemKind) ?*Node {
        const node = self.resources.getPtr(Node, rid) catch return null;
        if (node.state != self) return null;
        if (node.kind != kind and !(kind.isContainer() and node.kind.isContainer())) return null;
        return node;
    }
};

/// Infers the `ItemKind` of an inline options object (the wire object itself carries no `kind`).
fn inferKind(opts: Options) ItemKind {
    if (opts.items != null) return .Submenu;
    if (opts.item != null) return .Predefined;
    if (opts.checked != null) return .Check;
    if (opts.icon != null) return .Icon;
    return .MenuItem;
}

/// Fallback backend: every operation reports `error.Unavailable` (headless / unsupported OS).
/// Keeps `plugin:menu` importable without any native toolkit, so DCE still removes it entirely.
pub const StubBackend = struct {
    pub const vtable = Backend.VTable{
        .apply_app_menu = unavailableApp,
        .apply_window_menu = unavailableWindow,
        .popup = unavailablePopup,
    };
    fn unavailableApp(_: ?*anyopaque, _: Snapshot) MenuError!void {
        return error.Unavailable;
    }
    fn unavailableWindow(_: ?*anyopaque, _: ?[]const u8, _: Snapshot) MenuError!void {
        return error.Unavailable;
    }
    fn unavailablePopup(_: ?*anyopaque, _: ?[]const u8, _: Snapshot, _: ?Position) MenuError!void {
        return error.Unavailable;
    }
};

// ============================================================================
// Mock backend — records every snapshot so all 3 OS run the same assertions
// ============================================================================

pub const Mock = struct {
    allocator: Allocator,
    app_menu: ?[]Entry = null,
    window_menus: std.StringHashMapUnmanaged([]Entry) = .empty,
    popups: std.ArrayListUnmanaged(Popup) = .empty,
    apply_count: usize = 0,

    pub const Popup = struct {
        window: ?[]const u8,
        at: ?Position,
        entries: []Entry,
    };

    pub fn init(allocator: Allocator) Mock {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Mock) void {
        if (self.app_menu) |entries| freeEntries(self.allocator, entries);
        var it = self.window_menus.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeEntries(self.allocator, entry.value_ptr.*);
        }
        self.window_menus.deinit(self.allocator);
        for (self.popups.items) |record| {
            if (record.window) |w| self.allocator.free(w);
            freeEntries(self.allocator, record.entries);
        }
        self.popups.deinit(self.allocator);
    }

    pub fn backend(self: *Mock) Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Backend.VTable{
        .apply_app_menu = applyApp,
        .apply_window_menu = applyWindow,
        .popup = popup,
    };

    fn applyApp(ctx: ?*anyopaque, snapshot: Snapshot) MenuError!void {
        const self: *Mock = @ptrCast(@alignCast(ctx.?));
        if (self.app_menu) |old| freeEntries(self.allocator, old);
        self.app_menu = try cloneEntries(self.allocator, snapshot.entries);
        self.apply_count += 1;
    }

    fn applyWindow(ctx: ?*anyopaque, window: ?[]const u8, snapshot: Snapshot) MenuError!void {
        const self: *Mock = @ptrCast(@alignCast(ctx.?));
        const key = if (window) |w| try self.allocator.dupe(u8, w) else try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(key);
        const entries = try cloneEntries(self.allocator, snapshot.entries);
        if (try self.window_menus.fetchPut(self.allocator, key, entries)) |old| {
            self.allocator.free(old.key);
            freeEntries(self.allocator, old.value);
        }
        self.apply_count += 1;
    }

    fn popup(ctx: ?*anyopaque, window: ?[]const u8, snapshot: Snapshot, at: ?Position) MenuError!void {
        const self: *Mock = @ptrCast(@alignCast(ctx.?));
        try self.popups.append(self.allocator, .{
            .window = if (window) |w| try self.allocator.dupe(u8, w) else null,
            .at = at,
            .entries = try cloneEntries(self.allocator, snapshot.entries),
        });
        self.apply_count += 1;
    }

    fn cloneEntries(allocator: Allocator, entries: []const Entry) Allocator.Error![]Entry {
        const out = try allocator.alloc(Entry, entries.len);
        errdefer allocator.free(out);
        for (entries, 0..) |entry, i| {
            out[i] = entry;
            out[i].id = try allocator.dupe(u8, entry.id);
            out[i].text = try allocator.dupe(u8, entry.text);
        }
        return out;
    }

    fn freeEntries(allocator: Allocator, entries: []Entry) void {
        for (entries) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.text);
        }
        allocator.free(entries);
    }

    /// Simulates the user picking `id` in the native menu (native backends do the same).
    pub fn activate(self: *Mock, state: *MenuState, scratch: Allocator, id: []const u8) void {
        _ = self;
        state.activate(scratch, id);
    }
};

// ============================================================================
// RPC commands
// ============================================================================

/// `plugin:menu|*` command namespace (`Schema` key: `.menu`).
pub const Commands = struct {
    pub const rpc_prefix = "plugin:menu|";
    pub const RpcState = MenuState;

    const Created = struct { u53, []const u8, ItemKind };

    fn callCtx(ctx: *rpc.Ctx) ?core.CallContext {
        const ptr = ctx.getEnv(core.CallContext) orelse return null;
        return ptr.*;
    }

    fn nodeOf(state: *MenuState, rid: u53, kind: ItemKind) MenuError!*Node {
        return state.lookup(rid, kind) orelse error.BadResourceId;
    }

    /// `Menu.new` / `Submenu.new` / `MenuItem.new` / … — returns `[rid, id]`.
    pub fn new(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        kind: ItemKind,
        options: ?Options = null,
        handler: ?Channel([]const u8) = null,
    }) MenuError!struct { u53, []const u8 } {
        var options = args.options orelse Options{};
        if (args.handler) |h| options.handler = options.handler orelse h.callback_id;

        const node = try state.createNode(ctx.scratch, args.kind, options, callCtx(ctx));
        return .{ node.rid, node.id };
    }

    /// `create_default()` — macOS-style app menu (About / Quit …) as a tree we own.
    pub fn create_default(ctx: *rpc.Ctx, state: *MenuState) MenuError!struct { u53, []const u8 } {
        const root = try state.createNode(ctx.scratch, .Menu, .{ .id = "__default__" }, callCtx(ctx));

        const defaults = [_]Predefined{ .{ .Quit = {} }, .{ .About = null }, .{ .CloseWindow = {} } };
        for (defaults) |pre| {
            const child = try state.createNode(ctx.scratch, .Predefined, .{ .item = pre }, callCtx(ctx));
            child.parent = root;
            try root.children.append(state.allocator, child);
        }
        return .{ root.rid, root.id };
    }

    pub fn append(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        items: []const Spec,
    }) MenuError!void {
        return insertMany(ctx, state, args.rid, args.kind, args.items, null);
    }

    pub fn prepend(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        items: []const Spec,
    }) MenuError!void {
        return insertMany(ctx, state, args.rid, args.kind, args.items, 0);
    }

    pub fn insert(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        items: []const Spec,
        position: u53,
    }) MenuError!void {
        return insertMany(ctx, state, args.rid, args.kind, args.items, @intCast(args.position));
    }

    fn insertMany(
        ctx: *rpc.Ctx,
        state: *MenuState,
        rid: u53,
        kind: ItemKind,
        specs: []const Spec,
        start: ?usize,
    ) MenuError!void {
        const parent = try nodeOf(state, rid, kind);
        if (!parent.kind.isContainer()) return error.UnexpectedMenuKind;

        var at = start orelse parent.children.items.len;
        if (at > parent.children.items.len) return error.NotFound;
        for (specs) |spec| {
            const child = try state.createChild(ctx.scratch, spec, callCtx(ctx));
            if (child.parent != null) return error.UnexpectedMenuKind;
            child.parent = parent;
            parent.children.insert(state.allocator, at, child) catch return error.OutOfMemory;
            at += 1;
        }
        try state.refresh(ctx.scratch);
    }

    pub fn remove(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        item: struct { u53, ItemKind },
    }) MenuError!void {
        const parent = try nodeOf(state, args.rid, args.kind);
        if (!parent.kind.isContainer()) return error.UnexpectedMenuKind;
        const target = state.lookup(args.item[0], args.item[1]) orelse return error.BadResourceId;
        for (parent.children.items, 0..) |child, i| {
            if (child == target) {
                _ = parent.children.orderedRemove(i);
                target.parent = null;
                return state.refresh(ctx.scratch);
            }
        }
        return error.NotFound;
    }

    pub fn remove_at(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        position: u53,
    }) MenuError!?Created {
        const parent = try nodeOf(state, args.rid, args.kind);
        if (!parent.kind.isContainer()) return error.UnexpectedMenuKind;
        const at: usize = @intCast(args.position);
        if (at >= parent.children.items.len) return null;
        const child = parent.children.orderedRemove(at);
        child.parent = null;
        try state.refresh(ctx.scratch);
        return .{ child.rid, child.id, child.kind };
    }

    pub fn items(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
    }) MenuError![]const Created {
        const parent = try nodeOf(state, args.rid, args.kind);
        if (!parent.kind.isContainer()) return error.UnexpectedMenuKind;
        const out = ctx.scratch.alloc(Created, parent.children.items.len) catch return error.OutOfMemory;
        for (parent.children.items, 0..) |child, i| out[i] = .{ child.rid, child.id, child.kind };
        return out;
    }

    pub fn get(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        id: []const u8,
    }) MenuError!?Created {
        _ = ctx;
        const parent = try nodeOf(state, args.rid, args.kind);
        if (!parent.kind.isContainer()) return error.UnexpectedMenuKind;
        for (parent.children.items) |child| {
            if (std.mem.eql(u8, child.id, args.id)) return .{ child.rid, child.id, child.kind };
        }
        return null;
    }

    pub fn popup(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        window: ?[]const u8 = null,
        at: JsonArg = .{},
    }) MenuError!void {
        const node = try nodeOf(state, args.rid, args.kind);
        const at = if (args.at.value) |value| Position.fromJsonValue(value) else null;
        const entries = try state.snapshotOf(ctx.scratch, node);
        return state.backend.popup(args.window, .{ .entries = entries }, at);
    }

    pub fn set_as_app_menu(ctx: *rpc.Ctx, state: *MenuState, args: struct { rid: u53 }) MenuError!?struct { u53, []const u8 } {
        const node = state.lookup(args.rid, .Menu) orelse return error.BadResourceId;
        state.app_menu = node;
        try state.backend.applyAppMenu(.{ .entries = try state.snapshotOf(ctx.scratch, node) });
        return .{ args.rid, node.id };
    }

    pub fn set_as_window_menu(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        window: ?[]const u8 = null,
    }) MenuError!?struct { u53, []const u8 } {
        const node = state.lookup(args.rid, .Menu) orelse return error.BadResourceId;
        const label = args.window orelse "";
        const key = state.allocator.dupe(u8, label) catch return error.OutOfMemory;
        errdefer state.allocator.free(key);
        if (try state.window_menus.fetchPut(state.allocator, key, node)) |old| state.allocator.free(old.key);
        try state.backend.applyWindowMenu(args.window, .{ .entries = try state.snapshotOf(ctx.scratch, node) });
        return .{ args.rid, node.id };
    }

    pub fn text(ctx: *rpc.Ctx, state: *MenuState, args: struct { rid: u53, kind: ItemKind }) MenuError![]const u8 {
        _ = ctx;
        return (try nodeOf(state, args.rid, args.kind)).text;
    }

    pub fn set_text(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        text: []const u8,
    }) MenuError!void {
        const node = try nodeOf(state, args.rid, args.kind);
        node.text = node.adopt(args.text) catch return error.OutOfMemory;
        try state.refresh(ctx.scratch);
    }

    pub fn is_enabled(ctx: *rpc.Ctx, state: *MenuState, args: struct { rid: u53, kind: ItemKind }) MenuError!bool {
        _ = ctx;
        return (try nodeOf(state, args.rid, args.kind)).enabled;
    }

    pub fn set_enabled(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        enabled: bool,
    }) MenuError!void {
        const node = try nodeOf(state, args.rid, args.kind);
        node.enabled = args.enabled;
        try state.refresh(ctx.scratch);
    }

    pub fn set_accelerator(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        accelerator: ?[]const u8 = null,
    }) MenuError!void {
        const node = try nodeOf(state, args.rid, args.kind);
        node.accelerator = if (args.accelerator) |raw| (Accelerator.parse(raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAccelerator => return error.InvalidAccelerator,
        }) else null;
        try state.refresh(ctx.scratch);
    }

    /// macOS-only upstream; a documented no-op everywhere else (returns success like upstream does).
    pub fn set_as_windows_menu_for_nsapp(ctx: *rpc.Ctx, state: *MenuState, args: struct { rid: u53 }) MenuError!void {
        _ = ctx;
        _ = state;
        _ = args;
    }

    pub fn set_as_help_menu_for_nsapp(ctx: *rpc.Ctx, state: *MenuState, args: struct { rid: u53 }) MenuError!void {
        _ = ctx;
        _ = state;
        _ = args;
    }

    pub fn is_checked(ctx: *rpc.Ctx, state: *MenuState, args: struct { rid: u53 }) MenuError!bool {
        _ = ctx;
        const node = state.resources.getPtr(Node, args.rid) catch return error.BadResourceId;
        if (node.state != state) return error.BadResourceId;
        return node.checked;
    }

    pub fn set_checked(ctx: *rpc.Ctx, state: *MenuState, args: struct { rid: u53, checked: bool }) MenuError!void {
        const node = state.resources.getPtr(Node, args.rid) catch return error.BadResourceId;
        if (node.state != state) return error.BadResourceId;
        node.checked = args.checked;
        try state.refresh(ctx.scratch);
    }

    pub fn set_icon(ctx: *rpc.Ctx, state: *MenuState, args: struct {
        rid: u53,
        kind: ItemKind,
        icon: JsonArg = .{},
    }) MenuError!void {
        const node = try nodeOf(state, args.rid, args.kind);
        node.icon = if (args.icon.value) |value| Icon.fromValue(value) else null;
        try state.refresh(ctx.scratch);
    }
};

// ============================================================================
// JSON helpers (shared with the wire-decoding hooks above)
// ============================================================================

fn parseValue(allocator: Allocator, raw: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{});
}

fn toDecodeError(err: anytype) rpc.DecodeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnexpectedToken,
    };
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn asBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn asU53(value: std.json.Value) ?u53 {
    return switch (value) {
        .integer => |n| if (n < 0) null else @intCast(n),
        .float => |f| if (f < 0) null else @intFromFloat(f),
        else => null,
    };
}

fn asF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn asItemKind(value: std.json.Value) ?ItemKind {
    const raw = asString(value) orelse return null;
    inline for (@typeInfo(ItemKind).@"enum".field_names, 0..) |field_name, index| {
        if (std.mem.eql(u8, raw, field_name)) return @fromBackingInt(@intCast(index));
    }
    return null;
}

// ============================================================================
// Tests — the wire layer is validated identically on Linux / macOS / Windows
// ============================================================================

const TestSchema = rpc.Schema(.{ .menu = Commands, .resources = @import("../resources.zig").Commands });

const Fixture = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    resources: ResourceTable,
    mock: Mock,
    state: MenuState,
    host: core.RecordingHost,
    window: core.WindowId,

    /// `[rid, id]` as returned by `plugin:menu|new`.
    const Created = struct { rid: u53, id: []const u8 };

    fn create() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.allocator = testing.allocator;
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.resources = ResourceTable.init(testing.allocator, testing.io);
        self.mock = Mock.init(testing.allocator);
        self.state = MenuState.init(testing.allocator, testing.io, &self.resources).withBackend(self.mock.backend());
        self.host = core.RecordingHost.init(testing.allocator);
        self.window = try self.host.host().createWindow(.{ .title = "menu" });
        return self;
    }

    fn destroy(self: *Fixture) void {
        // Nodes live in the resource table, so the table must be released first.
        self.resources.deinit();
        self.state.deinit();
        self.mock.deinit();
        self.host.deinit();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    const Response = struct {
        resp: core.OutgoingResponse,

        fn deinit(self: *Response) void {
            self.resp.deinit();
        }
        fn body(self: *const Response) []const u8 {
            return self.resp.body.slice();
        }
        fn expectOk(self: *const Response) !void {
            if (self.resp.status != .ok) std.debug.print("\n[menu] {d} {s}\n", .{ self.resp.http_code, self.body() });
            try testing.expectEqual(core.IpcStatus.ok, self.resp.status);
        }
    };

    fn invoke(self: *Fixture, command: []const u8, payload: []const u8) !Response {
        _ = self.arena.reset(.retain_capacity);
        var router = TestSchema.bind(.{ .menu = &self.state, .resources = &self.resources });
        var handler = router.handler();
        var call_ctx = core.CallContext{ .host = self.host.host(), .window_id = self.window };
        var ctx = rpc.Ctx.init(testing.io, self.arena.allocator()).withEnv(&call_ctx);
        return .{ .resp = handler.dispatch(testing.allocator, &ctx, command, payload) };
    }

    /// Invokes and copies the body into `testing.allocator` (caller frees).
    fn invokeOk(self: *Fixture, command: []const u8, payload: []const u8) ![]u8 {
        var r = try self.invoke(command, payload);
        defer r.deinit();
        try r.expectOk();
        return testing.allocator.dupe(u8, r.body());
    }

    /// `plugin:menu|new` + parse the returned `[rid, id]` (the id is copied into `testing.allocator`).
    fn create_(self: *Fixture, payload: []const u8) !Created {
        const body = try self.invokeOk("plugin:menu|new", payload);
        defer testing.allocator.free(body);
        var parsed = try std.json.parseFromSlice([2]std.json.Value, testing.allocator, body, .{});
        defer parsed.deinit();
        const id = try testing.allocator.dupe(u8, parsed.value[1].string);
        return .{ .rid = @intCast(parsed.value[0].integer), .id = id };
    }

    fn ok(self: *Fixture, command: []const u8, payload: []const u8) !void {
        var r = try self.invoke(command, payload);
        defer r.deinit();
        try r.expectOk();
    }
};

fn json(comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, fmt, args);
}

test "plugin:menu|new flattens nested submenus in pre-order with depth and accelerator" {
    var f = try Fixture.create();
    defer f.destroy();

    const created = try f.create_(
        \\{"kind":"Menu","options":{"items":[
        \\  {"text":"File","items":[
        \\    {"text":"Quit","accelerator":"CmdOrCtrl+Q","id":"quit"},
        \\    {"item":"Separator"}
        \\  ]},
        \\  {"text":"Edit","items":[{"text":"Copy","item":"Copy"}]}
        \\]}}
    );
    defer testing.allocator.free(created.id);
    try testing.expect(created.rid > 0);

    const set_as = try json("{{\"rid\":{d}}}", .{created.rid});
    defer testing.allocator.free(set_as);
    try f.ok("plugin:menu|set_as_app_menu", set_as);

    const entries = f.mock.app_menu.?;
    try testing.expectEqual(@as(usize, 5), entries.len);
    try testing.expectEqual(EntryKind.submenu, entries[0].kind);
    try testing.expectEqualStrings("File", entries[0].text);
    try testing.expectEqual(@as(u16, 0), entries[0].depth);
    try testing.expectEqualStrings("Quit", entries[1].text);
    try testing.expectEqual(@as(u16, 1), entries[1].depth);
    try testing.expectEqual(EntryKind.separator, entries[2].kind);
    try testing.expectEqualStrings("", entries[2].text);
    try testing.expectEqual(EntryKind.submenu, entries[3].kind);
    try testing.expectEqualStrings("Copy", entries[4].text);
    try testing.expectEqual(@as(u16, 1), entries[4].depth);

    const acc = entries[1].accelerator.?;
    try testing.expect(acc.mods.cmd_or_ctrl);
    try testing.expectEqual(@as(u8, 'Q'), acc.key.char);

    // `muda` ids: user-supplied ones verbatim, otherwise `"1"`, `"2"`, …
    try testing.expectEqualStrings("quit", entries[1].id);
    try testing.expectEqualStrings("2", entries[0].id);
}

test "plugin:menu|append accepts [rid, kind] tuples and re-pushes every attached menu" {
    var f = try Fixture.create();
    defer f.destroy();

    const root = try f.create_("{\"kind\":\"Menu\"}");
    defer testing.allocator.free(root.id);
    const open = try f.create_("{\"kind\":\"MenuItem\",\"options\":{\"text\":\"Open\"}}");
    defer testing.allocator.free(open.id);
    const more = try f.create_("{\"kind\":\"Submenu\",\"options\":{\"text\":\"More\"}}");
    defer testing.allocator.free(more.id);

    const append_open = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"items\":[[{d},\"MenuItem\"]]}}", .{ root.rid, open.rid });
    defer testing.allocator.free(append_open);
    try f.ok("plugin:menu|append", append_open);

    const append_nested = try json("{{\"rid\":{d},\"kind\":\"Submenu\",\"items\":[{{\"text\":\"Nested\"}}]}}", .{more.rid});
    defer testing.allocator.free(append_nested);
    try f.ok("plugin:menu|append", append_nested);

    const append_more = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"items\":[[{d},\"Submenu\"]]}}", .{ root.rid, more.rid });
    defer testing.allocator.free(append_more);
    try f.ok("plugin:menu|append", append_more);

    const set_as = try json("{{\"rid\":{d}}}", .{root.rid});
    defer testing.allocator.free(set_as);
    try f.ok("plugin:menu|set_as_app_menu", set_as);

    const entries = f.mock.app_menu.?;
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("Open", entries[0].text);
    try testing.expectEqual(EntryKind.submenu, entries[1].kind);
    try testing.expectEqualStrings("More", entries[1].text);
    try testing.expectEqualStrings("Nested", entries[2].text);
    try testing.expectEqual(@as(u16, 1), entries[2].depth);

    // Any later mutation rebuilds the snapshot (declarative backends re-render it).
    const before = f.mock.apply_count;
    const set_text = try json("{{\"rid\":{d},\"kind\":\"MenuItem\",\"text\":\"Open…\"}}", .{open.rid});
    defer testing.allocator.free(set_text);
    try f.ok("plugin:menu|set_text", set_text);
    try testing.expect(f.mock.apply_count > before);
    try testing.expectEqualStrings("Open…", f.mock.app_menu.?[0].text);
}

test "plugin:menu|items, get, remove_at and remove round-trip [rid, id, kind] triples" {
    var f = try Fixture.create();
    defer f.destroy();

    const root = try f.create_("{\"kind\":\"Menu\"}");
    defer testing.allocator.free(root.id);
    const add = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"items\":[{{\"text\":\"A\",\"id\":\"a\"}},{{\"text\":\"B\",\"id\":\"b\"}}]}}", .{root.rid});
    defer testing.allocator.free(add);
    try f.ok("plugin:menu|append", add);

    const list = try json("{{\"rid\":{d},\"kind\":\"Menu\"}}", .{root.rid});
    defer testing.allocator.free(list);
    const by_id = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"id\":\"b\"}}", .{root.rid});
    defer testing.allocator.free(by_id);
    const missing = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"id\":\"missing\"}}", .{root.rid});
    defer testing.allocator.free(missing);

    const items_body = try f.invokeOk("plugin:menu|items", list);
    defer testing.allocator.free(items_body);
    // `[[rid, "a", "MenuItem"], [rid, "b", "MenuItem"]]` — rids come from a generational pool.
    var parsed_items = try std.json.parseFromSlice([]const [3]std.json.Value, testing.allocator, items_body, .{});
    defer parsed_items.deinit();
    try testing.expectEqual(@as(usize, 2), parsed_items.value.len);
    try testing.expectEqualStrings("a", parsed_items.value[0][1].string);
    try testing.expectEqualStrings("MenuItem", parsed_items.value[0][2].string);
    try testing.expectEqualStrings("b", parsed_items.value[1][1].string);
    const a_rid: u53 = @intCast(parsed_items.value[0][0].integer);
    const b_rid: u53 = @intCast(parsed_items.value[1][0].integer);

    const get_body = try f.invokeOk("plugin:menu|get", by_id);
    defer testing.allocator.free(get_body);
    try testing.expect(std.mem.indexOf(u8, get_body, "\"b\",\"MenuItem\"") != null);

    const missing_body = try f.invokeOk("plugin:menu|get", missing);
    defer testing.allocator.free(missing_body);
    try testing.expectEqualStrings("null", missing_body);

    const remove_at = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"position\":0}}", .{root.rid});
    defer testing.allocator.free(remove_at);
    const removed_body = try f.invokeOk("plugin:menu|remove_at", remove_at);
    defer testing.allocator.free(removed_body);
    var parsed_removed = try std.json.parseFromSlice([3]std.json.Value, testing.allocator, removed_body, .{});
    defer parsed_removed.deinit();
    try testing.expectEqual(a_rid, @as(u53, @intCast(parsed_removed.value[0].integer)));

    const remove = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"item\":[{d},\"MenuItem\"]}}", .{ root.rid, b_rid });
    defer testing.allocator.free(remove);
    try f.ok("plugin:menu|remove", remove);

    const empty = try f.invokeOk("plugin:menu|items", list);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("[]", empty);
}

test "plugin:menu rejects unknown rids, mismatched kinds and invalid input" {
    var f = try Fixture.create();
    defer f.destroy();

    const item = try f.create_("{\"kind\":\"MenuItem\",\"options\":{\"text\":\"x\"}}");
    defer testing.allocator.free(item.id);

    const wrong_kind = try json("{{\"rid\":{d},\"kind\":\"Menu\"}}", .{item.rid});
    defer testing.allocator.free(wrong_kind);
    const bad_accel = try json("{{\"rid\":{d},\"kind\":\"MenuItem\",\"accelerator\":\"Nope+K\"}}", .{item.rid});
    defer testing.allocator.free(bad_accel);

    const cases = [_][2][]const u8{
        .{ "plugin:menu|text", "{\"rid\":999999,\"kind\":\"MenuItem\"}" },
        .{ "plugin:menu|text", wrong_kind },
        .{ "plugin:menu|is_checked", "{\"rid\":999999}" },
        .{ "plugin:menu|new", "{\"kind\":\"Predefined\"}" },
        .{ "plugin:menu|set_accelerator", bad_accel },
        .{ "plugin:menu|new", "{\"kind\":\"Nope\"}" },
        .{ "plugin:menu|append", "{\"rid\":999999,\"kind\":\"Menu\",\"items\":[]}" },
    };
    for (cases) |case| {
        var r = try f.invoke(case[0], case[1]);
        defer r.deinit();
        try testing.expectEqual(core.IpcStatus.err, r.resp.status);
    }

    // `plugin:resources|close` detaches the node so the parent no longer lists it.
    const root = try f.create_("{\"kind\":\"Menu\"}");
    defer testing.allocator.free(root.id);
    const add = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"items\":[{{\"text\":\"gone\",\"id\":\"gone\"}}]}}", .{root.rid});
    defer testing.allocator.free(add);
    try f.ok("plugin:menu|append", add);

    const list = try json("{{\"rid\":{d},\"kind\":\"Menu\"}}", .{root.rid});
    defer testing.allocator.free(list);
    const listed = try f.invokeOk("plugin:menu|items", list);
    defer testing.allocator.free(listed);
    var parsed = try std.json.parseFromSlice([]const [3]std.json.Value, testing.allocator, listed, .{});
    defer parsed.deinit();
    const child_rid: u53 = @intCast(parsed.value[0][0].integer);

    const close = try json("{{\"rid\":{d}}}", .{child_rid});
    defer testing.allocator.free(close);
    try f.ok("plugin:resources|close", close);

    const after = try f.invokeOk("plugin:menu|items", list);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("[]", after);
}

test "plugin:menu activation is delivered through Channel<string>, popup records window and position" {
    var f = try Fixture.create();
    defer f.destroy();

    const item = try f.create_("{\"kind\":\"MenuItem\",\"options\":{\"text\":\"Reset\",\"id\":\"reset\"},\"handler\":\"__CHANNEL__:4242\"}");
    defer testing.allocator.free(item.id);

    const root = try f.create_("{\"kind\":\"Menu\"}");
    defer testing.allocator.free(root.id);
    const add = try json("{{\"rid\":{d},\"kind\":\"Menu\",\"items\":[[{d},\"MenuItem\"]]}}", .{ root.rid, item.rid });
    defer testing.allocator.free(add);
    try f.ok("plugin:menu|append", add);

    const set_as = try json("{{\"rid\":{d}}}", .{root.rid});
    defer testing.allocator.free(set_as);
    try f.ok("plugin:menu|set_as_app_menu", set_as);

    // A native backend reports an activation; the channel receives the `MenuId` string.
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    f.mock.activate(&f.state, scratch.allocator(), "reset");
    try testing.expectEqual(@as(usize, 1), f.host.eval_log.items.len);
    try testing.expectEqualStrings(
        "window.__TAURI_INTERNALS__.runCallback(4242,{\"index\":0,\"message\":\"reset\"});",
        f.host.eval_log.items[0],
    );

    const popup_payload = try json(
        "{{\"rid\":{d},\"kind\":\"Menu\",\"window\":\"main\",\"at\":{{\"Logical\":{{\"x\":12.5,\"y\":-3}}}}}}",
        .{root.rid},
    );
    defer testing.allocator.free(popup_payload);
    try f.ok("plugin:menu|popup", popup_payload);

    const popup_call = f.mock.popups.items[0];
    try testing.expectEqualStrings("main", popup_call.window.?);
    try testing.expectEqual(@as(f64, 12.5), popup_call.at.?.x);
    try testing.expectEqual(@as(f64, -3), popup_call.at.?.y);
    try testing.expect(popup_call.at.?.logical);
}

test "menu stub backend fails closed when no native toolkit is compiled in" {
    var resources = ResourceTable.init(testing.allocator, testing.io);
    defer resources.deinit();
    var state = MenuState.init(testing.allocator, testing.io, &resources);
    defer state.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = try arena.allocator().alloc(Entry, 0);
    try testing.expectError(error.Unavailable, state.backend.applyAppMenu(.{ .entries = entries }));
    try testing.expectError(error.Unavailable, state.backend.popup(null, .{ .entries = entries }, null));
}
