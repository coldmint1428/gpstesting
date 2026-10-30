// Dump every rendered artboard document from the Planova canvas.
// Usage: node tools/planova-dump.mjs <outDir> [port]
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const outDir = process.argv[2] || 'docs/design/planova/desktop';
const port = Number(process.argv[3] || 9222);
const base = `http://127.0.0.1:${port}`;
mkdirSync(outDir, { recursive: true });

const version = await fetch(`${base}/json/version`).then((r) => r.json());
const ws = new WebSocket(version.webSocketDebuggerUrl);
let nextId = 1;
const pending = new Map();

ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data));
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  }
});

const send = (method, params = {}, sessionId) => {
  const id = nextId++;
  const payload = { id, method, params };
  if (sessionId) payload.sessionId = sessionId;
  ws.send(JSON.stringify(payload));
  return new Promise((res, rej) => pending.set(id, { resolve: res, reject: rej }));
};

const evaluate = async (sessionId, expression) => {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
  if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 300));
  return r.result?.value;
};

await new Promise((res, rej) => {
  ws.addEventListener('open', res, { once: true });
  ws.addEventListener('error', () => rej(new Error('ws error')), { once: true });
});

const { targetInfos } = await send('Target.getTargets');
const frame = targetInfos.find((t) => String(t.url).includes('frame.claudeusercontent.com'));
if (!frame) {
  console.error('canvas frame not found');
  process.exit(1);
}
const { sessionId } = await send('Target.attachToTarget', { targetId: frame.targetId, flatten: true });

const count = await evaluate(sessionId, `document.querySelectorAll('[data-mega-artboard]').length`);
console.log('artboards:', count);

const written = [];
for (let i = 0; i < count; i++) {
  const info = await evaluate(
    sessionId,
    `(() => {
      const el = document.querySelectorAll('[data-mega-artboard]')[${i}];
      const f = el.querySelector('iframe');
      const doc = f && f.contentDocument;
      const name = el.getAttribute('data-mega-artboard') || ('artboard-' + ${i});
      const html = doc && doc.documentElement ? doc.documentElement.outerHTML : '';
      const rect = el.getBoundingClientRect();
      return { name, bytes: html.length, html, w: Math.round(rect.width), h: Math.round(rect.height), title: el.querySelector('[data-mega-title-text]')?.textContent || '' };
    })()`,
  );
  if (!info || !info.html) {
    console.log(`${i}: EMPTY ${info?.name}`);
    continue;
  }
  const file = join(outDir, info.name.replace(/[^a-z0-9._-]/gi, '_'));
  writeFileSync(file, info.html, 'utf8');
  written.push({ i, name: info.name, title: info.title, bytes: info.bytes, file });
  console.log(`${String(i).padStart(2)} ${info.title.padEnd(52)} ${String(info.bytes).padStart(7)}B`);
}

writeFileSync(join(outDir, '_index.json'), JSON.stringify(written, null, 2), 'utf8');
console.log('written:', written.length);
ws.close();
process.exit(0);
