// Condense every artboard into a structural digest for gap analysis.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const dirs = [
  { dir: 'docs/design/planova/desktop', label: 'DESKTOP' },
  { dir: 'docs/design/planova/mobile', label: 'MOBILE' },
];

const decode = (s) =>
  s
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

const stripTags = (s) => decode(s.replace(/<[^>]*>/g, ' '));

const grab = (html, re, map = (m) => stripTags(m[1])) => {
  const out = [];
  for (const m of html.matchAll(re)) {
    const v = map(m);
    if (v && v.length > 1 && v.length < 160) out.push(v);
  }
  return [...new Set(out)];
};

const TERMS = {
  roles: /\b(Root user|Planner|Group Admin|Admin|IC|Participant|Marshal)\b/gi,
  time: /\b(T\+0|snapshot|waypoint|state|time span|timeline|master clock)\b/gi,
  live: /\b(live monitor|no signal|GPS|location|checkpoint|at risk)\b/gi,
  change: /\b(shift|hold|version|re-plan|republish|updated)\b/gi,
  compare: /\b(on time|late|missed|not yet|attendance|present|absent)\b/gi,
  geo: /\b(zone|polygon|no-go|obstacle|entrance|exit|floor plan|floorplan)\b/gi,
  data: /\b(CSV|import|export|paste|duplicate|copy)\b/gi,
  notify: /\b(ack|acknowledge|notification|push)\b/gi,
};

const lines = [];
const termTotals = {};
for (const [k] of Object.entries(TERMS)) termTotals[k] = 0;

for (const { dir, label } of dirs) {
  lines.push(`\n# ${label}\n`);
  const files = readdirSync(dir).filter((f) => f.endsWith('.html')).sort();
  for (const file of files) {
    const html = readFileSync(join(dir, file), 'utf8');
    const title = decode((html.match(/<title>([^<]*)<\/title>/) || [, file])[1]);
    const headings = grab(html, /<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/g, (m) => stripTags(m[2]));
    const buttons = grab(html, /<button[^>]*>([\s\S]*?)<\/button>/g, (m) => stripTags(m[1]));
    const tabs = grab(html, /role="tab"[^>]*>([\s\S]*?)<\//g);
    const labels = grab(html, /<label[^>]*>([\s\S]*?)<\/label>/g);

    const body = stripTags(html.replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' '));
    const found = {};
    for (const [k, re] of Object.entries(TERMS)) {
      const hits = [...new Set((body.match(re) || []).map((s) => s.toLowerCase()))];
      if (hits.length) {
        found[k] = hits.slice(0, 6);
        termTotals[k] += hits.length;
      }
    }

    lines.push(`## ${file.replace('.dc.html', '')} — ${title}`);
    if (headings.length) lines.push(`- headings: ${headings.slice(0, 10).join(' | ')}`);
    if (tabs.length) lines.push(`- tabs: ${tabs.slice(0, 8).join(' | ')}`);
    if (buttons.length) lines.push(`- actions: ${buttons.slice(0, 14).join(' | ')}`);
    if (labels.length) lines.push(`- fields: ${labels.slice(0, 8).join(' | ')}`);
    const termKeys = Object.keys(found);
    if (termKeys.length) lines.push(`- terms: ${termKeys.map((k) => `${k}=[${found[k].join(',')}]`).join(' ')}`);
  }
}

lines.push('\n# TERM TOTALS\n');
for (const [k, v] of Object.entries(termTotals)) lines.push(`- ${k}: ${v}`);

writeFileSync('docs/design/planova/_digest.md', lines.join('\n'), 'utf8');
console.log(JSON.stringify({ bytes: lines.join('\n').length, termTotals }, null, 2));
