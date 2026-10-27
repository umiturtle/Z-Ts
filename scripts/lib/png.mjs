// scripts/lib/png.mjs — dependency-free PNG decoder shared by the CI screenshot tools.
//
// `zlib` (Node built-in) does the inflate; everything else (chunk parsing, unfiltering, palette
// expansion) is here so the gates run on a fresh runner without `npm install`.

import { inflateSync } from 'node:zlib';

export const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const CHANNELS = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

export function fail(prefix, msg) {
  console.error(`FAIL ${prefix} ${msg}`);
  process.exit(1);
}

export function parsePng(buf, file = 'png') {
  if (buf.length < 8 || !buf.subarray(0, 8).equals(PNG_SIGNATURE)) fail('screenshots', `${file}: not a PNG`);
  let offset = 8;
  const parsed = { ihdr: null, palette: null, idat: [], file };
  while (offset + 8 <= buf.length) {
    const length = buf.readUInt32BE(offset);
    const type = buf.toString('ascii', offset + 4, offset + 8);
    const data = buf.subarray(offset + 8, offset + 8 + length);
    offset += 12 + length;
    if (type === 'IHDR') {
      parsed.ihdr = {
        width: data.readUInt32BE(0),
        height: data.readUInt32BE(4),
        bitDepth: data[8],
        colorType: data[9],
        interlace: data[12],
      };
    } else if (type === 'PLTE') {
      parsed.palette = data;
    } else if (type === 'IDAT') {
      parsed.idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
  }
  if (!parsed.ihdr) fail('screenshots', `${file}: missing IHDR`);
  if (parsed.ihdr.interlace !== 0) fail('screenshots', `${file}: interlaced PNGs are not supported`);
  const channels = CHANNELS[parsed.ihdr.colorType];
  if (!channels) fail('screenshots', `${file}: unsupported colour type ${parsed.ihdr.colorType}`);
  if (parsed.ihdr.bitDepth !== 8) fail('screenshots', `${file}: unsupported bit depth ${parsed.ihdr.bitDepth}`);
  return parsed;
}

export function unfilter(parsed) {
  const { width, height, colorType } = parsed.ihdr;
  const channels = CHANNELS[colorType];
  const raw = inflateSync(Buffer.concat(parsed.idat));
  const stride = width * channels;
  const out = Buffer.alloc(stride * height);
  let pos = 0;
  for (let y = 0; y < height; y += 1) {
    const filter = raw[pos];
    pos += 1;
    const line = raw.subarray(pos, pos + stride);
    pos += stride;
    const prev = y === 0 ? null : out.subarray((y - 1) * stride, y * stride);
    const cur = out.subarray(y * stride, (y + 1) * stride);
    for (let x = 0; x < stride; x += 1) {
      const a = x >= channels ? cur[x - channels] : 0;
      const b = prev ? prev[x] : 0;
      const c = prev && x >= channels ? prev[x - channels] : 0;
      let value = line[x];
      switch (filter) {
        case 0:
          break;
        case 1:
          value += a;
          break;
        case 2:
          value += b;
          break;
        case 3:
          value += (a + b) >> 1;
          break;
        case 4: {
          const p = a + b - c;
          const pa = Math.abs(p - a);
          const pb = Math.abs(p - b);
          const pc = Math.abs(p - c);
          value += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
          break;
        }
        default:
          fail('screenshots', `${parsed.file}: bad filter ${filter} on row ${y}`);
      }
      cur[x] = value & 0xff;
    }
  }
  return { pixels: out, channels, stride };
}

/// RGB of one pixel, palette/gray expanded to RGB.
export function rgbAt(decoded, parsed, x, y) {
  const { pixels, channels, stride } = decoded;
  const i = y * stride + x * channels;
  if (parsed.ihdr.colorType === 3) {
    const idx = pixels[i] * 3;
    return [parsed.palette[idx], parsed.palette[idx + 1], parsed.palette[idx + 2]];
  }
  if (parsed.ihdr.colorType === 0 || parsed.ihdr.colorType === 4) {
    const g = pixels[i];
    return [g, g, g];
  }
  return [pixels[i], pixels[i + 1], pixels[i + 2]];
}

export function stats(decoded, parsed) {
  const { width, height } = parsed.ihdr;
  const seen = new Set();
  let sum = 0;
  let min = 255;
  let max = 0;
  const stepX = Math.max(1, Math.floor(width / 240));
  const stepY = Math.max(1, Math.floor(height / 240));

  for (let y = 0; y < height; y += stepY) {
    for (let x = 0; x < width; x += stepX) {
      const [r, g, b] = rgbAt(decoded, parsed, x, y);
      seen.add((r << 16) | (g << 8) | b);
      const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      sum += lum;
      min = Math.min(min, lum);
      max = Math.max(max, lum);
    }
  }
  const samples = Math.ceil(width / stepX) * Math.ceil(height / stepY);
  return {
    unique: seen.size,
    mean: sum / samples,
    min,
    max,
    center: rgbAt(decoded, parsed, Math.floor(width / 2), Math.floor(height / 2)),
  };
}

/// Pixel-level comparison of two decoded PNGs of identical size.
/// Returns `{ diffRatio, meanAbsDiff, maxDiff, worst: [x, y] }`.
export function diffPixels(a, aParsed, b, bParsed) {
  const width = aParsed.ihdr.width;
  const height = aParsed.ihdr.height;
  let differing = 0;
  let total = 0;
  let sum = 0;
  let maxDiff = 0;
  let worst = [0, 0];
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const [r1, g1, b1] = rgbAt(a, aParsed, x, y);
      const [r2, g2, b2] = rgbAt(b, bParsed, x, y);
      const d = Math.max(Math.abs(r1 - r2), Math.abs(g1 - g2), Math.abs(b1 - b2));
      sum += (Math.abs(r1 - r2) + Math.abs(g1 - g2) + Math.abs(b1 - b2)) / 3;
      total += 1;
      if (d > maxDiff) {
        maxDiff = d;
        worst = [x, y];
      }
      // A 3/255 threshold ignores rounding noise but still catches a shifted glyph or box.
      if (d > 3) differing += 1;
    }
  }
  return { diffRatio: differing / total, meanAbsDiff: sum / total, maxDiff, worst };
}
