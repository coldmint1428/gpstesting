// tools/bench_harness.mjs -- two browsers, one bench, driven through WebDriver BiDi.
//
// WHY THIS EXISTS. Everything about the bench's collaboration is decided by things a build cannot
// see: two sessions of one account, a lock answered by the database while a finger is still down, a
// frame arriving from somebody else's browser. `npm run build` passed while /polygon threw on load
// for a whole round -- a missing import is a legal reference to a global -- so "it builds" is not
// evidence for any of this. This drives the real page in two real browsers and reports what happened.
//
// It has earned its keep. It found a drawn area being saved without itself, an in-flight save's reply
// resurrecting a shape that had just been deleted, a lock let go of before the change it protected was
// saved, and a press refused in silence -- all four silent, and all four now fixed and covered here.
// Round 4 added the checks for the thing that replaced the whole-document save: a shape created, undone
// or deleted on one screen reaching the other one ON ITS OWN, with no reload anywhere in the test.
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
// A NOTE ON PATIENCE, WHICH ROUND 4 CHANGED. The canvas is 3.7 MB of a 4 MB cap, and while it was ONE
// document every save of it took 19 to 34 seconds, so this file waited accordingly. A save is now the
// SHAPE that changed (009_object_rows.sql), which is a few hundred bytes, and the checks below report
// what each one actually took -- which is the measurement that says whether that worked.

import { Driver, sleep } from './bidi.mjs'

const BASE = process.argv[2] || process.env.BENCH_BASE || 'http://localhost:5174'
const EMAIL = process.env.BENCH_EMAIL || ''
const PASSWORD = process.env.BENCH_PASSWORD || ''
const PORTS = { A: 9222, B: 9223 }

// The area this run makes and then deletes. Named per run so a run that dies halfway leaves something
// that cannot be mistaken for the next run's shape.
const AREA_NAME = 'HARNESS-' + Math.floor(Date.now() / 1000)

// The floor plan this run uploads, and then deletes: one small picture, made in the page (`fromFile`
// becomes the plan's name, so it carries the run's epoch the same way the area does).
const PLAN_FILE = 'HARNESS-' + Math.floor(Date.now() / 1000) + '.png'

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
  // Through `about:blank` first, deliberately: navigating to the URL a window is ALREADY on does not
  // reload it, so a run would otherwise start from whatever the last one left behind -- a page somebody
  // has been poking at by hand, with whatever they left installed in it.
  await driver.navigate('about:blank')
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

// Wait for a write to be over. Three phases, because "no badge" is ambiguous: a write that has not
// STARTED looks exactly like a write that has finished. A write is fast now -- one shape, not the whole
// canvas -- so the first phase polls quickly enough to catch a badge that is only up for a moment.
async function settle(driver, { appear = 20000, finish = 30000, quiet = 800 } = {}) {
  const started = Date.now()
  const badge = 'return JSON.stringify(Boolean($(\'[data-testid="saving-badge"]\')))'

  const seen = await (async () => {
    while (Date.now() - started < appear) {
      if (await driver.json(badge)) return true
      await sleep(50)
    }
    return false
  })()
  if (!seen) return Date.now() - started

  const finishBy = Date.now() + finish
  while (Date.now() < finishBy) {
    if (!(await driver.json(badge))) break
    await sleep(100)
  }

  let absentSince = null
  while (Date.now() < finishBy + quiet + 5000) {
    if (await driver.json(badge)) absentSince = null
    else {
      if (absentSince === null) absentSince = Date.now()
      if (Date.now() - absentSince >= quiet) return Date.now() - started
    }
    await sleep(100)
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

    // ---- a new area is drawn, and reaches the other planner on its own -
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
    // Naming the draft is what puts the whole thing down: finishDraft() creates the area and sets mode to
    // null. Under the old design that was the save of the entire canvas; the area is now a row of its own
    // and addArea() writes it before the mode changes at all.
    await A.until(`return JSON.stringify(Boolean(areaRow(${JSON.stringify(AREA_NAME)})))`, { label: 'the new area' })
    const aSave = await settle(A)
    const aSaved = await A.json(`return JSON.stringify({ error: pageError(), row: Boolean(areaRow(${JSON.stringify(AREA_NAME)})) })`)
    record(aSaved.row && !aSaved.error, 'a drawn area saves without a page error', 'the write took ' + aSave + 'ms')
    record(
      aSave >= 0 && aSave < 15000,
      'and it is the shape that is written, not the whole canvas',
      aSave + 'ms, against 19000-34000ms for one save of the whole document',
    )

    // AND THE OTHER PLANNER GETS IT WITHOUT RELOADING. This is the boundary the old design could not
    // cross: a whole-document save had nothing to say about one shape, so a shape that did not exist a
    // moment ago could only arrive with the other planner's next save. A shape is a published row now,
    // and B has not been reloaded since before it existed.
    let bArrival = null
    try {
      bArrival = await B.until(`return JSON.stringify(Boolean(areaRow(${JSON.stringify(AREA_NAME)})))`, {
        timeout: 20000,
        every: 100,
        label: 'the area to reach B on its own',
      })
    } catch {
      bArrival = null
    }
    record(
      Boolean(bArrival),
      'an area drawn on one screen appears on the other with no reload',
      bArrival ? 'B had it after ' + bArrival.ms + 'ms' : 'B never saw it: the row event did not arrive',
    )
    if (!bArrival) throw new Error('stopping here: without the area on both screens the rest cannot be tested')

    // ---- Undo takes away a shape THIS planner made ----------------------
    // It did not, before: the old merge kept every object its snapshot did not mention, on the reasoning
    // that another planner might have made it since, so Ctrl+Z after drawing left the area on the bench
    // for good. The rule now is "a shape the step does not have, which I made, goes" -- and that is a
    // deletion, so it is checked on both screens like any other change.
    await A.js('$(\'[data-testid="bench-undo"]\').click(); return JSON.stringify(true)')
    let aUndone = null
    let bUndone = null
    try {
      aUndone = await A.until(`return JSON.stringify(!areaRow(${JSON.stringify(AREA_NAME)}))`, {
        timeout: 15000,
        every: 100,
        label: 'the area to go from the screen that drew it',
      })
      bUndone = await B.until(`return JSON.stringify(!areaRow(${JSON.stringify(AREA_NAME)}))`, {
        timeout: 20000,
        every: 100,
        label: 'the area to go from the other screen',
      })
    } catch {
      // Either wait may have failed; both are reported below.
    }
    record(
      Boolean(aUndone) && Boolean(bUndone),
      'Undo takes away an area this planner made, on both screens',
      aUndone && bUndone ? 'gone from A and B' : 'A=' + Boolean(aUndone) + ' B=' + Boolean(bUndone),
    )

    await A.js('$(\'[data-testid="bench-redo"]\').click(); return JSON.stringify(true)')
    let aRedone = null
    let bRedone = null
    try {
      aRedone = await A.until(`return JSON.stringify(Boolean(areaRow(${JSON.stringify(AREA_NAME)})))`, {
        timeout: 15000,
        every: 100,
        label: 'the area to come back',
      })
      bRedone = await B.until(`return JSON.stringify(Boolean(areaRow(${JSON.stringify(AREA_NAME)})))`, {
        timeout: 20000,
        every: 100,
        label: 'the area to come back on the other screen',
      })
    } catch {
      // Reported below.
    }
    record(
      Boolean(aRedone) && Boolean(bRedone),
      'and Redo puts it back on both',
      aRedone && bRedone ? 'back on A and B' : 'A=' + Boolean(aRedone) + ' B=' + Boolean(bRedone),
    )
    if (!aRedone || !bRedone) throw new Error('stopping here: the area has to be there for the rest')

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
    // The drop, then Done. The write happens AT THE DROP -- nothing is written while a pointer is down --
    // and Done is what lets go of the lock. `area-shape-done` is the one in the panel for an area being
    // adjusted (the `area-done` button only exists while drawing).
    await A.js("pointer('pointerup', 0, 0); return JSON.stringify(true)")
    await A.js('$(\'[data-testid="area-shape-done"]\').click(); return JSON.stringify(true)')
    const dropSave = await settle(A)
    const aFinal = await A.json(`return JSON.stringify(outlineOf(${JSON.stringify(AREA_NAME)}))`)
    const converged = await B.until(
      `return JSON.stringify(outlineOf(${JSON.stringify(AREA_NAME)}) === ${JSON.stringify(aFinal)})`,
      { timeout: 15000, every: 150, label: 'the two screens to agree' },
    )
    record(true, 'both screens end on the geometry that was committed', 'agreed after ' + converged.ms + 'ms; the write took ' + dropSave + 'ms')
    record(aFinal !== outlineBefore, 'the drag was a real change', 'the outline differs from where it started')

    // ---- a page that stopped hearing anything catches up when it comes back --------------------
    // This is the one thing events cannot cover, and the reason the bench keeps a revision of its own: a
    // page that has been away compares its own number with the bench's and reads the canvas again only if
    // it really did miss something (see catchUp in useBenchDoc). The socket is genuinely dropped here
    // rather than faked, because that is the case the path exists for -- and while it is down B cannot
    // hear A's rename, so the only way the new name can reach B is that read. What is counted is the
    // READS, not just the result: a result could always have arrived as an event.
    await B.js(`
      const mod = await import('/src/lib/supabase.js')
      if (!window.__opensPatched) {
        const real = mod.supabase.rpc.bind(mod.supabase)
        window.__opens = 0
        mod.supabase.rpc = async (fn, args) => { if (fn === 'open_bench') window.__opens += 1; return real(fn, args) }
        window.__opensPatched = true
      }
      await mod.supabase.realtime.disconnect()
      return JSON.stringify(true)
    `)
    await sleep(1000)

    const caughtName = AREA_NAME + '-caught'
    await A.js(`
      const input = $('[data-testid="area-name-${AREA_NAME}"]')
      input.value = ${JSON.stringify(caughtName)}
      input.dispatchEvent(new Event('change', { bubbles: true }))
      return JSON.stringify(true)
    `)
    const caughtWrite = await settle(A)
    await B.js(`
      const mod = await import('/src/lib/supabase.js')
      mod.supabase.realtime.connect()
      return JSON.stringify(true)
    `)

    let bCaught = null
    try {
      bCaught = await B.until(`return JSON.stringify(Boolean(areaRow(${JSON.stringify(caughtName)})))`, {
        timeout: 25000,
        every: 200,
        label: 'the renamed area to reach a page that was not listening',
      })
    } catch {
      bCaught = null
    }
    const bOpens = await B.json('return JSON.stringify(window.__opens || 0)')
    record(
      Boolean(bCaught) && bOpens > 0,
      'a page whose socket dropped catches up when it comes back',
      bCaught
        ? 'B had the new name after ' + bCaught.ms + 'ms, having re-read the bench ' + bOpens + ' time(s); the rename took ' + caughtWrite + 'ms'
        : 'B never caught up, and re-read the bench ' + bOpens + ' time(s)',
    )

    // Back to the name everything below knows it by, now that B is listening again.
    await A.js(`
      const input = $('[data-testid="area-name-${caughtName}"]')
      input.value = ${JSON.stringify(AREA_NAME)}
      input.dispatchEvent(new Event('change', { bubbles: true }))
      return JSON.stringify(true)
    `)
    await settle(A)

    // ---- tidy up: delete the area this run made ------------------------
    // `confirm` answers for itself: the delete button asks before it does anything, and a real dialog in
    // a headless browser is a page that stops until somebody answers it.
    await A.js('window.confirm = () => true; return JSON.stringify(true)')
    await A.js(`areaRow(${JSON.stringify(AREA_NAME)}).click(); return JSON.stringify(true)`)
    await A.until('return JSON.stringify($$(".bench-vertex").length > 0)', { label: 'the dots again' })
    await A.js(`$('[data-testid="area-delete-${AREA_NAME}"]').click(); return JSON.stringify(true)`)
    const aDelete = await settle(A)
    const gone = await A.json(`return JSON.stringify({ row: Boolean(areaRow(${JSON.stringify(AREA_NAME)})), error: pageError() })`)
    record(!gone.row && !gone.error, 'the harness took its own area away again', 'the write took ' + aDelete + 'ms -- ' + JSON.stringify(gone))

    // And B loses it ON ITS OWN: a deletion is a row that went away, published like any other change.
    // Under the old design this needed a reload to notice -- which is what this check used to do, and
    // there is no reload anywhere in this harness any more.
    let bGone = null
    try {
      bGone = await B.until(`return JSON.stringify(!areaRow(${JSON.stringify(AREA_NAME)}))`, {
        timeout: 20000,
        every: 100,
        label: 'the area to be gone for B on its own',
      })
    } catch {
      bGone = null
    }
    record(
      Boolean(bGone),
      'and the other planner loses it without a reload',
      bGone ? 'gone from B after ' + bGone.ms + 'ms' : 'B still has it',
    )
    const afterCounts = await A.json(`return JSON.stringify($$('[data-testid^="area-row-HARNESS"]').length)`)
    record(afterCounts === 0, 'the bench is left as it was found', afterCounts + ' harness area(s) left')

    // ---- a floor plan: the other kind of shape, and the one that carries a picture -----------
    // This is the half of the bench the harness has never touched. It matters more now than it did: a
    // picture is a row of its own (009_object_rows.sql), keyed by the md5 of the image, so what is
    // checked here is the two things a picture does that an area cannot -- that a plan uploaded on one
    // screen reaches the other one with no reload, and that the PICTURE comes with it, which is a fetch
    // the receiving page only makes when it does not already have that image.
    const plansBefore = await A.json(`return JSON.stringify($$('img.bench-plan').length)`)
    const sizeBefore = await A.json(`return JSON.stringify(($('[data-testid="canvas-size"]') || {}).innerText || '')`)
    note('before the upload: ' + plansBefore + ' floor plan picture(s) on the map, ' + sizeBefore)

    await A.js(`
      const canvas = document.createElement('canvas')
      canvas.width = 600
      canvas.height = 400
      const ctx = canvas.getContext('2d')
      ctx.fillStyle = '#c00'
      ctx.fillRect(0, 0, 600, 400)
      ctx.fillStyle = '#fff'
      ctx.fillRect(60, 60, 220, 160)
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'))
      const input = $('[data-testid="floorplan-file"]')
      const transfer = new DataTransfer()
      transfer.items.add(new File([blob], ${JSON.stringify(PLAN_FILE)}, { type: 'image/png' }))
      input.files = transfer.files
      input.dispatchEvent(new Event('change', { bubbles: true }))
      return JSON.stringify(blob.size)
    `)
    const planWrite = await settle(A)
    const aPlan = await A.json(`return JSON.stringify({
      error: pageError(),
      pictures: $$('img.bench-plan').length,
      size: ($('[data-testid="canvas-size"]') || {}).innerText || '',
      rows: $$('[data-testid^="plan-name-"]').length,
    })`)
    record(
      aPlan.pictures === plansBefore + 1 && !aPlan.error,
      'a floor plan uploads, and its picture is stored beside it',
      'the write took ' + planWrite + 'ms and the bench went ' + sizeBefore + ' -> ' + aPlan.size,
    )

    // B has never seen this picture, and nothing reloads it: the row event says which picture the new
    // plan points at, and B goes and reads that one image.
    let bPicture = null
    try {
      bPicture = await B.until(`return JSON.stringify($$('img.bench-plan').length === ${plansBefore + 1})`, {
        timeout: 20000,
        every: 100,
        label: 'the new floor plan to reach B',
      })
    } catch {
      bPicture = null
    }
    const bPictureDetail = bPicture
      ? await B.json(`return JSON.stringify($$('img.bench-plan').map((i) => String(i.src).length))`)
      : null
    record(
      Boolean(bPicture) && Boolean(bPictureDetail) && Math.max(...bPictureDetail) > 500,
      'and the other planner draws it, picture and all, with no reload',
      bPicture ? 'B had it after ' + bPicture.ms + 'ms, picture sizes ' + JSON.stringify(bPictureDetail) : 'B never got it',
    )

    // Tidy up: the last plan in the list is the one this run made.
    await A.js(`
      window.confirm = () => true
      const buttons = $$('[data-testid^="plan-delete-"]')
      buttons[buttons.length - 1].click()
      return JSON.stringify(true)
    `)
    const planDelete = await settle(A)
    const aPlanGone = await A.json(`return JSON.stringify({
      error: pageError(),
      pictures: $$('img.bench-plan').length,
      size: ($('[data-testid="canvas-size"]') || {}).innerText || '',
    })`)
    record(
      aPlanGone.pictures === plansBefore && !aPlanGone.error,
      'the harness takes its floor plan away again',
      'the write took ' + planDelete + 'ms and the bench went back to ' + aPlanGone.size,
    )

    let bPlanGone = null
    try {
      bPlanGone = await B.until(`return JSON.stringify($$('img.bench-plan').length === ${plansBefore})`, {
        timeout: 20000,
        every: 100,
        label: 'the floor plan to go from B on its own',
      })
    } catch {
      bPlanGone = null
    }
    record(Boolean(bPlanGone), 'and the other planner loses it without a reload', bPlanGone ? 'gone from B after ' + bPlanGone.ms + 'ms' : 'B still has it')

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
