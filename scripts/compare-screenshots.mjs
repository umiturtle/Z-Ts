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
//        [--max-diff 0.06] [--max-mad 6] [--layout-tolerance 1] [--bg-tolerance 4] [--json out.json]
//   フラグはディレクトリの前後どちらでもよい（`--flag value` の組はディレクトリとして数えない）。
//
// 出力（成功時）: `OK parity hosts=gtk3,cocoa,win32 patterns=17 layout=ok pixels=max:2.1%`
// 失敗時: `FAIL parity <pattern>: <理由>` + exit 1。

import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { parsePng, unfilter, diffPixels, rgbAt, stats } from './lib/png.mjs';

const args = process.argv.slice(2);
// Every flag here takes a value, so drop `--flag value` pairs before collecting the directories.
// (Filtering on `startsWith('--')` alone leaves `0.06` behind and it gets mistaken for a run dir.)
const VALUE_FLAGS = new Set(['--max-diff', '--max-mad', '--layout-tolerance', '--bg-tolerance', '--json']);
const dirs = [];
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (VALUE_FLAGS.has(arg)) {
    i += 1;
    continue;
  }
  if (arg.startsWith('--')) continue;
  dirs.push(arg);
}
const flag = (name, fallback) => {
  const i = args.indexOf(name);
  if (i < 0) return fallback;
  const v = Number(args[i + 1]);
  return Number.isFinite(v) ? v : fallback;
};
const maxDiff = flag('--max-diff', 0.06);
// GTK/WebKitGTK quantises glyph advances to whole pixels (a 8.88px advance is laid out as 9px),
// while CoreText and DirectWrite keep the fractions. The error is bounded by 0.5px per glyph, so
// a text-driven box may legitimately be `0.5 × characters` off. Line-break counts are compared
// separately and exactly, which is what actually catches a wrapping regression.
const GLYPH_TOLERANCE = 0.5;
const GLYPH_TOLERANCE_MAX = 8;
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
// Collect every mismatch instead of aborting on the first one: a single run then tells us all
// 17 patterns × 3 pairs of trouble, which is the difference between one CI round and five.
const problems = [];
let worstDiff = 0;
let worstMad = 0;
let compared = 0;

const probeLine = (host, layout) => {
  const probe = layout && layout.probe;
  if (!probe) return `  ${host} probe: (none)`;
  const { ua = '', ...rest } = probe;
  const engine = (ua.match(/(Chrome|Safari|WebKit)\/[\d.]+/) || [ua.slice(0, 40)])[0];
  return `  ${host} probe: ${JSON.stringify(rest)} [${engine}]`;
};

/** Coarse 12×8 map of where the differing pixels are (percent of that cell), for diagnosis. */
const diffMap = (a, pa, b, pb) => {
  const cols = 12;
  const rows = 8;
  const cell = Array.from({ length: rows }, () => new Array(cols).fill(0));
  const total = Array.from({ length: rows }, () => new Array(cols).fill(0));
  const w = pa.ihdr.width;
  const h = pa.ihdr.height;
  for (let y = 0; y < h; y += 1) {
    const ry = Math.min(rows - 1, Math.floor((y * rows) / h));
    for (let x = 0; x < w; x += 1) {
      const cx = Math.min(cols - 1, Math.floor((x * cols) / w));
      total[ry][cx] += 1;
      const [r1, g1, b1] = rgbAt(a, pa, x, y);
      const [r2, g2, b2] = rgbAt(b, pb, x, y);
      if (Math.max(Math.abs(r1 - r2), Math.abs(g1 - g2), Math.abs(b1 - b2)) > 3) cell[ry][cx] += 1;
    }
  }
  const lines = cell.map((row, y) =>
    `    row${y}: ` + row.map((v, x) => `${((v / Math.max(1, total[y][x])) * 100).toFixed(0).padStart(3)}%`).join(' '),
  );
  return '  differing pixels by region (12 cols × 8 rows):\n' + lines.join('\n');
};

/** Full per-box dump (names, sizes, line counts) for a failing pattern. */
const dumpBoxes = (hostA, la, lb) => {
  const rows = la.boxes.map((box, i) => {
    const name = (la.names && la.names[i]) || `box${i}`;
    const other = lb.boxes[i] ? lb.boxes[i].join(',') : '?';
    return `    #${String(i).padStart(2)} ${name.padEnd(28)} ${hostA}=${box.join(',')} other=${other}` +
      ` chars=${la.chars ? la.chars[i] : '?'} lines=${la.lines ? la.lines[i] : '?'}/${lb.lines ? lb.lines[i] : '?'}`;
  });
  return rows.join('\n');
};

/** Record a mismatch and skip the rest of this pair. */
const reject = (msg) => {
  problems.push(msg);
};

for (const pattern of reference.manifest.patterns) {
  for (const other of runs.slice(1)) {
    const b = other.byName.get(pattern.name);
    if (!b) {
      reject(`${pattern.name}: missing from ${other.manifest.host}`);
      continue;
    }
    if (b.width !== pattern.width || b.height !== pattern.height) {
      reject(
        `${pattern.name}: ${other.manifest.host} captured ${b.width}x${b.height} but ` +
          `${reference.manifest.host} captured ${pattern.width}x${pattern.height} ` +
          `(same OS-independent CSS size expected)`,
      );
    }
    if (pattern.css_width !== b.css_width || pattern.css_height !== b.css_height) {
      reject(`${pattern.name}: CSS viewport differs (${pattern.css_width}x${pattern.css_height} vs ${b.css_width}x${b.css_height})`);
      continue;
    }

    // ---- 1. layout fingerprint ----
    const la = pattern.layout ? JSON.parse(pattern.layout) : null;
    const lb = b.layout ? JSON.parse(b.layout) : null;
    if (!la || !lb) {
      reject(`${pattern.name}: missing layout fingerprint (page reported no boxes)`);
      continue;
    }
    if (!la.font_ok || !lb.font_ok) {
      reject(`${pattern.name}: bundled fonts did not load (font_ok ${la.font_ok} / ${lb.font_ok})`);
      continue;
    }
    if (la.boxes.length !== lb.boxes.length) {
      reject(`${pattern.name}: ${la.boxes.length} boxes vs ${lb.boxes.length} — DOM differs between OSes`);
      continue;
    }
    // The number of line boxes per element must match exactly: that is the wrapping contract, and
    // it is immune to sub-pixel advance differences.
    if (la.lines && lb.lines) {
      if (la.lines.length !== lb.lines.length) {
        reject(`${pattern.name}: line signature has ${la.lines.length} entries vs ${lb.lines.length}`);
        continue;
      }
      const wrapAt = la.lines.findIndex((n, i) => n !== lb.lines[i]);
      if (wrapAt !== -1) {
        reject(
          `${pattern.name}: text wraps differently at box #${wrapAt}` +
            `${la.names && la.names[wrapAt] ? ` (${la.names[wrapAt]})` : ''}: ` +
            `${la.lines[wrapAt]} line(s) on ${reference.manifest.host} vs ${lb.lines[wrapAt]} on ${other.manifest.host}`,
        );
        continue;
      }
    }
    // Box geometry: ±1px for the layout we control, plus WebKitGTK's per-glyph quantisation
    // (≤0.5px per character) for boxes whose size comes from text.
    let maxDelta = 0;
    let maxSlack = 0;
    let badBox = -1;
    for (let i = 0; i < la.boxes.length; i += 1) {
      const glyphs = la.chars && la.chars[i] ? la.chars[i] : 0;
      const slack = layoutTolerance + Math.min(GLYPH_TOLERANCE_MAX, Math.ceil(GLYPH_TOLERANCE * glyphs));
      for (let k = 0; k < 4; k += 1) {
        const delta = Math.abs(la.boxes[i][k] - lb.boxes[i][k]);
        if (delta > slack && delta - slack > maxDelta - maxSlack) {
          maxDelta = delta;
          maxSlack = slack;
          badBox = i;
        }
      }
    }
    if (la.names && lb.names && la.names.join('|') !== lb.names.join('|')) {
      const at = la.names.findIndex((n, i) => n !== lb.names[i]);
      reject(
        `${pattern.name}: DOM differs at box #${at} (${la.names[at] ?? '?'} vs ${lb.names[at] ?? '?'}) — ` +
          'the same source must produce the same element list',
      );
      continue;
    }
    if (badBox !== -1) {
      const label = la.names && la.names[badBox] ? ` (${la.names[badBox]})` : '';
      reject(
        `${pattern.name}: layout differs by ${maxDelta}px at box #${badBox}${label} ` +
          `(allowed ${maxSlack}px = ${layoutTolerance}px base + 0.5px per glyph)\n  ${reference.manifest.host}: ${JSON.stringify(la.boxes[badBox])}\n  ${other.manifest.host}: ${JSON.stringify(lb.boxes[badBox])}\n` +
          probeLine(reference.manifest.host, la) +
          '\n' +
          probeLine(other.manifest.host, lb) +
          '\n' +
          dumpBoxes(reference.manifest.host, la, lb),
      );
      continue;
    }
    const docDelta = Math.max(Math.abs(la.doc_w - lb.doc_w), Math.abs(la.doc_h - lb.doc_h));
    if (docDelta > layoutTolerance) {
      reject(`${pattern.name}: document size differs by ${docDelta}px (${la.doc_w}x${la.doc_h} vs ${lb.doc_w}x${lb.doc_h})`);
      continue;
    }

    // ---- 2. pixels ----
    const bufA = readFileSync(path.join(reference.dir, pattern.file));
    const bufB = readFileSync(path.join(other.dir, b.file));
    const parsedA = parsePng(bufA, pattern.file);
    const parsedB = parsePng(bufB, b.file);
    const decodedA = unfilter(parsedA);
    const decodedB = unfilter(parsedB);
    const diff = diffPixels(decodedA, parsedA, decodedB, parsedB);

    // The painted background (1,1) must match within 4/255 per channel: a theme or palette
    // regression is not something an anti-aliasing tolerance should be allowed to hide, but
    // WebKit/Blink can differ by a rounding step when the page paints a gradient.
    const bgA = rgbAt(decodedA, parsedA, 1, 1);
    const bgB = rgbAt(decodedB, parsedB, 1, 1);
    const bgTolerance = flag('--bg-tolerance', 4);
    if (bgA.some((v, i) => Math.abs(v - bgB[i]) > bgTolerance)) {
      reject(`${pattern.name}: background rgb(${bgA}) vs rgb(${bgB}) — colours differ by more than ${bgTolerance}`);
      continue;
    }
    const stA = stats(decodedA, parsedA);
    const stB = stats(decodedB, parsedB);
    if (Math.abs(stA.mean - stB.mean) > 2.0) {
      reject(`${pattern.name}: mean luminance ${stA.mean.toFixed(1)} vs ${stB.mean.toFixed(1)} — visibly different`);
      continue;
    }
    if (diff.diffRatio > maxDiff || diff.meanAbsDiff > maxMad) {
      reject(
        `${pattern.name}: pixels differ (${(diff.diffRatio * 100).toFixed(1)}% > ${(maxDiff * 100).toFixed(1)}% ` +
          `or MAD ${diff.meanAbsDiff.toFixed(2)} > ${maxMad}) worst at ${diff.worst}\n` +
          diffMap(decodedA, parsedA, decodedB, parsedB),
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

if (problems.length > 0) {
  for (const msg of problems) console.error(`FAIL parity ${msg}`);
  console.error(`FAIL parity ${problems.length} mismatch(es) across ${reference.manifest.patterns.length} patterns`);
  process.exit(1);
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
