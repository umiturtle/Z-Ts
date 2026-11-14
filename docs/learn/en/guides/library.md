# Use ziggurats as a library from another project

> **Audience**: anyone adding ziggurats as a dependency to an existing Zig 0.17 project.
> **Time**: 5 minutes.
> **Prerequisites**: `zig 0.17.0` on `PATH`. The `zts` CLI is not required.

`zts init` scaffolds an application, but **ziggurats is also an ordinary Zig package**. Add one
dependency to `build.zig.zon`, call `b.dependency("z_ts", …)` in `build.zig`, and import whichever
`zts_*` modules you need. Nothing has to go through the CLI.

## 1. Add the dependency

Let `zig fetch --save` compute the hash — do not copy one by hand. The URL and hash change with
every release, so run the command instead of pasting a stale value.

```bash
zig fetch --save=z_ts https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz
```

It writes this into `build.zig.zon` (`…` is the real hash):

```zon
.dependencies = .{
    .z_ts = .{ .url = "https://github.com/umiturtle/ZigguraTs/releases/download/v0.1.1/z_ts-0.1.1.tar.gz", .hash = "z_ts-0.1.1-…" },
},
```

> [!WARNING]
> Never ship `.path = "../Z-Ts"`: it works only for someone who cloned this repository next to
> theirs, and their `zig build` will fail. Use `.path` while developing, then switch back to
> `.url` + `.hash` before publishing.

## 2. Pass the modules in `build.zig`

List only the modules you actually use — there is no need to link all of them.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zts = b.dependency("z_ts", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zts_foundation", .module = zts.module("zts_foundation") },
                .{ .name = "zts_core", .module = zts.module("zts_core") },
                .{ .name = "zts_rpc", .module = zts.module("zts_rpc") },
            },
        }),
    });
    b.installArtifact(exe);
}
```

Do not forget `.target` and `.optimize` in the second argument to `b.dependency`. Without them a
cross-build compiles the dependency for the host instead.

## 3. Import and use them

```zig
const std = @import("std");
const foundation = @import("zts_foundation");
const core = @import("zts_core");

pub fn main() !void {
    const ResourceId = foundation.Handle(.resource);
    var pool: foundation.HandlePool([]const u8, .resource) = .empty;
    defer pool.deinit(std.heap.page_allocator);

    const handle: ResourceId = try pool.acquire(std.heap.page_allocator, "pack://scene.bin");
    std.debug.print("handle: {any}\n", .{handle});

    const size = core.LogicalSize{ .width = .{ .v = 640 }, .height = .{ .v = 480 } };
    std.debug.print("size: {d}x{d}\n", .{ size.width.v, size.height.v });
}
```

`zts_core` re-exports the `zts_foundation` types, so one import covers geometry, handles and
queues. Conversely, if you do not need the desktop layer at all, importing only `zts_foundation`
keeps the dependency graph smaller.

## Available modules

| Module | Contents | Extra OS dependency |
|---|---|---|
| `zts_foundation` | handles, geometry, queues, ownership | none (pure Zig) |
| `zts_web` | embedded assets, MIME, HTTP Range, CSP | none |
| `zts_core` | re-exports `foundation` / `web`, plus the `Host` vtable | none |
| `zts_rpc` | commands, schema, TypeScript generation | none |
| `zts_bridge` | Live Preview HTTP / SSE server | none |
| `zts_webview` | native WebView (GTK / Cocoa / Win32 / Mock) | WebKit / WebView2 |
| `zts_tauri` | Tauri v2-compatible plugins | via `zts_webview` |
| `zts_wasm` / `zts_ssg` | WASM runtime and static site export | wasm32 |
| `z_ts` | root module bundling everything | all of the above |

> `zts_webview` depends on `zts_foundation` alone. Server-side code that opens no window can
> safely take just `zts_core` and `zts_rpc`.

## When it does not work

| Symptom | Cause and fix |
|---|---|
| `hash mismatch` | the archive changed but `.hash` did not; re-run `zig fetch --save=z_ts <URL>` |
| `unable to find module "zts_core"` | the name in `imports` differs from `@import`, or `b.dependency` is missing its second argument |
| `missing fingerprint` | your own `build.zig.zon`; paste the value Zig suggests |
| `file not found: examples/...` | a development `.path` dependency survived; switch to the release `.url` |

## CI verifies this exact recipe

[`tests/library-consumer/`](https://github.com/umiturtle/ZigguraTs/tree/main/tests/library-consumer) is a
separate package implementing the three steps above. CI builds the same `git archive` a release
ships, asks `zig fetch` for its hash, then — with a **cold global cache** — imports
`zts_foundation` / `zts_core` / `zts_rpc` / `zts_web`, builds and runs the binary. The moment
`build.zig` stops exporting a module, this goes red, so the code on this page cannot go stale.

## Next

- Start from a scaffold → [Your first ten minutes](../start.md)
- Define a command → [Commands (RPC)](rpc.md)
- Look up a public declaration → [API reference](../../../api/index.html)
- Release binaries and versions → [Install](install.md)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
