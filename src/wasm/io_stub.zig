//! Single-Threaded `std.Io` Implementation for `wasm32-freestanding` (`src/wasm/io_stub.zig`).
//!
//! Why this unlocks 100% isomorphic code sharing:
//! - In Zig `0.17.0`, all synchronization (`Io.Mutex`), clocks (`Io.Clock`), async tasks (`io.async`),
//!   and RNG (`io.random` / `io.randomSecure`) dispatch through a 2-word `std.Io` VTable.
//! - By providing this lightweight freestanding `Io` implementation:
//!   1. Uncontended `Io.Mutex.lockUncancelable` / `unlock` runs in 2 instructions with zero syscalls.
//!   2. `io.async(...)` executes eagerly on the current stack and returns `null` (official `Io.VTable`
//!      eager-completion contract), making async Zig code work unchanged on single-threaded Wasm!
//!   3. `io.random` / `io.randomSecure` bridge directly to WebCrypto `crypto.getRandomValues` on Wasm
//!      (and deterministic SplitMix64 when tested headless without WebCrypto).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_wasm = builtin.cpu.arch.isWasm();

extern "zts_host" fn zts_host_fill_random(ptr: [*]u8, len: usize) void;
extern "zts_host" fn zts_host_now_ms() f64;

var fallback_prng_state: u64 = 0x9E37_79B9_7F4A_7C15;
var fallback_tick_ns: i96 = 1_700_000_000_000_000_000;

fn nextSplitMix64() u64 {
    fallback_prng_state +%= 0x9E37_79B9_7F4A_7C15;
    var z = fallback_prng_state;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

fn fillRandomFallback(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const word = nextSplitMix64();
        const bytes: [8]u8 = @bitCast(word);
        const rem = @min(8, buf.len - i);
        @memcpy(buf[i .. i + rem], bytes[0..rem]);
        i += rem;
    }
}

/// Global stateless `std.Io` handle safe for `wasm32-freestanding` and deterministic unit tests.
pub fn wasmIo() Io {
    return .{
        .userdata = null,
        .vtable = &vtable,
    };
}

const vtable: Io.VTable = .{
    .crashHandler = stubNoop1,
    .async = stubAsync,
    .concurrent = stubConcurrent,
    .await = stubAwait,
    .cancel = stubAwait,
    .groupAsync = stubGroupAsync,
    .groupConcurrent = stubGroupConcurrent,
    .groupAwait = stubGroupAwait,
    .groupCancel = stubGroupCancel,
    .recancel = stubNoop1,
    .swapCancelProtection = stubSwapCancelProtection,
    .checkCancel = stubCheckCancel,
    .futexWait = stubFutexWait,
    .futexWaitUncancelable = stubFutexWaitUncancelable,
    .futexWake = stubFutexWake,
    .operate = stubOperate,
    .batchAwaitAsync = stubBatchAwaitAsync,
    .batchAwaitConcurrent = stubBatchAwaitConcurrent,
    .batchCancel = stubBatchCancel,

    .dirCreateDir = stubDirCreateDir,
    .dirCreateDirPath = stubDirCreateDirPath,
    .dirCreateDirPathOpen = stubDirCreateDirPathOpen,
    .dirOpenDir = stubDirOpenDir,
    .dirStat = stubDirStat,
    .dirStatFile = stubDirStatFile,
    .dirAccess = stubDirAccess,
    .dirCreateFile = stubDirCreateFile,
    .dirCreateFileAtomic = stubDirCreateFileAtomic,
    .dirOpenFile = stubDirOpenFile,
    .dirClose = stubDirClose,
    .dirRead = stubDirRead,
    .dirRealPath = stubDirRealPath,
    .dirRealPathFile = stubDirRealPathFile,
    .dirDeleteFile = stubDirDeleteFile,
    .dirDeleteDir = stubDirDeleteDir,
    .dirRename = stubDirRename,
    .dirRenamePreserve = stubDirRenamePreserve,
    .dirSymLink = stubDirSymLink,
    .dirReadLink = stubDirReadLink,
    .dirSetOwner = stubDirSetOwner,
    .dirSetFileOwner = stubDirSetFileOwner,
    .dirSetPermissions = stubDirSetPermissions,
    .dirSetFilePermissions = stubDirSetFilePermissions,
    .dirSetTimestamps = stubDirSetTimestamps,
    .dirHardLink = stubDirHardLink,

    .fileStat = stubFileStat,
    .fileLength = stubFileLength,
    .fileClose = stubFileClose,
    .fileWritePositional = stubFileWritePositional,
    .fileWriteFileStreaming = stubFileWriteFileStreaming,
    .fileWriteFilePositional = stubFileWriteFilePositional,
    .fileReadPositional = stubFileReadPositional,
    .fileSeekBy = stubFileSeekBy,
    .fileSeekTo = stubFileSeekTo,
    .fileSync = stubFileSync,
    .fileIsTty = stubFileIsTty,
    .fileEnableAnsiEscapeCodes = stubFileEnableAnsi,
    .fileSupportsAnsiEscapeCodes = stubFileIsTty,
    .fileSetLength = stubFileSetLength,
    .fileSetOwner = stubFileSetOwner,
    .fileSetPermissions = stubFileSetPermissions,
    .fileSetTimestamps = stubFileSetTimestamps,
    .fileLock = stubFileLock,
    .fileTryLock = stubFileTryLock,
    .fileUnlock = stubFileUnlock,
    .fileDowngradeLock = stubFileDowngradeLock,
    .fileRealPath = stubFileRealPath,
    .fileHardLink = stubFileHardLink,

    .fileMemoryMapCreate = stubMmapCreate,
    .fileMemoryMapDestroy = stubMmapDestroy,
    .fileMemoryMapSetLength = stubMmapSetLength,
    .fileMemoryMapRead = stubMmapRead,
    .fileMemoryMapWrite = stubMmapWrite,

    .processExecutableOpen = stubProcExecOpen,
    .processExecutablePath = stubProcExecPath,
    .lockStderr = stubLockStderr,
    .tryLockStderr = stubTryLockStderr,
    .unlockStderr = stubNoop1,
    .processCurrentPath = stubProcCurrentPath,
    .processSetCurrentDir = stubProcSetCurrentDir,
    .processSetCurrentPath = stubProcSetCurrentPath,
    .processReplace = stubProcReplace,
    .processSpawn = stubProcSpawn,
    .childWait = stubChildWait,
    .childKill = stubChildKill,

    .progressParentFile = stubProgressParentFile,
    .inheritParentDir = stubInheritParentDir,
    .inheritParentFile = stubInheritParentFile,

    .now = implNow,
    .clockResolution = implClockResolution,
    .sleep = implSleep,
    .random = implRandom,
    .randomSecure = implRandomSecure,

    .netListenIp = stubNetListenIp,
    .netAccept = stubNetAccept,
    .netBindIp = stubNetBindIp,
    .netConnectIp = stubNetConnectIp,
    .netListenUnix = stubNetListenUnix,
    .netConnectUnix = stubNetConnectUnix,
    .netSocketCreatePair = stubNetSocketPair,
    .netWriteFile = stubNetWriteFile,
    .netClose = stubNetClose,
    .netShutdown = stubNetShutdown,
    .netInterfaceNameResolve = stubNetIfResolve,
    .netInterfaceName = stubNetIfName,
    .netLookup = stubNetLookup,
};

fn stubNoop1(_: ?*anyopaque) void {}

fn stubAsync(
    _: ?*anyopaque,
    result: []u8,
    _: std.mem.Alignment,
    context: []const u8,
    _: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    start(context.ptr, result.ptr);
    return null;
}

fn stubConcurrent(
    _: ?*anyopaque,
    _: usize,
    _: std.mem.Alignment,
    _: []const u8,
    _: std.mem.Alignment,
    _: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    return error.ConcurrencyUnavailable;
}

fn stubAwait(_: ?*anyopaque, _: *Io.AnyFuture, _: []u8, _: std.mem.Alignment) void {}

fn stubGroupAsync(
    _: ?*anyopaque,
    _: *Io.Group,
    context: []const u8,
    _: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    start(context.ptr);
}

fn stubGroupConcurrent(
    _: ?*anyopaque,
    _: *Io.Group,
    _: []const u8,
    _: std.mem.Alignment,
    _: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    return error.ConcurrencyUnavailable;
}

fn stubGroupAwait(_: ?*anyopaque, _: *Io.Group, _: *anyopaque) Io.Cancelable!void {}
fn stubGroupCancel(_: ?*anyopaque, _: *Io.Group, _: *anyopaque) void {}
fn stubSwapCancelProtection(_: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    return new;
}
fn stubCheckCancel(_: ?*anyopaque) Io.Cancelable!void {}
fn stubFutexWait(_: ?*anyopaque, _: *const u32, _: u32, _: Io.Timeout) Io.Cancelable!void {}
fn stubFutexWaitUncancelable(_: ?*anyopaque, _: *const u32, _: u32) void {}
fn stubFutexWake(_: ?*anyopaque, _: *const u32, _: u32) void {}

fn stubOperate(_: ?*anyopaque, _: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return error.Canceled;
}
fn stubBatchAwaitAsync(_: ?*anyopaque, _: *Io.Batch) Io.Cancelable!void {}
fn stubBatchAwaitConcurrent(_: ?*anyopaque, _: *Io.Batch, _: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    return error.ConcurrencyUnavailable;
}
fn stubBatchCancel(_: ?*anyopaque, _: *Io.Batch) void {}

fn stubDirCreateDir(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
    return error.AccessDenied;
}
fn stubDirCreateDirPath(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    return error.AccessDenied;
}
fn stubDirCreateDirPathOpen(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.Permissions, _: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
    return error.AccessDenied;
}
fn stubDirOpenDir(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    return error.AccessDenied;
}
fn stubDirStat(_: ?*anyopaque, _: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
    return error.AccessDenied;
}
fn stubDirStatFile(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    return error.AccessDenied;
}
fn stubDirAccess(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
    return error.AccessDenied;
}
fn stubDirCreateFile(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
    return error.AccessDenied;
}
fn stubDirCreateFileAtomic(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
    return error.AccessDenied;
}
fn stubDirOpenFile(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
    return error.AccessDenied;
}
fn stubDirClose(_: ?*anyopaque, _: []const Io.Dir) void {}
fn stubDirRead(_: ?*anyopaque, _: *Io.Dir.Reader, _: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    return error.AccessDenied;
}
fn stubDirRealPath(_: ?*anyopaque, _: Io.Dir, _: []u8) Io.Dir.RealPathError!usize {
    return error.AccessDenied;
}
fn stubDirRealPathFile(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: []u8) Io.Dir.RealPathFileError!usize {
    return error.Unexpected;
}
fn stubDirDeleteFile(_: ?*anyopaque, _: Io.Dir, _: []const u8) Io.Dir.DeleteFileError!void {
    return error.AccessDenied;
}
fn stubDirDeleteDir(_: ?*anyopaque, _: Io.Dir, _: []const u8) Io.Dir.DeleteDirError!void {
    return error.AccessDenied;
}
fn stubDirRename(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir, _: []const u8) Io.Dir.RenameError!void {
    return error.AccessDenied;
}
fn stubDirRenamePreserve(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir, _: []const u8) Io.Dir.RenamePreserveError!void {
    return error.AccessDenied;
}
fn stubDirSymLink(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: []const u8, _: Io.Dir.SymLinkFlags) Io.Dir.SymLinkError!void {
    return error.AccessDenied;
}
fn stubDirReadLink(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: []u8) Io.Dir.ReadLinkError!usize {
    return error.AccessDenied;
}
fn stubDirSetOwner(_: ?*anyopaque, _: Io.Dir, _: ?Io.File.Uid, _: ?Io.File.Gid) Io.Dir.SetOwnerError!void {
    return error.AccessDenied;
}
fn stubDirSetFileOwner(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: ?Io.File.Uid, _: ?Io.File.Gid, _: Io.Dir.SetFileOwnerOptions) Io.Dir.SetFileOwnerError!void {
    return error.AccessDenied;
}
fn stubDirSetPermissions(_: ?*anyopaque, _: Io.Dir, _: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
    return error.AccessDenied;
}
fn stubDirSetFilePermissions(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.File.Permissions, _: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
    return error.AccessDenied;
}
fn stubDirSetTimestamps(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.SetTimestampsOptions) Io.Dir.SetTimestampsError!void {
    return error.AccessDenied;
}
fn stubDirHardLink(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir, _: []const u8, _: Io.Dir.HardLinkOptions) Io.Dir.HardLinkError!void {
    return error.AccessDenied;
}

fn stubFileStat(_: ?*anyopaque, _: Io.File) Io.File.StatError!Io.File.Stat {
    return error.AccessDenied;
}
fn stubFileLength(_: ?*anyopaque, _: Io.File) Io.File.LengthError!u64 {
    return error.AccessDenied;
}
fn stubFileClose(_: ?*anyopaque, _: []const Io.File) void {}
fn stubFileWritePositional(_: ?*anyopaque, _: Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) Io.File.WritePositionalError!usize {
    return error.AccessDenied;
}
fn stubFileWriteFileStreaming(_: ?*anyopaque, _: Io.File, _: []const u8, _: *Io.File.Reader, _: Io.Limit) Io.File.Writer.WriteFileError!usize {
    return error.AccessDenied;
}
fn stubFileWriteFilePositional(_: ?*anyopaque, _: Io.File, _: []const u8, _: *Io.File.Reader, _: Io.Limit, _: u64) Io.File.WriteFilePositionalError!usize {
    return error.AccessDenied;
}
fn stubFileReadPositional(_: ?*anyopaque, _: Io.File, _: []const []u8, _: u64) Io.File.ReadPositionalError!usize {
    return error.AccessDenied;
}
fn stubFileSeekBy(_: ?*anyopaque, _: Io.File, _: i64) Io.File.SeekError!void {}
fn stubFileSeekTo(_: ?*anyopaque, _: Io.File, _: u64) Io.File.SeekError!void {}
fn stubFileSync(_: ?*anyopaque, _: Io.File) Io.File.SyncError!void {}
fn stubFileIsTty(_: ?*anyopaque, _: Io.File) Io.Cancelable!bool {
    return false;
}
fn stubFileEnableAnsi(_: ?*anyopaque, _: Io.File) Io.File.EnableAnsiEscapeCodesError!void {}
fn stubFileSetLength(_: ?*anyopaque, _: Io.File, _: u64) Io.File.SetLengthError!void {
    return error.AccessDenied;
}
fn stubFileSetOwner(_: ?*anyopaque, _: Io.File, _: ?Io.File.Uid, _: ?Io.File.Gid) Io.File.SetOwnerError!void {
    return error.AccessDenied;
}
fn stubFileSetPermissions(_: ?*anyopaque, _: Io.File, _: Io.File.Permissions) Io.File.SetPermissionsError!void {
    return error.AccessDenied;
}
fn stubFileSetTimestamps(_: ?*anyopaque, _: Io.File, _: Io.File.SetTimestampsOptions) Io.File.SetTimestampsError!void {
    return error.AccessDenied;
}
fn stubFileLock(_: ?*anyopaque, _: Io.File, _: Io.File.Lock) Io.File.LockError!void {}
fn stubFileTryLock(_: ?*anyopaque, _: Io.File, _: Io.File.Lock) Io.File.LockError!bool {
    return true;
}
fn stubFileUnlock(_: ?*anyopaque, _: Io.File) void {}
fn stubFileDowngradeLock(_: ?*anyopaque, _: Io.File) Io.File.DowngradeLockError!void {}
fn stubFileRealPath(_: ?*anyopaque, _: Io.File, _: []u8) Io.File.RealPathError!usize {
    return error.AccessDenied;
}
fn stubFileHardLink(_: ?*anyopaque, _: Io.File, _: Io.Dir, _: []const u8, _: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
    return error.AccessDenied;
}

fn stubMmapCreate(_: ?*anyopaque, _: Io.File, _: Io.File.MemoryMap.CreateOptions) Io.File.MemoryMap.CreateError!Io.File.MemoryMap {
    return error.AccessDenied;
}
fn stubMmapDestroy(_: ?*anyopaque, _: *Io.File.MemoryMap) void {}
fn stubMmapSetLength(_: ?*anyopaque, _: *Io.File.MemoryMap, _: usize) Io.File.MemoryMap.SetLengthError!void {
    return error.AccessDenied;
}
fn stubMmapRead(_: ?*anyopaque, _: *Io.File.MemoryMap) Io.File.ReadPositionalError!void {
    return error.AccessDenied;
}
fn stubMmapWrite(_: ?*anyopaque, _: *Io.File.MemoryMap) Io.File.WritePositionalError!void {
    return error.AccessDenied;
}

fn stubProcExecOpen(_: ?*anyopaque, _: Io.Dir.OpenFileOptions) std.process.OpenExecutableError!Io.File {
    return error.AccessDenied;
}
fn stubProcExecPath(_: ?*anyopaque, _: []u8) std.process.ExecutablePathError!usize {
    return error.AccessDenied;
}
fn stubLockStderr(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    return error.Canceled;
}
fn stubTryLockStderr(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    return null;
}
fn stubProcCurrentPath(_: ?*anyopaque, _: []u8) std.process.CurrentPathError!usize {
    return error.Unexpected;
}
fn stubProcSetCurrentDir(_: ?*anyopaque, _: Io.Dir) std.process.SetCurrentDirError!void {
    return error.AccessDenied;
}
fn stubProcSetCurrentPath(_: ?*anyopaque, _: []const u8) std.process.SetCurrentPathError!void {
    return error.AccessDenied;
}
fn stubProcReplace(_: ?*anyopaque, _: std.process.ReplaceOptions) std.process.ReplaceError {
    return error.AccessDenied;
}
fn stubProcSpawn(_: ?*anyopaque, _: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    return error.AccessDenied;
}
fn stubChildWait(_: ?*anyopaque, _: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    return .{ .exited = 0 };
}
fn stubChildKill(_: ?*anyopaque, _: *std.process.Child) void {}

fn stubProgressParentFile(_: ?*anyopaque) std.Progress.ParentFileError!Io.File {
    return error.UnsupportedOperation;
}
fn stubInheritParentDir(_: ?*anyopaque, _: Io.Dir.Handle) Io.InheritParentHandleError!Io.Dir {
    return error.UnsupportedOperation;
}
fn stubInheritParentFile(_: ?*anyopaque, _: Io.File.Handle, _: Io.File.Flags) Io.InheritParentHandleError!Io.File {
    return error.UnsupportedOperation;
}

fn implNow(_: ?*anyopaque, _: Io.Clock) Io.Timestamp {
    if (is_wasm) {
        const ms = zts_host_now_ms();
        const ns: i96 = @intFromFloat(ms * 1_000_000.0);
        return .{ .nanoseconds = ns };
    }
    fallback_tick_ns += 1_000;
    return .{ .nanoseconds = fallback_tick_ns };
}

fn implClockResolution(_: ?*anyopaque, _: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    return .fromMicroseconds(1);
}

fn implSleep(_: ?*anyopaque, _: Io.Timeout) Io.Cancelable!void {}

fn implRandom(_: ?*anyopaque, buffer: []u8) void {
    if (is_wasm) {
        if (buffer.len > 0) zts_host_fill_random(buffer.ptr, buffer.len);
        return;
    }
    fillRandomFallback(buffer);
}

fn implRandomSecure(_: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    implRandom(null, buffer);
}

fn stubNetListenIp(_: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.ListenOptions) Io.net.IpAddress.ListenError!Io.net.Socket {
    return error.NetworkDown;
}
fn stubNetAccept(_: ?*anyopaque, _: Io.net.Socket.Handle, _: Io.net.Server.AcceptOptions) Io.net.Server.AcceptError!Io.net.Socket {
    return error.NetworkDown;
}
fn stubNetBindIp(_: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
    return error.NetworkDown;
}
fn stubNetConnectIp(_: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    return error.NetworkDown;
}
fn stubNetListenUnix(_: ?*anyopaque, _: *const Io.net.UnixAddress, _: Io.net.UnixAddress.ListenOptions) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
    return error.NetworkDown;
}
fn stubNetConnectUnix(_: ?*anyopaque, _: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
    return error.NetworkDown;
}
fn stubNetSocketPair(_: ?*anyopaque, _: Io.net.Socket.CreatePairOptions) Io.net.Socket.CreatePairError![2]Io.net.Socket {
    return error.OperationUnsupported;
}
fn stubNetWriteFile(_: ?*anyopaque, _: Io.net.Socket.Handle, _: []const u8, _: *Io.File.Reader, _: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
    return error.NetworkDown;
}
fn stubNetClose(_: ?*anyopaque, _: []const Io.net.Socket) void {}
fn stubNetShutdown(_: ?*anyopaque, _: Io.net.Socket.Handle, _: Io.net.ShutdownHow) Io.net.ShutdownError!void {}
fn stubNetIfResolve(_: ?*anyopaque, _: *const Io.net.Interface.Name) Io.net.Interface.Name.ResolveError!Io.net.Interface {
    return error.InterfaceNotFound;
}
fn stubNetIfName(_: ?*anyopaque, _: Io.net.Interface) Io.net.Interface.NameError!Io.net.Interface.Name {
    return error.InterfaceNotFound;
}
fn stubNetLookup(_: ?*anyopaque, _: Io.net.HostName, _: *Io.Queue(Io.net.HostName.LookupResult), _: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    return error.NetworkDown;
}
