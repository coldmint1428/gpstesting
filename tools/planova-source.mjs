// Download every file of the Planova artifact (project sources + runtime) from the frame host.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';

const BASE =
  'https://69949477-2a52-4899-896f-3bffa03015a5.frame.claudeusercontent.com/_f/1792749594-bdac/';
const OUT = 'docs/design/planova/source';

const manifest = JSON.parse(readFileSync('docs/design/planova-files.json', 'utf8'));
const files = manifest.files.map((f) => f.path);
console.log('files in manifest:', files.length);

const results = [];
for (const p of files) {
  const dest = join(OUT, p);
  try {
    const r = await fetch(BASE + p);
    if (!r.ok) {
      results.push({ p, status: r.status, skipped: true });
      continue;
    }
    const buf = Buffer.from(await r.arrayBuffer());
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, buf);
    results.push({ p, bytes: buf.length });
  } catch (e) {
    results.push({ p, error: e.message.slice(0, 80) });
  }
}

const ok = results.filter((r) => r.bytes);
const total = ok.reduce((a, r) => a + r.bytes, 0);
console.log(`downloaded ${ok.length}/${files.length} files, ${(total / 1048576).toFixed(2)} MB`);
const failed = results.filter((r) => !r.bytes);
if (failed.length) console.log('failed:', JSON.stringify(failed.slice(0, 10), null, 1));
writeFileSync(join(OUT, '_download-report.json'), JSON.stringify(results, null, 2), 'utf8');
