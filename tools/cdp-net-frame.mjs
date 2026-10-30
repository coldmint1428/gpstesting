// Capture the canvas frame's own network traffic, then reload that frame only.
// Usage: node tools/cdp-net-frame.mjs <outDir> [port] [waitMs]
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const outDir = process.argv[2] || 'docs/design/frame-net';
const port = Number(process.argv[3] || 9222);
const waitMs = Number(process.argv[4] || 25000);
mkdirSync(outDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const version = await fetch(`http://127.0.0.1:${port}/json/version`).then((r) => r.json());
const ws = new WebSocket(version.webSocketDebuggerUrl);
let nextId = 1;
const pending = new Map();
const responses = new Map();

ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data));
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    return;
  }
  if (msg.method === 'Network.responseReceived') {
    const { requestId, response, type } = msg.params;
    responses.set(requestId, { url: response.url, status: response.status, mime: response.mimeType, type });
  }
});

const send = (method, params = {}, sessionId) => {
  const id = nextId++;
  const payload = { id, method, params };
  if (sessionId) payload.sessionId = sessionId;
  ws.send(JSON.stringify(payload));
  return new Promise((res, rej) => pending.set(id, { resolve: res, reject: rej }));
};

await new Promise((res, rej) => {
  ws.addEventListener('open', res, { once: true });
  ws.addEventListener('error', () => rej(new Error('ws error')), { once: true });
});

const { targetInfos } = await send('Target.getTargets');
const frame = targetInfos.find((t) => String(t.url).includes('frame.claudeusercontent.com'));
if (!frame) {
  console.error('frame not found:', targetInfos.map((t) => `${t.type} ${t.url.slice(0, 60)}`));
  process.exit(1);
}
const { sessionId } = await send('Target.attachToTarget', { targetId: frame.targetId, flatten: true });
await send('Network.enable', { maxTotalBufferSize: 300 * 1024 * 1024 }, sessionId);
await send('Page.enable', {}, sessionId).catch(() => {});
console.log('network enabled on canvas frame, reloading it ...');

await send('Runtime.evaluate', { expression: 'location.reload()' }, sessionId);
await sleep(waitMs);

const rows = [...responses.values()];
console.log(JSON.stringify(rows.map((r) => ({ t: r.type, s: r.status, m: r.mime, u: r.url.slice(0, 150) })), null, 1));

let n = 0;
const interesting = [];
for (const [requestId, info] of responses) {
  if (!/dc\.html|project\/|_blob|\/p\/|files?\?/i.test(info.url)) continue;
  try {
    const body = await send('Network.getResponseBody', { requestId }, sessionId);
    const text = body.base64Encoded ? Buffer.from(body.body, 'base64').toString('utf8') : body.body;
    const name = `src-${String(n++).padStart(3, '0')}-${info.url.split('/').pop().split('?')[0].replace(/[^a-z0-9._-]/gi, '_')}`;
    writeFileSync(join(outDir, name.slice(0, 120)), text, 'utf8');
    interesting.push({ url: info.url.slice(0, 150), bytes: text.length, name });
  } catch {}
}
console.log('saved source bodies:', JSON.stringify(interesting, null, 1));
ws.close();
process.exit(0);
