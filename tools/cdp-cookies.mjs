// List cookies (browser-wide) filtered by domain substring.
// Usage: node tools/cdp-cookies.mjs [domainSubstring] [port]
const match = process.argv[2] || 'claude.ai';
const port = Number(process.argv[3] || 9222);
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

const send = (method, params = {}) => {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((res, rej) => pending.set(id, { resolve: res, reject: rej }));
};

await new Promise((res, rej) => {
  ws.addEventListener('open', res, { once: true });
  ws.addEventListener('error', () => rej(new Error('ws error')), { once: true });
});

const { cookies } = await send('Storage.getCookies', {});
const now = Date.now() / 1000;
const rows = cookies
  .filter((c) => c.domain.includes(match))
  .map((c) => ({
    name: c.name,
    domain: c.domain,
    expires: c.expires === -1 ? 'session' : new Date(c.expires * 1000).toISOString(),
    expired: c.expires !== -1 && c.expires < now,
    httpOnly: c.httpOnly,
    len: (c.value || '').length,
  }))
  .sort((a, b) => a.name.localeCompare(b.name));

console.log(JSON.stringify({ count: rows.length, rows }, null, 2));
ws.close();
process.exit(0);
