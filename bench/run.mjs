#!/usr/bin/env node
// M5-03 slice C — the reproducible ziggurats / upstream Tauri benchmark.
//
//   node bench/run.mjs                       # both sides (Rust auto-skips when unavailable)
//   node bench/run.mjs --skip-rust           # ziggurats only
//   node bench/run.mjs --ipc-iterations 100 --out /tmp/bench-out
//
// Output: <out>/results.json + <out>/results.md. No dependencies, no network, no display server.
// A metric that cannot be measured is reported as `skipped` with a reason — never guessed. CI
// appends results.md to $GITHUB_STEP_SUMMARY; hand-written numbers in README are forbidden.

import fs from "node:fs";
import path from "node:path";
import { root, hostInfo, round } from "./lib/probe.mjs";
import * as ziggurats from "./apps/ziggurats.mjs";
import * as rustTauri from "./apps/rust-tauri.mjs";

const METRICS = [
  { key: "cold_build_ms", label: "Clean build", unit: "ms" },
  { key: "incremental_build_ms", label: "Incremental (1 line)", unit: "ms" },
  { key: "binary_bytes", label: "Binary size", unit: "bytes" },
  { key: "startup_ms", label: "Startup", unit: "ms" },
  { key: "rss_kb", label: "RSS (idle)", unit: "KiB" },
  { key: "ipc_ms_per_call", label: "IPC round-trip", unit: "ms" },
];

function parseArgs(argv) {
  const options = {
    out: path.join(root, "bench", "out"),
    skipRust: false,
    startupIterations: 5,
    ipcIterations: 2000,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--help" || a === "-h") {
      console.log(`Usage: node bench/run.mjs [options]
  --out <dir>               output directory (default bench/out)
  --skip-rust               do not even attempt the Rust side
  --startup-iterations <n>  startup samples (default 5)
  --ipc-iterations <n>      invoke round-trips (default 2000)`);
      process.exit(0);
    } else if (a === "--skip-rust") {
      options.skipRust = true;
    } else if (a === "--out" && argv[i + 1]) {
      options.out = path.resolve(argv[++i]);
    } else if (a === "--startup-iterations" && argv[i + 1]) {
      options.startupIterations = Number(argv[++i]);
    } else if (a === "--ipc-iterations" && argv[i + 1]) {
      options.ipcIterations = Number(argv[++i]);
    } else {
      console.error(`unknown argument: ${a}`);
      process.exit(2);
    }
  }
  return options;
}

function fmt(entry, unit) {
  if (entry.status === "skipped") return `skipped — ${entry.reason}`;
  if (entry.value === null) return "skipped — no sample";
  const n = entry.value;
  const pretty = Number.isInteger(n) ? n.toLocaleString("en-US") : round(n);
  return `${pretty} ${unit}`;
}

function markdown(report) {
  const lines = [
    "## ziggurats / Tauri benchmark (M5-03 slice C)",
    "",
    `Generated: ${report.generated_at} · host: ${report.host.platform}/${report.host.arch}, ` +
      `${report.host.cpus} CPUs, ${report.host.total_memory_gb} GiB, ${report.host.node}`,
    "",
    "| Metric | ziggurats | Tauri v2 (Rust) |",
    "|---|---|---|",
  ];
  for (const m of METRICS) {
    const z = fmt(report.apps[0].metrics[m.key], m.unit);
    const r = report.apps[1]
      ? fmt(report.apps[1].metrics[m.key], m.unit)
      : "not run";
    lines.push(`| ${m.label} | ${z} | ${r} |`);
  }
  lines.push("", "Raw data: `results.json` in the output directory (CI artifact). Skipped metrics carry their reason in the JSON.", "");
  if (report.notes.length) {
    lines.push("### Notes", "");
    for (const n of report.notes) lines.push(`- ${n}`);
    lines.push("");
  }
  return lines.join("\n") + "\n";
}

const options = parseArgs(process.argv.slice(2));
fs.mkdirSync(options.out, { recursive: true });

console.log(`bench: measuring ziggurats …`);
const z = await ziggurats.measure(options);
const apps = [{ id: ziggurats.id, label: ziggurats.label, metrics: z.metrics }];
const notes = [...z.notes];

if (!options.skipRust) {
  console.log("bench: measuring Tauri v2 (Rust) …");
  const r = await rustTauri.measure(options);
  apps.push({ id: rustTauri.id, label: rustTauri.label, metrics: r.metrics });
  notes.push(...r.notes);
}

const report = {
  schema: 1,
  generated_at: new Date().toISOString(),
  host: hostInfo(),
  options: {
    startup_iterations: options.startupIterations,
    ipc_iterations: options.ipcIterations,
    skip_rust: options.skipRust,
  },
  apps,
  notes,
};

fs.writeFileSync(path.join(options.out, "results.json"), JSON.stringify(report, null, 2) + "\n");
fs.writeFileSync(path.join(options.out, "results.md"), markdown(report));
console.log(markdown(report));

if (z.fatal) {
  console.error("bench: ziggurats side could not run; see skipped reasons above");
  process.exit(1);
}
