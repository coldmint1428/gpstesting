// Render each dumped artboard HTML in a real browser and screenshot it full-size.
// Usage: node tools/planova-shots.mjs <htmlDir> <pngDir> [port] [limit] [scale]
import { readdirSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const htmlDir = process.argv[2] || 'docs/design/planova/desktop';
const pngDir = process.argv[3] || 'docs/design/planova/desktop-png';
const port = Number(process.argv[4] || 9222);
const limit = Number(process.argv[5] || 999);
const scale = Number(process.argv[6] || 2);

mkdirSync(pngDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = `http://127.0.0.1:${port}`;

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

await new Promise((res, rej) => {
  ws.addEventListener('open', res, { once: true });
  ws.addEventListener('error', () => rej(new Error('ws error')), { once: true });
});

const files = readdirSync(htmlDir)
  .filter((f) => f.endsWith('.html'))
  .sort()
  .slice(0, limit);

console.log(`rendering ${files.length} artboards from ${htmlDir}`);

const results = [];
for (const file of files) {
  const url = pathToFileURL(join(process.cwd(), htmlDir, file)).href;
  let targetId = null;
  try {
    const created = await send('Target.createTarget', { url: 'about:blank', background: true });
    targetId = created.targetId;
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    await send('Page.enable', {}, sessionId);
    await send('Page.navigate', { url }, sessionId);

    // Wait for layout to settle.
    let size = null;
    for (let i = 0; i < 30; i++) {
      await sleep(300);
      const r = await send(
        'Runtime.evaluate',
        {
          expression: `(() => {
            const d = document.documentElement, b = document.body;
            return {
              ready: document.readyState,
              w: Math.max(d.scrollWidth, b ? b.scrollWidth : 0, d.clientWidth),
              h: Math.max(d.scrollHeight, b ? b.scrollHeight : 0, d.clientHeight),
            };
          })()`,
          returnByValue: true,
        },
        sessionId,
      );
      const v = r.result?.value;
      if (v && v.ready === 'complete' && v.w > 100 && v.h > 100) {
        size = v;
        if (i >= 3) break;
      }
    }
    if (!size) throw new Error('no layout');

    const width = Math.min(Math.max(size.w, 320), 2000);
    const height = Math.min(Math.max(size.h, 400), 4000);
    await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: scale, mobile: false }, sessionId);
    await sleep(600);

    const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }, sessionId);
    const pngPath = join(pngDir, file.replace(/\.html$/, '.png'));
    writeFileSync(pngPath, Buffer.from(shot.data, 'base64'));
    results.push({ file, width, height, png: pngPath });
    console.log(`${file.padEnd(46)} ${width}x${height}`);
  } catch (e) {
    results.push({ file, error: e.message.slice(0, 120) });
    console.log(`${file.padEnd(46)} FAILED ${e.message.slice(0, 80)}`);
  } finally {
    if (targetId) await send('Target.closeTarget', { targetId }).catch(() => {});
  }
}

writeFileSync(join(pngDir, '_index.json'), JSON.stringify(results, null, 2), 'utf8');
console.log('done:', results.filter((r) => r.png).length, 'screenshots');
ws.close();
process.exit(0);
