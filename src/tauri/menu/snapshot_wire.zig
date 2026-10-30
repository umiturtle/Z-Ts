//! The one piece of native-menu work that is **not** OS specific: turning a flattened
//! [`Snapshot`] into what the Cocoa / Win32 backends hand to the toolkit.
//!
//! Everything here is Pure Zig and therefore unit-tested on Linux, macOS and Windows alike
//! (the same split `src/webview/windows_util.zig` and `src/tauri/native_win32.zig` use): the
//! depth validation, the mnemonic encoding, the macOS `keyEquivalent` table and the Win32
//! command-id allocation are all pure functions. The backends themselves only loop over the
//! produced entries and call `AppendMenuW` / `NSMenu.addItem`.
//!
//! ## Mnemonics
//!
//! The core's labels use GTK's marker: `_F` marks `F` as the mnemonic and `__` is a literal
//! underscore (this is what `M4-03`'s GTK backend feeds `gtk_menu_item_new_with_mnemonic`).
//! Upstream `muda` instead stores `&` in shared state; Z-Ts converts per backend, which keeps
//! the existing GTK behaviour (and its tests) intact:
//!
//! | platform | `_File` | `__x` | `Fish & Chips` |
//! |---|---|---|---|
//! | GTK | `_File` | `__x` | `Fish & Chips` |
//! | macOS | `File` | `_x` | `Fish & Chips` |
//! | Win32 | `&File` | `_x` | `Fish && Chips` |
//!
//! ## Accelerators
//!
//! macOS carries the shortcut on the `NSMenuItem` itself (`keyEquivalent` +
//! `keyEquivalentModifierMask`), so it both renders and **works** without extra plumbing.
//! Win32 has no per-item shortcut slot: the accelerator is rendered as the right-aligned
//! `\t`-suffix (what MSDN calls the "accelerator text") and actual key dispatch stays with the
//! host's message loop (`TranslateAcceleratorW`), which is a follow-up (documented in
//! `docs/architecture/tauri-menu-tray.md`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const menu = @import("mod.zig");
const accelerator = @import("accelerator.zig");

const Error = menu.MenuError;

/// Nesting limit shared with the GTK backend (an 8-level menu is already absurd).
pub const max_depth = 8;

/// Highest command id handed to Win32. `0` means "no command" and `WM_COMMAND` only carries a
/// 16-bit id, so the useful range is `1..0xEFFF` (the top of the word is reserved by the system).
pub const max_command = 0xEFFF;

/// Which native encoding `encode()` should produce. The snapshot itself is platform-neutral; only
/// mnemonics (`_` vs `&`) and the accelerator representation differ.
pub const Platform = enum { gtk, macos, windows };

/// Entry discriminant in the C ABI struct (`ZtsMenuEntry.kind`). Values are fixed by the shims.
pub const Kind = enum(u8) {
    submenu = 0,
    item = 1,
    separator = 2,
};

/// What a predefined item maps to on AppKit. `none` = a plain item (the backend still creates it
/// so the snapshot round-trips; Win32 always renders a plain item).
pub const Role = enum(u8) {
    none = 0,
    about,
    services,
    hide,
    hide_others,
    show_all,
    close_window,
    quit,
    bring_all_to_front,
    minimize,
    maximize,
    fullscreen,
    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,

    pub fn of(predefined: ?menu.Predefined) Role {
        const p = predefined orelse return .none;
        return switch (p) {
            .Separator => .none, // a separator is a `Kind`, not a role
            .About => .about,
            .Services => .services,
            .Hide => .hide,
            .HideOthers => .hide_others,
            .ShowAll => .show_all,
            .CloseWindow => .close_window,
            .Quit => .quit,
            .BringAllToFront => .bring_all_to_front,
            .Minimize => .minimize,
            .Maximize => .maximize,
            .Fullscreen => .fullscreen,
            .Undo => .undo,
            .Redo => .redo,
            .Cut => .cut,
            .Copy => .copy,
            .Paste => .paste,
            .SelectAll => .select_all,
        };
    }
};

/// Bit flags in `WireEntry.flags`.
pub const flag_enabled: u8 = 1 << 0;
/// `WireEntry.flags` bit 1: the menu item is checked.
pub const flag_checked: u8 = 1 << 1;

/// `ZtsMenuEntry` on the C side (`src/tauri/menu/native_macos_shim.m`). Field order, padding and
/// size are asserted in the tests below so a layout change cannot silently corrupt the ABI.
pub const WireEntry = extern struct {
    kind: u8,
    role: u8,
    flags: u8,
    reserved0: u8 = 0,
    depth: u16,
    /// 1-based Win32 command id (0 for separators); macOS uses it as `NSMenuItem.tag`.
    command: u16,
    id: ?[*:0]const u8,
    text: ?[*:0]const u8,
    key_equivalent: ?[*:0]const u8,
    modifier_mask: u8,
    reserved1: [3]u8 = .{ 0, 0, 0 },
};

/// A validated snapshot, ready for a native toolkit. Owns every string it exposes.
pub const Wire = struct {
    allocator: Allocator,
    entries: []WireEntry,
    /// Every NUL-terminated allocation, freed together in `deinit`. The slice type keeps the
    /// sentinel: `Allocator.free` only releases the trailing NUL when it can see it.
    owned: []const [:0]u8,

    pub fn deinit(self: *Wire) void {
        for (self.owned) |s| self.allocator.free(s);
        self.allocator.free(self.owned);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// The `MenuId` an activation of `command` refers to (`null` = no such command).
    pub fn idForCommand(self: Wire, command: u16) ?[]const u8 {
        if (command == 0) return null;
        const index = command - 1;
        if (index >= self.entries.len) return null;
        const id = self.entries[index].id orelse return null;
        return std.mem.span(id);
    }
};

/// Converts `snapshot` for `platform`.
///
/// Fails with `error.InvalidMenuDepth` when a depth skips a level (only a `.submenu` may open
/// one) or exceeds `max_depth`, and `error.Unsupported` when the snapshot has more entries than
/// Win32 command ids.
pub fn build(allocator: Allocator, snapshot: menu.Snapshot, platform: Platform) Error!Wire {
    var owned: std.ArrayListUnmanaged([:0]u8) = .empty;
    errdefer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    const entries = allocator.alloc(WireEntry, snapshot.entries.len) catch return error.OutOfMemory;
    errdefer allocator.free(entries);

    // `open_depth` is the deepest level the next entry may sit at. It starts at 0 and is only
    // raised by a `.submenu`; a leaf resets it, which is exactly what catches a skipped level.
    var open_depth: u16 = 0;
    for (snapshot.entries, 0..) |entry, i| {
        if (entry.depth > max_depth) return error.InvalidMenuDepth;
        if (entry.depth > open_depth) return error.InvalidMenuDepth;

        const kind = switch (entry.kind) {
            .submenu => Kind.submenu,
            .separator => Kind.separator,
            .item => Kind.item,
        };
        open_depth = switch (kind) {
            .submenu => entry.depth + 1,
            else => entry.depth,
        };

        const id = try own(allocator, &owned, entry.id);
        // Labels are rewritten per platform: `_` is GTK's marker, Win32 wants `&`, AppKit none.
        const text = try adopt(allocator, &owned, labelFor(allocator, textOf(entry), platform) catch return error.OutOfMemory);
        const key_equivalent: ?[*:0]const u8 = if (platform == .macos and entry.accelerator != null and kind != .separator)
            try own(allocator, &owned, macosKeyEquivalent(entry.accelerator.?))
        else
            null;

        var flags: u8 = 0;
        if (entry.enabled) flags |= flag_enabled;
        if (entry.checked) flags |= flag_checked;

        entries[i] = .{
            .kind = @backingInt(kind),
            .role = @backingInt(Role.of(entry.predefined)),
            .flags = flags,
            .depth = entry.depth,
            // Separators never reach `WM_COMMAND`; they keep their slot so `command - 1` stays
            // a direct index into `entries`.
            .command = if (kind == .separator) 0 else try commandId(i),
            .id = id,
            .text = text,
            .key_equivalent = key_equivalent,
            .modifier_mask = if (key_equivalent != null) entry.accelerator.?.toMacos().modifier_mask else 0,
        };
    }

    return .{
        .allocator = allocator,
        .entries = entries,
        .owned = owned.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

/// 1-based `WM_COMMAND` id for entry `index`. `0` means "no command", and the top of the 16-bit
/// word is reserved by the system, so `max_command` entries is the hard ceiling.
pub fn commandId(index: usize) Error!u16 {
    if (index + 1 > max_command) return error.Unsupported;
    return @intCast(index + 1);
}

fn own(allocator: Allocator, owned: *std.ArrayListUnmanaged([:0]u8), s: []const u8) Error![:0]const u8 {
    const out = allocator.allocSentinel(u8, s.len, 0) catch return error.OutOfMemory;
    @memcpy(out, s);
    return adopt(allocator, owned, out);
}

/// Takes over an already NUL-terminated allocation (freed with the rest of the wire).
fn adopt(allocator: Allocator, owned: *std.ArrayListUnmanaged([:0]u8), s: [:0]u8) Error![:0]const u8 {
    owned.append(allocator, s) catch {
        allocator.free(s);
        return error.OutOfMemory;
    };
    return s;
}

/// The label an entry carries: its own text, else the predefined default (`Copy`, `Quit`, …).
pub fn textOf(entry: menu.Entry) []const u8 {
    if (entry.text.len > 0) return entry.text;
    if (entry.predefined) |p| return p.defaultText();
    return "";
}

// ============================================================================
// Labels / mnemonics
// ============================================================================

/// Rewrites a core label for `platform` (`_` mnemonic marker → `&` on Win32, dropped on macOS).
pub fn labelFor(allocator: Allocator, text: []const u8, platform: Platform) Allocator.Error![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (platform) {
        .gtk => try out.appendSlice(allocator, text),
        .macos => {
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] == '_' and i + 1 < text.len) {
                    if (text[i + 1] == '_') {
                        try out.append(allocator, '_');
                        i += 1;
                    }
                    // A single `_` is the mnemonic marker: AppKit has no mnemonics, so drop it.
                    continue;
                }
                try out.append(allocator, text[i]);
            }
        },
        .windows => {
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] == '_' and i + 1 < text.len) {
                    if (text[i + 1] == '_') {
                        try out.append(allocator, '_');
                        i += 1;
                    } else {
                        try out.append(allocator, '&');
                    }
                    continue;
                }
                // A literal ampersand must be doubled or Win32 would eat it as a mnemonic.
                if (text[i] == '&') {
                    try out.appendSlice(allocator, "&&");
                    continue;
                }
                try out.append(allocator, text[i]);
            }
        },
    }
    return out.toOwnedSliceSentinel(allocator, 0);
}

// ============================================================================
// macOS key equivalents
// ============================================================================

/// `NSMenuItem.keyEquivalent` for `acc` (`""` = the key has no AppKit equivalent, so the item is
/// created without a shortcut instead of failing the whole menu).
///
/// The table mirrors `muda`'s `src/accelerator/macos.rs`: letters/digits map to themselves
/// (lower-case — the modifier mask carries Shift), punctuation to its character, and everything
/// else to the Unicode private-use function-key range (`NSUpArrowFunctionKey` = `U+F700`,
/// `NSF1FunctionKey` = `U+F704`, …).
pub fn macosKeyEquivalent(acc: accelerator.Accelerator) []const u8 {
    return switch (acc.key) {
        .char => |ch| blk: {
            const lower = if (std.ascii.isUpper(ch)) std.ascii.toLower(ch) else ch;
            // `&`/`+` would need UTF-8 escaping? No: every accepted `char` is ASCII, and
            // `single(&buf)` below only reads one byte.
            break :blk single(&char_buf, lower);
        },
        .function => |n| if (n >= 1 and n <= 35) unicodeKey(0xF704 + @as(u21, n - 1)) else "",
        .numpad => |n| if (n <= 9) single(&char_buf, '0' + n) else "",
        .named => |named| switch (named) {
            .backspace => "\x08",
            .enter => "\r",
            .space => " ",
            .tab => "\t",
            .delete => "\x7f",
            .escape => "\x1b",
            .end => unicodeKey(0xF72B),
            .home => unicodeKey(0xF729),
            .insert => unicodeKey(0xF727),
            .page_down => unicodeKey(0xF72D),
            .page_up => unicodeKey(0xF72C),
            .print_screen => unicodeKey(0xF72E),
            .scroll_lock => unicodeKey(0xF72F),
            .arrow_up => unicodeKey(0xF700),
            .arrow_down => unicodeKey(0xF701),
            .arrow_left => unicodeKey(0xF702),
            .arrow_right => unicodeKey(0xF703),
            .numpad_add => "+",
            .numpad_subtract => "-",
            .numpad_multiply => "*",
            .numpad_divide => "/",
            .numpad_decimal => ".",
            .numpad_enter => "\x03",
            .numpad_equal => "=",
            // No AppKit key equivalent: the shortcut is not rendered (never a wrong one).
            .caps_lock, .num_lock, .audio_volume_up, .audio_volume_down, .audio_volume_mute => "",
        },
    };
}

/// Scratch space for the single-byte results above. `macosKeyEquivalent` returns a slice into
/// this buffer, so callers must use it before calling again (the wire copies it immediately).
var char_buf: [1]u8 = undefined;

fn single(buf: *[1]u8, ch: u8) []const u8 {
    buf[0] = ch;
    return buf[0..1];
}

/// UTF-8 encoding of a Cocoa private-use function-key code point (`U+F700..U+F8FF`).
fn unicodeKey(codepoint: u21) []const u8 {
    const n: usize = std.unicode.utf8Encode(codepoint, &func_buf) catch return "";
    return func_buf[0..n];
}

var func_buf: [4]u8 = undefined;

// ============================================================================
// Win32 accelerator text
// ============================================================================

/// The `\t`-suffix Win32 draws on the right of a menu item (`"Ctrl+Shift+S"`).
///
/// Windows has no per-item shortcut slot; the text is presentation only. `CmdOrCtrl` resolves to
/// Control and `Meta` (the Windows key) is dropped, like `Accelerator.toWin32`.
pub fn acceleratorText(allocator: Allocator, acc: accelerator.Accelerator) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    const mods = acc.mods;
    if (mods.cmd_or_ctrl or mods.ctrl) w.writeAll("Ctrl+") catch return error.OutOfMemory;
    if (mods.alt) w.writeAll("Alt+") catch return error.OutOfMemory;
    if (mods.shift) w.writeAll("Shift+") catch return error.OutOfMemory;
    w.writeAll(keyName(acc.key)) catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

/// `F1`..`F24` / `Num0`..`Num9` are built at compile time so formatting never allocates.
const function_names: [24][]const u8 = blk: {
    var names: [24][]const u8 = undefined;
    for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("F{d}", .{i + 1});
    break :blk names;
};

const numpad_names: [10][]const u8 = blk: {
    var names: [10][]const u8 = undefined;
    for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("Num{d}", .{i});
    break :blk names;
};

fn keyName(key: accelerator.Key) []const u8 {
    return switch (key) {
        .char => |ch| blk: {
            break :blk single(&char_buf, if (std.ascii.isUpper(ch)) ch else std.ascii.toUpper(ch));
        },
        .function => |n| if (n >= 1 and n <= function_names.len) function_names[n - 1] else "",
        .numpad => |n| if (n <= 9) numpad_names[n] else "",
        .named => |named| switch (named) {
            .backspace => "Backspace",
            .caps_lock => "CapsLock",
            .enter, .numpad_enter => "Enter",
            .space => "Space",
            .tab => "Tab",
            .delete => "Del",
            .end => "End",
            .home => "Home",
            .insert => "Ins",
            .page_down => "PgDn",
            .page_up => "PgUp",
            .print_screen => "PrtSc",
            .scroll_lock => "ScrollLock",
            .num_lock => "NumLock",
            .escape => "Esc",
            .arrow_up => "Up",
            .arrow_down => "Down",
            .arrow_left => "Left",
            .arrow_right => "Right",
            .numpad_add => "+",
            .numpad_subtract => "-",
            .numpad_multiply => "*",
            .numpad_divide => "/",
            .numpad_decimal => ".",
            .numpad_equal => "=",
            .audio_volume_up => "VolumeUp",
            .audio_volume_down => "VolumeDown",
            .audio_volume_mute => "VolumeMute",
        },
    };
}

// ============================================================================
// Tests (pure — they run on every OS)
// ============================================================================

test "wire layout matches the C `ZtsMenuEntry`" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(WireEntry));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WireEntry, "kind"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(WireEntry, "depth"));
    try testing.expectEqual(@as(usize, 6), @offsetOf(WireEntry, "command"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(WireEntry, "id"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(WireEntry, "text"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(WireEntry, "key_equivalent"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(WireEntry, "modifier_mask"));
}

test "wire keeps the pre-order flattening, commands and mnemonics" {
    const entries = [_]menu.Entry{
        .{ .kind = .submenu, .id = "1", .text = "_File", .depth = 0 },
        .{ .kind = .item, .id = "2", .text = "_New", .depth = 1, .accelerator = accelerator.Accelerator.parse("CmdOrCtrl+N") catch unreachable },
        .{ .kind = .separator, .id = "3", .text = "", .depth = 1 },
        .{ .kind = .item, .id = "4", .text = "", .depth = 1, .enabled = false, .predefined = .Quit },
        .{ .kind = .item, .id = "5", .text = "Fish & Chips", .depth = 0 },
    };

    for ([_]Platform{ .macos, .windows, .gtk }) |platform| {
        var wire = try build(testing.allocator, .{ .entries = &entries }, platform);
        defer wire.deinit();

        try testing.expectEqual(@as(usize, 5), wire.entries.len);
        try testing.expectEqual(@as(u16, 0), wire.entries[0].depth);
        try testing.expectEqual(@as(u16, 1), wire.entries[1].depth);
        try testing.expectEqual(@backingInt(Kind.submenu), wire.entries[0].kind);
        try testing.expectEqual(@backingInt(Kind.separator), wire.entries[2].kind);

        // Round trip through the command id, which is what `WM_COMMAND` gives us back.
        try testing.expectEqualStrings("1", wire.idForCommand(1).?);
        try testing.expectEqualStrings("4", wire.idForCommand(4).?);
        try testing.expectEqual(@as(?[]const u8, null), wire.idForCommand(0));
        try testing.expectEqual(@as(?[]const u8, null), wire.idForCommand(9));

        // Separators keep their slot but are not activatable.
        try testing.expectEqual(@as(u16, 0), wire.entries[2].command);

        // A predefined item with no text falls back to its human label, and carries its role.
        try testing.expectEqualStrings("Quit", std.mem.span(wire.entries[3].text.?));
        try testing.expectEqual(@backingInt(Role.quit), wire.entries[3].role);
        try testing.expectEqual(@as(u8, 0), wire.entries[3].flags & flag_enabled);

        const label = std.mem.span(wire.entries[1].text.?);
        switch (platform) {
            .gtk => try testing.expectEqualStrings("_New", label),
            .macos => try testing.expectEqualStrings("New", label),
            .windows => try testing.expectEqualStrings("&New", label),
        }

        // macOS is the only platform that carries the shortcut on the item itself.
        if (platform == .macos) {
            try testing.expectEqualStrings("n", std.mem.span(wire.entries[1].key_equivalent.?));
            try testing.expectEqual(
                (accelerator.Accelerator.parse("CmdOrCtrl+N") catch unreachable).toMacos().modifier_mask,
                wire.entries[1].modifier_mask,
            );
        } else {
            try testing.expectEqual(@as(?[*:0]const u8, null), wire.entries[1].key_equivalent);
        }
    }
}

test "a depth that skips a level or overflows is rejected" {
    const skip = [_]menu.Entry{
        .{ .kind = .item, .id = "1", .text = "Deep", .depth = 2 },
    };
    try testing.expectError(error.InvalidMenuDepth, build(testing.allocator, .{ .entries = &skip }, .windows));

    const too_deep = [_]menu.Entry{
        .{ .kind = .item, .id = "1", .text = "Deep", .depth = max_depth + 1 },
    };
    try testing.expectError(error.InvalidMenuDepth, build(testing.allocator, .{ .entries = &too_deep }, .macos));

    // A submenu at the maximum depth cannot open a level below it, and we refuse `max_depth + 1`.
    const at_limit = [_]menu.Entry{
        .{ .kind = .submenu, .id = "1", .text = "Root", .depth = 0 },
        .{ .kind = .item, .id = "2", .text = "Leaf", .depth = 1 },
        .{ .kind = .submenu, .id = "3", .text = "Back", .depth = 0 },
        .{ .kind = .separator, .id = "4", .text = "", .depth = 1 },
    };
    var wire = try build(testing.allocator, .{ .entries = &at_limit }, .gtk);
    wire.deinit();
}

test "mnemonics: AppKit strips, Win32 converts, GTK keeps" {
    const cases = [_]struct { raw: []const u8, gtk: []const u8, macos: []const u8, windows: []const u8 }{
        .{ .raw = "_File", .gtk = "_File", .macos = "File", .windows = "&File" },
        .{ .raw = "E_xit", .gtk = "E_xit", .macos = "Exit", .windows = "E&xit" },
        .{ .raw = "__proto", .gtk = "__proto", .macos = "_proto", .windows = "_proto" },
        .{ .raw = "Fish & Chips", .gtk = "Fish & Chips", .macos = "Fish & Chips", .windows = "Fish && Chips" },
        .{ .raw = "100%", .gtk = "100%", .macos = "100%", .windows = "100%" },
        .{ .raw = "trailing_", .gtk = "trailing_", .macos = "trailing_", .windows = "trailing_" },
    };
    for (cases) |case| {
        const gtk = try labelFor(testing.allocator, case.raw, .gtk);
        defer testing.allocator.free(gtk);
        const mac = try labelFor(testing.allocator, case.raw, .macos);
        defer testing.allocator.free(mac);
        const win = try labelFor(testing.allocator, case.raw, .windows);
        defer testing.allocator.free(win);
        try testing.expectEqualStrings(case.gtk, gtk);
        try testing.expectEqualStrings(case.macos, mac);
        try testing.expectEqualStrings(case.windows, win);
    }
}

test "macOS key equivalents cover letters, punctuation, function and named keys" {
    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "CmdOrCtrl+K", .expected = "k" },
        .{ .raw = "CmdOrCtrl+Shift+K", .expected = "k" },
        .{ .raw = "CmdOrCtrl+1", .expected = "1" },
        .{ .raw = "CmdOrCtrl+Plus", .expected = "" }, // unsupported token → parse error, not a key
        .{ .raw = "F1", .expected = "\u{F704}" },
        .{ .raw = "F5", .expected = "\u{F708}" },
        .{ .raw = "F24", .expected = "\u{F71B}" },
        .{ .raw = "Up", .expected = "\u{F700}" },
        .{ .raw = "Right", .expected = "\u{F703}" },
        .{ .raw = "Home", .expected = "\u{F729}" },
        .{ .raw = "PageDown", .expected = "\u{F72D}" },
        .{ .raw = "Escape", .expected = "\x1b" },
        .{ .raw = "Numpad7", .expected = "7" },
        .{ .raw = "NumpadAdd", .expected = "+" },
    };
    for (cases) |case| {
        const acc = accelerator.Accelerator.parse(case.raw) catch {
            try testing.expectEqualStrings("", case.expected);
            continue;
        };
        try testing.expectEqualStrings(case.expected, macosKeyEquivalent(acc));
    }

    // The modifier mask carries Shift/Alt/Control/Command, and `CmdOrCtrl` means Command.
    const acc = accelerator.Accelerator.parse("CmdOrCtrl+Shift+K") catch unreachable;
    const mask = acc.toMacos().modifier_mask;
    try testing.expect(mask & accelerator.MAC_COMMAND != 0);
    try testing.expect(mask & accelerator.MAC_SHIFT != 0);
}

test "Win32 renders the accelerator as right-aligned text" {
    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "CmdOrCtrl+N", .expected = "Ctrl+N" },
        .{ .raw = "CmdOrCtrl+Shift+S", .expected = "Ctrl+Shift+S" },
        .{ .raw = "Alt+F4", .expected = "Alt+F4" },
        .{ .raw = "Ctrl+Alt+Delete", .expected = "Ctrl+Alt+Del" },
        .{ .raw = "CmdOrCtrl+Plus", .expected = "Ctrl+" }, // parses only if the key token is known
        .{ .raw = "F12", .expected = "F12" },
        .{ .raw = "Up", .expected = "Up" },
        .{ .raw = "Escape", .expected = "Esc" },
    };
    for (cases) |case| {
        const acc = accelerator.Accelerator.parse(case.raw) catch {
            try testing.expectEqualStrings("Ctrl+", case.expected);
            continue;
        };
        const text = try acceleratorText(testing.allocator, acc);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case.expected, text);
    }
}

test "command ids are 1-based and capped at the 16-bit WM_COMMAND range" {
    try testing.expectEqual(@as(u16, 1), try commandId(0));
    try testing.expectEqual(max_command, try commandId(max_command - 1));
    try testing.expectError(error.Unsupported, commandId(max_command));
}

test "wire deinit frees everything" {
    // `testing.allocator` fails the test on a leak, so this is the assertion.
    const entries = [_]menu.Entry{
        .{ .kind = .submenu, .id = "1", .text = "_File", .depth = 0 },
        .{ .kind = .item, .id = "2", .text = "_New", .depth = 1, .accelerator = accelerator.Accelerator.parse("CmdOrCtrl+N") catch unreachable },
    };
    var wire = try build(testing.allocator, .{ .entries = &entries }, .macos);
    wire.deinit();
}
