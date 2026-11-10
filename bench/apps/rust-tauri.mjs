// Upstream Rust Tauri side of the comparison.
//
// The upstream tree is a git submodule (`vendor/tauri`) and the Rust toolchain is opt-in via
// `scripts/setup-toolchains.sh --rust`. Neither is available in the default CI job, so this
// descriptor reports `skipped` with a reason instead of a number. When both ARE present it
// measures the same build/size metrics; startup/RSS/IPC stay skipped because a real Tauri
// window needs a display server, which the headless benchmark deliberately does not assume.

import fs from "node:fs";
import path from "node:path";
import { root, run, measured, skipped, which } from "../lib/probe.mjs";

export const id = "rust-tauri";
export const label = "Tauri v2 (Rust, upstream reference)";

const candidates = [
  "vendor/tauri/bench/tests/helloworld/src-tauri",
  "vendor/tauri/examples/helloworld/src-tauri",
];

function locateCrate() {
  for (const rel of candidates) {
    const dir = path.join(root, rel);
    if (fs.existsSync(path.join(dir, "Cargo.toml"))) return dir;
  }
  return null;
}

export async function measure(options) {
  const metrics = {};
  const notes = [];
  const cargo = which("cargo");
  const crate = locateCrate();

  if (!cargo) {
    const reason = "cargo not on PATH (run scripts/setup-toolchains.sh --rust to enable the Rust side)";
    for (const key of METRIC_KEYS) metrics[key] = skipped(reason);
    notes.push(reason);
    return { metrics, notes, fatal: false };
  }
  if (!crate) {
    const reason = "vendor/tauri helloworld crate not checked out (run setup-toolchains.sh --submodules)";
    for (const key of METRIC_KEYS) metrics[key] = skipped(reason);
    notes.push(reason);
    return { metrics, notes, fatal: false };
  }

  // A private target dir keeps the measurement isolated from any developer build.
  const target = path.join(root, "..", "zts-bench-rust-target");
  const env = { CARGO_TARGET_DIR: target };
  try {
    const clean = run([cargo, "clean"], { cwd: crate, env });
    if (clean.status !== 0) {
      for (const key of METRIC_KEYS) metrics[key] = skipped(`cargo clean failed: ${clean.stderr.slice(-200)}`);
      return { metrics, notes, fatal: false };
    }
    const cold = run([cargo, "build", "--release"], { cwd: crate, env, timeoutMs: 30 * 60 * 1000 });
    metrics.cold_build_ms = cold.status === 0
      ? measured(cold.ms, "ms", "cargo build --release from a clean target dir")
      : skipped(`cargo build failed: ${cold.stderr.slice(-300)}`);

    const mainRs = path.join(crate, "src", "main.rs");
    if (fs.existsSync(mainRs)) {
      fs.appendFileSync(mainRs, "\n// bench: incremental edit\n");
      const inc = run([cargo, "build", "--release"], { cwd: crate, env, timeoutMs: 30 * 60 * 1000 });
      metrics.incremental_build_ms = inc.status === 0
        ? measured(inc.ms, "ms", "one line appended to src/main.rs")
        : skipped(`incremental cargo build failed: ${inc.stderr.slice(-300)}`);
      // Restore: the benchmark must never leave the upstream tree modified.
      const text = fs.readFileSync(mainRs, "utf8").replace(/\n\/\/ bench: incremental edit\n$/, "\n");
      fs.writeFileSync(mainRs, text);
    } else {
      metrics.incremental_build_ms = skipped("src/main.rs not found");
    }

    // Cargo names the binary after [[bin]] / package name; use the largest release binary.
    const release = path.join(target, "release");
    let best = null;
    if (fs.existsSync(release)) {
      for (const name of fs.readdirSync(release)) {
        const full = path.join(release, name);
        const stat = fs.statSync(full);
        if (stat.isFile() && (best === null || stat.size > best.size)) best = { full, size: stat.size };
      }
    }
    metrics.binary_bytes = best
      ? measured(best.size, "bytes", path.basename(best.full))
      : skipped("no release binary found in CARGO_TARGET_DIR/release");
  } finally {
    fs.rmSync(target, { recursive: true, force: true });
  }

  const windowReason = "needs a display server / Tauri window; the headless CI job only measures builds";
  metrics.startup_ms = skipped(windowReason);
  metrics.rss_kb = skipped(windowReason);
  metrics.ipc_ms_per_call = skipped("requires a running Tauri WebView and the JS `invoke` harness");
  notes.push("Rust-side startup/RSS/IPC are intentionally skipped in headless CI.");
  return { metrics, notes, fatal: false };
}

export const METRIC_KEYS = [
  "cold_build_ms",
  "incremental_build_ms",
  "binary_bytes",
  "startup_ms",
  "rss_kb",
  "ipc_ms_per_call",
];

export const units = {
  cold_build_ms: "ms",
  incremental_build_ms: "ms",
  binary_bytes: "bytes",
  startup_ms: "ms",
  rss_kb: "KiB",
  ipc_ms_per_call: "ms",
};
