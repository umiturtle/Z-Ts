// Shared, dependency-free helpers for `bench/run.mjs` (Node 22 built-ins only).
//
// The benchmark must run on a cold CI container with no npm install, no Rust toolchain and no
// display server. Anything it cannot measure is reported as `skipped` with a reason rather than
// being guessed: a fabricated number in a Check Summary is worse than an honest gap.

import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:net";
import { performance } from "node:perf_hooks";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// `import.meta.dirname` needs Node >= 20.11; fileURLToPath keeps the runner usable on Node 18+.
export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

export function now() {
  return performance.now();
}

export function measured(value, unit, note = "") {
  return { status: "measured", value: round(value), unit, note };
}

export function skipped(reason, unit = "") {
  return { status: "skipped", value: null, unit, reason };
}

export function round(n) {
  if (!Number.isFinite(n)) return null;
  return Math.round(n * 100) / 100;
}

export function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/** Runs a command, returns { ms, stdout, stderr, status }. Never throws on non-zero exit. */
export function run(argv, options = {}) {
  const t0 = now();
  const r = spawnSync(argv[0], argv.slice(1), {
    cwd: options.cwd ?? root,
    env: { ...process.env, ...(options.env || {}) },
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: options.timeoutMs ?? 20 * 60 * 1000,
    shell: false,
  });
  const ms = now() - t0;
  return {
    ms,
    status: r.status,
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
    error: r.error?.message ?? null,
  };
}

/** Spawns a long-lived process and resolves when `ready` matches a stdout/stderr line. */
export function spawnUntil(argv, { cwd = root, env = {}, ready, timeoutMs = 30000 }) {
  return new Promise((resolve, reject) => {
    const child = spawn(argv[0], argv.slice(1), {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let done = false;
    const timer = setTimeout(() => finish(new Error(`ready timeout: ${ready}`)), timeoutMs);
    function finish(err) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (err) {
        child.kill("SIGKILL");
        reject(err);
      } else {
        resolve({ child, out });
      }
    }
    const onData = (chunk) => {
      out += chunk.toString();
      if (ready.test(out)) finish(null);
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("error", (e) => finish(e));
    child.on("exit", (code) => {
      if (!done) finish(new Error(`process exited early (code ${code}): ${out.slice(-400)}`));
    });
  });
}

/** Measures wall-clock time from spawn to a marker in stdout, repeatedly. */
export async function startupTimes(argv, marker, cwd, iterations = 5) {
  const samples = [];
  for (let i = 0; i < iterations; i += 1) {
    const t0 = now();
    const r = run(argv, { cwd, timeoutMs: 15000 });
    if (r.status !== 0 || !marker.test(r.stdout)) {
      return { samples, error: `startup probe failed: ${r.stderr.slice(-200) || r.stdout.slice(-200)}` };
    }
    samples.push(now() - t0);
  }
  return { samples };
}

/** Linux-only RSS sampling of a live child, in KiB. */
export function rssKb(pid) {
  if (process.platform !== "linux") return null;
  try {
    const text = fs.readFileSync(`/proc/${pid}/status`, "utf8");
    const m = /^VmRSS:\s+(\d+)\s+kB$/m.exec(text);
    return m ? Number(m[1]) : null;
  } catch {
    return null;
  }
}

export function findFreePort() {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.on("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const port = s.address().port;
      s.close(() => resolve(port));
    });
  });
}

export function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

export function hostInfo() {
  return {
    platform: process.platform,
    arch: process.arch,
    cpus: os.cpus().length,
    total_memory_gb: round(os.totalmem() / 1024 ** 3),
    node: process.version,
  };
}

export function which(bin) {
  const r = spawnSync(process.platform === "win32" ? "where" : "which", [bin], {
    encoding: "utf8",
  });
  if (r.status !== 0) return null;
  return r.stdout.split(/\r?\n/)[0] || null;
}

export function zigBin() {
  return process.env.ZTS_ZIG || which("zig") || null;
}
