//! OS-independent Win32 helpers for the dialog / clipboard backends.
//!
//! Everything here is Pure Zig with **no** Win32 imports, so the option-bit math, filter-spec
//! construction and UTF-16 conversion are unit-tested on Linux, macOS and Windows alike (the same
//! split `src/webview/windows_util.zig` uses). The actual `IFileOpenDialog` / `MessageBoxW` /
//! clipboard calls live in `dialog/native_windows.zig` and `clipboard/native_windows.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// `FILEOPENDIALOGOPTIONS` bits used by `plugin:dialog`.
pub const FileOpenDialogOptions = struct {
    pub const overwrite_prompt: u32 = 0x00000002;
    pub const strict_file_types: u32 = 0x00000004;
    pub const pick_folders: u32 = 0x00000020;
    pub const force_file_system: u32 = 0x00000040;
    pub const no_validate: u32 = 0x00000100;
    pub const allow_multi_select: u32 = 0x00000200;
    pub const path_must_exist: u32 = 0x00000800;
    pub const file_must_exist: u32 = 0x00001000;
    pub const no_read_only_return: u32 = 0x00008000;
    pub const no_dereference_links: u32 = 0x00100000;
    pub const dont_add_to_recent: u32 = 0x02000000;
    pub const force_show_hidden: u32 = 0x10000000;
};

/// Options for `IFileOpenDialog`, matching what upstream `rfd` requests per picker kind.
pub fn openDialogOptions(directory: bool, multiple: bool, must_exist: bool) u32 {
    var bits: u32 = FileOpenDialogOptions.force_file_system |
        FileOpenDialogOptions.path_must_exist |
        FileOpenDialogOptions.no_dereference_links;
    if (directory) {
        bits |= FileOpenDialogOptions.pick_folders;
    } else if (must_exist) {
        bits |= FileOpenDialogOptions.file_must_exist;
    }
    if (multiple) bits |= FileOpenDialogOptions.allow_multi_select;
    return bits;
}

/// Options for `IFileSaveDialog`.
pub fn saveDialogOptions() u32 {
    return FileOpenDialogOptions.overwrite_prompt |
        FileOpenDialogOptions.force_file_system |
        FileOpenDialogOptions.no_read_only_return;
}

/// `OPENFILENAME`-style filter spec: `"Images (*.png;*.jpg)"` / `"*.png;*.jpg"`.
pub const FilterSpec = struct {
    name: []const u8,
    pattern: []const u8,
};

/// Converts plugin filters into Win32 `COMDLG_FILTERSPEC` pairs.
///
/// An extension of `*` (upstream's "All files") becomes the `*.*` pattern. Caller owns both the
/// returned slice and every string in it.
pub fn buildFilterSpecs(allocator: Allocator, filters: []const []const u8) ![]FilterSpec {
    if (filters.len == 0) return &.{};

    var specs = try allocator.alloc(FilterSpec, filters.len);
    var filled: usize = 0;
    errdefer {
        for (specs[0..filled]) |spec| {
            allocator.free(spec.name);
            allocator.free(spec.pattern);
        }
        allocator.free(specs);
    }

    for (filters, 0..) |raw, i| {
        specs[i] = try parseFilter(allocator, raw);
        filled += 1;
    }
    return specs[0..filled];
}

/// `raw` is a `\x1f`-separated `name\x1fext1;ext2` record produced by `filterRecord`.
pub fn parseFilter(allocator: Allocator, raw: []const u8) !FilterSpec {
    const sep = std.mem.indexOfScalar(u8, raw, 0x1f) orelse return error.InvalidFilter;
    const name = raw[0..sep];
    const exts = raw[sep + 1 ..];

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("{s} ({s})", .{ name, exts });

    var pattern: std.Io.Writer.Allocating = .init(allocator);
    defer pattern.deinit();
    var it = std.mem.splitScalar(u8, exts, ';');
    var first = true;
    while (it.next()) |ext| {
        if (ext.len == 0) continue;
        if (!first) try pattern.writer.writeByte(';');
        first = false;
        if (std.mem.eql(u8, ext, "*")) {
            try pattern.writer.writeAll("*.*");
        } else {
            try pattern.writer.print("*.{s}", .{ext});
        }
    }

    return .{
        .name = try allocator.dupe(u8, aw.written()),
        .pattern = try allocator.dupe(u8, pattern.written()),
    };
}

/// Packs one plugin filter into the `name\x1fext;ext` record consumed by `parseFilter`.
pub fn filterRecord(allocator: Allocator, name: []const u8, extensions: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll(name);
    try aw.writer.writeByte(0x1f);
    for (extensions, 0..) |ext, i| {
        if (i > 0) try aw.writer.writeByte(';');
        try aw.writer.writeAll(ext);
    }
    return aw.toOwnedSlice();
}

/// UTF-16 (NUL-terminated, as returned by COM) → UTF-8, allocated from `allocator`.
pub fn utf16ZToUtf8(allocator: Allocator, raw: [*:0]const u16) ![]u8 {
    const len = std.mem.len(raw);
    return std.unicode.utf16LeToUtf8Alloc(allocator, raw[0..len]);
}

/// UTF-8 → NUL-terminated UTF-16 (caller frees with the same allocator).
pub fn utf8ToUtf16ZAlloc(allocator: Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, s);
}

/// `MessageBoxW` button sets.
pub const MessageBoxButtons = struct {
    pub const ok: u32 = 0x00000000;
    pub const ok_cancel: u32 = 0x00000001;
    pub const yes_no: u32 = 0x00000004;
    pub const yes_no_cancel: u32 = 0x00000003;
};

/// `MessageBoxW` icons.
pub const MessageBoxIcon = struct {
    pub const information: u32 = 0x00000040;
    pub const warning: u32 = 0x00000030;
    pub const @"error": u32 = 0x00000010;
};

/// `MessageBoxW` return values.
pub const MessageBoxResult = struct {
    pub const ok: c_int = 1;
    pub const cancel: c_int = 2;
    pub const yes: c_int = 6;
    pub const no: c_int = 7;
};

/// The four button sets a message dialog can have.
pub const MessageShape = enum { ok, ok_cancel, yes_no, yes_no_cancel };

/// Maps the shape onto the `MessageBoxW` button flag.
///
/// `MessageBoxW` cannot rename buttons, so a custom label still shows the OS text; the *result*
/// reported back to the webview keeps the caller's label (see ADR-0012 §5).
pub fn messageBoxButtons(shape: MessageShape) u32 {
    return switch (shape) {
        .ok => MessageBoxButtons.ok,
        .ok_cancel => MessageBoxButtons.ok_cancel,
        .yes_no => MessageBoxButtons.yes_no,
        .yes_no_cancel => MessageBoxButtons.yes_no_cancel,
    };
}

test "message shapes map onto the four MessageBoxW button sets" {
    try testing.expectEqual(MessageBoxButtons.ok, messageBoxButtons(.ok));
    try testing.expectEqual(MessageBoxButtons.ok_cancel, messageBoxButtons(.ok_cancel));
    try testing.expectEqual(MessageBoxButtons.yes_no, messageBoxButtons(.yes_no));
    try testing.expectEqual(MessageBoxButtons.yes_no_cancel, messageBoxButtons(.yes_no_cancel));
}

test "open/save dialog option bits follow the upstream picker kinds" {
    const file = openDialogOptions(false, false, true);
    try testing.expect(file & FileOpenDialogOptions.file_must_exist != 0);
    try testing.expect(file & FileOpenDialogOptions.pick_folders == 0);
    try testing.expect(file & FileOpenDialogOptions.allow_multi_select == 0);
    try testing.expect(file & FileOpenDialogOptions.force_file_system != 0);

    const folder = openDialogOptions(true, false, true);
    try testing.expect(folder & FileOpenDialogOptions.pick_folders != 0);
    // Folders must not require FILEMUSTEXIST semantics (they are directories).
    try testing.expect(folder & FileOpenDialogOptions.file_must_exist == 0);

    const many = openDialogOptions(false, true, true);
    try testing.expect(many & FileOpenDialogOptions.allow_multi_select != 0);

    const save = saveDialogOptions();
    try testing.expect(save & FileOpenDialogOptions.overwrite_prompt != 0);
    try testing.expect(save & FileOpenDialogOptions.no_read_only_return != 0);
}

test "filter specs render exactly like Win32 COMDLG_FILTERSPEC pairs" {
    const alloc = testing.allocator;
    const record = try filterRecord(alloc, "Images", &.{ "png", "jpg" });
    defer alloc.free(record);
    const spec = try parseFilter(alloc, record);
    defer alloc.free(spec.name);
    defer alloc.free(spec.pattern);

    try testing.expectEqualStrings("Images (png;jpg)", spec.name);
    try testing.expectEqualStrings("*.png;*.jpg", spec.pattern);

    const all_record = try filterRecord(alloc, "All files", &.{"*"});
    defer alloc.free(all_record);
    const all = try parseFilter(alloc, all_record);
    defer alloc.free(all.name);
    defer alloc.free(all.pattern);
    try testing.expectEqualStrings("*.*", all.pattern);
}

test "UTF-16 conversion round-trips ASCII, Japanese and surrogate pairs" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "hello", "こんにちは", "emoji 🎉 mixed", "" }) |input| {
        const wide = try utf8ToUtf16ZAlloc(alloc, input);
        defer alloc.free(wide);
        const back = try utf16ZToUtf8(alloc, wide.ptr);
        defer alloc.free(back);
        try testing.expectEqualStrings(input, back);
    }
}
