# Patterns that hold up: code that keeps working after it grows

> **Audience**: readers who finished [Your first ten minutes](../start.md) and
> [Build a counter](../tutorials/counter.md).
> **Time**: 20 minutes (exercises not counted).
> **What you get**: the choices you have when writing commands, state and errors — and the rule for
> picking one.

The tutorial's counter is a **working minimum**. Grow it a little and three things always happen.

- commands multiply to one per screen, and the same work ends up in three places
- you cannot decide where state belongs, so it becomes a `global var`
- errors start being returned as strings, and the UI starts printing them

This chapter is about those three (**commands, state, errors**) and the **boundary** they sit on.
This is where "works" and "keeps working" diverge. The API itself lives in
[`reference/cli.md`](../../../reference/cli.md) and the
[API reference](../../../api/index.html); this chapter is about *choosing*.

| Page | What it covers | Exercises |
|---|---|---|
| [Designing commands](commands.md) | granularity, arguments, return values, naming — one verb, one command | 3 |
| [Where state lives](state.md) | take `*State` as a parameter; what belongs to Zig vs. the page | 2 |
| [Designing errors](errors.md) | `error{}` granularity, validating at the boundary, translation in the UI | 3 |
| [The page/logic boundary](boundaries.md) | optimistic updates, double submits, loading; not one command per screen | 2 |

## How to read this chapter

Every page has the same shape.

1. **a short working example**
2. **the shape that grows / the shape that breaks** (a table plus before → after code)
3. **why** (one or two paragraphs; worth reading on its own)
4. **exercises** (open `<details>` for the answer)

Do the exercises by typing. Open a `zts init` project or
[`examples/counter`](../../../../examples/counter/README.md) and change it in place — 5 to 10
minutes each. Reading takes 20 minutes; doing everything takes about an hour.

> [!TIP]
> After this chapter: [Look things up](../guides/index.md) and
> [the working sample](../../../../examples/counter/README.md). The sample is the **finished
> shape**; this chapter is **how to decide while you are halfway there**.

---

## One table first

| You are wondering | Default answer | Exception |
|---|---|---|
| Split into two commands, or add an argument? | **split**. Different verb, different command | if the only difference is a value, use the argument |
| State in Zig or in the page? | **Zig if being wrong hurts**; page if it is only appearance | half-typed text belongs to the page |
| How to report failure? | return `error{…}`, let the UI translate the code | expected outcomes (out of stock) can be part of the return value |
| How many commands per screen? | **one per action**, not per screen | read-only fetches may be merged |
| Where to validate? | **once, at the boundary** (top of the command) | if the type can express it, use the type |

The pages that follow open each row, with the reason.
