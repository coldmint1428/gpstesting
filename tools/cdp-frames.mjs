// Enumerate every CDP target (pages + iframes) and dump each document's HTML.
// Usage: node tools/cdp-frames.mjs [outDir] [port]
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const outDir = process.argv[2] || 'docs/design/frames';
const port = Number(process.argv[3] || 9222);
const base = `http://127.0.0.1:${port}`;

mkdirSync(outDir, { recursive: true });

const version = await fetch(`${base}/json/version`).then((r) => r.json());
const ws = new WebSocket(version.webSocketDebuggerUrl);

let nextId = 1;
const pending = new Map();
const listeners = [];

ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data));
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  }
  for (const l of listeners) l(msg);
});

function send(method, params = {}, sessionId) {
  const id = nextId++;
  const payload = { id, method, params };
  if (sessionId) payload.sessionId = sessionId;
  ws.send(JSON.stringify(payload));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

await new Promise((res, rej) => {
  ws.addEventListener('open', res, { once: true });
  ws.addEventListener('error', () => rej(new Error('ws error')), { once: true });
});

await send('Target.setDiscoverTargets', { discover: true });

const { targetInfos } = await send('Target.getTargets');
console.log('targets:');
for (const t of targetInfos) {
  console.log(`  [${t.type}] ${t.title} :: ${String(t.url).slice(0, 120)}`);
}

const results = [];
let idx = 0;
for (const t of targetInfos) {
  if (!['page', 'iframe', 'webview'].includes(t.type)) continue;
  idx++;
  try {
    const { sessionId } = await send('Target.attachToTarget', { targetId: t.targetId, flatten: true });
    const html = await send(
      'Runtime.evaluate',
      { expression: 'document.documentElement.outerHTML', returnByValue: true },
      sessionId,
    );
    const value = html?.result?.value ?? '';
    const txt = await send(
      'Runtime.evaluate',
      { expression: 'document.body ? document.body.innerText.slice(0,4000) : ""', returnByValue: true },
      sessionId,
    );
    const safe = `${String(idx).padStart(2, '0')}-${new URL(t.url.startsWith('http') ? t.url : 'https://x.invalid/blank').hostname}`;
    const path = join(outDir, `${safe}.html`);
    writeFileSync(path, value, 'utf8');
    results.push({
      type: t.type,
      url: t.url,
      title: t.title,
      bytes: value.length,
      textChars: (txt?.result?.value || '').length,
      path,
    });
    await send('Target.detachFromTarget', { sessionId });
  } catch (e) {
    results.push({ type: t.type, url: t.url, error: e.message.slice(0, 200) });
  }
}

console.log(JSON.stringify(results, null, 2));
ws.close();
process.exit(0);
