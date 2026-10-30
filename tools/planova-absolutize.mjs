// Rewrite root-relative artifact asset paths to absolute frame-host URLs so the
// dumped artboard documents render standalone (offline of the canvas app).
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const HOST = 'https://69949477-2a52-4899-896f-3bffa03015a5.frame.claudeusercontent.com';
const dirs = process.argv.slice(2);
if (!dirs.length) dirs.push('docs/design/planova/desktop', 'docs/design/planova/mobile');

let totalFiles = 0;
let totalHits = 0;
for (const dir of dirs) {
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (!f.endsWith('.html') || !statSync(p).isFile()) continue;
    let html = readFileSync(p, 'utf8');
    const before = html.length;
    let hits = 0;
    for (const prefix of ['/_blob/', '/_f/']) {
      const re = new RegExp(`(?<!${HOST.replace(/[.]/g, '\\.')})${prefix.replace(/\//g, '\\/')}`, 'g');
      html = html.replace(re, (m) => {
        hits++;
        return HOST + prefix;
      });
    }
    if (hits) {
      writeFileSync(p, html, 'utf8');
      totalFiles++;
      totalHits += hits;
    }
    if (html.includes('https://https://')) console.log('WARN double-prefix in', f, before, '->', html.length);
  }
}
console.log(`absolutized ${totalHits} refs across ${totalFiles} files`);
