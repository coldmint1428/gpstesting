// Step 18, proved through the screen: two tabs on the same plan, the second one publishes, and the first one's publish
// is refused as stale -- and survives it.
//
//     node tools/sql.mjs --file dev/checks/step18-publish-prep.sql
//     node tools/run.mjs dev/checks/step18-publish.mjs --session .tmp/session.json
//
// The event is dev/checks/step18-publish-prep.sql's own bench (e18): a live plan ninety seconds into its walk, and a
// session on it. The check refuses to run against a bench that has already been copied, or one whose clock is too old
// for the copy to still have frames after the cut.
//
// WHY BOTH TABS ARE THE SAME PERSON. The harness drives one browser profile, so localStorage is shared and the tab
// that was opened last is the identity every *new* page starts with (step 16's finding 46). Tab A is opened first and
// keeps the session it was seeded with; tab B shares it. The second *planner* is a different person at the database
// end (step18-publish.sql publishes as testuser1 and then as testuser2), because what compare-and-set protects is the
// plan's revision, not who is holding it.
//
// What is proved, in order:
//   1. the planner's board opens the plan the event is running, at revision 1 -- the bench is fresh and the copy will
//      still have frames after its cut;
//   2. **Copy plan** opens the copy, and the copy is still a draft: the strip has nothing to say, because the session
//      is still running the original;
//   3. tab B opens the live plan (a draft is opened for nobody) and picks the copy from the plan list -- which is how
//      two planners end up on the same draft -- then labels the way-out moment and publishes: the copy becomes the
//      live plan at revision 2, and the running event moves onto it (step 17's hand-over);
//   4. tab A, which has not reloaded, is still drawing revision 1 -- its strip says so, with both numbers. The label
//      tab B wrote is on tab A's board, because the content of a plan travels live (step 19); the *revision* is what
//      is behind, and that is what this step is about.
//   5. tab A's own Publish is refused by the database (HTTP 409), and the refusal names the revision this screen held
//      and the one the plan is on. That refusal is the proof the client *sent* a revision: a null or a fresh number
//      would have published, not been refused;
//   6. the page picks itself up -- it re-reads the plan, so the next press publishes the plan as it now stands --
//      rather than leaving the planner with a dead end;
//   7. the second press publishes: revision 3, and the other tab's label is still there, because the first press
//      announced nothing at all.
import fs from 'node:fs'

const FRESH = 'node tools/sql.mjs --file dev/checks/step18-publish-prep.sql'

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

/** Press a toolbar button by its exact words, once it is enabled (finding 38: a disabled button swallows a press). */
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

export default {
  name: 'step 18 — publishing is compare-and-set, and leaves a version',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e18'
    const timeline = `${base}/events/${eventId}/timeline`
    const sessionFile = process.env.SESSION_FILE || '.tmp/session.json'
    if (!fs.existsSync(sessionFile)) {
      throw new Error(`no planner session at ${sessionFile} (mint one with tools/authlink.mjs)`)
    }

    // ---------- 1. the planner's board, on the plan the event is running ----------
    const a = await newTab({ label: 'planner, tab A', url: timeline, width: 1440, height: 1000 })
    await a.waitFor('.pv-board', { timeout: 20000 })
    await a.waitUntil(
      `document.querySelectorAll('.pv-frame').length === 5 && !!document.querySelector('[data-testid=plan-live]')`,
      { timeout: 20000, what: 'the board to open the live five-frame plan' },
    )
    const openedA = await selectedPlan(a)
    if (!openedA.includes('Doors walk')) throw new Error(`tab A opened "${openedA}", expected the event's plan`)
    a.pass(`the board opens the plan the event is running: "${openedA}"`)
    const revA = (await textOf(a, '[data-testid=plan-live-rev]')).trim()
    if (revA !== '1') {
      throw new Error(`this bench is not fresh (the live plan is revision ${revA}). Rebuild it with ${FRESH}`)
    }
    const t0Iso = await a.eval(`document.querySelector('[data-testid=plan-live-t0]').dataset.t0`)
    const age = Math.round((Date.now() - new Date(t0Iso).getTime()) / 1000)
    if (age > 300) {
      throw new Error(`this bench is ${age}s old; the copy would be past too much of the walk. Rebuild it with ${FRESH}`)
    }
    a.pass(`the plan is ${age}s into its walk, on revision 1`)

    // ---------- 2. tab A copies the plan ----------
    await pressButton(a, 'Copy plan')
    await a.waitUntil(`!!document.querySelector('.pv-frame[data-cut=true]')`, {
      timeout: 15000,
      what: 'the copy to open with its starting frame marked',
    })
    await waitForToast(a, 'Copied from')
    const copyA = await selectedPlan(a)
    await a.assertThat('the board switched to the copy', copyA.includes('(edited)'))
    const copyFrames = await a.eval(`document.querySelectorAll('.pv-frame').length`)
    if (copyFrames < 2) throw new Error(`the copy has ${copyFrames} frames; the bench is too old`)
    await a.assertThat(
      'the copy does not yet carry the label the other tab is about to write',
      `![...document.querySelectorAll('.pv-frame')].some((f) => (f.title || '').includes('out late'))`,
    )
    a.pass(`the copy is open with ${copyFrames} frames; the session is still on the original`)

    // ---------- 3. the second tab opens the copy and publishes it ----------
    const b = await newTab({ label: 'planner, tab B', url: timeline, width: 1440, height: 1000 })
    await b.waitFor('.pv-board', { timeout: 20000 })
    await b.waitUntil(`document.querySelectorAll('.pv-frame').length === 5`, {
      timeout: 20000,
      what: 'tab B to open the event\'s plan',
    })
    const openedB = await selectedPlan(b)
    if (!openedB.includes('Doors walk') || openedB.includes('(edited)')) {
      throw new Error(`tab B opened "${openedB}", expected the live plan -- a copy is not opened for anybody`)
    }
    await b.assertThat('the strip is on, because tab B opened the plan the event is running', `!!document.querySelector('[data-testid=plan-live]')`)
    b.pass(`tab B opens the live plan: "${openedB}"`)

    // A copy is a draft, so it is not opened for anybody: the second planner picks it from the plan list, which is how
    // two people end up on the same draft (the case compare-and-set is for).
    const picked = await b.eval(`(() => {
      const sel = document.querySelector('.pv-select')
      const opt = [...sel.options].find((o) => o.textContent.includes('(edited)'))
      if (!opt) return null
      sel.value = opt.value
      sel.dispatchEvent(new Event('change', { bubbles: true }))
      return opt.textContent.replace(/\\s+/g, ' ').trim()
    })()`)
    if (!picked) throw new Error('tab B has no copy to pick')
    b.pass(`tab B picked "${picked}" from the plan list`)
    await b.waitUntil(`!!document.querySelector('.pv-frame[data-cut=true]')`, {
      timeout: 15000,
      what: 'tab B to open the copy',
    })
    const copyB = await selectedPlan(b)
    await b.assertThat('tab B is on the copy', copyB.includes('(edited)'))
    // A draft nobody is running has no strip: the session still runs the plan the copy was cut from.
    await b.assertThat('the copy is not live yet, so the strip is silent', `!document.querySelector('[data-testid=plan-live]')`)
    b.pass('tab B is on the copy as a draft')

    await b.click('.pv-frame', { index: copyFrames - 1 })
    await b.waitUntil(
      `(() => { const el = document.querySelector('#pv-frame-note'); return !!el && !el.disabled })()`,
      { what: "the copy's last moment to be open" },
    )
    await b.type('#pv-frame-note', 'out late')
    await b.press('Enter')
    await b.waitUntil(`[...document.querySelectorAll('.pv-frame')].some((f) => (f.title || '').includes('out late'))`, {
      timeout: 12000,
      what: "tab B's label to be written",
    })
    b.pass('tab B labelled the way-out moment "out late"')

    await pressButton(b, 'Publish')
    await b.waitFor('[data-testid=confirm-dialog]')
    await b.assertContains('[data-testid=confirm-dialog]', 'Publish "Doors walk (edited)"?')
    await b.click('[data-testid=confirm-ok]')
    await waitForToast(b, 'Published. This is now the plan people see.')
    await b.waitUntil(
      `(() => { const el = document.querySelector('[data-testid=plan-live-rev]'); return !!el && el.textContent.trim() === '2' })()`,
      { timeout: 20000, what: 'the copy to become the live plan at revision 2' },
    )
    b.pass('tab B published the copy: revision 2, and the running event moved onto it')
    await b.assertNoErrors()
    await b.close()

    // ---------- 4. tab A holds a picture that has been published over ----------
    await a.waitUntil(`!!document.querySelector('[data-testid=plan-stale]')`, {
      timeout: 25000,
      what: "tab A's strip to notice the newer version",
    })
    const staleText = await textOf(a, '[data-testid=plan-stale]')
    a.pass(`tab A's strip: "${staleText}"`)
    await a.assertThat('the strip names both versions, oldest first', /version 1 → 2/.test(staleText))
    await a.assertThat('the strip says what is on screen is version 1', /What is on screen is version 1/.test(staleText))
    const shownA = (await textOf(a, '[data-testid=plan-live-rev]')).trim()
    await a.assertThat('the chip names the revision on screen, not the newer one', shownA === '1')
    // What tab A draws is a race between tab B's frame write and its publish, and step 19 is the reason: content
    // arrives live, but a publish is the moment the board stops adopting it and holds the picture it has. The claim
    // this step makes -- and the one that has to hold every run -- is the revision on screen and the warning.
    a.pass('tab A is still on revision 1, and says so')
    await a.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await a.sleep(300)
    await a.shot('shots/step18-stale.png')

    // ---------- 5. tab A publishes from the old picture, and is refused ----------
    await pressButton(a, 'Publish')
    await a.waitFor('[data-testid=confirm-dialog]')
    // Tab A still thinks the plan is a draft -- the plan it is holding was never published -- so it asks the
    // first-publish question, which is another way of seeing that its picture is old.
    await a.assertContains('[data-testid=confirm-dialog]', 'Publish "Doors walk (edited)"?')
    // The refusal is a 4xx from the database on purpose; the page is supposed to show it in words.
    a.expectHttp(409, 'rpc/plan_publish')
    await a.click('[data-testid=confirm-ok]')
    await waitForToast(a, 'Nothing was published')
    const refused = await lastToast(a)
    a.pass(`tab A is refused: "${refused}"`)
    await a.assertThat('the refusal names the revision this screen held', /had version 1 on it/.test(refused))
    await a.assertThat('and the one the plan is on', /now version 2/.test(refused))
    await a.assertThat('and says nothing was announced', /Nothing was published/.test(refused))
    await a.assertNoErrors()
    await a.sleep(400)
    await a.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await a.sleep(300)
    await a.shot('shots/step18-refused.png')

    // ---------- 6. the page picks itself up ----------
    await a.waitUntil(
      `(() => { const el = document.querySelector('[data-testid=plan-live-rev]'); return !!el && el.textContent.trim() === '2' })()`,
      { timeout: 20000, what: 'tab A to adopt the plan as it now stands' },
    )
    await a.waitUntil(`[...document.querySelectorAll('.pv-frame')].some((f) => (f.title || '').includes('out late'))`, {
      timeout: 20000,
      what: "tab B's label to appear on tab A after the reload",
    })
    await a.assertThat('the warning clears once the page is on the newer version', `!document.querySelector('[data-testid=plan-stale]')`)
    await a.assertThat('the plan on screen is now the live one', `[...document.querySelectorAll('button')].some((b) => b.textContent.trim() === 'Publish again')`)
    a.pass("tab A re-read the plan: revision 2, with tab B's label on it, and a button that would publish it again")

    // ---------- 7. the second press publishes what is really there ----------
    await pressButton(a, 'Publish again')
    await a.waitFor('[data-testid=confirm-dialog]')
    await a.assertContains('[data-testid=confirm-dialog]', 'Publish "Doors walk (edited)" again?')
    await a.click('[data-testid=confirm-ok]')
    await waitForToast(a, 'Published again. Everyone following it will see the change.')
    await a.waitUntil(
      `(() => { const el = document.querySelector('[data-testid=plan-live-rev]'); return !!el && el.textContent.trim() === '3' })()`,
      { timeout: 20000, what: 'the plan at revision 3' },
    )
    await a.assertThat(
      "tab B's label survived the second publish -- the refused one changed nothing",
      `[...document.querySelectorAll('.pv-frame')].some((f) => (f.title || '').includes('out late'))`,
    )
    await a.assertThat('nothing is stale after the publish', `!document.querySelector('[data-testid=plan-stale]')`)
    a.pass('the second press published the plan as it stands: revision 3')

    await a.sleep(6500)
    await a.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await a.sleep(300)
    await a.shot('shots/step18-republished.png')
    await a.assertNoErrors()
    await a.close()
  },
}
