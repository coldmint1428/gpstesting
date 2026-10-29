// Step 6's proof, through the browser: select a stretch of the time bar and push it, and the frames outside the
// stretch stay exactly where they were.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql     # rebuilds the bench (required)
//     node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 .tmp/session.json
//     node tools/run.mjs dev/checks/step6-push-chunk.mjs --session .tmp/session.json
//
// The bench's "Push bench" plan is the strip the step's Done-when names: four frames at +0:00 / +1:00 / +2:00 /
// +3:00, one note each, every step legal. The check clicks it through the gestures a person has:
//   * Shift+click a second dot selects the run between them; the inspector turns into the stretch it is about;
//   * Push -1m on +0:00..+1:00 is refused in words ("before T+0") and nothing moves;
//   * Push +5m on +1:00..+2:00 moves exactly those two: +3:00 and +0:00 keep their times and their notes, and the
//     two that moved keep theirs -- reordering the strip, which the 25 m rule then reports in red;
//   * a reload shows the same four times, so it was written and not just drawn;
//   * dragging one dot of a two-frame selection pushes both, in one request, leaving the other two alone;
//   * sweeping across the bar with the pointer selects the run it touches.
// Rebuilding the bench first matters: this check pushes the strip, so a second run without a rebuild starts from
// 0/3/6/7 and every expectation below is about the fixture's 0/1/2/3.
const EVENT = '0b000000-0000-4000-8000-000000000e01'
const PLAN = 'Push bench'

/** Each dot's title: "Frame +1:00" or "Frame +1:00 — doors". The DOM order is the plan's time order. */
function frameTitles(tab) {
  return tab.eval(`[...document.querySelectorAll('.pv-frame')].map((b) => b.getAttribute('title'))`)
}

export default {
  name: 'push a chunk — a stretch moves by naming both ends, the frames outside it stay put',

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

    await boardMatchesPicker()
    await openPlan()
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      what: 'the push bench strip (rebuild the fixture if it does not hold four frames)',
    })

    // ---------- 1. the strip, before anything moves ----------
    const start = await frameTitles(tab)
    tab.pass(`strip: ${JSON.stringify(start)}`)
    await tab.assertThat(
      'the strip is +0:00 / +1:00 / +2:00 / +3:00 with its notes',
      start.length === 4 &&
        start[0].startsWith('Frame +0:00') && start[0].includes('call') &&
        start[1].startsWith('Frame +1:00') &&
        start[2].startsWith('Frame +2:00') && start[2].includes('doors') &&
        start[3].startsWith('Frame +3:00') && start[3].includes('walk on'),
    )
    await tab.assertThat('nothing is flagged before the push', `!document.querySelector('.pv-badge.is-bad')`)
    await tab.assertThat('one frame is selected to begin with', `document.querySelectorAll('.pv-frame.is-selected').length === 1`)
    await tab.assertThat('and the inspector is about that one frame', `!!document.querySelector('#pv-frame-time')`)
    // The plan's groups have to be in the map's view when the plan opens: this plan stands north-west of the one the
    // board opened first, and before the fit was reset on a plan switch it showed the previous plan's corner with no
    // markers in it at all. The fit animates, so wait for it rather than measuring mid-flight.
    const markersInView = `(() => {
      const map = document.querySelector('.pv-map').getBoundingClientRect()
      const points = [...document.querySelectorAll('.pv-marker')].map((m) => {
        const b = m.getBoundingClientRect()
        return [b.left + b.width / 2 - map.left, b.top + b.height / 2 - map.top]
      })
      return points.length === 2 && points.every(([x, y]) => x > 0 && y > 0 && x < map.width && y < map.height)
    })()`
    await tab.waitUntil(markersInView, { what: 'the plan to be framed with its markers in view' })
    await tab.assertThat('the plan opens with its markers inside the map view', markersInView)

    // ---------- 1b. the arrow keys step between frames ----------
    // The dots at +2:00 and +3:00 are 11 px apart at the default zoom and their boxes overlap, so the later one wins
    // the hit test (finding 25). The keyboard is the reliable way to reach a particular frame, and Shift extends.
    await tab.press('ArrowRight')
    await tab.assertContains('.pv-hint', 'Frame +1:00')
    await tab.press('Shift+ArrowRight')
    await tab.assertContains('.pv-hint', '2 frames, +1:00 → +2:00')
    await tab.assertThat(
      'Shift+ArrowRight extends the stretch, the same as Shift+click',
      `document.querySelectorAll('.pv-frame.is-selected').length === 2`,
    )
    await tab.press('ArrowLeft')
    await tab.assertContains('.pv-hint', 'Frame +1:00')
    await tab.press('ArrowLeft')
    await tab.assertContains('.pv-hint', 'Frame +0:00')

    // ---------- 2. the group half of the selection model ----------
    // Ticking a group is a change to the picture, not to the plan: the other groups step back on the map, and the
    // row says it is ticked. This is the set steps 8 and 10 move and verify in bulk.
    await tab.assertThat(
      'the inspector lists every group of the event',
      `document.querySelectorAll('[data-testid=group-row]').length === 4`,
    )
    const gateRow = await tab.eval(
      `[...document.querySelectorAll('[data-testid=group-row]')].findIndex((r) => r.textContent.includes('Gate Crew'))`,
    )
    await tab.click('[data-testid=group-row]', { index: gateRow })
    // Gate Crew and Sound are the two groups this plan states, so they are the two markers on the map; ticking Gate
    // Crew has to step Sound back and leave Gate Crew alone.
    await tab.waitUntil(`!!document.querySelector('.leaflet-marker-icon[title="Sound"] .pv-marker.is-dim')`, {
      what: 'the other group on this frame to step back',
    })
    await tab.assertThat(
      'ticking one group steps the other one back, and leaves that one bright',
      `!!document.querySelector('.leaflet-marker-icon[title="Sound"] .pv-marker.is-dim') &&
       !document.querySelector('.leaflet-marker-icon[title="Gate Crew"] .pv-marker.is-dim')`,
    )
    await tab.assertThat(
      'the row says it is ticked',
      `document.querySelectorAll('[data-testid=group-row]')[${gateRow}].getAttribute('aria-pressed') === 'true'`,
    )
    await tab.click('[data-testid=group-row]', { index: gateRow })
    await tab.waitUntil(`document.querySelectorAll('.pv-marker.is-dim').length === 0`, { what: 'the map to come back' })

    // ---------- 3. Shift+click selects a stretch ----------
    await tab.click('.pv-frame', { index: 1 })
    await tab.assertContains('.pv-hint', 'Frame +1:00')
    await tab.click('.pv-frame', { index: 2, modifiers: 8 })
    await tab.assertContains('.pv-hint', '2 frames, +1:00 → +2:00')
    await tab.assertThat('the inspector is now about the stretch', `!!document.querySelector('[data-testid=selection-span]')`)
    await tab.assertContains('[data-testid=selection-span]', '2 frames, +1:00 → +2:00')
    await tab.assertThat(
      'a stretch has no single frame to type into',
      `!document.querySelector('#pv-frame-time') && !document.querySelector('#pv-frame-note')`,
    )
    await tab.assertThat('both dots are marked selected', `document.querySelectorAll('.pv-frame.is-selected').length === 2`)
    await tab.assertThat('and the bar draws the stretch it will move', `!!document.querySelector('[data-testid=selection-band]')`)

    // ---------- 4. the refusal the step names: below T+0 ----------
    // +0:00 cannot come back by a minute, and the board has to say so without moving anything. The refusal is a 4xx
    // from the database, so the failed request is expected -- and if it does not happen, the check says so.
    await tab.click('.pv-frame', { index: 0 })
    await tab.click('.pv-frame', { index: 1, modifiers: 8 })
    await tab.assertContains('.pv-hint', '+0:00 → +1:00')
    tab.expectHttp(400, 'rpc/frame_shift')
    await tab.click('[data-testid=push-minus-60]')
    await tab.waitForText('[data-testid=toasts]', 'before T+0')
    const refused = await frameTitles(tab)
    await tab.assertThat(
      'the refused push left every frame where it was',
      JSON.stringify(refused) === JSON.stringify(start),
    )

    // ---------- 5. the Done-when: +1:00..+2:00 pushed by +5m ----------
    await tab.click('.pv-frame', { index: 1 })
    await tab.click('.pv-frame', { index: 2, modifiers: 8 })
    await tab.assertContains('.pv-hint', '+1:00 → +2:00')
    await tab.click('[data-testid=push-300]')
    await tab.waitForText('[data-testid=toasts]', '2 frames moved by +5:00')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, { what: 'the same four frames' })
    const pushed = await frameTitles(tab)
    tab.pass(`after the push: ${JSON.stringify(pushed)}`)
    await tab.assertThat(
      'the stretch moved by five minutes',
      pushed[2].startsWith('Frame +6:00') && pushed[3].startsWith('Frame +7:00'),
    )
    await tab.assertThat(
      'the frames outside the stretch did not move',
      pushed[0].startsWith('Frame +0:00') && pushed[1].startsWith('Frame +3:00'),
    )
    await tab.assertThat(
      'and they kept their notes, which is what "not rewritten" means',
      pushed[0].includes('call') && pushed[1].includes('walk on'),
    )
    await tab.assertThat(
      'the moved frames kept their own notes',
      !pushed[2].includes('—') && pushed[3].includes('doors'),
    )

    // The chunk passed over the frame that stayed at +3:00, so the strip is now 0/3/6/7 and the pairs the 25 m rule
    // compares are different ones. Crossing is allowed; the rule then says what the new order means.
    await tab.waitUntil(`!!document.querySelector('.pv-badge.is-bad')`, { what: 'the rule to notice the new order' })
    await tab.assertThat(
      'the reorder shows as four broken pairs',
      `document.querySelectorAll('.pv-gap').length === 4`,
    )
    await tab.assertThat(
      'and the header counts them',
      `document.querySelector('.pv-badge.is-bad').textContent.toLowerCase().includes('4 too far apart')`,
    )
    await tab.assertThat(
      'the three frames in the broken run are marked',
      `document.querySelectorAll('.pv-frame.is-bad').length === 3`,
    )
    // The map animates its fit; a picture taken mid-flight shows a plan with no markers in the frame.
    await tab.sleep(1200)
    await tab.shot('shots/step6-push-chunk.png')

    // ---------- 6. it is in the database, not just on this screen ----------
    await tab.reload()
    await tab.waitFor('.pv-board', { timeout: 15000 })
    await tab.waitUntil(`document.querySelectorAll('.pv-select option').length >= 3`, {
      what: 'the plan list after the reload',
    })
    await boardMatchesPicker()
    await openPlan()
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, {
      what: 'the pushed strip to survive the reload',
    })
    const afterReload = await frameTitles(tab)
    tab.pass(`after the reload: ${JSON.stringify(afterReload)}`)
    await tab.assertThat('the push survived the reload', JSON.stringify(afterReload) === JSON.stringify(pushed))

    // ---------- 7. the gesture the bar is for: drag one, the stretch follows ----------
    // +3:00 and +6:00 selected, dragged 132 px = 120 s at the default 1.1 px per second. +7:00 stays where it is, so
    // the two that move keep their notes and the two that do not keep theirs.
    await tab.click('.pv-frame', { index: 1 })
    await tab.click('.pv-frame', { index: 2, modifiers: 8 })
    await tab.assertContains('.pv-hint', '+3:00 → +6:00')
    await tab.drag('.pv-frame', 132, 0, { index: 2 })
    await tab.waitForText('[data-testid=toasts]', '2 frames moved by +2:00')
    await tab.waitUntil(`document.querySelectorAll('.pv-frame').length === 4`, { what: 'four frames after the drag' })
    const dragged = await frameTitles(tab)
    tab.pass(`after the drag: ${JSON.stringify(dragged)}`)
    await tab.assertThat(
      'the dragged stretch moved together',
      dragged[1].startsWith('Frame +5:00') && dragged[3].startsWith('Frame +8:00'),
    )
    await tab.assertThat(
      'the two frames outside it stayed where they were',
      dragged[0].startsWith('Frame +0:00') && dragged[0].includes('call') && dragged[2].startsWith('Frame +7:00'),
    )
    await tab.assertThat(
      'and the two that moved took their notes with them',
      dragged[1].includes('walk on') && dragged[3].startsWith('Frame +8:00') && !dragged[3].includes('—'),
    )

    // ---------- 8. sweeping the bar selects the run it touches ----------
    // A press on the ruler, a drag to the right and a release: the two dots it passes over are selected. The ruler
    // is above every dot, so the press cannot land on one.
    const first = await tab.rect('.pv-frame', 0)
    const second = await tab.rect('.pv-frame', 1)
    const track = await tab.rect('.pv-track-inner')
    const y = track.top + 10
    await tab.mouse('mousePressed', first.x - 14, y)
    for (let step = 1; step <= 8; step += 1) {
      await tab.mouse('mouseMoved', first.x - 14 + ((second.x - first.x + 28) * step) / 8, y)
      await tab.sleep(16)
    }
    await tab.mouse('mouseReleased', second.x + 14, y)
    await tab.sleep(300)
    await tab.assertThat(
      'sweeping across two dots selects both',
      `document.querySelectorAll('.pv-frame.is-selected').length === 2`,
    )
    await tab.assertContains('.pv-hint', '+0:00 → +5:00')

    await tab.assertNoErrors()
  },
}
