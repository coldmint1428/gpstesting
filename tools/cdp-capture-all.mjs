// Large-scale capture: auto-attach to EVERY target (page + all frames), enable Network
// on each, reload, then persist every response body. Also snapshots each target's DOM.
// Usage: node tools/cdp-capture-all.mjs <outDir> [port] [waitMs] [urlFilterRegex]
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const outDir = process.argv[2] || 'docs/design/net';
const port = Number(process.argv[3] || 9222);
const waitMs = Number(process.argv[4] || 20000);
const urlFilter = new RegExp(process.argv[5] || 'claude|anthropic', 'i');
const base = `http://127.0.0.1:${port}`;

mkdirSync(outDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const version = await fetch(`${base}/json/version`).then((r) => r.json());
const ws = new WebSocket(version.webSocketDebuggerUrl);
let nextId = 1;
const pending = new Map();
const infoBySession = new Map();
const responses = new Map();

ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data));
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    return;
  }
  if (msg.method === 'Target.attachedToTarget') {
    const { sessionId, targetInfo } = msg.params;
    infoBySession.set(sessionId, targetInfo);
    const tag = `[${targetInfo.type}] ${String(targetInfo.url).slice(0, 80)}`;
    console.log('attached:', tag);
    send('Network.enable', { maxTotalBufferSize: 500 * 1024 * 1024, maxResourceBufferSize: 200 * 1024 * 1024 }, sessionId).catch(
      () => {},
    );
    send('Runtime.enable', {}, sessionId).catch(() => {});
    return;
  }
  if (msg.method === 'Network.responseReceived') {
    const { requestId, response, type } = msg.params;
    responses.set(`${msg.sessionId}|${requestId}`, {
      url: response.url,
      status: response.status,
      mime: response.mimeType,
      type,
      sessionId: msg.sessionId,
    });
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

await send('Target.setAutoAttach', {
  autoAttach: true,
  waitForDebuggerOnStart: false,
  flatten: true,
  filter: [{ type: 'page' }, { type: 'iframe' }, { type: 'worker' }],
});
await sleep(1500);

// Reload the claude.ai top page so the whole tree re-fetches under instrumentation.
const top = [...infoBySession.entries()].find(
  ([, t]) => t.type === 'page' && String(t.url).includes('claude.ai'),
);
if (!top) {
  console.error('top page not found; sessions:', [...infoBySession.values()].map((t) => t.url));
  process.exit(1);
}
const [topSession] = top;
await send('Page.enable', {}, topSession).catch(() => {});
await send('Page.reload', { ignoreCache: true }, topSession);
console.log(`reloaded, waiting ${waitMs}ms ...`);
await sleep(waitMs);

const saved = [];
let n = 0;
for (const [key, info] of responses) {
  if (!urlFilter.test(info.url)) continue;
  const [sessionId, requestId] = key.split('|');
  try {
    const body = await send('Network.getResponseBody', { requestId }, sessionId);
    const text = body.base64Encoded ? Buffer.from(body.body, 'base64').toString('utf8') : body.body;
    if (!text || text.length < 20) continue;
    const u = new URL(info.url);
    const fileName =
      `${String(n++).padStart(3, '0')}-${u.hostname.replace(/[^a-z0-9.]/gi, '')}` +
      `${u.pathname.replace(/[^a-z0-9._-]/gi, '_').slice(-80)}.txt`;
    const path = join(outDir, fileName.slice(0, 160));
    writeFileSync(path, text, 'utf8');
    saved.push({ url: info.url.slice(0, 200), status: info.status, mime: info.mime, type: info.type, bytes: text.length, path });
  } catch {}
}

// DOM snapshot of every live target.
const doms = [];
for (const [sessionId, t] of infoBySession) {
  try {
    const r = await send('Runtime.evaluate', { expression: 'document.documentElement.outerHTML', returnByValue: true }, sessionId);
    const html = r?.result?.value || '';
    if (!html) continue;
    const path = join(outDir, `dom-${doms.length}-${t.type}.html`);
    writeFileSync(path, html, 'utf8');
    doms.push({ type: t.type, url: String(t.url).slice(0, 120), bytes: html.length, path });
  } catch {}
}

writeFileSync(join(outDir, 'index.json'), JSON.stringify({ saved, doms }, null, 2), 'utf8');
console.log(JSON.stringify({ captured: saved.length, sessions: infoBySession.size, doms, sample: saved.slice(0, 40) }, null, 2));
ws.close();
process.exit(0);
