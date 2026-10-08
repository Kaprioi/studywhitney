// Renders Whitney's sprite (pulled from the page itself) into a 1024px app icon PNG
const fs = require('fs'), zlib = require('zlib');
const html = fs.readFileSync(process.argv[2], 'utf8');
const src = html.slice(html.indexOf('const W = 32'), html.indexOf('function paint('));
const { buildCat, PAL, W, H } = new Function(src + '; return { buildCat, PAL, W, H };')();
const g = buildCat({ eyes: 'open', mouth: 'closed', tail: 0.8, alert: false });
const S = 1024, scale = 21, ox = Math.round((S - W * scale) / 2), oy = Math.round((S - H * scale) / 2) + 6;
const px = Buffer.alloc(S * S * 4);
const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const r = 200, m = 100; // squircle-ish rounded square with macOS icon margin
for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
  const i = (y * S + x) * 4;
  const inX = x >= m && x < S - m, inY = y >= m && y < S - m;
  let inside = inX && inY;
  if (inside) { const cx = Math.min(Math.max(x, m + r), S - m - r), cy = Math.min(Math.max(y, m + r), S - m - r); inside = (x - cx) ** 2 + (y - cy) ** 2 <= r * r }
  if (inside) { const t = (y - m) / (S - 2 * m); px[i] = 251 - 20 * t; px[i + 1] = 214 - 30 * t; px[i + 2] = 226 - 10 * t; px[i + 3] = 255 }
}
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
  const c = g[y][x]; if (!c) continue; const [R, G, B] = hex(PAL[c]);
  for (let yy = 0; yy < scale; yy++) for (let xx = 0; xx < scale; xx++) {
    const X = ox + x * scale + xx, Y = oy + y * scale + yy; if (X < 0 || Y < 0 || X >= S || Y >= S) continue;
    const i = (Y * S + X) * 4; px[i] = R; px[i + 1] = G; px[i + 2] = B; px[i + 3] = 255;
  }
}
const raw = Buffer.alloc((S * 4 + 1) * S);
for (let y = 0; y < S; y++) { raw[y * (S * 4 + 1)] = 0; px.copy(raw, y * (S * 4 + 1) + 1, y * S * 4, (y + 1) * S * 4) }
const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0 });
const crc = b => { let c = 0xffffffff; for (const v of b) c = crcT[(c ^ v) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0 };
const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]) };
const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(S, 0); ihdr.writeUInt32BE(S, 4); ihdr[8] = 8; ihdr[9] = 6;
fs.writeFileSync(process.argv[3], Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]));
