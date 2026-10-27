#!/usr/bin/env node
// scripts/compare-screenshots.mjs — OS 間パリティ検証（`M5-05`）。
//
// 3 OS（Linux GTK / macOS WKWebView / Windows WebView2）のギャラリー出力を突き合わせ、
// **「同じ解像度なら同じ表示」** を 2 段で機械検証する:
//
//   1. **レイアウト**: 各ページが `load` + `document.fonts.ready` 後に投稿する
//      `{"app":"layout", boxes:[…]}` 指紋（要素の x/y/w/h を CSS px で丸めたもの）を比較。
//      許容差は既定 1px（サブピクセルの丸めだけを吸収する）。フォントが 1 つでも欠けると
//      ここで必ず落ちる。
//   2. **画素**: 同じ寸法の PNG を全画素比較し、差分率と平均差を出す。WebKit（Cocoa/GTK）と
//      Blink（WebView2）はアンチエイリアスの実装が違うため 0 にはならない。閾値は
//      `--max-diff`（既定 0.06 = 6% の画素が 3/255 を超えて違う）と `--max-mad`（既定 6.0）。
//
// 使い方:
//   node scripts/compare-screenshots.mjs <dirA> <dirB> [<dirC> …]
//        [--max-diff 0.06] [--max-mad 6] [--layout-tolerance 1] [--json out.json]
//
// 出力（成功時）: `OK parity hosts=gtk3,cocoa,win32 patterns=17 layout=ok pixels=max:2.1%`
// 失敗時: `FAIL parity <pattern>: <理由>` + exit 1。

import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { parsePng, unfilter, diffPixels, rgbAt, stats } from './lib/png.mjs';

const args = process.argv.slice(2);
const dirs = args.filter((a) => !a.startsWith('--'));
const flag = (name, fallback) => {
  const i = args.indexOf(name);
  if (i < 0) return fallback;
  const v = Number(args[i + 1]);
  return Number.isFinite(v) ? v : fallback;
};
const maxDiff = flag('--max-diff', 0.06);
const maxMad = flag('--max-mad', 6);
const layoutTolerance = flag('--layout-tolerance', 1);
const jsonIdx = args.indexOf('--json');

function fail(msg) {
  console.error(`FAIL parity ${msg}`);
  process.exit(1);
}

if (dirs.length < 2) fail('usage: compare-screenshots.mjs <dirA> <dirB> [<dirC> …] [--max-diff 0.06]');

const runs = dirs.map((dir) => {
  const manifestPath = path.join(dir, 'manifest.json');
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch (err) {
    fail(`cannot read ${manifestPath}: ${err.message}`);
  }
  if (!manifest.host) fail(`${dir}: manifest has no host`);
  return { dir, manifest, byName: new Map(manifest.patterns.map((p) => [p.name, p])) };
});

const hosts = runs.map((r) => r.manifest.host);
if (new Set(hosts).size !== hosts.length) fail(`duplicate host in ${hosts.join(',')} (mock runs cannot be compared)`);
if (hosts.includes('mock')) fail(`a run used the HeadlessMock backend (${hosts.join(',')}) — nothing was really rendered`);

const reference = runs[0];
const rows = [];
let worstDiff = 0;
let worstMad = 0;
let compared = 0;

for (const pattern of reference.manifest.patterns) {
  for (const other of runs.slice(1)) {
    const b = other.byName.get(pattern.name);
    if (!b) fail(`${pattern.name}: missing from ${other.manifest.host}`);
    if (b.width !== pattern.width || b.height !== pattern.height) {
      fail(
        `${pattern.name}: ${other.manifest.host} captured ${b.width}x${b.height} but ` +
          `${reference.manifest.host} captured ${pattern.width}x${pattern.height} ` +
          `(same OS-independent CSS size expected)`,
      );
    }
    if (pattern.css_width !== b.css_width || pattern.css_height !== b.css_height) {
      fail(`${pattern.name}: CSS viewport differs (${pattern.css_width}x${pattern.css_height} vs ${b.css_width}x${b.css_height})`);
    }

    // ---- 1. layout fingerprint ----
    const la = pattern.layout ? JSON.parse(pattern.layout) : null;
    const lb = b.layout ? JSON.parse(b.layout) : null;
    if (!la || !lb) fail(`${pattern.name}: missing layout fingerprint (page reported no boxes)`);
    if (!la.font_ok || !lb.font_ok) {
      fail(`${pattern.name}: bundled fonts did not load (font_ok ${la.font_ok} / ${lb.font_ok})`);
    }
    if (la.boxes.length !== lb.boxes.length) {
      fail(`${pattern.name}: ${la.boxes.length} boxes vs ${lb.boxes.length} — DOM differs between OSes`);
    }
    let maxDelta = 0;
    let badBox = -1;
    for (let i = 0; i < la.boxes.length; i += 1) {
      for (let k = 0; k < 4; k += 1) {
        const delta = Math.abs(la.boxes[i][k] - lb.boxes[i][k]);
        if (delta > maxDelta) {
          maxDelta = delta;
          badBox = i;
        }
      }
    }
    if (maxDelta > layoutTolerance) {
      fail(
        `${pattern.name}: layout differs by ${maxDelta}px at box #${badBox} ` +
          `(tolerance ${layoutTolerance}px)\n  ${reference.manifest.host}: ${JSON.stringify(la.boxes[badBox])}\n  ${other.manifest.host}: ${JSON.stringify(lb.boxes[badBox])}`,
      );
    }
    const docDelta = Math.max(Math.abs(la.doc_w - lb.doc_w), Math.abs(la.doc_h - lb.doc_h));
    if (docDelta > layoutTolerance) {
      fail(`${pattern.name}: document size differs by ${docDelta}px (${la.doc_w}x${la.doc_h} vs ${lb.doc_w}x${lb.doc_h})`);
    }

    // ---- 2. pixels ----
    const bufA = readFileSync(path.join(reference.dir, pattern.file));
    const bufB = readFileSync(path.join(other.dir, b.file));
    const parsedA = parsePng(bufA, pattern.file);
    const parsedB = parsePng(bufB, b.file);
    const decodedA = unfilter(parsedA);
    const decodedB = unfilter(parsedB);
    const diff = diffPixels(decodedA, parsedA, decodedB, parsedB);

    // The painted background (0,0) must match *exactly*: a theme/colour regression is not
    // something an anti-aliasing tolerance should hide.
    const bgA = rgbAt(decodedA, parsedA, 1, 1);
    const bgB = rgbAt(decodedB, parsedB, 1, 1);
    if (bgA.join(',') !== bgB.join(',')) {
      fail(`${pattern.name}: background rgb(${bgA}) vs rgb(${bgB}) — colours must be identical`);
    }
    const stA = stats(decodedA, parsedA);
    const stB = stats(decodedB, parsedB);
    if (Math.abs(stA.mean - stB.mean) > 2.0) {
      fail(`${pattern.name}: mean luminance ${stA.mean.toFixed(1)} vs ${stB.mean.toFixed(1)} — visibly different`);
    }
    if (diff.diffRatio > maxDiff || diff.meanAbsDiff > maxMad) {
      fail(
        `${pattern.name}: pixels differ (${(diff.diffRatio * 100).toFixed(1)}% > ${(maxDiff * 100).toFixed(1)}% ` +
          `or MAD ${diff.meanAbsDiff.toFixed(2)} > ${maxMad}) worst at ${diff.worst}`,
      );
    }

    worstDiff = Math.max(worstDiff, diff.diffRatio);
    worstMad = Math.max(worstMad, diff.meanAbsDiff);
    rows.push({
      pattern: pattern.name,
      pair: `${reference.manifest.host}/${other.manifest.host}`,
      layout: maxDelta,
      diff: diff.diffRatio,
      mad: diff.meanAbsDiff,
    });
    compared += 1;
  }
}

if (compared === 0) fail('no pattern was compared');

for (const row of rows) {
  console.log(
    `  ${row.pattern.padEnd(16)} ${row.pair.padEnd(13)} ` +
      `layout=${String(row.layout).padStart(2)}px ` +
      `pixels=${(row.diff * 100).toFixed(2).padStart(5)}% ` +
      `MAD=${row.mad.toFixed(2)}`,
  );
}

if (jsonIdx >= 0) {
  writeFileSync(args[jsonIdx + 1], JSON.stringify({ hosts, compared, rows, maxDiff: worstDiff, maxMad: worstMad }, null, 2));
}

console.log(
  `OK parity hosts=${hosts.join(',')} patterns=${reference.manifest.patterns.length} ` +
    `comparisons=${compared} layout=ok pixels=max:${(worstDiff * 100).toFixed(2)}% mad:${worstMad.toFixed(2)}`,
);
