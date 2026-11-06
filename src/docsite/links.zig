//! Cross-reference index: the one table that decides whether `` `Engine` `` in a paragraph becomes a
//! hyperlink.
//!
//! Two properties matter more than the data structure:
//!
//! 1. **It is derived from the sources, never hand-written.** The API entries come from the same
//!    `apidoc.collectPackage` pass that renders `docs/api/**`, so a renamed declaration breaks the
//!    link in the same build that would have published it. That is the anti-drift mechanism: a
//!    guide that still says `Schema.bind` either resolves to the current signature or fails the
//!    doctest/link gate.
//! 2. **Ambiguity is dropped, not guessed.** Six packages export a `Ctx`; linking the bare name
//!    would send half the readers to the wrong page. `pkg.Ctx` and `module.Ctx` stay exact.
//!
//! Lookup order: fully qualified (`zts_rpc.Ctx`, `schema.Ctx`) → bare (`Ctx`) when unique.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Index = struct {
    arena: Allocator,
    /// `zts_rpc.Ctx`, `schema.Ctx`, `Ctx`, `error.InvalidName`, `zts dev` — names nobody else claims.
    exact: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Bare names that are unique so far; a second, different target moves the name to `ambiguous`.
    bare: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Names that two different pages claim. Kept only so the report can explain the gap.
    ambiguous: std.StringHashMapUnmanaged(void) = .empty,
    /// Distinct `error{…}` names harvested from `src/**`. Reported so the error index can be held
    /// to the set the compiler actually knows about.
    errors: usize = 0,

    pub fn init(arena: Allocator) Index {
        return .{ .arena = arena };
    }

    pub fn count(self: *const Index) usize {
        return self.exact.count() + self.bare.count();
    }

    /// Registers a unique, fully-qualified name. The first writer wins: `zts_tauri.Ctx` and
    /// `zts_rpc.Ctx` are different keys, so neither can shadow the other.
    pub fn addExact(self: *Index, name: []const u8, href: []const u8) Allocator.Error!void {
        if (name.len == 0 or self.exact.contains(name)) return;
        try self.exact.put(self.arena, name, href);
    }

    /// Registers a bare name (`Ctx`) that several modules may export. It stays linkable only while
    /// every writer agrees; the second distinct target removes it for good.
    pub fn addBare(self: *Index, name: []const u8, href: []const u8) Allocator.Error!void {
        if (name.len == 0 or self.ambiguous.contains(name)) return;
        if (self.exact.contains(name)) return; // a qualified name already owns the spelling
        if (self.bare.get(name)) |existing| {
            if (std.mem.eql(u8, existing, href)) return;
            _ = self.bare.remove(name);
            try self.ambiguous.put(self.arena, name, {});
            return;
        }
        try self.bare.put(self.arena, name, href);
    }

    /// Like `addBare`, but never demotes: the first writer keeps the name. Used for namespaces that
    /// are allowed to win over a declaration with the same spelling (a package name beats a type).
    pub fn addWeak(self: *Index, name: []const u8, href: []const u8) Allocator.Error!void {
        if (name.len == 0) return;
        if (self.exact.contains(name) or self.bare.contains(name) or self.ambiguous.contains(name)) return;
        try self.bare.put(self.arena, name, href);
    }

    pub fn resolve(self: *const Index, name: []const u8) ?[]const u8 {
        if (self.exact.get(name)) |href| return href;
        if (self.ambiguous.contains(name)) return null;
        return self.bare.get(name);
    }
};

test "Index prefers qualified names and drops ambiguous bare ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ix = Index.init(arena_state.allocator());

    try ix.addExact("zts_rpc.schema.Ctx", "docs/api/zts_rpc/schema.html#Ctx");
    try ix.addBare("Ctx", "docs/api/zts_rpc/schema.html#Ctx");
    try std.testing.expectEqualStrings("docs/api/zts_rpc/schema.html#Ctx", ix.resolve("Ctx").?);

    // A second module exports `Ctx` with a different page: the bare spelling stops resolving.
    try ix.addBare("Ctx", "docs/api/zts_tauri/mod.html#Ctx");
    try std.testing.expect(ix.resolve("Ctx") == null);
    // The qualified name is untouched.
    try std.testing.expectEqualStrings("docs/api/zts_rpc/schema.html#Ctx", ix.resolve("zts_rpc.schema.Ctx").?);

    try ix.addBare("Engine", "docs/api/zts_tauri/engine.html#Engine");
    try ix.addBare("Engine", "docs/api/zts_tauri/engine.html#Engine");
    try std.testing.expectEqualStrings("docs/api/zts_tauri/engine.html#Engine", ix.resolve("Engine").?);

    try ix.addWeak("zts_rpc", "docs/api/zts_rpc/index.html");
    try std.testing.expectEqualStrings("docs/api/zts_rpc/index.html", ix.resolve("zts_rpc").?);
}

test "Index never lets a bare name shadow a qualified one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ix = Index.init(arena_state.allocator());
    try ix.addExact("Schema", "docs/api/root.html#Schema");
    try ix.addBare("Schema", "docs/api/zts_rpc/schema.html#Schema");
    try std.testing.expectEqualStrings("docs/api/root.html#Schema", ix.resolve("Schema").?);
}
