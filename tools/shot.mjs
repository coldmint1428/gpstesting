#!/usr/bin/env node
// Screenshot a page through the Chrome DevTools Protocol.
//
//   node tools/shot.mjs http://localhost:5178/dev/preview.html shots/board.png 1440 1000 2500
//
// Assumes a browser is already listening on the debugging port (start one with
//   msedge.exe --headless=new --remote-debugging-port=9222 --user-data-dir=<dir>)
// and talks to it directly: no puppeteer, no driver binary, just WebSocket and JSON.
//
// Prints console errors and uncaught exceptions, because a blank screenshot and a working one look identical
// until you know whether the page threw.

import fs from 'node:fs'

const PORT = process.env.CDP_PORT || '9222'
const [, , url, out, width = '1440', height = '1000', waitMs = '2200', clickSelector, sessionFile] = process.argv

if (!url || !out) {
  console.error('usage: node tools/shot.mjs <url> <out.png> [width] [height] [waitMs]')
  process.exit(2)
}

async function cdpHttp(path, method = 'GET') {
  const res = await fetch(`http://127.0.0.1:${PORT}${path}`, { method })
  const text = await res.text()
  try {
    return JSON.parse(text)
  } catch {
    return text
  }
}

class Cdp {
  constructor(ws) {
    this.ws = ws
    this.id = 0
    this.pending = new Map()
    this.events = []
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data)
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id)
        this.pending.delete(msg.id)
        if (msg.error) reject(new Error(`${msg.error.message} (${msg.error.code})`))
        else resolve(msg.result)
      } else if (msg.method) {
        this.events.push(msg)
      }
    })
  }

  send(method, params = {}) {
    const id = ++this.id
    this.ws.send(JSON.stringify({ id, method, params }))
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }))
  }
}

function open(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url)
    ws.addEventListener('open', () => resolve(ws))
    ws.addEventListener('error', (event) => reject(new Error(`websocket error: ${event.message || 'unknown'}`)))
  })
}

const target = await cdpHttp('/json/new?about:blank', 'PUT')
if (!target.webSocketDebuggerUrl) {
  console.error('could not open a tab:', JSON.stringify(target).slice(0, 400))
  process.exit(1)
}

const ws = await open(target.webSocketDebuggerUrl)
const cdp = new Cdp(ws)

await cdp.send('Page.enable')
await cdp.send('Runtime.enable')
await cdp.send('Log.enable')
// Without this the dev server's CSS modules can come back from cache and a screenshot shows the previous styles.
await cdp.send('Network.enable')
await cdp.send('Network.setCacheDisabled', { cacheDisabled: true })
await cdp.send('Emulation.setDeviceMetricsOverride', {
  width: Number(width),
  height: Number(height),
  deviceScaleFactor: 1,
  mobile: false,
})

// A page behind a login: seed the session into localStorage before any app script runs, so the client finds it
// on load exactly as it would after a real sign-in.
if (sessionFile) {
  const session = JSON.parse(fs.readFileSync(sessionFile, 'utf8'))
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `try{localStorage.setItem(${JSON.stringify(session.key)}, ${JSON.stringify(session.value)})}catch(e){}`,
  })
  console.log(`session seeded for ${session.userId}`)
}

await cdp.send('Page.navigate', { url })

// Wait for the load event, then a little longer for tiles, fonts and the first animation frame.
const deadline = Date.now() + 15000
while (Date.now() < deadline && !cdp.events.some((e) => e.method === 'Page.loadEventFired')) {
  await new Promise((r) => setTimeout(r, 100))
}
await new Promise((r) => setTimeout(r, Number(waitMs)))

// Optionally press something first, so a screenshot can show what an action did rather than only a still page.
// '-' means "no click" (an empty argument is dropped by some shells).
if (clickSelector && clickSelector !== '-') {
  const clicked = await cdp.send('Runtime.evaluate', {
    expression: `(() => { const el = document.querySelector(${JSON.stringify(clickSelector)}); if (!el) return 'missing'; el.click(); return 'clicked'; })()`,
    returnByValue: true,
  })
  console.log(`click ${clickSelector}: ${clicked.result.value}`)
  await new Promise((r) => setTimeout(r, 900))
}

const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
fs.mkdirSync(out.replace(/[\\/][^\\/]+$/, ''), { recursive: true })
fs.writeFileSync(out, Buffer.from(shot.data, 'base64'))

// What the page said, so a broken screen cannot pass as a quiet one.
const problems = []
for (const event of cdp.events) {
  if (event.method === 'Runtime.exceptionThrown') {
    const d = event.params.exceptionDetails
    problems.push(`EXCEPTION ${d.exception?.description || d.text}`)
  }
  if (event.method === 'Runtime.consoleAPICalled' && event.params.type === 'error') {
    problems.push(`CONSOLE ${event.params.args.map((a) => a.value ?? a.description ?? '').join(' ')}`)
  }
  if (event.method === 'Log.entryAdded' && event.params.entry.level === 'error') {
    problems.push(`LOG ${event.params.entry.text}`)
  }
}

const probe = await cdp.send('Runtime.evaluate', {
  expression:
    'JSON.stringify({ at: location.pathname, text: (document.body.innerText || "").length, frames: document.querySelectorAll(".pv-frame").length, markers: document.querySelectorAll(".pv-marker").length, head: (() => { const h = document.querySelector(".pv-board-head"); if (!h) return "missing"; const cs = getComputedStyle(h); return { display: cs.display, cls: h.className, kids: h.children.length, w: Math.round(h.getBoundingClientRect().width) }; })() })',
  returnByValue: true,
})

console.log(`wrote ${out}`)
console.log('page:', probe.result.value)
console.log(problems.length ? problems.join('\n') : 'no console errors')

ws.close()
await cdpHttp(`/json/close/${target.id}`)
