# Concepts

> **Audience**: readers who have run `zts dev` at least once. If not, start with [Your first ten minutes](../start.md).
> **Time**: four pages, about 15 minutes.

## Restating what you just saw, with three moving parts

In [Your first ten minutes](../start.md) you changed `web/index.html` and watched the browser
follow. Turn that into **a button calling a Zig function** and there are exactly three parts.

```text
  ①  the page          ②  the bridge                  ③  the command
  web/index.html  ──►  invoke("increment")  ──►  fn increment(state: *State) !i32
  (HTML / JS)          plain @tauri-apps/api          (an ordinary function in src/main.zig)
                              ▲                              │
                              └──── return value (number, struct, error) ────┘
```

| Part | Job | Where you write it |
|---|---|---|
| the page | UI and interaction; the same `@tauri-apps/api` as Tauri | `web/` |
| the bridge | match names and types, carry JSON; nothing hand-written | `Schema`, assembled by `comptime` |
| the command | a Zig function: take arguments, touch state, return a value | `src/` |

**Part 2 is ziggurats's job.** Routing, serialisation, type checks and the TypeScript declarations are
all generated from `Schema`, so you only ever write parts 1 and 3.

```zig check
const std = @import("std");
const rpc = @import("zts_rpc");

const State = struct { count: i32 = 0 };
const Commands = struct {
    pub fn increment(state: *State) !i32 {
        state.count += 1;
        return state.count;
    }
};

const Schema = rpc.Schema(.{ .app = Commands });

test "the command table holds exactly one command" {
    try std.testing.expectEqual(@as(usize, 1), Schema.commands.len);
}
```

## The four questions the other pages answer

The diagram covers *one* command. Four questions remain: where state lives, which plugins are
linked, who is allowed to call a command, and what each package may depend on.

| Page | In one sentence | You will learn |
|---|---|---|
| [Package layout](architecture.md) | six packages, each depending only downwards | where code belongs, why the core never needs libc |
| [How a command travels](commands.md) | what happens between `invoke` and a Zig function | the job of `Schema`, type checks, name mapping |
| [Plugins](plugins.md) | the seven stock Tauri plugins, unimplemented in Rust | `withCorePlugins`, binding state |
| [Security](security.md) | deny by default, allow in a capability | ACL, scopes, CSP, what is *not* protected |

## Five words to learn first

These come up on every page below; come back here when one slips.

| Word | Meaning |
|---|---|
| **Pack** | a distributable Zig module (`zts_rpc`, …). Link only what you use |
| **Host** | the only layer that touches the OS; swapped per artefact |
| **Ctx** | the execution context handed to a command (I/O, state, event emission) |
| **Schema** | the table of command names, argument and return types, built at `comptime` |
| **Capability** | a declaration that "this window may call this command" |

The [glossary](../../../glossary.md) defines them in more detail (it is linked from the prose as
well).

## Reading order

Knowing **Pack** and **Host** first makes the rest read faster.

1. [Package layout](architecture.md) — the map. Do not skip this one.
2. [How a command travels](commands.md) — the part you touch every day.
3. [Plugins](plugins.md) — windows, files, menus.
4. [Security](security.md) — read before shipping.

## Next

- Hands on → [Tutorials](../tutorials/index.md) (counter, todo list, screen)
- Started writing and unsure → [Patterns](../patterns/index.md)
- Just write it → [Guide: commands](../guides/rpc.md)
- Lost in terminology → [Glossary](../../../glossary.md)
