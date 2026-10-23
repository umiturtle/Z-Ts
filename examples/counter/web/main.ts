//! Z-Ts Counter — 無改造 `@tauri-apps/api` v2 (`invoke` / `listen`) だけを使うフロントエンド。
//!
//! 環境判定は一切しない。`getState` が返す `mode` フィールド（`desktop` / `bridge` / `wasm`）を
//! そのまま画面に表示するため、3 成果物で **同一バンドル** が動く。

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

interface CounterSnapshot {
  readonly count: number;
  readonly step: number;
  readonly mutations: number;
  readonly mode: string;
}

function element<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (found === null) throw new Error(`Z-Ts counter: missing #${id}`);
  return found as T;
}

const ui = {
  count: element("count"),
  step: element("step"),
  mutations: element("mutations"),
  mode: element("mode"),
  status: element("status"),
  events: element("events"),
  increment: element<HTMLButtonElement>("increment"),
  decrement: element<HTMLButtonElement>("decrement"),
  reset: element<HTMLButtonElement>("reset"),
  applyStep: element<HTMLButtonElement>("apply-step"),
  stepInput: element<HTMLInputElement>("step-input"),
};

let busy = false;
let receivedEvents = 0;

function setStatus(text: string, state: "idle" | "busy" | "error" | "ok"): void {
  ui.status.textContent = text;
  ui.status.dataset["state"] = state;
}

function render(snapshot: CounterSnapshot): void {
  ui.count.textContent = String(snapshot.count);
  ui.count.dataset["sign"] = snapshot.count < 0 ? "negative" : snapshot.count > 0 ? "positive" : "zero";
  ui.step.textContent = String(snapshot.step);
  ui.mutations.textContent = String(snapshot.mutations);
  ui.mode.textContent = snapshot.mode;
  ui.mode.dataset["mode"] = snapshot.mode;
  ui.stepInput.value = String(snapshot.step);
  document.title = `Z-Ts Counter (${snapshot.mode}) — ${snapshot.count}`;
}

/// `SSG` 出力にだけ存在するビルド時スナップショット（プリレンダリング済み初期値）。
function readPrerenderedSnapshot(): CounterSnapshot | null {
  const holder = document.getElementById("__ZTS_SSG_DATA__");
  const raw = holder?.textContent;
  if (raw === undefined || raw === null || raw.length === 0) return null;
  try {
    return JSON.parse(raw) as CounterSnapshot;
  } catch {
    return null;
  }
}

async function invokeCounter(command: string, args?: Record<string, unknown>): Promise<CounterSnapshot | null> {
  try {
    return await invoke<CounterSnapshot>(command, args);
  } catch (error) {
    setStatus(`RPC error: ${describeError(error)}`, "error");
    return null;
  }
}

function describeError(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null) {
    const record = error as Record<string, unknown>;
    if (typeof record["code"] === "string") return record["code"];
    try {
      return JSON.stringify(error);
    } catch {
      return "unknown";
    }
  }
  return String(error);
}

async function mutate(command: "increment" | "decrement" | "reset"): Promise<void> {
  if (busy) return;
  busy = true;
  setStatus(`${command}…`, "busy");
  const next = await invokeCounter(command);
  busy = false;
  if (next !== null) {
    // `counter:changed` でも同じ内容が届くが、コマンド応答を確定値として即時反映する。
    render(next);
    setStatus(`${command} ok`, "ok");
  }
}

async function applyStep(): Promise<void> {
  if (busy) return;
  const raw = Number(ui.stepInput.value);
  if (!Number.isFinite(raw)) {
    setStatus("step must be a number", "error");
    return;
  }
  const step = Math.min(100, Math.max(1, Math.trunc(raw)));
  ui.stepInput.value = String(step);

  busy = true;
  setStatus(`setStep(${step})…`, "busy");
  const next = await invokeCounter("setStep", { step });
  busy = false;
  if (next !== null) {
    render(next);
    setStatus(`step = ${next.step}`, "ok");
  }
}

async function boot(): Promise<void> {
  const prerendered = readPrerenderedSnapshot();
  if (prerendered !== null) {
    render(prerendered);
    setStatus("hydrated from __ZTS_SSG_DATA__", "ok");
  }

  // バックエンドからの状態変更通知（desktop: evalJs / bridge: SSE / wasm: JS⇔線形メモリ）。
  await listen<CounterSnapshot>("counter:changed", (event) => {
    receivedEvents += 1;
    ui.events.textContent = String(receivedEvents);
    render(event.payload);
    setStatus("synced via counter:changed", "ok");
  });

  const initial = await invokeCounter("getState");
  if (initial !== null) {
    render(initial);
    setStatus(`connected (${initial.mode})`, "ok");
  }

  ui.increment.addEventListener("click", () => void mutate("increment"));
  ui.decrement.addEventListener("click", () => void mutate("decrement"));
  ui.reset.addEventListener("click", () => void mutate("reset"));
  ui.applyStep.addEventListener("click", () => void applyStep());
  ui.stepInput.addEventListener("keydown", (event) => {
    if ((event as KeyboardEvent).key === "Enter") void applyStep();
  });
}

void boot();
