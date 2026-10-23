#!/usr/bin/env node
// Z-Ts Counter ショーケース (`M2-02`) のフロントエンドビルダー。
//
// 1. `tests/tauri/node_modules/@tauri-apps/api` が無ければ `npm ci --prefix tests/tauri`
//    （既存 E2E スイートと同じ依存を共有し、追加インストールを発生させない）。
// 2. `web/main.ts` を `tsc --noEmit`（strict）で型検査。
// 3. esbuild で `@tauri-apps/api` v2 ごと IIFE バンドルし、`index.html` / `styles.css` と共に
//    `<out_dir>/` へ出力する（このディレクトリがそのまま `embedFrontendDir` の入力になる）。
//
// Usage: node scripts/build-web.mjs <out_dir>

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const exampleDir = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(exampleDir, "..", "..");
const tauriDir = path.join(repoRoot, "tests", "tauri");

if (process.argv[2] === undefined) {
  console.error("Usage: node scripts/build-web.mjs <out_dir>");
  process.exit(2);
}
const outDir = path.resolve(process.argv[2]);
const nodeModules = path.join(tauriDir, "node_modules");

// 1. 依存（`tests/tauri` と共有）
const apiPkgJson = path.join(nodeModules, "@tauri-apps", "api", "package.json");
if (!fs.existsSync(apiPkgJson)) {
  const npmCmd = process.platform === "win32" ? "npm.cmd" : "npm";
  const hasLock = fs.existsSync(path.join(tauriDir, "package-lock.json"));
  execFileSync(npmCmd, [hasLock ? "ci" : "install", "--prefix", tauriDir, "--no-audit", "--no-fund"], {
    stdio: "inherit",
    shell: process.platform === "win32",
  });
}

// 2. Strict TypeScript check（`@tauri-apps/api` は `web/tsconfig.json` の paths で解決）
const tscBin = path.join(nodeModules, "typescript", "bin", "tsc");
if (fs.existsSync(tscBin)) {
  execFileSync(process.execPath, [tscBin, "-p", path.join(exampleDir, "web", "tsconfig.json")], {
    stdio: "inherit",
  });
} else {
  console.warn("counter: typescript not installed, skipping type check");
}

// 3. Bundle (esbuild の JS API を直接使うため `npx` 不要 = コールドスタートでも高速)
const { buildSync } = await import(pathToFileURL(path.join(nodeModules, "esbuild", "lib", "main.js")).href);

fs.mkdirSync(outDir, { recursive: true });
buildSync({
  entryPoints: [path.join(exampleDir, "web", "main.ts")],
  outfile: path.join(outDir, "app.js"),
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "es2022",
  legalComments: "none",
  nodePaths: [nodeModules],
});

for (const asset of ["index.html", "styles.css"]) {
  fs.copyFileSync(path.join(exampleDir, "web", asset), path.join(outDir, asset));
}

// 4. サニティチェック: ESM import が残っていない & 無改造 API が実際にバンドルされた
const bundle = fs.readFileSync(path.join(outDir, "app.js"), "utf8");
if (/(^|[;}\s])import\s*[{*"']/.test(bundle)) {
  console.error("counter: bundled app.js still contains an ESM import statement");
  process.exit(1);
}
if (!bundle.includes("__TAURI_INTERNALS__")) {
  console.error("counter: bundled app.js does not contain the unmodified @tauri-apps/api invoke bridge");
  process.exit(1);
}

const size = fs.statSync(path.join(outDir, "app.js")).size;
console.log(`counter frontend: app.js ${size} bytes (@tauri-apps/api v2 inlined, iife)`);
