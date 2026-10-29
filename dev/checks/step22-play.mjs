// Step 22, proved through the screen: the run plays on the strip, and a message reaches one group and not the other.
//
//     node tools/sql.mjs --file dev/checks/step22-play-prep.sql
//     node tools/run.mjs dev/checks/step22-play.mjs --session .tmp/session.json
//
// Needs two more sessions (the check says so if they are missing):
//     node tools/authlink.mjs ba04a00c-518f-4252-91d5-1081cecec1d2 .tmp/session4.json   (Gate Crew IC)
//     node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 .tmp/session3.json   (Sound admin)
//
// The event is the prep's own bench (e32): a live plan three moments long, a clock thirty seconds in, and one published
// change that moved Gate Crew's last moment and left Sound's walk alone.
//
// WHY THE TABS ARE OPENED IN THIS ORDER. The harness drives one browser profile, so localStorage is shared and the
// newest tab's seeded session is the identity the *whole browser* is heading for -- and a tab that reads again later
// (a poll, or the re-read an ack triggers) can find itself signed in as the newest tab's person. So each identity does
// all of its reading while it is the newest tab and is not touched after: the planner plays the run and sends the
// message; the Gate Crew IC reads, then acks; the Sound admin reads their one row, then acks. The tally those acks
// moved is read at the end on a *fresh* planner tab, which is stronger than watching the old one: it proves the count
// is in the database rather than on the screen that sent it.
//
// What is proved, in order:
//   1. THE RUN PLAYS. The planner presses Play on the strip; the cursor moves between the moments, the clock in the bar
//      advances, the caption says what the run is walking towards, and the badge on the map actually moves. The run
//      reaches the last moment and stops itself, the clock reading the end of the walk; Stop goes back to editing with
//      the moment the cursor was on open.
//   2. THE LOG HAS THE PLAN'S OWN VOICE. The ops board already has one row: the publish that moved Gate Crew's moment,
//      marked "Times changed", naming them and waiting on them. It was written by the plan, not typed by anybody.
//   3. A MESSAGE IS SENT AND COUNTED. The planner sends one message to every group; the row appears at the top with
//      "0 of 3 got it · waiting on Gate Crew, Sound".
//   4. ONE GROUP IS TOLD. The Gate Crew IC's schedule shows the timeline change AND the message; the Sound admin's shows
//      only the message. That is "only the affected groups are asked to ack", read as a person reads it.
//   5. ONE TAP. Each member presses Got it on the message; the row says "got it <time>" and the button is gone. The
//      timeline change is still waiting afterwards -- one tap acks one row, not a person's whole list.
//   6. THE TALLY MOVED. A fresh planner tab reads "2 of 3 got it · waiting on Gate Crew" for the message and "0 of 2"
//      for the change, with no reload involved.
import fs from 'node:fs'

const EVENT = '0b000000-0000-4000-8000-000000000e32'
const GATE = '0b000000-0000-4000-8000-00000000a321'

/** A log row's words, by kind, from the ops board. */
async function logRow(tab, kind) {
  return tab.eval(`(() => {
    const row = document.querySelector('[data-testid=log-row][data-kind="${kind}"]')
    if (!row) return null
    const text = (selector) => {
      const el = row.querySelector(selector)
      return el ? (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim() : ''
    }
    return { tally: text('[data-testid=log-tally]'), body: text('[data-testid=log-body]'), from: text('[data-testid=log-from]') }
  })()`)
}

/** The top-left corner of the first badge on the map, in screen pixels: the run has to move it. */
const MARKER_AT = `(() => {
  const el = document.querySelector('.pv-marker')
  if (!el) return null
  const rect = el.getBoundingClientRect()
  return { x: Math.round(rect.left), y: Math.round(rect.top) }
})()`

export default {
  name: 'step 22 — the run plays on the strip, and one group is told what changed',

  async run({ newTab, base }) {
    const timeline = `${base}/events/${EVENT}/timeline`
    const live = `${base}/events/${EVENT}/live`
    const plannerFile = process.env.SESSION_FILE || '.tmp/session.json'
    const gateFile = process.env.GATE_SESSION || '.tmp/session4.json'
    const soundFile = process.env.SOUND_SESSION || '.tmp/session3.json'
    for (const [file, id, who] of [
      [plannerFile, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'],
      [gateFile, 'ba04a00c-518f-4252-91d5-1081cecec1d2', 'Gate Crew IC'],
      [soundFile, '2906655b-33ad-4e9d-a608-f083e43e22d4', 'Sound admin'],
    ]) {
      if (!fs.existsSync(file)) {
        throw new Error(`no ${who} session at ${file}. Mint one with: node tools/authlink.mjs ${id} ${file}`)
      }
    }
    const gate = JSON.parse(fs.readFileSync(gateFile, 'utf8'))
    const sound = JSON.parse(fs.readFileSync(soundFile, 'utf8'))

    // ---------- 1. the run plays ----------
    const board = await newTab({ label: 'planner, the strip', url: timeline, width: 1440, height: 1000 })
    await board.waitFor('.pv-board', { timeout: 20000 })
    await board.waitUntil(`document.querySelectorAll('.pv-frame').length === 3`, {
      timeout: 20000,
      what: 'the three moments of the walk on the strip',
    })

    const idleButton = await board.text('[data-testid=play]')
    await board.assertThat(`the strip offers Play before the run starts (${idleButton})`, idleButton === 'Play')

    const markerBefore = await board.eval(MARKER_AT)
    await board.click('[data-testid=play]')
    await board.waitUntil(`!!document.querySelector('[data-testid=play-head]')`, {
      timeout: 5000,
      what: 'the run cursor to appear on the strip',
    })
    const clockEarly = await board.text('[data-testid=play-clock]')
    const headEarly = await board.eval(`document.querySelector('[data-testid=play-head]').getBoundingClientRect().left`)
    await board.assertThat(
      `the run starts near the plan's own zero and says so (${clockEarly})`,
      /^\+0:\d\d$/.test(clockEarly),
    )
    const hint = await board.text('[data-testid=board-hint]')
    await board.assertThat(`the caption says the run is playing (${hint})`, hint.includes('playing at 60×'))

    await board.sleep(700)
    const clockLater = await board.text('[data-testid=play-clock]')
    const headLater = await board.eval(`document.querySelector('[data-testid=play-head]').getBoundingClientRect().left`)
    const markerLater = await board.eval(MARKER_AT)
    await board.assertThat(
      `the strip's clock advances while the run is on (${clockEarly} -> ${clockLater})`,
      clockLater !== clockEarly,
    )
    await board.assertThat(
      `the cursor moves along the strip (${Math.round(headEarly)}px -> ${Math.round(headLater)}px)`,
      headLater > headEarly + 20,
    )
    await board.assertThat(
      `the badge on the map moves with the clock (${JSON.stringify(markerBefore)} -> ${JSON.stringify(markerLater)})`,
      !!markerBefore && !!markerLater && (markerLater.x !== markerBefore.x || markerLater.y !== markerBefore.y),
    )

    // The walk is two minutes long and the run is at 60x, so it reaches its end and stops by itself.
    await board.waitUntil(`document.querySelector('[data-testid=play]').innerText.trim() === 'Resume'`, {
      timeout: 10000,
      what: 'the run to reach the end of the walk and stop',
    })
    const endClock = await board.text('[data-testid=play-clock]')
    await board.assertThat(`the run stops at the last moment (${endClock})`, endClock === '+2:00')
    await board.shot('shots/step22-play.png')

    // Stop goes back to editing, with the moment the cursor was on open.
    await board.click('[data-testid=play-stop]')
    await board.waitUntil(`!document.querySelector('[data-testid=play-head]')`, {
      timeout: 5000,
      what: 'the run cursor to be gone after Stop',
    })
    const reopened = await board.eval(`(() => { const el = document.querySelector('#pv-frame-time'); return el ? el.value : null })()`)
    await board.assertThat(`Stop opens the moment the run ended on (${reopened})`, reopened === '+2:00')
    // Asserted while this is still the only identity on the browser (see the note above).
    await board.assertNoErrors()

    // ---------- 2. the plan's own row is on the board ----------
    const ops = await newTab({ label: 'planner, ops board', url: live, width: 1440, height: 1100 })
    await ops.waitFor('[data-testid=plan-ops]', { timeout: 25000 })
    await ops.waitUntil(`document.querySelectorAll('[data-testid=log-row]').length === 1`, {
      timeout: 25000,
      what: 'the publish’s own log row',
    })
    const change = await logRow(ops, 'timeline')
    await ops.assertThat(
      `the publish's row names the group whose times changed (${change && change.body})`,
      !!change && change.body === 'The timetable changed for Gate Crew (version 3).',
    )
    await ops.assertThat(
      `and it is waiting on them (${change && change.tally})`,
      !!change && change.tally === '0 of 2 got it · waiting on Gate Crew',
    )

    // ---------- 3. a message to every group ----------
    const typed = 'Weather: towers at 7. Covers on, everyone in.'
    await ops.type('[data-testid=log-draft]', typed)
    await ops.click('[data-testid=log-send]')
    await ops.waitUntil(`document.querySelectorAll('[data-testid=log-row]').length === 2`, {
      timeout: 20000,
      what: 'the sent message to appear at the top of the log',
    })
    const message = await logRow(ops, 'message')
    await ops.assertThat(`the message is at the top of the log (${message && message.body})`, !!message && message.body === typed)
    await ops.assertThat(
      `and it counts everybody it was sent to (${message && message.tally})`,
      !!message && message.tally === '0 of 3 got it · waiting on Gate Crew, Sound',
    )
    await ops.assertNoErrors()

    // ---------- 4. one group is told, the other is not ----------
    const gateTab = await newTab({ session: gate, label: 'Gate Crew IC', url: timeline, width: 1280, height: 1000 })
    await gateTab.waitFor('[data-testid=plan-schedule]', { timeout: 25000 })
    await gateTab.waitUntil(`document.querySelectorAll('[data-testid=sched-msg]').length === 2`, {
      timeout: 25000,
      what: 'Gate Crew’s change and the message on their schedule',
    })
    const gateKinds = await gateTab.eval(
      `[...document.querySelectorAll('[data-testid=sched-msg]')].map((el) => el.getAttribute('data-kind'))`,
    )
    await gateTab.assertThat(
      `Gate Crew's schedule carries the timeline change and the message (${gateKinds.join(', ')})`,
      gateKinds.length === 2 && gateKinds.includes('timeline') && gateKinds.includes('message'),
    )

    // ---------- 5. one tap, while this is still the newest tab ----------
    await gateTab.click('[data-testid=sched-msg][data-kind=message] [data-testid=sched-ack]')
    await gateTab.waitUntil(
      `document.querySelector('[data-testid=sched-msg][data-kind=message]').getAttribute('data-acked') === 'true'`,
      { timeout: 15000, what: 'Gate Crew’s ack of the message' },
    )
    const gateDone = await gateTab.text('[data-testid=sched-msg][data-kind=message] [data-testid=sched-acked]')
    await gateTab.assertThat(`Gate Crew's schedule says got it, with the time (${gateDone})`, /^got it \d{1,2}:\d{2}/.test(gateDone))
    const gateChange = await gateTab.eval(
      `document.querySelector('[data-testid=sched-msg][data-kind=timeline]').getAttribute('data-acked')`,
    )
    await gateTab.assertThat(
      `the timeline change is still waiting for them -- one tap is one row (${gateChange})`,
      gateChange === 'false',
    )
    await gateTab.assertNoErrors()

    // ---------- 6. the group nobody's walk changed for sees the message and nothing else ----------
    const soundTab = await newTab({ session: sound, label: 'Sound admin', url: timeline, width: 1280, height: 1000 })
    await soundTab.waitFor('[data-testid=plan-schedule]', { timeout: 25000 })
    await soundTab.waitUntil(`document.querySelectorAll('[data-testid=sched-msg]').length >= 1`, {
      timeout: 25000,
      what: 'the message on Sound’s schedule',
    })
    const soundKinds = await soundTab.eval(
      `[...document.querySelectorAll('[data-testid=sched-msg]')].map((el) => el.getAttribute('data-kind'))`,
    )
    await soundTab.assertThat(
      `Sound's schedule carries the message only -- their walk did not change (${soundKinds.join(', ')})`,
      soundKinds.length === 1 && soundKinds[0] === 'message',
    )
    await soundTab.click('[data-testid=sched-ack]')
    await soundTab.waitUntil(
      `document.querySelector('[data-testid=sched-msg]').getAttribute('data-acked') === 'true'`,
      { timeout: 15000, what: 'Sound’s ack' },
    )
    await soundTab.assertNoErrors()

    // ---------- 7. a fresh planner tab reads the tally both acks moved ----------
    const checkTab = await newTab({ label: 'planner, reading the tally', url: live, width: 1440, height: 1100 })
    await checkTab.waitFor('[data-testid=plan-ops]', { timeout: 25000 })
    await checkTab.waitUntil(
      `(() => {
        const row = document.querySelector('[data-testid=log-row][data-kind=message]')
        if (!row) return false
        const tally = row.querySelector('[data-testid=log-tally]')
        return !!tally && tally.innerText.includes('2 of 3')
      })()`,
      { timeout: 25000, what: 'the fresh board to read the tally at 2 of 3' },
    )
    const messageAfter = await logRow(checkTab, 'message')
    await checkTab.assertThat(
      `the tally counts both acks and names who is left (${messageAfter.tally})`,
      messageAfter.tally === '2 of 3 got it · waiting on Gate Crew',
    )
    const changeAfter = await logRow(checkTab, 'timeline')
    await checkTab.assertThat(
      `the timeline change still waits on its own group (${changeAfter.tally})`,
      changeAfter.tally === '0 of 2 got it · waiting on Gate Crew',
    )

    await checkTab.shot('shots/step22-log.png')
    await checkTab.assertNoErrors()
  },
}
