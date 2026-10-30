// Step 15, proved through the screen: a tab showing a running plan notices that another tab published a newer
// revision, says so in words, and catches up when asked.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
//     node tools/run.mjs dev/checks/step15-staleness.mjs --session .tmp/session.json
//
// Requires the plan bench and a session for testuser1 (root + planner). The check publishes "Clean walk" and starts
// the event on it if they are not already so, then puts the bench back: the extra frame is deleted, the plan is
// published again at its four-frame shape, and the event is ended. It is safe to run again.
//
// The interesting assertion is not that a column changed -- the database check proves that -- but that the tab
// holding the old payload *did something about it*: the stale sentence appeared, the tab re-read the timetable
// (counted from the network), and pressing the button replaced the old payload with the new one. Since step 19 the
// plan's *content* also travels live, but a publish is the moment the board deliberately stops adopting it -- whether
// the added frame arrived before that is a race, so it is not measured; the revision on screen is.
export default {
  name: 'step 15 — publishing from another tab makes this tab say its timetable is out of date',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e01'
    const timeline = `${base}/events/${eventId}/timeline`
    const livePage = `${base}/events/${eventId}/live`

    // ---------- one planner's tab: a published plan, and the event running it ----------
    const a = await newTab({ label: 'tab A', url: timeline, width: 1440, height: 1000 })
    await a.waitFor('.pv-board', { timeout: 15000 })
    await openPlan(a, 'Clean walk')
    // A guard, not an assertion: this check adds and deletes a frame, so a run that died half way leaves five and
    // the next run would measure a bench that is not the fixture. Say so instead of adding a sixth.
    const cleanWalkFrames = await pickerFrames(a, 'Clean walk')
    if (cleanWalkFrames !== 4) {
      throw new Error(
        `the bench's "Clean walk" has ${cleanWalkFrames} frame(s), expected 4 -- rebuild it with ` +
          '`node tools/sql.mjs --file supabase/fixtures/plan_bench.sql`',
      )
    }
    await publishIfDraft(a, 'Clean walk')
    await a.waitUntil(`document.querySelectorAll('.pv-frame').length === ${cleanWalkFrames}`, {
      what: 'Clean walk to show its four frames',
    })

    await a.goto(livePage)
    await a.waitFor('[data-testid=event-status]', { timeout: 15000 })
    await endIfLive(a)
    await a.waitUntil(`!document.querySelector('[data-testid=start-event-btn]').disabled`, {
      what: 'the Start button to become available once the plans have loaded',
    })
    await a.click('[data-testid=start-event-btn]')
    await a.waitFor('[data-testid=start-form]')
    const picked = await pickEngine(a, 'plan:', 'Clean walk')
    a.pass(`started the event on ${picked}`)
    await a.click('[data-testid=start-confirm-btn]')
    await a.waitFor('[data-testid=confirm-dialog]')
    await a.click('[data-testid=confirm-ok]')
    await a.waitFor('[data-testid=status-live]', { timeout: 15000 })

    // Back to the board: it opens the live plan, and the strip says which revision is running.
    await a.goto(timeline)
    await a.waitFor('[data-testid=plan-live]', { timeout: 15000 })
    // The strip can appear while the frames are still on their way (it only needs the plan and the session), so the
    // frame count is waited for rather than read the moment the strip exists -- a "0 frames" measurement would make
    // every count below meaningless.
    await a.waitUntil(`document.querySelectorAll('.pv-frame').length > 0`, {
      what: 'the running plan to draw its frames',
    })
    await a.waitUntil(
      `performance.getEntriesByType('resource').filter((e) => e.name.includes('session_timetable')).length > 0`,
      { what: 'the strip to have read the timetable once' },
    )
    await a.waitUntil(`!!document.querySelector('[data-testid=plan-live-rev]')`, {
      what: 'the strip to name the running revision',
    })
    const revA = Number((await a.text('[data-testid=plan-live-rev]')).trim())
    if (!Number.isInteger(revA) || revA < 1) throw new Error(`tab A read plan version "${revA}"`)
    a.pass(`tab A holds version ${revA} of the running plan`)
    const framesA = await a.count('.pv-frame')
    await a.assertThat('tab A is showing the plan it is running', framesA >= 4)
    a.pass(`tab A is showing its ${framesA} frames`)
    // The one read is a request, and counting it is how "the tab asked again" becomes an assertion.
    const readsBefore = await readsOf(a)
    a.pass(`the strip has read the timetable ${readsBefore} time(s) so far`)
    await a.assertThat('the strip has not read a newer revision yet', !(await a.has('[data-testid=plan-stale]')))

    // ---------- a second tab adds a frame and publishes again ----------
    const b = await newTab({ label: 'tab B', url: timeline, width: 1440, height: 1000 })
    await b.waitFor('.pv-board', { timeout: 15000 })
    await openPlan(b, 'Clean walk')
    await b.waitUntil(`document.querySelectorAll('.pv-frame').length === ${framesA}`, {
      what: `tab B to open the same ${framesA}-frame plan`,
    })

    await b.click('[data-testid=frame-add]')
    await b.waitUntil(`document.querySelectorAll('.pv-frame').length === ${framesA + 1}`, {
      what: 'tab B to add a frame',
    })
    b.pass(`tab B added a frame: ${framesA} -> ${framesA + 1}`)

    // A live plan's button is "Publish again": republishing is how a change ahead of the clock is announced.
    const publishLabel = await b.eval(
      `(() => {
        const button = [...document.querySelectorAll('.pv-toolbar button')].find((b) => /^Publish/.test(b.textContent.trim()))
        return button ? button.textContent.trim() : null
      })()`,
    )
    await b.assertThat('the running plan offers "Publish again"', publishLabel === 'Publish again')
    await clickByText(b, 'Publish again')
    await b.waitFor('[data-testid=confirm-dialog]')
    await b.assertContains('[data-testid=confirm-dialog]', 'Publish "Clean walk" again?')
    await b.click('[data-testid=confirm-ok]')
    await b.waitUntil(
      `(() => {
        const toasts = [...document.querySelectorAll('[data-testid=toasts] .toast-body')]
        return toasts.length > 0 && toasts[toasts.length - 1].textContent.includes('Published again')
      })()`,
      { what: 'the republish to confirm itself' },
    )
    b.pass('tab B published again')

    // ---------- tab A was not touched, and says so ----------
    await a.waitFor('[data-testid=plan-stale]', { timeout: 20000 })
    const staleText = await a.text('[data-testid=plan-stale]')
    await a.assertContains('[data-testid=plan-stale]', `version ${revA} → ${revA + 1}`)
    await a.assertContains('[data-testid=plan-stale]', `What is on screen is version ${revA}`)
    a.pass(`tab A says: ${staleText.replace(/\s+/g, ' ').trim()}`)
    // The frame count is deliberately not asserted. Since step 19 the content of a plan travels live, but whether tab A
    // read tab B's added frame before or after the publish is a race between two messages -- and a publish is exactly
    // the moment the board stops adopting content (it holds its picture and offers the catch-up). What is certain,
    // and what this check is about, is the revision on screen: it is still the one tab A loaded.
    const revStillShown = Number((await a.text('[data-testid=plan-live-rev]')).trim())
    await a.assertThat('the stale tab still names the revision it is showing', revStillShown === revA)

    // The claim "a bumped column the client ignores does not pass" turned into a count: the tab asked the database
    // again after the publish, rather than noticing a prop that changed on its own.
    const readsAfter = await readsOf(a)
    a.pass(`the tab re-read the timetable: ${readsBefore} -> ${readsAfter} request(s)`)
    await a.assertThat('the stale tab made a fresh read of the timetable', readsAfter > readsBefore)
    await a.shot('shots/step15-stale.png')

    // ---------- catch up ----------
    await a.click('[data-testid=plan-reload]')
    await a.waitUntil(
      `!document.querySelector('[data-testid=plan-stale]') &&
       document.querySelectorAll('.pv-frame').length === ${framesA + 1}`,
      { timeout: 12000, what: 'the board to catch up to the republished plan' },
    )
    await a.waitUntil(
      `Number(document.querySelector('[data-testid=plan-live-rev]').textContent.trim()) === ${revA + 1}`,
      { what: 'the strip to adopt the new revision' },
    )
    a.pass(`tab A caught up to version ${revA + 1} and now draws ${framesA + 1} frames`)
    await a.assertNoErrors()

    // ---------- put the bench back: four frames, published, no live session ----------
    // Tab B still holds the frame it added (it never reloaded), so it is the one that can take it away.
    await b.click('[data-testid=frame-delete]')
    await b.waitFor('[data-testid=confirm-dialog]')
    await b.click('[data-testid=confirm-ok]')
    await b.waitUntil(`document.querySelectorAll('.pv-frame').length === ${framesA}`, {
      what: 'tab B to delete the frame again',
    })
    await clickByText(b, 'Publish again')
    await b.waitFor('[data-testid=confirm-dialog]')
    await b.click('[data-testid=confirm-ok]')
    b.pass(`the bench plan is back to ${framesA} frames, published again`)

    // A sees the second publish too: the strip is not a one-shot.
    await a.waitFor('[data-testid=plan-stale]', { timeout: 20000 })
    await a.assertContains('[data-testid=plan-stale]', `version ${revA + 1} → ${revA + 2}`)
    a.pass('a second republish is noticed again, from the revision the tab had caught up to')

    await a.goto(livePage)
    await a.waitFor('[data-testid=event-status]', { timeout: 15000 })
    await endIfLive(a)
    a.pass('the event is ended again, so the bench has no open session')
  },
}

// ---------- helpers ----------

/** The frame count the picker prints for a named plan: "Clean walk (4)" -> 4. */
async function pickerFrames(tab, name) {
  return tab.eval(`(() => {
    const sel = document.querySelector('.pv-select')
    if (!sel) return null
    const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(name)}))
    const m = opt && opt.textContent.match(/\\((\\d+)\\)/)
    return m ? Number(m[1]) : null
  })()`)
}

/** Open a named plan from the picker, and wait for the board to agree with it. */
async function openPlan(tab, name) {
  await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 2`, {
    what: 'the plan list to load',
  })
  // The board opens the newest plan by itself as it mounts, and that load can land *after* the picker below is
  // changed -- which then stands the change down and the board shows a plan nobody selected. Waiting for the picker
  // and the board to agree first is what a person does by looking at the page (finding from step 3).
  await tab.waitUntil(
    `(() => {
      const sel = document.querySelector('.pv-select')
      if (!sel) return false
      const m = sel.options[sel.selectedIndex].textContent.match(/\\((\\d+)\\)/)
      return !!m && document.querySelectorAll('.pv-frame').length === Number(m[1])
    })()`,
    { what: 'the board to settle on the plan it opened' },
  )
  await tab.eval(`(() => {
    const sel = document.querySelector('.pv-select')
    const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(name)}))
    if (!opt) throw new Error('no "${name}" option')
    if (sel.value !== opt.value) {
      sel.value = opt.value
      sel.dispatchEvent(new Event('change'))
    }
    return opt.textContent.replace(/\\s+/g, ' ').trim()
  })()`)
  await tab.waitUntil(
    `(() => {
      const sel = document.querySelector('.pv-select')
      if (!sel) return false
      const chosen = sel.options[sel.selectedIndex].textContent
      const m = chosen.match(/\\((\\d+)\\)/)
      return chosen.includes(${JSON.stringify(name)}) && !!m && document.querySelectorAll('.pv-frame').length === Number(m[1])
    })()`,
    { what: `the board to open "${name}"` },
  )
}

/** Publish the open plan if it is not live yet, through the same button and question a planner uses. */
async function publishIfDraft(tab, name) {
  if (await tab.has('.pv-badge.is-live')) {
    tab.pass(`"${name}" is already published`)
    return
  }
  const clicked = await clickByText(tab, 'Publish')
  if (clicked !== 'clicked') throw new Error(`no Publish button on the board: ${clicked}`)
  await tab.waitFor('[data-testid=confirm-dialog]')
  await tab.assertContains('[data-testid=confirm-dialog]', `Publish "${name}"?`)
  await tab.click('[data-testid=confirm-ok]')
  await tab.waitUntil(`!!document.querySelector('.pv-badge.is-live')`, {
    timeout: 12000,
    what: 'the plan to go live',
  })
  tab.pass(`published "${name}" from the board`)
}

/** Press a button by its visible text, once it is enabled. Returns 'clicked' or the reason nothing was pressed. */
async function clickByText(tab, text) {
  // A write that has just landed leaves the toolbar's buttons disabled for a moment (the board holds `busy` until
  // the reload it follows has finished), so pressing the moment the frame count settles can hit a disabled button
  // and do nothing at all -- which reads as "the button does not work".
  await tab.waitUntil(
    `(() => {
      const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === ${JSON.stringify(text)})
      return !!button && !button.disabled
    })()`,
    { what: `the "${text}" button to become available` },
  )
  return tab.eval(`(() => {
    const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === ${JSON.stringify(text)})
    if (!button) return 'no button reading "${text}"'
    if (button.disabled) return 'the "${text}" button is disabled'
    button.click()
    return 'clicked'
  })()`)
}

/** Choose the plan (or run sheet) named in the Start dialog's picker. */
async function pickEngine(tab, prefix, name) {
  const chosen = await tab.eval(`(() => {
    const sel = document.querySelector('#start-engine')
    const opt = [...sel.options].find((o) => o.value.startsWith(${JSON.stringify(prefix)}) && o.textContent.trim().startsWith(${JSON.stringify(name)}))
    if (!opt) throw new Error('no ${prefix}${name} option in the Start dialog')
    sel.value = opt.value
    sel.dispatchEvent(new Event('change'))
    return opt.textContent.replace(/\\s+/g, ' ').trim()
  })()`)
  if (!chosen.startsWith(name)) throw new Error(`the Start dialog picked "${chosen}", not "${name}"`)
  return chosen
}

/** End the event if a previous run left it live. */
async function endIfLive(tab) {
  if (!(await tab.has('[data-testid=status-live]'))) return false
  await tab.click('[data-testid=end-event-btn]')
  await tab.waitFor('[data-testid=confirm-dialog]')
  await tab.click('[data-testid=confirm-ok]')
  await tab.waitFor('[data-testid=status-not-started]', { timeout: 15000 })
  return true
}

/** How many times this tab has called session_timetable, from the browser's own resource timings. */
async function readsOf(tab) {
  return tab.eval(
    `performance.getEntriesByType('resource').filter((e) => e.name.includes('session_timetable')).length`,
  )
}
