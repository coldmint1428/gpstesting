// Minimal CDP client: open a tab, navigate, dump rendered HTML + screenshot.
// Usage: node tools/cdp-extract.mjs "<url>" [outDir] [port]
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const url = process.argv[2];
const outDir = process.argv[3] || 'docs/design';
const port = Number(process.argv[4] || 9222);
const base = `http://127.0.0.1:${port}`;

if (!url) {
  console.error('usage: node tools/cdp-extract.mjs <url> [outDir] [port]');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function j(path, init) {
  const res = await fetch(base + path, init);
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

const version = await j('/json/version');
console.log('browser:', version.Browser || JSON.stringify(version).slice(0, 200));

const target = await j(`/json/new?${encodeURIComponent('about:blank')}`, { method: 'PUT' });
if (!target.webSocketDebuggerUrl) {
  console.error('no webSocketDebuggerUrl; got:', JSON.stringify(target).slice(0, 300));
  process.exit(1);
}

const ws = new WebSocket(target.webSocketDebuggerUrl);
let nextId = 1;
const pending = new Map();
const events = [];

function send(method, params = {}) {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data));
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  } else if (msg.method) {
    events.push(msg.method);
  }
});

await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve, { once: true });
  ws.addEventListener('error', (e) => reject(new Error('ws error: ' + (e.message || 'unknown'))), { once: true });
});
console.log('cdp connected');

await send('Page.enable');
await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', {
  width: 1600,
  height: 1200,
  deviceScaleFactor: 1,
  mobile: false,
});

await send('Page.navigate', { url });

// Wait for load, then give the SPA time to paint artboards.
for (let i = 0; i < 60; i++) {
  if (events.includes('Page.loadEventFired')) break;
  await sleep(500);
}
await sleep(6000);

const title = await send('Runtime.evaluate', { expression: 'document.title', returnByValue: true });
const href = await send('Runtime.evaluate', { expression: 'location.href', returnByValue: true });
const textLen = await send('Runtime.evaluate', {
  expression: 'document.body ? document.body.innerText.length : -1',
  returnByValue: true,
});
const html = await send('Runtime.evaluate', {
  expression: 'document.documentElement.outerHTML',
  returnByValue: true,
});

const htmlStr = html?.result?.value ?? '';
mkdirSync(outDir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const htmlPath = join(outDir, `artifact-${stamp}.html`);
writeFileSync(htmlPath, htmlStr, 'utf8');

let pngPath = '';
try {
  const shot = await send('Page.captureScreenshot', {
    format: 'png',
    captureBeyondViewport: true,
  });
  if (shot?.data) {
    pngPath = join(outDir, `artifact-${stamp}.png`);
    writeFileSync(pngPath, Buffer.from(shot.data, 'base64'));
  }
} catch (e) {
  console.log('screenshot failed:', e.message);
}

console.log(JSON.stringify({
  title: title?.result?.value,
  href: href?.result?.value,
  visibleTextLength: textLen?.result?.value,
  htmlBytes: htmlStr.length,
  htmlPath,
  pngPath,
}, null, 2));

ws.close();
process.exit(0);
