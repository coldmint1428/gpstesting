// Step 5's proof, through the browser: one "Fill" click turns an impossible stretch into a legal one.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql     # rebuilds the bench (required)
//     node tools/run.mjs dev/checks/step5-fill-gap.mjs --session .tmp/session.json
//
// The bench's "Walkthrough" plan has Sound 200 m away from where it still was, between +1:00 (the last frame that
// says where it is) and +3:00. Since step 12 the board and plan_check name the same pair and the same budget: the walk
// spans two frame steps, so it is allowed 50 m and 200 m is a break. The check measures the page:
//   * before: three red frame dots (the stretch, not just its two ends), one gap row naming Sound and 200 m over two
//     steps, one "too far apart" badge;
//   * the click: exactly ONE request to rpc/frames_fill (counted from the browser's resource timing), six frames
//     turned into fourteen, every gap warning gone and no red dot left -- while the crossing the fill does not
//     touch (Walkthrough also walks through "Stores" at +0:00, step 11) is still named in its own row and badge;
//   * after: clicking +2:07 -- a frame that did not exist before -- shows Sound's marker between where it stood at
//     +2:00 and where it stood at +3:00, on the same latitude. That is the straight line, drawn.
// Then a reload: fourteen frames, still no gap, and +2:07 still states Sound.
//
// Rebuilding the bench first matters: this check fills the walkthrough, so a second run without a rebuild starts
// from a plan that has nothing to fill.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const PLAN = 'Walkthrough'

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

/** How many requests the page has made to one RPC. The browser's own record, not a count we keep. */
function rpcCalls(tab, name) {
  return tab.eval(`performance.getEntriesByType('resource')
    .filter((e) => e.name.includes('/rpc/${name}')).length`)
}

export default {
  name: 'fill a gap — one impossible stretch becomes legal in one call',

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

    async function openPlan(name = PLAN) {
      const picked = await tab.eval(`(() => {
        const sel = document.querySelector('.pv-select')
        const opt = [...sel.options].find((o) => o.textContent.trim().startsWith(${JSON.stringify(name)}))
        if (!opt) return 'no "${name}" option'
        if (sel.value !== opt.value) {
          sel.value = opt.value
          sel.dispatchEvent(new Event('change'))
        }
        return opt.textContent.replace(/\\s+/g, ' ').trim()
      })()`)
      tab.pass(`opened "${picked}"`)
    }

    /**
     * Click a frame dot and wait for the board to say it opened. A Vue patch lands after the click returns, and a
     * tab that is mid-render can briefly hand back a dot that is not laid out yet -- a person would click again,
     * so the check does too, then reports what the page actually said.
     */
    async function openFrame(index, offset) {
      for (let attempt = 1; attempt <= 3; attempt += 1) {
        try {
          await tab.click('.pv-frame', { index })
        } catch {
          await tab.sleep(400)
          continue
        }
        if (await tab.eval(`!!(document.querySelector('.pv-hint') || {}).textContent?.includes('Frame ${offset}')`)) return
        await tab.sleep(400)
      }
      await tab.assertContains('.pv-hint', `Frame ${offset}`)
    }

    /**
     * The board shows the plan the picker says it shows. The page opens the newest plan on its own when it mounts,
     * and a change dispatched before that load has finished can be overwritten by it -- which looks exactly like
     * "the fill did not survive the reload" when it is really two loads racing. Waiting for the two to agree is
     * what a person does by looking at the page.
     */
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

    await boardMatchesPicker()
    await openPlan()
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 6`, {
      what: 'the walkthrough to hold its six frames (rebuild the fixture if it does not)',
    })

    // Wider timeline, so a frame 13 s after another is far enough away to click on its own rather than its
    // neighbour's dot. Two clicks on "+" take 1.1 px/s up to the 4 px/s ceiling.
    await tab.click('[data-testid=zoom-in]')
    await tab.click('[data-testid=zoom-in]')
    await tab.sleep(150)

    // ---------- 1. the plan says what is wrong ----------
    await openFrame(2, '+2:00')
    const before = await markerPixels(tab)
    tab.pass(`markers at +2:00: ${JSON.stringify(before)}`)
    await tab.assertThat('Sound is on the map at +2:00', Array.isArray(before.Sound))

    await openFrame(3, '+3:00')
    const far = await markerPixels(tab)
    tab.pass(`markers at +3:00: ${JSON.stringify(far)}`)
    await tab.assertThat(
      'between +2:00 and +3:00 Sound is about 200 m east',
      Array.isArray(far.Sound) && far.Sound[0] - before.Sound[0] > 100,
    )
    await tab.assertThat(
      'and on the same latitude as before',
      Math.abs(far.Sound[1] - before.Sound[1]) <= 2,
    )

    await openFrame(2, '+2:00')
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 1`, {
      what: 'the one gap the walkthrough has',
    })
    // textContent, lowercased: the badge is uppercased by CSS, so the rendered text is "1 TOO FAR APART".
    await tab.assertThat(
      'the header counts the one break',
      `document.querySelector('.pv-badge.is-bad').textContent.toLowerCase().includes('1 too far apart')`,
    )
    await tab.assertContains('.pv-gap', 'Sound')
    await tab.assertContains('.pv-gap', '200 m')
    await tab.assertContains('.pv-gap', '+1:00')
    await tab.assertContains('.pv-gap', '+3:00')
    // The rule is a budget per frame step (step 12): this walk has two of them, so the sentence says 50 m, not 25.
    await tab.assertContains('.pv-gap', '2 steps')
    await tab.assertThat(
      'the whole stretch is marked on the bar, not just its two ends',
      `document.querySelectorAll('.pv-frame.is-bad').length === 3`,
    )
    await tab.assertThat(
      'the warning offers to fill it',
      `!document.querySelector('[data-testid=gap-fill]').disabled`,
    )
    const callsBefore = await rpcCalls(tab, 'frames_fill')
    tab.pass(`frames_fill calls before: ${callsBefore}`)
    await tab.assertThat('opening the plan did not ask for a fill', callsBefore === 0)
    await tab.shot('shots/step5-before-fill.png')

    // ---------- 2. one click, one call ----------
    await tab.click('[data-testid=gap-fill]')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 14`, {
      what: 'the filled frames to appear (six plus eight)',
      timeout: 15000,
    })
    const callsAfter = await rpcCalls(tab, 'frames_fill')
    await tab.assertThat(
      'the whole fill was one round trip',
      callsAfter - callsBefore === 1,
    )

    await tab.waitUntil(`document.querySelector('[data-testid=toasts]').textContent.includes('Added 8 frames')`, {
      what: 'the fill confirmation',
    })

    await tab.assertThat(
      'no gap is left on the board',
      `document.querySelectorAll('.pv-gap').length === 0 && !document.querySelector('.pv-badge.is-bad')`,
    )
    // The fill fixed the walk, not the zone: this bench's Walkthrough also walks 20 m through "Stores" at +0:00,
    // and that row is the database's to keep until someone moves the group out (step 11). The badges are separate
    // so a count of 25 m breaks never starts counting a crossing.
    await tab.assertThat(
      'the crossing the fill did not touch is still named',
      `[...document.querySelectorAll('[data-testid=plan-problem]')].some((r) => r.textContent.includes('Stores'))`,
    )
    await tab.assertThat(
      'and no frame is flagged red any more',
      `document.querySelectorAll('.pv-frame.is-bad').length === 0`,
    )
    await tab.assertContains('.pv-bar-head', '14 frames')

    // ---------- 3. the filled positions are where the straight line says ----------
    // Measured against the two ends *as they are now*, not against the pixels read before the fill: the inspector
    // loses its warning when the gap closes, the page gets shorter, and Leaflet resizes the map -- which moves every
    // marker a few pixels without anything having moved on the ground. Two ends and the middle read back to back
    // share one layout, so the comparison means what it says.
    //
    // The walk the fill was asked to fix is +1:00 → +3:00 now (step 12: the board reports from the last frame that
    // said where Sound was, not from the frame that only carried it). Eight new frames sit between the old +1:00 and
    // +3:00, the first of them at +1:13, and the frame the check opens is the one at +2:07 -- an offset chosen by the
    // fill, not by this file, so the fraction along the line is read from the offsets rather than assumed.
    const offsetOf = (row) => Number(String(row).replace(/^\+/, '').split(':').reduce((s, n) => s * 60 + Number(n), 0))

    async function alongTheLine(label) {
      // The line starts at the frame that STATES where Sound is, not at the next one: +2:00 only carries the position
      // it was given at +1:00, and a carried frame is the same point on the map, so measuring from it would put the
      // start of the line in the middle of the walk.
      await openFrame(1, '+1:00')
      const start = await markerPixels(tab)
      const startAt = await tab.eval(`document.querySelector('#pv-frame-time').value`)
      await openFrame(7, '+2:07')
      const middle = await markerPixels(tab)
      const middleAt = await tab.eval(`document.querySelector('#pv-frame-time').value`)
      await openFrame(11, '+3:00')
      const end = await markerPixels(tab)
      const endAt = await tab.eval(`document.querySelector('#pv-frame-time').value`)
      tab.pass(`${label}: ${JSON.stringify({ start: start.Sound, middle: middle.Sound, end: end.Sound })}`)
      await tab.assertThat(`${label}: Sound is drawn at the filled frame`, Array.isArray(middle.Sound))
      await tab.assertThat(
        `${label}: Sound stands between where it was and where it is going`,
        middle.Sound[0] > start.Sound[0] + 3 && middle.Sound[0] < end.Sound[0] - 3,
      )
      await tab.assertThat(
        `${label}: on the straight line, not wandering off it`,
        Math.abs(middle.Sound[1] - start.Sound[1]) <= 2 && Math.abs(middle.Sound[1] - end.Sound[1]) <= 2,
      )
      return { start, middle, end, startAt, middleAt, endAt }
    }

    const filled = await alongTheLine('after the fill')
    // The samples are evenly spaced in time between the two ends, so the pixel fraction along the map has to be the
    // time fraction of the frame it was written at. Allowing 0.03 is about four seconds of slack on a 120 s stretch.
    tab.pass(`+2:07 is ${filled.middleAt}, between ${filled.startAt} and ${filled.endAt}`)
    await tab.assertThat(
      'and it sits at the fraction of time it names, not at either end',
      Math.abs(
        (filled.middle.Sound[0] - filled.start.Sound[0]) /
          (filled.end.Sound[0] - filled.start.Sound[0]) -
          (offsetOf(filled.middleAt) - offsetOf(filled.startAt)) /
            (offsetOf(filled.endAt) - offsetOf(filled.startAt)),
      ) < 0.03,
    )
    const filledStates = await groupStates(tab)
    tab.pass(`states at +2:07: ${JSON.stringify(filledStates)}`)
    await tab.assertThat(
      'the new frame states Sound rather than inheriting it',
      filledStates.Sound === 'set',
    )

    // ---------- 4. it is in the database, not just in this tab ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list to load after the reload',
    })
    await boardMatchesPicker()
    await openPlan()
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 14`, {
      what: 'the filled frames to survive the reload',
    })
    // The reload puts the bar back at its default scale, where a 13 s gap is 15 px and one dot's box overlaps the
    // next -- and the dot drawn later wins the hit test, so clicking the middle of one selects its neighbour. Zoom
    // back in the same way as before measuring.
    await tab.click('[data-testid=zoom-in]')
    await tab.click('[data-testid=zoom-in]')
    await tab.sleep(150)
    await tab.assertThat(
      'still no gap after the reload',
      `!document.querySelector('.pv-badge.is-bad')`,
    )
    await alongTheLine('after the reload')
    const reloadedStates = await groupStates(tab)
    tab.pass(`states after the reload: ${JSON.stringify(reloadedStates)}`)
    await tab.assertThat('the stored frame states Sound', reloadedStates.Sound === 'set')

    await tab.shot('shots/step5-fill-gap.png')

    // ---------- 5. one click fixes a stretch that two groups share ----------
    // "Twin gap" has Gate Crew and Sound both 200 m east of where they stood, between the same two frames, so the
    // board shows two warnings for one stretch. The button has to name both groups in one call: filling them one
    // at a time would be two round trips, and the second would be written against a plan the first had changed.
    await openPlan('Twin gap')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 2`, {
      what: 'the twin gap plan to hold its two frames',
    })
    await openFrame(0, '+0:00')
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 2`, {
      what: 'both groups to be flagged on the same stretch',
    })
    const rows = await tab.eval(
      `[...document.querySelectorAll('.pv-gap')].map((r) => r.textContent.replace(/\\s+/g, ' ').trim())`,
    )
    tab.pass(`two warnings: ${JSON.stringify(rows)}`)
    await tab.assertThat(
      'both warnings name the same two frames and the same 200 m',
      rows.length === 2 &&
        rows.every((text) => text.includes('+0:00') && text.includes('+5:00') && text.includes('200 m')),
    )
    await tab.assertThat(
      'each row knows the fill covers both groups',
      `[...document.querySelectorAll('[data-testid=gap-fill]')].every((b) => (b.title || '').includes('these groups'))`,
    )

    const twinCallsBefore = await rpcCalls(tab, 'frames_fill')
    await tab.click('[data-testid=gap-fill]', { index: 0 })
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 10`, {
      what: 'the twin gap to be filled (two frames plus eight)',
      timeout: 15000,
    })
    // Wait for *both* warnings to go before counting: the frame count reaches ten half way through a client that
    // fills one group at a time, and that is exactly the client this assertion exists to catch.
    await tab.waitUntil(`document.querySelectorAll('.pv-gap').length === 0`, {
      what: 'both groups to be filled',
      timeout: 15000,
    })
    await tab.assertThat(
      'filling a stretch two groups share is still one round trip',
      (await rpcCalls(tab, 'frames_fill')) - twinCallsBefore === 1,
    )
    await tab.assertThat('both warnings are gone', `document.querySelectorAll('.pv-gap').length === 0`)
    await openFrame(1, '+0:33')
    const twinStates = await groupStates(tab)
    tab.pass(`states at +0:33: ${JSON.stringify(twinStates)}`)
    await tab.assertThat(
      'the new frame states both groups, not just the one whose row was clicked',
      twinStates['Gate Crew'] === 'set' && twinStates.Sound === 'set',
    )
    await tab.assertThat('and both are drawn on the map', `document.querySelectorAll('.pv-marker').length === 2`)

    await tab.assertNoErrors()
  },
}
