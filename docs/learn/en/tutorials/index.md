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

### Three tutorials x nine libraries

Every branch carries the **state primitive and Zig linkage** chapter (seal, two states, SSR guard).

| Library | Counter | Todo | UI | State primitive |
|---|---|---|---|---|
| React | [counter](counter-react.md) | [todo](todo-react.md) | [ui](ui-react.md) | `useState(0)` |
| Solid | [counter](counter-solid.md) | [todo](todo-solid.md) | [ui](ui-solid.md) | `createSignal(0)` |
| Svelte | [counter](counter-svelte.md) | [todo](todo-svelte.md) | [ui](ui-svelte.md) | `let count = 0` |
| Angular | [counter](counter-angular.md) | [todo](todo-angular.md) | [ui](ui-angular.md) | `signal(0)` |
| Next.js | [counter](counter-next.md) | [todo](todo-next.md) | [ui](ui-next.md) | `useState(0)` (with `'use client'`) |
| Nuxt | [counter](counter-nuxt.md) | [todo](todo-nuxt.md) | [ui](ui-nuxt.md) | `ref(0)` |
| Astro | [counter](counter-astro.md) | [todo](todo-astro.md) | [ui](ui-astro.md) | Direct DOM updates (`data-zts`) |
| SvelteKit | [counter](counter-sveltekit.md) | [todo](todo-sveltekit.md) | [ui](ui-sveltekit.md) | `let count = 0` |
| SolidStart | [counter](counter-solidstart.md) | [todo](todo-solidstart.md) | [ui](ui-solidstart.md) | `createSignal(0)` |

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
