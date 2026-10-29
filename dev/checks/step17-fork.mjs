// Step 17, proved through the screen: a copy of a running plan starts where the walk already has everybody, the past
// is not on it, and publishing the copy carries the running event across without moving the clock.
//
//     node tools/sql.mjs --file dev/checks/step17-fork-prep.sql
//     node tools/run.mjs dev/checks/step17-fork.mjs --session .tmp/session.json
//
// Needs one more session (the check says so if it is missing):
//     node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 .tmp/session3.json   (Sound, plain member)
//
// The event is dev/checks/step17-fork-prep.sql's own bench (e17): a live plan ninety seconds into its walk, and a
// session on it. The check refuses to run against a bench that has already been copied, or one whose clock is too
// old for the copy to still have frames after the cut.
//
// WHY THE MEMBER'S TAB IS OPENED FIRST AND CLOSED AGAIN. The harness drives one browser profile, so localStorage is
// shared and the newest tab's seeded session is the one every tab starts using (step 16's finding 46). The member
// cannot be open while the planner copies and publishes. So the member's schedule is read before the copy (the
// whole plan, still running), the tab is closed, the planner does the copy and the publish, and then the member's
// tab is opened again: the two readings are the same person's screen either side of one publish.
//
// What is proved, in order:
//   1. before the copy, the member follows the whole plan: five moments from T+0, the first one late because the
//      call passed with nobody marking it;
//   2. the planner's board still draws the plan, and pressing Copy plan makes a draft whose first frame is the cut:
//      the walk before it is not on the copy, and the inspector says the copy starts here;
//   3. the copy is a plan like any other ahead of that point: a frame after the cut can be edited, and publishing it
//      makes it the live plan;
//   4. publishing carries the running event across: the live strip names the copy at the same T+0, so the clock did
//      not move with the plan;
//   5. an edit that would put a frame before the cut is refused, with a sentence naming the cut, and the time field
//      goes back to what the plan says rather than keeping the time the database refused;
//   6. the member's schedule after the publish is the copy's: its first moment is the cut (the walk's own instant,
//      not T+0), it reads arrived rather than late, the edited moment carries the planner's new note, and nothing on
//      the schedule is planned before the cut.
import fs from 'node:fs'

/** "+15:20" -- the same shape the board's own time field reads (src/utils/planFrames.js formatOffset). */
function formatOffset(t_s) {
  const total = Math.max(0, Math.round(t_s))
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  return '+' + (h > 0 ? h + ':' + String(m).padStart(2, '0') : String(m)) + ':' + String(s).padStart(2, '0')
}

/** "+1:47" from a frame's title ("Frame +1:47 — call"). */
function offsetOfTitle(title) {
  const match = /^Frame \+(\d+):(\d{2})(?::(\d{2}))?/.exec(title || '')
  if (!match) return null
  if (match[3] != null) return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3])
  return Number(match[1]) * 60 + Number(match[2])
}

const FRESH = 'node tools/sql.mjs --file dev/checks/step17-fork-prep.sql'

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

export default {
  name: 'step 17 — a copy of a running plan starts where the walk already had everybody',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e17'
    const timeline = `${base}/events/${eventId}/timeline`
    const memberFile = process.env.MEMBER_SESSION || '.tmp/session3.json'
    if (!fs.existsSync(memberFile)) {
      throw new Error(
        `no Sound member session at ${memberFile}. Mint one with: node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 ${memberFile}`,
      )
    }
    const member = JSON.parse(fs.readFileSync(memberFile, 'utf8'))

    // ---------- 1. the member's schedule before there is a copy ----------
    const before = await newTab({ session: member, label: 'sound member (before)', url: timeline, width: 1440, height: 1000 })
    await before.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await before.waitUntil(`document.querySelectorAll('[data-testid=sched-row]').length === 5`, {
      timeout: 15000,
      what: 'the five moments of the plan before it is copied',
    })
    const beforeStates = await before.eval(
      `[...document.querySelectorAll('[data-testid=sched-row]')].map((r) => r.dataset.state).join(',')`,
    )
    if (beforeStates !== 'late,pending,pending,pending,pending') {
      throw new Error(`this bench is not fresh (the schedule reads ${beforeStates}). Rebuild it with ${FRESH}`)
    }
    await before.assertContains('[data-testid=sched-plan]', 'Doors walk')
    const beforeFirst = await before.eval(`document.querySelector('[data-testid=sched-moment]').dataset.t`)
    await before.assertThat('before the copy the schedule starts at T+0 itself', beforeFirst === '0')
    before.pass(`before the copy: ${beforeStates}`)
    const beforeT0 = await textOf(before, '[data-testid=sched-t0]')
    before.pass(`the plan's clock reads T+0 ${beforeT0}, ninety seconds old`)
    await before.close()

    // ---------- 2. the planner copies the running plan ----------
    const planner = await newTab({ label: 'planner', url: timeline, width: 1440, height: 1000 })
    await planner.waitFor('.pv-board', { timeout: 20000 })
    await planner.waitUntil(`document.querySelectorAll('.pv-frame').length === 5 && !!document.querySelector('[data-testid=plan-live]')`, {
      timeout: 20000,
      what: 'the board to open the live five-frame plan',
    })
    await planner.assertContains('.pv-select', 'Doors walk')
    const revChip = (await textOf(planner, '[data-testid=plan-live-rev]')).trim()
    if (revChip !== '1') {
      throw new Error(`this bench is not fresh (the live plan is revision ${revChip}). Rebuild it with ${FRESH}`)
    }
    const t0Iso = await planner.eval(`document.querySelector('[data-testid=plan-live-t0]').dataset.t0`)
    const t0 = new Date(t0Iso).getTime()
    const age = Math.round((Date.now() - t0) / 1000)
    if (age > 300) {
      throw new Error(`this bench is ${age}s old; the copy would be past too much of the walk. Rebuild it with ${FRESH}`)
    }
    planner.pass(`the plan is ${age}s into its walk, on T+0 ${new Date(t0Iso).toLocaleString('en-SG')}`)

    const sourceTitles = await planner.eval(`[...document.querySelectorAll('.pv-frame')].map((f) => f.title || '')`)
    const sourceOffsets = sourceTitles.map(offsetOfTitle)
    if (sourceOffsets.some((t) => t == null)) throw new Error(`unreadable frame titles: ${sourceTitles.join(' | ')}`)
    planner.pass(`the original's moments: ${sourceOffsets.map(formatOffset).join(', ')}`)

    await pressButton(planner, 'Copy plan')
    await planner.waitUntil(`!!document.querySelector('.pv-frame[data-cut=true]')`, {
      timeout: 15000,
      what: 'the copy to open with its starting frame marked',
    })
    await waitForToast(planner, 'Copied from')

    // The copy has the anchor at the cut and every frame after it -- and nothing else.
    const copyTitles = await planner.eval(`[...document.querySelectorAll('.pv-frame')].map((f) => f.title || '')`)
    const copyOffsets = copyTitles.map(offsetOfTitle)
    const cut = copyOffsets[0]
    if (cut == null) throw new Error(`the copy's first frame has no readable time: ${copyTitles[0]}`)
    const expectedAfter = sourceOffsets.filter((t) => t > cut)
    planner.pass(`the copy starts at ${formatOffset(cut)}, with ${expectedAfter.length} of the original's moments after it`)
    await planner.assertThat(
      'the copy is the anchor at the cut plus exactly the frames after it',
      copyOffsets.length === expectedAfter.length + 1 && copyOffsets.join(',') === [cut, ...expectedAfter].join(','),
    )
    await planner.assertThat(
      'the copy contains no frame at or before the cut except its start',
      copyOffsets.filter((t) => t <= cut).length === 1,
    )
    await planner.assertThat(
      'the frames the copy kept are the original\'s own times',
      expectedAfter.every((t) => copyOffsets.includes(t)),
    )
    const cutNote = await textOf(planner, '[data-testid=frame-cut-note]')
    planner.pass(`the story the board tells: "${cutNote}"`)
    await planner.assertThat('the inspector says the copy starts here', /This copy starts here/.test(cutNote))
    await planner.assertThat(
      'the starting frame\'s time cannot be typed into',
      `document.querySelector('#pv-frame-time').disabled`,
    )
    await planner.assertThat(
      'but its note can: it is a label, not the walk',
      `!document.querySelector('#pv-frame-note').disabled`,
    )
    await planner.assertContains('.pv-select', '(edited)')
    const pickerCut = await planner.eval(`document.querySelector('.pv-select').value`)
    planner.pass(`the copy is its own plan: ${pickerCut}`)

    await planner.sleep(1500)
    await planner.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await planner.sleep(350)
    await planner.shot('shots/step17-board.png')
    // The strip itself: the copy's first dot carries the ring that says "this is where the copy begins".
    await planner.eval(`document.querySelector('.pv-bar').scrollIntoView({ block: 'center' })`)
    await planner.sleep(350)
    await planner.shot('shots/step17-cut.png')

    // ---------- 3. the copy is an ordinary plan ahead of the cut ----------
    const lastIndex = copyOffsets.length - 1
    await planner.click('.pv-frame', { index: lastIndex })
    await planner.waitUntil(
      `document.querySelector('#pv-frame-time') && document.querySelector('#pv-frame-time').value === ${JSON.stringify(formatOffset(copyOffsets[lastIndex]))}`,
      { what: 'the last moment of the copy to be open' },
    )
    await planner.type('#pv-frame-note', 'out late')
    await planner.press('Enter')
    await planner.waitUntil(
      `[...document.querySelectorAll('.pv-frame')].some((f) => (f.title || '').includes('out late'))`,
      { timeout: 12000, what: 'the edit ahead of the cut to be written' },
    )
    planner.pass(`the planner edited the moment at ${formatOffset(copyOffsets[lastIndex])} ahead of the cut`)

    await pressButton(planner, 'Publish')
    await planner.waitFor('[data-testid=confirm-dialog]')
    await planner.assertContains('[data-testid=confirm-dialog]', 'Publish "Doors walk (edited)"?')
    await planner.click('[data-testid=confirm-ok]')

    // ---------- 4. publishing carries the running event across ----------
    await planner.waitUntil(
      `(() => { const el = document.querySelector('[data-testid=plan-live-rev]'); return !!el && el.textContent.trim() === '2' })()`,
      { timeout: 20000, what: 'the live strip to follow the copy at revision 2' },
    )
    const afterT0 = await planner.eval(`document.querySelector('[data-testid=plan-live-t0]').dataset.t0`)
    await planner.assertThat('the clock did not move with the plan', afterT0 === t0Iso)
    planner.pass(`the live strip: ${(await textOf(planner, '[data-testid=plan-live]')).split('T+0')[0].trim()}, same T+0`)
    await planner.assertContains('.pv-select', '(edited)')

    // ---------- 5. an edit before the cut is refused, and the field goes back ----------
    await planner.click('.pv-frame', { index: 1 })
    await planner.waitUntil(
      `document.querySelector('#pv-frame-time') && document.querySelector('#pv-frame-time').value === ${JSON.stringify(formatOffset(sourceOffsets[1]))}`,
      { what: 'the first kept moment to be open' },
    )
    const framesBefore = await planner.eval(`document.querySelectorAll('.pv-frame').length`)
    await planner.type('#pv-frame-time', '+0:10')
    // The refusal is a 4xx from the database on purpose; the page is supposed to show it in words.
    planner.expectHttp(400, 'frame_move')
    await planner.press('Enter')
    await waitForToast(planner, 'starts at')
    const refused = await lastToast(planner)
    await planner.assertThat('the refusal names the cut, not a constraint', /This copy starts at \+/.test(refused))
    await planner.assertThat(
      'the time field went back to the plan\'s own time',
      `document.querySelector('#pv-frame-time').value === ${JSON.stringify(formatOffset(sourceOffsets[1]))}`,
    )
    await planner.assertThat(
      'and nothing moved on the strip',
      `document.querySelectorAll('.pv-frame').length === ${framesBefore}`,
    )
    await planner.assertNoErrors()
    await planner.close()

    // ---------- 6. the member's schedule, after one publish ----------
    const after = await newTab({ session: member, label: 'sound member (after)', url: timeline, width: 1440, height: 1000 })
    await after.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await after.waitUntil(`document.querySelectorAll('[data-testid=sched-row]').length > 0`, {
      timeout: 15000,
      what: 'the copy\'s timetable',
    })
    await after.assertContains('[data-testid=sched-plan]', '(edited)')
    const afterRev = (await textOf(after, '[data-testid=sched-rev]')).trim()
    await after.assertThat('the member follows the copy at the revision it was published at', afterRev === '2')

    const moments = await after.eval(`[...document.querySelectorAll('[data-testid=sched-moment]')].map((m) => ({
      t: Number(m.dataset.t),
      note: (m.querySelector('[data-testid=sched-note]') || {}).textContent || '',
      state: (m.querySelector('[data-testid=sched-row]') || { dataset: {} }).dataset.state || '',
    }))`)
    after.pass(`after the copy: ${moments.map((m) => formatOffset(m.t) + '/' + m.state).join(', ')}`)
    await after.assertThat('the schedule starts at the cut, not at T+0', moments[0].t === cut)
    await after.assertThat('every moment on it is at or after the cut', moments.every((m) => m.t >= cut))
    await after.assertThat('the kept moments are the copy\'s own', moments.map((m) => m.t).join(',') === [cut, ...expectedAfter].join(','))
    await after.assertThat('the moment at the cut reads arrived: nobody was teleported and nobody is late', moments[0].state === 'arrived')
    const arrivedDetail = await textOf(after, '[data-testid=sched-moment][data-t="' + cut + '"] .pv-sched-detail')
    after.pass(`the hand-over reads: "${arrivedDetail}"`)
    await after.assertThat('and it says the arrival was recorded, on time', /recorded/.test(arrivedDetail) && /on time/.test(arrivedDetail))
    const notes = moments.map((m) => m.note.trim()).filter(Boolean)
    after.pass(`the moments are labelled: ${notes.join(', ')}`)
    await after.assertThat('the planner\'s edit ahead of the cut came with it', notes.includes('out late'))

    // The clock time on the first moment is the cut's wall time, which is T+0 + the cut -- not the plan's printed T+0.
    const firstAtText = await textOf(after, `[data-testid=sched-at-${cut}]`)
    after.pass(`the first moment is ${firstAtText}`)
    await after.assertThat('the first moment prints a clock time', /\d{1,2}:\d{2}\s?(am|pm)/.test(firstAtText))

    await after.sleep(400)
    await after.eval(`document.querySelector('[data-testid=plan-schedule]').scrollIntoView({ block: 'start' })`)
    await after.sleep(300)
    await after.shot('shots/step17-member-after.png')
    await after.assertNoErrors()
    await after.close()
  },
}
