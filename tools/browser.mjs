// A browser you can drive with a script: click, type, drag, press a key, wait, reload, and hold more than one
// tab at once. Built straight on the Chrome DevTools Protocol, like tools/shot.mjs, because that is the smallest
// thing that produces REAL input: a trusted click is not the same event as calling element.click(), and a drag
// that Leaflet ignores is exactly the bug this is meant to catch.
//
//     node tools/run.mjs dev/checks/board-smoke.mjs
//
// The browser is Edge in headless mode. If nothing is listening on the debugging port this starts one
// (stdio is 'ignore': a piped child inside the sandbox is a pipe this process may not open).
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'

// Any Chromium will do — the harness only needs the DevTools protocol. Edge is first because it is what this
// machine happens to have; a Chrome or Chromium install is picked up without a change. BROWSER (or MSEDGE) points
// at a binary that is somewhere else.
const BROWSER_CANDIDATES = [
  process.env.BROWSER,
  process.env.MSEDGE,
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  path.join(os.homedir(), 'AppData\\Local\\Google\\Chrome\\Application\\chrome.exe'),
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  path.join(os.homedir(), 'AppData\\Local\\Microsoft\\Edge\\Application\\msedge.exe'),
].filter(Boolean)

export class CheckFailure extends Error {}

function explain(value, limit = 220) {
  const text = typeof value === 'string' ? value : JSON.stringify(value)
  if (!text) return String(value)
  return text.length > limit ? text.slice(0, limit) + '…' : text
}

class Cdp {
  constructor(ws) {
    this.ws = ws
    this.id = 0
    this.pending = new Map()
    this.listeners = new Set()
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data)
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id)
        this.pending.delete(msg.id)
        if (msg.error) reject(new Error(`${msg.error.message} (${msg.error.code})`))
        else resolve(msg.result)
      } else if (msg.method) {
        for (const listener of this.listeners) listener(msg)
      }
    })
  }

  send(method, params = {}) {
    const id = ++this.id
    this.ws.send(JSON.stringify({ id, method, params }))
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }))
  }

  on(listener) {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }
}

// ---------- the debugging endpoint ----------

async function endpoint(port) {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/version`)
    if (res.ok) return await res.json()
  } catch {
    /* not listening */
  }
  return null
}

async function passThrough(port, pathname, method = 'GET') {
  const res = await fetch(`http://127.0.0.1:${port}${pathname}`, { method })
  const text = await res.text()
  try {
    return JSON.parse(text)
  } catch {
    return text
  }
}

async function startBrowser(port, profileDir) {
  const exe = BROWSER_CANDIDATES.find((candidate) => fs.existsSync(candidate))
  if (!exe) {
    throw new Error(`no Chrome, Chromium or Edge found; set BROWSER to the executable, or start one on port ${port}`)
  }
  fs.mkdirSync(profileDir, { recursive: true })
  const child = spawn(
    exe,
    [
      '--headless=new',
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profileDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-gpu',
      '--hide-scrollbars',
      '--disable-extensions',
      '--disable-background-timer-throttling',
      'about:blank',
    ],
    { detached: true, stdio: 'ignore', windowsHide: true },
  )
  child.unref()

  const deadline = Date.now() + 20000
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 250))
    const version = await endpoint(port)
    if (version) return version
  }
  throw new Error(`the browser did not come up on port ${port} within 20s`)
}

// ---------- a tab ----------

const MODIFIERS = { Alt: 1, Control: 2, Meta: 4, Shift: 8 }
const KEYS = {
  Enter: { code: 'Enter', keyCode: 13, text: '\r' },
  Escape: { code: 'Escape', keyCode: 27 },
  Tab: { code: 'Tab', keyCode: 9 },
  Backspace: { code: 'Backspace', keyCode: 8 },
  Delete: { code: 'Delete', keyCode: 46 },
  ArrowLeft: { code: 'ArrowLeft', keyCode: 37 },
  ArrowUp: { code: 'ArrowUp', keyCode: 38 },
  ArrowRight: { code: 'ArrowRight', keyCode: 39 },
  ArrowDown: { code: 'ArrowDown', keyCode: 40 },
  Space: { code: 'Space', keyCode: 32, text: ' ' },
}

export class Tab {
  constructor(cdp, target, { port, label }) {
    this.cdp = cdp
    this.target = target
    this.port = port
    this.label = label || 'tab'
    this.checks = []
    this.problems = []
    this.loads = 0
    this.width = 1440
    this.height = 1000

    cdp.on((event) => {
      if (event.method === 'Page.loadEventFired') this.loads += 1
      if (event.method === 'Runtime.exceptionThrown') {
        const d = event.params.exceptionDetails
        this.problems.push(`EXCEPTION ${d.exception?.description || d.text}`)
      }
      if (event.method === 'Runtime.consoleAPICalled' && event.params.type === 'error') {
        this.problems.push(`CONSOLE ${event.params.args.map((a) => a.value ?? a.description ?? '').join(' ')}`)
      }
      // A 404 is reported with its URL: "Failed to load resource" on its own does not say which one, and a check
      // that fails because of a missing favicon is a check nobody will trust.
      if (event.method === 'Network.responseReceived' && event.params.response.status >= 400) {
        this.problems.push(`HTTP ${event.params.response.status} ${event.params.response.url}`)
      }
      if (event.method === 'Log.entryAdded' && event.params.entry.level === 'error') {
        const text = event.params.entry.text
        if (!/^Failed to load resource/.test(text)) this.problems.push(`LOG ${text}`)
      }
    })
  }

  // ---- bookkeeping: every assertion is recorded, and a failed one throws with what was actually on screen ----
  record(ok, what, detail) {
    this.checks.push({ ok, what, detail })
    if (!ok) throw new CheckFailure(`${this.label}: ${what}${detail ? ' — ' + detail : ''}`)
    return true
  }

  pass(what) {
    return this.record(true, what)
  }

  async setup({ width = 1440, height = 1000, session = null } = {}) {
    this.width = Number(width)
    this.height = Number(height)
    await this.cdp.send('Page.enable')
    await this.cdp.send('Runtime.enable')
    await this.cdp.send('Log.enable')
    await this.cdp.send('Network.enable')
    // A dev server's CSS comes back from cache and a screenshot shows the previous styles, which once hid a fix.
    await this.cdp.send('Network.setCacheDisabled', { cacheDisabled: true })
    await this.cdp.send('Emulation.setDeviceMetricsOverride', {
      width: this.width,
      height: this.height,
      deviceScaleFactor: 1,
      mobile: false,
    })
    if (session) await this.seedSession(session)
    // The resource-timing buffer holds 250 entries by default, and this app loads a map: a plan switch fills it with
    // tile requests, so the write a check is counting can be dropped and `performance.getEntriesByType('resource')`
    // answers 0 for a request that certainly happened. Raise it before any app script runs.
    await this.cdp.send('Page.addScriptToEvaluateOnNewDocument', {
      source: 'try{performance.setResourceTimingBufferSize(5000)}catch(e){}',
    })
    return this
  }

  // Seed a signed-in session before any app script runs, so the client finds it on load exactly as after a login.
  async seedSession(session) {
    const source = `try{localStorage.setItem(${JSON.stringify(session.key)}, ${JSON.stringify(session.value)})}catch(e){console.error('seed failed', e)}`
    await this.cdp.send('Page.addScriptToEvaluateOnNewDocument', { source })
  }

  // ---- navigation ----
  async goto(url, { settle = 500, timeout = 20000 } = {}) {
    const before = this.loads
    await this.cdp.send('Page.navigate', { url })
    await this.waitForLoad(before, timeout)
    if (settle) await this.sleep(settle)
    return this
  }

  async reload({ settle = 500, timeout = 20000 } = {}) {
    const before = this.loads
    await this.cdp.send('Page.reload', { ignoreCache: true })
    await this.waitForLoad(before, timeout)
    if (settle) await this.sleep(settle)
    return this
  }

  async waitForLoad(before, timeout) {
    const deadline = Date.now() + timeout
    while (this.loads <= before && Date.now() < deadline) await this.sleep(50)
    // A page that never fires load is a failure, not a slow page.
    if (this.loads <= before) throw new CheckFailure(`${this.label}: the page did not finish loading in ${timeout} ms`)
  }

  sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }

  // ---- reading the page ----
  async eval(expression) {
    const result = await this.cdp.send('Runtime.evaluate', {
      expression: typeof expression === 'function' ? `(${expression})()` : expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: true,
    })
    if (result.exceptionDetails) {
      throw new CheckFailure(
        `${this.label}: evaluating failed — ${result.exceptionDetails.exception?.description || result.exceptionDetails.text}`,
      )
    }
    return result.result.value
  }

  async url() {
    return this.eval('location.href')
  }

  async text(selector) {
    return this.eval(`(() => {
      const el = document.querySelector(${JSON.stringify(selector)})
      return el ? (el.innerText || el.textContent || '').trim() : null
    })()`)
  }

  async bodyText() {
    return this.eval('document.body ? (document.body.innerText || "").trim() : ""')
  }

  async count(selector) {
    return this.eval(`document.querySelectorAll(${JSON.stringify(selector)}).length`)
  }

  async has(selector) {
    return this.eval(`!!document.querySelector(${JSON.stringify(selector)})`)
  }

  // Scroll, let the scroll commit, then read. Chrome updates layout synchronously on scrollIntoView, so a rect read
  // in the same eval is already correct — but the *input pipeline* maps a click through the compositor's scroll
  // offset, which catches up a frame later. Reading both at once made the first click after a big scroll land at
  // the old coordinates: it hit the page background and the handler never ran. Two animation frames is enough --
  // but only for a tab that is being painted. A second tab in the same browser is in the background, where
  // requestAnimationFrame never fires at all, so the wait is raced against a timer and then given a few ms in Node.
  async rect(selector, index = 0) {
    const found = await this.eval(`(() => {
      const el = document.querySelectorAll(${JSON.stringify(selector)})[${index}]
      if (!el) return false
      el.scrollIntoView({ block: 'center', inline: 'center' })
      return true
    })()`)
    if (!found) return null
    await this.eval(`Promise.race([
      new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
      new Promise((done) => setTimeout(done, 150)),
    ])`)
    await this.sleep(30)
    return this.eval(`(() => {
      const el = document.querySelectorAll(${JSON.stringify(selector)})[${index}]
      if (!el) return null
      const r = el.getBoundingClientRect()
      if (!r.width && !r.height) return null
      return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height, left: r.left, top: r.top }
    })()`)
  }

  // ---- waiting ----
  async waitFor(selector, { timeout = 8000 } = {}) {
    const deadline = Date.now() + timeout
    while (Date.now() < deadline) {
      if (await this.has(selector)) return true
      await this.sleep(80)
    }
    throw new CheckFailure(`${this.label}: waited ${timeout} ms for ${selector} to appear; it never did`)
  }

  // Anything the page can be asked, asked repeatedly until true: a button that becomes enabled, a count that
  // settles, a list that stops growing. The predicate is JavaScript, evaluated in the page.
  async waitUntil(expression, { timeout = 8000, what = expression } = {}) {
    const deadline = Date.now() + timeout
    let last = null
    while (Date.now() < deadline) {
      last = await this.eval(`(() => { try { return !!(${expression}) } catch (e) { return 'threw: ' + e.message } })()`)
      if (last === true) return true
      await this.sleep(80)
    }
    throw new CheckFailure(`${this.label}: waited ${timeout} ms for ${what}; last answer was ${explain(last)}`)
  }

  async waitForText(selector, expected, { contains = true, timeout = 8000 } = {}) {    const deadline = Date.now() + timeout
    let seen = null
    while (Date.now() < deadline) {
      seen = await this.text(selector)
      if (seen != null && (contains ? seen.includes(expected) : seen === expected)) return true
      await this.sleep(80)
    }
    throw new CheckFailure(
      `${this.label}: expected ${selector} to ${contains ? 'contain' : 'be'} ${explain(expected)}, saw ${explain(seen)}`,
    )
  }

  // A frame or tile is moving for a few hundred ms after a click; wait until it stops before measuring.
  async settle(ms = 250) {
    await this.sleep(ms)
    return this
  }

  // ---- input ----
  async mouse(type, x, y, extra = {}) {
    await this.cdp.send('Input.dispatchMouseEvent', {
      type,
      x: Math.round(x),
      y: Math.round(y),
      button: 'left',
      buttons: type === 'mouseReleased' ? 0 : 1,
      clickCount: 1,
      ...extra,
    })
  }

  async click(selector, { index = 0, timeout = 8000, settle = 250, modifiers = 0 } = {}) {
    await this.waitFor(selector, { timeout })
    let box = await this.rect(selector, index)
    if (!box) throw new CheckFailure(`${this.label}: ${selector}[${index}] exists but has no size to click`)
    // A rect is a measurement, and the page can move between the measurement and the press: a scroll that has just
    // been asked for, a panel that has just changed height, an inspector that has just filled. The press then lands
    // at the old coordinates -- on the page background or on a neighbour -- and the handler never runs, which reads
    // as "the feature is broken". So ask the page what is under the point, and measure again if it is not the
    // element (or a child of it). Three tries is enough for a layout to settle; after that the click is made at the
    // last measurement, so a genuinely covered element still fails in the check that asked for it.
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const over = await this.eval(`(() => {
        const el = document.querySelectorAll(${JSON.stringify(selector)})[${index}]
        if (!el) return false
        const at = document.elementFromPoint(${box.x}, ${box.y})
        return !!at && (at === el || el.contains(at))
      })()`)
      if (over) break
      await this.sleep(80)
      box = await this.rect(selector, index)
      if (!box) throw new CheckFailure(`${this.label}: ${selector}[${index}] vanished before it could be clicked`)
    }
    // modifiers is the CDP bitfield (Alt 1, Ctrl 2, Meta 4, Shift 8): the press and the release both carry it, so
    // the click event the page sees has shiftKey set, which is the difference between "select" and "extend".
    await this.mouse('mousePressed', box.x, box.y, { modifiers })
    await this.mouse('mouseReleased', box.x, box.y, { modifiers })
    if (settle) await this.sleep(settle)
    return box
  }

  async type(selector, value, { index = 0, clear = true } = {}) {
    await this.click(selector, { index, settle: 80 })
    // The click focuses on mousedown, but the renderer can still be busy when the first key arrives -- a page that
    // re-renders in the background (a live update, a re-read) makes that window wider. Keys sent before the focus
    // lands go nowhere: Ctrl+A selects nothing, Backspace deletes nothing, and the text is *appended* to whatever was
    // in the box ("+5:00" + "+0:10"). Wait for the focus, then make sure the box really is empty before typing.
    const pick = `[...document.querySelectorAll(${JSON.stringify(selector)})][${index}]`
    await this.waitUntil(`(() => { const el = ${pick}; return !!el && document.activeElement === el })()`, {
      what: `${selector} to have the focus`,
    })
    if (clear) {
      for (let tries = 0; tries < 5; tries += 1) {
        await this.press('Control+a')
        await this.press('Backspace')
        const left = await this.eval(`(() => { const el = ${pick}; return el ? el.value : '' })()`)
        if (left === '') break
      }
    }
    // insertText is what a keyboard sends for plain characters; it also updates v-model.
    await this.cdp.send('Input.insertText', { text: value })
    await this.sleep(150)
    return this
  }

  async press(combo) {
    const parts = combo.split('+')
    const name = parts.pop()
    let modifiers = 0
    for (const part of parts) {
      const bit = MODIFIERS[part]
      if (!bit) throw new CheckFailure(`${this.label}: unknown modifier ${part} in ${combo}`)
      modifiers |= bit
    }
    const key = KEYS[name] || { code: `Key${name.toUpperCase()}`, keyCode: name.toUpperCase().charCodeAt(0) }
    const text = modifiers === 0 || modifiers === 8 ? key.text : undefined
    await this.cdp.send('Input.dispatchKeyEvent', {
      type: text ? 'keyDown' : 'rawKeyDown',
      modifiers,
      key: name,
      code: key.code,
      windowsVirtualKeyCode: key.keyCode,
      nativeVirtualKeyCode: key.keyCode,
      text,
    })
    await this.cdp.send('Input.dispatchKeyEvent', {
      type: 'keyUp',
      modifiers,
      key: name,
      code: key.code,
      windowsVirtualKeyCode: key.keyCode,
      nativeVirtualKeyCode: key.keyCode,
    })
    await this.sleep(120)
    return this
  }

  // A drag is a press, a path and a release -- the same stream a finger produces, so a handler listening on
  // pointerdown/pointermove sees it and a handler that only listens for click does not.
  async drag(selector, dx, dy, { index = 0, steps = 14, settle = 400 } = {}) {
    const box = await this.rect(selector, index)
    if (!box) throw new CheckFailure(`${this.label}: cannot drag ${selector}[${index}]: not visible`)
    await this.mouse('mousePressed', box.x, box.y)
    for (let step = 1; step <= steps; step += 1) {
      await this.mouse('mouseMoved', box.x + (dx * step) / steps, box.y + (dy * step) / steps)
      await this.sleep(16)
    }
    await this.mouse('mouseReleased', box.x + dx, box.y + dy)
    if (settle) await this.sleep(settle)
    return this
  }

  // ---- assertions ----
  async assertText(selector, expected, { exact = true, timeout = 6000 } = {}) {
    const deadline = Date.now() + timeout
    let seen = null
    while (Date.now() < deadline) {
      seen = await this.text(selector)
      const ok = seen != null && (exact ? seen === expected : seen.includes(expected))
      if (ok) return this.record(true, `${selector} is ${explain(expected, 60)}`)
      await this.sleep(80)
    }
    return this.record(
      false,
      `expected ${selector} ${exact ? 'to be' : 'to contain'} ${explain(expected)}`,
      `saw ${explain(seen)}`,
    )
  }

  async assertContains(selector, expected, { timeout = 6000 } = {}) {
    return this.assertText(selector, expected, { exact: false, timeout })
  }

  async assertCount(selector, expected, { timeout = 4000 } = {}) {
    const deadline = Date.now() + timeout
    let seen = null
    while (Date.now() < deadline) {
      seen = await this.count(selector)
      if (seen === expected) return this.record(true, `${selector} count is ${expected}`)
      await this.sleep(80)
    }
    return this.record(false, `expected ${expected} of ${selector}`, `saw ${seen}`)
  }

  /**
   * Assert something true. Three shapes are accepted, and they mean different things:
   *   boolean   -- decided here, in Node;
   *   function  -- an async predicate, awaited here;
   *   string    -- a JavaScript *expression*, evaluated in the page and required to answer exactly true.
   * The string form is the common one, and it used to be taken as a plain value: a non-empty string is truthy, so
   * every assertion written that way passed whether or not the page agreed. Anything that is not exactly `true`
   * now fails, and a thrown exception in the page fails with its message.
   */
  async assertThat(what, condition) {
    let ok
    if (typeof condition === 'function') {
      ok = await condition()
    } else if (typeof condition === 'string') {
      ok = await this.eval(`(() => { try { return !!(${condition}) } catch (e) { return 'threw: ' + e.message } })()`)
    } else {
      ok = condition
    }
    const passed = ok === true
    return this.record(passed, what, passed ? '' : `the page answered ${explain(ok)}`)
  }

  /**
   * An HTTP failure the check causes on purpose. A refused edit is a 4xx from the database, and the button that was
   * pressed is supposed to show it in words — which means the page *will* log a failed request. Naming it here
   * excuses that one response and nothing else, and if the refusal never happened the check fails, because an
   * expected error that never arrived means the thing being proved did not happen either.
   */
  expectHttp(status, urlPart, { count = 1 } = {}) {
    this.expectedHttp = this.expectedHttp || []
    this.expectedHttp.push({ status, urlPart, count })
  }

  /**
   * The problems that were not excused with expectHttp(), plus any excuse that never happened. Both the check's own
   * assertNoErrors() and the runner's final verdict read this, so an expected refusal is excused once and the same
   * way in both places.
   */
  unexplained() {
    const expected = (this.expectedHttp || []).map((entry) => ({ ...entry }))
    const problems = []
    for (const problem of this.problems) {
      const hit = expected.find(
        (entry) => entry.count > 0 && problem.startsWith(`HTTP ${entry.status} `) && problem.includes(entry.urlPart),
      )
      if (hit) hit.count -= 1
      else problems.push(problem)
    }
    return { problems, missing: expected.filter((entry) => entry.count > 0) }
  }

  async assertNoErrors() {
    const { problems, missing } = this.unexplained()
    // A blank screen and a working one look identical until you know the page threw.
    return this.record(
      problems.length === 0 && missing.length === 0,
      'no console errors or exceptions',
      [
        ...problems,
        ...missing.map((entry) => `the expected HTTP ${entry.status} from ${entry.urlPart} never happened`),
      ].join(' | '),
    )
  }

  // ---- output ----
  async shot(file) {
    const shot = await this.cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
    fs.mkdirSync(path.dirname(path.resolve(file)), { recursive: true })
    fs.writeFileSync(file, Buffer.from(shot.data, 'base64'))
    return file
  }

  async close() {
    try {
      await passThrough(this.port, `/json/close/${this.target.id}`)
    } catch {
      /* already gone */
    }
  }
}

// ---------- the browser ----------

export async function openBrowser({ port = process.env.CDP_PORT || 9222, profile = '.tmp/edge-runner' } = {}) {
  if (!(await endpoint(port))) await startBrowser(port, path.resolve(profile))

  const tabs = []
  let counter = 0

  async function newTab(options = {}) {
    const target = await passThrough(port, '/json/new?about:blank', 'PUT')
    if (!target.webSocketDebuggerUrl) throw new Error('could not open a tab: ' + explain(target, 300))
    const ws = await new Promise((resolve, reject) => {
      const socket = new WebSocket(target.webSocketDebuggerUrl)
      socket.addEventListener('open', () => resolve(socket))
      socket.addEventListener('error', () => reject(new Error('websocket to the tab failed')))
    })
    counter += 1
    const tab = new Tab(new Cdp(ws), target, { port, label: options.label || `tab${counter}` })
    await tab.setup(options)
    tabs.push(tab)
    if (options.url) await tab.goto(options.url, { settle: options.settle ?? 500 })
    return tab
  }

  async function close() {
    for (const tab of tabs) await tab.close()
  }

  return { newTab, close, port }
}
