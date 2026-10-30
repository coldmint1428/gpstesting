// Step 25, proved through the screen: the run sheet is gone from the event page, and what replaced it is what is there.
//
//     node tools/sql.mjs --file supabase/fixtures/plan_bench.sql
//     node tools/sql.mjs --file dev/checks/step20-ops-prep.sql
//     node tools/run.mjs dev/checks/step25-gone.mjs --session .tmp/session.json
//
// Two fixtures, because two screens need different ones. The Timeline and Live tabs are step 20's own bench (e20): a
// live plan with three groups on its ops table. That is the point — these pages used to hold a show bar, an ops queue
// beside the map and a queued "next move" card for a member, all fed by `movement_status`/`show_state`. Step 25 deleted
// them, and the Live page now shows the plan's own ops table, the map, and nothing else of that machinery. Playback and
// the Zones card need an event with a recording and with zones, which is the bench fixture (e01).
//
// A check that asserts an ABSENCE is only worth keeping if the absence is what the step sold. Every assertion below is
// about a selector or a word that used to exist and must not come back — the Timeline's "open the classic run sheet"
// button and its mention of a run sheet, the show bar, the ops queue, the map's cluster hint and toggle, Playback's
// "Ran with" line, the Zones card's movement count — and each one is paired with the thing that is there instead, so a
// page that failed to render at all cannot pass. If a later step reintroduces any of it, this fails.
//
// The screenshots are the review's evidence: the board with no run-sheet button, the Live page with the plan's ops
// table and a map that no longer clusters, the recording list without its run-sheet line, and the zones card.
import fs from 'node:fs'

export default {
  name: 'step 25 — the run sheet is gone from the event page',

  async run({ newTab, base }) {
    const eventId = '0b000000-0000-4000-8000-000000000e20'
    const sessionFile = process.env.SESSION_FILE || '.tmp/session.json'
    if (!fs.existsSync(sessionFile)) {
      throw new Error(`no planner session at ${sessionFile} (mint one with tools/authlink.mjs)`)
    }

    // ---------- the Timeline tab: the plan board, and no way into a run sheet ----------
    const board = await newTab({
      label: 'planner, timeline',
      url: `${base}/events/${eventId}/timeline`,
      width: 1440,
      height: 1000,
    })
    await board.waitFor('.pv-frame', { timeout: 25000 })
    await board.assertThat(
      'the timeline mentions no run sheet at all',
      `!/run sheet/i.test(document.body.innerText)`,
    )
    await board.assertThat(
      'the plan board is what the timeline shows',
      `!!document.querySelector('.pv-bar-head') && document.querySelectorAll('.pv-frame').length > 0`,
    )
    await board.shot('shots/step25-timeline.png')

    // ---------- the Live page: a plan session, its ops table, and none of the show's machinery ----------
    const live = await newTab({
      label: 'planner, live',
      url: `${base}/events/${eventId}/live`,
      width: 1440,
      height: 1000,
    })
    await live.waitFor('[data-testid=plan-ops]', { timeout: 25000 })
    await live.assertThat(
      'the live page has no show bar and no ops queue',
      `!document.querySelector('.show-bar') && !document.querySelector('[data-testid=ops-queue]')`,
    )
    await live.assertThat(
      'the map no longer clusters groups or draws status rings',
      `!document.querySelector('[data-testid=clusters-toggle]') && !document.querySelector('[data-testid=cluster-hint]')`,
    )
    await live.assertThat(
      'the map itself is still there',
      `!!document.querySelector('[data-testid=live-map]')`,
    )
    // The third group's moment is +1:45 on the prep's clock, so the table fills as the clock turns (step 20's own
    // check waits for the same three rows).
    await live.waitUntil(`document.querySelectorAll('[data-testid=ops-row]').length === 3`, {
      timeout: 25000,
      what: 'the plan ops table to have all three groups on it',
    })
    await live.assertThat(
      'the plan ops table is what tells the staff where their groups are',
      `document.querySelectorAll('[data-testid=ops-row]').length === 3`,
    )
    await live.shot('shots/step25-live.png')

    // ---------- Playback: still lists recordings, without the run-sheet line it used to carry ----------
    // The list read `session_run_sheets` to say "Ran with: Rehearsal 2, then 2b from 8:14 pm". That function is gone,
    // so the line is gone; the recordings are not. This tab and the next read the bench event, which has a recording
    // and zones (the step-20 bench has neither).
    const bench = '0b000000-0000-4000-8000-000000000e01'
    const playback = await newTab({
      label: 'planner, playback',
      url: `${base}/events/${bench}/playback`,
      width: 1440,
      height: 1000,
    })
    await playback.waitFor('[data-testid=playback-panel]', { timeout: 25000 })
    await playback.waitUntil(`!/Loading/.test(document.querySelector('[data-testid=playback-panel]').innerText)`, {
      timeout: 30000,
      what: 'the recording list to finish loading',
    })
    await playback.assertThat(
      'the playback list has no "Ran with" line',
      `!document.querySelector('[data-testid=ran-with]')`,
    )
    await playback.assertThat(
      'the playback list still lists the recording',
      `!!document.querySelector('[data-testid=playback-panel]').innerText.match(/readings|recording/i)`,
    )
    await playback.shot('shots/step25-playback.png')

    // ---------- the Zones card: the zones, without a run-sheet movement count ----------
    const map = await newTab({
      label: 'planner, zones',
      url: `${base}/events/${bench}/map`,
      width: 1440,
      height: 1000,
    })
    await map.waitFor('[data-testid=zone-overview]', { timeout: 25000 })
    // The card reads the zones when it mounts, so it is empty for a moment.
    await map.waitUntil(`document.querySelectorAll('[data-testid=zone-overview] [data-testid^=zone-]').length > 0`, {
      timeout: 20000,
      what: 'the zones card to list the event\u2019s zones',
    })
    await map.assertThat(
      'the zones card no longer names the run sheet or counts movements',
      `!/In the run sheet/i.test(document.querySelector('[data-testid=zone-overview]').innerText)`,
    )
    await map.assertThat(
      'the zones card still lists the event\u2019s zones',
      `document.querySelectorAll('[data-testid=zone-overview] [data-testid^=zone-]').length > 0`,
    )
    await map.shot('shots/step25-zones.png')
  },
}
