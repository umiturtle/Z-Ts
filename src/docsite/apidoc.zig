//! `M5-07` — API reference generator: Zig sources → `docs/api/**/*.html`.
//!
//! The site had a reference problem: the only way to learn `zts_rpc.Schema` was to open the
//! sources on GitHub. This module produces a `zig doc`-shaped reference from the sources
//! themselves, so the published site answers "what is the signature, what does it do, where do I
//! call it from" without leaving the page:
//!
//! ```text
//! docs/api/index.html                  every package + an A–Z index of every public declaration
//! docs/api/<package>/index.html        one package: modules, counts, documentation coverage
//! docs/api/<package>/<module>.html     one source file: `//!` text, then every declaration
//! ```
//!
//! What is extracted, per module:
//! * the `//!` header (rendered as Markdown),
//! * every top-level `pub` declaration with its `///` documentation (also rendered as Markdown,
//!   so `# Parameters` / `# Errors` sections and fenced examples look like the rest of the site),
//! * the members of a `pub const … = struct/enum/union/opaque { … }` body, one level deep,
//! * the 1-based source line, so each declaration links back to GitHub.
//!
//! This is deliberately *not* a Zig parser: it is a line scanner that tracks string/char literals
//! and brace depth, because all it needs is the shape of a declaration. Type checking is what
//! `zig build test` is for — a wrong signature here is caught by `verifyAssets`-style link checks
//! and by a human reading the page, not by re-implementing semantic analysis.

const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown = @import("markdown.zig");

pub const Error = Allocator.Error || error{WriteFailed};

pub const Kind = enum { function, constant, variable, type_, namespace, field };

pub fn kindGlyph(kind: Kind) []const u8 {
    return switch (kind) {
        .function => "fn",
        .constant => "const",
        .variable => "var",
        .type_ => "type",
        .namespace => "namespace",
        .field => "field",
    };
}

pub const Decl = struct {
    kind: Kind,
    name: []const u8,
    /// Declaration header with the body removed, whitespace collapsed:
    /// `pub fn setTitle(ctx: *Ctx, args: Args) (HostError || error{MissingContext})!void`.
    signature: []const u8,
    /// Raw `///` text (empty when the declaration is undocumented).
    doc: []const u8,
    /// 1-based line of the declaration in its source file.
    line: usize,
    members: []const Decl = &.{},
};

/// Who a module is *for*. The reference lists every file, but a reader learning the library must not
/// have to walk past 42 GTK `extern` declarations to find `Engine`. Internal modules are still
/// published (they are part of the source, and an embedder occasionally needs them) but they are
/// separated in the index, excluded from the coverage figure and kept out of the site search.
pub const Audience = enum { user, internal };

/// File names that are plumbing rather than API: hand-written FFI tables and contract tests.
/// Kept as an explicit list (not a heuristic) so the split is reviewable.
const internal_modules = [_][]const u8{
    "gtk_bindings.zig",
    "win32.zig",
    "webview2_com.zig",
    "webview2_loader.zig",
    "windows_util.zig",
};

pub fn audienceOf(path: []const u8) Audience {
    if (std.mem.endsWith(u8, path, "_test.zig")) return .internal;
    const base = std.fs.path.basename(path);
    for (internal_modules) |name| {
        if (std.mem.eql(u8, base, name)) return .internal;
    }
    return .user;
}

pub const Module = struct {
    /// Repository path (`src/tauri/fs/mod.zig`).
    path: []const u8,
    /// Basename without `.zig` (`mod`, `codec`, …).
    name: []const u8,
    /// Path relative to the package root, without `.zig` (`fs/mod`, `codec`).
    ///
    /// Several packages have one `mod.zig` per plugin directory, so the *basename* is not unique
    /// inside a package: using it as the page name silently overwrote
    /// `zts_tauri/mod.html` with `zts_tauri/tray/mod.zig`.
    slug: []const u8 = "",
    /// `//!` header text.
    doc: []const u8,
    decls: []const Decl,
    /// `.internal` for FFI tables and contract tests — see [`audienceOf`].
    audience: Audience = .user,
};

pub const PackageSpec = struct {
    name: []const u8,
    root: []const u8,
    blurb: []const u8,
};

pub const Package = struct {
    spec: PackageSpec,
    modules: []const Module,
};

pub const Page = struct {
    /// Site-relative path (`docs/api/zts_rpc/mod.html`).
    href: []const u8,
    title: []const u8,
    body: []const u8,
    /// Tag-free text for the site search (`decl names + signatures + module doc`).
    plain: []const u8 = "",
    /// Links the Markdown renderer saw in the documentation comments, so the site-wide link check
    /// covers the API pages too.
    links: []const markdown.Link = &.{},
};

/// The public surface, mirroring the modules declared in `build.zig` (one root file per package).
/// The file lists come from the root's relative `@import("….zig")` graph, not from a hand-written
/// table, so a new file inside `src/rpc/` shows up without editing this list.
pub const packages = [_]PackageSpec{
    .{
        .name = "zts_foundation",
        .root = "src/core/foundation.zig",
        .blurb = "ゼロ依存のランタイム土台 — `OwnedBytes` / `HandlePool` / `RingQueue` / `geometry` / `glob` / `url` / `html_escape` / `OutgoingResponse`",
    },
    .{
        .name = "zts_web",
        .root = "src/core/web.zig",
        .blurb = "埋め込みアセット配信・RFC 9110 `206` Range・MIME・CSP ビルダ（ウィンドウや RPC に依存しない）",
    },
    .{
        .name = "zts_core",
        .root = "src/core/mod.zig",
        .blurb = "デスクトップ `Host` VTable と `zts_foundation` / `zts_web` の再エクスポート",
    },
    .{
        .name = "zts_rpc",
        .root = "src/rpc/mod.zig",
        .blurb = "`comptime` RPC スキーマ・JSON/バイナリ codec・厳格な TypeScript 生成（`tsgen`）",
    },
    .{
        .name = "zts_bridge",
        .root = "src/bridge/mod.zig",
        .blurb = "HTTP/1.1 + SSE の Live Preview サーバ（三重 CSRF・`206` Range）",
    },
    .{
        .name = "zts_webview",
        .root = "src/webview/mod.zig",
        .blurb = "GTK3 / macOS / Win32 のネイティブ WebView、`HeadlessMock`、安定 C ABI",
    },
    .{
        .name = "zts_tauri",
        .root = "src/tauri/mod.zig",
        .blurb = "Tauri v2 ワイヤプロトコル、`Channel(T)`、標準プラグイン（fs / dialog / clipboard / menu / tray）",
    },
    .{
        .name = "zts_wasm",
        .root = "src/wasm/mod.zig",
        .blurb = "`wasm32-freestanding` ランタイム — `WasmHost` / `Instance` / C ABI exports",
    },
    .{
        .name = "zts_ssg",
        .root = "src/ssg/mod.zig",
        .blurb = "双方向の静的サイト生成 — フロントエンド埋め込みとサーバ不要 `dist/` エクスポータ",
    },
    .{
        .name = "z_ts",
        .root = "src/root.zig",
        .blurb = "全レイヤを再エクスポートするアンブレラ（`BridgeHost` / `WebviewHost` / `DesktopRuntime`）",
    },
};

pub const repo_blob_base = "https://github.com/umiturtle/Z-Ts/blob/main/";

// ---------------------------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------------------------

pub fn splitLines(arena: Allocator, text: []const u8) Error![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try list.append(arena, if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line);
    }
    return list.toOwnedSlice(arena);
}

/// Net brace change of one source line, ignoring string literals, character literals and comments.
pub fn braceDelta(line: []const u8) i32 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return 0;
    if (std.mem.startsWith(u8, trimmed, "//")) return 0;
    // Continuation lines of a multi-line string literal start with `\\`.
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return 0;

    const State = enum { code, string, char };
    var state: State = .code;
    var escaped = false;
    var delta: i32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        switch (state) {
            .string => {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == '"') {
                    state = .code;
                }
            },
            .char => {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == '\'') {
                    state = .code;
                }
            },
            .code => switch (ch) {
                '"' => state = .string,
                '\'' => state = .char,
                '/' => {
                    if (i + 1 < line.len and line[i + 1] == '/') return delta;
                },
                '{' => delta += 1,
                '}' => delta -= 1,
                else => {},
            },
        }
    }
    return delta;
}

pub const DeclStart = struct {
    kind: Kind,
    name: []const u8,
};

/// Recognises a `pub …` declaration header. `trimmed` must be left-trimmed.
pub fn declStart(trimmed: []const u8) ?DeclStart {
    if (!std.mem.startsWith(u8, trimmed, "pub ")) return null;
    var rest = std.mem.trimStart(u8, trimmed["pub ".len..], " \t");

    const modifiers = [_][]const u8{ "inline ", "extern ", "export ", "threadlocal ", "comptime " };
    var changed = true;
    while (changed) {
        changed = false;
        for (modifiers) |modifier| {
            if (std.mem.startsWith(u8, rest, modifier)) {
                rest = std.mem.trimStart(u8, rest[modifier.len..], " \t");
                changed = true;
            }
        }
    }

    if (std.mem.startsWith(u8, rest, "usingnamespace")) {
        return .{ .kind = .namespace, .name = "usingnamespace" };
    }

    const record_test = struct {
        fn take(rest_in: []const u8, keyword: []const u8) ?[]const u8 {
            if (!std.mem.startsWith(u8, rest_in, keyword)) return null;
            const after = rest_in[keyword.len..];
            if (after.len == 0) return null;
            const first = after[0];
            if (first != ' ' and first != '\t') return null;
            const t = std.mem.trimStart(u8, after, " \t");
            if (t.len == 0) return null;
            var end: usize = 0;
            if (t[0] == '@') {
                // Quoted identifier: `@"type"`.
                end = 1;
                if (end < t.len and t[end] == '"') {
                    if (std.mem.findScalarPos(u8, t, end + 1, '"')) |close| {
                        end = close + 1;
                    } else return null;
                } else return null;
            } else {
                while (end < t.len and isIdentChar(t[end])) end += 1;
                if (end == 0) return null;
            }
            return t[0..end];
        }
    };

    if (record_test.take(rest, "fn")) |name| return .{ .kind = .function, .name = name };
    if (record_test.take(rest, "var")) |name| return .{ .kind = .variable, .name = name };
    if (record_test.take(rest, "const")) |name| {
        // `pub const X = struct { … }` (and friends) is a type; anything else is a value.
        // `name` points into `rest` after `const`, so locate it again instead of assuming an
        // offset (the keyword is followed by at least one space).
        const after_keyword = rest["const".len..];
        const offset = std.mem.find(u8, after_keyword, name) orelse return .{ .kind = .constant, .name = name };
        var tail = std.mem.trimStart(u8, after_keyword[offset + name.len ..], " \t");
        if (tail.len > 0 and tail[0] == '=') {
            tail = std.mem.trimStart(u8, tail[1..], " \t");
            for ([_][]const u8{ "struct", "enum", "union", "opaque" }) |container| {
                if (!std.mem.startsWith(u8, tail, container)) continue;
                // `structOf(…)` is a function call, not a container declaration.
                if (tail.len > container.len and isIdentChar(tail[container.len])) continue;
                return .{ .kind = .type_, .name = name };
            }
        }
        return .{ .kind = .constant, .name = name };
    }
    return null;
}

/// `name: Type = default,` (struct/union field) or `name = value,` / `name,` (enum case).
/// Struct fields have no `pub` keyword in Zig, so the reference has to pick them up separately
/// from declarations.
pub fn fieldStart(trimmed: []const u8) ?DeclStart {
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "//")) return null;
    if (std.mem.startsWith(u8, trimmed, "pub ")) return null;

    var end: usize = 0;
    if (trimmed[0] == '@') {
        if (trimmed.len < 2 or trimmed[1] != '"') return null;
        if (std.mem.findScalarPos(u8, trimmed, 2, '"')) |close| {
            end = close + 1;
        } else return null;
    } else {
        if (!isIdentChar(trimmed[0]) or std.ascii.isDigit(trimmed[0])) return null;
        while (end < trimmed.len and isIdentChar(trimmed[end])) end += 1;
    }
    const name = trimmed[0..end];

    const rest = std.mem.trimStart(u8, trimmed[end..], " \t");
    if (rest.len == 0) return null;
    switch (rest[0]) {
        // A field type: `count: u32 = 0,`
        ':', ',' => return .{ .kind = .field, .name = name },
        // An enum case with an explicit value: `Fast = 3,`
        '=' => return .{ .kind = .field, .name = name },
        else => return null,
    }
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Collects the declaration header starting at `start`, stopping at the body (`{` / `;`) at
/// bracket depth zero, and collapses it onto one line.
pub fn signatureOf(arena: Allocator, lines: []const []const u8, start: usize, limit: usize) Error![]const u8 {
    var raw: std.Io.Writer.Allocating = .init(arena);
    defer raw.deinit();
    const writer = &raw.writer;

    const State = enum { code, string, char };
    var state: State = .code;
    var escaped = false;
    var parens: i32 = 0;
    var brackets: i32 = 0;
    var braces: i32 = 0;
    var done = false;

    var li = start;
    while (li < lines.len and li < start + limit and !done) : (li += 1) {
        const line = lines[li];
        if (li != start) try writer.writeByte(' ');
        var i: usize = 0;
        // A `//` comment ends the *line*, not the declaration: parameters continue below it.
        var skip_line = false;
        while (i < line.len and !done and !skip_line) : (i += 1) {
            const ch = line[i];
            switch (state) {
                .string => {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        state = .code;
                    }
                    try writer.writeByte(ch);
                },
                .char => {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '\'') {
                        state = .code;
                    }
                    try writer.writeByte(ch);
                },
                .code => switch (ch) {
                    '"' => {
                        state = .string;
                        try writer.writeByte(ch);
                    },
                    '\'' => {
                        state = .char;
                        try writer.writeByte(ch);
                    },
                    '/' => {
                        if (i + 1 < line.len and line[i + 1] == '/') {
                            skip_line = true;
                        } else {
                            try writer.writeByte(ch);
                        }
                    },
                    '(' => {
                        parens += 1;
                        try writer.writeByte(ch);
                    },
                    ')' => {
                        parens -= 1;
                        try writer.writeByte(ch);
                    },
                    '[' => {
                        brackets += 1;
                        try writer.writeByte(ch);
                    },
                    ']' => {
                        brackets -= 1;
                        try writer.writeByte(ch);
                    },
                    '{' => {
                        if (parens == 0 and brackets == 0 and braces == 0) {
                            done = true; // the body starts: the header is complete
                        } else {
                            braces += 1;
                            try writer.writeByte(ch);
                        }
                    },
                    '}' => {
                        braces -= 1;
                        try writer.writeByte(ch);
                    },
                    ';' => {
                        if (parens == 0 and brackets == 0 and braces == 0) {
                            done = true;
                        } else {
                            try writer.writeByte(ch);
                        }
                    },
                    else => try writer.writeByte(ch),
                },
            }
        }
    }

    return collapseWhitespace(arena, raw.written());
}

/// `count: u32 = 0,` -> `count: u32 = 0` (one line, trailing comma dropped).
pub fn fieldSignature(arena: Allocator, trimmed: []const u8) Error![]const u8 {
    var line = trimmed;
    if (std.mem.findScalarPos(u8, line, 0, ';')) |semi| line = line[0..semi];
    if (std.mem.findScalarPos(u8, line, 0, '/')) |slash| {
        if (slash + 1 < line.len and line[slash + 1] == '/') line = line[0..slash];
    }
    line = std.mem.trimEnd(u8, line, " \t\r");
    if (line.len > 0 and line[line.len - 1] == ',') line = line[0 .. line.len - 1];
    return collapseWhitespace(arena, line);
}

pub fn collapseWhitespace(arena: Allocator, text: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const writer = &out.writer;
    var pending_space = false;
    for (text) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            pending_space = out.written().len > 0 or pending_space;
            continue;
        }
        if (pending_space and out.written().len > 0) try writer.writeByte(' ');
        pending_space = false;
        try writer.writeByte(ch);
    }
    return out.toOwnedSlice();
}

fn stripDocPrefix(line: []const u8, prefix: []const u8) []const u8 {
    var rest = line[prefix.len..];
    if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    return rest;
}

fn docCommentAbove(arena: Allocator, lines: []const []const u8, at: usize, floor: usize) Error![]const u8 {
    var collected: std.ArrayListUnmanaged([]const u8) = .empty;
    var j = at;
    while (j > floor) {
        j -= 1;
        const trimmed = std.mem.trimStart(u8, lines[j], " \t");
        if (!std.mem.startsWith(u8, trimmed, "///")) break;
        try collected.append(arena, stripDocPrefix(trimmed, "///"));
    }
    if (collected.items.len == 0) return "";
    std.mem.reverse([]const u8, collected.items);
    return std.mem.join(arena, "\n", collected.items);
}

fn moduleDoc(arena: Allocator, lines: []const []const u8) Error![]const u8 {
    var collected: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen_blank = false;
    for (lines) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) {
            if (collected.items.len == 0) continue; // leading copyright/blank noise
            if (seen_blank) continue;
            seen_blank = true;
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, "//!")) break;
        seen_blank = false;
        try collected.append(arena, stripDocPrefix(trimmed, "//!"));
    }
    if (collected.items.len == 0) return "";
    return std.mem.join(arena, "\n", collected.items);
}

/// `src/tauri/fs/mod.zig` with package root `src/tauri/mod.zig` → `fs/mod`.
pub fn moduleSlug(arena: Allocator, package_root: []const u8, module_path: []const u8) Error![]const u8 {
    const dir = std.fs.path.dirname(package_root) orelse "";
    var rel = module_path;
    if (dir.len > 0 and std.mem.startsWith(u8, module_path, dir)) {
        rel = std.mem.trimStart(u8, module_path[dir.len..], "/");
    }
    if (std.mem.endsWith(u8, rel, ".zig")) rel = rel[0 .. rel.len - 4];
    _ = arena;
    return rel;
}

/// Parses one source file into a [`Module`]. Pure: same bytes in, same module out.
pub fn scanModule(arena: Allocator, path: []const u8, source: []const u8) Error!Module {
    const lines = try splitLines(arena, source);

    const depth = try arena.alloc(i32, lines.len);
    var running: i32 = 0;
    for (lines, 0..) |line, i| {
        depth[i] = running;
        running += braceDelta(line);
    }

    const base = std.fs.path.basename(path);
    return .{
        .path = path,
        .name = if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base,
        .doc = try moduleDoc(arena, lines),
        .decls = try scanDecls(arena, lines, depth, 0, lines.len, 0),
    };
}

fn scanDecls(
    arena: Allocator,
    lines: []const []const u8,
    depth: []const i32,
    from: usize,
    to: usize,
    at: i32,
) Error![]const Decl {
    var list: std.ArrayListUnmanaged(Decl) = .empty;
    var i = from;
    while (i < to) : (i += 1) {
        if (depth[i] != at) continue;
        const trimmed = std.mem.trimStart(u8, lines[i], " \t");
        const start = declStart(trimmed) orelse blk: {
            // Members of a type body: public struct fields and enum cases have no `pub`.
            if (at == 0) continue;
            break :blk fieldStart(trimmed) orelse continue;
        };

        var members: []const Decl = &.{};
        if (start.kind == .type_ or start.kind == .namespace) {
            var end = i + 1;
            while (end < to and depth[end] > at) end += 1;
            members = try scanDecls(arena, lines, depth, i + 1, end, at + 1);
        }

        const signature = if (start.kind == .field)
            try fieldSignature(arena, trimmed)
        else
            try signatureOf(arena, lines, i, 24);

        try list.append(arena, .{
            .kind = start.kind,
            .name = start.name,
            .signature = signature,
            .doc = try docCommentAbove(arena, lines, i, from),
            .line = i + 1,
            .members = members,
        });
    }
    return list.toOwnedSlice(arena);
}

/// Every relative `@import("….zig")` in the file (module imports such as `@import("zts_rpc")` are
/// other packages and are deliberately skipped).
pub fn importsOf(arena: Allocator, source: []const u8) Error![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    const needle = "@import(\"";
    var cursor: usize = 0;
    while (std.mem.find(u8, source[cursor..], needle)) |offset| {
        const start = cursor + offset + needle.len;
        const end = std.mem.findScalarPos(u8, source, start, '"') orelse break;
        const spec = source[start..end];
        if (std.mem.endsWith(u8, spec, ".zig")) try list.append(arena, spec);
        cursor = end + 1;
    }
    return list.toOwnedSlice(arena);
}

/// Joins a repository-relative directory with a relative path, resolving `.` and `..`.
pub fn joinPath(arena: Allocator, base_dir: []const u8, rel: []const u8) Error![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, base_dir, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        try parts.append(arena, part);
    }
    var rel_it = std.mem.splitScalar(u8, rel, '/');
    while (rel_it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(arena, part);
    }
    return std.mem.join(arena, "/", parts.items);
}

pub const collect_error = Error || std.Io.Dir.ReadFileError;

/// Follows the root file's relative import graph and returns one [`Module`] per source file,
/// sorted by path so the output is deterministic.
pub fn collectPackage(arena: Allocator, io: std.Io, spec: PackageSpec) !Package {
    const cwd = std.Io.Dir.cwd();

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    try queue.append(arena, spec.root);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var modules: std.ArrayListUnmanaged(Module) = .empty;

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const path = queue.items[head];
        if (seen.contains(path)) continue;
        try seen.put(arena, path, {});

        const source = cwd.readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |err| {
            std.debug.print("docsite: cannot read {s}: {t}\n", .{ path, err });
            return err;
        };
        var module = try scanModule(arena, path, source);
        module.slug = try moduleSlug(arena, spec.root, path);
        module.audience = audienceOf(path);
        try modules.append(arena, module);

        const dir = std.fs.path.dirname(path) orelse "";
        for (try importsOf(arena, source)) |spec_path| {
            try queue.append(arena, try joinPath(arena, dir, spec_path));
        }
    }

    std.mem.sort(Module, modules.items, {}, struct {
        fn lessThan(_: void, a: Module, b: Module) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    return .{ .spec = spec, .modules = try modules.toOwnedSlice(arena) };
}

/// `pub const Ctx = ctx.Ctx;` or `pub const codec = @import("codec.zig");` — the documentation
/// lives where the target is declared, so a re-export is not "undocumented", it is a pointer.
pub fn isAlias(decl: Decl) bool {
    if (decl.kind != .constant) return false;
    const eq = std.mem.findScalar(u8, decl.signature, '=') orelse return false;
    const value = std.mem.trim(u8, decl.signature[eq + 1 ..], " \t;");
    if (value.len == 0) return false;
    if (std.mem.startsWith(u8, value, "@import(")) return true;
    // A re-export names something (`types.WindowId`, `Ctx`); a literal (`1`, `1 << 0`, `"x"`) does
    // not. Without the leading-character check `pub const limit = 16` looked like an alias and was
    // silently dropped from the coverage figure.
    if (!isIdentStart(value[0])) return false;
    for (value) |ch| {
        if (!isIdentChar(ch) and ch != '.') return false;
    }
    return true;
}

/// Documentation-comment coverage of a package.
///
/// `total` / `documented` count the **user-facing** modules only: a percentage that includes 104
/// hand-written FFI declarations says nothing about whether a reader can learn the API, and it
/// would push authors to paste `///` lines onto `HWND_TOPMOST`. Internal modules are reported
/// separately so the number stays honest in both directions.
pub const Coverage = struct {
    total: usize = 0,
    documented: usize = 0,
    internal_total: usize = 0,
    internal_documented: usize = 0,

    pub fn add(self: *Coverage, other: Coverage) void {
        self.total += other.total;
        self.documented += other.documented;
        self.internal_total += other.internal_total;
        self.internal_documented += other.internal_documented;
    }
};

pub fn coverageOf(pkg: Package) Coverage {
    var total: usize = 0;
    var documented: usize = 0;
    var internal_total: usize = 0;
    var internal_documented: usize = 0;
    for (pkg.modules) |module| {
        const internal = module.audience == .internal;
        for (module.decls) |decl| {
            // Re-exports point at documentation that lives elsewhere; counting them as
            // "undocumented" would make the number meaningless.
            if (!isAlias(decl)) {
                if (internal) {
                    internal_total += 1;
                    if (decl.doc.len > 0) internal_documented += 1;
                } else {
                    total += 1;
                    if (decl.doc.len > 0) documented += 1;
                }
            }
            for (decl.members) |member| {
                if (internal) {
                    internal_total += 1;
                    if (member.doc.len > 0) internal_documented += 1;
                } else {
                    total += 1;
                    if (member.doc.len > 0) documented += 1;
                }
            }
        }
    }
    return .{
        .total = total,
        .documented = documented,
        .internal_total = internal_total,
        .internal_documented = internal_documented,
    };
}

pub fn percent(part: usize, whole: usize) usize {
    if (whole == 0) return 100;
    return (part * 100) / whole;
}

// ---------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(ch),
    };
}

const keywords = std.StaticStringMap(void).initComptime(.{
    .{"pub"},      .{"fn"},        .{"const"},    .{"var"},         .{"struct"},  .{"enum"},
    .{"union"},    .{"opaque"},    .{"inline"},   .{"extern"},      .{"export"},  .{"threadlocal"},
    .{"comptime"}, .{"error"},     .{"anytype"},  .{"noreturn"},    .{"type"},    .{"callconv"},
    .{"align"},    .{"allowzero"}, .{"volatile"}, .{"linksection"}, .{"noalias"}, .{"usingnamespace"},
});

const primitives = std.StaticStringMap(void).initComptime(.{
    .{"void"},   .{"bool"},    .{"usize"},  .{"isize"},        .{"anyopaque"},      .{"c_int"}, .{"c_uint"},
    .{"u8"},     .{"u16"},     .{"u32"},    .{"u64"},          .{"u128"},           .{"i8"},    .{"i16"},
    .{"i32"},    .{"i64"},     .{"i128"},   .{"f16"},          .{"f32"},            .{"f64"},   .{"f128"},
    .{"c_long"}, .{"c_ulong"}, .{"c_char"}, .{"comptime_int"}, .{"comptime_float"},
});

/// Zig-doc-ish colouring: keywords, primitives and `CamelCase` type names stand out, everything
/// else stays plain. Purely presentational — the escaped text is the source text, byte for byte.
pub fn writeSignature(writer: *std.Io.Writer, signature: []const u8) !void {
    var i: usize = 0;
    while (i < signature.len) {
        const ch = signature[i];
        if (isIdentChar(ch) and !std.ascii.isDigit(ch)) {
            var end = i;
            while (end < signature.len and isIdentChar(signature[end])) end += 1;
            const word = signature[i..end];
            const class: ?[]const u8 = if (keywords.has(word))
                "k"
            else if (primitives.has(word))
                "t"
            else if (std.ascii.isUpper(word[0]))
                "t"
            else
                null;
            if (class) |cls| {
                try writer.print("<span class=\"zk-{s}\">{s}</span>", .{ cls, word });
            } else {
                try writeEscaped(writer, word);
            }
            i = end;
            continue;
        }
        if (std.ascii.isDigit(ch)) {
            var end = i;
            while (end < signature.len and (std.ascii.isAlphanumeric(signature[end]) or signature[end] == '_' or signature[end] == '.')) end += 1;
            try writer.print("<span class=\"zk-n\">{s}</span>", .{signature[i..end]});
            i = end;
            continue;
        }
        try writeEscaped(writer, signature[i .. i + 1]);
        i += 1;
    }
}

/// Documentation comments are written next to the code, so they link to *files* (`codec.zig`,
/// `linux.zig`) rather than to pages of the site. Those links are resolved against the source file
/// that contains the comment and pointed at GitHub; everything else is left to the site-wide link
/// check.
fn sourceLinkTarget(arena: Allocator, source_path: []const u8, href: []const u8) Error!?[]const u8 {
    if (href.len == 0) return null;
    if (href[0] == '#') return null;
    if (std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://")) return null;
    if (std.mem.startsWith(u8, href, "mailto:") or std.mem.startsWith(u8, href, "//")) return null;

    const ext = std.fs.path.extension(href);
    const known = [_][]const u8{ ".zig", ".m", ".h", ".c", ".zon", ".json", ".ts", ".js", ".css", ".md", ".txt", ".sh" };
    var rewrite = false;
    for (known) |candidate| {
        if (std.mem.eql(u8, ext, candidate)) rewrite = true;
    }
    if (!rewrite) return null;

    const dir = std.fs.path.dirname(source_path) orelse "";
    const resolved = try joinPath(arena, dir, href);
    return try std.fmt.allocPrint(arena, "{s}{s}", .{ repo_blob_base, resolved });
}

/// Escapes text but turns `` `x` `` into `<code>x</code>`: the package blurbs are one-liners in the
/// source, not full Markdown documents, and they must not render raw backticks.
pub fn writeInlineCode(writer: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            const close = std.mem.findScalarPos(u8, text, i + 1, '`') orelse {
                try writeEscaped(writer, text[i..]);
                return;
            };
            try writer.writeAll("<code>");
            try writeEscaped(writer, text[i + 1 .. close]);
            try writer.writeAll("</code>");
            i = close + 1;
            continue;
        }
        var end = i;
        while (end < text.len and text[end] != '`') end += 1;
        try writeEscaped(writer, text[i..end]);
        i = end;
    }
}

fn renderDocMarkdown(
    arena: Allocator,
    text: []const u8,
    page: []const u8,
    source_path: []const u8,
    links: *std.ArrayListUnmanaged(markdown.Link),
) Error![]const u8 {
    if (text.len == 0) return "";
    const first = try markdown.render(arena, text, .{ .page = page });

    var rewrites: std.ArrayListUnmanaged(markdown.Rewrite) = .empty;
    for (first.links) |link| {
        if (try sourceLinkTarget(arena, source_path, link.href)) |target| {
            try rewrites.append(arena, .{ .page = page, .href = link.href, .to = target });
        }
    }

    if (rewrites.items.len == 0) {
        for (first.links) |link| try links.append(arena, link);
        return first.html;
    }

    const second = try markdown.render(arena, text, .{ .page = page, .rewrites = rewrites.items });
    for (second.links) |link| try links.append(arena, link);
    return second.html;
}

/// One declaration (plus its members) as an HTML section.
fn renderDecl(
    arena: Allocator,
    writer: *std.Io.Writer,
    decl: Decl,
    source_path: []const u8,
    page: []const u8,
    links: *std.ArrayListUnmanaged(markdown.Link),
) Error!void {
    try writer.print("<section class=\"api-decl\" id=\"{s}\">\n", .{decl.name});
    try writer.writeAll("<h2 class=\"api-sig\"><span class=\"api-kind\">");
    try writer.writeAll(kindGlyph(decl.kind));
    try writer.writeAll("</span><code>");
    try writeSignature(writer, decl.signature);
    try writer.writeAll("</code><a class=\"api-line\" href=\"");
    try writer.print("{s}{s}#L{d}\" title=\"ソースを開く\">L{d}</a></h2>\n", .{ repo_blob_base, source_path, decl.line, decl.line });

    if (decl.doc.len > 0) {
        try writer.writeAll("<div class=\"api-doc prose\">");
        try writer.writeAll(try renderDocMarkdown(arena, decl.doc, page, source_path, links));
        try writer.writeAll("</div>\n");
    } else if (isAlias(decl)) {
        try writer.writeAll("<p class=\"api-reexport\">再エクスポート（ドキュメントは定義元にあります）</p>\n");
    } else {
        try writer.writeAll("<p class=\"api-undoc\">ドキュメントコメント未記述 — シグネチャは上記のとおりです。</p>\n");
    }

    if (decl.members.len > 0) {
        try writer.writeAll("<div class=\"api-members\">\n");
        for (decl.members) |member| {
            const anchor = try std.fmt.allocPrint(arena, "{s}.{s}", .{ decl.name, member.name });
            try writer.print("<div class=\"api-member\" id=\"{s}\">\n<div class=\"api-member-sig\"><span class=\"api-kind\">{s}</span><code>", .{ anchor, kindGlyph(member.kind) });
            try writeSignature(writer, member.signature);
            try writer.print("</code><a class=\"api-line\" href=\"{s}{s}#L{d}\">L{d}</a></div>\n", .{ repo_blob_base, source_path, member.line, member.line });
            if (member.doc.len > 0) {
                try writer.writeAll("<div class=\"api-doc prose\">");
                try writer.writeAll(try renderDocMarkdown(arena, member.doc, page, source_path, links));
                try writer.writeAll("</div>\n");
            }
            try writer.writeAll("</div>\n");
        }
        try writer.writeAll("</div>\n");
    }

    try writer.writeAll("</section>\n");
}

pub fn moduleHref(arena: Allocator, package_name: []const u8, module: Module) Error![]const u8 {
    return std.fmt.allocPrint(arena, "docs/api/{s}/{s}.html", .{ package_name, module.slug });
}

pub fn packageHref(arena: Allocator, package_name: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(arena, "docs/api/{s}/index.html", .{package_name});
}

fn userModuleCount(pkg: Package) usize {
    var count: usize = 0;
    for (pkg.modules) |module| {
        if (module.audience == .user) count += 1;
    }
    return count;
}

/// One `<li>` of a package's module list, shared by the public block and the collapsed internal one.
fn renderModuleEntry(
    arena: Allocator,
    writer: *std.Io.Writer,
    module: Module,
    page: []const u8,
    source_path: []const u8,
    links: *std.ArrayListUnmanaged(markdown.Link),
) Error!void {
    const summary = try firstParagraph(arena, module.doc);
    try writer.print("<li><a href=\"{s}.html\">{s}.zig</a> <span class=\"api-count\">{d}</span>", .{
        module.slug, module.slug, declCount(module),
    });
    if (summary.len > 0) {
        try writer.writeAll("<div class=\"api-summary prose\">");
        try writer.writeAll(try renderDocMarkdown(arena, summary, page, source_path, links));
        try writer.writeAll("</div>");
    }
    try writer.writeAll("</li>\n");
}

/// Builds every API page: the A–Z index, one page per package and one page per module.
pub fn buildPages(arena: Allocator, packages_in: []const Package) Error![]const Page {
    var pages: std.ArrayListUnmanaged(Page) = .empty;

    for (packages_in) |pkg| {
        const pkg_href = try packageHref(arena, pkg.spec.name);

        for (pkg.modules) |module| {
            const href = try moduleHref(arena, pkg.spec.name, module);
            var links: std.ArrayListUnmanaged(markdown.Link) = .empty;

            var body: std.Io.Writer.Allocating = .init(arena);
            defer body.deinit();
            const writer = &body.writer;

            try writer.print("<p class=\"api-crumbs\"><a href=\"{s}\">API</a> / <a href=\"{s}\">{s}</a> / <code>{s}</code></p>\n", .{
                try std.fmt.allocPrint(arena, "{s}index.html", .{try relativePrefix(arena, href)}),
                try std.fmt.allocPrint(arena, "{s}index.html", .{try relativePrefix(arena, href)}),
                pkg.spec.name,
                module.name,
            });

            try writer.print("<h1>{s}<span class=\"api-pkg\">{s}</span></h1>\n", .{ module.name, pkg.spec.name });
            if (module.audience == .internal) {
                // Say it out loud: this page exists for completeness, not for learning.
                try writer.writeAll("<p class=\"internal-banner\"><span>内部実装</span> ");
                try writeInlineCode(writer, "このファイルは FFI 宣言・契約テストなどの内部実装です。ライブラリを使うだけなら読む必要はありません。");
                try writer.print(
                    " 使い方は <a href=\"{s}docs/guides/getting-started.html\">はじめかた</a> と API リファレンスの公開モジュールから入ってください。</p>\n",
                    .{try relativePrefix(arena, href)},
                );
            }
            try writer.print("<p class=\"api-path\"><a href=\"{s}{s}\">{s}</a> · 公開宣言 {d} 件</p>\n", .{
                repo_blob_base, module.path, module.path, declCount(module),
            });

            if (module.doc.len > 0) {
                try writer.writeAll("<div class=\"api-moduledoc prose\">");
                try writer.writeAll(try renderDocMarkdown(arena, module.doc, href, module.path, &links));
                try writer.writeAll("</div>\n");
            }

            if (module.decls.len > 0) {
                try writer.writeAll("<nav class=\"api-toc\"><strong>このファイルの宣言</strong><ul>");
                for (module.decls) |decl| {
                    try writer.print("<li><a href=\"#{s}\"><span class=\"api-kind\">{s}</span>{s}</a></li>", .{ decl.name, kindGlyph(decl.kind), decl.name });
                }
                try writer.writeAll("</ul></nav>\n");
            }

            for (module.decls) |decl| {
                try renderDecl(arena, writer, decl, module.path, href, &links);
            }

            if (module.decls.len == 0) {
                try writer.writeAll("<p class=\"api-undoc\">このファイルには公開宣言がありません（内部実装のみ）。</p>\n");
            }

            try pages.append(arena, .{
                .href = href,
                .title = try std.fmt.allocPrint(arena, "{s}/{s}", .{ pkg.spec.name, module.slug }),
                .body = try body.toOwnedSlice(),
                .plain = try searchText(arena, module),
                .links = try links.toOwnedSlice(arena),
            });
        }

        // Package index.
        var body: std.Io.Writer.Allocating = .init(arena);
        defer body.deinit();
        const writer = &body.writer;
        var links: std.ArrayListUnmanaged(markdown.Link) = .empty;

        const coverage = coverageOf(pkg);
        try writer.print("<p class=\"api-crumbs\"><a href=\"{s}index.html\">API</a> / <code>{s}</code></p>\n", .{ try relativePrefix(arena, pkg_href), pkg.spec.name });
        try writer.print("<h1>{s}</h1>\n", .{pkg.spec.name});
        try writer.print("<p class=\"api-path\">ルート <a href=\"{s}{s}\">{s}</a></p>\n", .{ repo_blob_base, pkg.spec.root, pkg.spec.root });
        try writer.writeAll("<p class=\"api-blurb\">");
        try writeInlineCode(writer, pkg.spec.blurb);
        try writer.writeAll("</p>\n");
        try writer.print(
            "<p class=\"api-stats\">公開モジュール {d} 件 · 公開宣言 {d} 件 · ドキュメントコメント {d} 件（{d}%）</p>\n",
            .{ userModuleCount(pkg), coverage.total, coverage.documented, percent(coverage.documented, coverage.total) },
        );
        if (coverage.internal_total > 0) {
            try writer.print(
                "<p class=\"api-blurb\">このほかに内部モジュール（FFI 宣言・契約テスト）が {d} 件あります。" ++
                    "読み手が使う API ではないため、下の一覧では畳んであり、文書化率の計算からも外しています。</p>\n",
                .{pkg.modules.len - userModuleCount(pkg)},
            );
        }

        try writer.writeAll("<h2>モジュール</h2>\n<ul class=\"api-modules\">\n");
        for (pkg.modules) |module| {
            if (module.audience == .internal) continue;
            try renderModuleEntry(arena, writer, module, pkg_href, pkg.spec.root, &links);
        }
        try writer.writeAll("</ul>\n");

        if (pkg.modules.len > userModuleCount(pkg)) {
            // Collapsed: an embedder can still find `gtk_bindings`, but the default reading path
            // never shows it.
            try writer.writeAll("<details class=\"api-internal\"><summary>内部モジュール（FFI バインディング・契約テスト）</summary>\n<ul class=\"api-modules\">\n");
            for (pkg.modules) |module| {
                if (module.audience != .internal) continue;
                try renderModuleEntry(arena, writer, module, pkg_href, pkg.spec.root, &links);
            }
            try writer.writeAll("</ul>\n</details>\n");
        }

        try writer.writeAll("<h2>宣言一覧</h2>\n<div class=\"api-index\">\n");
        for (pkg.modules) |module| {
            if (module.audience == .internal) continue;
            for (module.decls) |decl| {
                try writer.print("<a class=\"api-chip\" href=\"{s}.html#{s}\"><span class=\"api-kind\">{s}</span>{s}</a>\n", .{
                    module.slug, decl.name, kindGlyph(decl.kind), decl.name,
                });
            }
        }
        try writer.writeAll("</div>\n");

        try pages.append(arena, .{
            .href = pkg_href,
            .title = pkg.spec.name,
            .body = try body.toOwnedSlice(),
            .links = try links.toOwnedSlice(arena),
        });
    }

    // The A–Z index across every package.
    {
        const href = "docs/api/index.html";
        var body: std.Io.Writer.Allocating = .init(arena);
        defer body.deinit();
        const writer = &body.writer;

        var all: Coverage = .{};
        var module_count: usize = 0;
        for (packages_in) |pkg| {
            all.add(coverageOf(pkg));
            module_count += userModuleCount(pkg);
        }

        try writer.writeAll("<h1>API リファレンス</h1>\n");
        try writer.print(
            "<p class=\"api-blurb\">{d} パッケージ / {d} モジュール / 公開宣言 {d} 件。すべて<b>このリポジトリのソースから生成</b>しています" ++
                "（シグネチャ・<code>///</code> ドキュメント・ソース行へのリンク）。ドキュメントコメントが書かれているのは {d} 件（{d}%）。</p>\n",
            .{ packages_in.len, module_count, all.total, all.documented, percent(all.documented, all.total) },
        );
        if (all.internal_total > 0) {
            try writer.print(
                "<p class=\"api-blurb\">FFI バインディングや契約テスト（内部モジュール {d} 宣言）は、この数値にも A–Z 索引にも含めていません。" ++
                    "各パッケージのページで折り畳んであります。</p>\n",
                .{all.internal_total},
            );
        }

        try writer.writeAll("<table class=\"api-packages\"><thead><tr><th>パッケージ</th><th>説明</th><th>宣言</th><th>文書化</th></tr></thead><tbody>\n");
        for (packages_in) |pkg| {
            const coverage = coverageOf(pkg);
            try writer.print("<tr><td><a href=\"{s}/index.html\"><code>{s}</code></a></td><td>", .{ pkg.spec.name, pkg.spec.name });
            try writeInlineCode(writer, pkg.spec.blurb);
            try writer.print("</td><td class=\"num\">{d}</td><td class=\"num\">{d}%</td></tr>\n", .{ coverage.total, percent(coverage.documented, coverage.total) });
        }
        try writer.writeAll("</tbody></table>\n");

        try writer.writeAll("<h2 id=\"az\">A–Z 索引</h2>\n<p class=\"api-blurb\">公開モジュールの宣言（型のメンバと内部モジュールは含みません）。</p>\n<div class=\"api-index api-index-wide\">\n");
        for (packages_in) |pkg| {
            for (pkg.modules) |module| {
                if (module.audience == .internal) continue;
                for (module.decls) |decl| {
                    try writer.print("<a class=\"api-chip\" href=\"{s}/{s}.html#{s}\"><span class=\"api-kind\">{s}</span>{s}<span class=\"api-where\">{s}</span></a>\n", .{
                        pkg.spec.name, module.slug, decl.name, kindGlyph(decl.kind), decl.name, module.slug,
                    });
                }
            }
        }
        try writer.writeAll("</div>\n");

        try pages.append(arena, .{
            .href = href,
            .title = "API リファレンス",
            .body = try body.toOwnedSlice(),
        });
    }

    std.mem.sort(Page, pages.items, {}, struct {
        fn lessThan(_: void, a: Page, b: Page) bool {
            return std.mem.order(u8, a.href, b.href) == .lt;
        }
    }.lessThan);
    return pages.toOwnedSlice(arena);
}

/// Text the site search indexes for an API page: the module documentation plus every declaration
/// name, so typing `dispatch` or `Options` finds the page even when the prose never repeats it.
pub fn searchText(arena: Allocator, module: Module) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    if (module.doc.len > 0) try w.print("{s} ", .{try firstParagraph(arena, module.doc)});
    for (module.decls) |decl| {
        try w.print("{s} {s} ", .{ decl.name, decl.signature });
        for (decl.members) |member| try w.print("{s} ", .{member.name});
    }
    return out.toOwnedSlice();
}

pub fn declCount(module: Module) usize {
    var n: usize = 0;
    for (module.decls) |decl| n += 1 + decl.members.len;
    return n;
}

/// First paragraph of a Markdown blob, used as a one-line module summary.
pub fn firstParagraph(arena: Allocator, text: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const writer = &out.writer;
    var started = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            if (started) break;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (started) try writer.writeByte(' ');
        try writer.writeAll(trimmed);
        started = true;
    }
    return out.toOwnedSlice();
}

/// `../../` prefix for a site-relative path (`docs/api/x.html` → `../../`).
pub fn relativePrefix(arena: Allocator, href: []const u8) Error![]const u8 {
    var depth: usize = 0;
    for (href) |ch| if (ch == '/') {
        depth += 1;
    };
    if (depth == 0) return "";
    const out = try arena.alloc(u8, depth * 3);
    for (0..depth) |i| @memcpy(out[i * 3 ..][0..3], "../");
    return out;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "braceDelta ignores braces inside strings, chars and comments" {
    try testing.expectEqual(@as(i32, 1), braceDelta("pub const X = struct {"));
    try testing.expectEqual(@as(i32, -1), braceDelta("};"));
    try testing.expectEqual(@as(i32, 0), braceDelta("const s = \"{{{\";"));
    try testing.expectEqual(@as(i32, 0), braceDelta("// }}}}"));
    try testing.expectEqual(@as(i32, 0), braceDelta("/// pub fn f() void {}"));
    try testing.expectEqual(@as(i32, 0), braceDelta("    \\\\ text } with a brace"));
    try testing.expectEqual(@as(i32, 0), braceDelta("const c = '{';"));
}

test "declStart classifies functions, values and types" {
    const fn_decl = declStart("pub fn setTitle(ctx: *Ctx) !void {").?;
    try testing.expectEqual(Kind.function, fn_decl.kind);
    try testing.expectEqualStrings("setTitle", fn_decl.name);

    const inline_fn = declStart("pub inline fn add(a: u8, b: u8) u8 {").?;
    try testing.expectEqual(Kind.function, inline_fn.kind);
    try testing.expectEqualStrings("add", inline_fn.name);

    const type_decl = declStart("pub const Options = struct {").?;
    try testing.expectEqual(Kind.type_, type_decl.kind);
    try testing.expectEqualStrings("Options", type_decl.name);

    // A constant that happens to start with `struct…` in its value is still a constant.
    const value = declStart("pub const schema = structOf(.{});").?;
    try testing.expectEqual(Kind.constant, value.kind);

    try testing.expectEqual(Kind.variable, declStart("pub var counter: u32 = 0;").?.kind);
    try testing.expectEqual(Kind.constant, declStart("pub const version = \"1.0\";").?.kind);
    try testing.expectEqual(Kind.namespace, declStart("pub usingnamespace @import(\"x.zig\");").?.kind);

    // Not public ⇒ invisible to the reference.
    try testing.expect(declStart("fn hidden() void {}") == null);
    try testing.expect(declStart("pub fn") == null);
}

test "signatureOf stops at the body and collapses multi-line parameter lists" {
    const source =
        \\/// Doc.
        \\pub fn connect(
        \\    allocator: Allocator,
        \\    options: Options, // trailing comment
        \\) ConnectError!Connection {
        \\    return undefined;
        \\}
    ;
    const lines = try splitLines(testing.allocator, source);
    defer testing.allocator.free(lines);

    const sig = try signatureOf(testing.allocator, lines, 1, 24);
    defer testing.allocator.free(sig);
    try testing.expectEqualStrings("pub fn connect( allocator: Allocator, options: Options, ) ConnectError!Connection", sig);
}

test "scanModule picks module docs, declarations, docs and struct members" {
    const source =
        \\//! Module level documentation.
        \\//! Second line.
        \\
        \\const std = @import("std");
        \\
        \\/// The version.
        \\pub const version = "0.1.0";
        \\
        \\pub const Options = struct {
        \\    /// How many.
        \\    count: u32 = 0,
        \\    /// A nested struct that must not leak into the top level.
        \\    pub const Inner = struct {
        \\        pub fn hidden() void {}
        \\    };
        \\    pub fn init() Options {
        \\        return .{};
        \\    }
        \\};
        \\
        \\pub fn undocumented() void {}
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const module = try scanModule(arena_state.allocator(), "src/x/mod.zig", source);

    try testing.expectEqualStrings("mod", module.name);
    try testing.expect(std.mem.indexOf(u8, module.doc, "Module level documentation") != null);
    try testing.expect(std.mem.indexOf(u8, module.doc, "Second line") != null);

    try testing.expectEqual(@as(usize, 3), module.decls.len);
    try testing.expectEqualStrings("version", module.decls[0].name);
    try testing.expectEqualStrings("The version.", module.decls[0].doc);
    try testing.expectEqual(Kind.constant, module.decls[0].kind);

    const options = module.decls[1];
    try testing.expectEqualStrings("Options", options.name);
    try testing.expectEqual(Kind.type_, options.kind);
    try testing.expectEqual(@as(usize, 3), options.members.len);
    try testing.expectEqualStrings("count", options.members[0].name);
    try testing.expectEqual(Kind.field, options.members[0].kind);
    try testing.expectEqualStrings("count: u32 = 0", options.members[0].signature);
    try testing.expectEqualStrings("How many.", options.members[0].doc);
    try testing.expectEqualStrings("Inner", options.members[1].name);
    try testing.expectEqualStrings("init", options.members[2].name);

    try testing.expectEqualStrings("undocumented", module.decls[2].name);
    try testing.expectEqualStrings("", module.decls[2].doc);
}

test "importsOf keeps only relative zig files" {
    const source =
        \\const std = @import("std");
        \\const foundation = @import("zts_foundation");
        \\const codec = @import("codec.zig");
        \\const nested = @import("../core/owned_bytes.zig");
    ;
    const imports = try importsOf(testing.allocator, source);
    defer testing.allocator.free(imports);
    try testing.expectEqual(@as(usize, 2), imports.len);
    try testing.expectEqualStrings("codec.zig", imports[0]);
    try testing.expectEqualStrings("../core/owned_bytes.zig", imports[1]);
}

test "joinPath normalises dot segments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("src/rpc/codec.zig", try joinPath(arena, "src/rpc", "codec.zig"));
    try testing.expectEqualStrings("src/rpc/codec.zig", try joinPath(arena, "src/rpc/sub", "../codec.zig"));
    try testing.expectEqualStrings("src/root.zig", try joinPath(arena, "", "src/root.zig"));
}

test "firstParagraph stops at the first blank line and skips headings" {
    const text =
        \\# Title
        \\
        \\First paragraph
        \\ continues here.
        \\
        \\Second paragraph.
    ;
    const summary = try firstParagraph(testing.allocator, text);
    defer testing.allocator.free(summary);
    try testing.expectEqualStrings("First paragraph continues here.", summary);
}

test "relativePrefix matches the page depth" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("../../", try relativePrefix(arena, "docs/api/index.html"));
    try testing.expectEqualStrings("../../../", try relativePrefix(arena, "docs/api/zts_rpc/mod.html"));
    try testing.expectEqualStrings("", try relativePrefix(arena, "index.html"));
}

test "fieldStart recognises struct fields and enum cases but not code" {
    try testing.expectEqualStrings("count", fieldStart("count: u32 = 0,").?.name);
    try testing.expectEqual(Kind.field, fieldStart("count: u32 = 0,").?.kind);
    try testing.expectEqualStrings("Fast", fieldStart("Fast = 3,").?.name);
    try testing.expectEqualStrings("Slow", fieldStart("Slow,").?.name);
    try testing.expectEqualStrings("@\"item\"", fieldStart("@\"item\": []const u8,").?.name);

    try testing.expect(fieldStart("const Self = @This();") == null);
    try testing.expect(fieldStart("fn init() void {}") == null);
    try testing.expect(fieldStart("};") == null);
    try testing.expect(fieldStart("// count: u32 = 0,") == null);
}

test "fieldSignature drops the trailing comma and keeps the default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("count: u32 = 0", try fieldSignature(arena_state.allocator(), "count: u32 = 0,"));
    try testing.expectEqualStrings("name: []const u8", try fieldSignature(arena_state.allocator(), "name: []const u8, // the label"));
}

test "isAlias treats numeric constants as declarations, not re-exports" {
    // `pub const limit = 16` has no documentation site of its own; it must be counted.
    const literal = Decl{ .kind = .constant, .name = "limit", .signature = "pub const limit = 16", .doc = "", .line = 1 };
    try std.testing.expect(!isAlias(literal));
}

test "isAlias recognises re-exports and dotted paths but not values" {
    const alias_import = Decl{ .kind = .constant, .name = "codec", .signature = "pub const codec = @import(\"codec.zig\")", .doc = "", .line = 1 };
    try testing.expect(isAlias(alias_import));

    const alias_path = Decl{ .kind = .constant, .name = "Ctx", .signature = "pub const Ctx = ctx.Ctx", .doc = "", .line = 1 };
    try testing.expect(isAlias(alias_path));

    const literal = Decl{ .kind = .constant, .name = "version", .signature = "pub const version = \"0.1.0\"", .doc = "", .line = 1 };
    try testing.expect(!isAlias(literal));

    const array = Decl{ .kind = .constant, .name = "packages", .signature = "pub const packages = [_]PackageSpec{", .doc = "", .line = 1 };
    try testing.expect(!isAlias(array));

    const function = Decl{ .kind = .function, .name = "f", .signature = "pub fn f() void", .doc = "", .line = 1 };
    try testing.expect(!isAlias(function));
}

test "moduleSlug keeps the path inside the package so plugin mod.zig files do not collide" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("mod", try moduleSlug(arena, "src/tauri/mod.zig", "src/tauri/mod.zig"));
    try testing.expectEqualStrings("tray/mod", try moduleSlug(arena, "src/tauri/mod.zig", "src/tauri/tray/mod.zig"));
    try testing.expectEqualStrings("fs/mod", try moduleSlug(arena, "src/tauri/mod.zig", "src/tauri/fs/mod.zig"));
    try testing.expectEqualStrings("codec", try moduleSlug(arena, "src/rpc/mod.zig", "src/rpc/codec.zig"));
    try testing.expectEqualStrings("root", try moduleSlug(arena, "src/root.zig", "src/root.zig"));
}

test "audienceOf separates FFI tables and contract tests from the reader-facing API" {
    // Read by a learner.
    try std.testing.expectEqual(Audience.user, audienceOf("src/rpc/mod.zig"));
    try std.testing.expectEqual(Audience.user, audienceOf("src/webview/c_api.zig"));
    try std.testing.expectEqual(Audience.user, audienceOf("src/tauri/fs/scope.zig"));
    // Plumbing: hand-written extern tables and test-only helpers.
    try std.testing.expectEqual(Audience.internal, audienceOf("src/webview/gtk_bindings.zig"));
    try std.testing.expectEqual(Audience.internal, audienceOf("src/webview/win32.zig"));
    try std.testing.expectEqual(Audience.internal, audienceOf("src/webview/webview2_com.zig"));
    try std.testing.expectEqual(Audience.internal, audienceOf("src/webview/capture_test.zig"));
}

test "coverageOf keeps internal declarations out of the percentage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const documented = Decl{ .kind = .function, .name = "visible", .signature = "pub fn visible() void", .doc = "/// Visible.", .line = 1 };
    const undocumented = Decl{ .kind = .constant, .name = "hidden", .signature = "pub const hidden = 1", .doc = "", .line = 2 };
    const pkg = Package{
        .spec = .{ .name = "p", .root = "src/p/mod.zig", .blurb = "" },
        .modules = try arena.dupe(Module, &.{
            .{ .path = "src/p/mod.zig", .name = "mod", .slug = "mod", .doc = "", .decls = try arena.dupe(Decl, &.{documented}), .audience = .user },
            .{ .path = "src/p/win32.zig", .name = "win32", .slug = "win32", .doc = "", .decls = try arena.dupe(Decl, &.{undocumented}), .audience = .internal },
        }),
    };

    const coverage = coverageOf(pkg);
    try std.testing.expectEqual(@as(usize, 1), coverage.total); // the FFI table is not "the API"
    try std.testing.expectEqual(@as(usize, 1), coverage.documented);
    try std.testing.expectEqual(@as(usize, 100), percent(coverage.documented, coverage.total));
    // …but it is not hidden either.
    try std.testing.expectEqual(@as(usize, 1), coverage.internal_total);
    try std.testing.expectEqual(@as(usize, 0), coverage.internal_documented);
}
