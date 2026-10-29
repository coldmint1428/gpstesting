// Step 4's proof, through the browser: a frame that mentions one group still *means* three, so copying and
// pasting it has to reproduce all three positions at the coordinates they inherited.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql     # rebuilds the bench (required)
//     node tools/run.mjs dev/checks/step4-copy-paste.mjs --session .tmp/session.json
//
// The bench's "Copy bench" plan is the whole fixture:
//   +0:00  states Gate Crew, Sound and Backstage
//   +1:00  states only Gate Crew, 11 m east, with the note "one here"
// Pasting puts a new frame at +2:00 (last frame + 60 s, on the 5 s grid). The check measures the rendered page:
// the marker pixels at +1:00 and at the pasted frame, the inspector's per-group state, and the note after a
// reload. Marker pixels are the honest measurement of "same place": the coordinates never appear on screen.
//
// Rebuilding the bench first matters: this check leaves the pasted frame behind, so a second run without a
// rebuild starts at three frames and fails on "exactly two" rather than measuring a fresh paste.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const PLAN = 'Copy bench'

/**
 * Marker position per group name, in CSS pixels *inside the map container*.
 *
 * Relative to the map, not the viewport: the time bar sits at the bottom of a tall page, so clicking a frame
 * scrolls the page and every viewport coordinate shifts by the scroll amount. What must stay put is the marker's
 * place on the map, which is exactly what this measures.
 */
function markerPixels(tab) {
  return tab.eval(`(() => {
    const map = document.querySelector('.pv-map').getBoundingClientRect()
    const out = {}
    for (const el of document.querySelectorAll('.pv-marker')) {
      const root = el.closest('.leaflet-marker-icon') || el.parentElement
      const box = el.getBoundingClientRect()
      out[root.title || '?'] = [Math.round(box.left - map.left), Math.round(box.top - map.top)]
    }
    return out
  })()`)
}

/** The inspector's word for each group at the selected frame, by group name: set / same / not yet placed. */
function groupStates(tab) {
  return tab.eval(`Object.fromEntries([...document.querySelectorAll('.pv-group-row')].map((row) => [
    row.querySelector('.pv-group-name').textContent.trim(),
    row.querySelector('.pv-group-state').textContent.trim(),
  ]))`)
}

export default {
  name: 'copy and paste — one stated group becomes three pasted positions',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list to load (three plans in the bench)',
    })

    async function openCopyBench() {
      const picked = await tab.eval(`(() => {
        const sel = document.querySelector('.pv-select')
        const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(PLAN)}))
        if (!opt) return 'no "${PLAN}" option'
        if (sel.value !== opt.value) {
          sel.value = opt.value
          sel.dispatchEvent(new Event('change'))
        }
        return opt.textContent.replace(/\\s+/g, ' ').trim()
      })()`)
      tab.pass(`opened "${picked}"`)
    }

    /** Click a frame dot and wait for the board to say it opened. A Vue patch lands after the click returns. */
    async function openFrame(index, offset) {
      for (let attempt = 1; attempt <= 3; attempt += 1) {
        await tab.click('.pv-frame', { index })
        // A plan switch can land between the click and its render and put the selection back on the first frame;
        // a person would simply click again, so the check does too, then reports what the page actually said.
        if (await tab.eval(`!!(document.querySelector('.pv-hint') || {}).textContent?.includes('Frame ${offset}')`)) return
        await tab.sleep(400)
      }
      await tab.assertContains('.pv-hint', `Frame ${offset}`)
    }

    await openCopyBench()
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, {
      what: 'the copy bench to hold exactly two frames (rebuild the fixture if it does not)',
    })

    // ---------- 1. +1:00 states one group and means three ----------
    await openFrame(1, '+1:00')
    const sourceStates = await groupStates(tab)
    tab.pass(`states at +1:00: ${JSON.stringify(sourceStates)}`)
    await tab.assertThat(
      '+1:00 states Gate Crew and leaves Sound and Backstage inherited',
      sourceStates['Gate Crew'] === 'set' &&
        sourceStates['Sound'] === 'same' &&
        sourceStates['Backstage'] === 'same' &&
        sourceStates['Security'] === 'not yet placed',
    )
    const before = await markerPixels(tab)
    tab.pass(`markers at +1:00: ${JSON.stringify(before)}`)
    await tab.assertThat('three groups are on the map at +1:00', Object.keys(before).length === 3)
    await tab.assertThat(
      'the three markers stand in three different places',
      new Set(Object.values(before).map((p) => p.join(','))).size === 3,
    )

    // ---------- 2. copy, and paste as one write ----------
    await tab.click('[data-testid=frame-copy]')
    await tab.waitUntil(`document.querySelector('[data-testid=toasts]').textContent.includes('Copied +1:00')`, {
      what: 'the copy confirmation',
    })
    await tab.assertThat(
      'paste is available once a frame has been copied',
      `!document.querySelector('[data-testid=frame-paste]').disabled`,
    )
    await tab.click('[data-testid=frame-paste]')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 3`, {
      what: 'the pasted frame to appear',
      timeout: 12000,
    })
    await tab.waitUntil(`document.querySelector('.pv-hint').textContent.includes('Frame +2:00')`, {
      what: 'the pasted frame to open',
    })

    // The pasted frame states all three, because the copy was a snapshot of where everyone stood — not of the
    // one row the source frame happened to state.
    const pastedStates = await groupStates(tab)
    tab.pass(`states at +2:00: ${JSON.stringify(pastedStates)}`)
    await tab.assertThat(
      'the pasted frame states all three groups',
      pastedStates['Gate Crew'] === 'set' && pastedStates['Sound'] === 'set' && pastedStates['Backstage'] === 'set',
    )
    await tab.assertThat(
      'the note came across with the frame',
      `document.querySelector('#pv-frame-note').value === 'one here'`,
    )
    const after = await markerPixels(tab)
    tab.pass(`markers at +2:00: ${JSON.stringify(after)}`)
    await tab.assertThat('the pasted frame shows three markers', Object.keys(after).length === 3)
    for (const [name, point] of Object.entries(before)) {
      const moved = after[name]
      await tab.assertThat(
        `${name} was pasted where it already stood`,
        Array.isArray(moved) && Math.abs(moved[0] - point[0]) <= 2 && Math.abs(moved[1] - point[1]) <= 2,
      )
    }

    // ---------- 3. it is in the database, not just in this tab ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list to load after the reload',
    })
    await openCopyBench()
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 3`, {
      what: 'the pasted frame to survive the reload',
    })
    await openFrame(2, '+2:00')
    await tab.assertThat(
      'the note survived the reload',
      `document.querySelector('#pv-frame-note').value === 'one here'`,
    )
    const reloadedStates = await groupStates(tab)
    await tab.assertThat(
      'the stored frame states all three groups',
      reloadedStates['Gate Crew'] === 'set' && reloadedStates['Sound'] === 'set' && reloadedStates['Backstage'] === 'set',
    )
    const reloaded = await markerPixels(tab)
    tab.pass(`markers after reload: ${JSON.stringify(reloaded)}`)
    await tab.assertThat(
      'all three groups are drawn after the reload',
      Object.keys(reloaded).length === 3 &&
        Object.keys(reloaded).sort().join(',') === Object.keys(before).sort().join(','),
    )
    for (const [name, point] of Object.entries(before)) {
      const moved = reloaded[name]
      await tab.assertThat(
        `${name} reloaded at the coordinates it inherited`,
        Array.isArray(moved) && Math.abs(moved[0] - point[0]) <= 2 && Math.abs(moved[1] - point[1]) <= 2,
      )
    }

    await tab.shot('shots/step4-copy-paste.png')
    await tab.assertNoErrors()
  },
}
