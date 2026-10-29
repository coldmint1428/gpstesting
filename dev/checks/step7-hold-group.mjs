// Step 7's proof, through the browser: hold one group where it already stands, and nothing else on that later
// frame changes.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql     # rebuilds the bench (required)
//     node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 .tmp/session.json
//     node tools/run.mjs dev/checks/step7-hold-group.mjs --session .tmp/session.json
//
// The bench's "Copy bench" is the plan this step's Done-when fits: +0:00 states three groups, +1:00 states Gate Crew
// only. Sound is stated once, at +0:00, and never again -- so holding it for five minutes writes +5:00 with Sound
// and nobody else, which is exactly "the row at +5:00 for that group equals the one at +0:00, and no other group
// gained one".
//
// What the check clicks through:
//   * the inspector's hold line names everyone standing at the frame before anything is ticked;
//   * ticking Sound narrows it to Sound (and steps the other groups back on the map);
//   * Hold +5m is ONE request to rpc/frame_hold, and the strip gains +5:00;
//   * opening +5:00 draws Sound's marker on the same pixels it had at +0:00, while only Sound's row says "set" --
//     the other groups are still drawn there, because the board carries a position forward, but this frame does not
//     state them: that is the Done-when's "no other group gained one", read on the screen;
//   * a reload shows the same three frames;
//   * two holds that would lie are refused in words and change nothing: Twin gap's +5:00 already puts Gate Crew
//     somewhere else, and Push bench's Gate Crew moves at +1:00 -- before the moment being asked for.
// The database half is dev/checks/step7-hold-group.sql; this file is the part a person does with a mouse.
const EVENT = '0b000000-0000-4000-8000-000000000e01'

/** Each dot's title: "Frame +1:00" or "Frame +1:00 — doors". The DOM order is the plan's time order. */
function frameTitles(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-frame')].map((b) => b.getAttribute('title'))`)
}

/** How many requests the page has made to one RPC. The browser's own record, not a count we keep. */
function rpcCalls(tab, name) {
  return tab.eval(`performance.getEntriesByType('resource')
    .filter((e) => e.name.includes('/rpc/${name}')).length`)
}

/** A group's marker, measured inside the map container (the page scrolls, the map does not). */
function markerAt(tab, title) {
  return tab.eval(`(() => {
    const map = document.querySelector('.pv-map').getBoundingClientRect()
    const el = document.querySelector('.leaflet-marker-icon[title=${JSON.stringify(title)}]')
    if (!el) return null
    const b = el.getBoundingClientRect()
    return {
      x: Math.round((b.left + b.width / 2 - map.left) * 10) / 10,
      y: Math.round((b.top + b.height / 2 - map.top) * 10) / 10,
    }
  })()`)
}

export default {
  name: 'hold one group — a later frame states it where it stands, and nobody else is written',

  async run({ newTab, base }) {
    const tab = await newTab({
      label: 'planner',
      url: `${base}/events/${EVENT}/timeline`,
      width: 1440,
      height: 1000,
    })
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list to load (five plans in the bench)',
    })

    async function openPlan(name) {
      const picked = await tab.eval(`(() => {
        const sel = document.querySelector('.pv-select')
        const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(name)}))
        if (!opt) return 'no such option'
        if (sel.value !== opt.value) {
          sel.value = opt.value
          sel.dispatchEvent(new Event('change'))
        }
        return opt.textContent.replace(/\\s+/g, ' ').trim()
      })()`)
      tab.pass(`opened "${picked}"`)
    }

    // The page opens the newest plan on its own when it mounts; a change dispatched before that load finishes is
    // overwritten by it. Waiting for the picker and the board to agree is what a person does by looking.
    async function boardMatchesPicker() {
      await tab.waitUntil(
        `(() => {
          const sel = document.querySelector('.pv-select')
          if (!sel) return false
          const m = sel.options[sel.selectedIndex].textContent.match(/\\((\\d+)\\)/)
          return !!m && document.querySelectorAll('.pv-frame').length === Number(m[1])
        })()`,
        { what: 'the board to show the plan the picker names' },
      )
    }

    /** The inspector row for a group, by name. Rows are alphabetical. */
    async function groupRow(name) {
      const index = await tab.eval(
        `[...document.querySelectorAll('[data-testid=group-row]')].findIndex((r) => r.textContent.includes(${JSON.stringify(name)}))`,
      )
      if (index < 0) throw new Error(`no group row for ${name}`)
      return index
    }

    await boardMatchesPicker()
    await openPlan('Copy bench')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, {
      what: 'the copy bench strip (rebuild the fixture if it does not hold two frames)',
    })

    // ---------- 1. the strip, and who the hold would act on ----------
    const start = await frameTitles(tab)
    tab.pass(`strip: ${JSON.stringify(start)}`)
    await tab.assertThat(
      'the copy bench opens on +0:00 / +1:00',
      start.length === 2 && start[0].startsWith('Frame +0:00') && start[1].startsWith('Frame +1:00'),
    )
    await tab.assertThat('one frame is open to begin with', `!!document.querySelector('#pv-frame-time')`)
    await tab.assertContains('.pv-hint', 'Frame +0:00')
    await tab.assertThat(
      "the inspector lists the event's four groups",
      `document.querySelectorAll('[data-testid=group-row]').length === 4`,
    )
    // Nothing is ticked, so the hold acts on everybody standing at this frame -- which is three of the four: Security
    // is in no frame of this plan.
    await tab.assertContains('[data-testid=hold-target]', 'Keep Backstage, Gate Crew and Sound where they stand')

    // ---------- 2. tick one group: the hold narrows to it ----------
    const soundRow = await groupRow('Sound')
    await tab.click('[data-testid=group-row]', { index: soundRow })
    await tab.assertContains('[data-testid=hold-target]', 'Keep Sound where it stands')
    await tab.waitUntil(`!!document.querySelector('.leaflet-marker-icon[title="Gate Crew"] .pv-marker.is-dim')`, {
      what: 'the groups that are not held to step back',
    })
    await tab.assertThat(
      'the other groups step back, and the held one stays bright',
      `!!document.querySelector('.leaflet-marker-icon[title="Gate Crew"] .pv-marker.is-dim') &&
       !!document.querySelector('.leaflet-marker-icon[title="Backstage"] .pv-marker.is-dim') &&
       !document.querySelector('.leaflet-marker-icon[title="Sound"] .pv-marker.is-dim')`,
    )
    const soundAt0 = await markerAt(tab, 'Sound')
    tab.pass(`Sound at +0:00 sits at ${JSON.stringify(soundAt0)}`)

    // ---------- 3. the Done-when: Hold +5m ----------
    const callsBefore = await rpcCalls(tab, 'frame_hold')
    await tab.click('[data-testid=hold-300]')
    await tab.waitForText('[data-testid=toasts]', 'Held Sound at +0:00 until +5:00')
    const callsAfter = await rpcCalls(tab, 'frame_hold')
    tab.pass(`frame_hold round trips: ${callsBefore} → ${callsAfter}`)
    await tab.assertThat('the hold is one call, not one per group', callsAfter === callsBefore + 1)
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 3`, { what: 'the new frame on the strip' })
    const held = await frameTitles(tab)
    tab.pass(`strip after the hold: ${JSON.stringify(held)}`)
    await tab.assertThat(
      'the strip gained +5:00 and kept the two moments it had',
      held[0].startsWith('Frame +0:00') && held[1].startsWith('Frame +1:00') && held[2].startsWith('Frame +5:00'),
    )
    // The clock at a later moment does not need a note: a hold is a statement about place, not about the run.
    await tab.assertThat('the held frame carries no note of its own', !held[2].includes('—'))
    await tab.assertThat('the frame the planner was on is still the open one', `document.querySelector('#pv-frame-time').value === '+0:00'`)

    // ---------- 4. the held moment, on the map ----------
    // Two dots far apart, so clicking the new one is unambiguous. (Finding 25 is about dots 13 s apart.)
    await tab.click('.pv-frame', { index: 2 })
    await tab.assertContains('.pv-hint', 'Frame +5:00')
    await tab.waitUntil(`!!document.querySelector('.leaflet-marker-icon[title="Sound"]')`, {
      what: 'the held group to be drawn at +5:00',
    })
    const soundAt300 = await markerAt(tab, 'Sound')
    tab.pass(`Sound at +5:00 sits at ${JSON.stringify(soundAt300)}`)
    await tab.assertThat(
      'the held marker stands on the pixels it had at +0:00',
      !!soundAt0 && !!soundAt300 &&
        Math.abs(soundAt300.x - soundAt0.x) <= 1.5 &&
        Math.abs(soundAt300.y - soundAt0.y) <= 1.5,
    )
    await tab.assertThat(
      'and nobody is missing from the map: the board carries every placed group forward',
      `document.querySelectorAll('.pv-marker').length === 3`,
    )
    const states = await tab.eval(`(() => {
      const out = {}
      for (const row of document.querySelectorAll('[data-testid=group-row]')) {
        const name = row.querySelector('.pv-group-name').textContent.trim()
        out[name] = row.querySelector('.pv-group-state').textContent.trim()
      }
      return out
    })()`)
    tab.pass(`groups at +5:00: ${JSON.stringify(states)}`)
    // Every group is still drawn on this frame -- the board carries positions forward, which is what "unchanged
    // since +0:00" looks like on a map -- so "no other group gained one" is a question about which groups this frame
    // *states*, and that is what the inspector's rows say: "set" means the frame says it, "same" means carried in.
    await tab.assertThat('the held group is set at +5:00', states.Sound === 'set')
    await tab.assertThat(
      'no other group gained a statement there',
      states['Gate Crew'] === 'same' && states.Backstage === 'same' && states.Security === 'not yet placed',
    )
    await tab.assertThat(
      'exactly one group is stated on the held frame',
      `[...document.querySelectorAll('.pv-group-state')].filter((s) => s.textContent.trim() === 'set').length === 1`,
    )
    await tab.assertThat('a hold cannot break the 25 m rule', `!document.querySelector('.pv-badge.is-bad') && !document.querySelector('.pv-gap')`)
    await tab.sleep(1200)
    await tab.shot('shots/step7-hold-group.png')

    // ---------- 5. it is in the database, not just on this screen ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list after the reload',
    })
    await boardMatchesPicker()
    await openPlan('Copy bench')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 3`, {
      what: 'the held strip to survive the reload',
    })
    const afterReload = await frameTitles(tab)
    await tab.assertThat('the hold survived the reload', JSON.stringify(afterReload) === JSON.stringify(held))
    await tab.click('.pv-frame', { index: 2 })
    await tab.assertContains('.pv-hint', 'Frame +5:00')
    await tab.waitUntil(`!!document.querySelector('.leaflet-marker-icon[title="Sound"]')`, {
      what: 'the held group after the reload',
    })
    await tab.assertThat(
      'and it still states only that group',
      `[...document.querySelectorAll('.pv-group-state')].filter((s) => s.textContent.trim() === 'set').length === 1`,
    )

    // ---------- 6. the two holds that would lie ----------
    // (a) Twin gap's +5:00 already puts Gate Crew 200 m east of where it stands at +0:00. Holding it there would
    // rewrite a decision somebody made, so the database says so and nothing moves.
    await openPlan('Twin gap')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, { what: 'the twin gap strip' })
    await tab.assertContains('.pv-hint', 'Frame +0:00')
    await tab.assertContains('[data-testid=hold-target]', 'Keep Gate Crew and Sound where they stand')
    tab.expectHttp(400, 'rpc/frame_hold')
    await tab.click('[data-testid=hold-300]')
    await tab.waitForText('[data-testid=toasts]', 'already stands somewhere else at +5:00')
    await tab.assertThat(
      'the refused hold left the twin gap strip alone',
      `document.querySelectorAll('.pv-frame').length === 2`,
    )

    // (b) Push bench's Gate Crew moves at +1:00, so holding it to +5:00 would draw a 72 m jump back rather than a
    // delay. The sentence names the frame it moves at.
    await openPlan('Push bench')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, { what: 'the push bench strip' })
    await tab.assertContains('.pv-hint', 'Frame +0:00')
    tab.expectHttp(400, 'rpc/frame_hold')
    await tab.click('[data-testid=hold-300]')
    await tab.waitForText('[data-testid=toasts]', 'moves before +5:00')
    await tab.assertThat(
      'the refused hold left the push bench strip alone',
      `document.querySelectorAll('.pv-frame').length === 4`,
    )

    await tab.assertNoErrors()
  },
}
