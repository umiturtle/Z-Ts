//! Menu accelerator parsing & per-OS rendering (`CmdOrCtrl+Shift+K` …).
//!
//! `@tauri-apps/api/menu` documents the accepted syntax: zero or more modifiers followed by exactly
//! one key, joined with `+`, matched case-insensitively with spaces around each token ignored:
//!
//! ```text
//! CmdOrCtrl+Shift+K      cmdorctrl + shift + k      F5      Escape      Numpad7
//! ```
//!
//! Parsing lives in `zts_tauri` (Pure Zig, `link_libc = false`) so **every OS runs the same
//! tables**; each native backend then renders the parsed form into its own toolkit vocabulary
//! ([`renderGtk`], [`toWin32`], or the macOS shim's JSON fields).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const ParseError = error{ InvalidAccelerator, OutOfMemory };

/// Modifier flags. `cmd_or_ctrl` is kept separate from `meta`/`ctrl` because it resolves to
/// **Command on macOS and Control everywhere else**, which only the backend can decide.
pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Command (macOS) / Super / Win (elsewhere).
    meta: bool = false,
    cmd_or_ctrl: bool = false,

    pub fn isEmpty(self: Mods) bool {
        return !self.shift and !self.ctrl and !self.alt and !self.meta and !self.cmd_or_ctrl;
    }

    /// Resolves `cmd_or_ctrl` for a concrete platform. `is_macos` picks Command over Control.
    pub fn resolved(self: Mods, is_macos: bool) Mods {
        if (!self.cmd_or_ctrl) return self;
        var out = self;
        out.cmd_or_ctrl = false;
        if (is_macos) out.meta = true else out.ctrl = true;
        return out;
    }
};

/// A single printable key (`'A'`..`'Z'`, `'0'`..`'9'`, punctuation), upper-cased.
pub const Key = union(enum) {
    char: u8,
    /// `F1`..`F24`.
    function: u8,
    /// `Numpad0`..`Numpad9`.
    numpad: u8,
    named: Named,

    pub const Named = enum {
        backspace,
        caps_lock,
        enter,
        space,
        tab,
        delete,
        end,
        home,
        insert,
        page_down,
        page_up,
        print_screen,
        scroll_lock,
        num_lock,
        escape,
        arrow_up,
        arrow_down,
        arrow_left,
        arrow_right,
        numpad_add,
        numpad_subtract,
        numpad_multiply,
        numpad_divide,
        numpad_decimal,
        numpad_enter,
        numpad_equal,
        audio_volume_up,
        audio_volume_down,
        audio_volume_mute,
    };
};

/// A parsed keyboard shortcut: modifiers plus one key. `Accelerator.parse("CmdOrCtrl+Shift+K")`
/// resolves `CmdOrCtrl` to Command on macOS and Control elsewhere, which is how one menu definition
/// stays native on all three platforms.
pub const Accelerator = struct {
    mods: Mods = .{},
    key: Key,

    /// Parses `CmdOrCtrl+Shift+K`. Unknown modifiers or keys are rejected (never silently ignored,
    /// so a typo in a menu definition fails the `plugin:menu|new` call instead of doing nothing).
    pub fn parse(raw: []const u8) ParseError!Accelerator {
        var mods: Mods = .{};
        const rest = std.mem.trim(u8, raw, " \t");
        if (rest.len == 0) return error.InvalidAccelerator;

        var key: ?Key = null;
        // Every token before the last must be a modifier; the last token is the key.
        var it = TokenIterator{ .rest = rest };
        var saw_key = false;
        while (it.next()) |token| {
            if (saw_key) return error.InvalidAccelerator; // a key followed by more tokens
            const first = parseModifier(token) orelse {
                key = try parseKey(token);
                saw_key = true;
                continue;
            };
            switch (first) {
                .shift => {
                    if (mods.shift) return error.InvalidAccelerator;
                    mods.shift = true;
                },
                .ctrl => {
                    if (mods.ctrl) return error.InvalidAccelerator;
                    mods.ctrl = true;
                },
                .alt => {
                    if (mods.alt) return error.InvalidAccelerator;
                    mods.alt = true;
                },
                .meta => {
                    if (mods.meta) return error.InvalidAccelerator;
                    mods.meta = true;
                },
                .cmd_or_ctrl => {
                    if (mods.cmd_or_ctrl) return error.InvalidAccelerator;
                    mods.cmd_or_ctrl = true;
                },
            }
        }
        const parsed = key orelse return error.InvalidAccelerator;
        return .{ .mods = mods, .key = parsed };
    }

    /// GTK3 accelerator string (`"<Primary><Shift>k"`). GTK understands `<Primary>` as
    /// Command on macOS and Control elsewhere, matching `CmdOrCtrl` exactly.
    pub fn renderGtk(acc: Accelerator, allocator: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        // Canonical ordering (`<Primary><Control><Alt><Shift>`) so the rendered string is stable
        // regardless of the order the caller wrote the modifiers in.
        const m = acc.mods;
        if (m.cmd_or_ctrl) aw.writer.writeAll("<Primary>") catch return error.OutOfMemory;
        if (m.ctrl) aw.writer.writeAll("<Control>") catch return error.OutOfMemory;
        if (m.meta) aw.writer.writeAll("<Meta>") catch return error.OutOfMemory;
        if (m.alt) aw.writer.writeAll("<Alt>") catch return error.OutOfMemory;
        if (m.shift) aw.writer.writeAll("<Shift>") catch return error.OutOfMemory;
        writeGtkKey(&aw.writer, acc.key) catch return error.OutOfMemory;
        return aw.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Windows `ACCEL` components: `fVirt` (`FVIRTKEY | FSHIFT | FCONTROL | FALT`) and `key`.
    /// `cmd_or_ctrl` resolves to Control, and Command has no Windows equivalent so it is dropped.
    pub fn toWin32(self: Accelerator) Win32Accel {
        const m = self.mods.resolved(false);
        var virt: u8 = FVIRTKEY;
        if (m.shift) virt |= FSHIFT;
        if (m.ctrl) virt |= FCONTROL;
        if (m.alt) virt |= FALT;
        return .{ .virt = virt, .key = win32VirtualKey(self.key) };
    }

    /// macOS rendering descriptor (`cmdKey` / `shiftKey` / `optionKey` / `controlKey` + character).
    /// The Objective-C shim turns this into `NSMenuItem.keyEquivalent` + `keyEquivalentModifierMask`.
    pub fn toMacos(self: Accelerator) MacosAccel {
        const m = self.mods.resolved(true);
        var mask: u8 = 0;
        if (m.shift) mask |= MAC_SHIFT;
        if (m.ctrl) mask |= MAC_CONTROL;
        if (m.alt) mask |= MAC_OPTION;
        if (m.meta) mask |= MAC_COMMAND;
        return .{ .modifier_mask = mask, .key_equivalent = macosKeyEquivalent(self.key) };
    }
};

pub const FVIRTKEY: u8 = 0x01;
pub const FSHIFT: u8 = 0x04;
pub const FCONTROL: u8 = 0x08;
pub const FALT: u8 = 0x10;

/// `ACCEL` entry for `CreateAcceleratorTableW`: `virt` holds the `fVirt` flags, `key` the virtual-key
/// code (or `0` to use `ascii`).
pub const Win32Accel = struct {
    virt: u8,
    /// `wVk`; `0` means "literal character" (use `wAsciiChar` instead).
    key: u16,
    ascii: u8 = 0,

    pub fn init(self: Win32Accel) Win32Accel {
        return self;
    }
};

/// `NSEventModifierFlags` bits used by the Objective-C shim: Shift (`1 << 17` in AppKit, folded to this
/// compact mask before crossing the ABI).
pub const MAC_SHIFT: u8 = 1 << 0;
/// `NSEventModifierFlags` bit for Control, folded into the shim's compact mask.
pub const MAC_CONTROL: u8 = 1 << 1;
pub const MAC_OPTION: u8 = 1 << 2;
pub const MAC_COMMAND: u8 = 1 << 3;

pub const MacosAccel = struct {
    modifier_mask: u8,
    /// Single-character `keyEquivalent`, or an empty string when the key has no direct equivalent
    /// (the shim then falls back to the `virtual_key` code below).
    key_equivalent: u8 = 0,
    virtual_key: u16 = 0,
};

// ============================================================================
// Tokenizer
// ============================================================================

const TokenIterator = struct {
    rest: []const u8,

    fn next(self: *TokenIterator) ?[]const u8 {
        var s = std.mem.trim(u8, self.rest, " \t");
        if (s.len == 0) return null;
        const idx = std.mem.indexOfScalar(u8, s, '+');
        if (idx) |i| {
            const token = s[0..i];
            self.rest = s[i + 1 ..];
            return std.mem.trim(u8, token, " \t");
        }
        self.rest = s[s.len..];
        return s;
    }
};

const ModifierName = enum { shift, ctrl, alt, meta, cmd_or_ctrl };

fn parseModifier(token: []const u8) ?ModifierName {
    const table = .{
        .{ "shift", ModifierName.shift },
        .{ "control", ModifierName.ctrl },
        .{ "ctrl", ModifierName.ctrl },
        .{ "alt", ModifierName.alt },
        .{ "option", ModifierName.alt },
        .{ "command", ModifierName.meta },
        .{ "cmd", ModifierName.meta },
        .{ "super", ModifierName.meta },
        .{ "cmdorctrl", ModifierName.cmd_or_ctrl },
        .{ "cmdorcontrol", ModifierName.cmd_or_ctrl },
        .{ "commandorctrl", ModifierName.cmd_or_ctrl },
        .{ "commandorcontrol", ModifierName.cmd_or_ctrl },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(token, row[0])) return row[1];
    }
    return null;
}

fn parseKey(token: []const u8) ParseError!Key {
    if (token.len == 1) {
        const ch = token[0];
        if (std.ascii.isAlphanumeric(ch)) return .{ .char = std.ascii.toUpper(ch) };
        // Punctuation is accepted as-is (`/`, `,`, `-`, `.`, `=`, `[`, `]`, `\\`, `` ` ``, `;`, `'`).
        if (std.ascii.isPrint(ch)) return .{ .char = ch };
        return error.InvalidAccelerator;
    }

    // `KeyA`..`KeyZ`, `Digit0`..`Digit9`.
    if (token.len == 4 and std.ascii.eqlIgnoreCase(token[0..3], "key")) {
        const ch = token[3];
        if (std.ascii.isAlphabetic(ch)) return .{ .char = std.ascii.toUpper(ch) };
    }
    if (token.len == 6 and std.ascii.eqlIgnoreCase(token[0..5], "digit")) {
        const ch = token[5];
        if (std.ascii.isDigit(ch)) return .{ .char = ch };
    }

    // `F1`..`F24`.
    if ((token[0] == 'f' or token[0] == 'F') and token.len <= 3) {
        if (std.fmt.parseInt(u8, token[1..], 10)) |n| {
            if (n >= 1 and n <= 24) return .{ .function = n };
        } else |_| {}
    }

    // `Numpad0`..`Numpad9` / `Num0`..`Num9`.
    inline for (.{ "numpad", "num" }) |prefix| {
        if (token.len == prefix.len + 1 and std.ascii.eqlIgnoreCase(token[0..prefix.len], prefix)) {
            const ch = token[prefix.len];
            if (std.ascii.isDigit(ch)) return .{ .numpad = ch - '0' };
        }
    }

    const named = [_]struct { []const u8, Key }{
        .{ "Backspace", .{ .named = .backspace } },
        .{ "CapsLock", .{ .named = .caps_lock } },
        .{ "Enter", .{ .named = .enter } },
        .{ "Return", .{ .named = .enter } },
        .{ "Space", .{ .named = .space } },
        .{ "Tab", .{ .named = .tab } },
        .{ "Delete", .{ .named = .delete } },
        .{ "Del", .{ .named = .delete } },
        .{ "End", .{ .named = .end } },
        .{ "Home", .{ .named = .home } },
        .{ "Insert", .{ .named = .insert } },
        .{ "Ins", .{ .named = .insert } },
        .{ "PageDown", .{ .named = .page_down } },
        .{ "PageUp", .{ .named = .page_up } },
        .{ "PrintScreen", .{ .named = .print_screen } },
        .{ "ScrollLock", .{ .named = .scroll_lock } },
        .{ "NumLock", .{ .named = .num_lock } },
        .{ "Escape", .{ .named = .escape } },
        .{ "Esc", .{ .named = .escape } },
        .{ "ArrowUp", .{ .named = .arrow_up } },
        .{ "Up", .{ .named = .arrow_up } },
        .{ "ArrowDown", .{ .named = .arrow_down } },
        .{ "Down", .{ .named = .arrow_down } },
        .{ "ArrowLeft", .{ .named = .arrow_left } },
        .{ "Left", .{ .named = .arrow_left } },
        .{ "ArrowRight", .{ .named = .arrow_right } },
        .{ "Right", .{ .named = .arrow_right } },
        .{ "NumpadAdd", .{ .named = .numpad_add } },
        .{ "NumAdd", .{ .named = .numpad_add } },
        .{ "NumpadSubtract", .{ .named = .numpad_subtract } },
        .{ "NumSubtract", .{ .named = .numpad_subtract } },
        .{ "NumpadMultiply", .{ .named = .numpad_multiply } },
        .{ "NumMultiply", .{ .named = .numpad_multiply } },
        .{ "NumpadDivide", .{ .named = .numpad_divide } },
        .{ "NumDivide", .{ .named = .numpad_divide } },
        .{ "NumpadDecimal", .{ .named = .numpad_decimal } },
        .{ "NumDecimal", .{ .named = .numpad_decimal } },
        .{ "NumpadEnter", .{ .named = .numpad_enter } },
        .{ "NumEnter", .{ .named = .numpad_enter } },
        .{ "NumpadEqual", .{ .named = .numpad_equal } },
        .{ "NumEqual", .{ .named = .numpad_equal } },
        .{ "AudioVolumeUp", .{ .named = .audio_volume_up } },
        .{ "VolumeUp", .{ .named = .audio_volume_up } },
        .{ "AudioVolumeDown", .{ .named = .audio_volume_down } },
        .{ "VolumeDown", .{ .named = .audio_volume_down } },
        .{ "AudioVolumeMute", .{ .named = .audio_volume_mute } },
        .{ "VolumeMute", .{ .named = .audio_volume_mute } },
        .{ "Backquote", .{ .char = '`' } },
        .{ "Backslash", .{ .char = '\\' } },
        .{ "BracketLeft", .{ .char = '[' } },
        .{ "BracketRight", .{ .char = ']' } },
        .{ "Comma", .{ .char = ',' } },
        .{ "Equal", .{ .char = '=' } },
        .{ "Minus", .{ .char = '-' } },
        .{ "Period", .{ .char = '.' } },
        .{ "Quote", .{ .char = '\'' } },
        .{ "Semicolon", .{ .char = ';' } },
        .{ "Slash", .{ .char = '/' } },
    };
    inline for (named) |row| {
        if (std.ascii.eqlIgnoreCase(token, row[0])) return row[1];
    }

    return error.InvalidAccelerator;
}

/// GTK key names (the part after the modifiers in a GTK accelerator string).
fn writeGtkKey(writer: *std.Io.Writer, key: Key) std.Io.Writer.Error!void {
    switch (key) {
        .char => |ch| if (std.ascii.isUpper(ch)) try writer.writeByte(std.ascii.toLower(ch)) else try writer.writeByte(ch),
        .function => |n| try writer.print("F{d}", .{n}),
        .numpad => |n| try writer.print("KP_{d}", .{n}),
        .named => |n| try writer.writeAll(switch (n) {
            .backspace => "BackSpace",
            .caps_lock => "Caps_Lock",
            .enter => "Return",
            .space => "space",
            .tab => "Tab",
            .delete => "Delete",
            .end => "End",
            .home => "Home",
            .insert => "Insert",
            .page_down => "Page_Down",
            .page_up => "Page_Up",
            .print_screen => "Print",
            .scroll_lock => "Scroll_Lock",
            .num_lock => "Num_Lock",
            .escape => "Escape",
            .arrow_up => "Up",
            .arrow_down => "Down",
            .arrow_left => "Left",
            .arrow_right => "Right",
            .numpad_add => "KP_Add",
            .numpad_subtract => "KP_Subtract",
            .numpad_multiply => "KP_Multiply",
            .numpad_divide => "KP_Divide",
            .numpad_decimal => "KP_Decimal",
            .numpad_enter => "KP_Enter",
            .numpad_equal => "KP_Equal",
            .audio_volume_up => "AudioRaiseVolume",
            .audio_volume_down => "AudioLowerVolume",
            .audio_volume_mute => "AudioMute",
        }),
    }
}

/// Win32 virtual-key codes (`VK_*`).
fn win32VirtualKey(key: Key) u16 {
    return switch (key) {
        .char => |ch| if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch))
            ch // VK codes for 0-9/A-Z are the ASCII values
        else
            0,
        .function => |n| 0x70 + (n - 1), // VK_F1 = 0x70
        .numpad => |n| 0x60 + n, // VK_NUMPAD0 = 0x60
        .named => |n| switch (n) {
            .backspace => 0x08,
            .caps_lock => 0x14,
            .enter => 0x0D,
            .space => 0x20,
            .tab => 0x09,
            .delete => 0x2E,
            .end => 0x23,
            .home => 0x24,
            .insert => 0x2D,
            .page_down => 0x22,
            .page_up => 0x21,
            .print_screen => 0x2C,
            .scroll_lock => 0x91,
            .num_lock => 0x90,
            .escape => 0x1B,
            .arrow_up => 0x26,
            .arrow_down => 0x28,
            .arrow_left => 0x25,
            .arrow_right => 0x27,
            .numpad_add => 0x6B,
            .numpad_subtract => 0x6D,
            .numpad_multiply => 0x6A,
            .numpad_divide => 0x6F,
            .numpad_decimal => 0x6E,
            .numpad_enter => 0x0D,
            .numpad_equal => 0x0C,
            .audio_volume_up => 0xAF,
            .audio_volume_down => 0xAE,
            .audio_volume_mute => 0xAD,
        },
    };
}

/// macOS `keyEquivalent` characters. Letters/digits map to themselves (lower-case; the modifier
/// mask carries Shift), function keys map to the Unicode private-use `NSF1FunctionKey` range.
fn macosKeyEquivalent(key: Key) u8 {
    return switch (key) {
        .char => |ch| if (std.ascii.isUpper(ch)) std.ascii.toLower(ch) else ch,
        .function, .numpad, .named => 0,
    };
}

/// macOS virtual key codes for the keys that have no `keyEquivalent` character.
pub fn macosVirtualKey(key: Key) u16 {
    return switch (key) {
        .function => |n| switch (n) {
            1 => 122,
            2 => 120,
            3 => 99,
            4 => 118,
            5 => 96,
            6 => 97,
            7 => 98,
            8 => 100,
            9 => 101,
            10 => 109,
            11 => 103,
            12 => 111,
            13 => 105,
            14 => 107,
            15 => 113,
            16 => 106,
            17 => 64,
            18 => 79,
            19 => 80,
            20 => 90,
            else => 0,
        },
        .numpad => |n| 82 + n,
        .named => |n| switch (n) {
            .backspace => 51,
            .caps_lock => 57,
            .enter => 36,
            .space => 49,
            .tab => 48,
            .delete => 117,
            .end => 119,
            .home => 115,
            .insert => 114,
            .page_down => 121,
            .page_up => 116,
            .print_screen => 0,
            .scroll_lock => 0,
            .num_lock => 71,
            .escape => 53,
            .arrow_up => 126,
            .arrow_down => 125,
            .arrow_left => 123,
            .arrow_right => 124,
            .numpad_add => 69,
            .numpad_subtract => 78,
            .numpad_multiply => 67,
            .numpad_divide => 75,
            .numpad_decimal => 65,
            .numpad_enter => 76,
            .numpad_equal => 81,
            .audio_volume_up => 72,
            .audio_volume_down => 73,
            .audio_volume_mute => 74,
        },
        .char => 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parses the documented modifier spellings and resolves CmdOrCtrl per platform" {
    const acc = try Accelerator.parse("CmdOrCtrl+Shift+K");
    try testing.expect(acc.mods.cmd_or_ctrl);
    try testing.expect(acc.mods.shift);
    try testing.expectEqual(Key{ .char = 'K' }, acc.key);

    // Case-insensitive with spaces around every token.
    const spaced = try Accelerator.parse(" cmdorctrl + shift + k ");
    try testing.expect(spaced.mods.cmd_or_ctrl);
    try testing.expectEqual(Key{ .char = 'K' }, spaced.key);

    const mac = acc.mods.resolved(true);
    try testing.expect(mac.meta and !mac.ctrl);
    const other = acc.mods.resolved(false);
    try testing.expect(other.ctrl and !other.meta);

    // Every documented alias maps onto the same flag.
    const aliases = [_][]const u8{ "Shift", "Control", "Ctrl", "Alt", "Option", "Command", "Cmd", "Super" };
    inline for (aliases) |alias| {
        const single = try Accelerator.parse(alias ++ "+A");
        try testing.expect(!single.mods.isEmpty());
    }
    const ctrl_aliases = [_][]const u8{ "CmdOrCtrl", "CmdOrControl", "CommandOrCtrl", "CommandOrControl" };
    inline for (ctrl_aliases) |alias| {
        const p = try Accelerator.parse(alias ++ "+A");
        try testing.expect(p.mods.cmd_or_ctrl);
    }
}

test "parses letters, digits, function keys, punctuation and named keys" {
    try testing.expectEqual(Key{ .char = 'A' }, (try Accelerator.parse("KeyA")).key);
    try testing.expectEqual(Key{ .char = '7' }, (try Accelerator.parse("Digit7")).key);
    try testing.expectEqual(Key{ .function = 24 }, (try Accelerator.parse("F24")).key);
    try testing.expectEqual(Key{ .numpad = 3 }, (try Accelerator.parse("Numpad3")).key);
    try testing.expectEqual(Key{ .numpad = 3 }, (try Accelerator.parse("Num3")).key);
    try testing.expectEqual(Key{ .char = '/' }, (try Accelerator.parse("Slash")).key);
    try testing.expectEqual(Key{ .char = '/' }, (try Accelerator.parse("/")).key);
    try testing.expectEqual(Key{ .named = .escape }, (try Accelerator.parse("Esc")).key);
    try testing.expectEqual(Key{ .named = .arrow_up }, (try Accelerator.parse("Up")).key);
    try testing.expectEqual(Key{ .named = .numpad_add }, (try Accelerator.parse("NumAdd")).key);
    try testing.expectEqual(Key{ .named = .audio_volume_mute }, (try Accelerator.parse("VolumeMute")).key);
}

test "rejects malformed accelerators instead of silently ignoring them" {
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse(""));
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse("Shift"));
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse("Control+Shift"));
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse("K+Shift"));
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse("Shift+Shift+K"));
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse("Hyper+K"));
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse("F25"));
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse("Nonsense"));
    try testing.expectError(error.InvalidAccelerator, Accelerator.parse("Shift+K+J"));
}

test "renders GTK accelerator strings that GTK can parse back" {
    const acc = try Accelerator.parse("CmdOrCtrl+Shift+K");
    const gtk = try acc.renderGtk(testing.allocator);
    defer testing.allocator.free(gtk);
    try testing.expectEqualStrings("<Primary><Shift>k", gtk);

    const f5 = try (try Accelerator.parse("F5")).renderGtk(testing.allocator);
    defer testing.allocator.free(f5);
    try testing.expectEqualStrings("F5", f5);

    const ctrl_alt_del = try (try Accelerator.parse("Ctrl+Alt+Delete")).renderGtk(testing.allocator);
    defer testing.allocator.free(ctrl_alt_del);
    try testing.expectEqualStrings("<Control><Alt>Delete", ctrl_alt_del);
}

test "maps modifiers and keys onto Win32 ACCEL fields and macOS masks" {
    const acc = try Accelerator.parse("CmdOrCtrl+Shift+K");
    const win = acc.toWin32();
    try testing.expectEqual(@as(u8, FVIRTKEY | FSHIFT | FCONTROL), win.virt);
    try testing.expectEqual(@as(u16, 'K'), win.key);

    const mac = acc.toMacos();
    try testing.expectEqual(@as(u8, MAC_COMMAND | MAC_SHIFT), mac.modifier_mask);
    try testing.expectEqual(@as(u8, 'k'), mac.key_equivalent);

    // Option/Alt only.
    const alt = try Accelerator.parse("Option+ArrowLeft");
    try testing.expectEqual(@as(u8, MAC_OPTION), alt.toMacos().modifier_mask);
    try testing.expectEqual(@as(u16, 0x25), alt.toWin32().key);
    try testing.expectEqual(@as(u16, macosVirtualKey(.{ .named = .arrow_left })), macosVirtualKey(alt.key));
    try testing.expectEqual(@as(u16, 123), macosVirtualKey(alt.key));
}
