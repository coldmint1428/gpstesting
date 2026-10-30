// Step 19, proved through the screen: a change one tab makes reaches another tab that never reloads.
//
//     node tools/sql.mjs --file dev/checks/step19-realtime-prep.sql
//     node tools/run.mjs dev/checks/step19-realtime.mjs --session .tmp/session.json
//
// The event is dev/checks/step19-realtime-prep.sql's own bench (e19): a live plan two minutes into its walk, three
// moments, a session on it. The check refuses to run against a bench that is already published or already four frames
// long, because its first assertion is that the second tab's edit is the only thing that changed.
//
// WHY TWO TABS OF THE SAME PERSON. The harness drives one browser profile, so localStorage is shared and every new
// page starts with the session the last tab was seeded with. Two tabs of one planner is the case a second *person*
// produces at the database end: the same event, the same plan, the same write path -- and, crucially, a tab that is
// not the one writing, which is what the subscription has to reach.
//
// WHY TAB A PROVES THE CHANNEL AND NOT A POLL. The board has no timer: it reads on its own writes and when the live
// strip offers the catch-up. Tab A is never touched between tab B's edit and the assertion, so a label appearing on
// tab A within a few seconds can only have arrived over the channel (before step 19 it would have waited for a page
// reload that never comes).
//
// What is proved, in order:
//   1. tab A opens the plan the event is running: three frames, the call moment open, its note "call", revision 1;
//   2. tab B opens the same plan and changes that moment's note -- a plain frame write, not a publish;
//   3. tab A, untouched, shows "wave through" in its note field and still has three frames: the board re-read the
//      frames because the plan row moved, which is what every write to a plan does (055);
//   4. tab B adds a frame, and tab A's bar goes from "3 frames" to "4 frames" by itself;
//   5. tab B publishes, and tab A's strip says the version moved (1 → 2) while the plan it is drawing is unchanged --
//      the publish is the strip's decision to take (step 18), so the board keeps the picture it has;
//   6. tab A takes the catch-up, and the four frames and the note are still there: what it had was the truth.
import fs from 'node:fs'

const FRESH = 'node tools/sql.mjs --file dev/checks/step19-realtime-prep.sql'

/** The words in the newest toast. The container keeps older ones until they fade, so "the last one" is what counts. */
async function lastToast(tab) {
  return tab.eval(`(() => {
    const items = [...document.querySelectorAll('[data-testid=toasts] .toast-body')]
    return items.length ? items[items.length - 1].textContent.replace(/\\s+/g, ' ').trim() : ''
  })()`)
}

async function waitForToast(tab, needle) {
  await tab.waitUntil(
    `(() => {
      const items = [...document.querySelectorAll('[data-testid=toasts] .toast-body')]
      const last = items.length ? items[items.length - 1].textContent : ''
      return last.includes(${JSON.stringify(needle)})
    })()`,
    { what: `the toast "${needle}"`, timeout: 12000 },
  )
  tab.pass(`toast: ${JSON.stringify(await lastToast(tab))}`)
}

/** Read a text node's text, retrying while the page is mid-render. */
async function textOf(tab, selector) {
  for (let i = 0; i < 40; i += 1) {
    const text = await tab.eval(
      `(() => { const el = document.querySelector(${JSON.stringify(selector)})
        return el ? el.textContent.replace(/\\s+/g, ' ').trim() : null })()`,
    )
    if (text != null) return text
    await tab.sleep(150)
  }
  throw new Error(`${tab.label}: no ${selector} on the page`)
}

/** Press a toolbar button by its exact words, once it is enabled (a disabled button swallows a press). */
async function pressButton(tab, label) {
  await tab.waitUntil(
    `(() => {
       const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === ${JSON.stringify(label)})
       return !!button && !button.disabled
     })()`,
    { what: `"${label}" to be ready` },
  )
  const clicked = await tab.eval(`(() => {
    const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === ${JSON.stringify(label)})
    if (!button) return 'missing'
    button.click()
    return 'clicked'
  })()`)
  if (clicked !== 'clicked') throw new Error(`${tab.label}: no "${label}" button`)
  tab.pass(`pressed ${label}`)
}

/** The plan the picker has selected -- the element's text, not the page's, because the picker lists every plan. */
async function selectedPlan(tab) {
  return tab.eval(`(() => {
    const sel = document.querySelector('.pv-select')
    return sel && sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].textContent.replace(/\\s+/g, ' ').trim() : ''
  })()`)
}

/** Wait for the board's own note field to say `text` (the input is bound to the open frame). */
async function waitForNote(tab, text, what) {
  await tab.waitUntil(
    `(() => { const el = document.querySelector('#pv-frame-note'); return !!el && el.value === ${JSON.stringify(text)} })()`,
    { timeout: 15000, what },
  )
}

export default {
  name: 'step 19 — a change reaches the other screen without a reload',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e19'
    const timeline = `${base}/events/${eventId}/timeline`
    const sessionFile = process.env.SESSION_FILE || '.tmp/session.json'
    if (!fs.existsSync(sessionFile)) {
      throw new Error(`no planner session at ${sessionFile} (mint one with tools/authlink.mjs)`)
    }

    // ---------- 1. the planner's board, on the plan the event is running ----------
    const a = await newTab({ label: 'planner, tab A', url: timeline, width: 1440, height: 1000 })
    await a.waitFor('.pv-board', { timeout: 20000 })
    await a.waitUntil(
      `document.querySelectorAll('.pv-frame').length === 3 && !!document.querySelector('[data-testid=plan-live]')`,
      { timeout: 20000, what: 'the board to open the live three-frame plan' },
    )
    const openedA = await selectedPlan(a)
    if (!openedA.includes('Live walk')) throw new Error(`tab A opened "${openedA}", expected the event's plan`)
    a.pass(`the board opens the plan the event is running: "${openedA}"`)
    const revA = (await textOf(a, '[data-testid=plan-live-rev]')).trim()
    if (revA !== '1') {
      throw new Error(`this bench is not fresh (the live plan is revision ${revA}). Rebuild it with ${FRESH}`)
    }
    await a.assertContains('.pv-bar-head', '3 frames')
    await waitForNote(a, 'call', 'the call moment to be open with its note')
    a.pass('three frames, the call moment open, revision 1')

    // The board also reaches the stage: the first subscription read is harmless, but a write from tab B before the
    // socket is up would be missed, and this check is about what the channel delivers.
    await a.sleep(1500)

    // ---------- 2. tab B opens the same plan and labels the moment tab A is showing ----------
    const b = await newTab({ label: 'planner, tab B', url: timeline, width: 1440, height: 1000 })
    await b.waitFor('.pv-board', { timeout: 20000 })
    await b.waitUntil(`document.querySelectorAll('.pv-frame').length === 3`, {
      timeout: 20000,
      what: "tab B to open the event's plan",
    })
    b.pass('tab B opened the same plan')
    await b.click('.pv-frame', { index: 0 })
    await b.waitUntil(`(() => { const el = document.querySelector('#pv-frame-note'); return !!el && !el.disabled })()`, {
      what: 'the call moment to be open in tab B',
    })
    await b.type('#pv-frame-note', 'wave through')
    await b.press('Enter')
    await b.waitUntil(`[...document.querySelectorAll('.pv-frame')].some((f) => (f.title || '').includes('wave through'))`, {
      timeout: 12000,
      what: "tab B's note to be written",
    })
    b.pass('tab B changed the call moment\'s note to "wave through"')
    await b.assertNoErrors()

    // ---------- 3. tab A, untouched, has it ----------
    await waitForNote(a, 'wave through', "tab A to show tab B's note without a reload")
    await a.assertContains('.pv-bar-head', '3 frames') // a note is not a new frame: the count is the same
    await a.assertThat(
      "tab A's frame carries the new note in its title too",
      `[...document.querySelectorAll('.pv-frame')].some((f) => (f.title || '').includes('wave through'))`,
    )
    a.pass('tab A re-read the plan because the row moved: the note is there, and the board was not reloaded')
    await a.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await a.sleep(300)
    await a.shot('shots/step19-live.png')

    // ---------- 4. a frame tab B adds appears on tab A as a word ----------
    await pressButton(b, 'Add frame')
    await b.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      timeout: 15000,
      what: 'tab B to have four frames',
    })
    await a.waitUntil(`document.querySelector('.pv-bar-head').textContent.includes('4 frames')`, {
      timeout: 15000,
      what: "tab A's bar to count four frames",
    })
    await a.assertThat('tab A draws four frames', `document.querySelectorAll('.pv-frame').length === 4`)
    a.pass('tab B\'s new frame reached tab A: "3 frames" became "4 frames"')

    // ---------- 5. tab B publishes; tab A says the version moved, and keeps its picture ----------
    await pressButton(b, 'Publish again')
    await b.waitFor('[data-testid=confirm-dialog]')
    await b.assertContains('[data-testid=confirm-dialog]', 'Publish "Live walk" again?')
    await b.click('[data-testid=confirm-ok]')
    await waitForToast(b, 'Published again. Everyone following it will see the change.')
    await b.waitUntil(
      `(() => { const el = document.querySelector('[data-testid=plan-live-rev]'); return !!el && el.textContent.trim() === '2' })()`,
      { timeout: 20000, what: 'the plan at revision 2' },
    )
    b.pass('tab B published: revision 2')
    await b.assertNoErrors()
    await b.close()

    await a.waitUntil(`!!document.querySelector('[data-testid=plan-stale]')`, {
      timeout: 25000,
      what: "tab A's strip to notice the newer version",
    })
    const staleText = await textOf(a, '[data-testid=plan-stale]')
    a.pass(`tab A's strip: "${staleText}"`)
    await a.assertThat('the strip names both versions, oldest first', /version 1 → 2/.test(staleText))
    await a.assertThat('the strip says what is on screen is version 1', /What is on screen is version 1/.test(staleText))
    await a.assertThat(
      'a publish is not content: tab A keeps the picture it had (four frames and the note)',
      `document.querySelectorAll('.pv-frame').length === 4 && document.querySelector('#pv-frame-note').value === 'wave through'`,
    )
    a.pass('tab A is still on revision 1, drawing the plan as it was published over')
    await a.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await a.sleep(300)
    await a.shot('shots/step19-published.png')

    // ---------- 6. the catch-up keeps what the channel already brought ----------
    await pressButton(a, 'Show version 2')
    await a.waitUntil(
      `(() => {
         const el = document.querySelector('[data-testid=plan-live-rev]')
         return !!el && el.textContent.trim() === '2' && !document.querySelector('[data-testid=plan-stale]')
       })()`,
      { timeout: 20000, what: 'tab A to adopt revision 2' },
    )
    await a.assertThat('the note is still there after the catch-up', `document.querySelector('#pv-frame-note').value === 'wave through'`)
    await a.assertThat('and so is the fourth frame', `document.querySelectorAll('.pv-frame').length === 4`)
    a.pass('tab A took revision 2 and kept the four frames and the note')

    // ---------- 7. a plan thrown away in one tab leaves the other ----------
    // This is the one case a `plans` UPDATE cannot carry: the row is gone, so the event has to be a DELETE, and a
    // DELETE only says which event it belonged to because the table's replica identity is full (055). Without it the
    // filter never matches and tab A would keep drawing a plan that no longer exists.
    const b2 = await newTab({ label: 'planner, tab B again', url: timeline, width: 1440, height: 1000 })
    await b2.waitFor('.pv-board', { timeout: 20000 })
    await b2.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      timeout: 20000,
      what: 'tab B to reopen the four-frame plan',
    })
    await pressButton(b2, 'Delete plan')
    await b2.waitFor('[data-testid=confirm-dialog]')
    await b2.assertContains('[data-testid=confirm-dialog]', 'Delete "Live walk"?')
    await b2.click('[data-testid=confirm-ok]')
    await b2.pass('tab B deleted the plan')

    await a.waitUntil(
      `document.querySelectorAll('.pv-frame').length === 0 && !!document.querySelector('[data-testid=plan-empty]')`,
      { timeout: 15000, what: 'tab A to let the deleted plan go' },
    )
    a.pass('tab A heard the deletion and let the plan go, without a reload')
    await b2.assertNoErrors()
    await b2.close()

    await a.sleep(6500)
    await a.assertNoErrors()
    await a.close()
  },
}
