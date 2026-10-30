//! Windows native dialogs: `IFileOpenDialog` / `IFileSaveDialog` (Common Item Dialog COM) for file
//! and folder picking, and `MessageBoxW` for message dialogs.
//!
//! Vtables are declared by hand in ABI order (no `@cImport`, no `.idl` translation). The pure
//! option/filter/UTF-16 helpers live in `../native_win32.zig` so they are unit-tested on every OS.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dialog = @import("mod.zig");
const win = @import("../native_win32.zig");

const Error = dialog.BackendError;

const CALL: std.builtin.CallingConvention = .winapi;
const HResult = i32;
const Guid = extern struct { data: [16]u8 };
const HWND = ?*anyopaque;

fn guid(comptime text: []const u8) Guid {
    var out: Guid = .{ .data = undefined };
    var i: usize = 0;
    var byte_index: usize = 0;
    while (i < text.len) {
        if (text[i] == '-') {
            i += 1;
            continue;
        }
        const hi = std.fmt.charToDigit(text[i], 16) catch unreachable;
        const lo = std.fmt.charToDigit(text[i + 1], 16) catch unreachable;
        out.data[byte_index] = (hi << 4) | lo;
        byte_index += 1;
        i += 2;
    }
    return out;
}

const CLSID_FileOpenDialog = guid("dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7");
const CLSID_FileSaveDialog = guid("c0b4e2f3-ba21-4773-8dba-335ec946eb8b");
const IID_IFileOpenDialog = guid("d57c7288-d4ad-4768-be02-9d969532d960");
const IID_IFileSaveDialog = guid("84bccd23-5fde-4cdb-aea4-af64b83d78ab");
const IID_IShellItem = guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
const IID_IShellItemArray = guid("b63ea76d-1f85-456f-a19c-48159efa858b");

const CLSCTX_INPROC_SERVER: u32 = 1;
const COINIT_APARTMENTTHREADED: u32 = 0x2;
const S_OK: HResult = 0;
const S_FALSE: HResult = 1;
/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)` — the user pressed Cancel / closed the dialog.
const HRESULT_CANCELLED: HResult = @bitCast(@as(u32, 0x800704C7));
const SIGDN_FILESYSPATH: u32 = 0x80058000;

pub const COMDLG_FILTERSPEC = extern struct {
    pszName: ?[*:0]const u16,
    pszSpec: ?[*:0]const u16,
};

pub const IShellItem = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *IShellItem, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *IShellItem) callconv(CALL) u32,
        Release: *const fn (this: *IShellItem) callconv(CALL) u32,
        BindToHandler: ?*const anyopaque,
        GetParent: ?*const anyopaque,
        GetDisplayName: *const fn (this: *IShellItem, sigdn: u32, out: *?[*:0]u16) callconv(CALL) HResult,
        GetAttributes: ?*const anyopaque,
        Compare: ?*const anyopaque,
    };
};

pub const IShellItemArray = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *IShellItemArray, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *IShellItemArray) callconv(CALL) u32,
        Release: *const fn (this: *IShellItemArray) callconv(CALL) u32,
        BindToHandler: ?*const anyopaque,
        GetPropertyStore: ?*const anyopaque,
        GetPropertyDescriptionList: ?*const anyopaque,
        GetAttributes: ?*const anyopaque,
        GetCount: *const fn (this: *IShellItemArray, out: *u32) callconv(CALL) HResult,
        GetItemAt: *const fn (this: *IShellItemArray, index: u32, out: *?*IShellItem) callconv(CALL) HResult,
        EnumItems: ?*const anyopaque,
    };
};

/// `IFileDialog` (27 slots). `IFileOpenDialog` / `IFileSaveDialog` extend it, so the shared prefix
/// is all this backend needs except for `GetResults` (declared below).
pub const IFileDialog = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (this: *IFileDialog, riid: *const Guid, out: *?*anyopaque) callconv(CALL) HResult,
        AddRef: *const fn (this: *IFileDialog) callconv(CALL) u32,
        Release: *const fn (this: *IFileDialog) callconv(CALL) u32,
        Show: *const fn (this: *IFileDialog, parent: HWND) callconv(CALL) HResult,
        SetFileTypes: *const fn (this: *IFileDialog, count: u32, specs: ?[*]const COMDLG_FILTERSPEC) callconv(CALL) HResult,
        SetFileTypeIndex: *const fn (this: *IFileDialog, index: u32) callconv(CALL) HResult,
        GetFileTypeIndex: ?*const anyopaque,
        Advise: ?*const anyopaque,
        Unadvise: ?*const anyopaque,
        SetOptions: *const fn (this: *IFileDialog, options: u32) callconv(CALL) HResult,
        GetOptions: *const fn (this: *IFileDialog, out: *u32) callconv(CALL) HResult,
        SetDefaultFolder: ?*const anyopaque,
        SetFolder: ?*const anyopaque,
        GetFolder: ?*const anyopaque,
        GetCurrentSelection: ?*const anyopaque,
        SetFileName: *const fn (this: *IFileDialog, name: ?[*:0]const u16) callconv(CALL) HResult,
        GetFileName: ?*const anyopaque,
        SetTitle: *const fn (this: *IFileDialog, title: ?[*:0]const u16) callconv(CALL) HResult,
        SetOkButtonLabel: ?*const anyopaque,
        SetFileNameLabel: ?*const anyopaque,
        GetResult: *const fn (this: *IFileDialog, out: *?*IShellItem) callconv(CALL) HResult,
        AddPlace: ?*const anyopaque,
        SetDefaultExtension: *const fn (this: *IFileDialog, ext: ?[*:0]const u16) callconv(CALL) HResult,
        Close: ?*const anyopaque,
        SetClientGuid: ?*const anyopaque,
        ClearClientData: ?*const anyopaque,
        SetFilter: ?*const anyopaque,
        /// `IFileOpenDialog::GetResults` sits immediately after `IFileDialog`'s 27 slots.
        GetResults: *const fn (this: *IFileDialog, out: *?*IShellItemArray) callconv(CALL) HResult,
    };
};

extern "c" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) HResult;
extern "c" fn CoUninitialize() void;
extern "c" fn CoCreateInstance(
    clsid: *const Guid,
    outer: ?*anyopaque,
    cls_ctx: u32,
    iid: *const Guid,
    out: *?*anyopaque,
) HResult;
extern "c" fn CoTaskMemFree(mem: ?*anyopaque) void;
extern "c" fn MessageBoxW(hwnd: HWND, text: ?[*:0]const u16, caption: ?[*:0]const u16, flags: u32) c_int;

var com_ready: ?bool = null;

fn ensureCom() bool {
    if (com_ready) |ready| return ready;
    const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    // S_OK / S_FALSE (already initialized) / RPC_E_CHANGED_MODE (someone else owns STA): all usable.
    const ok = hr == S_OK or hr == S_FALSE or hr == @as(HResult, @bitCast(@as(u32, 0x80010106)));
    com_ready = ok;
    return ok;
}

fn succeeded(hr: HResult) bool {
    return hr >= 0;
}

const Filters = struct {
    specs: []COMDLG_FILTERSPEC = &.{},
    names: [][]u16 = &.{},
    patterns: [][]u16 = &.{},

    fn deinit(self: *Filters, allocator: Allocator) void {
        for (self.names) |n| allocator.free(n);
        for (self.patterns) |p| allocator.free(p);
        if (self.names.len > 0) allocator.free(self.names);
        if (self.patterns.len > 0) allocator.free(self.patterns);
        if (self.specs.len > 0) allocator.free(self.specs);
        self.* = .{};
    }
};

fn buildFilters(allocator: Allocator, filters: []const dialog.DialogFilter) Error!Filters {
    if (filters.len == 0) return .{};

    var out: Filters = .{};
    out.names = allocator.alloc([]u16, filters.len) catch return error.OutOfMemory;
    out.patterns = allocator.alloc([]u16, filters.len) catch {
        allocator.free(out.names);
        return error.OutOfMemory;
    };
    out.specs = allocator.alloc(COMDLG_FILTERSPEC, filters.len) catch {
        allocator.free(out.names);
        allocator.free(out.patterns);
        return error.OutOfMemory;
    };
    var filled: usize = 0;
    errdefer {
        for (out.names[0..filled]) |n| allocator.free(n);
        for (out.patterns[0..filled]) |p| allocator.free(p);
        allocator.free(out.names);
        allocator.free(out.patterns);
        allocator.free(out.specs);
    }

    for (filters, 0..) |filter, i| {
        const record = win.filterRecord(allocator, filter.name, filter.extensions) catch return error.OutOfMemory;
        defer allocator.free(record);
        const spec = win.parseFilter(allocator, record) catch return error.Failed;
        defer allocator.free(spec.name);
        defer allocator.free(spec.pattern);

        const name_z = win.utf8ToUtf16ZAlloc(allocator, spec.name) catch return error.OutOfMemory;
        const pattern_z = win.utf8ToUtf16ZAlloc(allocator, spec.pattern) catch {
            allocator.free(name_z);
            return error.OutOfMemory;
        };
        out.names[i] = name_z;
        out.patterns[i] = pattern_z;
        out.specs[i] = .{ .pszName = name_z.ptr, .pszSpec = pattern_z.ptr };
        filled += 1;
    }
    return out;
}

fn itemPath(allocator: Allocator, item: *IShellItem) Error![]const u8 {
    var raw: ?[*:0]u16 = null;
    if (!succeeded(item.vtable.GetDisplayName(item, SIGDN_FILESYSPATH, &raw))) return error.Failed;
    defer CoTaskMemFree(@ptrCast(raw));
    const wide = raw orelse return error.Failed;
    return win.utf16ZToUtf8(allocator, wide) catch error.OutOfMemory;
}

fn collect(
    allocator: Allocator,
    file_dialog: *IFileDialog,
    multiple: bool,
) Error!dialog.Selection {
    if (multiple) {
        var array: ?*IShellItemArray = null;
        if (succeeded(file_dialog.vtable.GetResults(file_dialog, &array)) and array != null) {
            const items = array.?;
            defer _ = items.vtable.Release(items);

            var count: u32 = 0;
            if (!succeeded(items.vtable.GetCount(items, &count)) or count == 0) return .{};

            const paths = allocator.alloc([]const u8, count) catch return error.OutOfMemory;
            var filled: usize = 0;
            errdefer {
                for (paths[0..filled]) |p| allocator.free(p);
                allocator.free(paths);
            }
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                var item: ?*IShellItem = null;
                if (!succeeded(items.vtable.GetItemAt(items, i, &item)) or item == null) continue;
                defer _ = item.?.vtable.Release(item.?);
                paths[filled] = try itemPath(allocator, item.?);
                filled += 1;
            }
            return .{ .paths = paths[0..filled] };
        }
        // Fall through to the single-item path (some pickers return no array).
    }

    var item: ?*IShellItem = null;
    if (!succeeded(file_dialog.vtable.GetResult(file_dialog, &item)) or item == null) return .{};
    defer _ = item.?.vtable.Release(item.?);

    const one = try itemPath(allocator, item.?);
    errdefer allocator.free(one);
    const paths = allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
    paths[0] = one;
    return .{ .paths = paths };
}

fn show(
    allocator: Allocator,
    clsid: *const Guid,
    iid: *const Guid,
    options_bits: u32,
    title: ?[]const u8,
    default_path: ?[]const u8,
    filters: []const dialog.DialogFilter,
    multiple: bool,
    default_extension: ?[]const u8,
) Error!dialog.Selection {
    if (!ensureCom()) return error.Unavailable;

    var raw: ?*anyopaque = null;
    if (!succeeded(CoCreateInstance(clsid, null, CLSCTX_INPROC_SERVER, iid, &raw)) or raw == null) return error.Unavailable;
    const dlg: *IFileDialog = @ptrCast(@alignCast(raw.?));
    defer _ = dlg.vtable.Release(dlg);

    _ = dlg.vtable.SetOptions(dlg, options_bits);

    var filters_out = try buildFilters(allocator, filters);
    defer filters_out.deinit(allocator);
    if (filters_out.specs.len > 0) {
        _ = dlg.vtable.SetFileTypes(dlg, @intCast(filters_out.specs.len), filters_out.specs.ptr);
    }

    if (title) |t| {
        if (t.len > 0) {
            const title_z = win.utf8ToUtf16ZAlloc(allocator, t) catch return error.OutOfMemory;
            defer allocator.free(title_z);
            _ = dlg.vtable.SetTitle(dlg, title_z.ptr);
        }
    }
    if (default_path) |p| {
        if (p.len > 0) {
            const path_z = win.utf8ToUtf16ZAlloc(allocator, p) catch return error.OutOfMemory;
            defer allocator.free(path_z);
            _ = dlg.vtable.SetFileName(dlg, path_z.ptr);
        }
    }
    if (default_extension) |ext| {
        if (ext.len > 0) {
            const ext_z = win.utf8ToUtf16ZAlloc(allocator, ext) catch return error.OutOfMemory;
            defer allocator.free(ext_z);
            _ = dlg.vtable.SetDefaultExtension(dlg, ext_z.ptr);
        }
    }

    const hr = dlg.vtable.Show(dlg, null);
    if (hr == HRESULT_CANCELLED) return .{};
    if (!succeeded(hr)) return error.Failed;

    return collect(allocator, dlg, multiple);
}

fn openImpl(_: ?*anyopaque, allocator: Allocator, options: dialog.OpenDialogOptions) Error!dialog.Selection {
    return show(
        allocator,
        &CLSID_FileOpenDialog,
        &IID_IFileOpenDialog,
        win.openDialogOptions(options.directory, options.multiple, true),
        options.title,
        options.default_path,
        options.filters,
        options.multiple and !options.directory,
        null,
    );
}

fn saveImpl(_: ?*anyopaque, allocator: Allocator, options: dialog.SaveDialogOptions) Error!dialog.Selection {
    // The extension of `defaultPath` doubles as the dialog's default extension.
    const ext = if (options.default_path) |p| blk: {
        const e = std.fs.path.extension(p);
        break :blk if (e.len > 1) e[1..] else null;
    } else null;

    return show(
        allocator,
        &CLSID_FileSaveDialog,
        &IID_IFileSaveDialog,
        win.saveDialogOptions(),
        options.title,
        options.default_path,
        options.filters,
        false,
        ext,
    );
}

fn shapeOf(buttons: dialog.MessageDialogButtons) win.MessageShape {
    if (buttons.yes != null and buttons.no != null and buttons.cancel != null) return .yes_no_cancel;
    if (buttons.yes != null and buttons.no != null) return .yes_no;
    if (buttons.ok != null and buttons.cancel != null) return .ok_cancel;
    return .ok;
}

fn messageImpl(_: ?*anyopaque, allocator: Allocator, request: dialog.MessageRequest) Error![]const u8 {
    var labels_buf: [3]dialog.Button = undefined;
    const buttons = request.buttons.labels(&labels_buf);
    if (buttons.len == 0) return error.Failed;

    const shape = shapeOf(request.buttons);
    // `MessageBoxW` cannot rename buttons: the stock set is shown, and the result is mapped back
    // to the caller's label so `ask()` / `confirm()` still compare against the label they passed.
    const flags: u32 = win.messageBoxButtons(shape) | switch (request.kind) {
        .info => win.MessageBoxIcon.information,
        .warning => win.MessageBoxIcon.warning,
        .@"error" => win.MessageBoxIcon.@"error",
    };

    const text_z = win.utf8ToUtf16ZAlloc(allocator, request.message) catch return error.OutOfMemory;
    defer allocator.free(text_z);

    const title = request.title orelse "Z-Ts";
    const title_z = win.utf8ToUtf16ZAlloc(allocator, title) catch return error.OutOfMemory;
    defer allocator.free(title_z);

    const result = MessageBoxW(null, text_z.ptr, title_z.ptr, flags);
    return switch (result) {
        win.MessageBoxResult.ok => request.buttons.ok orelse "Ok",
        win.MessageBoxResult.cancel => request.buttons.cancel orelse "Cancel",
        win.MessageBoxResult.yes => request.buttons.yes orelse "Yes",
        win.MessageBoxResult.no => request.buttons.no orelse "No",
        else => "Cancel",
    };
}

const vtable = dialog.Backend.VTable{
    .open = openImpl,
    .save = saveImpl,
    .message = messageImpl,
};

pub fn backend() dialog.Backend {
    return .{ .vtable = &vtable };
}

test "COM GUID literals parse to the documented byte order" {
    const iid = guid("00000000-0000-0000-c000-000000000046");
    try std.testing.expectEqual(@as(u8, 0xc0), iid.data[8]);
    try std.testing.expectEqual(@as(u8, 0x00), iid.data[0]);
    try std.testing.expectEqual(@as(u8, 0x46), iid.data[15]);
}
