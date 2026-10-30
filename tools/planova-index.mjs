// Generate the Planova gallery index + README from the captured artboards.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = 'docs/design/planova';
const groups = [
  { key: 'desktop', label: 'Desktop', dir: 'desktop', png: 'desktop-png', w: 1440 },
  { key: 'mobile', label: 'Mobile (Android)', dir: 'mobile', png: 'mobile-png', w: 390 },
];

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const sections = [];
let totalBoards = 0;
let totalPngs = 0;
for (const g of groups) {
  const idx = JSON.parse(readFileSync(join(ROOT, g.dir, '_index.json'), 'utf8'));
  const cards = idx
    .map((b, i) => {
      const png = `${g.png}/${b.name.replace(/\.html$/, '')}.png`;
      const hasPng = existsSync(join(ROOT, png));
      if (hasPng) totalPngs++;
      return `<a class="card" href="${esc(g.dir)}/${esc(b.name)}">
  <div class="shot">${hasPng ? `<img loading="lazy" src="${esc(png)}" alt="${esc(b.title || b.name)}">` : '<span class="miss">no render</span>'}</div>
  <div class="meta"><span class="n">${String(i + 1).padStart(2, '0')}</span><span class="t">${esc(b.title || b.name)}</span></div>
</a>`;
    })
    .join('\n');
  totalBoards += idx.length;
  sections.push(`<section><h2>${esc(g.label)} <em>${idx.length} artboards</em></h2><div class="grid">${cards}</div></section>`);
}

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Planova — captured artboards</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; padding:32px 28px 64px; background:#141715; color:#e8ece9;
         font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,sans-serif; }
  header h1 { font-size:24px; margin:0 0 6px; letter-spacing:-0.01em; }
  header p { margin:0 0 4px; color:#93a09a; font-size:13px; }
  code { background:#1e2320; padding:1px 5px; border-radius:4px; font-size:12px; }
  h2 { font-size:15px; margin:40px 0 14px; font-weight:600; display:flex; align-items:baseline; gap:10px; }
  h2 em { font-style:normal; color:#7b8983; font-weight:400; font-size:12px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:18px; }
  .card { display:block; text-decoration:none; color:inherit; background:#1a1f1c; border:1px solid #262d29;
          border-radius:10px; overflow:hidden; transition:border-color .15s, transform .15s; }
  .card:hover { border-color:#3d6b58; transform:translateY(-2px); }
  .shot { background:#fff; height:210px; overflow:hidden; position:relative; }
  .shot img { width:100%; height:auto; display:block; }
  .miss { display:grid; place-items:center; height:100%; color:#9aa; font-size:12px; }
  .meta { display:flex; gap:8px; padding:10px 12px; align-items:baseline; }
  .n { color:#6f7d77; font-variant-numeric:tabular-nums; font-size:11px; }
  .t { font-size:12.5px; line-height:1.35; }
</style></head>
<body>
<header>
  <h1>Planova — captured artboards</h1>
  <p>${totalBoards} screens · ${totalPngs} rendered PNGs · source HTML alongside each card</p>
  <p>Extracted from the Claude Design canvas artifact <code>E3BCxpMCA1Fs6w2HJG6AoW</code>. Click a card for the standalone HTML.</p>
</header>
${sections.join('\n')}
</body></html>`;

writeFileSync(join(ROOT, 'index.html'), html, 'utf8');
console.log(JSON.stringify({ totalBoards, totalPngs, index: join(ROOT, 'index.html') }, null, 2));
