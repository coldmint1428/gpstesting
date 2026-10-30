// Evaluate an expression inside a CDP target whose URL matches a substring.
// Usage: node tools/cdp-eval.mjs <urlSubstring> <expressionFile|-> [port]
import { readFileSync } from 'node:fs';

const match = process.argv[2];
const exprArg = process.argv[3];
const port = Number(process.argv[4] || 9222);
const base = `http://127.0.0.1:${port}`;

const expression = exprArg === '-' ? readFileSync(0, 'utf8') : exprArg;

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

const { targetInfos } = await send('Target.getTargets');
const target = targetInfos.find((t) => String(t.url).includes(match));
if (!target) {
  console.error('no target matching:', match);
  console.error(targetInfos.map((t) => `  [${t.type}] ${t.url.slice(0, 100)}`).join('\n'));
  process.exit(1);
}

const { sessionId } = await send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
const res = await send(
  'Runtime.evaluate',
  { expression, returnByValue: true, awaitPromise: true, includeCommandLineAPI: true },
  sessionId,
);

if (res.exceptionDetails) {
  console.error('EXCEPTION:', JSON.stringify(res.exceptionDetails).slice(0, 1500));
  process.exit(1);
}
console.log(JSON.stringify(res.result?.value ?? res.result, null, 2));
ws.close();
process.exit(0);
