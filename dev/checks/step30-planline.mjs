// Step 30, proved through the screen: on the Live page, under the people, the walk the plan states -- one dashed line per
// group, the leg the clock is on bold and solid -- drawn from the one read the follower's map already uses, and gone
// when the session runs no plan.
//
//     node tools/sql.mjs --file dev/checks/step30-planline-prep.sql
//     node tools/run.mjs dev/checks/step30-planline.mjs --session .tmp/session.json
//
// Needs three more sessions (the check says so if they are missing):
//     node tools/authlink.mjs 2906655b-33ad-4e9d-a608-f083e43e22d4 .tmp/session3.json   (Sound's member)
//     node tools/authlink.mjs ba04a00c-518f-4252-91d5-1081cecec1d2 .tmp/session4.json   (Gate Crew's IC)
//     node tools/authlink.mjs 00cd023b-0e26-4574-a635-760e782c8029 .tmp/session5.json   (a marshal)
//
// THE BENCH IS STEP 29'S, run within five minutes of the prep (the bold leg is the pair +0:00 -> +5:00 only while the
// clock is between them). Gate Crew's walk is one run, a break at its off-site moment, and a lone stage dot; Sound's is a
// lane of five points. Two ICs are sharing, each ~25 m off their group's line, so the picture holds both halves of the
// question at once: where the plan says the group is, and where the group actually is.
//
// What is proved, in order:
//   1. THE STAFF VIEW. Two dashed lines, one per group, in the groups' own colours; one bold leg each, the pair of moments
//      the clock is on and the next; the ops table's row for that same group is on the same moment (a cross-read, not a
//      restatement); the legend says what the bold line is; the checkbox is there and checked; a press on a person's dot
//      still selects them, so the line is not eating the taps; and the walk came from the timetable, not from the plan's
//      frames.
//   2. THE TOGGLE. Off: no line, no leg, the people still there. On again: the line returns -- a hidden layer, not a
//      discarded read.
//   3. TWO IDENTITIES ON THE SAME ADDRESS prove the scope: Sound's member sees one line and it is Sound's; Gate Crew's IC
//      sees one line and it is Gate Crew's; neither sees the staff board.
//   4. THE MARSHAL reads every group: two lines and the board's two rows.
//   5-6. THE TWO EMPTY BENCHES: never started, and running without a plan -- no line, no legend line, no checkbox, and
//      the map that is still there is the people's.
//   7. THE SHOTS.
import fs from 'node:fs'

const soundFile = process.env.SOUND_SESSION || '.tmp/session3.json'
const gateFile = process.env.GATE_SESSION || '.tmp/session4.json'
const marshalFile = process.env.MARSHAL_SESSION || '.tmp/session5.json'
const staffFile = process.env.PLANNER_SESSION || '.tmp/session.json'

const EVENT = '0b000000-0000-4000-8000-000000000e39'
const GATE = '0b000000-0000-4000-8000-00000000a391'
const SOUND = '0b000000-0000-4000-8000-00000000a392'
const NEVER = '0b000000-0000-4000-8000-000000000e3a'
const NO_PLAN = '0b000000-0000-4000-8000-000000000e3b'

/** The dashed line(s) one group's walk is drawn with, and the attributes the check reads off them. */
const lineOf = (group) => `(() => {
  const el = document.querySelector('[data-plan-line="${group}"]')
  return el ? {
    width: el.getAttribute('stroke-width'),
    dash: el.getAttribute('stroke-dasharray'),
    colour: el.getAttribute('stroke'),
    rev: el.getAttribute('data-plan-rev'),
    opacity: el.getAttribute('stroke-opacity'),
  } : null
})()`

/** The bold leg: which two moments the clock is between, and what the stroke says about how loud it is. */
const legOf = (group) => `(() => {
  const el = document.querySelector('[data-plan-leg="${group}"]')
  return el ? {
    from: Number(el.getAttribute('data-leg-from')),
    to: Number(el.getAttribute('data-leg-to')),
    width: el.getAttribute('stroke-width'),
    dash: el.getAttribute('stroke-dasharray'),
    points: el.getAttribute('d'),
  } : null
})()`

/** The staff board's row for one group: the moment the read says it is on. */
const opsRow = (group) => `(() => {
  const el = document.querySelector('[data-testid=ops-row][data-group="${group}"]')
  if (!el) return null
  const when = el.querySelector('[data-testid=ops-when]')
  return { status: el.getAttribute('data-status'), when: when ? when.textContent.replace(/\\s+/g, ' ').trim() : '' }
})()`

const count = (selector) => `document.querySelectorAll(${JSON.stringify(selector)}).length`

/** "+0:00" for a t_s, the way the schedule and the board write a moment. */
const offset = (t) => '+' + Math.floor(t / 60) + ':' + String(t % 60).padStart(2, '0')

export default {
  name: 'step 30 — the plan under the live map',

  async run({ newTab, base }) {
    const live = `${base}/events/${EVENT}/live`

    for (const [file, id, who] of [
      [staffFile, 'ead7d0d2-8c53-4bca-b4e5-27bb8ca513a7', 'planner'],
      [soundFile, '2906655b-33ad-4e9d-a608-f083e43e22d4', "Sound's member"],
      [gateFile, 'ba04a00c-518f-4252-91d5-1081cecec1d2', "Gate Crew's IC"],
      [marshalFile, '00cd023b-0e26-4574-a635-760e782c8029', 'marshal'],
    ]) {
      if (!fs.existsSync(file)) {
        throw new Error(`no ${who} session at ${file}. Mint one with: node tools/authlink.mjs ${id} ${file}`)
      }
    }
    const staff = JSON.parse(fs.readFileSync(staffFile, 'utf8'))
    const sound = JSON.parse(fs.readFileSync(soundFile, 'utf8'))
    const gate = JSON.parse(fs.readFileSync(gateFile, 'utf8'))
    const marshal = JSON.parse(fs.readFileSync(marshalFile, 'utf8'))

    // ---------- 1. the staff view: the walk under the people ----------
    const view = await newTab({ session: staff, label: 'staff live', url: live, width: 1440, height: 1500 })
    await view.waitFor('[data-testid=live-map]', { timeout: 25000 })
    await view.waitFor('[data-testid=plan-ops]', { timeout: 25000 })
    // Both lines and both legs: the read has to have answered, and the clock has to be inside the first leg.
    await view.waitUntil(`${count('[data-plan-line]')} === 2 && ${count('[data-plan-leg]')} === 2`, {
      what: 'the two walks and the two legs of the moment the clock is on',
      timeout: 25000,
    })

    const groups = await view.eval(
      `[...new Set([...document.querySelectorAll('[data-plan-line]')].map((el) => el.getAttribute('data-plan-line')))].sort()`,
    )
    const gateLine = await view.eval(lineOf(GATE))
    const gateLeg = await view.eval(legOf(GATE))
    const soundLeg = await view.eval(legOf(SOUND))
    view.pass(`the lines are drawn for ${groups.length} group(s): ${groups.join(', ')}`)
    view.pass(`Gate Crew's line: dash "${gateLine && gateLine.dash}" at ${gateLine && gateLine.opacity} opacity, v${gateLine && gateLine.rev}`)
    view.pass(`Gate Crew's leg: ${gateLeg && offset(gateLeg.from)} → ${gateLeg && offset(gateLeg.to)}, ${gateLeg && gateLeg.width} px`)

    await view.assertThat(
      'one dashed line per group the read answered, and no more',
      groups.length === 2 && groups.includes(GATE) && groups.includes(SOUND),
    )
    await view.assertThat(
      'the plan’s line is dashed and quiet: 2 px at 55 %',
      !!gateLine && gateLine.width === '2' && /5/.test(gateLine.dash || '') && gateLine.opacity === '0.55',
    )
    await view.assertThat('and it says which revision of the plan it draws', !!gateLine && gateLine.rev === '1')
    await view.assertThat(
      'the leg the clock is on is the pair +0:00 → +5:00',
      !!gateLeg && gateLeg.from === 0 && gateLeg.to === 300,
    )
    await view.assertThat(
      'and it is drawn over the line, solid and loud: 4 px, no dashes',
      !!gateLeg && gateLeg.width === '4' && gateLeg.dash == null && /^M/.test(gateLeg.points || ''),
    )
    await view.assertThat('Sound has its own leg on the same pair of moments', !!soundLeg && soundLeg.from === 0 && soundLeg.to === 300)
    await view.assertThat(
      'each group’s line is in that group’s own colour',
      gateLine.colour.toLowerCase() === '#244f3f' && (await view.eval(lineOf(SOUND))).colour.toLowerCase() === '#8a5a2b',
    )

    // The cross-read: the board's row for the same group is on the same moment the bold leg starts from. This is the
    // sentence the whole step exists for, and it is not a restatement: the row's offset is the board's, the leg's is the
    // map's, and the two reads arrive by different calls.
    await view.waitUntil(`${count('[data-testid=ops-row]')} >= 2`, { what: 'the board’s rows', timeout: 15000 })
    const row = await view.eval(opsRow(GATE))
    view.pass(`the board says of Gate Crew: ${row && row.status} · ${row && row.when}`)
    await view.assertThat(
      'the ops board’s row for Gate Crew is on the moment the bold leg starts from',
      !!row && row.status === 'active' && row.when.includes(offset(gateLeg.from)),
    )
    await view.assertThat(
      'so the line and the row agree about where the group should be right now',
      !!row && row.when.includes(offset(0)) && gateLeg.from === 0,
    )

    // The legend and the toggle.
    const legend = (await view.text('[data-testid=map-plan-legend]')).replace(/\s+/g, ' ').trim()
    view.pass(`the legend says: "${legend}"`)
    await view.assertThat('the legend says what the bold line is', /bold one is due now/i.test(legend))
    const toggle = await view.eval(`(() => {
      const el = document.querySelector('[data-testid=plan-toggle] input')
      return el ? { checked: el.checked, label: el.closest('label').textContent.replace(/\\s+/g, ' ').trim() } : null
    })()`)
    view.pass(`the checkbox: "${toggle && toggle.label}" ${toggle && toggle.checked ? 'checked' : 'unchecked'}`)
    await view.assertThat('the plan layer is on by default, and the box names the revision', !!toggle && toggle.checked && /v1/.test(toggle.label))

    // The people are still the subject: the list is there beside the map, and a press on a dot still selects the person
    // under it -- which is what an `interactive: false` line is for. (The press is made after the picture: a tooltip over
    // the walk would be a picture of a tooltip.)
    await view.waitUntil(`${count('.pm')} >= 1`, { what: 'a person on the map', timeout: 25000 })
    view.pass(`${await view.count('.pm')} person marker(s) on the map`)
    await view.assertThat('the people list is still there beside the map', (await view.count('[data-testid=people-list] li')) >= 1)

    // One read, not a second door: the walk came from the timetable, and the plan's frames were never asked for.
    const asked = await view.eval(`performance.getEntriesByType('resource').map((e) => e.name)`)
    const planSurface = asked.filter((name) => /\/rest\/v1\/(plan_frames|plan_positions)/.test(name))
    view.pass(`${asked.filter((n) => n.includes('session_timetable')).length} timetable read(s), ${planSurface.length} plan-surface resource(s)`)
    await view.assertThat('the walk was read from the timetable', asked.some((name) => name.includes('session_timetable')))
    await view.assertThat('and never from the plan’s frames or positions', planSurface.length === 0)

    // A picture of a map with no tiles on it would be a grey box: wait for the basemap, not for a clock. Then put the
    // map at the top of the window: the Live page is taller than the viewport (the board, the log), and a shot taken
    // from the top is a shot of the board with the map cut in half.
    await view.waitUntil(`${count('.leaflet-tile-loaded')} >= 4`, { what: 'the basemap tiles', timeout: 20000 })
    await view.eval(`window.scrollTo(0, document.querySelector('[data-testid=live-map]').getBoundingClientRect().top + window.scrollY - 24)`)
    await view.sleep(700)
    await view.shot('shots/step30-planline-staff.png')

    await view.click('.pm')
    await view.waitUntil(`${count('.pm-selected')} === 1`, { what: 'a press on a dot to select the person', timeout: 10000 })
    await view.assertThat('a press on a person’s dot still selects them (the line does not eat the tap)', (await view.count('.pm-selected')) === 1)
    await view.assertNoErrors()
    await view.close()

    // ---------- 2. the toggle: a layer, not a discarded read ----------
    const layer = await newTab({ session: staff, label: 'the toggle', url: live, width: 1440, height: 1200 })
    await layer.waitFor('[data-testid=plan-toggle]', { timeout: 25000 })
    await layer.waitUntil(`${count('[data-plan-line]')} === 2`, { what: 'the lines to be drawn first', timeout: 25000 })
    // Wait for both people as well: the markers arrive with the readings, and a count taken while they are still
    // landing would compare the layer's effect with the network's.
    await layer.waitUntil(`${count('.pm')} === 2`, { what: 'both people on the map', timeout: 25000 })
    const peopleBefore = await layer.count('.pm')

    await layer.click('[data-testid=plan-toggle] input')
    await layer.waitUntil(`${count('[data-plan-line]')} === 0 && ${count('[data-plan-leg]')} === 0`, {
      what: 'the layer to go when the box is cleared',
      timeout: 10000,
    })
    layer.pass('unchecked, the walk is gone from the map')
    await layer.assertThat('and the people are untouched by it', (await layer.count('.pm')) === peopleBefore && peopleBefore >= 1)

    await layer.click('[data-testid=plan-toggle] input')
    await layer.waitUntil(`${count('[data-plan-line]')} === 2`, { what: 'the walk to come back', timeout: 10000 })
    await layer.assertThat('checked again, the same walk is back, without asking for it again', (await layer.count('[data-plan-line]')) === 2)
    await layer.assertThat('and the legend never moved, because the plan is still the plan', (await layer.count('[data-testid=map-plan-legend]')) === 1)
    await layer.assertNoErrors()
    await layer.close()

    // ---------- 3. two identities on the same address: the scope ----------
    const soundTab = await newTab({ session: sound, label: 'sound member', url: live, width: 1280, height: 1300 })
    await soundTab.waitFor('[data-testid=live-map]', { timeout: 25000 })
    await soundTab.waitUntil(`${count('[data-plan-line]')} === 1`, { what: "Sound's own line", timeout: 25000 })
    const soundGroups = await soundTab.eval(
      `[...new Set([...document.querySelectorAll('[data-plan-line]')].map((el) => el.getAttribute('data-plan-line')))].join(',')`,
    )
    soundTab.pass(`Sound's member sees the walk of: ${soundGroups}`)
    await soundTab.assertThat('a member sees one line, and it is their own group’s', soundGroups === SOUND)
    await soundTab.assertThat('and none of Gate Crew’s', (await soundTab.count(`[data-plan-line="${GATE}"]`)) === 0)
    await soundTab.assertThat('the staff board is not on a member’s page at all', (await soundTab.count('[data-testid=plan-ops]')) === 0)
    await soundTab.assertThat('their own leg is drawn too', (await soundTab.count(`[data-plan-leg="${SOUND}"]`)) === 1)
    await soundTab.waitUntil(`${count('.leaflet-tile-loaded')} >= 4`, { what: 'the basemap tiles', timeout: 20000 })
    await soundTab.eval(`window.scrollTo(0, document.querySelector('[data-testid=live-map]').getBoundingClientRect().top + window.scrollY - 24)`)
    await soundTab.sleep(600)
    await soundTab.shot('shots/step30-planline-sound.png')
    await soundTab.assertNoErrors()
    await soundTab.close()

    const gateTab = await newTab({ session: gate, label: 'gate crew IC', url: live, width: 1280, height: 1300 })
    await gateTab.waitFor('[data-testid=live-map]', { timeout: 25000 })
    await gateTab.waitUntil(`${count('[data-plan-line]')} === 1`, { what: "Gate Crew's own line", timeout: 25000 })
    await gateTab.assertThat(
      'the other identity sees one line, and it is the other group’s',
      (await gateTab.count(`[data-plan-line="${GATE}"]`)) === 1 && (await gateTab.count(`[data-plan-line="${SOUND}"]`)) === 0,
    )
    await gateTab.assertThat('and no board of theirs either', (await gateTab.count('[data-testid=plan-ops]')) === 0)
    await gateTab.assertNoErrors()
    await gateTab.close()

    // ---------- 4. the marshal reads every group ----------
    const marshalTab = await newTab({ session: marshal, label: 'marshal', url: live, width: 1280, height: 1400 })
    await marshalTab.waitFor('[data-testid=live-map]', { timeout: 25000 })
    await marshalTab.waitUntil(`${count('[data-plan-line]')} === 2`, { what: "both groups' walks for a marshal", timeout: 25000 })
    await marshalTab.assertThat(
      'a marshal sees both lines',
      (await marshalTab.count(`[data-plan-line="${GATE}"]`)) === 1 && (await marshalTab.count(`[data-plan-line="${SOUND}"]`)) === 1,
    )
    await marshalTab.waitUntil(`${count('[data-testid=ops-row]')} === 2`, { what: 'both rows of the board', timeout: 15000 })
    await marshalTab.assertThat('and the board’s two rows', (await marshalTab.count('[data-testid=ops-row]')) === 2)
    await marshalTab.assertNoErrors()
    await marshalTab.close()

    // ---------- 5-6. the two empty benches ----------
    for (const [id, name, why, badge] of [
      [NEVER, 'never started', 'an event that has never been started', 'status-not-started'],
      [NO_PLAN, 'no plan tonight', 'an event running without a plan', 'status-live'],
    ]) {
      const bench = await newTab({ session: staff, label: name, url: `${base}/events/${id}/live`, width: 1200, height: 1000 })
      await bench.waitFor('[data-testid=live-map]', { timeout: 25000 })
      await bench.sleep(2500) // long enough for a read to have arrived, if one were being made
      const state = (await bench.text('[data-testid=event-status]')).replace(/\s+/g, ' ').trim()
      bench.pass(`${why} says: "${state.slice(0, 90)}"`)
      await bench.assertThat(`${why} is the state the check expects`, (await bench.count(`[data-testid=${badge}]`)) === 1)
      await bench.assertThat(`${why} draws no walk`, (await bench.count('[data-plan-line]')) === 0 && (await bench.count('[data-plan-leg]')) === 0)
      await bench.assertThat(`${why} shows no legend line for a plan`, (await bench.count('[data-testid=map-plan-legend]')) === 0)
      await bench.assertThat(`${why} offers no plan checkbox`, (await bench.count('[data-testid=plan-toggle]')) === 0)
      await bench.assertThat(`and the map that is still there is the people’s`, (await bench.eval(`document.querySelector('[data-testid=live-map]').getBoundingClientRect().height`)) > 200)
      await bench.assertNoErrors()
      await bench.close()
    }
  },
}
