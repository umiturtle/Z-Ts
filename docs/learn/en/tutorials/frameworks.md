# Choose a library for the tutorials

> **Audience**: readers who want to try ziggurats without leaving their usual frontend stack.
> **Time**: one minute to choose; 15 minutes for the tutorial you pick.

The three tutorials share **the same Zig side**. For the frontend you can pick **any** of the nine
libraries with a committed example, or plain JavaScript. `increment`, `zts dev` and `zts build`
are identical on every branch.

<!-- framework-picker -->

## How the branches work

| Original tutorial | Shared | What changes per library |
|---|---|---|
| [Build a counter](counter.md) | the `increment` command, `zts dev`, `zts build` | state and button syntax (nine full branch pages) |
| [Build a todo list](todo.md) | three Zig commands, `error{}`, command tests | list rendering (read the "State" column above) |
| [Build the screen](ui.md) | state boundaries, CSP | conditional template syntax |

> [!NOTE]
> The five learning-path steps and their minute budget are unchanged: a branch is an **alternative
> route, not an extra chapter**. Read one and you are done in 15 minutes.

## The real examples

| Example | Version | Build | Output | Tutorial | Live demo |
|---|---|---|---|---|---|
| [`react/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/react) | 19.3 | `vite build` | `dist` | [Tutorial](counter-react.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/react/index.html) |
| [`solid/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/solid) | 1.9 | `vite build` | `dist` | [Tutorial](counter-solid.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/solid/index.html) |
| [`svelte/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/svelte) | 5.57 | `vite build` | `dist` | [Tutorial](counter-svelte.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/svelte/index.html) |
| [`angular/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/angular) | 22.2 | `ng build` | `dist/browser` | [Tutorial](counter-angular.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/angular/index.html) |
| [`next/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/next) | 16.4 | `next build` | `out` | [Tutorial](counter-next.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/next/index.html) |
| [`nuxt/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/nuxt) | 4.6 | `nuxt generate` | `.output/public` | [Tutorial](counter-nuxt.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/nuxt/index.html) |
| [`astro/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/astro) | 6.4 | `astro build` | `dist` | [Tutorial](counter-astro.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/astro/index.html) |
| [`sveltekit/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/sveltekit) | 3.1 | `vite build` | `build` | [Tutorial](counter-sveltekit.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/sveltekit/index.html) |
| [`solidstart/`](https://github.com/umiturtle/Z-Ts/tree/main/examples/frameworks/solidstart) | 2.1 | `vite build` | `dist/client` | [Tutorial](counter-solidstart.md) | [Open](https://umiturtle.github.io/Z-Ts/examples/frameworks/solidstart/index.html) |

See [`examples/frameworks/README.en.md`](../../../../examples/frameworks/README.en.md) for the
build commands and the 3-OS screenshot comparison.

## Telling whether Zig is running behind the page

The nine published demos are static HTML, so the strip at the bottom of each one reads **`ZIG OFFLINE`**
in red and its `+` / `-` buttons are disabled. That is the point: a browser alone does not run
ziggurats. Open the same build in the native gallery (`examples/gallery`) and the strip turns
**`ZIG ONLINE`** in green, showing a 16-character seal that only Zig can produce and a counter owned
by Zig. `zig_probe` / `zig_inc` / `zig_dec` are answered over `ipc://` by the Zig binary; no static
file implements them. Every branch page's appendix links to the real wiring.

## Next

- Work through one → [Build a counter](counter.md) (plain JS) or any row above
- Back to the chapter hub → [Tutorials](index.md)
- Concepts first → [Concepts](../concepts/index.md)
- Shaping commands → [Patterns](../patterns/index.md)
