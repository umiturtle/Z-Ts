"""Per-library profiles for the three branched tutorials.

One source of truth for the framework-specific parts of `counter-<id>.md`, `todo-<id>.md` and
`ui-<id>.md`. `src/docsite/frameworks.json` stays the catalog for the picker/table; this module
owns the *teaching* text. Every prose field is a ``(ja, en)`` pair so both languages cannot drift.

The `code_*` fields are tutorial-only snippets: the committed examples deliberately keep a local
counter so the 3-OS screenshot comparison has no backend dependency. Rule 22 checks that all nine
catalog ids have a profile and that all 54 generated pages carry the Zig-linkage material.
"""

from __future__ import annotations

# Shared by every branch page: the Zig side never changes with the frontend library.
ZIG_COMMANDS = ("zig_probe", "zig_inc", "zig_dec")

PROFILES: dict[str, dict[str, object]] = {
    "react": {
        "reactivity": (
            "`useState(0)` は値と setter の組を返します。setter を呼ぶとコンポーネント関数が**もう一度実行され**、返した JSX 全体が再評価されます。状態はレンダリングごとに作り直されるクロージャなので、`await` の前の値を後で使うと古い値を掴みます。",
            "`useState(0)` returns a value and a setter. Calling the setter **re-runs the component function** and re-evaluates all of its JSX. State is a per-render closure, so a value captured before `await` is stale afterwards.",
        ),
        "sync": (
            "`setCount(await invoke(\"zig_inc\"))` のように **Zig の戻り値だけ**を渡します。クリック時に `setCount(c => c + 1)` で楽観更新すると、Zig が拒否したとき画面だけが進みます。`invoke` が reject したら setter を呼ばず、エラー状態に切り替えてください。",
            "Feed **only the Zig result** into `setCount(await invoke(\"zig_inc\"))`. An optimistic `setCount(c => c + 1)` on click makes the UI run ahead when Zig rejects the command. If `invoke` rejects, do not call the setter — switch to an error state instead.",
        ),
        "guard": (
            "`useEffect` はブラウザでだけ走るので、`window.__ZTS_ZIG__` の確認はそこに置きます。`zts dev` のブラウザには bridge が無いため `ZIG OFFLINE` のままになるのは正常です。",
            "`useEffect` only runs in the browser, so check `window.__ZTS_ZIG__` there. With no host behind `zts dev`, the panel correctly stays at `ZIG OFFLINE`.",
        ),
        "todo_state": (
            "一覧は `useState<Todo[]>([])` に持ちます。`invoke(\"listTodos\")` の結果で配列を**丸ごと差し替え**、`map` には `t.id` を `key` に渡します。",
            "Keep the list in `useState<Todo[]>([])`, replace the whole array from `invoke(\"listTodos\")`, and use `t.id` as the `key` in `map`.",
        ),
        "ui_state": (
            "`const [status, setStatus] = useState<\"loading\" | \"ready\" | \"empty\" | \"error\">(\"loading\")` の 1 本で出し分けます。条件付き JSX は `status === ... ? ... : ...` です。",
            "Use one `useState<\"loading\" | \"ready\" | \"empty\" | \"error\">(\"loading\")` and conditional JSX with `status === ... ? ... : ...`.",
        ),
        "pitfall": (
            "`useEffect` の依存配列を空にしたまま `invoke` を呼ぶと StrictMode の開発時だけ 2 回走ります。Zig 側のカウンタが 2 つ進むので、本番と挙動が違って見えたらまずここを疑ってください。",
            "An empty dependency array makes `invoke` run twice under StrictMode in development, which advances the Zig counter twice. If dev and production disagree, check this first.",
        ),
        "code_zig": '''import { invoke } from "@tauri-apps/api/core";

const [zigCount, setZigCount] = useState(0);
const [seal, setSeal] = useState("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  setZigCount(r.count);   // 楽観更新せず、Zig の戻り値だけを正にする
  setSeal(r.seal);        // Zig 側だけが作れる SHA-256 seal
}''',
        "code_todo": '''const [todos, setTodos] = useState<Todo[]>([]);

async function refresh() {
  setTodos(await invoke<Todo[]>("listTodos"));
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // ローカル配列を足さず、Zig から読み直す
}
// {todos.map((t) => <li key={t.id}>{t.title}</li>)}''',
        "code_ui": '''const [status, setStatus] = useState<"loading" | "ready" | "empty" | "error">("loading");

async function load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    setStatus(list.length ? "ready" : "empty");
  } catch (e) {
    setStatus("error");   // 画面だけ進めない
  }
}''',
    },
    "solid": {
        "reactivity": (
            "`createSignal(0)` は `[getter, setter]` の組を返します。**参照した DOM ノードだけ**が更新され、コンポーネント関数は最初の 1 回しか実行されません。`count` は値ではなく関数なので、JSX 内では `count()` と呼びます。",
            "`createSignal(0)` returns a `[getter, setter]` pair. **Only the DOM nodes that read it** update, and the component function runs exactly once. `count` is a function, so JSX calls `count()`.",
        ),
        "sync": (
            "`setCount(r.count)` は Zig の戻り値が届いてから 1 回だけ呼びます。細粒度リアクティビティなので「画面が先に動いた」ように見えにくい分、シグナルを 2 つ（ローカルと Zig）に分けて持つと状態の出所が追えます。",
            "Call `setCount(r.count)` exactly once, after Zig replies. Fine-grained updates hide a run-ahead UI, so keep two signals (local counter and Zig counter) to make the source of truth obvious.",
        ),
        "guard": (
            "`onMount` はクライアントでだけ走ります。`window.__ZTS_ZIG__` の `mount()` をそこから呼び、静的書き出しでは `ZIG OFFLINE` のままにします。",
            "`onMount` is client-only, so call `window.__ZTS_ZIG__.mount()` from there; a static export simply leaves the panel at `ZIG OFFLINE`.",
        ),
        "todo_state": (
            "一覧は `createSignal<Todo[]>([])` と `<For each={todos()}>` です。`<For>` はキー付きの差分更新なので、`map` より DOM の作り直しが少ないのが Solid 流です。",
            "Use `createSignal<Todo[]>([])` with `<For each={todos()}>`. `<For>` is keyed and reuses DOM nodes instead of rebuilding them like `map`.",
        ),
        "ui_state": (
            "`<Show when={status() === \"ready\"} fallback={...}>` で 3 状態を出し分けます。`status` もシグナルなので、条件は関数呼び出しで書きます。",
            "Branch with `<Show when={status() === \"ready\"} fallback={...}>`. `status` is a signal too, so the condition calls it.",
        ),
        "pitfall": (
            "`count` を `count()` と呼び忘れると関数オブジェクトが DOM に渡ります。逆に `createSignal` の外で `let` に代入しても画面は更新されません。",
            "Forgetting the `count()` call passes the function object to the DOM; assigning to a plain `let` outside a signal never repaints.",
        ),
        "code_zig": '''import { invoke } from "@tauri-apps/api/core";

const [zigCount, setZigCount] = createSignal(0);
const [seal, setSeal] = createSignal("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  setZigCount(r.count);   // Zig の戻り値だけを正にする
  setSeal(r.seal);
}''',
        "code_todo": '''const [todos, setTodos] = createSignal<Todo[]>([]);

async function refresh() {
  setTodos(await invoke<Todo[]>("listTodos"));
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // Zig から読み直す
}
// <For each={todos()}>{(t) => <li>{t.title}</li>}</For>''',
        "code_ui": '''const [status, setStatus] = createSignal<"loading" | "ready" | "empty" | "error">("loading");

async function load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    setStatus(list.length ? "ready" : "empty");
  } catch (e) {
    setStatus("error");
  }
}
// <Show when={status() === "ready"} fallback={<p>Loading…</p>}>…</Show>''',
    },
    "svelte": {
        "reactivity": (
            "Svelte 5 の例は `let count = 0` で、代入がそのままリアクティブです（必要なら `$state(0)`）。コンパイラが代入箇所を直接 DOM 更新に変換するので、仮想 DOM も再レンダリングもありません。",
            "The Svelte 5 example uses `let count = 0`, where assignment is reactive (`$state(0)` is the explicit form). The compiler turns each assignment into a direct DOM update — no virtual DOM, no re-render.",
        ),
        "sync": (
            "`count = r.count` は `await` の後に 1 回だけ代入します。代入が即座に画面へ効くため、`invoke` 前に `count += 1` と書くと一瞬だけ Zig と食い違った値が見えます。",
            "Assign `count = r.count` exactly once after `await`. Because assignment repaints instantly, a `count += 1` before `invoke` shows a value that disagrees with Zig for one frame.",
        ),
        "guard": (
            "`onMount` 内でだけ `window` を触ります。`.svelte` の `<script>` はビルド時に評価されることがあるので、トップレベルで bridge を参照しないでください。",
            "Touch `window` only inside `onMount`. The top-level `<script>` can be evaluated at build time, so never reference the bridge there.",
        ),
        "todo_state": (
            "`let todos: Todo[] = $state([])` と `{#each todos as t (t.id)}` のキー付き each を使います。代入で差し替えるので `push` より `todos = next` が確実です。",
            "Use `let todos: Todo[] = $state([])` with a keyed `{#each todos as t (t.id)}`. Reactivity follows assignment, so `todos = next` is safer than `push`.",
        ),
        "ui_state": (
            "`{#if status === \"loading\"}…{:else if status === \"error\"}…{:else}…{/if}` で 3 状態をテンプレートに書きます。状態は `let status = $state(\"loading\")` です。",
            "Express the three states in the template with `{#if status === \"loading\"}…{:else if status === \"error\"}…{:else}…{/if}`, backed by `let status = $state(\"loading\")`.",
        ),
        "pitfall": (
            "配列を `todos.push(x)` で増やしても代入が無いと Svelte 5 の `$state` でも追跡されないことがあります。必ず `todos = [...todos, x]` か再読込で差し替えてください。",
            "A bare `todos.push(x)` may not be tracked even by `$state`. Replace the array (`todos = [...todos, x]`) or re-read it from Zig.",
        ),
        "code_zig": '''import { invoke } from "@tauri-apps/api/core";

let zigCount = $state(0);
let seal = $state("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  zigCount = r.count;     // await の後に 1 回だけ代入
  seal = r.seal;
}''',
        "code_todo": '''let todos: Todo[] = $state([]);

async function refresh() {
  todos = await invoke<Todo[]>("listTodos");
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // 代入で丸ごと差し替える
}
// {#each todos as t (t.id)}<li>{t.title}</li>{/each}''',
        "code_ui": '''let status: "loading" | "ready" | "empty" | "error" = $state("loading");

async function load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    status = list.length ? "ready" : "empty";
  } catch (e) {
    status = "error";
  }
}
// {#if status === "error"}<p class="error">…</p>{/if}''',
    },
    "angular": {
        "reactivity": (
            "`signal(0)` は `count()` で読み、`count.set(v)` / `count.update(fn)` で書きます。テンプレートの `{{ count() }}` を追跡して**その部分だけ**更新するので、Zone.js による全体変更検知は要りません。",
            "`signal(0)` is read as `count()` and written with `count.set(v)` / `count.update(fn)`. The template tracks `{{ count() }}` and updates only that binding — no Zone.js-wide change detection.",
        ),
        "sync": (
            "`this.count.set(r.count)` を `await` の後に呼びます。`count.update(c => c + 1)` を先に走らせると、Zig がエラーを返した瞬間にシグナルだけが進みます。`computed()` は読み取り専用なので、Zig の値は `signal` 側に置いてください。",
            "Call `this.count.set(r.count)` after `await`. A leading `count.update(c => c + 1)` leaves the signal ahead when Zig returns an error. `computed()` is read-only, so the Zig value belongs in the writable `signal`.",
        ),
        "guard": (
            "builder が `<script>` を注入するので `index.html` に手で書きません。`ngAfterViewInit` 以降で `window.__ZTS_ZIG__` を確認し、SSR 系のプリレンダーでは触らないでください。",
            "The builder injects `<script>` into `index.html`, so do not add one by hand. Check `window.__ZTS_ZIG__` from `ngAfterViewInit` onwards, never during prerendering.",
        ),
        "todo_state": (
            "`todos = signal<Todo[]>([])` と `@for (t of todos(); track t.id)` を使います。`track` を省略すると一覧の差分が効きません。",
            "Use `todos = signal<Todo[]>([])` with `@for (t of todos(); track t.id)`. Omitting `track` loses keyed diffing.",
        ),
        "ui_state": (
            "`status = signal<\"loading\" | \"ready\" | \"empty\" | \"error\">(\"loading\")` と `@if (status() === \"error\") {…} @else {…}` で出し分けます。",
            "Use `status = signal<\"loading\" | \"ready\" | \"empty\" | \"error\">(\"loading\")` with `@if (status() === \"error\") {…} @else {…}`.",
        ),
        "pitfall": (
            "`count` を `count()` ではなく `count` と書くとシグナル関数そのものが表示されます。また `invoke<number>` の型指定を省くと `unknown` になり `set` に渡せません。",
            "Writing `count` instead of `count()` renders the signal function itself. Without `invoke<number>` the result is `unknown` and cannot be passed to `set`.",
        ),
        "code_zig": '''import { invoke } from "@tauri-apps/api/core";

zigCount = signal(0);
seal = signal("—");

async zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  this.zigCount.set(r.count);   // Zig の戻り値だけを正にする
  this.seal.set(r.seal);
}''',
        "code_todo": '''todos = signal<Todo[]>([]);

async refresh() {
  this.todos.set(await invoke<Todo[]>("listTodos"));
}
async add(title: string) {
  await invoke("addTodo", { title });
  await this.refresh();        // Zig から読み直す
}
// @for (t of todos(); track t.id) {<li>{{ t.title }}</li>}''',
        "code_ui": '''status = signal<"loading" | "ready" | "empty" | "error">("loading");

async load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    this.status.set(list.length ? "ready" : "empty");
  } catch (e) {
    this.status.set("error");
  }
}
// @if (status() === "error") {<p class="error">…</p>}''',
    },
    "next": {
        "reactivity": (
            "App Router の状態を持つページには `'use client'` が必須です。`useState(0)` はクライアントコンポーネントだけが使え、サーバーコンポーネントに書くとビルドが落ちます。",
            "A stateful App Router page needs `'use client'`. `useState(0)` exists only in client components; putting it in a server component fails the build.",
        ),
        "sync": (
            "`output: 'export'` の静的書き出しには Zig ホストが無いので、`invoke` は `zts build` 後のバイナリでだけ届きます。`setCount` は `await` の後に 1 回、reject 時は呼ばないでください。",
            "With `output: 'export'` there is no Zig host, so `invoke` only reaches a backend from the `zts build` binary. Call `setCount` once after `await`, and never on rejection.",
        ),
        "guard": (
            "`window.__ZTS_ZIG__` は `useEffect` 内でだけ参照します。`'use client'` でもプリレンダー時にモジュール本体は評価されるため、トップレベルの `window` は危険です。",
            "Reference `window.__ZTS_ZIG__` only inside `useEffect`. Even with `'use client'`, module scope is evaluated during prerendering, so a top-level `window` is unsafe.",
        ),
        "todo_state": (
            "`useState<Todo[]>([])` と `todos.map(t => <li key={t.id}>)`。`out/` に書き出される HTML には一覧が空の状態だけが載るので、初回は必ず `invoke` で読み直します。",
            "Use `useState<Todo[]>([])` with `todos.map(t => <li key={t.id}>)`. The exported `out/` HTML contains only the empty list, so the first paint must re-read via `invoke`.",
        ),
        "ui_state": (
            "`useState<\"loading\" | \"ready\" | \"empty\" | \"error\">(\"loading\")` から始め、プリレンダーでは `ZIG OFFLINE` を出しておくとハイドレーション後の差が出ません。",
            "Start from `useState<\"loading\" | \"ready\" | \"empty\" | \"error\">(\"loading\")` and render `ZIG OFFLINE` during prerender so hydration does not mismatch.",
        ),
        "pitfall": (
            "`next build` の静的書き出しに `invoke` の結果を埋め込もうとすると、ビルド時には Zig が居ないので失敗します。状態の初期値は常に「読み込み中」にしてください。",
            "Never try to bake `invoke` results into the static export — no Zig exists at build time. The initial state must always be \"loading\".",
        ),
        "code_zig": '''"use client";
import { invoke } from "@tauri-apps/api/core";

const [zigCount, setZigCount] = useState(0);
const [seal, setSeal] = useState("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  setZigCount(r.count);
  setSeal(r.seal);
}''',
        "code_todo": '''const [todos, setTodos] = useState<Todo[]>([]);

useEffect(() => { refresh(); }, []);
async function refresh() {
  setTodos(await invoke<Todo[]>("listTodos"));
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();
}
// {todos.map((t) => <li key={t.id}>{t.title}</li>)}''',
        "code_ui": '''const [status, setStatus] = useState<"loading" | "ready" | "empty" | "error">("loading");

useEffect(() => {
  invoke<Todo[]>("listTodos")
    .then((list) => setStatus(list.length ? "ready" : "empty"))
    .catch(() => setStatus("error"));
}, []);''',
    },
    "nuxt": {
        "reactivity": (
            "`<script setup>` の `ref(0)` は `.value` で読み書きします。テンプレートでは自動でアンラップされるので `count` と書けますが、スクリプト内では `count.value` が必要です。",
            "`ref(0)` in `<script setup>` is read and written through `.value`. Templates unwrap it automatically (`count`), but script code needs `count.value`.",
        ),
        "sync": (
            "`count.value = r.count` を `await` の後に 1 回だけ。SSR 済み HTML には初期値 `0` が載っているので、クライアントで Zig の値を流し込むまで表示が食い違います。読み込み中はパネルを `ZIG OFFLINE` のままにしてください。",
            "Assign `count.value = r.count` once after `await`. The pre-rendered HTML already contains `0`, so the display disagrees until the client injects Zig's value — keep the panel at `ZIG OFFLINE` while loading.",
        ),
        "guard": (
            "`import.meta.client` でブラウザ側だけをガードします。`nuxt generate` のプリレンダーで `window.__ZTS_ZIG__` や `invoke` を呼ぶとビルドが落ちます。",
            "Guard browser-only code with `import.meta.client`. Calling `window.__ZTS_ZIG__` or `invoke` during `nuxt generate` breaks the prerender.",
        ),
        "todo_state": (
            "`ref<Todo[]>([])` と `v-for=\"t in todos\" :key=\"t.id\"`。`ref` の配列は `.value` を丸ごと差し替えるのが確実です。",
            "Use `ref<Todo[]>([])` with `v-for=\"t in todos\" :key=\"t.id\"`. Replace `todos.value` wholesale rather than mutating it.",
        ),
        "ui_state": (
            "`ref<\"loading\" | \"ready\" | \"empty\" | \"error\">(\"loading\")` と `v-if` / `v-else-if`。プリレンダーでは `loading` が出ます。",
            "Use `ref<\"loading\" | \"ready\" | \"empty\" | \"error\">(\"loading\")` with `v-if` / `v-else-if`; prerender shows `loading`.",
        ),
        "pitfall": (
            "`count.value` を書き忘れて `count = r.count` とすると `ref` 自体を上書きし、テンプレートの追跡が切れます。",
            "Writing `count = r.count` instead of `count.value` replaces the ref object and breaks template tracking.",
        ),
        "code_zig": '''import { invoke } from "@tauri-apps/api/core";

const zigCount = ref(0);
const seal = ref("—");

async function zigInc() {
  if (!import.meta.client) return;
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  zigCount.value = r.count;   // Zig の戻り値だけを正にする
  seal.value = r.seal;
}''',
        "code_todo": '''const todos = ref<Todo[]>([]);

async function refresh() {
  if (!import.meta.client) return;
  todos.value = await invoke<Todo[]>("listTodos");
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // Zig から読み直す
}
// <li v-for="t in todos" :key="t.id">{{ t.title }}</li>''',
        "code_ui": '''const status = ref<"loading" | "ready" | "empty" | "error">("loading");

onMounted(async () => {
  try {
    const list = await invoke<Todo[]>("listTodos");
    status.value = list.length ? "ready" : "empty";
  } catch (e) {
    status.value = "error";
  }
});''',
    },
    "astro": {
        "reactivity": (
            "アイランドを置かず、静的 HTML ＋小さな `<script>` だけで動かします。状態は変数ではなく **DOM の `data-zts` 属性**にあり、`textContent` を書き換えるのが唯一の更新手段です。",
            "There is no island: static HTML plus a tiny `<script>`. State lives in the DOM's `data-zts` attributes rather than a variable, and `textContent` is the only update mechanism.",
        ),
        "sync": (
            "`value.textContent = String(r.count)` は `await` の後に 1 回だけ。フレームワークの再レンダリングが無いので、書き換え順がそのまま画面に出ます。Zig が居ない静的ビルドでは `invoke` を呼ばず `ZIG OFFLINE` を保ってください。",
            "Set `value.textContent = String(r.count)` once after `await`. With no re-render, write order is exactly what the user sees. In a static build with no Zig host, do not call `invoke` and keep `ZIG OFFLINE`.",
        ),
        "guard": (
            "Astro はデフォルトで JS を送りません。`<script>` はビルド時にバンドルされ、`window.__ZTS_ZIG__` はネイティブホストが `DOCUMENT_START` で注入したときだけ存在します。",
            "Astro ships no framework JS by default. `<script>` is bundled at build time, and `window.__ZTS_ZIG__` exists only when the native host injects it at `DOCUMENT_START`.",
        ),
        "todo_state": (
            "一覧は `<ul data-zts=\"todo-list\">` に `innerHTML` ではなく `createElement` / `textContent` で差し込みます（CSP と XSS の両方に効きます）。",
            "Build the list into `<ul data-zts=\"todo-list\">` with `createElement` / `textContent`, not `innerHTML` — this satisfies both CSP and XSS hygiene.",
        ),
        "ui_state": (
            "`data-zts=\"status\"` の 1 要素に `loading` / `empty` / `error` を書き分け、`hidden` 属性で 3 つのブロックを切り替えます。",
            "Write `loading` / `empty` / `error` into one `data-zts=\"status\"` element and toggle three blocks with the `hidden` attribute.",
        ),
        "pitfall": (
            "`querySelector` が `null` を返したときのガードを忘れると、静的 HTML を単体で開いた瞬間に `TypeError` になります。`if (!value) return;` を必ず入れてください。",
            "Without a null guard, `querySelector` throws a `TypeError` the moment the static HTML is opened alone. Always start with `if (!value) return;`.",
        ),
        "code_zig": '''import { invoke } from "@tauri-apps/api/core";

const value = document.querySelector('[data-zts="count"]');
const seal = document.querySelector('[data-zts="zig-seal"]');
const inc = document.querySelector('[data-zts="zig-inc"]');
if (!value || !seal || !inc) throw new Error("counter markup missing");

inc.addEventListener("click", async () => {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  value.textContent = String(r.count);   // Zig の戻り値だけを正にする
  seal.textContent = r.seal;
});''',
        "code_todo": '''const list = document.querySelector('[data-zts="todo-list"]');

async function refresh() {
  if (!list) return;
  const todos = await invoke<Todo[]>("listTodos");
  list.replaceChildren(...todos.map((t) => {
    const li = document.createElement("li");
    li.textContent = t.title;   // innerHTML ではなく textContent
    return li;
  }));
}''',
        "code_ui": '''const status = document.querySelector('[data-zts="status"]');

async function load() {
  if (!status) return;
  try {
    const list = await invoke<Todo[]>("listTodos");
    status.textContent = list.length ? "ready" : "empty";
  } catch (e) {
    status.textContent = "error";
  }
}''',
    },
    "sveltekit": {
        "reactivity": (
            "Svelte 5 の `let count = 0` / `$state(0)` は代入で直接 DOM を更新します。adapter-static のプリレンダーでは `0` が HTML に焼き付くので、クライアントの最初の `invoke` が実状態を作ります。",
            "Svelte 5's `let count = 0` / `$state(0)` updates the DOM directly on assignment. adapter-static bakes `0` into the HTML, so the client's first `invoke` establishes the real state.",
        ),
        "sync": (
            "`count = r.count` を `await` の後に 1 回。プリレンダー値との差が一瞬見えるので、`ZIG OFFLINE` の表示を消すのは seal が届いてからにしてください。",
            "Assign `count = r.count` once after `await`. Because the prerendered value is briefly visible, only clear `ZIG OFFLINE` after the seal arrives.",
        ),
        "guard": (
            "`onMount` または `browser` でガードします。`+page.svelte` のモジュールスコープはプリレンダー時にサーバーで評価されます。`svelte.config.js` は不要で adapter は Vite に渡します。",
            "Guard with `onMount` or `browser`: module scope in `+page.svelte` is evaluated on the server during prerender. No `svelte.config.js` is needed — the adapter goes to Vite.",
        ),
        "todo_state": (
            "`let todos = $state<Todo[]>([])` とキー付き `{#each ... (t.id)}`。`load` 関数ではなくクライアントの `invoke` で読み直します。",
            "Use `let todos = $state<Todo[]>([])` with a keyed `{#each ... (t.id)}`, re-read via client-side `invoke` rather than a `load` function.",
        ),
        "ui_state": (
            "`{#if}` チェーンで 3 状態。プリレンダーでは `loading` を出し、ハイドレーション後に差し替えます。",
            "An `{#if}` chain for the three states; prerender `loading` and swap it after hydration.",
        ),
        "pitfall": (
            "SSR 中に `window.__ZTS_ZIG__` を読むと `ReferenceError` になります。`browser` ガードを外さないでください。",
            "Reading `window.__ZTS_ZIG__` during SSR throws `ReferenceError`. Keep the `browser` guard.",
        ),
        "code_zig": '''import { invoke } from "@tauri-apps/api/core";
import { onMount } from "svelte";

let zigCount = $state(0);
let seal = $state("—");

onMount(() => {
  const zig = window.__ZTS_ZIG__;   // プリレンダーでは触らない
  if (zig && typeof zig.mount === "function") zig.mount();
});

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  zigCount = r.count;
  seal = r.seal;
}''',
        "code_todo": '''let todos: Todo[] = $state([]);

async function refresh() {
  todos = await invoke<Todo[]>("listTodos");
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // Zig から読み直す
}
// {#each todos as t (t.id)}<li>{t.title}</li>{/each}''',
        "code_ui": '''let status: "loading" | "ready" | "empty" | "error" = $state("loading");

onMount(async () => {
  try {
    const list = await invoke<Todo[]>("listTodos");
    status = list.length ? "ready" : "empty";
  } catch (e) {
    status = "error";
  }
});''',
    },
    "solidstart": {
        "reactivity": (
            "SPA モード（`ssr:false`）なのでサーバーレンダリングは走りませんが、`createSignal` の意味は Solid と同じです。`count()` で読み、`setCount` で書きます。ルートの `index.tsx` が本体です。",
            "SPA mode (`ssr:false`) skips server rendering, but `createSignal` behaves exactly like Solid: read `count()`, write `setCount`. The route's `index.tsx` is the whole app.",
        ),
        "sync": (
            "`setCount(r.count)` は `await` の後に 1 回。SPA でもプリレンダーされた HTML が残る設定にした場合は、Zig の値が届くまで `ZIG OFFLINE` を出してください。",
            "Call `setCount(r.count)` once after `await`. If you ever enable prerendering, keep `ZIG OFFLINE` visible until Zig's value arrives.",
        ),
        "guard": (
            "`onMount` で `window.__ZTS_ZIG__.mount()` を呼びます。`ssr:false` でもビルド時にモジュールが評価されることがあるので、トップレベルの `window` は避けます。",
            "Call `window.__ZTS_ZIG__.mount()` in `onMount`. Even with `ssr:false`, module scope may be evaluated at build time, so avoid a top-level `window`.",
        ),
        "todo_state": (
            "`createSignal<Todo[]>([])` と `<For each={todos()}>`。`dist/client` に書き出した後も `invoke` はネイティブホスト経由で届きます。",
            "Use `createSignal<Todo[]>([])` with `<For each={todos()}>`; `invoke` still reaches the native host from the `dist/client` export.",
        ),
        "ui_state": (
            "`<Show when={status() === \"ready\"} fallback={...}>` で 3 状態を出し分けます。",
            "Branch with `<Show when={status() === \"ready\"} fallback={...}>` across the three states.",
        ),
        "pitfall": (
            "`ssr:false` を外すと `window` 参照がビルド時に落ちます。SPA 設定を変えたら `onMount` ガードを必ず見直してください。",
            "Removing `ssr:false` makes a bare `window` reference fail at build time. Revisit the `onMount` guard whenever the SPA setting changes.",
        ),
        "code_zig": '''import { invoke } from "@tauri-apps/api/core";

const [zigCount, setZigCount] = createSignal(0);
const [seal, setSeal] = createSignal("—");

async function zigInc() {
  const r = await invoke<{ ok: boolean; count: number; seal: string }>("zig_inc");
  setZigCount(r.count);   // Zig の戻り値だけを正にする
  setSeal(r.seal);
}''',
        "code_todo": '''const [todos, setTodos] = createSignal<Todo[]>([]);

async function refresh() {
  setTodos(await invoke<Todo[]>("listTodos"));
}
async function add(title: string) {
  await invoke("addTodo", { title });
  await refresh();        // Zig から読み直す
}
// <For each={todos()}>{(t) => <li>{t.title}</li>}</For>''',
        "code_ui": '''const [status, setStatus] = createSignal<"loading" | "ready" | "empty" | "error">("loading");

async function load() {
  try {
    const list = await invoke<Todo[]>("listTodos");
    setStatus(list.length ? "ready" : "empty");
  } catch (e) {
    setStatus("error");
  }
}''',
    },
}
