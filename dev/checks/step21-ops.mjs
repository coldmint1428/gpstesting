// Step 21, proved through the screen: a moment that closes itself, a moment a person closes, and the hand-back.
//
//     node tools/sql.mjs --file dev/checks/step21-ops-prep.sql
//     node tools/run.mjs dev/checks/step21-ops.mjs --session .tmp/session.json
//
// The event is the prep's own bench (e31): a live plan 58 seconds into its walk, so its +1:00 moment is due two seconds
// after the prep commits. Gate Crew's position is `auto` and its IC is already inside the zone its +1:00 point stands in;
// Sound's is `manual`, and its IC is inside its zone too. So the page opens with both groups due a moment and neither
// recorded, and from there the two halves of step 21 happen without the page being touched:
//
//   * the deployed 5 s tick (gps-plan-push, live on this project) closes Gate Crew's moment by itself. The check waits
//     for the chip to appear: nothing is clicked, and nothing on this page writes it. That is the whole of "an auto
//     verified frame closes when an IC is inside its zone" as a person sees it.
//   * Sound's moment does NOT close, because `manual` means a person has to say so. The two buttons are there; the check
//     presses Arrived and the chip replaces them, marked as a person's.
//
// Then the hand-back: the board says nobody has it, one press writes the row, and a reload proves the row is in the
// database and not on the screen.
import fs from 'node:fs'

const GATE = '0b000000-0000-4000-8000-00000000a311'
const SOUND = '0b000000-0000-4000-8000-00000000a312'

/** One group's line: the mark chip (if any), the buttons (if any), and the words around them. */
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
      state: text('[data-testid=ops-state]'),
      when: text('[data-testid=ops-when]'),
      mark: text('[data-testid=ops-mark]'),
      arrived: !!row.querySelector('[data-testid=ops-mark-arrived]'),
      missed: !!row.querySelector('[data-testid=ops-mark-missed]'),
    }
  })()`)
}

export default {
  name: 'step 21 — a moment that closes itself, a moment a person closes, and who has the board',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e31'
    const live = `${base}/events/${eventId}/live`
    const sessionFile = process.env.SESSION_FILE || '.tmp/session.json'
    if (!fs.existsSync(sessionFile)) {
      throw new Error(`no planner session at ${sessionFile} (mint one with tools/authlink.mjs)`)
    }

    const a = await newTab({ label: 'planner, ops board', url: live, width: 1440, height: 1000 })
    await a.waitFor('[data-testid=plan-ops]', { timeout: 25000 })
    await a.waitUntil(`document.querySelectorAll('[data-testid=ops-row]').length === 2`, {
      timeout: 25000,
      what: 'the ops board to have both groups on it',
    })

    // ---------- 1. both moments are due and neither is recorded ----------
    // At this instant the +1:00 moment is a second or two away, so a group could still be on its +0:00 moment: the
    // assertion is that BOTH groups offer the two buttons and NEITHER has a chip.
    await a.waitUntil(
      `(() => {
        const done = [...document.querySelectorAll('[data-testid=ops-mark-arrived]')].length
        return done === 2
      })()`,
      { timeout: 20000, what: 'both groups to offer the two recording buttons' },
    )
    const gateBefore = await rowOf(a, GATE)
    const soundBefore = await rowOf(a, SOUND)
    await a.assertThat(
      `Gate Crew offers Arrived / Missed and nothing is recorded yet (${gateBefore.mark || 'no chip'})`,
      gateBefore.arrived && gateBefore.missed && gateBefore.mark === '',
    )
    await a.assertThat(
      `Sound offers Arrived / Missed and nothing is recorded yet (${soundBefore.mark || 'no chip'})`,
      soundBefore.arrived && soundBefore.missed && soundBefore.mark === '',
    )
    await a.assertThat(
      `the board starts with nobody holding it (${await a.text('[data-testid=ops-handback]')})`,
      (await a.text('[data-testid=ops-handback]')) === 'No hand-back yet',
    )

    // ---------- 2. the tick closes Gate Crew, with nothing clicked ----------
    // Waiting for this chip is waiting for the cron job: gps-plan-push runs every 5 s, plan_auto_close() sees an `auto`
    // position whose point is inside a zone with its IC in it, and writes the row. Nothing on this page can produce it.
    await a.waitUntil(
      `(() => {
        const row = document.querySelector('[data-testid=ops-row][data-group="${GATE}"]')
        return !!row && !!row.querySelector('[data-testid=ops-mark]')
      })()`,
      { timeout: 60000, what: 'the deployed tick to close Gate Crew’s +1:00 moment' },
    )
    const gateAfter = await rowOf(a, GATE)
    await a.assertThat(
      `Gate Crew's moment closed itself when its IC was inside the zone (${gateAfter.mark})`,
      /^Arrived \d{1,2}:\d{2}\s?(am|pm)/.test(gateAfter.mark) && gateAfter.mark.includes('the phone was there'),
    )
    await a.assertThat(
      `Gate Crew no longer offers the buttons -- the moment is recorded (${gateAfter.mark})`,
      !gateAfter.arrived && !gateAfter.missed,
    )

    // ---------- 3. Sound is left for a person, and a person records it ----------
    const soundStill = await rowOf(a, SOUND)
    await a.assertThat(
      `Sound's manual moment did NOT close itself, while its IC was inside the zone (${soundStill.mark || 'no chip'})`,
      soundStill.mark === '' && soundStill.arrived,
    )
    await a.assertThat(
      `Sound is now on its +1:00 moment (${soundStill.when})`,
      soundStill.when === 'Now +1:00 · stage',
    )

    await a.shot('shots/step21-ops.png')

    await a.click(`[data-testid=ops-row][data-group="${SOUND}"] [data-testid=ops-mark-arrived]`)
    await a.waitUntil(
      `(() => {
        const row = document.querySelector('[data-testid=ops-row][data-group="${SOUND}"]')
        return !!row && !!row.querySelector('[data-testid=ops-mark]')
      })()`,
      { timeout: 15000, what: 'the recorded chip to replace Sound’s buttons' },
    )
    const soundAfter = await rowOf(a, SOUND)
    await a.assertThat(
      `the tap recorded Sound's moment, and the board says a person did it (${soundAfter.mark})`,
      soundAfter.mark.startsWith('Arrived ') && soundAfter.mark.includes('by hand'),
    )
    await a.assertThat(
      `the buttons are gone once the moment is recorded (${soundAfter.mark})`,
      !soundAfter.arrived && !soundAfter.missed,
    )
    // The other group is untouched: one group's record is not another's.
    const gateUntouched = await rowOf(a, GATE)
    await a.assertThat(
      `Gate Crew's record still says the tick closed it (${gateUntouched.mark})`,
      gateUntouched.mark.includes('the phone was there'),
    )

    // ---------- 4. the hand-back ----------
    const beforeTake = await a.text('[data-testid=ops-handback]')
    await a.click('[data-testid=ops-take]')
    await a.waitUntil(
      `!document.querySelector('[data-testid=ops-handback]').innerText.startsWith('No hand-back')`,
      { timeout: 15000, what: 'the board to record that it was taken' },
    )
    const afterTake = await a.text('[data-testid=ops-handback]')
    await a.assertThat(
      `taking the board writes the row and names the taker (${beforeTake} -> ${afterTake})`,
      beforeTake === 'No hand-back yet' && /^Board with testuser1 since \d{1,2}:\d{2}/.test(afterTake),
    )

    // ---------- 5. it is the database, not the screen ----------
    await a.reload()
    await a.waitFor('[data-testid=plan-ops]', { timeout: 25000 })
    await a.waitUntil(`document.querySelectorAll('[data-testid=ops-row]').length === 2`, {
      timeout: 25000,
      what: 'the board to come back after a reload',
    })
    const gateReload = await rowOf(a, GATE)
    const soundReload = await rowOf(a, SOUND)
    await a.assertThat(
      `after a reload the tick's close is still there (${gateReload.mark})`,
      gateReload.mark.includes('the phone was there'),
    )
    await a.assertThat(
      `after a reload the hand mark is still there (${soundReload.mark})`,
      soundReload.mark.includes('by hand'),
    )
    const handReload = await a.text('[data-testid=ops-handback]')
    await a.assertThat(
      `after a reload the board still knows whose it is (${handReload})`,
      handReload === afterTake,
    )

    await a.shot('shots/step21-ops-marked.png')
    await a.assertNoErrors()
  },
}
