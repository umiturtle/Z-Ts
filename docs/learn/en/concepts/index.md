# Concepts

> **Audience**: readers who want to know how Z-Ts is assembled before writing code.
> **Time**: four pages, about 15 minutes.

Z-Ts is not just "Tauri, but in Zig". To produce **three artefacts from one source**, the
dependency graph is split into six layers and everything that touches the OS is pushed to the
outside. After these four pages, the guides stop looking like arbitrary rules.

| Page | In one sentence | You will learn |
|---|---|---|
| [Package layout](architecture.md) | six packages, each depending only downwards | where code belongs, why the core never needs libc |
| [How a command travels](commands.md) | what happens between `invoke` and a Zig function | the job of `Schema`, type checks, name mapping |
| [Plugins](plugins.md) | the seven stock Tauri plugins, unimplemented in Rust | `withCorePlugins`, binding state |
| [Security](security.md) | deny by default, allow in a capability | ACL, scopes, CSP, what is *not* protected |

## Five words to learn first

| Word | Meaning |
|---|---|
| **Pack** | a distributable Zig module (`zts_rpc`, …). Link only what you use |
| **Host** | the only layer that touches the OS; swapped per artefact |
| **Ctx** | the execution context handed to a command (I/O, state, event emission) |
| **Schema** | the table of command names, argument and return types, built at `comptime` |
| **Capability** | a declaration that "this window may call this command" |

The [glossary](../../../glossary.md) defines 31 terms in more detail.

## Reading order

1. [Package layout](architecture.md) — the map. Do not skip this one.
2. [How a command travels](commands.md) — the part you touch every day.
3. [Plugins](plugins.md) — windows, files, menus.
4. [Security](security.md) — read before shipping.

## Next

- Hands on → [Tutorial: the counter](../tutorials/counter.md)
- Just write it → [Guide: commands](../guides/rpc.md)
