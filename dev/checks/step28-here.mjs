// Step 28, proved through the screen: the group's IC can say "we're here" from their own timetable, and the mark is
// theirs -- the ops board says "by hand" for it and "the phone was there" for the tick's own close.
//
//     node tools/sql.mjs --file dev/checks/step28-here-prep.sql
//     node tools/authlink.mjs ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7 .tmp/session.json    (planner, root)
//     node tools/authlink.mjs ba04a00c-518f-4252-91d5-1081cecec1d2 .tmp/session4.json   (Gate Crew's first IC)
//     node tools/authlink.mjs 00cd023b-0e26-4574-a635-760e782c8029 .tmp/session5.json   (Gate Crew's second IC)
//     node tools/run.mjs dev/checks/step28-here.mjs --session .tmp/session.json
//
// Three tabs, one after another (one browser profile, so the newest tab's seeded session is every tab's identity --
// finding 46). The bench (`step28-here-prep.sql`) is a live plan whose +0:00 moment is the clock's, with Gate Crew's
// IC on it and no reading for Gate Crew, and Sound's IC standing on its own moment so the deployed tick closes it.
//
// What is proved, in order:
//   1. the IC's actual schedule offers ONE press, on the moment the clock is on, and not on the moments ahead -- and
//      pressing it writes `progress_mark`, turns the row to "arrived", and the row says when;
//   2. a reload finds the same row arrived with no press: the mark is in the database, not in the browser;
//   3. the group's SECOND IC opens the same page and sees the moment already recorded, with nothing to press -- the
//      same moment is not offered twice;
//   4. the planner's ops board says "Arrived ... · by hand" for Gate Crew's moment and "Arrived ... · the phone was
//      there" for Sound's -- the tick's close and a person's press are told apart by the row, not by a missing name
//      (064's `marked_auto`), and neither row offers the ops buttons once it is recorded.
import fs from 'node:fs'

const icOneFile = process.env.IC_SESSION || '.tmp/session4.json'
const icTwoFile = process.env.SECOND_IC_SESSION || '.tmp/session5.json'
const plannerFile = process.env.PLANNER_SESSION || '.tmp/session.json'

/** The first moment (0 s) in the timetable, as a selector. */
const FIRST = '[data-testid=sched-moment][data-t="0"]'

export default {
  name: 'step 28 — the IC says "we\'re here" from their own schedule',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e38'
    const timeline = `${base}/events/${eventId}/timeline`
    const live = `${base}/events/${eventId}/live`

    for (const [file, id, who] of [
      [icOneFile, 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'Gate Crew IC'],
      [icTwoFile, '00cd023b-0e26-4574-a635-760e782c8029', "Gate Crew's second IC"],
      [plannerFile, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'],
    ]) {
      if (!fs.existsSync(file)) {
        throw new Error(`no ${who} session at ${file}. Mint one with: node tools/authlink.mjs ${id} ${file}`)
      }
    }
    const icOne = JSON.parse(fs.readFileSync(icOneFile, 'utf8'))
    const icTwo = JSON.parse(fs.readFileSync(icTwoFile, 'utf8'))
    const planner = JSON.parse(fs.readFileSync(plannerFile, 'utf8'))

    // ---------- 1. the IC's own schedule ----------
    const mine = await newTab({ session: icOne, label: 'gate crew IC', url: timeline, width: 1200, height: 1000 })
    await mine.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await mine.waitUntil(`document.querySelectorAll('[data-testid=sched-moment]').length === 3`, {
      what: 'the three moments of the plan',
    })

    const firstState = await mine.eval(`document.querySelector('${FIRST} [data-testid=sched-state]').textContent.trim()`)
    mine.pass(`the +0:00 moment reads "${firstState}"`)
    await mine.assertThat('the moment the clock is on is late, the state a press belongs to', firstState.toLowerCase() === 'late')
    await mine.assertThat('the IC is offered exactly one press', (await mine.count('[data-testid=sched-here]')) === 1)
    await mine.assertThat(
      'and it belongs to the moment the clock is on',
      await mine.has(`${FIRST} [data-testid=sched-here]`),
    )
    await mine.assertThat(
      'the moments ahead offer nothing to press',
      !(await mine.has('[data-testid=sched-moment][data-t="300"] [data-testid=sched-here]')),
    )

    await mine.shot('shots/step28-here.png')

    await mine.click(`${FIRST} [data-testid=sched-here]`)
    await mine.waitUntil(`document.querySelector('${FIRST} [data-testid=sched-row]').dataset.state === 'arrived'`, {
      timeout: 12000,
      what: 'the moment to read arrived after the press',
    })
    const detail = await mine.text(`${FIRST} .pv-sched-detail`)
    mine.pass(`the row now says: ${detail}`)
    await mine.assertThat('the row records when it was said', /recorded /.test(detail))
    await mine.assertThat('and the press is gone once the moment is recorded', (await mine.count('[data-testid=sched-here]')) === 0)

    const asked = await mine.eval(`performance.getEntriesByType('resource').map((e) => e.name)`)
    await mine.assertThat(
      'the press went to progress_mark, the only door that writes a mark',
      asked.some((name) => name.includes('progress_mark')),
    )

    await mine.shot('shots/step28-arrived.png')
    await mine.assertNoErrors()
    await mine.close()

    // ---------- 2. a reload: the mark is the database's ----------
    const again = await newTab({ session: icOne, label: 'gate crew IC reloaded', url: timeline, width: 1200, height: 1000 })
    await again.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await again.waitUntil(`document.querySelectorAll('[data-testid=sched-moment]').length === 3`, {
      what: 'the three moments after a reload',
    })
    await again.waitUntil(`document.querySelector('${FIRST} [data-testid=sched-row]').dataset.state === 'arrived'`, {
      timeout: 12000,
      what: 'the moment to still read arrived after a reload',
    })
    await again.assertThat('the mark survived the reload', true)
    await again.assertThat('and there is still nothing left to press', (await again.count('[data-testid=sched-here]')) === 0)
    await again.assertNoErrors()
    await again.close()

    // ---------- 3. the group's second IC sees it done, not to do ----------
    const peer = await newTab({ session: icTwo, label: 'gate crew IC two', url: timeline, width: 1200, height: 1000 })
    await peer.waitFor('[data-testid=plan-schedule]', { timeout: 20000 })
    await peer.waitUntil(`document.querySelectorAll('[data-testid=sched-moment]').length === 3`, {
      what: "the second IC's three moments",
    })
    await peer.assertThat(
      "the second IC reads the first IC's mark",
      (await peer.eval(`document.querySelector('${FIRST} [data-testid=sched-row]').dataset.state`)) === 'arrived',
    )
    await peer.assertThat('and is not offered the same moment again', (await peer.count('[data-testid=sched-here]')) === 0)
    await peer.assertNoErrors()
    await peer.close()

    // ---------- 4. the ops board tells the two writers apart ----------
    const board = await newTab({ session: planner, label: 'planner', url: live, width: 1440, height: 1000 })
    await board.waitFor('[data-testid=plan-ops]', { timeout: 20000 })
    await board.waitUntil(`document.querySelectorAll('[data-testid=ops-row]').length === 2`, {
      what: 'the board to list both groups',
    })

    const gateMark = await board.eval(
      `(() => { const row = document.querySelector('[data-testid=ops-row][data-group="0b000000-0000-4000-8000-00000000a381"] [data-testid=ops-mark]')
        return row ? row.textContent.replace(/\\s+/g, ' ').trim() : null })()`,
    )
    if (!gateMark) throw new Error('the ops board has no mark for Gate Crew, whose IC just pressed')
    board.pass(`the board says: ${gateMark}`)
    await board.assertThat("Gate Crew's mark is the press's, so it says by hand", /by hand/.test(gateMark))

    // The tick closes Sound's moment by itself within a few seconds of the bench being built. Waiting for the board's
    // own words (not a sleep) is also waiting for the deployed five-second job.
    await board.waitUntil(
      `(() => { const row = document.querySelector('[data-testid=ops-row][data-group="0b000000-0000-4000-8000-00000000a382"] [data-testid=ops-mark]')
        return !!row && /the phone was there/.test(row.textContent) })()`,
      { timeout: 30000, what: "the tick's close of Sound's moment to appear on the board" },
    )
    const soundMark = await board.text(
      '[data-testid=ops-row][data-group="0b000000-0000-4000-8000-00000000a382"] [data-testid=ops-mark]',
    )
    board.pass(`the board also says: ${soundMark}`)
    await board.assertThat(
      "the tick's close is told apart from a person's (marked_auto, not a missing name)",
      /the phone was there/.test(soundMark),
    )

    for (const group of ['0b000000-0000-4000-8000-00000000a381', '0b000000-0000-4000-8000-00000000a382']) {
      await board.assertThat(
        `a recorded moment offers no Arrived/Missed buttons (${group.slice(-4)})`,
        !(await board.has(`[data-testid=ops-row][data-group="${group}"] [data-testid=ops-mark-arrived]`)) &&
          !(await board.has(`[data-testid=ops-row][data-group="${group}"] [data-testid=ops-mark-missed]`)),
      )
    }

    await board.assertNoErrors()
    await board.shot('shots/step28-ops.png')
    await board.close()
  },
}
