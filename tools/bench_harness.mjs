// tools/bench_harness.mjs -- two browsers, one bench, driven through WebDriver BiDi.
//
// WHY THIS EXISTS. Everything about the bench's collaboration is decided by things a build cannot
// see: two sessions of one account, a lock answered by the database while a finger is still down, a
// frame arriving from somebody else's browser. `npm run build` passed while /polygon threw on load
// for a whole round -- a missing import is a legal reference to a global -- so "it builds" is not
// evidence for any of this. This drives the real page in two real browsers and reports what happened.
//
// It has earned its keep: it found a drawn area being saved without itself, an in-flight save's reply
// resurrecting a shape that had just been deleted, a lock let go of before the change it protected
// was saved, and a press refused in silence -- all four silent, and all four now fixed and covered
// here.
//
// HOW TO RUN IT. Two Firefox instances, each with its own profile (so each has its own login and its
// own sessionStorage: the same account in two browsers, which is the case all of this started from),
// each started with --remote-debugging-port, and the dev server running:
//
//   BENCH_EMAIL=... BENCH_PASSWORD=... node tools/bench_harness.mjs http://localhost:5174
//
// The account comes from the environment and has no default: this file is in the repository, and a
// test account's password in a repository is a password in a repository.
//
// They are NOT started by this script: Firefox needs named pipes for its own multi-process IPC, which
// the confined DSH sandbox does not allow, so it is launched from a shell with full access. This
// script only talks HTTP and WebSocket (see tools/bidi.mjs).
//
// WHAT IT TOUCHES. It makes its own area (named per run), works on that, and deletes it again -- so a
// run leaves the bench exactly as it found it, and a run that dies halfway leaves something the next
// run sweeps up. It never touches anybody else's shapes.
//
// A NOTE ON PATIENCE. This bench is 3.7 MB of a 4 MB cap and one save of it was measured at 22
// seconds, so every check that waits for a save waits tens of seconds. That is a fact about the
// bench, not about the harness, and it is worth knowing on its own.

import { Driver, sleep } from './bidi.mjs'

const BASE = process.argv[2] || process.env.BENCH_BASE || 'http://localhost:5174'
const EMAIL = process.env.BENCH_EMAIL || ''
const PASSWORD = process.env.BENCH_PASSWORD || ''
const PORTS = { A: 9222, B: 9223 }

// The area this run makes and then deletes. Named per run so a run that dies halfway leaves something
// that cannot be mistaken for the next run's shape.
const AREA_NAME = 'HARNESS-' + Math.floor(Date.now() / 1000)

// ---------------------------------------------------------------- results
const results = []
function record(ok, title, detail = '') {
  results.push({ ok, title, detail })
  console.log((ok ? '  ok   ' : ' FAIL  ') + title + (detail ? '  -- ' + detail : ''))
}
function note(text) {
  console.log('       ' + text)
}

// ------------------------------------------------------------- page level
async function signIn(driver) {
  await driver.navigate(BASE + '/polygon')
  // Either the login form or the bench itself: a profile keeps its session, so a second run of this
  // harness is already signed in.
  await driver.until('return JSON.stringify(Boolean($(\'[data-testid="email"]\') || mapEl()))', {
    timeout: 30000,
    label: 'the login form or the bench',
  })
  const already = await driver.json('return JSON.stringify(Boolean(mapEl()))')

  if (!already) {
    await driver.js(`
      const email = $('[data-testid="email"]')
      email.value = ${JSON.stringify(EMAIL)}
      email.dispatchEvent(new Event('input', { bubbles: true }))
      const password = $('[data-testid="password"]')
      password.value = ${JSON.stringify(PASSWORD)}
      password.dispatchEvent(new Event('input', { bubbles: true }))
      $('[data-testid="auth-submit"]').click()
      return JSON.stringify(true)
    `)
  }

  await driver.until('return JSON.stringify(Boolean(mapEl()))', {
    timeout: 30000,
    label: already ? 'the bench' : 'the bench to open after signing in',
  })
  // The bench draws its map before the document has arrived; wait until the loading line is gone.
  await driver.until('return JSON.stringify(!document.body.innerText.includes("Loading the bench"))', {
    label: 'the canvas to load',
  })
  await driver.arm()
}

// Wait for a save to be over. Three phases, because "no badge" is ambiguous: a save that has not
// STARTED looks exactly like a save that has finished. It matters here -- the page queues one save at
// a time and a save of this bench takes about twenty seconds, so a save asked for a moment after
// another one appears up to half a minute later.
async function settle(driver, { appear = 60000, finish = 120000, quiet = 1200 } = {}) {
  const started = Date.now()
  const badge = 'return JSON.stringify(Boolean($(\'[data-testid="saving-badge"]\')))'

  const seen = await (async () => {
    while (Date.now() - started < appear) {
      await sleep(150)
      if (await driver.json(badge)) return true
    }
    return false
  })()
  if (!seen) return Date.now() - started

  const finishBy = Date.now() + finish
  while (Date.now() < finishBy) {
    if (!(await driver.json(badge))) break
    await sleep(200)
  }

  let absentSince = null
  while (Date.now() < finishBy + quiet + 5000) {
    if (await driver.json(badge)) absentSince = null
    else {
      if (absentSince === null) absentSince = Date.now()
      if (Date.now() - absentSince >= quiet) return Date.now() - started
    }
    await sleep(150)
  }
  return -1
}

// What one window shows for a shape, sampled over a few seconds. Sampled rather than polled once: a
// change that flashed past between two polls is still a change, and "nothing moved" is a much
// stronger statement when the whole series is flat.
async function watch(driver, name, ms, every = 200) {
  const series = []
  const started = Date.now()
  while (Date.now() - started < ms) {
    const outline = await driver.json(`return JSON.stringify(outlineOf(${JSON.stringify(name)}))`)
    series.push({ at: Date.now() - started, outline })
    await sleep(every)
  }
  return series
}

async function main() {
  if (!EMAIL || !PASSWORD) {
    console.error('Set BENCH_EMAIL and BENCH_PASSWORD to the test account this should sign in as.')
    process.exit(2)
  }
  console.log('bench harness: ' + BASE + ' as ' + EMAIL)
  let A = null
  let B = null

  try {
    A = await new Driver('A', PORTS.A).open()
    B = await new Driver('B', PORTS.B).open()

    // ---- does the page run at all? -------------------------------------
    await signIn(A)
    await signIn(B)
    const visibility = await Promise.all([
      A.json('return JSON.stringify(document.visibilityState)'),
      B.json('return JSON.stringify(document.visibilityState)'),
    ])
    note('visibilityState: A=' + visibility[0] + '  B=' + visibility[1])

    const loaded = await Promise.all([
      A.json(`return JSON.stringify({ map: Boolean(mapEl()), error: pageError(), rows: $$('[data-testid^="area-row-"]').length, size: ($('[data-testid="canvas-size"]') || {}).innerText || '' })`),
      B.json(`return JSON.stringify({ map: Boolean(mapEl()), error: pageError(), rows: $$('[data-testid^="area-row-"]').length, size: ($('[data-testid="canvas-size"]') || {}).innerText || '' })`),
    ])
    note('A loaded the bench: ' + JSON.stringify(loaded[0]))
    note('B loaded the bench: ' + JSON.stringify(loaded[1]))
    record(
      loaded[0].map && loaded[1].map && !loaded[0].error && !loaded[1].error,
      'both windows open the bench without a page error',
      loaded[0].rows + ' and ' + loaded[1].rows + ' areas on the canvas',
    )

    // ---- presence: the same account in two windows ---------------------
    const seen = await A.until(
      `const el = $('[data-testid="bench-here-now"]')
       return JSON.stringify(el ? el.innerText.replace(/\\s+/g, ' ').trim() : '')`,
      { timeout: 20000, label: 'the header to list the other window' },
    )
    record(
      /another window/i.test(seen.value),
      'a second window of the same account is listed as its own planner',
      '"' + seen.value + '" after ' + seen.ms + 'ms',
    )

    // ---- a run that died leaves its area behind: take it away ----------
    const leftovers = await A.json(
      `return JSON.stringify($$('[data-testid^="area-row-HARNESS-"]').map((el) => el.getAttribute('data-testid').slice('area-row-'.length)))`,
    )
    for (const name of leftovers) {
      await A.js(`window.confirm = () => true; areaRow(${JSON.stringify(name)}).click(); return JSON.stringify(true)`)
      await A.js(`$('[data-testid="area-delete-${name}"]').click(); return JSON.stringify(true)`)
      await settle(A)
    }
    if (leftovers.length) note('swept ' + leftovers.length + ' area(s) left by an earlier run: ' + leftovers.join(', '))

    // ---- a new area is drawn and saved ---------------------------------
    await A.js('$(\'[data-testid="draw-areas"]\').click(); return JSON.stringify(true)')
    await A.js(`
      const map = mapEl()
      for (const [fx, fy] of [[0.35, 0.35], [0.5, 0.3], [0.45, 0.55]]) {
        const p = onMap(fx, fy)
        mouseClick(p.x, p.y, map)
      }
      return JSON.stringify(true)
    `)
    await A.until('return JSON.stringify(Boolean($(\'[data-testid="area-finish"]\')))', { label: 'the Finish button' })
    await A.js('$(\'[data-testid="area-finish"]\').click(); return JSON.stringify(true)')
    await A.until('return JSON.stringify(Boolean($(\'[data-testid="area-name"]\')))', { label: 'the name form' })
    await A.js(`
      const input = $('[data-testid="area-name"]')
      input.value = ${JSON.stringify(AREA_NAME)}
      input.dispatchEvent(new Event('input', { bubbles: true }))
      $('[data-testid="area-save"]').click()
      return JSON.stringify(true)
    `)
    // Saving the draft name is what puts the whole thing down: finishDraft() creates the area AND sets
    // mode to null, which is the save. There is no separate Done button at this point.
    await A.until(`return JSON.stringify(Boolean(areaRow(${JSON.stringify(AREA_NAME)})))`, { label: 'the new area' })
    const aSave = await settle(A)
    const aSaved = await A.json(`return JSON.stringify({ error: pageError(), row: Boolean(areaRow(${JSON.stringify(AREA_NAME)})) })`)
    record(aSaved.row && !aSaved.error, 'a drawn area saves without a page error', 'the save took ' + aSave + 'ms')

    // A shape that did not exist a moment ago is not delivered live -- only a change to a shape
    // already on the other screen is -- so B re-reads the bench to get it. This is the one boundary
    // live frames draw, and it is checked rather than assumed.
    await B.navigate(BASE + '/polygon')
    await B.until('return JSON.stringify(Boolean(mapEl()))', { timeout: 30000, label: 'B to reload' })
    await B.until('return JSON.stringify(!document.body.innerText.includes("Loading the bench"))', { label: 'B to load' })
    let bRow = null
    try {
      bRow = await B.until(`return JSON.stringify(Boolean(areaRow(${JSON.stringify(AREA_NAME)})))`, {
        timeout: 30000,
        label: 'the area to reach B',
      })
    } catch {
      bRow = null
    }
    record(
      Boolean(bRow),
      'the area that was just saved is really on the bench',
      bRow ? 'B found it after ' + bRow.ms + 'ms' : 'B NEVER SAW IT: the save went out without the shape it was made for',
    )
    if (!bRow) throw new Error('stopping here: without the area on both screens the rest cannot be tested')

    // ---- live frames: A drags a dot, B watches -------------------------
    await A.js(`areaRow(${JSON.stringify(AREA_NAME)}).click(); return JSON.stringify(true)`)
    const dots = await A.until('return JSON.stringify($$(".bench-vertex").length)', { label: 'the dots of the area' })
    record(dots.value === 3, 'selecting the area shows its three dots', dots.value + ' dots')

    const outlineBefore = await A.json(`return JSON.stringify(outlineOf(${JSON.stringify(AREA_NAME)}))`)

    // The press, and two small moves to warm the path up. A frame published before the other page's
    // channel has finished joining is simply lost -- there is no replay, which is the point of a
    // frame -- and B has only just reloaded. What is MEASURED is the burst that follows this.
    const press = await A.json(`
      const dot = $('.bench-vertex')
      const host = dot.closest('.leaflet-marker-icon') || dot
      const c = centreOf(host)
      pointer('pointerdown', c.x, c.y, host)
      for (let i = 1; i <= 2; i++) pointer('pointermove', c.x + i * 5, c.y + i * 3)
      return JSON.stringify({ x: c.x, y: c.y })
    `)
    note('A pressed a dot at ' + Math.round(press.x) + ',' + Math.round(press.y) + ' (still holding)')
    await sleep(3000)

    const bBefore = await B.json(`return JSON.stringify(outlineOf(${JSON.stringify(AREA_NAME)}))`)
    await A.json(`
      const c = { x: ${press.x}, y: ${press.y} }
      for (let i = 3; i <= 9; i++) pointer('pointermove', c.x + i * 6, c.y + i * 3)
      return JSON.stringify(true)
    `)
    const first = await watch(B, AREA_NAME, 6000)
    const movedAt = first.find((sample) => sample.outline !== bBefore)
    record(
      Boolean(movedAt),
      "a drag in flight is drawn on the other planner's screen, with no reload",
      movedAt
        ? 'B moved after ' + movedAt.at + 'ms, and showed ' + new Set(first.map((s) => s.outline)).size + ' outline(s) in 6s'
        : 'B was flat for 6s: ' + JSON.stringify(first.slice(0, 2)),
    )

    // A second burst: the watching screen keeps up rather than jumping once.
    const bMid = first[first.length - 1].outline
    await A.json(`
      const c = { x: ${press.x}, y: ${press.y} }
      for (let i = 10; i <= 15; i++) pointer('pointermove', c.x + i * 6, c.y + i * 3)
      return JSON.stringify(true)
    `)
    const second = await watch(B, AREA_NAME, 5000)
    const followedAt = second.find((sample) => sample.outline !== bMid)
    record(
      Boolean(followedAt),
      'the watching screen keeps up with a continuing drag',
      followedAt ? 'followed within ' + followedAt.at + 'ms' : 'no further movement in 5s',
    )

    // ---- the loser: B presses the same shape while A holds it ----------
    // B picks the area in its list first, which is also the only thing that brings B's own map to it
    // (each planner has their own view), so the press lands on the shape and not on empty water.
    // Selecting is not writing, so nothing about this takes a lock.
    await B.js(`areaRow(${JSON.stringify(AREA_NAME)}).click(); return JSON.stringify(true)`)
    await B.until('return JSON.stringify($$(".bench-vertex").length > 0)', {
      timeout: 15000,
      label: "B's map to frame the area",
    })

    const target = await B.json(`
      const label = $$('.leaflet-tooltip').find((el) => el.innerText.trim() === ${JSON.stringify(AREA_NAME)})
      const c = centreOf(label)
      const el = document.elementFromPoint(c.x, c.y)
      window.__press = el
      window.__pressAt = c
      return JSON.stringify({ tag: el ? el.tagName : '', cls: el ? String(el.getAttribute('class') || '') : '' })
    `)
    record(
      /leaflet-interactive/.test(target.cls),
      "B's press lands on the shape itself",
      target.tag + '.' + target.cls.split(' ')[0],
    )

    const bOutlineBeforePress = await B.json(`return JSON.stringify(outlineOf(${JSON.stringify(AREA_NAME)}))`)
    await B.json(`
      const el = window.__press
      const c = window.__pressAt
      pointer('pointerdown', c.x, c.y, el)
      for (let i = 1; i <= 6; i++) pointer('pointermove', c.x + i * 10, c.y)
      return JSON.stringify(true)
    `)
    await sleep(2500) // long enough for a round trip to have moved something if anything was going to
    const bAfterRefusal = await B.json(`return JSON.stringify({
      outline: outlineOf(${JSON.stringify(AREA_NAME)}),
      strip: stripText(),
      notice: Boolean($('[data-testid="lock-notice"]')),
    })`)
    await B.js("pointer('pointerup', 0, 0); return JSON.stringify(true)")

    record(
      bAfterRefusal.outline === bOutlineBeforePress,
      'a press on a shape somebody else is holding moves nothing',
      bAfterRefusal.outline === bOutlineBeforePress ? 'the outline is untouched' : 'IT MOVED',
    )
    record(
      bAfterRefusal.notice && /editing this|another window/i.test(bAfterRefusal.strip),
      'and the planner is told who has it, without asking the database',
      '"' + bAfterRefusal.strip + '"',
    )

    // ---- the winner finishes: the two screens agree --------------------
    // The drop, then Done: putting the shape down is the save. `area-shape-done` is the one in the
    // panel for an area being adjusted (the `area-done` button only exists while drawing).
    await A.js("pointer('pointerup', 0, 0); return JSON.stringify(true)")
    await A.js('$(\'[data-testid="area-shape-done"]\').click(); return JSON.stringify(true)')
    const dropSave = await settle(A)
    const aFinal = await A.json(`return JSON.stringify(outlineOf(${JSON.stringify(AREA_NAME)}))`)
    const converged = await B.until(
      `return JSON.stringify(outlineOf(${JSON.stringify(AREA_NAME)}) === ${JSON.stringify(aFinal)})`,
      { timeout: 15000, every: 150, label: 'the two screens to agree' },
    )
    record(true, 'both screens end on the geometry that was committed', 'agreed after ' + converged.ms + 'ms; the save took ' + dropSave + 'ms')
    record(aFinal !== outlineBefore, 'the drag was a real change', 'the outline differs from where it started')

    // ---- tidy up: delete the area this run made ------------------------
    await A.js('window.confirm = () => true; return JSON.stringify(true)')
    await A.js(`areaRow(${JSON.stringify(AREA_NAME)}).click(); return JSON.stringify(true)`)
    await A.until('return JSON.stringify($$(".bench-vertex").length > 0)', { label: 'the dots again' })
    await A.js(`$('[data-testid="area-delete-${AREA_NAME}"]').click(); return JSON.stringify(true)`)
    const aDelete = await settle(A)
    const gone = await A.json(`return JSON.stringify({ row: Boolean(areaRow(${JSON.stringify(AREA_NAME)})), error: pageError() })`)
    record(!gone.row && !gone.error, 'the harness took its own area away again', 'the save took ' + aDelete + 'ms -- ' + JSON.stringify(gone))

    await B.navigate(BASE + '/polygon')
    await B.until('return JSON.stringify(Boolean(mapEl()))', { timeout: 30000, label: 'B to reload' })
    const bGone = await B.until(`return JSON.stringify(!areaRow(${JSON.stringify(AREA_NAME)}))`, {
      timeout: 90000,
      label: 'the area to be gone for B',
    })
    record(true, 'and the other planner no longer has it', 'after ' + bGone.ms + 'ms')
    const afterCounts = await A.json(`return JSON.stringify($$('[data-testid^="area-row-HARNESS"]').length)`)
    record(afterCounts === 0, 'the bench is left as it was found', afterCounts + ' harness area(s) left')

    // ---- nothing said anything it should not have ----------------------
    for (const driver of [A, B]) {
      const errors = driver.errors().concat(await driver.heard())
      record(
        errors.length === 0,
        driver.name + ' reported no errors of its own',
        errors.length ? JSON.stringify(errors.slice(0, 3)) : 'nothing in the console, nothing thrown',
      )
      if (driver.ignored && driver.ignored.length) {
        note(driver.name + ' ignored ' + driver.ignored.length + " console error(s) that are not the app's (e.g. a tile server's cookie)")
      }
    }
  } finally {
    if (A) await A.end()
    if (B) await B.end()
  }

  const failed = results.filter((entry) => !entry.ok)
  console.log(
    '\n' +
      (results.length - failed.length) +
      '/' +
      results.length +
      ' checks passed' +
      (failed.length ? ' -- FAILED: ' + failed.map((f) => f.title).join('; ') : ''),
  )
  process.exit(failed.length ? 1 : 0)
}

main().catch((error) => {
  console.error('\nharness could not finish: ' + error.message)
  process.exit(2)
})
