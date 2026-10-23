#!/usr/bin/env node
// Cold-start-safe TypeScript checker & bundler for `tests/tauri/` (`M1-07`).
//
// 1. Auto-runs `npm ci --prefix tests/tauri` ONLY when `tests/tauri/node_modules/@tauri-apps/api` is absent.
// 2. Runs `tsc --noEmit` (`strict: true`) verifying `generated_api.ts` + `@tauri-apps/api` v2 types.
// 3. Bundles `tests/tauri/src/e2e_suite.ts` -> `<out_file>` via `esbuild` in ~25ms.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tauriTestDir = path.join(rootDir, "tests", "tauri");
const outFile = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(tauriTestDir, "dist", "e2e_suite.bundle.js");

const npmCmd = process.platform === "win32" ? "npm.cmd" : "npm";
const apiPkgJson = path.join(tauriTestDir, "node_modules", "@tauri-apps", "api", "package.json");

if (!fs.existsSync(apiPkgJson)) {
  const hasLock = fs.existsSync(path.join(tauriTestDir, "package-lock.json"));
  execFileSync(
    npmCmd,
    [hasLock ? "ci" : "install", "--prefix", tauriTestDir, "--no-audit", "--no-fund"],
    { stdio: "inherit", shell: process.platform === "win32" },
  );
}

// 1. Strict TypeScript check (`tsc --noEmit`)
const tscBin = path.join(tauriTestDir, "node_modules", "typescript", "bin", "tsc");
execFileSync(process.execPath, [tscBin, "-p", path.join(tauriTestDir, "tsconfig.json")], {
  stdio: "inherit",
});

// 2. Bundle unmodified `@tauri-apps/api` v2 + `generated_api.ts` in-process via `esbuild` JS API (~5ms, 100% OS-agnostic!)
fs.mkdirSync(path.dirname(outFile), { recursive: true });
const { buildSync } = await import(
  path.join(tauriTestDir, "node_modules", "esbuild", "lib", "main.js")
);
buildSync({
  entryPoints: [path.join(tauriTestDir, "src", "e2e_suite.ts")],
  bundle: true,
  format: "iife",
  globalName: "ZtsTauriSuite",
  platform: "browser",
  target: "es2022",
  outfile: outFile,
});
