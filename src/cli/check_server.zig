//! `M5-17` — a persistent Zig compiler server for `zts dev`.
//!
//! A fresh `zig build-exe` costs ~370 ms even with `-fno-emit-bin`: process startup plus semantic
//! analysis of `std` and the module graph. Zig 0.17's self-hosted backend can instead re-analyse
//! only the changed files in **a few milliseconds**, but only while the compiler process stays
//! alive. `--watch` (the build runner's own watcher) panics on this toolchain, so we drive the
//! compiler's `--listen=-` protocol ourselves: one long-lived `zig build-exe` child, one
//! `update` message per Zig edit, read back the error bundle.
//!
//! Everything here is best-effort. Any failure (verbose capture, argv parse, spawn, handshake,
//! protocol) returns an error and `runDev` falls back to `zig build check` for that edit and the
//! rest of the session. A slow correct build is always preferable to a fast wrong one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Tokens that must be present in the captured compiler argv before we trust the split. Paths
/// containing spaces would break a naive whitespace tokenise; the required `-M…=` values are
/// checked for existence by the caller, so a broken split is detected rather than misused.
const required_tokens = [_][]const u8{
    "build-exe",
    "-fno-emit-bin",
    "--listen=-",
    "--zig-lib-dir",
    "--name",
};

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    in_buf: [64 * 1024]u8 = undefined,
    out_buf: [4096]u8 = undefined,
    reader: std.Io.File.Reader = undefined,
    writer: std.Io.File.Writer = undefined,
    client: std.zig.Client = undefined,
    closed: bool = false,

    /// Captures the `check` step's compiler command line, spawns it as a server and verifies the
    /// protocol handshake. `arena` owns the argv strings (freed after `spawn`).
    pub fn start(gpa: Allocator, io: Io, arena: Allocator, dir: []const u8, zig_path: []const u8) !*Server {
        const captured = try std.process.run(gpa, io, .{
            .argv = &.{ zig_path, "build", "check", "--verbose", "--summary", "none" },
            .cwd = .{ .path = dir },
        });
        defer gpa.free(captured.stdout);
        defer gpa.free(captured.stderr);
        if (!captured.term.success()) return error.CaptureFailed;

        const argv = try parseArgv(arena, io, captured.stdout, captured.stderr, dir);

        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .child = undefined,
        };
        self.child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = dir },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer self.close();

        // `reader`/`writer` hold pointers into `self.in_buf` / `self.out_buf`; `self` is heap
        // allocated and never moved, so those pointers stay valid.
        self.reader = self.child.stdout.?.readerStreaming(io, &self.in_buf);
        self.writer = self.child.stdin.?.writerStreaming(io, &self.out_buf);
        self.client = .{ .in = &self.reader.interface, .out = &self.writer.interface };

        const hello = try self.client.receiveMessage();
        const version = try self.client.in.take(hello.bytes_len);
        if (hello.tag != .zig_version or !std.mem.eql(u8, version, builtin.zig_version_string)) {
            return error.BadHandshake;
        }
        // The first `update` does the full semantic analysis and registers the file inputs that
        // later updates diff against. Paying for it here (once, at startup) means the author's
        // first edit is already a millisecond-scale re-check instead of a ~1 s first compile.
        if (!try self.update()) return error.WarmupFailed;
        return self;
    }

    /// Sends one `update` and waits for the end-of-update `error_bundle`. Returns `false` when the
    /// bundle contains compile errors (which are rendered to stderr like a normal `zig build`).
    pub fn update(self: *Server) !bool {
        if (self.closed) return error.ServerClosed;
        try self.client.serveBodylessMessage(.update);
        while (true) {
            const header = try self.client.receiveMessage();
            const body = try self.client.in.take(header.bytes_len);
            switch (header.tag) {
                .error_bundle => {
                    var bundle = try std.zig.Server.allocErrorBundle(self.gpa, body);
                    defer bundle.deinit(self.gpa);
                    const failed = bundle.errorMessageCount() > 0;
                    if (failed) bundle.renderToStderr(self.io, .{}, .auto) catch {};
                    return !failed;
                },
                // `file_system_inputs`, `emit_digest`, `config`, … are consumed above and need no
                // action here; `error_bundle` is the documented end-of-update marker.
                else => {},
            }
        }
    }

    /// Sends `exit`, reaps the child and frees the server. Safe to call after a protocol error.
    pub fn close(self: *Server) void {
        if (self.closed) return;
        self.closed = true;
        self.client.serveBodylessMessage(.exit) catch {};
        if (self.child.stdin) |f| {
            f.close(self.io);
            self.child.stdin = null;
        }
        _ = self.child.wait(self.io) catch {};
        if (self.child.stdout) |f| {
            f.close(self.io);
            self.child.stdout = null;
        }
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// Extracts the `zig build-exe … -fno-emit-bin … --listen=-` command from `--verbose` output and
/// adds the flags the incremental self-hosted backend needs. Verbose output goes to stderr in
/// Zig 0.17, but both streams are searched so a future version that moves it to stdout still works.
pub fn parseArgv(
    arena: Allocator,
    io: Io,
    stdout: []const u8,
    stderr: []const u8,
    dir: []const u8,
) ![]const []const u8 {
    const line = findLine(stdout) orelse findLine(stderr) orelse return error.NoVerboseLine;
    const colon = std.mem.indexOf(u8, line, ": ") orelse return error.NoVerboseLine;
    const command = std.mem.trimStart(u8, line[colon + 2 ..], " \t");

    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (it.next()) |tok| try tokens.append(arena, try arena.dupe(u8, tok));

    if (tokens.items.len < 8) return error.BadArgv;
    if (!std.mem.eql(u8, tokens.items[1], "build-exe")) return error.BadArgv;
    for (required_tokens) |want| {
        var found = false;
        for (tokens.items) |tok| {
            if (std.mem.eql(u8, tok, want)) found = true;
        }
        if (!found) return error.BadArgv;
    }
    // Every `-M…=<path>` must point at a real file relative to the project. This catches a broken
    // whitespace split (a path containing a space) instead of spawning a bogus compiler.
    for (tokens.items) |tok| {
        if (!std.mem.startsWith(u8, tok, "-M")) continue;
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
        const path = tok[eq + 1 ..];
        if (path.len == 0) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, path });
        Io.Dir.cwd().access(io, full, .{}) catch return error.BadArgv;
    }

    // `-fno-llvm` (the Debug default) plus `-fincremental` is the combination that keeps the
    // analysed module graph in memory and re-checks only changed files on the next `update`.
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try out.append(arena, tokens.items[0]);
    try out.append(arena, tokens.items[1]);
    try out.append(arena, "-fno-llvm");
    try out.append(arena, "-fincremental");
    for (tokens.items[2..]) |tok| try out.append(arena, tok);
    return out.items;
}

fn findLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "build-exe") == null) continue;
        if (std.mem.indexOf(u8, line, "-fno-emit-bin") == null) continue;
        if (std.mem.indexOf(u8, line, "--listen=-") == null) continue;
        return line;
    }
    return null;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "parseArgv extracts the check command and adds incremental flags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Use the real repository sources as the module paths so the existence check passes.
    const verbose = try std.fmt.allocPrint(arena, "info(verbose): /usr/local/bin/zig build-exe -Odebug --dep embedded_frontend " ++
        "-Mroot=src/cli/main.zig -fno-emit-bin --cache-dir .zig-cache " ++
        "--global-cache-dir /home/user/.cache/zig --name app_check " ++
        "--zig-lib-dir /tmp/zig/lib/ --listen=-\n", .{});
    const argv = try parseArgv(arena, testing.io, "", verbose, ".");
    try testing.expectEqualStrings("build-exe", argv[1]);
    try testing.expectEqualStrings("-fno-llvm", argv[2]);
    try testing.expectEqualStrings("-fincremental", argv[3]);
    try testing.expectEqualStrings("--listen=-", argv[argv.len - 1]);
    var has_no_emit = false;
    var has_root = false;
    for (argv) |tok| {
        if (std.mem.eql(u8, tok, "-fno-emit-bin")) has_no_emit = true;
        if (std.mem.eql(u8, tok, "-Mroot=src/cli/main.zig")) has_root = true;
    }
    try testing.expect(has_no_emit);
    try testing.expect(has_root);
}

test "parseArgv rejects output without a compiler command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.NoVerboseLine, parseArgv(arena_state.allocator(), testing.io, "", "OK build-tools embed files=1\n", "."));
}
