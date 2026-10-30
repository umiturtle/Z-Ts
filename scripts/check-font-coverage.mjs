#!/usr/bin/env node
// scripts/check-font-coverage.mjs — 文字化け（豆腐）防止ゲート。
//
// ギャラリーは 3 OS で画素を一致させるため **システムフォントを使わず**、同梱の
// `ZTS Sans` / `ZTS Serif` / `ZTS Mono`（Noto Sans/Serif JP + JetBrains Mono のサブセット）だけを
// 描画する。したがって、ページに収録外の文字を書くと **Linux では豆腐（□）** になる。
// 本スクリプトは `examples/` 配下のデモ HTML に出てくる全文字を
// `examples/gallery/src/web/fonts/coverage.txt`（`scripts/build-fonts.py` が生成）と突き合わせる。
//
// 使い方:
//   node scripts/check-font-coverage.mjs            # examples/gallery/src/web 配下の *.html
//   node scripts/check-font-coverage.mjs <file>...  # 指定ファイルだけ
//
// 失敗時: `FAIL font-coverage <file>: U+3042 …` + exit 1。文言を足したら
//   `python3 scripts/build-fonts.py` を再実行してフォントと coverage.txt を作り直す。

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const COVERAGE = path.join(ROOT, 'examples', 'gallery', 'src', 'web', 'fonts', 'coverage.txt');

if (!existsSync(COVERAGE)) {
  console.error(`FAIL font-coverage missing ${path.relative(ROOT, COVERAGE)} (run scripts/build-fonts.py)`);
  process.exit(1);
}

const covered = new Set();
for (const line of readFileSync(COVERAGE, 'utf8').split('\n')) {
  if (line.startsWith('#')) continue;
  for (const ch of line) covered.add(ch);
}

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === 'zig-out' || name === '.zig-cache' || name === 'dist' || name === '.output') continue;
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (/\.(html|ts|tsx|js|jsx|mjs|css)$/.test(name)) out.push(full);
  }
  return out;
}

// Only the pages the gallery actually renders (system-font apps like `examples/counter` are not
// part of the parity set, so their text does not need to be in the bundled subsets).
const explicit = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const files = explicit.length
  ? explicit.map((f) => path.resolve(f))
  : walk(path.join(ROOT, 'examples', 'gallery', 'src', 'web'));

let missing = 0;
for (const file of files) {
  const text = readFileSync(file, 'utf8');
  const bad = new Map();
  for (const ch of text) {
    const cp = ch.codePointAt(0);
    // Whitespace and control characters are not drawn; everything else must be covered.
    if (cp <= 0x20 || (cp >= 0x7f && cp <= 0x9f)) continue;
    if (covered.has(ch)) continue;
    bad.set(ch, (bad.get(ch) ?? 0) + 1);
  }
  if (bad.size === 0) continue;
  missing += 1;
  const sample = [...bad.entries()]
    .slice(0, 12)
    .map(([ch, n]) => `U+${ch.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}("${ch}"×${n})`)
    .join(' ');
  console.log(`FAIL font-coverage ${path.relative(ROOT, file)}: ${sample}`);
}

if (missing > 0) {
  console.error(
    `FAIL font-coverage ${missing} file(s) use characters the bundled fonts cannot draw — ` +
      `run \`python3 scripts/build-fonts.py\` after adding the text`,
  );
  process.exit(1);
}

console.log(`OK font-coverage files=${files.length} chars=${covered.size}`);
