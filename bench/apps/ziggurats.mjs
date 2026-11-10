// ziggurats side of the comparison. Everything here is driven by the `zts` binary and the
// committed showcase app; no npm install, no network, no display server is required.

import fs from "node:fs";
import path from "node:path";
import {
  root, run, measured, skipped, median, now, spawnUntil, startupTimes,
  rssKb, findFreePort, sleep, zigBin,
} from "../lib/probe.mjs";

export const id = "ziggurats";
export const label = "ziggurats (Zig 0.17, ReleaseSmall)";

function exe(name, base = path.join(root, "zig-out", "bin")) {
  const withExe = process.platform === "win32" ? `${name}.exe` : name;
  return path.join(base, withExe);
}

function liveExe() {
  return exe("counter-live", path.join(root, "examples", "counter", "zig-out", "bin"));
}

function projectName() {
  return "bench_app";
}

/** Returns { metrics, notes } — every metric is measured or explicitly skipped. */
export async function measure(options) {
  const metrics = {};
  const notes = [];
  const zts = exe("zts");
  const zig = zigBin();

  if (!fs.existsSync(zts)) {
    const reason = `${zts} not found — run \`./zigw build\` first`;
    for (const key of METRIC_KEYS) metrics[key] = skipped(reason);
    return { metrics, notes, fatal: true };
  }
  if (!zig) {
    const reason = "zig not on PATH (and ZTS_ZIG unset)";
    for (const key of METRIC_KEYS) metrics[key] = skipped(reason);
    return { metrics, notes, fatal: true };
  }

  const tmp = fs.mkdtempSync(path.join(root, "..", "zts-bench-"));
  const project = path.join(tmp, projectName());
  const initEnv = { ZTS_ZIG: zig };

  try {
    // `zts init` runs one build to fill in Zig's package fingerprint. That build is NOT measured;
    // its cache is discarded before the cold build below so the number is a real cold start.
    const init = run([zts, "init", projectName()], { cwd: tmp, env: initEnv });
    if (init.status !== 0) {
      const reason = `zts init failed: ${(init.stderr || init.stdout).slice(-300)}`;
      for (const key of METRIC_KEYS) metrics[key] = skipped(reason);
      return { metrics, notes, fatal: true };
    }

    // Per the design note, "clean" means a fresh project-local Zig cache / zig-out, with the
    // shared global toolchain cache warm — matching `rm -rf .zig-cache zig-out && build`.
    const buildEnv = { ZTS_ZIG: zig };
    fs.rmSync(path.join(project, ".zig-cache"), { recursive: true, force: true });
    fs.rmSync(path.join(project, "zig-out"), { recursive: true, force: true });

    const cold = run([zts, "build"], { cwd: project, env: buildEnv });
    metrics.cold_build_ms = cold.status === 0
      ? measured(cold.ms, "ms", "fresh project, warm global Zig cache")
      : skipped(`zts build failed: ${(cold.stderr || cold.stdout).slice(-300)}`);

    // Incremental: one line in the app's root source, warm caches, same project.
    const srcFile = path.join(project, "src", "main.zig");
    if (metrics.cold_build_ms.status === "measured" && fs.existsSync(srcFile)) {
      fs.appendFileSync(srcFile, "\n// bench: incremental edit\n");
      const inc = run([zts, "build"], { cwd: project, env: buildEnv });
      metrics.incremental_build_ms = inc.status === 0
        ? measured(inc.ms, "ms", "one line appended to src/main.zig")
        : skipped(`incremental zts build failed: ${(inc.stderr || inc.stdout).slice(-300)}`);
    } else {
      metrics.incremental_build_ms = skipped("cold build did not succeed");
    }

    const binary = path.join(project, "zig-out", "bin", process.platform === "win32" ? `${projectName()}.exe` : projectName());
    if (fs.existsSync(binary)) {
      metrics.binary_bytes = measured(fs.statSync(binary).size, "bytes", path.basename(binary));
    } else {
      metrics.binary_bytes = skipped("no built binary at " + binary);
    }

    // Startup: the generated app prints its embedded-asset count and exits, so it runs headless.
    if (fs.existsSync(binary)) {
      const res = await startupTimes([binary], /embedded assets/, project, options.startupIterations);
      metrics.startup_ms = res.samples.length === options.startupIterations
        ? measured(median(res.samples), "ms", `${options.startupIterations} runs, median`)
        : skipped(res.error || "startup probe incomplete");
    } else {
      metrics.startup_ms = skipped("no built binary");
    }

    // RSS + IPC both use the committed Live Preview server (a real, long-lived process).
    const liveResult = await measureLive(options);
    metrics.rss_kb = liveResult.rss;
    metrics.ipc_ms_per_call = liveResult.ipc;
    notes.push(...liveResult.notes);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  return { metrics, notes, fatal: false };
}

async function measureLive(options) {
  const live = liveExe();
  const counterDir = path.join(root, "examples", "counter");
  const notes = [];
  let rss = skipped("Live Preview server unavailable");
  let ipc = skipped("Live Preview server unavailable");

  if (!fs.existsSync(live)) {
    const zig = zigBin();
    if (zig) {
      const build = run([zig, "build", "live", "--summary", "none"], { cwd: counterDir, env: { ZTS_ZIG: zig } });
      if (build.status !== 0) notes.push(`zig build live failed: ${(build.stderr || build.stdout).slice(-200)}`);
    } else {
      notes.push("zig not on PATH; cannot build counter-live");
    }
  }
  if (!fs.existsSync(live)) return { rss, ipc, notes };

  const port = await findFreePort();
  let child;
  try {
    const started = await spawnUntil([live, "--port", String(port), "--host", "127.0.0.1"], {
      cwd: counterDir,
      ready: /Live Preview/,
      timeoutMs: 30000,
    });
    child = started.child;
    await sleep(150);

    const sample = rssKb(child.pid);
    rss = sample !== null
      ? measured(sample, "KiB", "VmRSS of counter-live at idle (Linux /proc)")
      : skipped("VmRSS is Linux-only");

    // The bootstrap script in GET / carries the per-instance invoke key; Set-Cookie carries the
    // session token. Both are required by the bridge's triple CSRF check.
    const base = `http://127.0.0.1:${port}`;
    const page = await fetch(base + "/", { signal: AbortSignal.timeout(10000) });
    const html = await page.text();
    const key = /const KEY = "([0-9a-f]+)"/.exec(html)?.[1];
    const cookie = (page.headers.get("set-cookie") || "").split(";")[0];
    if (!key || !cookie) {
      ipc = skipped("could not extract invoke key / session cookie from GET /");
      return { rss, ipc, notes };
    }

    const times = [];
    let failed = 0;
    for (let i = 0; i < options.ipcIterations; i += 1) {
      const t0 = now();
      const res = await fetch(`${base}/__zts_ipc__/getState`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Origin: base,
          Cookie: cookie,
          "Tauri-Invoke-Key": key,
        },
        body: "{}",
        signal: AbortSignal.timeout(10000),
      });
      await res.arrayBuffer();
      if (!res.ok) failed += 1;
      times.push(now() - t0);
    }
    if (failed > 0) {
      ipc = skipped(`${failed}/${options.ipcIterations} IPC calls returned non-2xx`);
    } else {
      ipc = measured(median(times), "ms", `${options.ipcIterations} JSON invoke round-trips, median`);
    }
  } catch (err) {
    notes.push(`Live Preview probe: ${err.message}`);
  } finally {
    if (child && child.exitCode === null) child.kill("SIGKILL");
  }
  return { rss, ipc, notes };
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
