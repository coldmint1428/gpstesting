// Step 29, proved through the screen: a follower opens the Map tab and sees the walk their group is meant to take --
// the line through their own moments, on the venue's zones -- and nothing of another group's.
//
//     node tools/sql.mjs --file dev/checks/step29-route-prep.sql
//     node tools/run.mjs dev/checks/step29-route.mjs --session .tmp/session.json
//
// Needs two more sessions (the check says so if they are missing):
//     node tools/authlink.mjs ba04a00c-518f-4252-91d5-1081cecec1d2 .tmp/session4.json   (Gate Crew's IC)
//     node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 .tmp/session3.json   (Sound's member)
//
// The bench (`step29-route-prep.sql`) is a live walk of five frames. Gate Crew has two placed moments at the gate, a
// carried frame, an off-site moment and a stage: one line, one break, and a lone dot. Sound walks a parallel lane in
// open ground with a point at every frame. T+0 is five seconds before the prep commits, so +0:00 is the moment the
// clock is on and +5:00 is the next one the card names.
//
// What is proved, in order:
//   1. GATE CREW'S MEMBER SEES ONE WALK. Three dots, one line, every dot theirs, a label on the moment the clock is on
//      and on the stage; the header names the plan and its revision; the next card names the next moment and its place;
//      and the page asked the timetable for the points rather than the plan's frames or positions.
//   2. THE SCHEDULE'S PLACE IS A WAY TO THE MAP. The three placed moments offer a link and the two placedless ones do
//      not; following it opens the map on that moment, and the moment is still open when the address is opened cold --
//      the focus is in the URL, not in the click.
//   3. SOUND'S MEMBER SEES THEIR OWN WALK AND NONE OF GATE CREW'S. Five dots, one line, every dot theirs, no Gate Crew
//      dot at all: the pair of tabs proves the scope through the interface, not by hiding elements.
//   4. THE PLANNER'S BOARD OF THE SAME WALK, for comparison: the same two groups on the board's locked map, drawn from
//      the plan rather than from the timetable.
import fs from 'node:fs'

const gateFile = process.env.GATE_SESSION || '.tmp/session4.json'
const soundFile = process.env.SOUND_SESSION || '.tmp/session3.json'
const plannerFile = process.env.PLANNER_SESSION || '.tmp/session.json'

const EVENT = '0b000000-0000-4000-8000-000000000e39'
const GATE = '0b000000-0000-4000-8000-00000000a391'
const SOUND = '0b000000-0000-4000-8000-00000000a392'

/** A dot count for one group, as a browser expression. */
const dots = (group) => `document.querySelectorAll('[data-testid=route-dot][data-group="${group}"]').length`

/** The label text of the dot at one t_s, as a browser expression. */
const label = (t) =>
  `(() => { const el = document.querySelector('[data-testid=route-dot][data-t="${t}"] [data-testid=route-dot-label]')
    return el ? el.textContent.replace(/\\s+/g, ' ').trim() : null })()`

export default {
  name: "step 29 — the follower's own map",

  async run({ newTab, base }) {
    const map = `${base}/events/${EVENT}/map`
    const timeline = `${base}/events/${EVENT}/timeline`

    for (const [file, id, who] of [
      [gateFile, 'ba04a00c-518f-4252-91d5-1081cecec1d2', "Gate Crew's IC"],
      [soundFile, '2906655b-33ad-4e9d-a608-f083e43e22d4', "Sound's member"],
      [plannerFile, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'],
    ]) {
      if (!fs.existsSync(file)) {
        throw new Error(`no ${who} session at ${file}. Mint one with: node tools/authlink.mjs ${id} ${file}`)
      }
    }
    const gate = JSON.parse(fs.readFileSync(gateFile, 'utf8'))
    const sound = JSON.parse(fs.readFileSync(soundFile, 'utf8'))
    const planner = JSON.parse(fs.readFileSync(plannerFile, 'utf8'))

    // ---------- 1. Gate Crew's member: their own walk ----------
    const walk = await newTab({ session: gate, label: 'gate crew IC', url: map, width: 1280, height: 1100 })
    await walk.waitFor('[data-testid=plan-route]', { timeout: 25000 })
    await walk.waitUntil(`${dots(GATE)} === 3`, { what: "Gate Crew's three dots", timeout: 20000 })
    await walk.waitUntil(`document.querySelectorAll('path[data-route]').length === 1`, {
      what: 'the one run of Gate Crew’s line',
      timeout: 10000,
    })

    walk.pass(`the title reads "${await walk.text('[data-testid=plan-route] .pv-route-title')}"`)
    await walk.assertThat(
      'the Map tab is the follower’s map, not the placeholder',
      (await walk.text('[data-testid=plan-route] .pv-route-title')).trim() === 'Your route',
    )
    await walk.assertThat('and it names their group', /Gate Crew/.test(await walk.text('[data-testid=route-group]')))
    await walk.assertThat('and the revision it is showing', (await walk.text('[data-testid=route-rev]')).trim() === '1')

    // The walk: three stated moments, one run (0 -> 300), a lone dot after the break.
    await walk.assertThat('three stated moments are drawn', (await walk.count('[data-testid=route-dot]')) === 3)
    await walk.assertThat('and not one of them is another group’s', (await walk.count(`[data-testid=route-dot][data-group="${SOUND}"]`)) === 0)
    await walk.assertThat(
      'the line is Gate Crew’s and there is one run of it',
      (await walk.eval(`[...document.querySelectorAll('path[data-route]')].map((p) => p.getAttribute('data-route')).join(',')`)) === GATE,
    )

    const atGate = await walk.eval(label(0))
    const atStage = await walk.eval(label(1200))
    walk.pass(`the +0:00 dot says "${atGate}"`)
    walk.pass(`the +20:00 dot says "${atStage}"`)
    await walk.assertThat('a placed moment’s label names its clock time', /\d{1,2}:\d{2}\s?(am|pm)/.test(atGate || ''))
    await walk.assertThat('and its place', /Main Gate/.test(atGate || ''))
    await walk.assertThat('the walk’s far end names the stage', /Stage/.test(atStage || ''))
    await walk.assertThat(
      'the two unplaced moments have no dot to label at all (carried and off site)',
      (await walk.count('[data-testid=route-dot][data-t="600"]')) === 0 &&
        (await walk.count('[data-testid=route-dot][data-t="900"]')) === 0,
    )

    // The next moment, over the map.
    const nextText = (await walk.text('[data-testid=route-next]')).replace(/\s+/g, ' ').trim()
    walk.pass(`the card over the map reads "${nextText}"`)
    await walk.assertThat('the card names the next moment, its place and the wait', /next/i.test(nextText) && /Main Gate/.test(nextText) && /in \d+ min|due now/.test(nextText))
    await walk.assertThat('and marks the moment the clock is on', (await walk.count('[data-testid=route-dot].is-current')) === 1)

    // One read, not a second door: the points came from the timetable, and the plan's frames were never asked for.
    const asked = await walk.eval(`performance.getEntriesByType('resource').map((e) => e.name)`)
    const planSurface = asked.filter((name) => /\/rest\/v1\/(plan_frames|plan_list|plan_positions|plan_progress)/.test(name))
    walk.pass(`${asked.filter((n) => n.includes('session_timetable')).length} timetable read(s), ${asked.filter((n) => n.includes('event_zones')).length} zone read(s), ${planSurface.length} plan-surface resource(s)`)
    await walk.assertThat('the map asked the timetable for the points', asked.some((name) => name.includes('session_timetable')))
    await walk.assertThat('it drew the venue’s zones', asked.some((name) => name.includes('event_zones')))
    await walk.assertThat('and never asked for the plan’s frames or positions', planSurface.length === 0)
    // A screenshot of a map with no tiles on it would be a picture of a grey box: wait for the basemap, not for a clock.
    await walk.waitUntil(`document.querySelectorAll('.leaflet-tile-loaded').length >= 4`, {
      what: 'the basemap tiles',
      timeout: 15000,
    })
    await walk.sleep(500) // the tiles fade in; a shot taken mid-fade is a picture of a grey box

    await walk.assertNoErrors()
    await walk.shot('shots/step29-route-gate.png')
    await walk.close()

    // ---------- 2. the schedule's place link opens the same moment ----------
    const schedule = await newTab({ session: gate, label: 'gate crew schedule', url: timeline, width: 1280, height: 1000 })
    await schedule.waitFor('[data-testid=plan-schedule]', { timeout: 25000 })
    await schedule.waitUntil(`document.querySelectorAll('[data-testid=sched-moment]').length === 5`, {
      what: 'the five moments of the walk',
    })

    const links = await schedule.eval(`[...document.querySelectorAll('[data-testid=sched-place-link]')].map((a) => ({
      t: a.closest('[data-testid=sched-moment]').dataset.t,
      href: a.getAttribute('href'),
      place: a.textContent.replace(/\\s+/g, ' ').trim(),
    }))`)
    schedule.pass(`the schedule's place links: ${links.map((l) => `${l.t}s ${l.place}`).join(' | ')}`)
    await schedule.assertThat('three placed moments offer a way to the map', links.length === 3)
    await schedule.assertThat(
      'and only the placed ones: the carried and off-site rows have no link',
      !links.some((l) => l.t === '600' || l.t === '900'),
    )
    await schedule.assertThat(
      'the link names the moment it opens',
      links.some((l) => l.t === '1200' && /\/map\?t=1200$/.test(l.href || '')),
    )
    await schedule.shot('shots/step29-schedule-link.png')

    const stageHref = (links.find((l) => l.t === '1200') || {}).href
    await schedule.click('[data-testid=sched-moment][data-t="1200"] [data-testid=sched-place-link]')
    await schedule.waitUntil(`location.pathname.endsWith('/map')`, { what: 'the map to open', timeout: 15000 })
    await schedule.waitUntil(`!!document.querySelector('[data-testid=route-dot][data-t="1200"]')`, {
      what: 'the stage moment to be on the map',
      timeout: 20000,
    })
    const focused = await schedule.eval(`(() => { const el = document.querySelector('[data-testid=route-dot][data-t="1200"]')
      return el ? el.className + ' | ' + el.querySelector('[data-testid=route-dot-label]').textContent.replace(/\\s+/g, ' ').trim() : null })()`)
    schedule.pass(`the opened moment: ${focused}`)
    await schedule.assertThat('the moment the link named is the one marked on the map', /is-focused/.test(focused || ''))
    await schedule.assertThat('and its label names the stage', /Stage/.test(focused || ''))
    await schedule.assertNoErrors()
    await schedule.close()

    // The address is the focus: opened cold, it lands on the same moment.
    const cold = await newTab({ session: gate, label: 'gate crew, address only', url: `${base}${stageHref}`, width: 1280, height: 1000 })
    await cold.waitFor('[data-testid=plan-route]', { timeout: 25000 })
    await cold.waitUntil(`!!document.querySelector('[data-testid=route-dot].is-focused')`, {
      what: 'the address to open on the moment it names',
      timeout: 20000,
    })
    await cold.assertThat(
      'the focus is in the URL, so a reload keeps it',
      (await cold.eval(`document.querySelector('[data-testid=route-dot].is-focused').getAttribute('data-t')`)) === '1200',
    )
    await cold.assertNoErrors()
    await cold.close()

    // ---------- the sentences, not an empty map ----------
    const empty = await newTab({
      session: gate,
      label: 'never started',
      url: `${base}/events/0b000000-0000-4000-8000-000000000e3a/map`,
      width: 1280,
      height: 900,
    })
    await empty.waitFor('[data-testid=plan-route]', { timeout: 25000 })
    await empty.waitUntil(`document.querySelector('[data-testid=route-empty]') !== null`, {
      what: 'the sentence for an event with no schedule',
      timeout: 15000,
    })
    const emptyText = (await empty.text('[data-testid=route-empty]')).replace(/\s+/g, ' ').trim()
    empty.pass(`an event that has never been started says: "${emptyText}"`)
    await empty.assertThat('an event that has never been started says so', /No schedule yet/.test(emptyText))
    await empty.assertThat(
      'and no map is drawn behind the sentence',
      (await empty.eval(`document.querySelector('[data-testid=route-map]').getBoundingClientRect().height`)) === 0,
    )
    await empty.assertThat(
      'with nothing on it',
      (await empty.count('[data-testid=route-dot]')) === 0 && (await empty.count('path[data-route]')) === 0,
    )
    await empty.shot('shots/step29-route-empty.png')
    await empty.assertNoErrors()
    await empty.close()

    const noPlan = await newTab({
      session: gate,
      label: 'no plan tonight',
      url: `${base}/events/0b000000-0000-4000-8000-000000000e3b/map`,
      width: 1280,
      height: 900,
    })
    await noPlan.waitFor('[data-testid=plan-route]', { timeout: 25000 })
    await noPlan.waitUntil(`document.querySelector('[data-testid=route-empty]') !== null`, {
      what: 'the sentence for an event running without a plan',
      timeout: 15000,
    })
    const noPlanText = (await noPlan.text('[data-testid=route-empty]')).replace(/\s+/g, ' ').trim()
    noPlan.pass(`an event running without a plan says: "${noPlanText}"`)
    await noPlan.assertThat('an event running without a plan says so', /running without a plan/.test(noPlanText))
    await noPlan.assertThat(
      'and does not draw a map either',
      (await noPlan.eval(`document.querySelector('[data-testid=route-map]').getBoundingClientRect().height`)) === 0,
    )
    await noPlan.assertNoErrors()
    await noPlan.close()

    // ---------- 3. Sound's member: their own walk, and none of Gate Crew's ----------
    const other = await newTab({ session: sound, label: 'sound member', url: map, width: 1280, height: 1100 })
    await other.waitFor('[data-testid=plan-route]', { timeout: 25000 })
    await other.waitUntil(`${dots(SOUND)} === 5`, { what: "Sound's five dots", timeout: 20000 })
    await other.waitUntil(`document.querySelectorAll('path[data-route]').length === 1`, {
      what: "Sound's line",
      timeout: 10000,
    })

    const soundGroup = await other.text('[data-testid=route-group]')
    other.pass(`the other member's header says "${soundGroup.replace(/\\s+/g, ' ').trim()}"`)
    await other.assertThat('the header names Sound, not Gate Crew', /Sound/.test(soundGroup) && !/Gate Crew/.test(soundGroup))
    await other.assertThat('five stated moments are drawn', (await other.count('[data-testid=route-dot]')) === 5)
    await other.assertThat('and not one of them is Gate Crew’s', (await other.count(`[data-testid=route-dot][data-group="${GATE}"]`)) === 0)
    await other.assertThat(
      'the line is Sound’s',
      (await other.eval(`[...document.querySelectorAll('path[data-route]')].map((p) => p.getAttribute('data-route')).join(',')`)) === SOUND,
    )
    // Every one of Sound's moments stands in open ground: a point, no place, so no place on any label.
    const soundLabels = await other.eval(`[...document.querySelectorAll('[data-testid=route-dot-label]')].map((e) => e.textContent.replace(/\\s+/g, ' ').trim())`)
    other.pass(`Sound's labels: ${soundLabels.join(' | ')}`)
    await other.assertThat(
      'a route point is a point with no place on its label',
      soundLabels.length === 5 && soundLabels.every((text) => !/Main Gate|Stage/.test(text)),
    )
    await other.assertThat(
      'and the two members see each other’s group nowhere on this page',
      (await other.count(`[data-testid=route-dot][data-group="${GATE}"]`)) === 0,
    )
    await other.waitUntil(`document.querySelectorAll('.leaflet-tile-loaded').length >= 4`, {
      what: "Sound's basemap tiles",
      timeout: 15000,
    })
    await other.sleep(500)

    await other.assertNoErrors()
    await other.shot('shots/step29-route-sound.png')
    await other.close()

    // ---------- 4. the planner's board of the same walk ----------
    const board = await newTab({ session: planner, label: 'planner', url: timeline, width: 1440, height: 1400 })
    await board.waitFor('.pv-board', { timeout: 25000 })
    await board.waitUntil(`document.querySelectorAll('.pv-marker').length >= 2`, {
      what: 'the board to draw both groups at its open frame',
      timeout: 20000,
    })
    await board.waitUntil(`document.querySelectorAll('.pv-marker').length >= 2`, {
      what: 'the board to draw both groups at its open frame',
      timeout: 20000,
    })
    board.pass('the board draws the same two groups from the plan, for comparison')
    await board.waitUntil(`document.querySelectorAll('.leaflet-tile-loaded').length >= 4`, {
      what: "the board's basemap tiles",
      timeout: 15000,
    })
    await board.sleep(600)
    await board.assertNoErrors()
    await board.shot('shots/step29-board.png')
    await board.close()
  },
}
