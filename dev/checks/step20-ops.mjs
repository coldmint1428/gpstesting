// Step 20, proved through the screen: the ops board of a plan that is running.
//
//     node tools/sql.mjs --file dev/checks/step20-ops-prep.sql
//     node tools/run.mjs dev/checks/step20-ops.mjs --session .tmp/session.json
//
// The event is dev/checks/step20-ops-prep.sql's own bench (e20): a live plan two seconds into its walk, three groups,
// and Gate Crew's two ICs 20 m apart. The check refuses to run without a planner session, because the board is a
// staff read (a member has their own schedule instead, step 16).
//
// WHY THE NUMBERS AND NOT JUST THE WORDS. The database check (step20-ops.sql) proves the arithmetic in degrees; this
// one proves that the arithmetic reaches a person. "1 m from the walk" is the whole point: two ICs 20 m apart, and the
// board must not say 10 m (an average) or 20 m (the sloppy IC) -- the midpoint is 1.18 m from the accurate one.
//
// WHY IT WAITS FOR A FLIP. A moment's status changes when the clock reaches it, and nothing else in this page moves a
// group from "Not started" to "Under way". Gate Crew's first leg is 45 s: when the page opens it is walking, Sound is
// waiting for its +0:45, and Backstage's single moment is at +1:45. Waiting for Sound's state to change is therefore
// waiting for the plan's own clock to pass a frame -- and the assertions after it read the result: the new moment,
// the new leg's travel time, and the group that has finished.
import fs from 'node:fs'

const GATE = '0b000000-0000-4000-8000-00000000a200'
const SOUND = '0b000000-0000-4000-8000-00000000a201'
const BACKSTAGE = '0b000000-0000-4000-8000-00000000a202'

/** One group's line, as the DOM has it: the chip's attribute, and the four pieces of text the screen renders. */
async function rowOf(tab, groupId) {
  return tab.eval(`(() => {
    const row = document.querySelector('[data-testid=ops-row][data-group="${groupId}"]')
    if (!row) return null
    const text = (selector) => {
      const el = row.querySelector(selector)
      return el ? (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim() : ''
    }
    return {
      status: row.getAttribute('data-status'),
      group: text('[data-testid=ops-group]'),
      state: text('[data-testid=ops-state]'),
      when: text('[data-testid=ops-when]'),
      next: text('[data-testid=ops-next]'),
      travel: text('[data-testid=ops-travel]'),
      place: text('[data-testid=ops-place]'),
    }
  })()`)
}

/** Wait until a group's line has a state, then hand back the whole line. */
async function waitForStatus(tab, groupId, status, what, timeout) {
  await tab.waitUntil(
    `(() => {
      const row = document.querySelector('[data-testid=ops-row][data-group="${groupId}"]')
      return !!row && row.getAttribute('data-status') === ${JSON.stringify(status)}
    })()`,
    { timeout, what },
  )
  return rowOf(tab, groupId)
}

export default {
  name: 'step 20 — the ops board: who is under way, what is next, and where a group really is',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e20'
    const live = `${base}/events/${eventId}/live`
    const sessionFile = process.env.SESSION_FILE || '.tmp/session.json'
    if (!fs.existsSync(sessionFile)) {
      throw new Error(`no planner session at ${sessionFile} (mint one with tools/authlink.mjs)`)
    }

    // ---------- 1. the board is on the live page, with one row per group ----------
    const a = await newTab({ label: 'planner, ops board', url: live, width: 1440, height: 1000 })
    await a.waitFor('[data-testid=plan-ops]', { timeout: 25000 })
    await a.waitUntil(`document.querySelectorAll('[data-testid=ops-row]').length === 3`, {
      timeout: 25000,
      what: 'the ops board to have three groups on it',
    })
    await a.assertCount('[data-testid=ops-row]', 3)
    const counts = await a.text('[data-testid=ops-counts]')
    await a.assertThat(
      `the header counts three groups (${counts})`,
      counts.includes('3 groups') && counts.includes('1 under way') && counts.includes('2 not started'),
    )

    // ---------- 2. Gate Crew is walking: the moment, the leg, and one metre off the walk ----------
    const gate = await waitForStatus(a, GATE, 'active', 'Gate Crew to be under way', 20000)
    if (!gate) throw new Error('Gate Crew never appeared on the ops board')
    await a.assertThat(`Gate Crew is under way (${gate.state})`, gate.status === 'active' && gate.state === 'Under way')
    await a.assertThat(`Gate Crew is on its +0:00 moment (${gate.when})`, gate.when === 'Now +0:00 · call')
    await a.assertThat(`Gate Crew's next moment is +0:45 (${gate.next})`, gate.next.startsWith('Next +0:45 · in '))
    await a.assertThat(`the strip gives Gate Crew 45 s for this leg (${gate.travel})`, gate.travel === 'Travel 45 s')
    await a.assertThat(
      `Gate Crew is 1 m off the walk, from its two ICs (${gate.place})`,
      gate.place.includes('1 m from the walk') && gate.place.includes('2 ICs'),
    )

    // Sound has not started: its first moment is the one Gate Crew is walking to.
    const sound = await rowOf(a, SOUND)
    await a.assertThat(
      `Sound is waiting for its first moment (${sound.state} / ${sound.when})`,
      sound.status === 'pending' && sound.state === 'Not started' && sound.when === 'First moment +0:45 · stage',
    )
    await a.assertThat(`Sound's start is counted down (${sound.next})`, sound.next.startsWith('Starts +0:45 · in '))

    // Backstage appears once, at +1:45.
    const backstage = await rowOf(a, BACKSTAGE)
    await a.assertThat(
      `Backstage's only moment is +1:45 (${backstage.when})`,
      backstage.status === 'pending' && backstage.when === 'First moment +1:45 · out',
    )
    await a.assertThat(`Backstage has no ICs sharing (${backstage.place})`, backstage.place === 'No signal')

    await a.shot('shots/step20-ops.png')

    // ---------- 3. the clock passes +0:45 ----------
    // Nothing is clicked: the screen wakes at the moment the read gave it. Waiting for Sound is waiting for that.
    const soundAfter = await waitForStatus(a, SOUND, 'active', 'the clock to reach Sound’s +0:45', 60000)
    if (!soundAfter) throw new Error('Sound never appeared on the ops board')
    await a.assertThat(
      `Sound is under way on its +0:45 moment (${soundAfter.when})`,
      soundAfter.state === 'Under way' && soundAfter.when === 'Now +0:45 · stage',
    )
    await a.assertThat(
      `Sound's +0:45 moment has the next one after it (${soundAfter.next})`,
      soundAfter.next.startsWith('Next +1:45 · in '),
    )
    await a.assertThat(
      `Sound's leg is the 60 s the strip gives it (${soundAfter.travel})`,
      soundAfter.travel === 'Travel 1 min',
    )

    const gateAfter = await rowOf(a, GATE)
    if (!gateAfter) throw new Error('Gate Crew left the ops board')
    await a.assertThat(
      `Gate Crew has finished its walk (${gateAfter.state} / ${gateAfter.when})`,
      gateAfter.status === 'done' && gateAfter.state === 'Done' && gateAfter.when === 'Last moment +0:45 · stage',
    )
    const backstageAfter = await rowOf(a, BACKSTAGE)
    if (!backstageAfter) throw new Error('Backstage left the ops board')
    await a.assertThat(
      `Backstage is still waiting (${backstageAfter.state})`,
      backstageAfter.status === 'pending' && backstageAfter.state === 'Not started',
    )

    const countsAfter = await a.text('[data-testid=ops-counts]')
    await a.assertThat(
      `the header moved with the clock (${countsAfter})`,
      countsAfter.includes('1 under way') && countsAfter.includes('1 not started') && countsAfter.includes('1 done'),
    )

    await a.shot('shots/step20-ops-flipped.png')

    await a.assertNoErrors()
  },
}
