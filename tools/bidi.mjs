// tools/bidi.mjs -- just enough WebDriver BiDi to drive a Firefox page, and nothing else.
//
// Used by tools/bench_harness.mjs (the two-browser bench test) and tools/probe.mjs (ad-hoc questions
// asked of a page that is already open). Firefox 141 and later have no CDP, and its Remote Agent
// refuses an HTTP `POST /session` ("The handshake request must use GET method"), so the session is
// created on the BiDi socket itself with `session.new`.
//
// The only command that matters here is `script.evaluate`: everything the bench does is driven by
// real events dispatched into the page, because what it listens for is a pointerdown on a Leaflet
// element and pointermove on the window, and no input protocol can be trusted to reach those.

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// Prepended to every snippet: the bench is a Leaflet map, so almost everything is about finding the
// element a planner would have put their finger on.
export const HELPERS = `
  const $ = (s) => document.querySelector(s)
  const $$ = (s) => Array.from(document.querySelectorAll(s))
  const centreOf = (el) => { const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height } }
  const pointer = (type, x, y, target) => (target || window).dispatchEvent(new PointerEvent(type, {
    clientX: x, clientY: y, bubbles: true, cancelable: true, button: 0,
    buttons: type === 'pointerup' ? 0 : 1, pointerId: 1, pointerType: 'mouse', isPrimary: true,
  }))
  const mouseClick = (x, y, target) => (target || window).dispatchEvent(new MouseEvent('click', {
    clientX: x, clientY: y, bubbles: true, cancelable: true, button: 0,
  }))
  const mapEl = () => $('[data-testid="bench-map"]')
  const onMap = (fx, fy) => { const r = mapEl().getBoundingClientRect(); return { x: r.left + r.width * fx, y: r.top + r.height * fy } }
  const areaRow = (name) => $$('[data-testid^="area-row-"]').find((el) => el.getAttribute('data-testid') === 'area-row-' + name) || null
  const outlineOf = (name) => { const row = areaRow(name); const p = row && row.querySelector('svg.area-thumb polygon'); return p ? p.getAttribute('points') : null }
  const stripText = () => { const el = $('[data-testid="bench-hint"]'); return el ? el.innerText.trim() : '' }
  const pageError = () => { const el = $('[data-testid="page-error"]'); return el ? el.innerText.trim() : '' }
`

export class Driver {
  constructor(name, port) {
    this.name = name
    this.port = port
    this.next = 0
    this.pending = new Map()
    this.logs = []
  }

  async open() {
    this.ws = new WebSocket('ws://127.0.0.1:' + this.port + '/session')
    await new Promise((resolve, reject) => {
      this.ws.addEventListener('open', resolve, { once: true })
      this.ws.addEventListener('error', () => reject(new Error(this.name + ': no BiDi socket on ' + this.port)), {
        once: true,
      })
    })
    this.ws.addEventListener('message', (event) => this.onMessage(JSON.parse(event.data)))

    const session = await this.send('session.new', { capabilities: { alwaysMatch: {} } })
    this.sessionId = session.sessionId

    const tree = await this.send('browsingContext.getTree', {})
    this.context = tree.contexts[0].context
    // `log.entryAdded` is the only error channel this Firefox has: the `runtime` module does not
    // exist (subscribing to runtime.exceptionThrown is refused with "Module runtime does not exist"),
    // which is why a page that wants to report its own errors installs a trap as well -- see arm().
    await this.send('session.subscribe', { events: ['log.entryAdded'] })
    return this
  }

  // Record what the page itself sees go wrong, from inside the page.
  async arm() {
    await this.js(`
      window.__harnessErrors = window.__harnessErrors || []
      window.addEventListener('error', (event) => window.__harnessErrors.push('error: ' + (event.message || '')))
      window.addEventListener('unhandledrejection', (event) => window.__harnessErrors.push('rejection: ' + String(event.reason)))
      return JSON.stringify(true)
    `)
  }

  async heard() {
    return (await this.json('return JSON.stringify(window.__harnessErrors || [])')) || []
  }

  onMessage(message) {
    if (message.id) {
      const waiting = this.pending.get(message.id)
      if (!waiting) return
      this.pending.delete(message.id)
      if (message.error) waiting.reject(new Error(this.name + ' ' + message.error + ' (' + waiting.method + ')'))
      else waiting.resolve(message.result)
      return
    }

    if (message.method === 'log.entryAdded') {
      const entry = message.params
      this.logs.push({ level: entry.level, text: String(entry.text || '') })
    }
  }

  send(method, params = {}) {
    const id = ++this.next
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(this.name + ': ' + method + ' timed out'))
      }, 120000)
      this.pending.set(id, {
        method,
        resolve: (value) => {
          clearTimeout(timer)
          resolve(value)
        },
        reject: (error) => {
          clearTimeout(timer)
          reject(error)
        },
      })
      this.ws.send(JSON.stringify({ id, method, params }))
    })
  }

  // Run a snippet in the page. The snippet is the body of an ASYNC function, so it may await, and it
  // must `return` something JSON-serialisable -- by convention JSON.stringify(...), so nothing
  // depends on how BiDi serialises objects.
  async js(body) {
    const result = await this.send('script.evaluate', {
      expression: '(async () => {\n' + HELPERS + '\n' + body + '\n})()',
      target: { context: this.context },
      awaitPromise: true,
      resultOwnership: 'none',
    })

    if (result.type === 'exception') {
      const details = result.exceptionDetails || {}
      const thrown = details.exception && details.exception.value !== undefined ? details.exception.value : ''
      throw new Error(this.name + ' page threw: ' + (details.text || '') + ' ' + String(thrown))
    }
    return result.result ? result.result.value : undefined
  }

  async json(body) {
    const raw = await this.js(body)
    return raw === undefined || raw === null ? null : JSON.parse(raw)
  }

  async until(body, { timeout = 15000, every = 250, label = 'condition' } = {}) {
    const started = Date.now()
    while (Date.now() - started < timeout) {
      const value = await this.json(body)
      if (value) return { value, ms: Date.now() - started }
      await sleep(every)
    }
    throw new Error(this.name + ': ' + label + ' did not happen in ' + timeout + 'ms')
  }

  async navigate(url) {
    await this.send('browsingContext.navigate', { context: this.context, url, wait: 'complete' })
  }

  // Errors that are this APP's. The browser logs plenty that is not: OneMap's tile server has a
  // cookie refused for an invalid domain, Cloudflare's bot cookie is refused as cross-site. Left in,
  // those made the harness's last check fail -- twice -- while the bench worked perfectly, so the
  // filter is a list of what it means for this page to have gone wrong, and everything it drops is
  // kept and reported rather than hidden.
  errors() {
    const mine = []
    const ignored = []
    const appFailure =
      /not defined|is not a function|cannot read|undefined is not|typeerror|referenceerror|uncaught|\[vue warn\]|is not valid|too large|failed to fetch|permission denied|row-level security|invalid jwt|500|401|403/i

    for (const entry of this.logs) {
      const text = String(entry.text || '')
      if (entry.level === 'exception' || appFailure.test(text)) mine.push(entry)
      else if (entry.level === 'error') ignored.push(text)
    }
    this.ignored = ignored
    return mine
  }

  close() {
    try {
      this.ws.close()
    } catch {
      // closing a socket that is already gone is not a result worth reporting
    }
  }

  async end() {
    try {
      await this.send('session.end', {})
    } catch {
      // a session that is already gone is exactly the state this is trying to reach
    }
    this.close()
  }
}
