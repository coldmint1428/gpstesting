// Build an inventory of the Planova artifact from captured data.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const netDir = 'docs/design/net';
const frameJsonPath = join(netDir, readdirSync(netDir).find((f) => /^013-claude\.ai_api_frame_/.test(f)));
const frame = JSON.parse(readFileSync(frameJsonPath, 'utf8'));

writeFileSync('docs/design/planova-files.json', JSON.stringify(frame, null, 2), 'utf8');

const files = frame.files;
const project = files.filter((f) => f.path.startsWith('project/'));
const desktop = project.filter((f) => /^project\/D-.*\.dc\.html$/.test(f.path));
const mobile = project.filter((f) => /^project\/M-.*\.dc\.html$/.test(f.path));
const support = project.filter((f) => !/\.dc\.html$/.test(f.path));

// Artboard titles from any rendered canvas DOM capture (pick the richest).
const domCandidates = [
  ...readdirSync('docs/design').filter((f) => /^artifact-.*\.html$/.test(f)).map((f) => join('docs/design', f)),
  ...readdirSync(netDir).filter((f) => /^dom-.*\.html$/.test(f)).map((f) => join(netDir, f)),
  ...readdirSync('docs/design/frames').filter((f) => /\.html$/.test(f)).map((f) => join('docs/design/frames', f)),
];
let dom = '';
for (const p of domCandidates) {
  try {
    const t = readFileSync(p, 'utf8');
    if (t.includes('aria-label="Artboard')) dom = t;
  } catch {}
}
const labels = [...dom.matchAll(/aria-label="Artboard (\d+) of (\d+): ([^"]+)"/g)].map((m) => ({
  n: Number(m[1]),
  total: Number(m[2]),
  title: m[3],
}));
const uniq = [];
const seen = new Set();
for (const l of labels) {
  const k = l.n;
  if (seen.has(k)) continue;
  seen.add(k);
  uniq.push(l);
}
uniq.sort((a, b) => a.n - b.n);

const lines = [];
lines.push('# Planova — artifact inventory');
lines.push('');
lines.push(`- Artifact: \`${frame.title}\` (kind: ${frame.kind}, ver: ${frame.ver})`);
lines.push(`- Data sign-in required: **${frame.dataSignInRequired}**`);
lines.push(`- Files in manifest: ${files.length} (project: ${project.length})`);
lines.push(`- Desktop artboards: ${desktop.length} · Mobile artboards: ${mobile.length}`);
lines.push(`- Rendered artboard count (canvas): ${uniq[0]?.total ?? 'unknown'}`);
lines.push('');
lines.push('## Rendered artboard titles (desktop page)');
lines.push('');
for (const a of uniq) lines.push(`${a.n}. ${a.title}`);
lines.push('');
lines.push('## Desktop artboard files');
lines.push('');
lines.push('| File | Bytes |');
lines.push('|---|---|');
for (const f of desktop) lines.push(`| \`${f.path.replace('project/', '')}\` | ${f.size.toLocaleString()} |`);
lines.push('');
lines.push('## Mobile artboard files');
lines.push('');
lines.push('| File | Bytes |');
lines.push('|---|---|');
for (const f of mobile) lines.push(`| \`${f.path.replace('project/', '')}\` | ${f.size.toLocaleString()} |`);
lines.push('');
lines.push('## Support files');
lines.push('');
lines.push('| File | Bytes |');
lines.push('|---|---|');
for (const f of support) lines.push(`| \`${f.path}\` | ${f.size.toLocaleString()} |`);

writeFileSync('docs/design/planova-inventory.md', lines.join('\n'), 'utf8');

console.log(
  JSON.stringify(
    {
      titles: uniq.length,
      desktop: desktop.length,
      mobile: mobile.length,
      support: support.length,
      firstFive: uniq.slice(0, 5),
      wrote: ['docs/design/planova-inventory.md', 'docs/design/planova-files.json'],
    },
    null,
    2,
  ),
);
