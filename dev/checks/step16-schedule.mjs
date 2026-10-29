// Step 16, proved through the screen: a member reads their own schedule, the board stays the planner's, and the
// clock turns a moment from "due" to "late" without the page being reloaded.
//
//     node tools/sql.mjs --file dev/checks/step16-schedule-prep.sql
//     node tools/run.mjs dev/checks/step16-schedule.mjs --session .tmp/session.json
//
// Needs two more sessions (the check says so if they are missing):
//     node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 .tmp/session3.json   (Sound, plain member)
//     node tools/authlink.mjs 00cd023b-0e26-4574-a635-760e782c8029 .tmp/session5.json   (marshal, no group)
//
// The event is dev/checks/step16-schedule-prep.sql's own bench (e16): a live plan whose five moments carry all five
// words -- arrived, not required, late, missed, pending -- for Sound, and a second group so "only their group" has
// something it must not show. The check refuses to run against a bench that has already been changed.
//
// WHY THE TABS ARE OPENED IN THIS ORDER. The harness drives one browser profile, so localStorage is shared and the
// newest tab's seeded session is the one every tab starts using: a tab opened as the planner makes the whole browser
// the planner. That is a property of the bench, not of the app (step 3's check is written the same way). So the
// planner acts first, and is finished before the member exists; the member is opened second and is the identity while
// everything about the schedule is asserted; the marshal is opened last, because its read is about scope and not about
// the clock. The push that tells a screen a plan was republished is step 15's proof, with two tabs of one identity;
// the other half -- the clock waking the page at the moment the read gave it -- is proved here, on a tab nobody
// touches after it opens.
//
// What is proved, in order:
//   1. the planner's page is still the board: five frames, the picker naming the plan, the running revision on the
//      strip. Closing the plan surface must not have narrowed the people who draw;
//   2. the planner moves the last moment to half a minute ahead and republishes -- the product's own way of changing
//      a timetable people are already following;
//   3. the member's Timeline tab is called Schedule and shows the timetable, not the board: no strip, no picker, no
//      Add frame, no Publish -- and the page never asks the database for the plan or its frames, only for its own
//      timetable;
//   4. their five moments are their group's five, in clock order, with the clock times the plan's T+0 gives them and
//      the five words on them;
//   5. the moved moment reads "due" and then turns "late" when the clock passes it -- no reload, and with a second
//      read visible in the browser's resource timings;
//   6. a marshal opens the same page as a timetable with every group on it (10 rows) -- closing the plan surface did
//      not close the ops read;
//   7. once the planner ends the event, the member's page still reads its timetable, with the clock stopped at the
//      moment it closed and nothing left saying "due" -- the closed branch of the screen, read at its end time.
import fs from 'node:fs'

/** "+15:20" -- the same shape the board's own time field reads (src/utils/planFrames.js formatOffset). */
function formatOffset(t_s) {
  const total = Math.max(0, Math.round(t_s))
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  return '+' + (h > 0 ? h + ':' + String(m).padStart(2, '0') : String(m)) + ':' + String(s).padStart(2, '0')
}

const READS = `performance.getEntriesByType('resource').filter((e) => e.name.includes('session_timetable')).length`
const FRESH = 'node tools/sql.mjs --file dev/checks/step16-schedule-prep.sql'

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

export default {
  name: "step 16 — a member's schedule is their own group's timetable, and the clock turns it",

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e16'
    const timeline = `${base}/events/${eventId}/timeline`
    const memberFile = process.env.MEMBER_SESSION || '.tmp/session3.json'
    const marshalFile = process.env.MARSHAL_SESSION || '.tmp/session5.json'
    for (const [file, id, who] of [
      [memberFile, '2906655b-33ad-4e9d-a608-f083e43e22d4', 'Sound member'],
      [marshalFile, '00cd023b-0e26-4574-a635-760e782c8029', 'marshal'],
    ]) {
      if (!fs.existsSync(file)) {
        throw new Error(`no ${who} session at ${file}. Mint one with: node tools/authlink.mjs ${id} ${file}`)
      }
    }
    const member = JSON.parse(fs.readFileSync(memberFile, 'utf8'))
    const marshal = JSON.parse(fs.readFileSync(marshalFile, 'utf8'))

    // ---------- 1. the planner's page is still the board ----------
    const planner = await newTab({ label: 'planner', url: timeline, width: 1440, height: 1000 })
    await planner.waitFor('.pv-board', { timeout: 20000 })
    await planner.waitUntil(
      `document.querySelectorAll('.pv-frame').length === 5 && !!document.querySelector('.pv-select')`,
      { what: 'the board to open the five-frame plan' },
    )
    await planner.assertThat('the planner has no schedule', `!document.querySelector('[data-testid=plan-schedule]')`)
    const plannerTab = await planner.text('[data-testid=tab-timeline]')
    await planner.assertThat("and the planner's tab still says Timeline", plannerTab.trim() === 'Timeline')
    await planner.assertContains('.pv-select', 'Doors walk')

    const frameTitles = await planner.eval(`[...document.querySelectorAll('.pv-frame')].map((f) => f.title || '')`)
    planner.pass(`the board's five moments: ${frameTitles.map((t) => t.split(' — ')[0]).join(', ')}`)
    const stripRev = await planner.eval(`document.querySelector('[data-testid=plan-live-rev]').textContent.trim()`)
    if (stripRev !== '1' || !frameTitles.some((t) => t.startsWith('Frame +25:00'))) {
      throw new Error(`this bench is not fresh (revision ${stripRev}). Rebuild it with ${FRESH}`)
    }
    await planner.assertThat('the running plan is revision 1, and the last moment is still +25:00', stripRev === '1')
    // The tiles are the map's business, not the board's: give them a moment so the control picture shows the plan
    // rather than a grey stage (the fit itself happened on the board's own schedule), and put the whole board in
    // the viewport so the picture is the screen rather than its top half.
    await planner.sleep(1800)
    await planner.eval(`document.querySelector('.pv-board').scrollIntoView({ block: 'start' })`)
    await planner.sleep(400)
    await planner.shot('shots/step16-board.png')

    // ---------- 2. the planner changes the running timetable, the product's way ----------
    // The member's clock is the plan's T+0, and the strip already names the instant it is showing (data-t0). The
    // offset that lands the moved moment half a minute ahead is computed from it, so the member's page sees a
    // moment that is genuinely due when it arrives.
    const t0Iso = await planner.eval(`document.querySelector('[data-testid=plan-live-t0]').dataset.t0`)
    const t0 = new Date(t0Iso).getTime()
    const target = Math.round((Date.now() - t0) / 1000) + 35
    const at = formatOffset(target)
    planner.pass(`T+0 is ${new Date(t0Iso).toLocaleString('en-SG')}; moving the last moment to ${at}`)

    await planner.click('.pv-frame', { index: 4 })
    await planner.waitUntil(`document.querySelector('#pv-frame-time').value === '+25:00'`, {
      what: 'the last dot to be open at +25:00',
    })
    await planner.type('#pv-frame-time', at)
    await planner.press('Enter')
    await planner.waitUntil(
      `[...document.querySelectorAll('.pv-frame')].some((f) => (f.title || '').startsWith('Frame ${at}'))`,
      { timeout: 12000, what: `the frame to move to ${at}` },
    )
    planner.pass(`the board moved the moment to ${at}`)

    // The move's own write leaves the toolbar busy for a moment (a second save in flight would be refused as stale),
    // so the button is waited for rather than clicked at: pressing it while disabled does nothing at all.
    await planner.waitUntil(
      `(() => {
         const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Publish again')
         return !!button && !button.disabled
       })()`,
      { what: 'Publish again to be ready' },
    )
    const clicks = await planner.eval(`(() => {
      const button = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Publish again')
      if (!button) return 'no Publish again button'
      button.click()
      return 'clicked'
    })()`)
    planner.pass(`publish again: ${clicks}`)
    await planner.waitFor('[data-testid=confirm-dialog]')
    await planner.assertContains('[data-testid=confirm-dialog]', 'Publish "Doors walk" again?')
    await planner.click('[data-testid=confirm-ok]')
    await planner.waitUntil(
      `document.querySelector('[data-testid=plan-live-rev]') &&
       document.querySelector('[data-testid=plan-live-rev]').textContent.trim() === '2'`,
      { timeout: 15000, what: 'the board to adopt revision 2' },
    )
    planner.pass('the republish is revision 2')
    await planner.assertNoErrors()
    // Closed before the member's tab exists: the bench shares one browser profile, so a tab left open would change
    // identity under the next one and start asking for things its new role may not have (the run sheets, here).
    await planner.close()

    // ---------- 3. the member's page: a schedule, not the board ----------
    const viewer = await newTab({
      session: member,
      label: 'sound member',
      url: timeline,
      width: 1440,
      height: 1000,
    })
    await viewer.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await viewer.waitUntil(`document.querySelectorAll('[data-testid=sched-row]').length > 0`, {
      what: 'the timetable rows to arrive',
    })

    const rev = await textOf(viewer, '[data-testid=sched-rev]')
    const rows = await viewer.eval(`[...document.querySelectorAll('[data-testid=sched-row]')].map((r) => ({
      state: r.dataset.state, group: r.dataset.group,
    }))`)
    if (rev !== '2' || rows.length !== 5) {
      throw new Error(
        `this bench is not the shape this check left it in (revision ${rev}, ${rows.length} rows). Rebuild it with ${FRESH}`,
      )
    }

    const tabLabel = await viewer.text('[data-testid=tab-timeline]')
    viewer.pass(`the member's Timeline tab is called "${tabLabel.trim()}"`)
    await viewer.assertThat('and it says Schedule', tabLabel.trim() === 'Schedule')

    // The board is not this screen with its controls hidden: none of it is rendered.
    await viewer.assertThat(
      "no plan board, no strip, no picker, no frames on the member's page",
      `!document.querySelector('.pv-board') && !document.querySelector('.pv-select') &&
       !document.querySelector('.pv-frame') && !document.querySelector('.pv-map') &&
       !document.querySelector('[data-testid=plan-live]')`,
    )
    const body = await viewer.bodyText()
    for (const control of ['Add frame', 'Publish', 'Copy plan', 'Delete plan', 'Undo', 'Redo']) {
      await viewer.assertThat(`the member has no "${control}"`, !body.includes(control))
    }

    // The one read: this page must not ask for the plan or its frames at all.
    const asked = await viewer.eval(`performance.getEntriesByType('resource')
      .map((e) => e.name)
      .filter((name) => /\\/rest\\/v1\\/(plan_frames|plan_list|plan_positions|plan_progress)/.test(name))`)
    viewer.pass(`the page asked for ${asked.length} plan-surface resource(s)`)
    await viewer.assertThat("the member's screen never asks for the plan or its frames", asked.length === 0)

    // ---------- 4. their five moments, and only their group ----------
    viewer.pass(`the member's moments: ${rows.map((r) => r.state).join(' → ')}`)
    await viewer.assertThat('five moments, one per frame', rows.length === 5)
    await viewer.assertThat(
      'all five words the timetable can print, in clock order',
      rows.map((r) => r.state).join(',') === 'arrived,not_required,late,missed,pending',
    )
    const groups = [...new Set(rows.map((r) => r.group))]
    await viewer.assertThat('every row is one group', groups.length === 1)
    await viewer.assertThat('and it is Sound', rows.every((r) => r.group === groups[0]) && !body.includes('Gate Crew'))

    // The words as a person reads them, not as the database spells them.
    const words = await viewer.eval(
      `[...document.querySelectorAll('[data-testid=sched-state]')].map((e) => e.textContent.trim()).join('|')`,
    )
    viewer.pass(`the schedule says: ${words}`)
    await viewer.assertThat('the five words are printed for a reader', words === 'arrived|not required|late|missed|due')

    await viewer.assertContains('[data-testid=sched-plan]', 'Doors walk')
    await viewer.assertContains('[data-testid=sched-group]', 'Sound')
    // textContent, not innerText: the badge is uppercased by CSS.
    const phaseWord = await viewer.eval(`document.querySelector('[data-testid=sched-phase]').textContent.trim()`)
    await viewer.assertThat('the header says the event is live', phaseWord === 'live')

    // The clock times are the plan's, and the first moment is T+0 by definition -- so the header and the first row
    // must agree. If the screen added the clock wrongly, they would not.
    const t0Text = await textOf(viewer, '[data-testid=sched-t0]')
    const firstAt = await textOf(viewer, '[data-testid=sched-at-0]')
    viewer.pass(`T+0 is ${t0Text}, and the first moment is ${firstAt}`)
    await viewer.assertThat('the first moment is T+0 itself', firstAt === t0Text)
    await viewer.assertThat(
      'every moment prints a clock time, not an offset alone',
      `[...document.querySelectorAll('[data-testid=sched-moment]')].every((m) =>
         /\\d{1,2}:\\d{2}\\s?(am|pm)/.test(m.querySelector('.pv-sched-at').textContent))`,
    )
    // The planner's notes are the labels on the moments.
    const notes = await viewer.eval(
      `[...document.querySelectorAll('[data-testid=sched-note]')].map((e) => e.textContent.trim()).join(',')`,
    )
    viewer.pass(`the moments are labelled: ${notes}`)
    await viewer.assertThat('the notes came with the times', notes === 'call,build,curtain,out')

    // What each word means, in the detail line.
    const detailOf = (state) =>
      textOf(viewer, `[data-testid=sched-row][data-state="${state}"] .pv-sched-detail`)
    const arrived = await detailOf('arrived')
    const late = await detailOf('late')
    const offSite = await detailOf('not_required')
    const missed = await detailOf('missed')
    const pending = await detailOf('pending')
    viewer.pass(`arrived: "${arrived}"`)
    viewer.pass(`late: "${late}"`)
    viewer.pass(`not required: "${offSite}"`)
    viewer.pass(`missed: "${missed}"`)
    viewer.pass(`pending: "${pending}"`)
    await viewer.assertThat(
      'the arrival says it was two minutes late and when it was recorded',
      /2 min late/.test(arrived) && /recorded/.test(arrived),
    )
    await viewer.assertThat('the late moment says how late the clock is', /late/.test(late))
    await viewer.assertThat('the off-site moment says there was nothing to arrive at', offSite === 'off site at this moment')
    await viewer.assertThat('the missed moment says a decision was made, and when', /decided/.test(missed) && /recorded/.test(missed))
    await viewer.assertThat('the pending moment counts down', /in \d+ (min|s)/.test(pending))

    // ---------- 5. the clock: due now, late a moment later, with no reload ----------
    const loadsBefore = viewer.loads
    const readsBefore = await viewer.eval(READS)
    const movedState = `(() => {
      const moment = [...document.querySelectorAll('[data-testid=sched-moment]')].find((m) => m.dataset.t === '${target}')
      const row = moment && moment.querySelector('[data-testid=sched-row]')
      return row ? row.dataset.state : ''
    })()`
    await viewer.waitUntil(`!!document.querySelector('[data-testid=sched-moment][data-t="${target}"]')`, {
      timeout: 15000,
      what: `the moved moment at ${at} to be on the member's screen`,
    })
    await viewer.waitUntil(`${movedState} === 'pending'`, {
      timeout: 15000,
      what: `the moment at ${at} to be due, not yet late`,
    })
    const dueText = await textOf(viewer, `[data-testid=sched-moment][data-t="${target}"] .pv-sched-detail`)
    viewer.pass(`the moved moment is due: "${dueText}"`)
    await viewer.assertThat('and it counts down', /in \d+ (s|min)/.test(dueText))

    await viewer.waitUntil(`${movedState} === 'late'`, {
      timeout: 60000,
      what: `the clock to pass the moment at ${at} with no reload`,
    })
    const lateText = await textOf(viewer, `[data-testid=sched-moment][data-t="${target}"] .pv-sched-detail`)
    viewer.pass(`the same moment, a moment later: "${lateText}"`)
    await viewer.assertThat('the screen says it is late', /late$/.test(lateText))
    await viewer.assertThat('the tab was never reloaded', viewer.loads === loadsBefore)

    const readsAfter = await viewer.eval(READS)
    viewer.pass(`the member's page read the timetable ${readsBefore} → ${readsAfter} times`)
    await viewer.assertThat('the clock made the page ask the database again', readsAfter > readsBefore)
    await viewer.shot('shots/step16-member-schedule.png')
    await viewer.assertNoErrors()
    await viewer.close()

    // ---------- 6. the marshal reads the same page with every group on it ----------
    const ops = await newTab({ session: marshal, label: 'marshal', url: timeline, width: 1440, height: 1000 })
    await ops.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await ops.waitUntil(`document.querySelectorAll('[data-testid=sched-row]').length === 10`, {
      what: 'ten rows: two groups, five moments',
    })
    await ops.assertThat('the marshal has no board either', `!document.querySelector('.pv-board')`)
    await ops.assertContains('.pv-sched-title', 'Timetable')
    const opsGroups = await ops.eval(
      `[...new Set([...document.querySelectorAll('.pv-sched-group')].map((e) => e.textContent.trim()))]`,
    )
    ops.pass(`the marshal's timetable names ${opsGroups.join(' and ')}`)
    await ops.assertThat(
      'both groups are named',
      opsGroups.length === 2 && opsGroups.includes('Gate Crew') && opsGroups.includes('Sound'),
    )
    // The other group's record is on the ops read; the member's page has no row of it at all.
    await ops.assertThat(
      "the other group's rows are on the ops read",
      `[...document.querySelectorAll('[data-testid=sched-row]')].some((r) =>
         r.dataset.group === '0b000000-0000-4000-8000-00000000a160' && r.dataset.state === 'arrived')`,
    )
    await ops.shot('shots/step16-marshal-timetable.png')
    await ops.assertNoErrors()
    await ops.close()

    // ---------- 7. a closed event keeps its timetable, read as it stood when it closed ----------
    const closing = await newTab({ label: 'closing planner', url: timeline, width: 1440, height: 1000 })
    await closing.waitFor('[data-testid=end-event-btn]', { timeout: 20000 })
    await closing.click('[data-testid=end-event-btn]')
    await closing.waitFor('[data-testid=confirm-dialog]')
    await closing.click('[data-testid=confirm-ok]')
    await closing.waitFor('[data-testid=status-not-started]', { timeout: 20000 })
    closing.pass('the planner ended the event')
    await closing.assertNoErrors()
    await closing.close()

    const after = await newTab({ session: member, label: 'member after the end', url: timeline, width: 1440, height: 1000 })
    await after.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await after.waitUntil(`document.querySelectorAll('[data-testid=sched-row]').length === 5`, {
      what: 'the closed timetable to render',
    })
    const endedPhase = await after.eval(`document.querySelector('[data-testid=sched-phase]').textContent.trim()`)
    await after.assertThat('the closed event reads as ended', endedPhase === 'ended')
    const endedLine = await textOf(after, '[data-testid=sched-ended]')
    const frozenClock = await textOf(after, '[data-testid=sched-now]')
    after.pass(`the closed schedule says "${endedLine}"`)
    await after.assertThat('the clock is the moment it closed, not the wall clock now', endedLine.includes(frozenClock))
    // Read at that instant, the night is as it ended: the two unmarked moments in the past are late, and nothing is
    // still "due" -- a closed show has nothing left to come.
    const endedStates = await after.eval(
      `[...document.querySelectorAll('[data-testid=sched-row]')].map((r) => r.dataset.state).join(',')`,
    )
    after.pass(`the closed timetable reads ${endedStates}`)
    await after.assertThat('nothing is still pending on a closed event', endedStates === 'arrived,not_required,late,missed,late')
    await after.shot('shots/step16-ended-schedule.png')
    await after.assertNoErrors()
  },
}
