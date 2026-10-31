//! Reads the object format and the CPU out of an executable's header (`M5-03`).
//!
//! `zts package` needs the architecture for the Debian `Architecture:` field and for the
//! `demo-0.1.0-x86_64.tar.gz` file name. The host's architecture is the wrong answer whenever
//! `zts build --target aarch64-linux` ran first, so the facts are read from the bytes that are
//! about to be packaged. Only the three container formats Z-Ts can emit are recognised; anything
//! else is refused instead of being mislabelled.

const std = @import("std");
const testing = std.testing;

pub const Format = enum {
    elf,
    macho,
    pe,
};

pub const Binary = struct {
    format: Format,
    arch: std.Target.Cpu.Arch,
};

pub const DetectError = error{
    NotAnExecutable,
    UnknownArchitecture,
};

/// Identifies `bytes` and returns the CPU it was built for.
///
/// The PE path is the reason this module exists: `zts build --target x86_64-windows` writes
/// `zig-out/bin/demo.exe`, and a `.deb` for that binary would be a lie, so the caller uses `format`
/// to refuse the mismatch rather than guessing from the file extension.
pub fn detect(bytes: []const u8) DetectError!Binary {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x7fELF")) {
        if (bytes.len < 20) return error.NotAnExecutable;
        return .{ .format = .elf, .arch = try elfArch(readInt(u16, bytes[18..20])) };
    }
    if (bytes.len >= 4) {
        const magic = readInt(u32, bytes[0..4]);
        if (magic == 0xfeed_facf or magic == 0xfeed_face or magic == 0xcefa_edfe or magic == 0xcffa_edfe) {
            if (bytes.len < 8) return error.NotAnExecutable;
            return .{ .format = .macho, .arch = try machoArch(readInt(u32, bytes[4..8])) };
        }
    }
    if (bytes.len >= 0x40 and std.mem.eql(u8, bytes[0..2], "MZ")) {
        const lfanew = readInt(u32, bytes[0x3C..0x40]);
        if (lfanew + 24 > bytes.len) return error.NotAnExecutable;
        const coff = bytes[lfanew..];
        if (!std.mem.eql(u8, coff[0..4], "PE\x00\x00")) return error.NotAnExecutable;
        return .{ .format = .pe, .arch = try peArch(readInt(u16, coff[4..6])) };
    }
    return error.NotAnExecutable;
}

fn elfArch(machine: u16) DetectError!std.Target.Cpu.Arch {
    return switch (machine) {
        0x03 => .x86,
        0x28 => .arm,
        0x3E => .x86_64,
        0xB7 => .aarch64,
        0xF3 => .riscv64,
        else => error.UnknownArchitecture,
    };
}

fn machoArch(cputype: u32) DetectError!std.Target.Cpu.Arch {
    return switch (cputype) {
        0x0000_0007 => .x86,
        0x0000_000C => .arm,
        0x0100_0007 => .x86_64,
        0x0100_000C => .aarch64,
        else => error.UnknownArchitecture,
    };
}

fn peArch(machine: u16) DetectError!std.Target.Cpu.Arch {
    return switch (machine) {
        0x014C => .x86,
        0x01C4 => .arm,
        0x8664 => .x86_64,
        0xAA64 => .aarch64,
        else => error.UnknownArchitecture,
    };
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

/// Builds a minimal but real PE header: `MZ`, `e_lfanew`, the `PE\0\0` signature and the COFF
/// machine word. Tests use it to prove `detect` never trusts a file extension.
fn syntheticPe(allocator: std.mem.Allocator, machine: u16) ![]u8 {
    const bytes = try allocator.alloc(u8, 0x100);
    @memset(bytes, 0);
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u32, bytes[0x3C..0x40], 0x80, .little);
    @memcpy(bytes[0x80..0x84], "PE\x00\x00");
    std.mem.writeInt(u16, bytes[0x84..0x86], machine, .little);
    return bytes;
}

test "ELF is recognised by its machine word, not by the file name" {
    var header: [64]u8 = @splat(0);
    @memcpy(header[0..4], "\x7fELF");
    std.mem.writeInt(u16, header[18..20], 0xB7, .little); // EM_AARCH64
    const binary = try detect(&header);
    try testing.expectEqual(Format.elf, binary.format);
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, binary.arch);
}

test "Mach-O 64-bit little-endian reads cputype after the magic" {
    var header: [32]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 0xfeed_facf, .little);
    std.mem.writeInt(u32, header[4..8], 0x0100_000C, .little); // CPU_TYPE_ARM64
    const binary = try detect(&header);
    try testing.expectEqual(Format.macho, binary.format);
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, binary.arch);
}

test "PE is found through e_lfanew and reports its machine word" {
    const allocator = testing.allocator;
    const bytes = try syntheticPe(allocator, 0x8664);
    defer allocator.free(bytes);
    const binary = try detect(bytes);
    try testing.expectEqual(Format.pe, binary.format);
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, binary.arch);
}

test "junk, truncated headers and unknown architectures are refused" {
    try testing.expectError(error.NotAnExecutable, detect("#!/bin/sh\nexit 0\n"));
    try testing.expectError(error.NotAnExecutable, detect("\x7fELF"));
    try testing.expectError(error.NotAnExecutable, detect("MZ"));

    var elf: [64]u8 = @splat(0);
    @memcpy(elf[0..4], "\x7fELF");
    std.mem.writeInt(u16, elf[18..20], 0x1234, .little);
    try testing.expectError(error.UnknownArchitecture, detect(&elf));

    // An `MZ` stub without a PE signature (a DOS program) is not a Windows executable.
    var dos: [0x100]u8 = @splat(0);
    dos[0] = 'M';
    dos[1] = 'Z';
    std.mem.writeInt(u32, dos[0x3C..0x40], 0x80, .little);
    @memcpy(dos[0x80..0x84], "NE\x00\x00");
    try testing.expectError(error.NotAnExecutable, detect(&dos));
}
