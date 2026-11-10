# Tutorials

> **Audience**: readers who would rather type than read.
> **Time**: 10–20 minutes per tutorial.

Every tutorial **leaves you with something that runs**. When a term gets in the way, look it up in
the [glossary](../../../glossary.md) — you do not have to stop and read a chapter.

| Tutorial | You build | You learn |
|---|---|---|
| 1. [Build a counter](counter.md) | an app where clicking increments a number (desktop / browser / static) | `zts init` → command → UI → build |
| 2. [Build a todo list](todo.md) | a list you can add to, complete and remove from | state in one struct, returning failures, testing commands |
| 3. [Build the screen](ui.md) | a page that distinguishes loading, empty and error | view states, CSS swapping, CSP |

## Work through them with your library

All three share **the same Zig side**. For the frontend, pick any of the nine libraries with a
committed example, or plain JavaScript. **Read one branch and you are done** — these are
alternative routes, not extra chapters, so the time budget does not grow.

<!-- framework-picker -->

The [chooser hub](frameworks.md) also links each example's source, build command and live demo.

## How to work through one

1. **Go in order.** Tutorial 2 reuses tutorial 1's project (it also works in a fresh one).
2. **Type it, do not only read it.** Copying works, but typing once shows you where you hesitate.
3. **Run it at the end of every chapter.** Carrying a broken build forward makes causes hard to
   separate.
4. **`zig check` blocks are compiled by CI.** Every block marked that way builds; a tutorial that
   goes stale turns red.

## Before you start

- `zts` on your machine ([Install](../guides/install.md))
- Zig 0.17 on `PATH` or in `ZTS_ZIG`
- a terminal

Never run `zts` before? [Your first ten minutes](../start.md) (10 minutes) covers steps 0–1 and
gets you a page in a browser.

- After all three: design → [Patterns](../patterns/index.md) (how to shape commands, state and errors)
- Design first → [Concepts](../concepts/index.md)
- One specific job → [Guides](../guides/index.md)
